# Dynamic Test Context + Lazy Include Loading — Design Specification

> **spec_id:** 2026-04-10-dynamic-test-context-1430
> **topic:** Lazy include loading + per-task CodeSift retrieval — classify first, load matching context
> **status:** Approved
> **created_at:** 2026-04-10T14:30:00Z
> **approved_at:** 2026-04-10T15:00:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

Two separate but compounding problems waste tokens and hurt test quality:

### Problem 1: Static profile is useless for 80% of files

The project profile system (`analyze_project()` → `.zuvo/project-profile.json`) was built to give skills project context. After testing on 4 real projects (tgmcontest, tgm-survey-platform, translation-qa, service-level files):

- **ORCHESTRATOR files (app.ts):** profile helps — 32/32 invariants passed. ~1% of files.
- **SERVICE/UTILITY/COMPONENT files:** profile gives near-zero value. ~80% of files.

Research confirms (STALL+ 2024, CoCoGen 2024, CrossCodeEval 2023):
1. **Static metadata is the wrong signal.** "framework: hono" doesn't help write a service test. An existing test file from the project does.
2. **Task-time retrieval beats pre-loaded profiles.** Aider, Cody, Copilot — none pre-compute static profiles. All do on-demand retrieval.
3. **File-level dependency graph is the strongest signal.** STALL+ found +24% accuracy over RAG alone.
4. **Generic context hurts more than it helps.** RLCoder (ICSE 2025): naively retrieved context adds noise. ContextBench (2025): 30-50% of provided context isn't utilized.

### Problem 2: Eager include loading wastes 60-70% of context

Current write-tests Phase 0 loads ALL includes BEFORE reading the production file:

