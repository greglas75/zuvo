---
name: debug
description: "Systematic bug investigation with a five-phase framework: reproduce, narrow, diagnose, fix, verify. Supports automated regression bisect via --regression flag. Produces a structured debug report with root cause analysis, regression test, and CQ/Q self-evaluations."
---

# zuvo:debug — Structured Bug Investigation

A disciplined five-phase process for turning a bug report, error message, or unexpected behavior into a confirmed root cause, verified fix, and permanent regression test.

**Scope:** Any bug, error, or unexpected behavior that needs investigation.
**Out of scope:** Code quality sweeps (use `zuvo:code-audit`), general review (use `zuvo:review`), performance problems without a specific bug (use `zuvo:performance-audit`).

## Argument Parsing

Parse `$ARGUMENTS` to determine the starting phase:

| Input | Starting point |
|-------|---------------|
| _(empty)_ | Ask the user: "Describe the issue. Share the error message, stack trace, or explain what is happening." |
| Error message or stack trace | Phase 1.5 (Minimal Reproduction) -- verify the error is reproducible before narrowing |
| Code snippet or file reference | Phase 3 (Diagnose) -- read the code, trace the execution path |
| Description like "why does X" or "X is broken" | Phase 1 (Reproduce) -- gather context before proceeding |
| `--regression` flag, or words like "bisect", "regression", "this used to work" | Phase R (Regression Bisect) -- automated git bisect to find the breaking commit |

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Key tools for debugging:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 2 | Identify recent symbol-level changes | `changed_symbols(repo, since="HEAD~5")` | `git log --oneline` + `git diff` |
| 2 | Compact change summary | `diff_outline(repo, since="HEAD~5")` | `git diff --stat` |
| 2 | Blast radius of recent changes | `impact_analysis(repo, since="HEAD~5", depth=2)` | Grep for imports of changed files |
| 3 | Trace callers/callees of buggy function | `trace_call_chain(repo, symbol_name, direction, depth=3)` | Repeated Grep for function name |
| 3 | Understand buggy function with imports and siblings | `get_context_bundle(repo, symbol_name)` | Read the entire file |
| 3 | Find where an error is thrown | `search_text(repo, query="error message", regex=true)` | Grep |
| 3 | Read multiple functions along the call path | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |
| 3 | File structure around the bug | `get_file_outline(repo, file_path)` | Read the file |
| Any | Batch 3+ lookups | `codebase_retrieval(repo, queries=[...])` | Sequential Grep/Read |

## Mandatory File Reading

### PHASE 0 — Bootstrap (always, before reading error/file)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
```

This is the ONLY file loaded before reading the error report or target file.

### PHASE 0.5 — Classify (read error/file, determine bug category)

After CodeSift setup, read the error, stack trace, or target file. Classify bug category:
- **logic:** wrong output, off-by-one, condition error, missing branch
- **async:** race condition, unhandled rejection, deadlock, timeout
- **data:** wrong query, missing join, constraint violation, data corruption
- **integration:** API contract mismatch, version incompatibility, env config error
- **test-failure:** existing test broke, flaky test, test infrastructure issue

Print: `[CLASSIFIED] Bug category: {logic|async|data|integration|test-failure}`

### PHASE 1 — Conditional Load (based on bug category)

| Include | logic | async | data | integration | test-failure |
|---------|-------|-------|------|-------------|-------------|
| `../../rules/cq-patterns.md` | Full | CQ15,CQ21 focus | CQ6,7,9 focus | CQ8,CQ19 focus | **SKIP** |
| `../../rules/cq-checklist.md` | Full | CQ15,CQ21 focus | CQ6,7,9 focus | CQ8,CQ19 focus | **SKIP** |
| `../../rules/testing.md` | **SKIP** | **SKIP** | **SKIP** | **SKIP** | Full |
| `../../rules/test-quality-rules.md` | **SKIP** | **SKIP** | **SKIP** | **SKIP** | Full |

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file]
```

