# write-tests PHASE 0/1 — read the includes in one message instead of one per turn

Reverted in 84f5c39. Kept because the result generalises past this one edit.

blob 3617b230c129   (post-edit blob of skills/write-tests/SKILL.md at b58afe7)
case CASE-01 (apps/api/src/modules/runner/runner-maxdiff-score-contract.ts, 99 mutants)

| arm | kill | billed | turns |
|---|---|---|---|
| v3 — loading block untouched | 87.9% | 941k | 46 |
| v5 — "read the set in ONE message" + measured rationale | n/a | n/a | 281 |

v5's turn count was read live from the container's own transcript; the run was still
harvesting when the call was made, and 281 vs 46 needs no third digit to decide.

## What it was aiming at, and hit

The target was real and the fix worked: a v4 run spent 76 of its 159 shell calls on
`cat`/`ls`/`grep` against the skill's own includes, ~3.3M tokens, before touching
production code. Under v5 that pathology is **gone** — one `cat` in the entire run, and
it was for `tsconfig.base.json`. The agent switched to the `Read` tool as intended.

## What it did instead

Total turns went 46 -> 281. The waste it removed was replaced several times over
somewhere else.

## CORRECTION (same day) — this comparison does not measure what it claimed

The turn counts above are real. The conclusion drawn from them was not.

Checking which of the pipeline's gates each run ACTUALLY executed — counting markers the
agent itself emitted, not markers found anywhere in the transcript, which also contains the
skill text the agent read:

| arm | turns | Agent dispatches | markers the agent EMITTED |
|---|---|---|---|
| v2 | 135 | 1 | Adversarial x1 |
| v3 | 46 | 0 | **none** |
| v5 | 281 | 0 | Blind x3, Adversarial x4 |

**v3 emitted nothing.** It classified, wrote tests, and stopped — no blind audit, no
adversarial, no writer dispatch, though its own text mandates the dispatch. Its 46 turns are
the cost of a run that skipped verification, not the cost of an efficient one. v5's 281 turns
bought work v3 never did.

So "the edit multiplied turns 46 -> 281" is comparing a compliant run against a
non-compliant one and attributing the difference to the edit. The same objection applies to
the 46 -> 290 figure recorded for 64a8bdd.

**What actually varies run to run is how much of the pipeline the agent executes.** That was
already visible elsewhere in this benchmark — the skill did not fire at all in 3 of 8 runs on
a neutral prompt — and it was not connected to the turn counter until now.

Turn count alone is therefore not an interpretable metric across single runs. Any future
comparison must report emitted-marker counts alongside turns and compare only runs at equal
compliance, or use N>=3 per arm.

The revert stands, on the narrower ground that the edit is unmeasured rather than harmful.
