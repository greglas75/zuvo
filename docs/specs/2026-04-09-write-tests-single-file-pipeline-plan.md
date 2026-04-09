# Implementation Plan: write-tests Single-File Pipeline

**Spec:** docs/specs/2026-04-09-write-tests-single-file-pipeline-spec.md
**spec_id:** 2026-04-09-write-tests-single-file-1412
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-09
**Tasks:** 9
**Estimated complexity:** 7 standard, 2 complex

## Architecture Summary

All changes are markdown files (no production code). The rewrite touches:
- 1 skill file: `skills/write-tests/SKILL.md` (rewrite from 532 to ≤250 lines)
- 5 new shared includes (4 extracted from skill + 1 Q-scoring protocol extracted from execute agent)
- 1 new agent file: `skills/write-tests/agents/test-quality-reviewer.md`
- 1 updated agent: `skills/execute/agents/quality-reviewer.md` (reference shared include instead of inline)
- Build scripts already handle `shared/includes/` copying — no build changes needed

Dependency direction: SKILL.md → shared includes (read references). Agent → shared include. No circular deps.

## Technical Decisions

- **No TDD** — this is a markdown skill plugin, not production code. Verification is via build validation scripts.
- **Extract-then-rewrite** — create shared includes first (Tasks 1-5), then rewrite SKILL.md (Task 6) referencing them. This avoids broken references.
- **Preserve content** — extracted includes keep the exact content from current SKILL.md, except `test-edge-cases.md` which restructures the single paragraph into a table for clarity.
- **Note:** `shared/includes/test-contract.md` already exists (115 lines). No need to create it — Task 6 references it directly.
- **Coverage Scanner replaced by CodeSift** — instead of a sub-agent, Phase 0 uses direct CodeSift calls: `find_dead_code`, `classify_roles`, `analyze_hotspots`, `find_references(symbol_names, file_pattern="*.test.*")`. Zero agent overhead, more precise.
- **Q-scoring extracted to shared include** — `execute/agents/quality-reviewer.md` Part 2 (Q1-Q19 scoring + evidence rules + N/A abuse + output format + guardrails) extracted to `shared/includes/q-scoring-protocol.md`. Reusable by write-tests, fix-tests, write-e2e, build, and any future skill that evaluates test quality.

## Quality Strategy

