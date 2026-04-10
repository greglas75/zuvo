# Implementation Plan: Dynamic Test Context

**Spec:** docs/specs/2026-04-10-dynamic-test-context-spec.md
**spec_id:** 2026-04-10-dynamic-test-context-1430
**planning_mode:** spec-driven
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-10
**Tasks:** 4
**Estimated complexity:** 4 standard (1 spike + 2 markdown changes + 1 validation)

## Architecture Summary

Single-file change: `skills/write-tests/SKILL.md`. Phase 0 Step 2 replaces static profile loading with 4 CodeSift retrieval dimensions. All other skill steps unchanged. No new files, no new tools, no code.

## Technical Decisions

- Use existing CodeSift MCP tools (already available in Phase 0 via `codesift-setup.md`)
- 4 separate calls (not batch) — allows per-query graceful skip
- Cap Query 2 at 5 dependencies
- Total token budget: ~5K across all 4 dimensions
- Legacy fallback: if CodeSift unavailable, skip enrichment entirely

## Quality Strategy

- No TDD (markdown skill file, not code)
- Verification: manual run on SERVICE file, check `[CONTEXT]` output
- Acceptance: AC #7-10 measured empirically on tgm-survey-platform
- Risk: exemplar selection quality — mitigated by selection heuristic (same dir > same type > any)

## Task Breakdown

---

### Task 1: Spike — validate 4 CodeSift queries on real SERVICE file
**Files:** none (manual exploration in tgm-survey-platform)
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: N/A (spike — exploration, not code)
- [ ] GREEN: In a Claude Code session on tgm-survey-platform, manually run the 4 CodeSift queries for `apps/api/src/modules/organization/organization.service.ts`:
  1. `codebase_retrieval(token_budget=2000, queries=[{type: "semantic", query: "test for SERVICE organization"}])` → Does it find an exemplar test?
  2. `find_references("<main_export>")` + `search_text(query: "vi.mock.*organization", file_pattern: "*.test.*")` → Does it find mock patterns?
  3. `search_text(query: "beforeAll|globalSetup|setupFiles", file_pattern: "vitest.config.*|setup.*")` → Does it find setup files?
  4. `assemble_context(query: "organization service imports", level: "L1", token_budget: 1000)` → Does it return useful signatures?
  Record: total latency, total tokens retrieved, quality of results (relevant or noise?).
- [ ] Verify: All 4 queries return non-empty results. Total latency <20s. Total tokens <6K. Results are relevant (not random files).
  Expected: Exemplar test found, mock patterns found, setup file found, signatures returned.
- [ ] Acceptance: Validates feasibility of AC #1, #2, #3 before writing skill changes.
- [ ] Commit: N/A (spike only — no code changes)

