# Bench records

One record per **control-block** edit — the sections of a skill that decide what an
agent loads, how it classifies, and which gates it must pass. Everything else in a
skill needs no record.

A record exists because reasoning about these blocks has a measurable failure rate.
On 2026-08-20 a 29-line rewrite of `write-tests` Step 2's writer payload shipped on
argument alone; the rig then measured **11.4M billed tokens and 290 turns** against
the reverted version's **941k and 46**, for **+1.0pp** mutation kill. The argument was
sound. The outcome was a 12x cost regression, because prose that reads like "carry
five things" changes how thoroughly an agent works, not merely how much text it holds.
Only running it could have shown that.

## Contract

`hooks/control-block-bench-gate.sh` blocks an agent push that edits a control block
unless some file here contains the **post-edit blob id** of the changed file. Keying on
the blob rather than the commit means evidence cannot be recycled across edits: change
the block again, and the old record stops counting.

A record must carry, for the changed version **and** the version it replaces:

| field | why |
|---|---|
| kill-rate | did the change help |
| billed tokens | what it cost |
| turn count | the tell for a behavioural blow-up — turns move before tokens do |

One corpus case is the floor. Run-to-run variance on this rig has been measured as
high as 14pp, so a quality difference under ~10pp is not a result yet — say so in the
record rather than rounding it into a claim.

## Format

```markdown
# <what changed>
blob <12-hex post-edit blob id of the changed file>
case CASE-0N (<file>, <N> mutants)

| arm | kill | billed | turns |
|---|---|---|---|
| before | 87.9% | 941k | 46 |
| after  | 88.9% | 11,421k | 290 |

verdict: <ship | revert | inconclusive> — <one line>
```

Get the blob id with `git rev-parse HEAD:<path> | cut -c1-12`.

Human override, attributable and logged: `ZUVO_ALLOW_UNMEASURED_CONTROL_EDIT=1`.
