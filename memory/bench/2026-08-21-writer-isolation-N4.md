# Writer isolation — measured properly, N=4 per arm

blob 6eb6d1a8b5ce   (skills/write-tests/SKILL.md at 60656a9)
case CASE-01 (apps/api/src/modules/runner/runner-maxdiff-score-contract.ts, 99 mutants)

Only runs that actually executed >=3 pipeline gates are compared, so the arms are matched on
what they DID, not merely on which version they carried.

| arm | N | turns med [range] | billed med [range] | kill med | green suites | gates avg |
|---|---|---|---|---|---|---|
| v2 (no isolation) | 4 | 265 [86-486] | 8.6M [1.8-22.5] | — | **2/4** | 4.5 |
| **v3 (isolation)** | 4 | **79 [53-196]** | **1.8M [1.3-5.1]** | 87.9% | **5/5** | 4.5 |
| v4 (+ stack includes) | 4 | 190 [90-298] | 5.9M [2.0-11.4] | 88.9% | 4/4 | 4.8 |
| v6 (+ load-includes helper) | 3 | 209 [202-360] | 6.0M [5.5-13.4] | — | 0/1 | 5.0 |

verdict: **ship v3, keep v4 and v6 reverted** — 4.8x cheaper, 3.4x fewer turns, twice the
reliability, quality unchanged, at equal gate coverage.

## Why this needed N=4 and three attempts at the instrument

The same claim was made on 2026-08-20 from ONE run per arm and was not defensible then, for
three separate reasons, each of which produced a confident wrong answer:

1. **Noise.** Five repetitions of the identical configuration spanned 46-196 turns and
   941k-5.1M tokens — 4.3x and 5.5x. Most single-run differences called regressions that day
   sit inside that.
2. **A compliance detector that read the skill's own text.** Grepping a transcript for
   "INVENTORY FROZEN" matches the file that MANDATES the inventory, not a run that froze one.
   Conclusion drawn: "the gates almost never fire." False.
3. **A compliance detector that matched literals.** Fixing (2) by reading only the agent's own
   words, but matching exact strings, scored a run reporting "froze a 47-row manifest" and
   "Mutation probes: 3/3" as having run nothing. Conclusion drawn: "v3 never runs the
   pipeline." Also false — and it is the opposite error to (2), from the same instrument.

The baseline used all day — v3 at 46 turns / 941k — was the one run in five that genuinely
did skip the gates. Every ratio computed against it was wrong.

Matching on meaning (case-insensitive alternates per gate) and requiring >=3 gates before an
arm enters the comparison is what made the numbers above mean anything.

## What is now measured, and what is still not

Measured: cost, turns, clean-pass reliability, gate coverage, kill-rate — CASE-01 only.
Not measured: whether this holds on a component, a hook, or a 88-branch module. The frontend
cases have N=1 and are not evidence.