**Gate:** If spike fails (queries return garbage, latency >30s, or CodeSift can't find relevant tests), STOP. Revisit query design before proceeding.

---

### Task 2: Replace static profile loading with dynamic retrieval instructions
**Files:** `skills/write-tests/SKILL.md` (modify)
**Complexity:** standard
**Dependencies:** Task 1 (spike must pass gate)
**Execution routing:** default

- [ ] RED: N/A (markdown change — no TDD)
- [ ] GREEN: Modify Phase 0 Step 2 in `skills/write-tests/SKILL.md`:
  - Remove: static profile loading (`Read .zuvo/project-profile.json with offset=0 limit=50`)
  - Remove: profile consumption instructions (the `IF profile.conventions...` block)
  - Remove: `project-profile-protocol.md` from Mandatory File Loading checklist (item 8)
  - Add: 4 retrieval dimensions with CodeSift queries:
    - **Dimension 1 — Exemplar test:** `codebase_retrieval(repo, token_budget=2000, queries=[{type: "semantic", query: "test for [code_type] in [module]"}, {type: "text", query: "describe.*[code_type]", file_pattern: "*.test.*"}])`. Select best match by: same directory > same code type > any test. Read the exemplar file as pattern reference.
    - **Dimension 2 — Import context:** `find_references(repo, "<main_export>")` + `trace_call_chain(repo, "<main_export>", direction: "callees", depth: 1)`. Then for at most 5 dependencies: `search_text(repo, query: "vi.mock.*<dep_path>", file_pattern: "*.test.*", top_k: 3)`.
    - **Dimension 3 — Test setup:** `search_text(repo, query: "beforeAll|globalSetup|setupFiles", file_pattern: "vitest.config.*|jest.config.*|setup.*")` + `get_file_outline(repo, file_path: "<setup_file>")`.
    - **Dimension 4 — Hub signatures:** `assemble_context(repo, query: "<imports>", level: "L1", token_budget: 1000)`.
  - Add: console output `[CONTEXT] Loaded: exemplar={path}, {N} import mocks, {N} setup helpers, {N} utility signatures`
  - Add: fallback `If CodeSift unavailable: skip to Step 3 (legacy stack detection).`
  - Add: error handling per query: `catch timeout/error → print [CONTEXT] Query N timed out — skipping {dimension}. → continue`
- [ ] Verify: `grep -c "Dimension" skills/write-tests/SKILL.md && grep -c "\[CONTEXT\]" skills/write-tests/SKILL.md`
  Expected: Dimension count >= 4, [CONTEXT] count >= 3
- [ ] Acceptance: AC #1 (4 retrieval dimensions), AC #3 (<6K tokens), AC #6 (no new mandatory files)
- [ ] Commit: `feat: replace static profile with per-task CodeSift retrieval in write-tests Phase 0`

---

### Task 3: Update Step 1 (Analyze) to use retrieved context
**Files:** `skills/write-tests/SKILL.md` (modify)
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: N/A (markdown change)
- [ ] GREEN: Modify Step 1 (Analyze) in `skills/write-tests/SKILL.md`:
  - Replace: `If project profile loaded in Phase 0: Check file_classifications...` block
  - With: `If exemplar test loaded in Phase 0: Use it as pattern reference for mock style, describe/it structure, import conventions, and setup patterns. If import context loaded: Use discovered mock patterns for MOCK INVENTORY in test contract. If hub signatures loaded: Reference utility function signatures when planning assertions.`
  - Add to test contract section (Step 2): `If exemplar test is available, use its patterns for MOCK INVENTORY section. Copy mock import paths from exemplar, not from memory.`
- [ ] Verify: `grep -c "exemplar" skills/write-tests/SKILL.md`
  Expected: >= 3 references to exemplar
- [ ] Acceptance: AC #10 (mock pattern match >= 70%)
- [ ] Commit: `feat: wire dynamic context into test analysis and contract steps`

---

### Task 4: E2E validation on SERVICE file
**Files:** none (validation only)
**Complexity:** standard
**Dependencies:** Tasks 2, 3
**Execution routing:** default

- [ ] RED: N/A (validation)
- [ ] GREEN: Execute the full pipeline:
  1. Install updated skill: `./scripts/install.sh`
  2. Restart Claude Code
  3. In tgm-survey-platform, run: `/zuvo:write-tests` on a SERVICE file (e.g., `apps/api/src/modules/organization/organization.service.ts`)
  4. Verify output contains `[CONTEXT] Loaded: exemplar=...`
  5. Verify generated test uses mock patterns from project (not generic patterns)
  6. Check token usage — should be lower than previous runs with static profile
- [ ] Verify: Visual inspection of skill output for `[CONTEXT]` line and exemplar-based patterns
  Expected: `[CONTEXT] Loaded: exemplar={some_test_path}, {N} import mocks, {N} setup helpers, {N} utility signatures`
- [ ] Acceptance: AC #2 (<20s total), AC #4 (legacy fallback), AC #5 (no new gate failures), AC #7 (Q >= 16/19), AC #8 (CQ25 -30%), AC #9 (tokens -40%), AC #10 (mock match >= 70%)
- [ ] Commit: N/A (validation only)

---

## Dependency Graph

```
Task 1 (spike) ──GATE──→ Task 2 (Phase 0 rewrite) ←── Task 3 (Step 1 update) ←── Task 4 (E2E validation)
```

Task 1 is a go/no-go gate. If spike fails, revisit query design.

## Acceptance Criteria Coverage

| Spec AC | Task(s) |
|---------|---------|
| AC #1 (4 retrieval dimensions) | Task 1 (spike), Task 2 |
| AC #2 (<20s total) | Task 1 (spike), Task 4 |
| AC #3 (<6K tokens) | Task 1 (spike), Task 2 |
| AC #4 (legacy fallback) | Task 2, Task 4 |
| AC #5 (no new gate failures) | Task 4 |
| AC #6 (no new mandatory files) | Task 2 |
| AC #7 (Q >= 16/19) | Task 4 |
| AC #8 (CQ25 -30%) | Task 4 |
| AC #9 (tokens -40%) | Task 4 |
| AC #10 (mock match >= 70%) | Task 3, Task 4 |

## Notes

- Task 1 is a spike — run manually in Claude Code with CodeSift. If queries don't return useful results, STOP and redesign before touching the skill file.
- Tasks 2 and 3 are markdown edits to `skills/write-tests/SKILL.md` — no TDD, no code compilation.
- Task 4 requires a live Claude Code session with CodeSift in tgm-survey-platform. Cannot be automated.
- The spec's `project-profile-protocol.md` stays in shared/includes — just removed from write-tests mandatory file loading.
