## Phase 2: Test Handling

Skip for VERIFY_COMPILATION test mode.

### Load Conditional Files

```
Phase 2: testing.md -- READ
Phase 2: test-edge-cases.md -- READ (WRITE_NEW, IMPROVE_TESTS, or CHARACTERIZE_GAP)
```

### Test Mode Execution

**RUN_EXISTING:** Run the existing suite through the contract, so the command is typed once and the
lock is measured rather than asserted:

```bash
~/.zuvo/refactor-contract baseline --mode existing "<the command that runs the suite>"
```

It records the command, the parsed pass/fail counts and the pre-refactor SHA into
`prove.characterization`, and exits non-zero if the suite is not green — the refactoring must not
start from a broken state, and this is what makes that a fact rather than a claim. Later,
`~/.zuvo/refactor-contract recheck` re-runs the SAME stored command and writes the before → after
comparison into `prove.characterization_after` (with `evidence.characterization_after`), exiting 1 on drift.

Why the command and not a hand-written value: the field used to hold whatever sentence the run typed
into it, and the commit gate only checks that it is non-empty. Measured across 25 refactor sessions,
this command is also the single most-repeated shell shape in the skill — 66 re-issues of its
environment prefix alone. The MODE stays yours to choose; the result stops being yours to write.

`baseline` and `recheck` wait for their subprocess and return its result. The host may still yield
before completion; use its supported long wait/notification mechanism. One CLI invocation does
not guarantee one model/tool round-trip. Do not repeatedly request unchanged status.

### Freeze the characterization package

Before `baseline`, record the explicit test paths and command, including coverage scope for any
planned new helper. `recheck` compares the recorded pass count as well as failures. Keep these
characterization files unchanged after the baseline; add new direct helper tests in a separate
file and run them with a separate command. Include that future file in the scope fence now.
Never overwrite the old-code baseline after extraction to hide an increased test count or drift.
Use content-keyed evidence to avoid repeating an unchanged recheck after report-only edits.

**CHARACTERIZE_GAP:** The existing test does not exercise every unit being moved (`coverage_gap > 0`). Close the gap BEFORE any production edit:
1. For **each** uncovered unit in `uncovered_units`, write a characterization (pin-down) test that executes it with a representative input and asserts on real output — mount/render the component, or call the function, with a payload that reaches actual logic (not an empty-state/early-return path). Source representative inputs from existing fixtures, sample data, or recover them from git history (e.g. `git show <sha>:<path>`) when they were deleted; never invent shapes the code never sees.
   - The bar is "fails loudly if behavior changes," not full Q1-Q25. A smoke test that mounts the unit and asserts `does not throw` + a stable output snapshot is the minimum; prefer a value assertion where the unit returns something checkable.
   - A parameterized table over the units (one case per unit) is the canonical shape for SPLIT_FILE / GOD_CLASS.
2. Run the new tests against the **pre-refactor** code and confirm they pass. This is the lock — they must be green on the OLD code, or they are not characterizing current behavior. If a unit genuinely cannot be exercised (truly dead), record it in the contract as `dead:<unit>` with evidence and exclude it from the move; do not silently skip it.
   - For a private unit that will become a new export, characterize its existing consumers on
     old code and measure that the moved lines execute. After extraction, test the new export
     directly in the separate planned test file. A test that only runs after extraction cannot
     substitute for an old-code baseline. Byte identity complements this evidence; it does not
     make an unrun pre-change test green. If no consumer can exercise a moved unit, resolve that
     gap before editing rather than inventing an `extracted-identical` baseline.
2.5. **Probe the lock before trusting it** — per `../../../shared/includes/test-mutation-probes.md`,
   run 2-3 mutation probes against the **pre-refactor** unit and confirm the new
   characterization tests KILL them. Every probe must be reverted byte-exact; the
   pre-refactor baseline you already established in step 2 is the restore target, so this
   costs one extra targeted test run per probe and nothing else.

   This step exists because step 2 does not prove what the bar in 1 claims. Green-on-old
   proves the test does not CONTRADICT current behaviour. It does not prove the test would
   NOTICE a change — and the bar one line up is literally "fails loudly if behavior
   changes", with the same paragraph permitting `does not throw` as the minimum. A
   `does not throw` smoke test is green on the old code, green on the new code, and green
   on a version that returns the wrong value: it passes the lock while characterizing
   nothing. Measured on a real suite 2026-08-09 (translation-qa `resync-units`): 17 green
   tests, and a one-character mutation to the tie-break that decides which unit a
   proofreader's work lands in survived untouched — in a file whose own test header names
   that exact risk first.

   A probe that SURVIVES means the test is a shape assertion, not a lock: strengthen it and
   re-probe **before** any production edit. Record `prove.characterization_probes =
   "<killed>/<total>"`. This is part of SAFETY gate 1, not an addition to it — an
   unverified lock is the gate believing its own claim.

3. Apply Q1-Q25 self-eval on the new tests. Only after `coverage_gap` reaches 0 (every moved unit now exercised, or proven dead) does execution proceed.
4. Record `test_audit_after` with the closed gap, **and record the characterization LOCK in the CONTRACT `prove` block NOW — before any production edit**: `prove.characterization = "green:<pre-refactor sha7>:<N>u:<test path>"` — a STRING (like the other prove fields) naming the pre-refactor SHA the pin-down tests were green against, the unit count, and the test path, with `coverage_gap: 0`. The Prove step is not only blind_audit + adversarial recorded at commit time — the characterization lock is the FIRST proof and belongs in the CONTRACT the moment tests are green on the old code (between green tests and the move), not backfilled at commit. **This is a gated artifact, not advice: the `refactor-safety-gate` hook and the completion self-check both BLOCK on a missing/`not_run` `prove.characterization`** (added after the 2026-07-09 skill-eval run proved prose alone gets skipped).

**VERIFY_MOVE:** No characterization authoring — the proof is that nothing changed. Execute in this
order, BEFORE the move and again after: (1) declare the regression fence over the units being moved
and the barrel path; (2) run the consumer suites and record the green baseline SHA; (3) do the move;
(4) re-prove byte identity per symbol, re-run the cycle check, re-run the consumer suites. Record
`prove.characterization = "verify-move:<pre-refactor sha7>:<N>u:<consumer suite path>"` at step 2 —
same timing rule as every other mode, before the first production edit, never backfilled. If step 4
shows any symbol whose bytes moved, the tier was wrong: revert, re-route to CHARACTERIZE_GAP, and
say so in the run log rather than downgrading the claim in place.

**WRITE_NEW:** Write tests for the target file before refactoring. The tests capture the current behavior so that the refactoring can be verified against them. Apply Q1-Q25 self-eval on the new tests. Same coverage bar as CHARACTERIZE_GAP: every unit being moved must be exercised, not just the file's entry point. **Same LOCK recording as CHARACTERIZE_GAP step 4** — the moment the new suite is green on the PRE-refactor code, write `prove.characterization = "green:<pre-refactor sha7>:<N>u:<test path>"` into the CONTRACT, BEFORE any move edit (the commit gate blocks without it; this mode is where the 2026-07-09 eval caught the backfill gap).

**IMPROVE_TESTS:** When the refactoring type is IMPROVE_TESTS (target is a test file):
1. Run Q1-Q25 self-eval on the existing tests to identify gaps
2. Classify gaps and plan improvements
3. Execute structural cleanup first, then assertion strengthening
4. Re-score -- gate: improvement of at least 2 points (or reach 16+/25)

### Test Results Display

Show the test results, then proceed to execution. No approval gate.

---
