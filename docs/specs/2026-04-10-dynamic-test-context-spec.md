# Dynamic Test Context — Design Specification

> **spec_id:** 2026-04-10-dynamic-test-context-1430
> **topic:** Replace static project profile with per-task CodeSift retrieval in write-tests
> **status:** Draft
> **created_at:** 2026-04-10T14:30:00Z
> **approved_at:** null
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

The project profile system (`analyze_project()` → `.zuvo/project-profile.json`) was built to give zuvo skills project-level context. After testing on 4 real projects (tgmcontest, tgm-survey-platform, translation-qa, and service-level files), the results are:

- **ORCHESTRATOR files (app.ts):** profile helps — 32/32 invariants passed. ~1% of files.
- **SERVICE/UTILITY/COMPONENT files:** profile gives near-zero value. "Profile jest overhead, nie asset" (direct user feedback). ~80% of files.

Root cause identified by research (STALL+ 2024, CoCoGen 2024, CrossCodeEval 2023):

1. **Static metadata is the wrong signal.** "framework: hono" doesn't help write a service test. What helps is: "here's how an existing test in this project mocks Prisma, here's the setup file, here's the error class import path."
2. **Task-time retrieval beats pre-loaded profiles.** Aider (PageRank on code graph), Cody (BM25 + semantic), Copilot (GitHub code search) — none pre-compute a static profile. All do on-demand retrieval.
3. **File-level dependency graph is the strongest signal.** STALL+ found +24% accuracy over RAG alone. What does this file import? What imports it? What test files exist for its dependencies?
4. **Generic context hurts more than it helps.** RLCoder (ICSE 2025): naively retrieved context adds noise. ContextBench (2025): 30-50% of provided context isn't utilized.

The profile system adds ~34K tokens of mostly useless data (file classifications for 6749 files when the skill needs patterns for 1 file), costs $5-7 per test session in wasted context, and doesn't improve the quality gates that actually fail (CQ25: pattern compliance, CQ26: structured logger — both require project-specific code examples, not labels).

**If we do nothing:** write-tests continues to work at current quality, but we maintain a complex system (profile generation, caching, protocol, SessionStart hook) that delivers negligible value for 80% of tasks.

## Design Decisions

### DD1: Replace static profile with per-task dynamic retrieval

**Chosen:** When CodeSift is available, write-tests Phase 0 queries CodeSift for context specific to the target file. No pre-computed profile. No JSON on disk. Each task gets exactly the context it needs.

**Rejected:** Expanding the static profile with more sections (conventions bundle, import maps, pattern exemplars). Research consensus (STALL+, CoCoGen, Aider, Cody) is that static pre-loaded context is the wrong approach for code generation. More data ≠ more useful.

### DD2: No CodeSift = no context enrichment (legacy behavior)

**Chosen:** Without CodeSift, write-tests falls back to current legacy behavior (read package.json, detect test runner, read existing tests manually). No degraded profile, no partial context.

**Why:** The profile only exists because CodeSift generates it. Without CodeSift there's nothing to fall back to. This makes CodeSift a genuine value-add: install it → get better tests.

### DD3: Retrieval is 4 targeted dimensions, not a dump

**Chosen:** Phase 0 retrieves context along exactly 4 dimensions, each answering a specific question. Each dimension may involve 1-3 CodeSift tool calls (total budget: max ~12 MCP calls across all dimensions):

1. **"What does an existing test for this code type look like in THIS project?"** → Find exemplar test file
2. **"What does this file import and how are those dependencies tested?"** → Import graph + existing mocks
3. **"What mock patterns does this project use?"** → Setup files + common mock signatures
4. **"What are the key signatures of utilities this file depends on?"** → Hub function signatures

Total budget: ~5K tokens retrieved. Not 34K of profile dump.

**Rejected:** Single large `codebase_retrieval` call with many sub-queries. Research (ContextBench) shows that large context dumps have 30-50% waste. Targeted queries with explicit purposes produce better utilization.

### DD4: Exemplar-based context over label-based context

**Chosen:** Instead of telling the LLM "mock_style: vi.mock" (a label), show it an actual test file from the same project that uses vi.mock correctly (an exemplar). The LLM learns patterns from examples, not from metadata descriptions.

**Research basis:** Claude Code's own plugin system uses this approach — `examples/` directory in skills with working code. CoCoGen's +80% improvement comes from iterative refinement against real project code, not metadata.

## Solution Overview

