# Overnight run — 2026-08-21 → 08-22

Goal set at 17:15: **a full `write-tests` run under 20 minutes, quality held.** Then move down
the file list and optimise as far as it goes.

Everything below is measured on the rig (coding-vps, containers, frozen mutant sets / StrykerJS),
not argued. Where a number is a single run rather than a median, it says so.

---

## Bottom line

**Quality moved for the first time in this benchmark.** Two independent five-run batches agree:

| arm | kill (med) | RED | wall (med) | vs control |
|---|---|---|---|---|
| naked (no skill) | 84.8% | 0/4 | 231s | — |
| **v7** — on `main` now | 88.9% | 0/5 | 492s | +4.1 |
| **v9 / v10** | **90.9%** | 0/5 | 1214s / 2353s | **+6.1** |

Against a per-file ceiling of ~91.9% (eight mutants survive every arm ever run on this file),
90.9% is one non-equivalent mutant from the top.

**The 20-minute target is a tail problem, not a median problem.** v7's median is 8 minutes and
v9's is 20; what breaks the target is a minority of runs at 60+ minutes. Every fix tonight
attacks a specific, measured cause of that tail rather than trimming work:

| cause | measured | fix |
|---|---|---|
| four separate fix-and-rerun loops | 0 repeats → 30-111 turns; 28-30 repeats → 395-485 | one command, one verdict |
| a call over the Bash tool's **120s** limit gets backgrounded | runs then poll for their own output, 4-6 turns each | early pass **78s → 5s** |
| project-wide `tsc` on a repo with **6050** pre-existing errors | largest bucket in EVERY arm, incl. the control | scoped, incremental, deferred |
| `ZUVO_BASE` resolved by a 4-line sed recipe | most-repeated command in the whole corpus (30×) | `~/.zuvo/zuvo-base` |
| the coverage gate run twice, once per document | 15 direct calls in one run | includes defer to the helper |
| a deferral reported `SKIP`, which means "do it by hand" | **677s over 24 turns**, 29% of one run's wall | `DEFER` is its own state |

**And the misses have a shape.** Comparing per-mutant survivors across 39 suites: what separates
an 88% suite from a 91% one is boundaries the tests never sat exactly on — a deleted `throw`
survived 34 of 39 suites, `< ` changed to `<=` survived 27, `[0]` shifted to `[1]` survived 15.
`test-coverage-gate.py boundaries` now derives those obligations from the source instead of from
the code-type classification that was gating the existing rule.

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

## What the missing points are actually made of

Kill rate is a scalar; it cannot say WHAT the extra points consist of. Comparing per-mutant
survivor sets across all **39 scored suites** for CASE-01 answers it, and the answer changes what
is worth optimising.

**Eight mutants survive every single arm** — including the best. Equivalent-mutant candidates
(or a gap the whole approach shares). That puts the practical ceiling on this file at **~91.9%,
not 100%**, which means v9's 90.9% sits **one non-equivalent mutant from the ceiling**. There is
essentially nothing left to win on CASE-01, and further quality work belongs on the other cases,
where kill rates are 61-78%.

**The mutants that separate an 88% suite from a 91% one are all boundaries the tests never sat
exactly on:**

| mutant | survived in |
|---|---|
| `throw` deleted outright (L187) | **34 of 39 suites** |
| `finiteValue < 0` → `<=` (L60) | 27 of 39 |
| literal `0` → `1` (L60) | 27 of 39 |
| `normalized[0]` → `normalized[1]` (L185) | 15 of 39 |
| `\|\|` → `&&` (L17) | 12 of 39 |

Not exotic. Not deep semantics. Off-by-one and error-path removal.

And zuvo already tells writers to do this — `test-edge-cases.md` says *"exact threshold N, N-1
(should NOT trigger), N+1 (should trigger)"*. The rule lives in a table row keyed on **code
type**, so a bare `value < 0` inside a pure function never triggers it. Classification decides
whether the rule applies, and classification happens *before* the comparisons are known. That
ordering is the bug, not the wording.

