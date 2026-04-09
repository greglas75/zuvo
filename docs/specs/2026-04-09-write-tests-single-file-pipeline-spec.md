# write-tests Single-File Pipeline — Design Specification

> **spec_id:** 2026-04-09-write-tests-single-file-1412
> **topic:** Rewrite write-tests to process one file at a time with full verification pipeline per file
> **status:** Approved
> **created_at:** 2026-04-09T14:12:00Z
> **approved_at:** 2026-04-09T15:20:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

The current `zuvo:write-tests` skill processes files in batches of 15 (auto mode) or all-at-once (explicit mode). All verification gates (adversarial review, quality audit, anti-tautology check) sit at the END of the batch. This creates a "rush to finish" pattern where agents:

1. Write 10+ test files (173 tests in the observed failure)
2. Run tests — all green
3. Skip Phase 3 pre-write contract, Phase 4.2 anti-tautology, Phase 4.4 quality auditor, Phase 4.5 adversarial review
4. Jump straight to "WRITE-TESTS COMPLETE" report

**Root causes:**
- **Context decay:** 532-line skill prompt means mandatory gates from Phase 4 are invisible by the time the agent finishes writing in Phase 3. Repeating "MANDATORY — do NOT skip" 3x in the protocol did not prevent skipping.
- **Batch momentum:** 15 files × green tests = strong "done" signal. Verification phases look like "extra work after the real work."
- **Structural flaw:** Adversarial review is step 4.5 of 5.5 — positioned as a post-hoc check, not an integral part of the loop.

**Consequence:** Tests pass but have tautological oracles, weak assertions, missing edge cases, and no cross-model verification. Quality gates exist on paper but not in practice.

## Design Decisions

### D1: Single-file pipeline (not batches)

Process ONE production file at a time through the FULL pipeline: analyze → write → verify → adversarial → next file. The agent cannot skip adversarial because it is step 4 of 5 inside the per-file loop, not a phase at the end of a batch.

**Why not 3-file mini-batches?** Even with 3 files, the agent can "momentum" past verification after green tests on files 1-2. One file = one pipeline = zero room to skip.

**Cost:** More adversarial API calls (N instead of 1). Acceptable — quality over speed.

### D2: Skill prompt ≤200 lines

Current skill is 532 lines, 41 sections. Agent loses context. New skill is a tight orchestrator (~150-200 lines). All reference material extracted to shared includes and agent instructions:

| Content | Current location | New location |
|---------|-----------------|-------------|
| Code-Type Gate (11 types, 50 lines) | Inline in SKILL.md | `shared/includes/test-code-types.md` |
| Pre-Write Contract protocol | Inline in SKILL.md | `shared/includes/test-contract.md` (already exists, just reference it) |
| Pre-Write Blocklist | Inline in SKILL.md | `shared/includes/test-blocklist.md` |
| Mock Safety Rules | Inline in SKILL.md | `shared/includes/test-mock-safety.md` or append to existing `testing.md` rule |
| Edge Case Checklist | Inline in SKILL.md | `shared/includes/test-edge-cases.md` |
| Q1-Q19 Self-Eval protocol | Inline in SKILL.md | Already in `quality-gates.md`, just reference |
| Quality Auditor dispatch | Inline in SKILL.md | Inline agent prompt (no separate agent file needed for single-agent fallback) |

SKILL.md keeps: argument parsing, mode table, the per-file loop, Phase 0 (once), and completion report.

### D3: Adversarial review is step 4 of 5 per file

Not a separate "Phase 4.5" at the end. It's an integral step in the per-file pipeline:

```
FOR EACH FILE:
  Step 1: Analyze (read, classify, plan)
  Step 2: Write (contract → test → run)
  Step 3: Verify (anti-tautology + Q-gates + auditor)
  Step 4: Adversarial review
  Step 5: Log result → NEXT
```

If adversarial finds CRITICAL: fix, re-run test, re-run adversarial (max 2 total calls per file). If CRITICAL persists after 2 calls: mark file FAILED in coverage.md, backlog the findings with file:line, proceed to next file. FAILED files appear in completion report.

### D4: Auto-mode processes queue, not batches

Current: batch 15 → verify batch → check coverage → next batch.
New: build priority queue in Phase 0, process one file at a time until queue empty.

Queue is persisted to `memory/coverage.md` so crash recovery picks up from next unprocessed file.

### D5: No sub-agent requirement for quality audit