```
write-tests Phase 0 (with CodeSift)
│
├─ Query 1: find_exemplar_test
│  → "Find a test file for a [SERVICE/GUARD/etc.] in this project"
│  → Returns: path to best matching existing test file
│  → Skill reads it as a pattern reference
│
├─ Query 2: get_import_context
│  → "What does target file import? What tests exist for those imports?"
│  → Returns: import list + existing mock patterns for each dependency
│
├─ Query 3: get_test_setup
│  → "What setup/helper files does this project's test suite use?"
│  → Returns: setup file paths + key exports (factories, mocks, helpers)
│
└─ Query 4: get_hub_signatures
   → "What utility functions does this file use? Show signatures."
   → Returns: function signatures for reused utilities (not full source)

Total: ~5K tokens of highly relevant, task-specific context
vs. ~34K tokens of mostly irrelevant static profile
```

**Data flow:**

```
Skill Phase 0
  → detect code type (read file, classify)
  → IF CodeSift available:
      → run 4 targeted queries (~5K tokens total)
      → inject results into Step 1 context
  → IF CodeSift unavailable:
      → legacy behavior (read package.json, grep for test patterns)
  → proceed to Step 1 (Analyze) with enriched context
```

## Detailed Design

### Files Changed

| File | Change |
|------|--------|
| `skills/write-tests/SKILL.md` | Phase 0 Step 2: replace static profile loading with 4 CodeSift queries |
| `shared/includes/project-profile-protocol.md` | No change (stays for other skills, write-tests stops referencing it) |

### CodeSift Tool Reference

All queries use existing CodeSift MCP tools. Parameter schemas per `codesift-setup.md`:

| Tool | Purpose | Key params |
|------|---------|-----------|
| `codebase_retrieval` | Batch multi-query retrieval | `queries: [{type, query, file_pattern, ...}]`, `token_budget` |
| `search_text` | Text pattern search | `query`, `file_pattern`, `top_k`, `group_by_file` |
| `find_references` | Find all usages of a symbol | `symbol_name` |
| `trace_call_chain` | Caller/callee graph | `symbol_name`, `direction: "callers"\|"callees"`, `depth` |
| `get_file_outline` | Symbol list for a file | `file_path` |
| `assemble_context` | Token-budgeted symbol dump | `query`, `level: "L0"\|"L1"\|"L2"\|"L3"`, `token_budget` |

**L1 = signatures and docstrings only** (~56 symbols per 5K budget). L0 = full source. L1 is the right level for "show me what exists" without overwhelming context.

### Decision: 4 separate calls (not batch)

Separate calls allow per-query graceful skip on failure (as specified in Failure Modes). A batch call would require all-or-nothing error handling. The 4 queries are independent — partial results from 3/4 queries are strictly better than 0/4.

### Query 1: find_exemplar_test

**Purpose:** Find the best existing test file to use as a pattern reference for the target file.

**Implementation:**
```
codebase_retrieval(repo, token_budget=2000, queries=[
  {type: "semantic", query: "test for [code_type] [similar_name]"},
  {type: "text", query: "describe.*[code_type]", file_pattern: "*.test.*"}
])
```

**Selection heuristic:** Prefer test files that:
1. Test the same code type (SERVICE → find another SERVICE test)
2. Are in the same module/directory
3. Have recent git activity (actively maintained tests)
4. Have passing Q-scores from prior write-tests runs (if coverage.md exists)

**Output to skill:** Path to 1 exemplar test file. Skill reads it with `Read` tool. This becomes the "here's how tests look in this project" reference.

### Query 2: get_import_context

**Purpose:** Understand what the target file depends on and how those dependencies are mocked in existing tests.

**Implementation:**
```
codebase_retrieval(repo, token_budget=1500, queries=[
  {type: "references", symbol_name: "<main_export>"},
  {type: "call_chain", symbol_name: "<main_export>", direction: "callees", depth: 1}
])
```

Then for **at most 5 dependencies** (sorted by import order, skip node_modules):
```
search_text(repo, query: "vi.mock.*<dependency_path>", file_pattern: "*.test.*", top_k: 3)
```

Cap at 5 to prevent unbounded CodeSift calls when a file has many imports.

**Output to skill:** List of dependencies + how each is mocked in existing project tests. This gives the LLM concrete mock patterns, not abstract labels.

### Query 3: get_test_setup

**Purpose:** Find shared test infrastructure (setup files, factories, custom matchers).

