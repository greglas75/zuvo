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

## The generalisation, which is the reason this record exists

This is the SECOND edit to a control block that reduced nothing and multiplied turns:

| edit | intent | turns before -> after |
|---|---|---|
| 64a8bdd — payload as a 5-item list | give the writer technique | 46 -> 290 |
| b58afe7 — read the set in one message | cut redundant reads | 46 -> 281 |

Two different authors' intents, two different sections, near-identical outcome. The
common factor is not what the text SAID — one added material, one removed work. It is
that both ELABORATED a block that governs how the agent proceeds. Adding structure and
rationale where the agent is deciding how to work appears to make it work more
exhaustively, and turn count is what that costs.

Provisional rule for the next attempt: to cut turns, change what the agent must DO
(fewer mandated steps, batched by a script it executes), not how the doing is DESCRIBED.
Prose about efficiency is still prose the agent must weigh, and weighing costs turns.
