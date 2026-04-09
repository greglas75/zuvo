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
| `--no-cache` | Force regeneration of project profile before test planning |

---

## Mandatory File Loading

**Phase 0 (always load):** core files needed before analysis.

```
CORE (Phase 0):
  1. ../../shared/includes/codesift-setup.md      -- [READ|MISSING -> STOP]
  2. ../../shared/includes/test-contract.md        -- [READ|MISSING -> STOP]
  3. ../../shared/includes/test-blocklist.md       -- [READ|MISSING -> STOP]
  4. ../../shared/includes/test-mock-safety.md     -- [READ|MISSING -> STOP]
  5. ../../shared/includes/quality-gates.md        -- [READ|MISSING -> STOP]
  6. ../../shared/includes/run-logger.md           -- [READ|MISSING -> STOP]
  7. ../../rules/testing.md                          -- [READ|MISSING -> STOP]
  8. ../../shared/includes/project-profile-protocol.md -- [READ|MISSING -> DEGRADED]
  9. ../../shared/includes/retrospective.md          -- RETRO PROTOCOL
```

**Step 1 (load after classification):** based on file complexity.

```
STANDARD+ only (skip for THIN):
  10. ../../shared/includes/test-edge-cases.md      -- [READ|SKIP]
  11. ../../shared/includes/test-code-types.md      -- [READ|SKIP]
```

---

## Phase 0: Setup (runs once)

1. **CodeSift setup** per `codesift-setup.md`. Note repo identifier.
2. **Project profile:** Load project profile per `project-profile-protocol.md` (pass `--no-cache` flag if set).
   - If `profile.conventions` exists for this file's framework: use convention values for ORCHESTRATOR test planning (middleware names, rate limit values, auth boundaries, route mounts).
   - If profile unavailable or partial: use generic `test-code-types.md` patterns (current behavior).
3. **Stack detection:** If profile loaded, use `profile.stack` for framework/test-runner/language. Otherwise: read package.json/tsconfig/composer.json. Detect test runner (vitest/jest/phpunit). Find existing test patterns (DB helpers, factory functions, mock conventions).
4. **Baseline test run:** execute test suite, record pre-existing failures. These are ignored in verification.
5. **Build queue:**
   - **Explicit mode:** queue = user's target file(s)
   - **Auto mode with CodeSift:** single batch call:
     ```
     codebase_retrieval(repo, token_budget=5000, queries=[
       {type: "dead_code"},
       {type: "hotspots", since_days: 90},
       {type: "references", symbol_names: [exports], file_pattern: "*.test.*"},
       {type: "classify_roles", file_pattern: "src/"}
     ])
     ```
     Dead/leaf symbols with 0 test refs = UNCOVERED. **Priority:** hub symbols first (many connections = failures cascade), then high-churn, then leaf.
   - **Auto mode without CodeSift:** `Glob("src/**/*.ts")` + check for matching `*.test.*` files. Files without test = UNCOVERED.

**`--dry-run` mode:** after building queue, run Step 1 (Analyze) for each file, print classification table, STOP.

---

## Per-File Loop

For each file in the queue, execute Steps 1-5 in order. Do NOT skip any step. Do NOT proceed to the next file until all 5 steps complete.

### Step 1: Analyze

Read the production file fully. Classify it.

**With CodeSift:** single batch call:
```
codebase_retrieval(repo, token_budget=3000, queries=[
  {type: "outline", file_path: "<file>"},
  {type: "complexity", file_pattern: "<file>"},
  {type: "call_chain", symbol_name: "<main_export>", direction: "callees"}
])
```

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

No sub-agent dispatch. Step 4 (4 adversarial passes with different models) provides true independent verification — stronger than same-model sub-agent.

### Step 4: Adversarial Review (iterative, complexity-tiered)

Run adversarial passes sequentially, one RANDOM provider per pass (`--rotate`). Each pass sees the FIXED code from previous passes. Early exit when a pass returns 0 findings. Run until clean or max passes exhausted (whichever first).

**Pass count by complexity:**

| Complexity | Max passes | Rationale |
|-----------|-----------|-----------|
| THIN | 1 | Sanity check — wiring correctness only |
| STANDARD | 2 | Pass 1 finds gaps, pass 2 verifies fixes |
| COMPLEX | 2 + optional 3rd | Extra pass ONLY IF pass 2 found CRITICAL with high confidence |

Agent data shows passes 3-4 yield 0 new findings and cost ~60K tokens. 99% of value is in first 2 passes.

**Input: production + test file** (not just diff). Reviewer needs to see what's being tested to find gaps:

```bash
adversarial-review --rotate --mode test \
  --context "Code type: [type] [complexity] [testability]. Q-GATES: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]" \
  --files "<absolute-path-to-production-file> <absolute-path-to-test-file>"
```

**Always use absolute paths for --files.** Relative paths fail silently.

The provider sees both files and focuses on gaps between production behavior and test coverage. Without production code, reviewer can't detect missing ordering tests, auth boundary gaps, or untested error messages.

**Pass sequence with structured context (prevents repetition):**

```
Pass 1:
  --context "Code type: [type] [complexity]. Q-GATES: [scores]"
  --files "<prod> <test>"
  → fix CRITICAL/WARNING → re-run tests

Pass 2:
  --context "Code type: [type] [complexity]. Q-GATES: [scores].
    FIXED: [list of findings fixed in pass 1].
    REJECTED: [findings consciously skipped, with reason].
    KNOWN: [remaining limitations]."
  --files "<prod> <test>"
  → fix findings → re-run tests

Pass 3+: same pattern, accumulate FIXED/REJECTED/KNOWN from all previous passes.
```

**Context rules:**
- FIXED findings must NOT be re-raised. If reviewer repeats a fixed finding, ignore it.
- REJECTED findings have a **severity cap**: `REJECTED: [finding] — max re-raise: INFO`. If reviewer escalates a rejected finding above the cap (e.g. INFO → CRITICAL), auto-ignore. This prevents adversarial from overriding conscious scope decisions.
- Each pass adds its own fixes/rejections to the context for the next pass.
- Early exit: 0 new findings (not counting repeats of FIXED/REJECTED).

**Stub fidelity rule for ORCHESTRATOR:** Route module stubs MUST use `all()` (catch-all). Testing HTTP methods (GET vs POST) is the responsibility of route module tests, not orchestrator tests. If adversarial flags "stubs don't verify HTTP methods" — REJECT with "scope mismatch, route module responsibility".

If `adversarial-review` is not found: check `../../scripts/adversarial-review.sh`. If missing entirely, mark file SKIPPED_REVIEW and proceed.

**Fix policy per pass:**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING (<10 lines)** | Fix immediately. |
| **WARNING (>10 lines)** | Add to backlog with file:line. |
| **INFO** | Known concerns (max 3). |
| **0 findings** | Early exit — stop passes, file is clean. |
| **After pass 4 with unresolved CRITICAL** | Mark file **FAILED** in coverage.md. Backlog findings. |
| **Provider unavailable on all passes** | Mark file **SKIPPED_REVIEW** in coverage.md. |

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
3. **Retrospective** per `retrospective.md`. Gate check -> structured questions -> TSV emit -> markdown append. If gate check skips: print "RETRO: skipped (trivial session)".
4. **Report:**

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