`test-coverage-gate.py boundaries --production <file>` removes the ordering problem by reading
the source: every relational operator, boolean operator, `throw`/`raise` and literal index becomes
an inventory obligation, each with the specific case that kills its mutant — the input where both
sides are EQUAL, the operand that alone decides a boolean, a test that FAILS when the throw is
deleted. Run against the real CASE-01 file it names `finiteValue < 0` at L25 and the throws at
L18/L26: exactly the mutants 27 and 34 of 39 suites failed to kill.

This is the first lever found tonight that aims at **quality** rather than cost, and its value
should show on CASE-02/03/04/05 rather than on CASE-01, which is already at its ceiling.

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

## v9 — the first real quality gain in this benchmark, and the tension it creates

| arm | n | kill (med) | RED | wall (med) | tokens (med) |
|---|---|---|---|---|---|
| naked | 4 | 84.8% | 0/4 | 231s | 0.30M |
| zuvo-v3 (main, was) | 9 | 88.4% | 1/9 | 698s | 2.70M |
| zuvo-v7 (main, now) | 5 | 88.9% | 0/5 | 492s | 1.82M |
| zuvo-v8 | 5 | 88.9% | 0/5 | 1684s | 4.39M |
| **zuvo-v9** | 5 | **90.9%** | 0/5 | 1214s | 4.43M |

v9 is the first arm to move the median at all: **+2.0 points over v7, +6.1 over the control**, with
no RED suites. Every earlier "improvement" held quality flat and moved only cost.

It also complicates the plateau result above, and the honest thing is to say so rather than pick
the reading that suits the conclusion. Within v9's five runs:

| wall | kill |
|---|---|
| 648s | 87.9% |
| 1148s | 87.9% |
| 1214s | 90.9% |
| 3770s | 90.9% |
| 4033s | 90.9% |

That is +3.0 points for the more expensive runs — a within-arm dose-response, at n=5, in an arm
where the corpus-wide analysis predicted roughly half a point. Both cannot be the whole story.
The plateau analysis has 33 runs behind it and v9 has five, so v9 is the weaker evidence; but it is
also the only arm measured *after* the verification loop was made cheap, so it may simply be
describing a different regime.

**That is exactly what v10 measures.** v10 is v9 plus a 15-minute clock on the verification loop.
If the clock costs ~3 points, the plateau reading is wrong for this arm and the trade is real and
the user's to make. If quality holds at 90.9% with the tail cut, the clock is free. Running now,
n=5, same case.

## v10 — same quality as v9, twice the wall, and the reason is a single word

| arm | n | kill (med) | RED | wall (med) | tokens (med) |
|---|---|---|---|---|---|
| naked | 4 | 84.8% | 0/4 | 231s | 0.30M |
| zuvo-v7 (main) | 5 | 88.9% | 0/5 | **492s** | 1.82M |
| zuvo-v9 | 5 | **90.9%** | 0/5 | 1214s | 4.43M |
| zuvo-v10 | 5 | **90.9%** | 0/5 | 2353s | 7.26M |

v10 holds v9's 90.9% — the quality gain is stable across two independent five-run batches, which
is worth more than either batch alone. What it does not hold is the cost, and the clock it was
built to test never even fired: the verification loop now finishes in **1.9 minutes**, so a
15-minute budget is nowhere near binding. The extra wall is the SKIP/DEFER collision below.

## A one-word regression I introduced, and how the rig found it

v10's phase attribution showed one run spending **677 seconds across 24 turns** in the mutation
bucket — 29% of its wall — running StrykerJS and hand probes itself, while the helper was
deferring mutation to a later pass.

The deferral reported status `SKIP`. `SKIP` already meant "this check cannot run here", and
Step 3.3 keys on exactly that to fall back to hand-written probes. So every deferred pass read as
*the runner is unavailable, do it manually*, and the agent went off to do the expensive thing the
helper was about to do for free on the next pass.

Deferral is now `DEFER`, a state of its own, and the skill says plainly that DEFER is not SKIP:
one means "later, by me", the other "never, here".