| Include | Lines | What write-tests actually uses | Waste |
|---------|-------|-------------------------------|-------|
| quality-gates.md | 144 | Q1-Q19 only (lines 88-144). CQ1-CQ28 are for code review, not tests | **60%** |
| test-contract.md | 149 | Only the variant matching code type (e.g., SERVICE doesn't need ORCHESTRATOR template) | **50%** |
| test-code-types.md | 240 | Only 1 of 11 type sections (e.g., SERVICE agent doesn't need COMPONENT/HOOK/ORCHESTRATOR templates) | **70%** |
| test-mock-safety.md | 27 | All rules — but skip entirely for PURE (no mocks) | **100% for PURE** |
| test-edge-cases.md | ~80 | All rules — but skip entirely for THIN (insufficient branching) | **100% for THIN** |

Agent feedback from PHP session (96 LOC service, 5 branches): 182K tokens consumed, 6.5K useful = **3.6% efficiency**. The pipeline loaded 17K tokens of includes before even opening the production file, and half were irrelevant to the code type.

Root cause: **skill loads includes BEFORE classification.** The agent doesn't know the code type until AFTER reading the production file. But by then, all includes are already in context.

### Combined impact

| Source | Current tokens | With both fixes | Savings |
|--------|---------------|-----------------|---------|
| Static profile dump | ~34K | 0 (replaced by ~5K dynamic retrieval) | ~29K |
| Irrelevant include sections | ~10-15K per session | ~2-5K (matching sections only) | ~8-12K |
| **Total per session** | **~45-50K waste** | **~5-10K relevant** | **~35-40K** |

**If we do nothing:** every test session wastes ~40K tokens on context the agent doesn't use, and the includes pollute the context window even when cached (the agent still processes them to decide what's relevant).

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

### DD5: Classify FIRST, load includes AFTER — lazy include loading

**Chosen:** Phase 0 loads ONLY `codesift-setup.md` (1 file, ~2K tokens). Then reads the production file, classifies it (code type + complexity + testability). ONLY AFTER classification, loads the matching includes.

**Current (eager):** Load 5 core includes (~17K) → read production file → classify → write tests.
**New (lazy):** Load codesift-setup ONLY (~2K) → read production file → classify → load includes matching code type (~4-12K depending on tier).

**Why not testing.md before classification?** Agent classifies by code structure (imports, branchy, LOC, decorators), not by testing rules. testing.md needed only when writing, not when classifying.

**Rejected:** Loading all includes and instructing agent to "ignore irrelevant sections." Even with cache, irrelevant context pollutes the agent's attention and wastes context window budget. Agent feedback: 3.6% efficiency on a simple service file.

### DD6: Per-code-type include maps — 4 loading tiers

**Chosen:** After classification, the skill loads ONLY the includes that the detected code type needs. 4 tiers:

| Tier | Code types | Includes loaded | ~Tokens |
|------|-----------|----------------|---------|
| **LIGHT** | PURE, VALIDATOR×THIN, STATE-MACHINE×THIN | test-contract (BRANCHES + VALUES sections), quality-gates (Q1-Q19 only) | ~6K |
| **STANDARD** | SERVICE, GUARD, API-CALL, ORM/DB | test-contract (full), quality-gates (Q1-Q19), test-mock-safety, test-edge-cases | ~12K |
| **HEAVY** | CONTROLLER, ORCHESTRATOR, any×COMPLEX | test-contract (full + ORCHESTRATOR variant), quality-gates (Q1-Q19), test-mock-safety, test-edge-cases, test-code-types (matching template) | ~20K |
| **COMPONENT** | COMPONENT, HOOK | test-contract (full), quality-gates (Q1-Q19). Skip mock-safety (component mocks follow different patterns from exemplar). Skip edge-cases (string/number edges rarely apply to render). | ~8K |

vs current: always ~27K regardless of type.

**Why Q1-Q19 only?** quality-gates.md contains CQ1-CQ28 (code quality gates for production code review) AND Q1-Q19 (test quality gates). write-tests uses ONLY Q1-Q19. CQ gates are for `zuvo:review`, `zuvo:code-audit`, and `zuvo:build`. Loading CQ1-CQ28 in write-tests is 60% waste.

**Implementation:** The skill instruction says `Read quality-gates.md from "## Q1-Q19: Test Quality Gates" to end of file`. Agent reads with offset. No file splitting needed — one instruction change.

### DD7: Selective section loading (not file splitting)

**Chosen:** Instruct the agent to read specific sections of shared includes using heading-based navigation, not split files into smaller pieces.

For each include:
- **quality-gates.md:** `Read from "## Q1-Q19" heading to end of file` (skip CQ1-CQ28)
- **test-contract.md:** Full read (all sections needed regardless of type, but contract is used as internal checklist — not printed)
- **test-code-types.md:** `Read only the section matching your classified code type` (e.g., search for "### ORCHESTRATOR" heading, read that section only)
- **test-mock-safety.md:** Full read when loaded (already conditionally loaded per DD6)
- **test-edge-cases.md:** Full read when loaded (already conditionally loaded per DD6)

**Rejected:** Splitting quality-gates.md into quality-gates-cq.md and quality-gates-q.md. Would require updating 10+ skills that reference it. Maintenance overhead > token savings.

**Rejected:** Hardcoded line offsets (`Read from line 88`). Lines shift when files are edited. Fragile.

### DD8: Test contract as internal checklist — don't print

**Chosen:** The test contract (from test-contract.md) is used by the agent as an internal planning checklist. It is NOT printed to the conversation. The user sees only: branch coverage table + test outline + planned test count.

**Why:** Printing the full contract costs ~2K output tokens. User feedback: "ja tego w ogóle nie czytam" (I don't read it at all). The contract's value is in forcing the agent to plan systematically, not in showing the user the plan.

### DD9: Universal pattern — ALL skills, not just write-tests

**Chosen:** Lazy include loading is a universal architectural pattern for all zuvo skills that load shared includes. Every skill that loads includes should follow the same principle: **read input first, classify, then load matching context.**

| Skill | Current eager load | Classify-first signal | Lazy loading opportunity |
|-------|-------------------|----------------------|--------------------------|
| **write-tests** | 5 core + 3 conditional = ~27K | Code type (SERVICE/PURE/COMPONENT/...) + complexity (THIN/STANDARD/COMPLEX) | Load only matching tier: LIGHT ~6K, STANDARD ~12K, HEAVY ~20K, COMPONENT ~8K |
| **build** | test-contract + code-types + edge-cases = ~22K | Task tier (LIGHT vs DEEP) from plan | LIGHT tasks skip edge-cases + code-types. DEEP loads full set |
| **review** | quality-gates + testing + mock-safety = ~25K | Does diff touch tests? What file types in diff? | Skip test includes entirely if diff is prod-only. Load CQ or Q gates per file type |
| **refactor** | ETAP protocol + quality-gates = ~18K | Refactor type: rename, extract, split, inline | Rename needs only symbol search. Extract needs structure analysis. Different includes per type |
| **code-audit** | CQ + Q gates = ~25K | File type + domain (security, data, async) | Conditional CQ gates (CQ16-CQ28) activate only when code context matches. Skip inactive |
| **debug** | quality-gates + testing = ~20K | Bug category: logic, async, data, integration | Logic bugs need CQ gates. Async bugs need CQ15/CQ17. Most don't need test gates |

**Multi-file skills** (review, audit, refactor with multiple targets): per-file lazy loading. When processing file N, check if its type requires an include not yet loaded. If yes, load it. If already loaded from file N-1, skip. This is incremental — includes accumulate across files but never duplicate.

**Implementation approach:** Each skill's SKILL.md gets a restructured Mandatory File Loading section:
```
PHASE 0 — BOOTSTRAP (before reading input):
  1. codesift-setup.md
  [2. skill-specific minimum — e.g., tdd-protocol.md for build]

PHASE 0.5 — CLASSIFY (after reading input, before main work):
  Read input (production file / diff / task spec)
  Classify: type + complexity + domain

PHASE 1 — CONDITIONAL (based on classification):
  Load includes matching classification tier
  [Specific include map per skill — defined in each SKILL.md]

DEFERRED — (at completion):
  run-logger.md, retrospective.md
```

**Scope of this spec:** Define the universal pattern + implement for write-tests (highest token waste, best-measured). Other skills adopt the pattern via individual SKILL.md edits (no separate spec needed — it's the same pattern with skill-specific include maps).

## Solution Overview

Two complementary changes that work together:

### Change A: Lazy include loading (all skills)

Restructure the skill execution order so classification happens BEFORE include loading:

```
BEFORE (eager — current):
  Phase 0: Load 5-8 includes (~17-27K) → Read production file → Classify → Write
  Problem: 60-70% of loaded includes are irrelevant to the code type

AFTER (lazy — new):
  Phase 0: Load codesift-setup ONLY (~2K) → Read production file → Classify
  Phase 0.5: Load includes matching classification (~4-12K)
  Phase 1: Write with relevant context only
```

### Change B: Dynamic CodeSift retrieval (replaces static profile)

```
write-tests Phase 0 (with CodeSift, AFTER classification)
│
├─ Query 1: find_exemplar_test
│  → "Find a test file for a [SERVICE/GUARD/etc.] in this project"
│  → Returns: path to best matching existing test file
│
├─ Query 2: get_import_context (CONDITIONAL — skip if exemplar covers it)
│  → "What does target file import? How are those deps mocked?"
│  → Returns: import list + existing mock patterns
│
├─ Query 3: get_test_setup (CONDITIONAL — skip if CLAUDE.md covers it)
│  → "What setup/helper files does this project's test suite use?"
│  → Returns: setup file paths + key exports
│
└─ Query 4: get_hub_signatures
   → "What utility functions does this file use? Show signatures."
   → Returns: function signatures (L1, not full source)

Total: ~5K tokens of highly relevant, task-specific context
```

### Combined data flow

```
Phase 0 — BOOTSTRAP
  Load codesift-setup.md ONLY
  IF CodeSift available: initialize CodeSift
  Read production file

Phase 0.5 — CLASSIFY
  Classify: code type + complexity + testability
  Print: [FILE] path: TYPE COMPLEXITY TESTABILITY

Phase 0.5 — LOAD (based on classification)
  Determine loading tier: LIGHT / STANDARD / HEAVY / COMPONENT
  Load matching includes (see DD6 tier table)
  IF CodeSift available: run 4 targeted queries (~5K)
  Print: [CONTEXT] Tier: STANDARD, loaded: test-contract, quality-gates Q1-Q19, mock-safety, edge-cases
  Print: [CONTEXT] CodeSift: exemplar={path}, {N} import mocks, {N} signatures

Phase 1+ — WORK
  Proceed with relevant context only (~6-20K vs current ~50K)
```

### Token impact per tier

| Tier | Includes | CodeSift | Total | vs current (~50K) |
|------|----------|----------|-------|--------------------|
| LIGHT | ~4K | ~5K | ~9K | **-82%** |
| STANDARD | ~8K | ~5K | ~13K | **-74%** |
| HEAVY | ~15K | ~5K | ~20K | **-60%** |
| COMPONENT | ~6K | ~5K | ~11K | **-78%** |
| No CodeSift, LIGHT | ~4K | 0 | ~4K | **-92%** |
| No CodeSift, STANDARD | ~8K | 0 | ~8K | **-84%** |

## Detailed Design

### Files Changed

| File | Change |
|------|--------|
| `skills/write-tests/SKILL.md` | Restructure Phase 0: bootstrap → classify → conditional load + 4 CodeSift queries |
| `skills/build/SKILL.md` | Restructure Mandatory File Loading: classify task tier → load matching includes |
| `skills/review/SKILL.md` | Restructure: read diff first → classify file types → load per-type includes |
| `skills/refactor/SKILL.md` | Restructure: read target → classify refactor type → load matching includes |
| `skills/code-audit/SKILL.md` | Restructure: read file → classify domain → activate matching CQ gates |
| `skills/debug/SKILL.md` | Restructure: read error/file → classify bug category → load matching includes |
| `shared/includes/project-profile-protocol.md` | No change (stays for other skills that want full profile) |

### Lazy Include Loading — Universal Pattern

Every skill that loads shared includes adopts this 3-phase structure in Mandatory File Loading:

```markdown
## Mandatory File Loading

PHASE 0 — BOOTSTRAP (load BEFORE reading input):
  1. ../../shared/includes/codesift-setup.md      -- [READ|MISSING -> STOP]
  [2-N. Skill-specific minimum — only files needed to READ and CLASSIFY input]

PHASE 0.5 — CLASSIFY (read input, determine what context is needed):
  Read the input (production file / git diff / task spec / error log)
  Classify: [skill-specific classification dimensions]
  Print: [CLASSIFIED] {classification result}
  Determine loading tier → select include set

PHASE 1 — CONDITIONAL (load based on classification):
  Load includes from the tier's include map (see below)
  Print checklist with READ/SKIP status for each include

DEFERRED — (load at completion, not at start):
  run-logger.md, retrospective.md
```

### write-tests Include Map (by tier)

| Include | LIGHT | STANDARD | HEAVY | COMPONENT |
|---------|-------|----------|-------|-----------|
| codesift-setup.md | Phase 0 | Phase 0 | Phase 0 | Phase 0 |
| test-contract.md | BRANCHES + VALUES sections only | Full | Full + ORCHESTRATOR variant | Full |
| quality-gates.md | Q1-Q19 section only | Q1-Q19 section only | Q1-Q19 section only | Q1-Q19 section only |
| testing.md (rules) | Full | Full | Full | Full |
| test-blocklist.md | Full | Full | Full | Full |
| test-mock-safety.md | **SKIP** (no mocks) | Full | Full | **SKIP** (use exemplar patterns) |
| test-edge-cases.md | **SKIP** (insufficient branching) | Full | Full | **SKIP** (render, not data) |
| test-code-types.md | **SKIP** | Matching section only | Matching section + templates | **SKIP** (use exemplar) |

### Tier assignment rules

```
IF code_type IN (PURE, VALIDATOR) AND complexity == THIN → LIGHT
IF code_type IN (PURE, VALIDATOR) AND complexity == STANDARD → STANDARD (edge-cases needed)
IF code_type IN (STATE-MACHINE) AND complexity == THIN → LIGHT
IF code_type IN (COMPONENT, HOOK) → COMPONENT
IF code_type IN (CONTROLLER, ORCHESTRATOR) → HEAVY
IF complexity == COMPLEX → HEAVY (regardless of code type)
ELSE → STANDARD
```

### build Include Map (by task tier)

| Include | LIGHT task | STANDARD task | DEEP task |
|---------|-----------|---------------|-----------|
| codesift-setup.md | Phase 0 | Phase 0 | Phase 0 |
| tdd-protocol.md | Phase 0 | Phase 0 | Phase 0 |
| quality-gates.md | Q1-Q19 only | Full (CQ + Q) | Full |
| test-contract.md | BRANCHES only | Full | Full |
| test-code-types.md | **SKIP** | Matching section | Full |
| test-edge-cases.md | **SKIP** | Full | Full |
| test-mock-safety.md | **SKIP** | If mocks needed | Full |

### review Include Map (by diff content)

| Include | Prod-only diff | Test-only diff | Mixed diff |
|---------|---------------|----------------|------------|
| codesift-setup.md | Phase 0 | Phase 0 | Phase 0 |
| quality-gates.md | CQ1-CQ28 only | Q1-Q19 only | Full |
| testing.md | **SKIP** | Full | Full |
| test-mock-safety.md | **SKIP** | If test mocks present | If test mocks present |
| security rules | If auth/input code | **SKIP** | If auth/input code |

### Section loading implementation

For selective section loading, the skill instruction tells the agent HOW to read:

```markdown
# quality-gates.md — Q1-Q19 only
Read `quality-gates.md`. Use ONLY the "## Q1-Q19: Test Quality Gates" section
(from that heading to end of file). Ignore CQ1-CQ28 section entirely.

# test-code-types.md — matching section only  
Read `test-code-types.md`. Find the "### {CODE_TYPE}" heading matching your
classification. Read ONLY that section (to the next ### heading). Skip all
other code type sections.

# test-contract.md — BRANCHES + VALUES only (LIGHT tier)
Read `test-contract.md`. Use ONLY sections 1 (BRANCHES), 3 (EXPECTED VALUES),
and 6 (TEST OUTLINE). Skip sections 2, 4, 5 for LIGHT tier.
```

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

**Mandatory File Loading** changes from:

```
PHASE 0 — ALWAYS (load before reading production file):
  1. codesift-setup.md, 2. test-contract.md, 3. test-blocklist.md,
  4. quality-gates.md, 5. testing.md
STEP 1 — AFTER classification:
  6. test-mock-safety.md, 7. test-edge-cases.md, 8. test-code-types.md
```

To:

```
PHASE 0 — BOOTSTRAP (load BEFORE reading production file):
  1. codesift-setup.md                            -- [READ|MISSING -> STOP]

PHASE 0.5 — CLASSIFY (read file, determine tier):
  Read production file fully
  Classify: code type + complexity + testability
  Determine loading tier (LIGHT / STANDARD / HEAVY / COMPONENT)

PHASE 1 — CONDITIONAL (load based on tier):
  2. test-contract.md                             -- [READ sections per tier]
  3. test-blocklist.md                            -- [READ always]
  4. quality-gates.md                             -- [READ Q1-Q19 section ONLY]
  5. testing.md                                   -- [READ always]
  6. test-mock-safety.md                          -- [READ if STANDARD+, SKIP for LIGHT/COMPONENT]
  7. test-edge-cases.md                           -- [READ if STANDARD+, SKIP for LIGHT/COMPONENT]
  8. test-code-types.md                           -- [READ matching section if HEAVY, SKIP otherwise]

DEFERRED:
  9. run-logger.md, 10. retrospective.md          -- [READ at Step 5]
```

**Phase 0 Step 2** changes from static profile to dynamic CodeSift queries (runs AFTER classification, as part of Phase 1):

```
Dynamic context (when CodeSift available, runs after classification):
  D1. Find exemplar test (same code type, same module) → Read as pattern reference
  D2. Get import mocks (CONDITIONAL — skip if D1 covers mock patterns)
  D3. Get test setup (CONDITIONAL — skip if CLAUDE.md covers it)
  D4. Get hub signatures (L1 signatures of imported utilities)
  
  Print: [CONTEXT] Tier: {tier}, exemplar={path}, {N} import mocks, {N} signatures
  If CodeSift unavailable: skip. Print: [CONTEXT] CodeSift unavailable — legacy detection.
```

### What Changes across skills

**Universal changes (all skills with lazy loading):**
1. Mandatory File Loading restructured to 3-phase pattern (bootstrap → classify → conditional)
2. `codesift-setup.md` moves from "one of many Phase 0 files" to "the ONLY Phase 0 file"
3. Each skill defines its own classification dimensions and include map

**write-tests specific:**
4. Static profile loading removed (`Read .zuvo/project-profile.json`)
5. Reference to `project-profile-protocol.md` removed
6. 4 CodeSift retrieval dimensions added (DD3)
7. Test contract used as internal checklist, not printed to conversation (DD8)

**Everything stays unchanged:**
1. `project-profile-protocol.md` — stays in `shared/includes/` (available for skills that want it)
2. SessionStart hook profile summary — stays (low cost, orientation)
3. `analyze_project()` MCP tool — stays (useful for project overview)
4. `.zuvo/project-profile.json` on disk — stays if generated
5. All quality gates, contracts, adversarial review — unchanged (just loaded later)
6. Shared include FILES — no splitting, no restructuring, no new files

### Edge Cases

**Lazy include loading:**

| Edge case | Handling |
|-----------|----------|
| File matches multiple code types (e.g., SERVICE with PURE helpers) | Use the HIGHER tier. SERVICE+PURE → STANDARD (not LIGHT). |
| Classification is ambiguous (e.g., 49 LOC — THIN or STANDARD?) | Default to higher tier. Better to load extra includes than miss needed ones. |
| Multi-file skill (review) processes SERVICE then COMPONENT | When COMPONENT file is reached, mock-safety is already loaded from SERVICE. Skip reload. |
| Barrel/re-export file detected | Expand to sub-modules. Classify each sub-module independently. |
| New code type not in tier table | Default to STANDARD tier. Log warning for skill maintainer. |
| Include file missing (e.g., test-edge-cases.md deleted) | Skip with warning. Degraded mode — don't stop the pipeline. |
| quality-gates.md format changes (Q section moves) | Heading-based search ("## Q1-Q19") is resilient to line changes. Only breaks if heading text changes. |

**Dynamic CodeSift retrieval:**

| Edge case | Handling |
|-----------|----------|
| CodeSift available but no exemplar test found | Skip exemplar, proceed with other queries. Print: `[CONTEXT] No exemplar found — using generic patterns.` |
| Target file has zero imports | Skip D2 and D4. Only exemplar + setup. |
| Very large project (>10K files) | Token budgets on queries cap output. No degradation. |
| Monorepo — target in workspace A, tests in workspace B | CodeSift indexes full repo — cross-workspace queries work. |
| No test files exist anywhere in project | All queries return empty. Legacy behavior. |
| CodeSift index stale | Auto-refreshes via file watcher. Not our problem. |

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

**Lazy include loading (all skills):**
1. write-tests loads ONLY codesift-setup.md before reading the production file (verified by print output)
2. Classification happens BEFORE any other includes are loaded
3. Loading tier is printed: `[CLASSIFIED] {file}: {type} {complexity} → tier {TIER}`
4. Include checklist shows READ/SKIP per file with tier justification
5. build, review, refactor, code-audit, debug SKILL.md files restructured to 3-phase pattern
6. No quality gate regression: Q1-Q19 scores on a fixed 5-file corpus match or exceed baseline

**Dynamic CodeSift retrieval (write-tests):**
7. Phase 0 retrieves context along 4 dimensions (max ~12 MCP calls) when CodeSift available
8. Total retrieval completes in <20s
9. Total retrieved context is <6K tokens
10. Legacy fallback works when CodeSift unavailable (same behavior as pre-change)

### Success criteria (must pass for value)

11. Token cost per write-tests session: reduced by >= 50% vs current (measured by comparing include tokens loaded)
12. First-pass Q score for SERVICE files: median >= 16/19 across 5 runs (no regression)
13. CQ25 (pattern compliance) violations: reduced by >= 30% vs current
14. Exemplar-based tests match project mock patterns without manual correction in >= 70% of cases
15. Token cost per review session: reduced by >= 30% (measured by comparing include tokens loaded)
16. Token cost per build session: reduced by >= 30%

## Validation Methodology

**For AC #1-5 (lazy loading structure):**
Run write-tests on 3 files of different types (PURE, SERVICE, ORCHESTRATOR). Verify from print output:
- Phase 0 loads ONLY codesift-setup.md
- Classification prints BEFORE any include READ
- Include checklist shows correct READ/SKIP per tier
- Repeat for build (1 LIGHT + 1 DEEP task), review (prod-only diff + mixed diff)

**For AC #6 (no quality regression):**
Run write-tests on 5 SERVICE files in tgm-survey-platform (same files, same commit as baseline):
- Record Q self-eval scores
- Compare against baseline scores from current eager-loading runs
- Zero new gate failures (Q7, Q11, Q13, Q15, Q17 critical gates)

**For AC #11 (token cost — write-tests):**
Measure includes loaded (from print output) for a complete write-tests run:
- Current: all includes loaded = ~27K
- New: tier-based loading
- Verify LIGHT ≤ 8K, STANDARD ≤ 15K, HEAVY ≤ 22K, COMPONENT ≤ 12K

**For AC #12 (Q score):**
5 runs on SERVICE files → median Q score >= 16/19

**For AC #13 (CQ25 violations):**
5 runs with lazy loading + CodeSift → count CQ25 violations from adversarial pass 1
Compare against 5 baseline runs → >= 30% fewer violations

**For AC #14 (mock pattern match):**
10 SERVICE files: does generated test use same mock import style as exemplar? Same beforeEach pattern? Same setup helpers? >= 7/10 match.

**For AC #15-16 (token cost — review/build):**
1 review run + 1 build run → measure includes loaded from print output vs current.

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

- Dynamic CodeSift retrieval for build/review/refactor (lazy loading YES, CodeSift queries per-skill NO — that requires skill-specific query design)
- CodeSift-side query optimization (batching, caching)
- Exemplar quality scoring (prefer tests with high Q scores)
- Splitting shared include files (quality-gates-cq.md / quality-gates-q.md) — selective reading is sufficient for now
- Automatic tier detection from git history (e.g., files with frequent test failures → always HEAVY)

### Permanently out of scope

- Static profile expansion (more sections, more data) — research says this is wrong direction
- Embedding-based retrieval (Aider/Cody use structural search, not embeddings, for code)
- Profile generation for projects without CodeSift
- Hardcoded line offsets for section reading (fragile, breaks on edits)

## Open Questions

1. ~~**Batch vs separate calls**~~ **RESOLVED:** 4 separate calls. Allows per-query graceful skip.

2. ~~**Exemplar selection in large projects**~~ **RESOLVED:** CodeSift semantic search with token_budget=2000 caps output.

3. ~~**Split include files vs selective reading**~~ **RESOLVED:** Selective reading via heading-based instructions. No file splitting needed.

4. ~~**Which skills get lazy loading**~~ **RESOLVED:** All skills with shared includes. write-tests first, then build, review, refactor, code-audit, debug.

5. ~~**quality-gates.md CQ section in test skills**~~ **RESOLVED:** Test skills read from "## Q1-Q19" heading only. CQ gates irrelevant for test writing.
