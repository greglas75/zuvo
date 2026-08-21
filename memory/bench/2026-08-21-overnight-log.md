# Overnight run — 2026-08-21 → 08-22

Goal set at 17:15: **a full `write-tests` run under 20 minutes, quality held.** Then move down
the file list and optimise as far as it goes.

Everything below is measured on the rig (coding-vps, containers, frozen mutant sets / StrykerJS),
not argued. Where a number is a single run rather than a median, it says so.

---

## Where the time actually goes

Every turn of 23 runs was attributed to **what the agent did** — the tool call, and for a bash
turn the program that command invokes. Nothing reads narrative text: the skill's own prose
contains every phase name, so a text-matching detector scores a run that merely *loaded* the
skill as having run every phase. That mistake has already produced two confident, false
conclusions in this project.

Median wall per bucket, per arm:

| bucket | naked (no skill) | v3 (main, was) | v7 | v8 |
|---|---|---|---|---|
| **typecheck** | **122s — 54% of its wall** | 173s | — | 247s (max 722s) |
| **mutation** | — | 8s | 136s | 270s (max 1089s) |
| suite-run | 14s | 124s | 130s | 97s |
| think (no tool call) | 46s | 106s | 82s | 129s |
| bash-other | 18s | 148s | 138s | 192s |

Two things fall out of this that no amount of reading the skill would have suggested:

**1. The largest block in every arm — including the arm with no skill loaded — is `tsc`.**
Agents reach for a project-wide `tsc --noEmit` unprompted. On this project that spend buys
almost nothing: `apps/api` carries **6050 pre-existing type errors**, so a run's own two
diagnostics arrive buried in 6048 it did not cause.

**2. The most-repeated single bash command in the whole corpus is zuvo's own `ZUVO_BASE`
resolver** — 30 invocations of the four-line sed recipe from `env-compat.md`. In a container it
resolves to nothing (there is no `installed_plugins.json`), after which the transcripts show an
agent improvising: `find / -iname zuvo`, `ls ~/.claude/skills`, `cat` the helper to check whether
it is real.

---

## What shipped

### v7 — verify once, let the native runner measure (`7e1c88e`)

| arm | kill (med) | RED | wall (med) | tokens (med) | turns (med) |
|---|---|---|---|---|---|
| v3 (n=9) | 88.4% | **1/9** | 698s | 2.70M | 107 |
| **v7 (n=5)** | 88.9% | **0/5** | **492s** | **1.82M** | **81** |

Median quality is unchanged and inside the rig's variance. What moved is the tail: worst scored
run 81.8% → 87.9%, RED suites gone, a third off the cost.

### `~/.zuvo/verify-tests` — one command, one verdict (`9135b5e`, `ed59fe4`, `590b72d`, `b76a294`)

Turn count across 28 runs tracks one variable almost perfectly: how many times a run re-issued a
verification command it had already issued. 0 repeats → 30-111 turns. 9-14 → 193-321. 28-30 →
395-485. The repeated commands are always the same four, because the skill asked for four
separate fix-and-rerun loops.

Prose could not close it — v7 says "run it ONCE, do not iterate" and a run called the gate five
times anyway. So it is a command: suite + coverage gate + scoped coverage + scoped typecheck +
StrykerJS in one process, one block listing every open gap, and it owns its own stop condition
(three passes, then `BUDGET EXHAUSTED` → record the remainder, do not iterate).

- **jest works, verified on real `rs_be`**, not on a fixture: 191 mutants, scoped by a generated
  config that anchors `testMatch` on `<rootDir>` — Stryker runs in a sandbox copy, so an absolute
  path matches nothing and the failure reads as a broken mutation setup.
- **Typecheck folded in and scoped**: the tsconfig that *owns* the file, incremental (57s cold,
  16s warm), and only errors in the written spec are gaps. Production-file errors are printed and
  backlogged; the other 6048 are counted and dismissed.
- **Mutation deferred** until the gate and coverage stop reporting gaps — measuring mutation on a
  first pass with 43 open rows measures a suite that is about to be rewritten.
- End to end on the rig: **78s → 59s cold, 21s warm**, and the warm pass now includes a typecheck
  the old shape did not have.

### `~/.zuvo/zuvo-base` — the resolver is a program (`d064ae5`)

Ordered, deterministic, works in a container. Stale `$ZUVO_BASE` loses to a real install; the
SHA-named cache sibling never outranks a semver directory; failure writes to stderr and nothing to
stdout, so `X="$(zuvo-base)"` is `""` rather than a diagnostic used as a path. Benefits all 47
skills that shell out, not just this one.

---

## Measured, and NOT shipped as-is