Current skill requires Sonnet sub-agent for quality audit (Phase 4.4). This adds complexity and platform dependency. 

New approach: quality audit is a best-effort CHECKPOINT role-switch (same agent, explicit context boundary). Agent prints `[CHECKPOINT: quality audit]`, re-reads the test file from disk, scores Q1-Q19 with evidence. This is a heuristic — the same agent reviewing its own work has confirmation bias. The real independence mechanism is Step 4 (adversarial review via different AI model). The checkpoint catches obvious self-eval inflation; adversarial catches the rest.

Sub-agent dispatch remains OPTIONAL optimization on Claude Code (true independence).

### D6: Coverage Scanner stays, Pattern Selector removed

Coverage Scanner (Phase 0, Haiku, Explore) is valuable — discovers untested files and ranks by risk. Keep it for auto mode.

Pattern Selector was a separate agent that classified code types. This is now done inline per-file in Step 1 (simpler, no agent overhead, code-type classification is fast).

## Solution Overview

```
Phase 0: ONCE per invocation
  ├── Read rules + shared includes
  ├── Knowledge prime (stack detection, existing patterns)
  ├── Baseline test run
  └── Build file queue (explicit target or auto-discovery via Coverage Scanner)

PER-FILE LOOP (for each file in queue):
  ├── Step 1: ANALYZE
  │     Read production file, classify code type + complexity + testability
  │     Plan: test count, patterns, mock strategy, describe/it outline
  │
  ├── Step 2: WRITE
  │     Fill test contract (from shared/includes/test-contract.md)
  │     Check blocklist (from shared/includes/test-blocklist.md)  
  │     Write test file
  │     Run tests — must pass
  │
  ├── Step 3: VERIFY
  │     Anti-tautology check (grep echo patterns, verify value sources)
  │     Q1-Q19 self-eval (critical gates must pass)
  │     [CHECKPOINT: quality audit] — re-read, independent score
  │
  ├── Step 4: ADVERSARIAL
  │     git add <test-file> && git diff --staged | adversarial-review --json --mode test
  │     Fix CRITICAL findings → re-run test → re-run adversarial (max 2 total)
  │     WARNING: fix if <10 lines, else backlog
  │
  └── Step 5: LOG
        Update memory/coverage.md
        Print per-file summary
        → NEXT file in queue

COMPLETION (after queue empty):
  ├── Backlog persistence
  ├── Knowledge curation
  └── WRITE-TESTS COMPLETE report + run log
```

## Detailed Design

### Argument Parsing (unchanged)

| Input | Behavior |
|-------|----------|
| `[file.ts]` | Write tests for one production file |
| `[directory/]` | Write tests for all production files in the directory |
| `auto` | Discover uncovered files, process one at a time until done |
| `--dry-run` | Run Phase 0 + Step 1 for all files, print plan, stop |

### Phase 0: Setup (runs once)

1. Mandatory file loading (same checklist, trimmed to essentials)
2. CodeSift setup (if available)
3. Knowledge prime: detect stack, test runner, existing patterns
4. Baseline test run: record pre-existing failures
5. **Build queue:**
   - Explicit mode: queue = user's target files
   - Auto mode: spawn Coverage Scanner → get ranked file list → queue = all UNCOVERED + PARTIAL files

### Per-File Steps

**Step 1: Analyze** (~20 lines in SKILL.md)
- Read production file fully
- Classify: code type (from `test-code-types.md`), complexity (THIN/STANDARD/COMPLEX), testability (UNIT_MOCKABLE/UNIT_REFLECTION/NEEDS_INTEGRATION/MIXED)
- Plan: target test count, describe/it outline, mock strategy
- Print classification summary (3-4 lines)

**Step 2: Write** (~20 lines in SKILL.md)
- Fill test contract per `test-contract.md` (BRANCHES, ERROR PATHS, EXPECTED VALUES, MOCK INVENTORY, MUTATION TARGETS)
- Check blocklist per `test-blocklist.md`
- Write test file
- Run tests — all must pass. Fix if red.

**Step 3: Verify** (~20 lines in SKILL.md)
- Anti-tautology: grep for echo patterns, verify value sources
- Q1-Q19 self-eval with critical gate enforcement
- `[CHECKPOINT: quality audit]` — re-read test independently, score with evidence
- If auditor score differs by 2+ from self-eval: auditor wins, fix