**Implementation:**
```
search_text(repo, query: "beforeAll|globalSetup|setupFiles", file_pattern: "vitest.config.*|jest.config.*|setup.*")
```

Plus:
```
get_file_outline(repo, file_path: "<detected_setup_file>")
```

**Output to skill:** Setup file path + list of exported helpers (factory functions, mock builders, DB helpers). Skill reads only the relevant exports, not the whole file.

### Query 4: get_hub_signatures

**Purpose:** Show signatures (not full source) of utility functions the target file imports.

**Implementation:**
```
assemble_context(repo, query: "<imports_from_target_file>", level: "L1", token_budget: 1000)
```

L1 = signatures and docstrings only (~56 symbols per 5K budget). This tells the LLM what utilities exist without overwhelming it with implementation details.

**Output to skill:** Function signatures for imported utilities. The LLM knows `paginate(items, page, limit)` exists without reading 200 lines of pagination code.

### Integration with write-tests SKILL.md

Phase 0 Step 2 changes from:

```
2. **Project profile (MANDATORY):** Read .zuvo/project-profile.json...
```

To:

```
2. **Dynamic context (when CodeSift available):**
   Run 4 targeted CodeSift queries for the target file:
   a. Find exemplar test (same code type, same module) → Read it as pattern reference
   b. Get import context (what target imports, how deps are mocked in existing tests)
   c. Get test setup (setup files, factories, helpers)
   d. Get hub signatures (L1 signatures of imported utilities)
   
   Print: [CONTEXT] Loaded: exemplar={path}, {N} import mocks, {N} setup helpers, {N} utility signatures
   
   If CodeSift unavailable: skip to Step 3 (legacy stack detection).
```

### What Changes in write-tests

**write-tests stops using:**
1. Static profile loading (`Read .zuvo/project-profile.json`)
2. Reference to `project-profile-protocol.md` in mandatory file loading

**Everything else stays unchanged:**
1. `project-profile-protocol.md` — stays in `shared/includes/` (other skills may use it)
2. SessionStart hook profile summary — stays (low cost, useful for orientation)
3. `analyze_project()` MCP tool — stays (useful for project overview, onboarding)
4. `.zuvo/project-profile.json` on disk — stays if generated (not deleted, not read by write-tests)
5. **Stack detection** from legacy (package.json) or CodeSift — still needed for test runner
6. **Code type classification** — still done in Step 1 per `test-code-types.md`
7. **All quality gates, contracts, adversarial review** — unchanged
8. **CodeSift setup** in Phase 0 — still needed for the 4 retrieval dimensions

### Edge Cases

| Edge case | Handling |
|-----------|----------|
| CodeSift available but no exemplar test found | Skip exemplar, proceed with other 3 queries. Print: `[CONTEXT] No exemplar found for [code_type] — using generic patterns.` |
| Target file has zero imports | Skip Query 2 and 4. Only exemplar + setup. |
| Very large project (>10K files) | Queries have token budgets — CodeSift handles truncation. No degradation. |
| Monorepo — target in workspace A, tests in workspace B | CodeSift indexes the full repo — cross-workspace queries work. |
| No test files exist anywhere in project | All 4 queries return empty. Legacy behavior. Print: `[CONTEXT] No existing tests found — writing from scratch.` |
| CodeSift index stale | CodeSift auto-refreshes via file watcher. Not our problem. |

### Failure Modes

#### CodeSift query timeout

| Scenario | Detection | Console output | Recovery |
|----------|-----------|---------------|----------|
| Single query takes >10s | Catch MCP timeout exception | `[CONTEXT] Query N timed out — skipping {dimension}.` | Skip that query, proceed with others |
| All 4 queries timeout | All 4 catch blocks fire | `[CONTEXT] All queries failed — using legacy detection.` | Fall back to legacy |
| CodeSift MCP server down | Connection refused / MCP error | `[CONTEXT] CodeSift unavailable — using legacy detection.` | Fall back to legacy, warn once per session |
| Query returns empty result | Result array length === 0 | `[CONTEXT] No {dimension} found for {code_type}.` | Skip silently, proceed |

**Cost-benefit:** Frequency: rare (<1%) × Severity: low (graceful fallback) → **Accept**

#### Retrieved context is misleading

