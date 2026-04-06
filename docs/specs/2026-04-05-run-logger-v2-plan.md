# Implementation Plan: Run Logger v2

**Spec:** `docs/specs/2026-04-05-run-logger-v2-spec.md`
**spec_id:** 2026-04-05-run-logger-v2-1845
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-05
**Tasks:** 11
**Estimated complexity:** 9 standard, 2 complex

## Architecture Summary

Four components, strict dependency order:

1. **C1 — `shared/includes/run-logger.md`** — single source of truth for 11-field TSV schema, path resolution, Log-in-Output pattern. Must be completed first.
2. **C2 — 15 existing skills (UPDATE)** — remove trailing `## Run Log` sections, embed `Run:` template in output blocks, add `run-logger.md` to mandatory file loading where missing, standardize VERDICT.
3. **C3 — 22 new skills (ADD)** — add `run-logger.md` to mandatory file loading, add `Run:` template to output blocks (20 of 22 need a new COMPLETE block created).
4. **C4 — retro parser** — combined with C2 retro update. Phase 3 parser handles 9-field and 11-field entries via tab count. Phase 6 Run Log section replaced by Log-in-Output in RETRO COMPLETE block.

Dependency: C1 → (C2 + C3 in parallel) → C4 last.

## Technical Decisions

- **Log-in-Output pattern**: `Run:` line embedded as mandatory field inside each skill's named output block. One-line append instruction follows immediately.
- **TSV 11 fields**: DATE, SKILL, PROJECT, CQ_SCORE, Q_SCORE, VERDICT, TASKS, DURATION, NOTES, BRANCH, HEAD_SHA7. Fields 10-11 appended for backward compat.
- **Path format**: match existing style per file (`{plugin_root}/...` or `../../...`).
- **VERDICT vocab**: PASS, WARN, FAIL, BLOCKED, ABORTED only. Canary maps HEALTHY→PASS, DEGRADED→WARN, BROKEN→FAIL. Security-audit maps HEALTHY→PASS, NEEDS ATTENTION→WARN, AT RISK/CRITICAL→FAIL. Deploy maps PARTIAL→WARN.
- **Skills needing new COMPLETE blocks**: 20 of 22 C3 skills (only write-tests and write-e2e already have them).

## Quality Strategy

- **No test runner** — this is a markdown-only plugin. Verification via grep/diff shell commands.
- **TDD adapted**: RED = verification command that currently fails, GREEN = edit, Verify = run command.
- **Risk areas**: retro (dual writer/reader, two output block variants), review (844 lines, 3 completion contexts), refactor (765 lines, 2 completion blocks).
- **Final verification**: bash script checking all 7 ACs via grep.
- **AC3 count check**: use tight grep pattern `run-logger.md` in SKILL.md to avoid false positives.

## Task Breakdown

### Task 1: Rewrite run-logger.md with 11-field schema and Log-in-Output pattern
**Files:** `shared/includes/run-logger.md`
**Complexity:** standard
**Dependencies:** none