**Step 4: Adversarial** (~15 lines in SKILL.md)
- **IMPORTANT: Reset staged index first:** `git reset HEAD && git add <test-file>` then `git diff --staged | adversarial-review --json --mode test`
- This ensures only the CURRENT file's diff is reviewed (not accumulated staged changes from previous files)
- Fallback: `adversarial-review` resolves per platform (build scripts handle path transformation)
- CRITICAL → fix + re-test + re-adversarial (max 2 calls per file). If CRITICAL persists after 2 calls → mark file FAILED in coverage.md, backlog findings, proceed to next file
- WARNING (<10 lines) → fix. WARNING (>10 lines) → backlog
- INFO → known concerns
- Provider down → note "adversarial: skipped (provider unavailable)", proceed. Files with skipped adversarial are marked SKIPPED_REVIEW in coverage.md (not PASS)

**Step 5: Log** (~5 lines in SKILL.md)
- Update `memory/coverage.md`: file, status, test count, Q score, date
- Print one-line per-file summary:
  ```
  ✓ utils/slug.ts — 12 tests, Q 18/19, adversarial: clean
  ```

### Completion (after queue empty)

Same as current Phase 5: backlog persistence, knowledge curation, completion report with run log.

### Extracted Shared Includes (new or updated files)

| File | Content | Lines |
|------|---------|-------|
| `shared/includes/test-code-types.md` | NEW — 11 code types with detection signals and min test formulas | ~40 |
| `shared/includes/test-blocklist.md` | NEW — blocked patterns table (from current Phase 3) | ~25 |
| `shared/includes/test-mock-safety.md` | NEW — mock safety rules (from current Phase 3) | ~15 |
| `shared/includes/test-edge-cases.md` | NEW — edge case checklist per parameter type (from current Phase 3) | ~15 |
| `shared/includes/test-contract.md` | EXISTS — already referenced, no change needed | — |
| `shared/includes/quality-gates.md` | EXISTS — Q1-Q19, already referenced | — |

### Resume / Crash Recovery

`memory/coverage.md` is the checkpoint. Each file's result is logged in Step 5 BEFORE moving to the next file.

**File statuses in coverage.md:**
| Status | Meaning | Resume action |
|--------|---------|---------------|
| PASS | All steps completed, adversarial clean | Skip |
| FAILED | Adversarial CRITICAL persisted after 2 retries | Skip (already backlocked) |
| SKIPPED_REVIEW | Steps 1-3 passed, adversarial provider unavailable | Re-process (run adversarial only) |
| (absent) | Not yet processed | Process from Step 1 |

On crash:
1. Phase 0 reads `memory/coverage.md`
2. If test file exists on disk but file is not logged → partial run. Delete test file, re-process from Step 1.
3. Skip files marked PASS or FAILED
4. Re-process SKIPPED_REVIEW files (adversarial only)
5. Process absent files in queue order

Auto mode: crash recovery re-runs Coverage Scanner to rebuild priority queue (queue order is not persisted).

## Acceptance Criteria

1. `zuvo:write-tests src/utils/slug.ts` processes exactly one file through Steps 1-5, including adversarial review
2. `zuvo:write-tests auto` discovers files, processes them ONE AT A TIME, each with full adversarial review
3. Adversarial review runs per-file (not per-batch, not per-invocation)
4. SKILL.md target ≤250 lines (down from 532). Hard cap: 300.
5. No mandatory gate exists outside the per-file loop (except Phase 0 setup and final completion report)
6. `[CHECKPOINT: quality audit]` appears in output for every STANDARD+ file
7. `memory/coverage.md` updated after each file (before next file starts)
8. `--dry-run` shows plan for all files without writing tests
9. Skill produces identical step sequence and output fields on Claude Code, Codex, Cursor, Antigravity (same 5 steps per file, same coverage.md schema, same completion gating)
10. Agent cannot produce "WRITE-TESTS COMPLETE" without adversarial having run (or explicitly marked SKIPPED_REVIEW/FAILED) for every file

## Out of Scope

- Changes to `adversarial-review.sh` script itself
- Changes to other skills (build, execute, etc.) — those may adopt similar pattern later
- Changes to Q1-Q19 quality gates definitions
- New shared includes beyond the 4 extracted files

**In scope (clarification):** Removing mandatory sub-agent for quality audit (D5) and removing Pattern Selector agent (D6) ARE in scope — they are part of the skill rewrite. Coverage Scanner stays as optional auto-mode agent.

## Open Questions

None — all resolved during design dialogue.