### Optional Files (loaded if available)

```
  ../../shared/includes/knowledge-prime.md   -- [READ | MISSING -> degraded]
```

### DEFERRED — Load at completion

```
  ../../shared/includes/run-logger.md        -- [READ at final step]
  ../../shared/includes/retrospective.md     -- [READ at final step]
  ../../shared/includes/knowledge-curate.md  -- [READ at final step | MISSING -> degraded]
```

**If PHASE 0 file missing:** Run self-evaluation using the embedded minimal checklist below. Note "DEGRADED — codesift-setup.md unavailable" in the debug report.

**Minimal checklist (fallback only):**
1. Error path tested? (Q7)
2. All branches exercised? (Q11)
3. Test imports real production code? (Q13)
4. Assertions verify values, not just shape? (Q15)
5. Expected values from spec, not copied from implementation? (Q17)
6. Boundary validation present? (CQ3)
7. Auth guard paired with query filter? (CQ4)
8. Infrastructure errors handled with timeout? (CQ8)
9. No duplicated logic blocks? (CQ14)

---

## Framework: Five Phases

```
Phase 1:   REPRODUCE    -- Understand expected vs. actual behavior
Phase 1.5: MINIMAL REPRO -- Verify a stack trace is current and reproducible
Phase 2:   NARROW       -- Establish baseline, reduce the search space
Phase 3:   DIAGNOSE     -- Trace the code path, form and test hypotheses
Phase 4:   FIX + VERIFY -- Implement fix, regression test, quality gates

Phase R:   REGRESSION BISECT -- Alternative path for "this used to work" bugs
           Replaces Phases 1-3 with automated git bisect, then joins Phase 4.
```

---

## Phase 0: Knowledge Prime

Run the knowledge prime protocol from `knowledge-prime.md`:
```
WORK_TYPE = "research"
WORK_KEYWORDS = <keywords from the bug description, error messages, affected files>
WORK_FILES = <files mentioned in the bug report, if any>
```

Known gotchas from prior sessions may directly identify the root cause.

---

## Phase 1: Reproduce

Establish a clear, reproducible failure. Gather from the user if not provided:

- **Expected behavior:** What should happen?
- **Actual behavior:** What happens instead?
- **Reproduction steps:** Exact sequence to trigger the bug
- **Scope:** Does it happen always, intermittently, for all users, or under specific conditions?
- **Timeline:** When did it start? Was there a recent deploy, config change, or dependency update?

If reproduction is inconsistent, flag as a potential race condition, environment-dependent issue, or test-order dependency.

## Phase 1.5: Minimal Reproduction

A stack trace proves an error occurred at some point. It does not prove the error is reproducible right now. Before narrowing:

1. Run the failing test or hit the failing endpoint. Can you trigger the same error?
2. **If yes:** Proceed to Phase 2 with confirmed reproduction.
3. **If no:** The trace may be from a different state (stale data, previous deploy, changed config). Go back to Phase 1: gather expected vs actual, steps, scope.
4. **If intermittent:** Run 3 times to confirm flakiness, then proceed with a flaky flag.

Skip this phase only when the failure is self-evident (type error visible in code, compilation failure).

## Phase 2: Narrow

### 2.0 Baseline Check

Before changing anything, determine whether this is a new regression or a pre-existing problem.

1. Run existing tests for the affected area. Are any already failing?
2. Check recent commits to the affected files: `git log --oneline -10 -- [affected-files]`
3. If CodeSift is available: `changed_symbols(repo, since="HEAD~5")` to see symbol-level changes near the bug. `diff_outline(repo, since="HEAD~5")` for a compact summary.
4. Record the current test state as a baseline.

Output:
```
BASELINE: [N] passing, [M] failing in affected area
REGRESSION: YES (commit [hash]) | NO (pre-existing) | UNKNOWN
```

### 2.1 Reduce the Search Space

Work through these in order, stopping when the failure point is identified:

