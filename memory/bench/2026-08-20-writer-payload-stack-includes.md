# write-tests Step 2 writer payload — adding the stack technique includes

Reverted in `9bd3658`. Kept as the record of why, and as the shape a bench record takes.

blob d0388ba3f63d   (post-edit blob of skills/write-tests/SKILL.md at 64a8bdd)
case CASE-01 (apps/api/src/modules/runner/runner-maxdiff-score-contract.ts, 99 mutants)

| arm | kill | billed | turns | wall |
|---|---|---|---|---|
| v3 — contract-only payload | 87.9% | 941k | 46 | 376s |
| v4 — payload as a 5-item list incl. stack includes | 88.9% | 11,421k | 290 | 2672s |
| v2 — no writer isolation at all | 88.9% | 3,440k | 128 | 808s |

CASE-04 under the same edit: 20,499k billed, 4084s, 51KB of tests for a 12.9KB source.

verdict: **revert** — +1.0pp for 12x tokens and 7x time, and strictly worse than the
version isolation was meant to improve on (v2: same kill, a third of the cost).

What the numbers say that the argument did not: the write phase alone went 662k→3,450k
and 33→103 turns. The extra ~16KB of includes cannot account for that. Restating the
payload as an enumerated list changed how exhaustively the agent worked — a behavioural
change, not a context-size change. Turn count moved first and moved most; it is the
cheapest early tell.

Still open, and the reason this is a revert rather than a rejection: the edit was
justified by frontend runs that turned out not to have invoked the skill at all
(no Skill tool call, no classification line, no contract on disk). Whether the stack
includes help on a component or a hook has never actually been measured. The follow-up
experiment runs `v3clean` vs `v3b` (one added clause, no list, no paragraph) on CASE-02
and CASE-03, with v4 as the control arm.