The general shape is worth keeping: **a helper that shares a status word with a fallback rule
inherits that rule's behaviour whether or not it meant to.** No amount of reading the helper would
have found this — the helper is correct in isolation. It took attributing wall-clock to what the
agent actually ran.

## Rig repair, and the failure mode worth remembering

Making the rig multi-repo (so a case can name its own checkout) broke it twice, and the two
breakages fail in opposite ways:

1. **The patch went through an ssh heredoc**, which stripped the quotes around a path and
   expanded `$BENCH`/`$CASE` at *write* time, leaving
   `print(json.load(open(/corpus//meta.json)).get(repo_dir, /repo))` in the script. Python
   raised, `REPO` came back empty, `cp -a "" "$WS"` copied nothing — and five agents were handed
   an empty directory tree. One of them said so plainly ("there's nothing to write tests for")
   **and the run still exited 0 after 34 seconds.** A completed run with no suite is
   indistinguishable, downstream, from a skill that refused to work.
2. **Switching the node_modules source to `$REPO/node_modules` reintroduced instrument rule 1.**
   In the tgm corpus that path is a *symlink* to a shared store, `cp -al` on a symlink copies the
   link, and the container then follows a host path it cannot see. The green/red selfcheck caught
   this one immediately — npx downloaded its own vitest and the green case failed — which is the
   selfcheck doing exactly the job it was built for.

The lesson is the asymmetry. The failure the instrument checked for was caught in seconds; the
failure it did not check for produced five green-looking runs. `run_arm.sh` now refuses to start
an agent when the workspace is under 1 MB or the file under test is absent, and every path is
passed to Python as **argv** rather than interpolated into its source.

## Instrument changes made tonight

- The rig is multi-repo: a case names its own checkout, and the green/red selfcheck picks the
  runner and the directory from the case rather than assuming `apps/api` + vitest.
- `run_arm.sh` refuses to start an agent on a workspace under 1 MB or without the file under
  test, and bounds the docker CLIENT as well as the agent (a client outliving its container
  stalled the whole sweep).
- Every `pgrep` wait is anchored on the start of the command line. Unanchored, they matched the
  monitoring shells watching them — an instrument that blocked the experiment it was observing,
  and the reason the driver sat idle for half an hour. The correction then produced its own
  variant: a driver waiting on `^bash /root/bench/night2.sh` never matched, because that process
  was started as `bash night2.sh` from inside the directory, so the absolute path is not in its
  command line at all. **Anchoring is only correct against the form the process actually has**,
  and two drivers ran in parallel for a few minutes as a result. They serialised on the
  idle-box check, but they shared one `supervisor.state`; one driver from there on.
- A repetition of the control arm is still the control arm. `arm_needs_skill` tested the run
  directory against the literal `'naked'`, so `naked-r1` was expected to invoke a skill it
  deliberately does not have and came out `SKILL_NOT_INVOKED` — a verdict the supervisor reads as
  "not complete", which would have relaunched every control run three times and then given up.
  Caught before the CASE-05 control batch, not during it.
- Scoring is serialised behind a lock, and dispatches per case: frozen mutants where a frozen set
  exists, StrykerJS otherwise (which is how a jest case can be scored at all).

## State of the night plan

Seven batches, sequenced (five containers is what this box absorbs while staying responsive;
two batches at once would make every wall-clock number a measurement of contention):

| # | case | arm | what it answers |
|---|---|---|---|
| 1 | CASE-01 | v10 ×5 | **does the 15-minute clock cost quality?** v10 is v9 plus the clock and nothing else |
| 2 | CASE-05 | naked ×3 | a floor on jest/NestJS, a stack this benchmark has never run |
| 3 | CASE-05 | v10 ×3 | the skill on that stack |
| 4 | CASE-05 | v11 ×3 | v10 + boundary obligations, same stack, same night |
| 5-7 | CASE-02/03/04 | v11 ×3 each | the boundary change where there is room: these sit at 61-78% kill |