1. **Error message and stack trace** -- Read the full trace, not just the last line. The root cause is usually earlier in the chain.
2. **Logs around the failure time** -- What happened immediately before the error?
3. **Recent changes** -- Commits, deploys, dependency updates, config changes in the relevant window.
4. **Environment comparison** -- If it works in one environment but not another, find the difference.
5. **Binary search** -- If the code path is long, identify the midpoint and determine whether the bug is upstream or downstream.

## Phase 3: Diagnose

Trace the execution path from input to failure.

1. **Entry point** -- Where does the triggering action enter the system?
2. **Trace forward** -- Follow data through each function and service until the point of failure. If CodeSift is available, use `trace_call_chain(repo, symbol_name, direction="callees", depth=3)` from the entry point. Use `get_context_bundle(repo, symbol_name)` to understand the buggy function with its imports and neighbors.
3. **Form hypotheses (max 3)** -- List 2-3 possible root causes, ordered by likelihood.
4. **Test each hypothesis** -- For each: what evidence would confirm or rule it out? Gather that evidence. If 2 hypotheses fail, pivot: re-read the code path from scratch, add logging, or widen the search scope. Do not keep guessing in the same direction.
5. **Root cause** -- Identify the specific line, condition, or assumption that fails. Distinguish root cause from symptoms.

### Error-Type Playbooks

| Error type | Most common root causes |
|------------|------------------------|
| `undefined` or `null` | Missing null guard, wrong property key, async timing issue |
| Wrong value | Off-by-one, unit mismatch, stale cached data |
| Permission denied | Auth context not propagated, RBAC misconfigured, missing query filter |
| Timeout | N+1 query, missing database index, unbounded loop |
| Flaky / intermittent | Race condition, shared global state, test-order dependency |
| Works in dev, fails in prod | Missing env variable, production data edge case, timezone difference |

### Stack-Specific Diagnostic Sequences

**API / Backend:**
1. Reproduce with curl or the test runner against the endpoint
2. Check request validation -- does the schema reject the input, or does it let bad data through?
3. Check auth context at the point of failure
4. Check the database query -- does it return expected data? Run EXPLAIN for slow queries.
5. Check error handling -- does the catch block swallow, transform, or propagate correctly?

**Frontend / UI:**
1. Check browser console for errors, network tab for failed requests
2. Determine if API data is correct -- if yes, the bug is in rendering or state management
3. Trace component prop flow to the failing component
4. Check event handlers -- does the user action trigger the expected dispatch or callback?
5. Check SSR hydration mismatch if applicable

**Database / Performance:**
1. Identify the slow or failing query from logs or ORM debug mode
2. Run EXPLAIN ANALYZE -- missing index? full table scan? cartesian join?
3. Check for N+1 patterns (same query executed in a loop)
4. Check connection pool exhaustion or timeout settings
5. Check if dataset size has grown beyond what the query handles efficiently

**Async / Flaky:**
1. Run the failing test 5 times. How often does it fail?
2. Check for shared mutable state between tests (globals, singletons, database rows)
3. Check timing assumptions (setTimeout, sleep, waitFor with insufficient duration)
4. Check execution-order dependency (does the test rely on another test running first?)
5. Check resource cleanup (ports, connections, file handles released properly?)

---

## Phase 4: Fix and Verify

### 4.1 Implement the Fix

1. **Apply the minimal fix** -- Address the root cause only. Do not refactor adjacent code or fix unrelated issues.
2. **Explain why** -- Connect the fix to the diagnosed root cause. Add a code comment if the fix is non-obvious.
3. **Check side effects** -- Does the fix alter behavior for other callers? Does it change the function's contract?
4. **Consider edge cases** -- Does the fix hold for null, empty, concurrent, and high-load scenarios?

### 4.2 Run Targeted Tests

Run only the tests covering the affected area:
```
[test-runner] [affected-test-files]
```
If any fail, the fix is incomplete or introduced a new problem. Iterate.

