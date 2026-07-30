# In-Run Production Bug Fix Protocol (write-tests Step 4.5)

> A `write-tests` run that surfaces a real production bug FIXES it before the
> file closes — it does not backlog it and hand off. Mirrors `zuvo:refactor`
> Phase 3.5 ([[refactor-fix-in-run]]) and `zuvo:review`'s no-silent-deferral
> rule ([[no-silent-backlog-deferral]]): the file leaves **tested AND
> correct** ([[proper-solutions-only]]).

**Trigger:** Step 1.5 (bug scan), Step 2 (red truthful test), or Step 4
(adversarial) surfaced a confirmed-real production bug — verified against
source; false positives are rejected with an attack-vector refutation, never
carried here.

## Disposition is fix-SCOPE, not severity

Severity decides merge-blocking and follow-up breadth; it does NOT decide
fix-now-vs-defer. A HIGH-severity security bug with an in-scope fix is fixed
now, exactly like a trivial one:

| Situation | Action |
|-----------|--------|
| Real bug, fix within the production file under test (or a clearly-owned helper) | **FIX now.** Any size. Then flip the regression test to assert corrected behavior. |
| Fix needs changes OUTSIDE the test's production target (cross-module reorder, shared guard, schema/migration) | Escalate **loudly** to `zuvo:build` / `zuvo:security-audit` with file:line + repro — AND fix any clearly in-scope portion. Record the escalation; never a silent backlog row. |
| The "bug" is a behavior/product DECISION (partial-result vs hard-error, etc.) | Interactive: ask. Batch/`--auto`: pick the safe default, log it, proceed. Backlog only if the user declines. |
| HIGH/CRITICAL **security** bug, in-scope | Fix now AND surface to `zuvo:security-audit` for breadth. The audit is follow-up, never a substitute for the fix. |

## Characterization-first (keeps Step 2 green without lying)

If the strongest honest regression test would be RED against current
production code: do NOT weaken the assertion, and do NOT park the bug. Write a
**characterization test** documenting current (buggy) behavior so Step 2 stays
green and the bug is provably captured — then fix it here and flip the test to
the corrected contract.

## Stacked-commit structure (preserves characterization purity)

1. **Commit 1** — the test file written against current behavior. For a buggy
   path, this is the test that documents/exposes the bug.
2. **Commit 2** — the production fix + the regression test flipped to the
   corrected contract (red on the commit-1 SHA, green now).

Together they prove "this is what it did → this is the fix." Use the
auto-commit policy already in effect. Never collapse the two concerns into one
hidden edit.

## After the fix

- Terminal state is `PASS` (bug fixed, regression green) — NOT `FAILED`.
- The production edit changed the file hash: rebuild the affected manifest
  rows, re-freeze, re-run the final coverage validation, and re-run the blind
  audit on the new (production, test) hash pair — the freshness guard
  invalidates every prior CLEAN.
- Only genuinely out-of-scope or user-declined items remain in
  `memory/backlog.md`. Record fixed files in `Files tested: ... ([J] fixed)`
  and in the Step 2b review artifact.