CASE-01 deliberately stays on v10 so its comparison against v9 isolates the clock. Everything
after it runs v11, because the boundary work aims at files that are not already at their ceiling.

### Reference points already on record

| case | file | incumbent / control |
|---|---|---|
| CASE-01 | `runner-maxdiff-score-contract.ts` (vitest) | naked 84.8%, ceiling ~91.9% |
| CASE-02 | `QuestionResponseAnswer.tsx` (React) | naked 75.2% |
| CASE-03 | `useFeedbackForm.ts` (React hook) | naked 66.1% |
| CASE-04 | `survey-logic-auditor.replay.ts` | naked 67.2% |
| CASE-05 | `dom-translation-detector.ts` (jest/NestJS) | **human-written incumbent 34.6%** — 35 of its 50 tests are skipped |

## CASE-05 (shield / jest / NestJS) — the control beats the committed spec by 50 points

First numbers from a stack this benchmark had never run:

| suite | kill | killed | survived | **no-coverage** | wall |
|---|---|---|---|---|---|
| the repo's own hand-written spec | **34.6%** | 66 | 26 | **99** | — |
| naked r1 / r2 / r3 (no skill) | 83.2 / 84.3 / 84.3% | ~160 | 26 | 4-6 | 162s |

The 26 survivors are **identical in all four suites**, which is what an equivalent-mutant set looks
like. The entire difference is `no-coverage`: the committed spec does not execute most of the
file, because **35 of its 50 tests are `skip`ped**. A three-minute run with no skill loaded covers
what a checked-in test file does not.

That also sets the headroom, and it is much tighter than CASE-01's:

| case | control | ceiling | headroom | captured by the skill |
|---|---|---|---|---|
| CASE-01 | 84.8% | 91.9% | 7.1 pts | **6.1** |
| CASE-05 | 84.3% | ~86.4% (if all 26 are equivalent) | ~2.1 pts | measuring now |

Worth carrying forward as a benchmark-design point: **a case only discriminates where the control
leaves room.** Files a competent agent covers in three minutes cannot show a six-point difference,
whatever the skill does.

## Worth considering, not done

`test-coverage-gate.py boundaries` is useful to more than `write-tests`, and two sibling skills
would take it almost unchanged:

- **`zuvo:test-audit`** audits suites that already exist. Today it can say a suite is thin; with
  the obligations it could say *which* boundary it never sits on — "L25 `finiteValue < 0` has no
  test where the value is exactly 0" — which is the difference between a score and a work list.
- **`zuvo:mutation-test`** already reports survivors; annotating each with the obligation it
  failed is the same three lines `verify-tests` now carries.

Neither is done, because neither was asked for and both change skills outside the one under
measurement. Flagging rather than doing.

## Reading the results in the morning

On `coding-vps`, everything lives in `/root/bench`:

```bash
ssh coding-vps 'cd /root/bench && python3 summary.py'        # START HERE — medians per case x arm
ssh coding-vps 'cd /root/bench && python3 table.py'          # the individual runs behind them
ssh coding-vps 'tail -30 /root/bench/night.log'              # which batches ran and when
ssh coding-vps 'ls /root/bench/mon-*.log'                    # one live trace per batch
ssh coding-vps 'cd /root/bench && python3 turns_vs_kill.py'  # the plateau analysis, refreshed
ssh coding-vps 'cd /root/bench && python3 survivors.py CASE-03'   # what the misses are made of
ssh coding-vps 'cd /root/bench && python3 aggwall.py naked zuvo-v9 zuvo-v10 zuvo-v11'  # where wall went
```

`summary.py` is the one to start from: medians rather than means (one 4000-second outlier
otherwise moves the number that gets quoted), RED suites counted rather than averaged in, and a
per-case ceiling from the mutants that survive every arm — with the arm count printed, because a
ceiling drawn from 3 suites is a much looser claim than one drawn from 44. A `-` in the kill column means the run finished but scoring
has not caught up; a `0.0` means the suite fails on unmutated source and is worthless, which is a
result, not a gap.