### 4.3 Run Full Suite

```
[test-runner]
```
Compare with the Phase 2.0 baseline. No new failures should appear. If new failures exist, the fix has side effects. Investigate before proceeding.

### 4.4 Confirm Original Reproduction is Resolved

Re-run the exact reproduction from Phase 1 or Phase 1.5. If the bug still occurs, the root cause diagnosis was wrong. Return to Phase 3.

Read `../../shared/includes/verification-protocol.md` -- no completion claims without fresh evidence.

### 4.5 Write Regression Test

Write a test that:
1. Recreates the exact condition that triggered the bug
2. Asserts the correct behavior (the bug no longer occurs)
3. Would have caught this bug if it had existed before the original code was written

Run Q1-Q19 self-evaluation on the regression test. Read `../../rules/testing.md` for the full protocol.

Condensed reference: `../../shared/includes/quality-gates.md`

- Score each gate individually (1/0, N/A counts as 1 but needs justification)
- Critical gates: Q7, Q11, Q13, Q15, Q17 -- any = 0 means fix the test
- Threshold: >= 16 PASS, 9-15 FIX (address worst gaps), < 9 REWRITE

### 4.6 CQ Self-Evaluation (on production code changes)

Run CQ1-CQ29 on each modified production file. Read `../../rules/cq-checklist.md` for the full protocol.

- Static critical gates: CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 -- any = 0 means FAIL
- Conditional gates: CQ16 (money), CQ19 (API boundary), CQ20 (dual fields), CQ21 (concurrency), CQ22 (subscriptions), CQ23-CQ28 -- activated by code context
- Threshold: >= 24 PASS, 22-23 CONDITIONAL PASS, < 22 FAIL
- Provide file:function:line evidence for every critical gate scored as 1

### 4.6b Adversarial Review (MANDATORY — do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --mode code
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** — fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** — known concerns (max 3, one line each).

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this — if true, it's serious."

"Pre-existing" is NOT a reason to skip a finding. If the issue is in a file you are already editing, fix it now. If not, add it to backlog with file:line. The adversarial review found a real problem — don't dismiss it just because it existed before your changes.

### 4.7 Defense-in-Depth

After confirming the fix works, add validation at multiple layers to prevent the same class of bug from recurring:

| Layer | What to add | Example |
|-------|------------|---------|
| Entry validation | Guard at the function or endpoint boundary | Null check, schema validation, type narrowing |
| Business logic | Assertion or invariant within the core logic | Guard clause, exhaustive switch, pre/post-condition |
| Environment guard | Runtime check for assumptions about external state | Config validation at startup, connection health check |
| Debug instrumentation | Logging or metric that makes this failure class visible in production | Structured log with correlation ID at the failure point |

Not every layer applies to every bug. Add guards where they make sense. The goal is that if a similar bug occurs in the future, it fails loudly and early rather than silently propagating.

---

## Phase R: Regression Bisect

An alternative flow for bugs that are confirmed regressions. Replaces Phases 1-3 with automated `git bisect`, then joins Phase 4 for the fix and verification.

### When to Use

- The user says "this used to work", "regression", or explicitly passes `--regression`
- The bug is a behavioral change from a previously working state
- A test can be written that reproduces the failure deterministically

### When NOT to Use (fall back to standard Phases 1-4)

- The bug is not a regression (new feature, never worked correctly)
- No test can reproduce it (flaky, environment-dependent, requires manual UI interaction)
- The change is very recent (last 1-2 commits) -- just read the diff with `git show`
- Uncommitted changes cannot be stashed cleanly

### R.1 Write a Minimal Reproducer Test

Write a small, focused test that captures the regression:

1. The test must FAIL on current HEAD (it reproduces the bug)
2. Save it as `__bisect_test.{ts,py,sh}` (temporary, deleted after bisect completes)
3. Determine the test command based on the project's runner:
   - Vitest: `npx vitest run __bisect_test.ts --reporter=verbose`
   - Jest: `npx jest __bisect_test.ts --verbose`
   - Pytest: `python -m pytest __bisect_test.py -x -q`
   - Shell: `bash __bisect_test.sh`