- Each shared include is self-contained and validated by the existing build scripts
- SKILL.md line count verified ≤250 (AC #4)
- Full build (`install.sh`) validates no broken references, no residual `{plugin_root}`, no CC-specific tool names
- Adversarial review on final SKILL.md validates structural correctness

## Task Breakdown

### Task 1: Extract test-code-types.md
**Files:** `shared/includes/test-code-types.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Create `shared/includes/test-code-types.md` with the 11 code-type classification table from current SKILL.md lines 215-236 (Code-Type Gate section). Include: detection signals, min test formulas, mixed file handling, PURE_EXTRACTABLE detection.
- [ ] Verify: `wc -l shared/includes/test-code-types.md` — expect 35-50 lines
- [ ] Commit: `extract: test-code-types.md from write-tests skill`

### Task 2: Extract test-blocklist.md
**Files:** `shared/includes/test-blocklist.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Create `shared/includes/test-blocklist.md` with the blocked patterns table from current SKILL.md lines 367-379. Include the 7-row table with Blocked Pattern, Why, Do Instead columns.
- [ ] Verify: `wc -l shared/includes/test-blocklist.md` — expect 20-30 lines
- [ ] Commit: `extract: test-blocklist.md from write-tests skill`

### Task 3: Extract test-mock-safety.md
**Files:** `shared/includes/test-mock-safety.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Create `shared/includes/test-mock-safety.md` with mock safety rules from current SKILL.md lines 390-397. Include all 6 rules (toHaveBeenCalledWith, no `as any`, reset in beforeEach, async generators, streams, external services).
- [ ] Verify: `wc -l shared/includes/test-mock-safety.md` — expect 15-25 lines
- [ ] Commit: `extract: test-mock-safety.md from write-tests skill`

### Task 4: Extract test-edge-cases.md
**Files:** `shared/includes/test-edge-cases.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Create `shared/includes/test-edge-cases.md` with edge case checklist from current SKILL.md lines 399-403. Restructure the single paragraph into a table: parameter type → edge cases to test.
- [ ] Verify: `wc -l shared/includes/test-edge-cases.md` — expect 20-35 lines
- [ ] Commit: `extract: test-edge-cases.md from write-tests skill`

### Task 5: Extract q-scoring-protocol.md + create test-quality-reviewer agent
**Files:** `shared/includes/q-scoring-protocol.md`, `skills/write-tests/agents/test-quality-reviewer.md`
**Complexity:** complex
**Dependencies:** none

Two sub-tasks:

**5a: Extract Q-scoring protocol from execute/quality-reviewer.md**
- [ ] Create `shared/includes/q-scoring-protocol.md` by extracting from `skills/execute/agents/quality-reviewer.md`:
  - Part 2: Q1-Q19 scoring rules with evidence requirements ("No evidence = score 0")
  - N/A abuse check (>60% N/A = flag)
  - Output format (Q scorecard with evidence per gate, critical gates list)
  - Guardrails (do not score without evidence, do not use N/A to avoid hard evaluation)
- [ ] Update `skills/execute/agents/quality-reviewer.md` to reference `../../shared/includes/q-scoring-protocol.md` for Part 2 instead of inline content. Keep Part 1 (CQ1-CQ28) and Part 3 (file limits) inline — those are execute-specific.
- [ ] Verify: `wc -l shared/includes/q-scoring-protocol.md` — expect 50-70 lines

**5b: Create test-quality-reviewer agent**
- [ ] Create `skills/write-tests/agents/test-quality-reviewer.md` (~40 lines):
  - Frontmatter: name, description, model: sonnet, tools: [Read, Grep, Glob]
  - "What You Receive": production file, test file, test contract
  - "Your Job": load `../../shared/includes/q-scoring-protocol.md`, evaluate Q1-Q19 with evidence
  - CodeSift instructions (get_file_outline, get_symbol) with Grep/Read fallback
  - Final verdict: Q score, critical gates, PASS/FAIL
  - "Must NOT": modify files, skip gates, score without evidence
- [ ] Verify: agent has frontmatter with name, description, model, tools
- [ ] Commit: `extract: q-scoring-protocol.md + add test-quality-reviewer agent`

### Task 6: Rewrite write-tests SKILL.md
**Files:** `skills/write-tests/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3, Task 4, Task 5

This is the core task. Rewrite the entire SKILL.md from 532 lines to ≤250, implementing the single-file pipeline from the spec.

- [ ] Rewrite `skills/write-tests/SKILL.md` with:
  - **Header:** frontmatter, scope, argument parsing, mode table (~25 lines)
  - **Mandatory File Loading:** checklist referencing new + existing includes (~15 lines)
  - **Phase 0: Setup** (~35 lines):
    - Knowledge prime (stack, test runner, existing patterns)
    - Baseline test run
    - Build queue:
      - Explicit mode: queue = user's target files
      - Auto mode: CodeSift discovery pipeline:
        ```
        classify_roles(repo) → find dead/leaf symbols
        analyze_hotspots(repo, since_days=90) → prioritize by churn
        find_references(repo, symbol_names=[exports], file_pattern="*.test.*") → find 0-ref = untested
        ```
        Fallback (no CodeSift): Glob + Grep for test files matching production files
  - **Per-File Loop:** Steps 1-5 (~80 lines total):
    - Step 1: Analyze (~20 lines) — CodeSift: `get_file_outline` + `analyze_complexity` + `trace_call_chain(callees)`. Classify code type (ref `test-code-types.md`), complexity, testability. Edge cases (ref `test-edge-cases.md` for STANDARD+). Plan: test count, describe/it outline, mock strategy.
    - Step 2: Write (~20 lines) — contract (ref `test-contract.md`), blocklist (ref `test-blocklist.md`), mock safety (ref `test-mock-safety.md`), write test file, run tests (must pass).
    - Step 3: Verify (~15 lines) — anti-tautology check, Q1-Q19 self-eval (ref `quality-gates.md`), `[CHECKPOINT: quality audit]` using `q-scoring-protocol.md`. On Claude Code: optionally dispatch `agents/test-quality-reviewer.md` instead. Discrepancy 2+ = auditor wins.
    - Step 4: Adversarial (~15 lines) — `git reset HEAD && git add <test-file> && git diff --staged | adversarial-review --json --mode test`. Fix policy per spec (CRITICAL→fix+retry max 2, WARNING→fix if <10 lines, FAILED/SKIPPED_REVIEW states).
    - Step 5: Log (~10 lines) — update `memory/coverage.md` (PASS/FAILED/SKIPPED_REVIEW), print per-file summary.
  - **Completion:** backlog, knowledge curation, report with run log (~25 lines)
  - **Resume/Recovery:** coverage.md statuses (PASS/FAILED/SKIPPED_REVIEW/absent), partial run detection (~15 lines)
  - **Principles:** condensed (~10 lines)
- [ ] Verify: `wc -l skills/write-tests/SKILL.md` — expect ≤250
- [ ] Verify: `bash scripts/build-codex-skills.sh 2>&1 | grep -E 'ERROR|BUILD'` — no errors
- [ ] Verify: `bash scripts/build-cursor-skills.sh 2>&1 | grep -E 'ERROR|BUILD'` — no errors
- [ ] Commit: `rewrite: write-tests — single-file pipeline with CodeSift + quality reviewer`

### Task 7: Update using-zuvo routing description
**Files:** `skills/using-zuvo/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 6

- [ ] Update the `zuvo:write-tests` description in the routing table and skill list to reflect single-file pipeline (remove "batches of 15", add "one file at a time with full adversarial per file").
- [ ] Verify: `grep -A2 'write-tests' skills/using-zuvo/SKILL.md | grep -c 'batch'` — expect 0 in write-tests entry context
- [ ] Commit: `docs: update using-zuvo to reflect write-tests single-file pipeline`

### Task 8: Update spec description in plugin manifests
**Files:** `skills/write-tests/SKILL.md` frontmatter (already done in Task 6), `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`
**Complexity:** standard
**Dependencies:** Task 6

- [ ] Update write-tests description in plugin manifests to match new behavior (single-file, not batch)
- [ ] Verify: `grep 'write-tests' .claude-plugin/plugin.json` — description matches
- [ ] Commit: `docs: update plugin manifests for write-tests single-file pipeline`

### Task 9: Validate full build + adversarial review
**Files:** none (validation only)
**Complexity:** standard
**Dependencies:** Task 6, Task 7, Task 8

- [ ] Run `./scripts/install.sh` — all platforms pass
- [ ] Run `adversarial-review --json --mode spec --files "skills/write-tests/SKILL.md"` — no CRITICAL
- [ ] Verify SKILL.md line count ≤250
- [ ] Verify 5 new shared includes exist and are copied to all platform caches
- [ ] Verify `skills/write-tests/agents/test-quality-reviewer.md` exists and has proper frontmatter
- [ ] Verify `execute/agents/quality-reviewer.md` still references Q1-Q19 (via shared include)
- [ ] No commit (validation only)
