---
name: write-tests
description: >
  Write tests for existing production code. Processes ONE file at a time
  through a full pipeline: analyze, write, verify, adversarial review, log.
  Uses CodeSift for discovery and analysis when available. Modes: [path]
  (specific target), auto (discover and loop until done), --dry-run (plan only).
---

# zuvo:write-tests — Single-File Test Pipeline

Generate high-quality tests for production code. Each file goes through the full pipeline individually — no batching, no skipping verification.

**Scope:** Existing production files with missing or partial test coverage.
**Out of scope:** New feature tests (use `zuvo:build`), mass anti-pattern repair (use `zuvo:fix-tests`), audit without writing (use `zuvo:test-audit`).

## Argument Parsing

| Input | Behavior |
|-------|----------|
| `[file.ts]` | Write tests for one production file |
| `[directory/]` | Write tests for all production files in the directory |
| `auto` | Discover uncovered files, process one at a time until done |
| `--dry-run` | Run Phase 0 + Step 1 for all files, print plan, stop |

---

## Mandatory File Loading

Read each file. Print checklist. If any REQUIRED file is missing, STOP.

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md      -- [READ|MISSING -> STOP]
  2. ../../shared/includes/test-contract.md        -- [READ|MISSING -> STOP]
  3. ../../shared/includes/test-code-types.md      -- [READ|MISSING -> STOP]
  4. ../../shared/includes/test-blocklist.md       -- [READ|MISSING -> STOP]
  5. ../../shared/includes/test-mock-safety.md     -- [READ|MISSING -> STOP]
  6. ../../shared/includes/test-edge-cases.md      -- [READ|MISSING -> STOP]
  7. ../../shared/includes/q-scoring-protocol.md   -- [READ|MISSING -> STOP]
  8. ../../shared/includes/quality-gates.md        -- [READ|MISSING -> STOP]
  9. ../../shared/includes/run-logger.md           -- [READ|MISSING -> STOP]
  10. ../../rules/testing.md                       -- [READ|MISSING -> STOP]
