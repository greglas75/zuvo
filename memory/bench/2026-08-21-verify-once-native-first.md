# write-tests: run the coverage gate ONCE, and reach for the native mutation runner first
blob e2037873d999
case CASE-01 (apps/api/src/modules/runner/runner-maxdiff-score-contract.ts, 99 mutants)

Three edits, measured together as one arm (v7) because they change one behaviour — how many
times a run re-verifies before it accepts an answer:

1. Step 2.5 gains "Run it ONCE. Do not iterate it." The gate proves inventory rows have
   evidence attached; it cannot prove the evidence detects anything. Iterating it optimises
   the proxy.
2. Step 3.3 makes the native runner the PRIMARY measurement rather than a footnote after the
   hand probes — a scoped StrykerJS run generated 235 mutants in ~71s of CPU and zero
   conversational turns, against 3-6 hand probes that each cost a turn.
3. Step 3.3 permits a workspace-local `npm install --no-save` when no runner is configured,
   and raises the in-run survivor cap from 3 to 5 (a real runner surfaces 200+ mutants, so the
   cap should reflect what a fix round can close, not what a hand-probe set could produce).

| arm | kill | billed | turns |
|---|---|---|---|
| before (v3) | 88.4% | 2,700k | 107 |
| after  (v7) | 88.9% | 1,820k | 81 |

Medians across n=9 (v3) and n=5 (v7) runs on the same case, same corpus, same container image.

The median quality difference (+0.5pp) is well inside this rig's variance and is NOT a result.
Three things outside the variance are:

- **RED suites: 1/9 -> 0/5.** A suite that fails on unmutated source scores 0 and is worthless;
  v3 produced one, v7 none.
- **Worst case, not median.** v3's weakest scored run was 81.8%; v7's was 87.9%. The floor moved
  six points while the median did not move at all.
- **Cost: -33% tokens, -30% wall, -24% turns**, with the spread narrowing (v7 kill range
  87.9-88.9, sd ~0.5; v3 range 81.8-90.9, sd ~3.3).

verdict: ship — quality unchanged at the median, materially better at the floor, and a third
cheaper. The gain is consistency, not peak score.

## What this arm did NOT fix

v7's own rule is prose ("run it ONCE"), and run v7-r5 called the gate five times anyway, took
288 turns and 9.4M tokens. Across all 28 runs on this case, turn count tracks one variable
almost perfectly: how many times a run re-issued a verification command it had already issued
(0 repeats -> 30-111 turns; 9-14 -> 193-321; 28-30 -> 395-485). Telling an agent how many times
to verify still leaves it deciding when it is done. See `2026-08-21-verify-tests-helper.md`.