| Scenario | Detection | Console output | Recovery |
|----------|-----------|---------------|----------|
| Exemplar test is low quality | Not detectable pre-generation | None (exemplar loaded silently) | Adversarial review catches bad patterns in Step 4 |
| Mock pattern is outdated | Not detectable pre-generation | None | Test failure in Step 2 → fix cycle catches it |
| Hub signature changed since index | Import/compile error at runtime | Test run fails with clear error | Fix cycle: read actual file, correct signature |

**Cost-benefit:** Frequency: occasional (~5%) × Severity: medium (wrong first attempt, caught by existing verification cycle) → **Accept**

## Acceptance Criteria

### Ship criteria (must pass)

1. write-tests Phase 0 retrieves context along 4 dimensions (max ~12 MCP tool calls total) when CodeSift available
2. Total retrieval completes in <20s (individual calls may vary, total wall time budgeted)
3. Total retrieved context is <6K tokens
4. Legacy fallback works when CodeSift unavailable (no exceptions, skill completes normally, same behavior as pre-change write-tests)
5. Existing quality gates (Q1-Q19, adversarial) produce zero new gate failures on a fixed 5-file corpus vs. baseline commit
6. No new mandatory files loaded (net context reduction)

### Success criteria (must pass for value)

7. First-pass Q score for SERVICE files: median >= 16/19 across 5 runs (same as current — no regression)
8. CQ25 (pattern compliance) violations in generated tests: reduced by >= 30% vs. current (measured by adversarial pass 1 findings)
9. Token cost per test session: reduced by >= 40% vs. current (34K profile → <6K retrieval)
10. Exemplar-based tests match project mock patterns without manual correction in >= 70% of cases

## Validation Methodology

**For AC #7 (Q score no regression):**
Run write-tests on 5 SERVICE files in tgm-survey-platform (same files, same commit):
- 5 runs with dynamic retrieval → record Q self-eval score from Step 3
- Median Q score must be >= 16/19
- Compare against baseline from current profile-based runs (if available) to confirm no regression

**For AC #8 (CQ25 violations):**
Run write-tests on 5 SERVICE files in tgm-survey-platform (same files, same commit):
- 5 runs with current profile system → count CQ25 violations from adversarial pass 1
- 5 runs with dynamic retrieval → count CQ25 violations
- Compare: dynamic retrieval should have >= 30% fewer violations

**For AC #9 (token cost):**
Measure total input tokens (from Claude Code usage display) for a complete write-tests run:
- Current: profile system (~34K profile + skill includes)
- New: dynamic retrieval (~5K queries + skill includes)
- Delta should be >= 40% reduction in total input tokens

**For AC #10 (mock pattern match):**
After generating test for each of 10 SERVICE files:
- Check: does generated test use same mock import style as exemplar? (vi.mock path match)
- Check: does it import from project setup helpers? (setup file usage)
- Check: does it follow project's beforeEach pattern?
- Score: count files where all 3 checks pass. Must be >= 7/10.

## Rollback Strategy

Remove the 4 retrieval dimensions from Phase 0 Step 2. Skill reverts to legacy behavior (package.json detection, no enriched context). The queries are additive — removing them leaves the skill fully functional at pre-change quality.

No data to preserve — dynamic retrieval doesn't write to disk. Existing `.zuvo/project-profile.json` files remain untouched.

## Backward Compatibility

- `project-profile-protocol.md` remains in shared/includes but write-tests stops referencing it
- `.zuvo/project-profile.json` files on disk are ignored by write-tests (not deleted — other uses may exist)
- `analyze_project()` MCP tool stays available for direct use
- SessionStart hook profile summary stays (useful for orientation, low cost)

## Out of Scope

### Deferred to v2

- Dynamic retrieval for `zuvo:build` (code writing) — same approach, different queries
- Dynamic retrieval for `zuvo:review` and `zuvo:refactor`
- CodeSift-side query optimization (batching, caching)
- Exemplar quality scoring (prefer tests with high Q scores)

### Permanently out of scope

- Static profile expansion (more sections, more data) — research says this is wrong direction
- Embedding-based retrieval (Aider/Cody use structural search, not embeddings, for code)
- Profile generation for projects without CodeSift

## Open Questions

1. ~~**Batch vs separate calls**~~ **RESOLVED:** 4 separate calls. Rationale: allows per-query graceful skip as specified in Failure Modes. See "Decision: 4 separate calls" in Detailed Design.

2. ~~**Exemplar selection in large projects**~~ **RESOLVED:** CodeSift semantic search with selection heuristic defined in Query 1: same directory > same code type > any test. The `token_budget=2000` parameter caps results regardless of project size.