```

---

## Phase 0: Setup (runs once)

1. **CodeSift setup** per `codesift-setup.md`. Note repo identifier.
2. **Stack detection:** read package.json/tsconfig/composer.json. Detect test runner (vitest/jest/phpunit). Find existing test patterns (DB helpers, factory functions, mock conventions).
3. **Baseline test run:** execute test suite, record pre-existing failures. These are ignored in verification.
4. **Build queue:**
   - **Explicit mode:** queue = user's target file(s)
   - **Auto mode with CodeSift:**
     ```
     classify_roles(repo)                    → dead/leaf symbols = likely untested
     analyze_hotspots(repo, since_days=90)   → prioritize by churn × complexity
     find_references(repo, symbol_names=[exported symbols], file_pattern="*.test.*")
                                             → 0 refs in test files = no tests
     ```
     Merge results. Priority: UNCOVERED+high-churn first. Queue all UNCOVERED + PARTIAL files.
   - **Auto mode without CodeSift:** `Glob("src/**/*.ts")` + check for matching `*.test.*` files. Files without test = UNCOVERED.

**`--dry-run` mode:** after building queue, run Step 1 (Analyze) for each file, print classification table, STOP.

---

## Per-File Loop

For each file in the queue, execute Steps 1-5 in order. Do NOT skip any step. Do NOT proceed to the next file until all 5 steps complete.

### Step 1: Analyze

Read the production file fully. Classify it.

**With CodeSift:**
- `get_file_outline(repo, file_path)` → exports, classes, functions
- `analyze_complexity(repo, file_pattern="<file>")` → cyclomatic complexity, nesting, LOC
- `trace_call_chain(repo, symbol, direction="callees")` → dependencies to mock

**Without CodeSift:** Read the file, count branches manually.

Classify per `test-code-types.md`:
- **Code type:** VALIDATOR / SERVICE / CONTROLLER / HOOK / PURE / COMPONENT / GUARD / API-CALL / ORCHESTRATOR / STATE-MACHINE / ORM-DB
- **Complexity:** THIN / STANDARD / COMPLEX
- **Testability:** UNIT_MOCKABLE / UNIT_REFLECTION / NEEDS_INTEGRATION / MIXED

Plan: target test count (from code-type formula), describe/it outline, mock strategy. For STANDARD+, apply edge cases from `test-edge-cases.md`.

Print: `[file]: [type] [complexity] [testability] → [N] tests planned`

### Step 2: Write

1. **Fill test contract** per `test-contract.md`: BRANCHES, ERROR PATHS, EXPECTED VALUES, MOCK INVENTORY, MUTATION TARGETS, TEST OUTLINE.
2. **Check blocklist** per `test-blocklist.md` — verify you are NOT about to write any blocked pattern.
3. **Apply mock rules** per `test-mock-safety.md`.
4. **Write the test file.** Follow the contract and plan exactly.
5. **Run tests:** `[test runner] [test file]`. All new tests must pass. Pre-existing failures ignored. Fix red tests before proceeding.

### Step 3: Verify

1. **Anti-tautology check:** grep test file for mock-return-echoed-in-assertion patterns. Verify every expected value is spec-derived, not implementation-derived. Any tautological oracle found = fix immediately.
2. **Q1-Q19 self-eval** per `quality-gates.md`. Print scorecard with evidence:
   ```
   Self-eval: Q1=1 Q2=1 Q3=0 ... → [N]/19 [PASS|FIX|REWRITE]
   Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]
   ```
   Any critical gate at 0: fix immediately and re-score.
3. **Quality audit** per `q-scoring-protocol.md`:
   - **Claude Code (sub-agent available):** dispatch `agents/test-quality-reviewer.md` (Sonnet, Explore). Pass production file, test file, test contract.
   - **All platforms (fallback):** `[CHECKPOINT: quality audit]` — re-read the test file from disk as if seeing it for the first time. Score Q1-Q19 independently with evidence. This is a best-effort heuristic; Step 4 (adversarial) provides true cross-model independence.
   - **Discrepancy 2+ points** on any gate: auditor's score wins. Fix before proceeding.

### Step 4: Adversarial Review

```bash
git diff HEAD -- <test-file> | adversarial-review --json --mode test
```

If `adversarial-review` is not found: check `../../scripts/adversarial-review.sh`. If missing entirely, mark file SKIPPED_REVIEW and proceed.

Wait for complete output. Handle findings:

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. Re-run adversarial (max 2 total calls per file). |
| **CRITICAL after 2 calls** | Mark file **FAILED** in coverage.md. Backlog findings with file:line. Proceed to next file. |
| **WARNING (<10 lines)** | Fix immediately. |
| **WARNING (>10 lines)** | Add to backlog with file:line. |
| **INFO** | Known concerns (max 3). |
| **Provider unavailable** | Note `adversarial: skipped (provider unavailable)`. Mark file **SKIPPED_REVIEW** in coverage.md. |

### Step 5: Log

Update `memory/coverage.md`:
```
| File | Status | Tests | Q Score | Adversarial | Date |
```

Statuses: `PASS`, `FAILED`, `SKIPPED_REVIEW`

Print per-file summary: `[status] [file] — [N] tests, Q [N]/19, adversarial: [clean|N findings|skipped]`

**→ NEXT file in queue.**

---

## Completion (after queue empty)

1. **Backlog persistence:** write unfixed issues to `memory/backlog.md`
2. **Knowledge curation** per `knowledge-curate.md`
3. **Report:**

```
WRITE-TESTS COMPLETE
-----
Files tested:  [N] ([M] new, [K] extended, [J] fixed)
Tests written: [N] total
Q gates:       [N]/19 avg (critical gates: all pass)
Failures:      pre-existing: [N], new: 0
FAILED files:  [list or "none"]
SKIPPED_REVIEW: [list or "none"]
Run: <ISO-8601-Z>	write-tests	<project>	-	<Q>	<VERDICT>	<TASKS>	<DURATION>	<NOTES>	<BRANCH>	<SHA7>
-----
```

Append `Run:` line to log file per `run-logger.md`.

**Do NOT print WRITE-TESTS COMPLETE if any file has no status in coverage.md.**

---

## Resume / Crash Recovery

On start, read `memory/coverage.md`:

| Status | Resume action |
|--------|---------------|
| PASS | Skip |
| FAILED | Skip (already backlocked) |
| SKIPPED_REVIEW | Re-process Step 4 only (adversarial) |
| (absent) | Process from Step 1 |

If a test file exists on disk but file is absent from coverage.md → partial run. Check if file was auto-generated (contains `// Generated by zuvo:write-tests` header). If yes, delete and re-process from Step 1. If no (pre-existing/manual test), treat as ADD TO (extend, don't replace).

Auto mode: re-run CodeSift discovery to rebuild priority queue (queue order not persisted).

---

## Principles

1. Read production code before planning tests. Every assertion traces to real behavior.
2. Test depth matches complexity. A 25-line wrapper does not need 30 edge-case tests.
3. Test what the code OWNS, mock what it DELEGATES.
4. ONE file, FULL pipeline. No batching. No skipping steps.
5. Adversarial review is step 4 of 5 — not optional, not at the end.