**v8 is a cost regression.** Same quality, 3.4× the wall, 2.4× the tokens:

| arm | kill (med) | RED | wall (med) | tokens (med) |
|---|---|---|---|---|
| v7 | 88.9% | 0/5 | 492s | 1.82M |
| v8 | 88.9% | 0/5 | 1684s | 4.39M |

Two causes, both now fixed and being re-measured as v9:

- **Only 2 of 5 runs used the helper at all.** Three read `ZUVO_BASE=` as "the helper will not
  work" and took the fallback I had left open — inside containers where the helper ran correctly
  on the first try. "Helper absent" now has exactly one test: `[ -x ~/.zuvo/verify-tests ]`.
- **Mutation ran on every pass, including the useless ones.** Now deferred.

---

## The finding the wall-clock buckets could not show

Reading the v9 transcripts rather than their timings turned up the reason several runs were
expensive, and it is not a phase at all:

> **The helper's cold invocation crossed the Bash tool's default 120-second limit.**

Inside a loaded container the harness backgrounds a call that long and hands back a task id
instead of the output. Every run that hit it then built a polling loop — `sleep 90; kill -0
<pid>`, `sleep 60; echo tick`, `tail /tmp/verify-out.txt` — four to six turns spent waiting for
output that one turn returns. A shell `timeout 590` prefix does not help: it bounds the program,
not the harness.

Two fixes, and the second is the one that matters:

- the gate and the coverage run execute concurrently (independent processes over the same green
  suite);
- **the typecheck joined mutation behind the cheap checks.** Both describe the *finished* suite,
  and a pass still reporting uncovered rows is looking at one about to be rewritten — so 57s of
  `tsc` and 270s of Stryker no longer run on a pass whose result they cannot inform.

Measured, same file, same manifest: **a first pass with gaps open went 78s → 5s.** The expensive
measurements still run, on the pass where the suite is worth measuring. The skill also now tells
the agent to give the call `timeout: 600000`, so the final pass — which does run both — cannot hit
the same wall.

There is a second-order lesson here worth keeping. Wall-clock attribution found *typecheck* and
*mutation* as the big blocks, and both were real. But the reason those blocks were expensive in
turns rather than merely in seconds was a harness limit that no bucket could name. Timings say
where the time went; transcripts say why.

## The result that decides the 20-minute question

Across **33 scored runs** on CASE-01, turns and mutation kill correlate at **Spearman +0.73**.
Read alone, that says working longer buys coverage and the 20-minute target is a trade.

Split by arm, it mostly disappears:

| arm | cheap half → dear half (median kill) |
|---|---|
| naked | 85.4% → **83.8%** |
| zuvo-v4 | 89.4% → **88.9%** |
| zuvo-v7 | 88.4% → 88.9% — *60 turns scored 88.9; 288 turns scored 88.9* |
| zuvo-v3 | 87.4% → 88.9% |
| zuvo-v8 | 87.9% → 89.9% |

Median effect: **about half a point for 3.2× the turns**, and negative in two arms. The +0.73 is
a *between-arm* effect — better skills cost more turns and score more — not a dose-response
within a skill.

The other half of the picture is worse than neutral: **three of the four suites that came out RED**
(fail on unmutated source, scored 0, worthless) were among the most expensive runs in the corpus —
358, 395 and 485 turns. Past the plateau, effort buys variance.

So capping the run is close to free, and the cap has to be owned by a program rather than by the
agent's sense of when it is done. `verify-tests` now carries two: three passes, and a **15-minute
clock from the first pass**, recorded in the state file so a long detour between passes cannot
reset it. Every pass prints `pass N of 3   X.X of 15 min`. On expiry the remaining survivors are
recorded with their IDs and the file finishes — which is the correct outcome, not a failure to
try hard enough.

## Open at the time of writing

- **v9** (escape hatch closed + typecheck folded + mutation deferred), CASE-01, n=5. Three
  finished at **648s, 1148s, 1214s** — two of three under the 20-minute target, against v8's
  1684s median. The two slow runs are the ones that hit the 120-second backgrounding above.
- **v10** carries everything: the closed escape hatch, the folded+deferred typecheck, deferred
  mutation, the include de-duplication, `zuvo-base`, and the 5-second early pass. Queued.
- **CASE-05 = shield** (`rs_be`, jest, NestJS): corpus entry created, repo + deps + Stryker
  installed on the rig, incumbent baseline scored. The human-written spec kills **34.6%**
  (66/191 mutants, 99 no-coverage) — 35 of its 50 tests are `skip`ped. Large headroom.
- The rig is now multi-repo: a case names its own checkout, and the green/red selfcheck picks the
  runner and directory from the case rather than assuming `apps/api` + vitest.