- [ ] RED: `grep -c "HEAD_SHA7" shared/includes/run-logger.md` returns 0 (field doesn't exist yet)
- [ ] GREEN: Rewrite `shared/includes/run-logger.md`:
  - Replace 9-field schema table with 11-field schema (add BRANCH at position 10, HEAD_SHA7 at position 11)
  - Update path resolution bash block: add `|| ! test -w ~/.zuvo` to the write-check condition
  - Change PROJECT resolution from `basename "$(pwd)"` to `basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"`
  - Add BRANCH resolution: `git branch --show-current 2>/dev/null || echo "-"`
  - Add HEAD_SHA7 resolution: `git rev-parse --short HEAD 2>/dev/null || echo "-"`
  - Add new section "Log-in-Output Pattern" documenting the `Run:` line approach with a concrete example
  - Remove old "How to Log" prose instructions about appending per format
  - Keep "When to Log", "What NOT to Log", and "Reading the Log" sections (update examples for 11 fields)
- [ ] Verify: `grep -c "HEAD_SHA7" shared/includes/run-logger.md && grep -c "test -w" shared/includes/run-logger.md && grep -c "git rev-parse --show-toplevel" shared/includes/run-logger.md`
  Expected: each returns 1+
- [ ] Acceptance: AC1, AC2, AC7
- [ ] Commit: `feat: rewrite run-logger.md with 11-field schema, path fix, and Log-in-Output pattern`

---

### Task 2: Update pipeline skills (brainstorm, plan, execute)
**Files:** `skills/brainstorm/SKILL.md`, `skills/plan/SKILL.md`, `skills/execute/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: `grep -c "run-logger.md" skills/brainstorm/SKILL.md` returns 0 (not in mandatory loading)
- [ ] GREEN: For each of brainstorm, plan, execute:
  1. Add `run-logger.md` to mandatory file loading checklist (match existing path format in file)
  2. Find the named output block (BRAINSTORM COMPLETE / plan output / EXECUTION COMPLETE)
  3. Insert `Run:` template line inside the output block:
     - brainstorm: `Run: <ISO-8601-Z>\tbrainstorm\t<project>\t-\t-\t<VERDICT>\t-\t3-phase\t<NOTES>\t<BRANCH>\t<SHA7>`
     - plan: `Run: <ISO-8601-Z>\tplan\t<project>\t-\t-\t<VERDICT>\t<TASKS>\t3-phase\t<NOTES>\t<BRANCH>\t<SHA7>`
     - execute: `Run: <ISO-8601-Z>\texecute\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<N>-tasks\t<NOTES>\t<BRANCH>\t<SHA7>`
  4. Add one-line append instruction after the `Run:` line
  5. Remove the trailing `## Run Log` section from each file
- [ ] Verify: `grep -rn "^## Run Log$" skills/brainstorm/SKILL.md skills/plan/SKILL.md skills/execute/SKILL.md | wc -l` returns 0; `grep -l "run-logger.md" skills/brainstorm/SKILL.md skills/plan/SKILL.md skills/execute/SKILL.md | wc -l` returns 3
  Expected: 0 trailing sections, 3 files reference run-logger.md
- [ ] Acceptance: AC3, AC5 (partial)
- [ ] Commit: `feat: embed Run: log template in pipeline skills (brainstorm, plan, execute)`

---

### Task 3: Add logging to 9 new audit skills (batch)
**Files:** `skills/api-audit/SKILL.md`, `skills/ci-audit/SKILL.md`, `skills/db-audit/SKILL.md`, `skills/dependency-audit/SKILL.md`, `skills/env-audit/SKILL.md`, `skills/performance-audit/SKILL.md`, `skills/pentest/SKILL.md`, `skills/seo-audit/SKILL.md`, `skills/structure-audit/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: `grep -rl "run-logger.md" skills/api-audit/SKILL.md` returns nothing
- [ ] GREEN: For each of the 9 audit skills:
  1. Add `run-logger.md` to mandatory file loading checklist
  2. Find or create the named output block (e.g., `## API-AUDIT COMPLETE`). Most audit skills save a report file but don't have a printed completion block — add one at the end of the final phase.
  3. Insert audit category `Run:` template:
     `Run: <ISO-8601-Z>\t<skill-name>\t<project>\t<N-critical>\t<N-total>\t<VERDICT>\t-\t<N>-dimensions\t<NOTES>\t<BRANCH>\t<SHA7>`
  4. Add VERDICT mapping note: 0 critical = PASS, 1-3 = WARN, 4+ = FAIL
  5. Add one-line append instruction
- [ ] Verify: `for s in api-audit ci-audit db-audit dependency-audit env-audit performance-audit pentest seo-audit structure-audit; do grep -l "run-logger.md" skills/$s/SKILL.md; done | wc -l`
  Expected: 9
- [ ] Acceptance: AC3, AC4 (partial)
- [ ] Commit: `feat: add Run: log template to 9 audit skills`

---

### Task 4: Update 3 existing audit skills (code-audit, security-audit, test-audit)
**Files:** `skills/code-audit/SKILL.md`, `skills/security-audit/SKILL.md`, `skills/test-audit/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: `grep -c "^## Run Log$" skills/code-audit/SKILL.md` returns 1 (trailing section exists)
- [ ] GREEN: For each of code-audit, security-audit, test-audit:
  1. Add `run-logger.md` to mandatory file loading (if not already there)
  2. Find the named output block
  3. Insert category-specific `Run:` template:
     - code-audit + test-audit: audit template (`<N-critical>`, `<N-total>`, VERDICT by critical count)
     - security-audit (special): `Run: <ISO-8601-Z>\tsecurity-audit\t<project>\t-\t-\t<VERDICT>\t-\t<N>-dimensions\t<NOTES>\t<BRANCH>\t<SHA7>` with VERDICT mapping: HEALTHY→PASS, NEEDS ATTENTION→WARN, AT RISK/CRITICAL→FAIL
  4. Add append instruction
  5. Remove trailing `## Run Log` section
- [ ] Verify: `grep -rn "^## Run Log$" skills/code-audit/SKILL.md skills/security-audit/SKILL.md skills/test-audit/SKILL.md | wc -l` returns 0
  Expected: 0
- [ ] Acceptance: AC3, AC4, AC5 (partial)
- [ ] Commit: `feat: migrate Run: log template in code-audit, security-audit, test-audit`

---

### Task 5: Update core skills (build, debug)
**Files:** `skills/build/SKILL.md`, `skills/debug/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: `grep -c "^## Run Log$" skills/build/SKILL.md` returns 1
- [ ] GREEN: For build and debug:
  1. Add `run-logger.md` to mandatory file loading
  2. Find the BUILD COMPLETE / DEBUG COMPLETE output block
  3. Insert core template: `Run: <ISO-8601-Z>\tbuild\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>`
  4. Preserve build's tier-specific DURATION values (light/standard/deep) and CQ_SCORE mapping (critical-only for LIGHT)
  5. Add append instruction
  6. Remove trailing `## Run Log` section
- [ ] Verify: `grep -rn "^## Run Log$" skills/build/SKILL.md skills/debug/SKILL.md | wc -l` returns 0; `grep -c "run-logger.md" skills/build/SKILL.md` returns 1+
  Expected: 0 trailing, both reference run-logger
- [ ] Acceptance: AC3, AC5 (partial)
- [ ] Commit: `feat: migrate Run: log template in build and debug skills`

---

### Task 6: Update refactor skill
**Files:** `skills/refactor/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: `grep -c "^### Run Log$" skills/refactor/SKILL.md` returns 1 (has ### not ## heading)
- [ ] GREEN:
  1. Add `run-logger.md` to mandatory file loading (if not already there — refactor references it but may not load it)
  2. Find REFACTORING COMPLETE output block (~line 561) — insert core `Run:` template
  3. Find BATCH COMPLETE block (~line 701) — insert same `Run:` template (batch refactors should also log)
  4. Preserve refactor-specific DURATION values (etap labels)
  5. Add append instruction after each `Run:` line
  6. Remove the `### Run Log` trailing section
  7. Remove the reference to `run-logger.md § Environment-Aware Log Path` in the old section
- [ ] Verify: `grep -rn "Run Log" skills/refactor/SKILL.md | wc -l` returns 0; `grep -c "Run:.*refactor" skills/refactor/SKILL.md` returns 2 (one per completion block)
  Expected: 0 trailing section references, 2 Run: templates
- [ ] Acceptance: AC3, AC5 (partial)
- [ ] Commit: `feat: migrate Run: log template in refactor skill (single + batch modes)`

---

### Task 7: Add logging to 4 test skills + 9 utility skills (batch)
**Files:** `skills/fix-tests/SKILL.md`, `skills/tests-performance/SKILL.md`, `skills/write-e2e/SKILL.md`, `skills/write-tests/SKILL.md`, `skills/architecture/SKILL.md`, `skills/backlog/SKILL.md`, `skills/design/SKILL.md`, `skills/design-review/SKILL.md`, `skills/docs/SKILL.md`, `skills/presentation/SKILL.md`, `skills/receive-review/SKILL.md`, `skills/seo-fix/SKILL.md`, `skills/ui-design-team/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: `grep -rl "run-logger.md" skills/write-tests/SKILL.md skills/docs/SKILL.md` returns nothing
- [ ] GREEN: For each of the 13 skills:
  1. Add `run-logger.md` to mandatory file loading checklist
  2. Find or create the named output block:
     - write-tests: has WRITE-TESTS COMPLETE — insert inside it
     - write-e2e: has or needs WRITE-E2E COMPLETE
     - fix-tests, tests-performance: need new COMPLETE blocks
     - architecture, backlog, design, design-review, docs, presentation, receive-review, seo-fix, ui-design-team: need new COMPLETE blocks
  3. Insert category-specific `Run:` template:
     - Test skills: `Run: <ISO-8601-Z>\t<skill>\t<project>\t-\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>`
     - Utility skills: `Run: <ISO-8601-Z>\t<skill>\t<project>\t-\t-\t<VERDICT>\t-\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>`
  4. Add append instruction
- [ ] Verify: `for s in fix-tests tests-performance write-e2e write-tests architecture backlog design design-review docs presentation receive-review seo-fix ui-design-team; do grep -l "run-logger.md" skills/$s/SKILL.md; done | wc -l`
  Expected: 13
- [ ] Acceptance: AC3 (partial)
- [ ] Commit: `feat: add Run: log template to test and utility skills (13 files)`

---

### Task 8: Update release skills (ship, deploy, release-docs, canary)
**Files:** `skills/ship/SKILL.md`, `skills/deploy/SKILL.md`, `skills/release-docs/SKILL.md`, `skills/canary/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1

- [ ] RED: `grep -c "HEALTHY\|DEGRADED\|BROKEN" skills/canary/SKILL.md` returns matches (non-standard verdicts in run-log context)
- [ ] GREEN: For each of ship, deploy, release-docs, canary:
  1. Verify `run-logger.md` is already in mandatory file loading (all 4 should have it). If not, add it.
  2. Find the named output block (SHIP COMPLETE, DEPLOY COMPLETE, etc.)
  3. Insert release-category `Run:` template with 11 fields:
     - ship: `Run: <ISO-8601-Z>\tship\t<project>\t-\t-\t<VERDICT>\t-\t5-phase\t<NOTES>\t<BRANCH>\t<SHA7>`
     - deploy: same pattern, `7-phase`, VERDICT mapping: PARTIAL→WARN
     - release-docs: same pattern, `5-phase`
     - canary: `Run: <ISO-8601-Z>\tcanary\t<project>\t-\t-\t<VERDICT>\t-\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>` with VERDICT mapping note: HEALTHY→PASS, DEGRADED→WARN, BROKEN→FAIL. DURATION = monitoring duration (e.g., `10m`)
  4. Add append instruction
  5. Remove trailing Run Log sections (ship and deploy have inline TSV templates in their existing sections — remove those too)
  6. For canary: ensure the VERDICT mapping note is near the `Run:` template so the LLM uses PASS/WARN/FAIL, not HEALTHY/DEGRADED/BROKEN
- [ ] Verify: `grep -rn "^## Run Log$\|^### Run Log$\|^### 2. Run logger$" skills/ship/SKILL.md skills/deploy/SKILL.md skills/release-docs/SKILL.md skills/canary/SKILL.md | wc -l` returns 0
  Expected: 0
- [ ] Acceptance: AC3, AC4, AC5 (partial)
- [ ] Commit: `feat: migrate Run: log template in release skills (ship, deploy, release-docs, canary)`

---

### Task 9: Update review skill
**Files:** `skills/review/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: `grep -c "^## Run Log$" skills/review/SKILL.md` returns 1
- [ ] GREEN:
  1. Add `run-logger.md` to mandatory file loading checklist
  2. Find the primary REVIEW COMPLETE output block — insert `Run:` template:
     `Run: <ISO-8601-Z>\treview\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>`
  3. **Do NOT add `Run:` to batch mode or utility mode** completion blocks (tag, mark-reviewed, status) — these are not full skill executions
  4. Add append instruction
  5. Remove the trailing `## Run Log` section (~line 835)
  6. Standardize VERDICT: review uses `BLOCK` in some contexts — ensure template says `BLOCKED` not `BLOCK`
- [ ] Verify: `grep -c "^## Run Log$" skills/review/SKILL.md` returns 0; `grep -c "Run:.*review" skills/review/SKILL.md` returns 1
  Expected: 0 trailing, 1 Run: template in primary completion block only
- [ ] Acceptance: AC3, AC4, AC5 (partial)
- [ ] Commit: `feat: migrate Run: log template in review skill (primary completion only)`

---

### Task 10: Update retro skill (writer + parser)
**Files:** `skills/retro/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1
**Execution routing:** deep implementation tier

- [ ] RED: `grep -c "^## Phase 6" skills/retro/SKILL.md` returns 1 (Phase 6 Run Log section still exists)
- [ ] GREEN:
  1. **Phase 3 parser update**: Find the runs.log reading/parsing section. Update instructions:
     - Parse each line by splitting on tabs
     - Lines with 10 tab characters (11 fields): populate all fields including BRANCH (field 10) and HEAD_SHA7 (field 11)
     - Lines with 8 tab characters (9 fields): treat BRANCH and HEAD_SHA7 as `-`
     - Lines that don't match either pattern (e.g., pipe-delimited legacy): skip silently
     - DATE parsing: handle both `T...Z` and `T...` formats as UTC
  2. **Quality Trends update**: After the existing CQ/Q/pass-fail aggregation, add:
     - `Branch distribution:` line showing count per branch (e.g., `main: 8, feature/x: 2`)
     - Only display when at least one 11-field entry exists in the filtered window
  3. **Phase 6 removal**: Delete the standalone `## Phase 6: Run Log` section
  4. **RETRO COMPLETE output block**: Find both RETRO COMPLETE variants (normal and E13 qualitative-only). Insert `Run:` template in each:
     `Run: <ISO-8601-Z>\tretro\t<project>\t-\t-\t<VERDICT>\t-\t6-phase\t<NOTES>\t<BRANCH>\t<SHA7>`
  5. Add append instruction after each `Run:` line
- [ ] Verify: `grep -c "^## Phase 6" skills/retro/SKILL.md` returns 0; `grep -c "Run:.*retro" skills/retro/SKILL.md` returns 2 (one per COMPLETE variant); `grep -c "HEAD_SHA7\|BRANCH\|tab" skills/retro/SKILL.md` returns 3+ (parser references)
  Expected: Phase 6 gone, 2 Run: templates, parser mentions new fields
- [ ] Acceptance: AC3, AC5, AC6
- [ ] Commit: `feat: update retro parser for 11-field schema + migrate Run: log to output blocks`

---

### Task 11: Final verification sweep
**Files:** none (read-only verification)
**Complexity:** standard
**Dependencies:** Tasks 1-10

- [ ] RED: `grep -rl "^## Run Log$" skills/ --include="SKILL.md" | wc -l` returns >0 (some trailing sections still exist before all tasks done)
- [ ] GREEN: Run the full verification script (below). Fix any failures found.
- [ ] Verify:
  ```bash
  # AC1: 11-field schema
  grep -c "HEAD_SHA7" shared/includes/run-logger.md  # expect 1+

  # AC2: Path fix
  grep -c "test -w" shared/includes/run-logger.md  # expect 1+
  grep -c "git rev-parse --show-toplevel" shared/includes/run-logger.md  # expect 1+

  # AC3: 37 skills reference run-logger.md
  grep -rl "run-logger.md" skills/ --include="SKILL.md" | grep -v "using-zuvo\|worktree" | wc -l  # expect 37

  # AC4: No non-standard VERDICT in Run: lines
  grep -rn "Run:.*HEALTHY\|Run:.*DEGRADED\|Run:.*BROKEN\|Run:.*AT RISK\|Run:.*NEEDS ATTENTION" skills/ --include="SKILL.md" | wc -l  # expect 0

  # AC5: No trailing Run Log sections
  grep -rl "^## Run Log$\|^### Run Log$" skills/ --include="SKILL.md" | wc -l  # expect 0

  # AC6: Retro Phase 6 removed, Run: present, parser updated
  grep -c "^## Phase 6" skills/retro/SKILL.md  # expect 0
  grep -c "Run:.*retro" skills/retro/SKILL.md  # expect 2

  # AC7: Field order preserved
  grep -c "DATE.*SKILL.*PROJECT.*CQ_SCORE.*Q_SCORE.*VERDICT.*TASKS.*DURATION.*NOTES" shared/includes/run-logger.md  # expect 1+
  ```
  Expected: all checks pass
- [ ] Acceptance: AC1-AC7 (full coverage)
- [ ] Commit: `chore: verify all run-logger v2 acceptance criteria pass`