4. Run the test once on HEAD to confirm it fails

### R.2 Determine Good and Bad Commit Range

- **Bad commit:** Current HEAD (confirmed failing in R.1)
- **Good commit:** Determined by one of:
  - User-provided commit hash or tag ("it worked in v2.3")
  - Auto-detection: test against HEAD~10, HEAD~20, HEAD~30. Use the first commit where the test passes.
  - If the user is unsure: show `git log --oneline -30` and ask them to identify the last known-good point.
- **Verify the good commit:**
  ```
  git stash
  git checkout <good-commit> --quiet
  [run test command -- must exit 0]
  git checkout - --quiet
  git stash pop 2>/dev/null
  ```
- If the test also fails on the "good" commit, this is not a regression. Fall back to standard debug flow (Phase 1).

### R.3 Run Git Bisect

Stash uncommitted changes first.

```
git stash
git bisect start HEAD <good-commit>
git bisect run <test-command>
```

The bisect will output the first bad commit when complete.

**Guardrails:**
- If bisect exceeds 20 steps: the range is too wide or the test is flaky. Abort with `git bisect reset` and fall back to manual debugging.
- If the test is flaky (inconsistent results on the same commit): abort and address flakiness first.
- If bisect encounters merge conflicts during checkout: abort and use manual `git bisect good/bad` stepping, skipping problematic commits with `git bisect skip`.

### R.4 Analyze the Breaking Commit

Once bisect identifies the first bad commit:

1. Read the full diff: `git show <first-bad-commit>`
2. Identify the specific change that caused the regression
3. Reset bisect: `git bisect reset`
4. Restore stashed changes: `git stash pop 2>/dev/null`

### R.5 Fix and Verify

The exact breaking commit is now known, making the root cause typically clear from the diff.

1. Apply a targeted fix informed by knowing which change broke things
2. Rename the reproducer test from `__bisect_test.*` to a permanent name (e.g., `regression-[description].test.ts`)
3. Run the same verification as Phase 4: targeted tests, full suite, original reproduction, CQ self-eval on production changes, Q self-eval on regression test

### R.6 Cleanup

Always execute, even if bisect was aborted:

```
git bisect reset 2>/dev/null
git stash pop 2>/dev/null
rm -f __bisect_test.ts __bisect_test.py __bisect_test.sh
```

---

## Backlog Persistence

If debugging reveals unrelated issues (code smells, missing tests, outdated patterns), do not fix them during the debug session. Persist each to `memory/backlog.md`:

1. Read `memory/backlog.md`. If missing, create it with the standard template.
2. Fingerprint each item: `file|rule-id|signature`. Deduplicate against existing entries.
3. Confidence 0-25: discard. Confidence 26-50: track. Confidence 51+: report.

Source: `debug/[date]`. Zero silent discards.

---

## Output: Standard Debug Report

```
## Debug Report: [issue summary]

### Reproduction
- **Expected:** [what should happen]
- **Actual:** [what happens instead]
- **Steps:** [how to reproduce]
- **Scope:** [always / intermittent / specific conditions]
- **Baseline:** [N] passing, [M] failing before fix

### Diagnosis

| # | Hypothesis | Evidence | Verdict |
|---|-----------|----------|---------|
| 1 | [most likely cause] | [file:line, log output, test result] | CONFIRMED / RULED OUT |
| 2 | [alternative cause] | [evidence] | CONFIRMED / RULED OUT |

**Confidence:** HIGH / MEDIUM / LOW -- [reasoning]

### Root Cause
[1-3 sentences explaining WHY the bug occurs, not just where]
File: [file:line]

### Fix Applied
```[language]
// Before:
[broken code]

// After:
[fixed code]
```

### Defense-in-Depth
[Guards added at which layers, or "N/A -- fix is self-guarding"]

### Verification
- Targeted tests: PASS ([N] tests)
- Full suite: PASS (no new failures vs baseline)
- Original reproduction: RESOLVED
- CQ self-eval: [score]/29
- Regression test Q self-eval: [score]/19

### Side Effects
[Any other paths affected, or "None -- change is isolated to [scope]"]

### Regression Test
```[language]
it('should [describe the bug scenario]', () => {
  // Reproduce the bug condition
  // Assert correct behavior
});
```
```

## Output: Regression Bisect Report

```
## Debug Report: [issue summary] (Regression Bisect)

### Regression Detection
- **Symptom:** [what stopped working]
- **Reproducer test:** __bisect_test.ts -> renamed to [final-test-name]
- **Good commit:** [hash] ([date] -- [message])
- **Bad commit:** HEAD ([hash])
- **Bisect steps:** [N] steps across [M] commits

### Breaking Commit
- **Commit:** [hash] -- [message]
- **Author:** [author] ([date])
- **Files changed:** [list]
- **Root cause:** [1-3 sentences -- what in this commit broke the behavior]

### Fix Applied
```[language]
// Before (from breaking commit):
[code that caused regression]

// After (fix):
[fixed code]
```

### Defense-in-Depth
[Guards added at which layers]

### Verification
- Targeted tests: PASS ([N] tests)
- Full suite: PASS (no new failures)
- Original reproduction: RESOLVED
- CQ self-eval: [score]/29
- Regression test Q self-eval: [score]/19
```

---

## Knowledge Curation

After the fix is verified, run the knowledge curation protocol from `knowledge-curate.md`:
```
WORK_TYPE = "research"
CALLER = "zuvo:debug"
REFERENCE = <git SHA of the fix commit>
```

Debugging often uncovers gotchas and codebase-facts that are highly valuable for future sessions.

---

## Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to completion.

---

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Bug category classified and printed: [logic/async/data/integration/test-failure]
[ ] Root cause identified at specific file:line (not just symptom)
[ ] Original reproduction confirmed RESOLVED
[ ] Regression test written with Q self-eval (>=16)
[ ] CQ self-eval on modified production files
[ ] Adversarial review ran on staged diff
[ ] Backlog updated
[ ] Run: line printed and appended to log
```

## Completion

After Phase 4 or Phase R verification passes:

```
DEBUG COMPLETE
----------------------------------------------------
Issue: [summary]
Mode: standard | regression-bisect
Root cause: [1-line explanation]
Breaking commit: [hash -- message] (regression mode only)
Files fixed: [list]
Regression test: [test file path]
Verification: targeted PASS | full suite PASS | repro RESOLVED
CQ: [score]/29 | Q: [score]/19
Confidence: HIGH / MEDIUM / LOW
Backlog: [N items added | "none"]

Run: <ISO-8601-Z>\tdebug\t<project>\t<CQ>\t<Q>\t<VERDICT>\t-\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS / WARN / FAIL / BLOCKED / ABORTED only.
CQ: from Phase 4.6 CQ self-eval on production fix (`N/29`).
Q: from Phase 4.5 Q self-eval on regression test (`N/19`).
TASKS: `-` (debug does not track task count).
DURATION: mode label (e.g., `standard`, `regression-bisect`).
NOTES: 1-line root cause summary (max 80 chars).

Next steps:
  zuvo:review [fixed-files]  -- verify fix quality
  git commit -m "fix: [issue summary]"
----------------------------------------------------
```

---

## Tips for Better Input

- **Share the full stack trace**, not just the last line. The root error is usually deeper in the chain.
- **"This used to work"** -- use `zuvo:debug --regression` for automated git bisect.
- **"Only in prod"** -- likely a missing env variable, production data edge case, or timezone issue.
- **"Random / flaky"** -- likely a race condition, shared mutable state, or test-order dependency.
