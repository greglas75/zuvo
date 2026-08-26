# Overnight run — 2026-08-21 → 08-22

Goal set at 17:15: **a full run under 20 minutes, quality held.** Then move down the file list and
optimise as far as it goes.

Read as `write-tests`, since that is the skill this whole session has been benchmarking and the
"file list" is its corpus. If it meant `zuvo:refactor` the skill instead, none of this measures
that — `~/.zuvo/runs.log` holds one entry and no refactor timings, so there is no fleet data to
answer it from, and it would need its own rig.

Everything below is measured on the rig (coding-vps, containers, frozen mutant sets / StrykerJS),
not argued. Where a number is a single run rather than a median, it says so.

---

## CORRECTION — every RED suite in this benchmark was an instrument error

Found at 22:30 while diagnosing three shield runs that all scored 0.0.

**Seven of the eight RED suites came from runs that also wrote
`production-file-modified.diff`.** That is not a coincidence: Step 4.5 of `write-tests` mandates
fixing production bugs surfaced while writing tests, in-run. The suite and the fix ship together.

The scorer threw the fix away. It copies the pristine corpus repo, installs only the arm's test
file, and runs it against unfixed production — so a test asserting the corrected behaviour fails,
the clean-pass gate trips, and the run scores 0. **Doing the mandated thing scored worse than
never finding the bug.**

Audited across all five cases, not just the one where it surfaced. Nine runs modified production;
each is now either re-scored with its own source restored (StrykerJS cases) or marked
`PRODUCTION_MODIFIED` (frozen-mutant cases). **The corpus contains exactly two genuinely broken
suites — `zuvo-v3-r6` on CASE-01 and `zuvo-v4` on CASE-04 — the only two that wrote no production
diff at all.**

Re-scored with the run's own production file restored:

| shield / CASE-05 | before | after |
|---|---|---|
| zuvo-v10-r1 | **0.0% (RED)** | **85.7%**, suite PASS |
| naked (control) | 84.3% | 84.3% |

So the skill does beat the control on that file, and the instrument was reporting it as total
failure. Everything below that says "RED" needs reading against this: **`v2 2/4 RED`, `v6 1/3 RED`,
`v11 1/5 RED` and all three shield runs are affected.** Only `zuvo-v3-r6` (CASE-01) and `zuvo-v4`
(CASE-04) wrote no production diff and remain genuinely broken suites.

### What changed

- `stryker_score2.sh` restores the run's own production file (a saved copy, else the diff applied
  by named target — the diff carries absolute paths into a workspace since reclaimed, so no `-p`
  level resolves it) before scoring. Tests and fix are scored together, which is the state the run
  produced.
- The frozen-mutant engine **cannot** do that: its mutants are byte offsets into one source text,
  and any production edit invalidates every offset after it. Such runs now score
  `PRODUCTION_MODIFIED` with a null kill-rate — excluded from medians, reported separately —
  rather than a zero that describes the instrument.
- `run_arm.sh` now saves the modified production file itself, not only a diff of it.

### The lesson, which is the same one twice

A pipeline step that CHANGES the system under test needs a measurement that reproduces the state
it left. This rig froze production to keep mutants stable, and that freeze silently contradicted
a mandated pipeline step. The tell was available all night — a `production-file-modified.diff` in
every RED run — and I read "RED" as a property of the suite for six hours before checking what
those runs had in common.

## Bottom line

**Quality moved for the first time in this benchmark.** Two independent five-run batches agree:

| arm | kill (med) | RED | wall (med) | vs control |
|---|---|---|---|---|
| naked (no skill) | 84.8% | 0/4 | 231s | — |
| **v7** — on `main` now | 88.9% | 0/5 | 492s | +4.1 |
| **v9 / v10 / v11** | **90.9%** | 0/5, 0/5, 0/4 | 1214s / 2353s / 2900s | **+6.1** |

And on **shield** (`rs_be`, jest/NestJS), a stack this benchmark had never run:

| arm | kill (med) | wall (med) |
|---|---|---|
| the repo's own committed spec | 34.6% | — |
| naked (no skill) | 84.3% | 162s |
| **zuvo-v10** | **88.2%** | 4203s |

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

**One RED suite in the whole corpus, not eight.** Seven of the eight were the scorer discarding a
production fix the pipeline mandates — see the correction at the top, which is the most important
thing on this page.

**And the misses have a shape.** Comparing per-mutant survivors across 39 suites: what separates
an 88% suite from a 91% one is boundaries the tests never sat exactly on — a deleted `throw`
survived 34 of 39 suites, `< ` changed to `<=` survived 27, `[0]` shifted to `[1]` survived 15.
`test-coverage-gate.py boundaries` now derives those obligations from the source instead of from
the code-type classification that was gating the existing rule.

---

## All five cases, corrected

| case | file | control | zuvo | Δ | ceiling |
|---|---|---|---|---|---|
| CASE-01 | `runner-maxdiff-score-contract.ts` (vitest) | 84.8% | 90.9% *(v11)* | +6.1 | 91.9% |
| CASE-02 | `QuestionResponseAnswer.tsx` (React) | 75.2% | 81.4% *(v12)* | +6.2 | 81.9% |
| CASE-03 | `useFeedbackForm.ts` (React hook) | 66.1% | 72.9% *(v12)* | +6.8 | 79.7% |
| CASE-04 | `survey-logic-auditor.replay.ts` | 67.2% | **85.8%** *(v12)* | **+18.6** | 88.9% |
| CASE-05 | `dom-translation-detector.ts` (jest) | 84.3% | 84.3% *(v12)* | +0.0 | ≥90.7% |

Four of five sit within one to seven points of the ceiling, and the gain over a no-skill control is
between six and nineteen points.

**What that table does NOT show is which change earned it.** CASE-02/03/04 have one v12 arm each,
compared against arms from earlier in the session (v3, v4, v5) that lack roughly ten changes, not
one. Attributing those gains to the boundary obligations — the newest change — would be exactly
the between-arm mistake the plateau analysis already caught once. The only clean same-generation
comparisons of the obligations are CASE-01 (v11 with them, 90.9%; v10 without, 90.9% — no
difference) and shield (below). CASE-05 is the one the deferral bug starved, and CASE-04 — the
largest file, the one the split rule fires on — is where the skill is worth the most by a wide
margin.

Across roughly ninety runs the corpus now holds **two** genuinely broken suites: `zuvo-v3-r6`
(CASE-01) and `zuvo-v4` (CASE-04). Every other zero was one of two instrument faults, both of the
same shape — the scorer not reproducing what the run produced:

| fault | runs affected | fix |
|---|---|---|
| a run fixed production in-run (Step 4.5) and the scorer discarded the fix | 9 | restore the run's own source (Stryker) or mark `PRODUCTION_MODIFIED` (frozen mutants) |
| a run SPLIT its suite and the harvest collected specs but not the fixtures module they import | 1 | harvest sibling modules too; stop reclaiming the workspace of a zero-scoring run |

The second is worth stating plainly: the split rule is a documented, mandatory part of
`write-tests` (>40 owned rows), so the harvest was always going to lose a case the moment one got
large enough. Both faults punished the pipeline for following its own rules.

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

The other half of the picture is **withdrawn.** It read: *three of the four RED suites were among
the most expensive runs, so past the plateau effort buys variance.* Those three runs did not write
broken suites — they fixed production bugs in-run, exactly as Step 4.5 requires, and the scorer
discarded the fix (see the correction at the top). Re-scored, they are `PRODUCTION_MODIFIED`, not
zeros. Expensive runs are not more likely to produce a worthless suite; they are more likely to
find a production bug, which is the opposite conclusion.

What survives is the part that never depended on RED counts: within one arm, working 3-5x longer
moves the median by about half a point.

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

## v11 on CASE-01 — one run at the ceiling, no median gain

| run | wall | kill |
|---|---|---|
| r4 | 1870s | 90.9% |
| r5 | 2419s | **91.9% — the ceiling, the only run in 44 arms to reach it** |
| r1 | 2900s | `PRODUCTION_MODIFIED` — fixed a real defect in-run, not comparable on frozen mutants |
| r3 | 3069s | 90.9% |
| r2 | 4208s | 89.9% |

Median 90.9% over the four comparable runs, 0 RED: identical to v9 and v10, at **2.4x v9's wall**
and 10.4M tokens. On CASE-01 the
boundary obligations buy nothing, which is what a file one mutant from its ceiling should show.
They do change behaviour — 61 tests written against v10's 38, from a 61-row inventory — but the
extra tests land on mutants that were already dead.

r1 is worth reading closely, because it is where the instrument bug surfaced. The obligations
pushed the run to try `optionId: undefined`, which found a **real production defect**: the module
throws a raw `TypeError` where its own contract promises `MaxDiffScoreContractError`. The run fixed
it, per Step 4.5. The scorer then measured the suite against unfixed production and reported 0.

The helper now names the two legal exits from a red suite in the suite-FAIL gap list itself —
still worth having, since a run genuinely CAN finish red — but r1 was not one of those runs.

**Second-order effect worth carrying:** obligations derived from source surface more production
bugs than tests written from intent. That makes the in-run fix rule matter more, not less.

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

## Shield, complete — and the result is uncomfortable

| arm | kill (med) | RED | wall (med) | tokens (med) |
|---|---|---|---|---|
| the repo's committed spec | 34.6% | — | — | — |
| naked (no skill) | 84.3% | 0/3 | 162s | 0.24M |
| **zuvo-v10** | **90.7%** | 0/3 | 4203s | 10.20M |
| **zuvo-v12** | **84.3%** | 0/3 | 833s | 3.06M |

v10 is the largest quality gain anywhere in this benchmark: **+6.4 points over the control**, and
it takes seventy minutes to get there (two of its three runs were cut off by the container cap and
still scored it). v12 is **five times cheaper and scores exactly the control's number.**

Two things follow, and they pull against each other:

1. **This file has real headroom and effort buys it.** The ceiling here is at least 90.7%, not the
   ~86.4% I estimated earlier from the control and the incumbent — that estimate counted mutants
   as equivalent that v10 went on to kill. Where CASE-01 was one mutant from its ceiling and extra
   work bought nothing, shield had six points on the table.
2. **v12 stops before collecting them.** Whatever the DEFER fix and the rest removed, some of it
   was work that mattered here.

I cannot say which change caused it: v10 and v12 differ in **four** things at once — the boundary
obligations, the DEFER fix, the Step 3.3 repair, the survivor annotation. Attributing a 6.4-point
drop or a 5x speedup to any one of them would be a guess.

### Found it, before the ablation ran

The harvested verify-state for `zuvo-v12-r3` says the whole story in six characters per pass:

```
p1  P/F/P/D/D/P     p2  P/F/P/D/D/P
    suite PASS · gate FAIL · coverage PASS · typecheck DEFER · mutation DEFER · hash PASS
```

The coverage **gate** failed on every pass, and the deferral I had built waited on that gate — so
typecheck and mutation never ran at all, on any pass, in any of the three runs. The suite finished
having never been mutated, which is why it scored the control's number: nothing ever told it which
mutants survived.

The mistake is in what the deferral waited for. The gate checks whether inventory rows carry
evidence — bookkeeping. It says nothing about whether the tests detect anything. A run with
imperfect bookkeeping and a good suite still deserves its most valuable signal.

Fixed: the expensive checks now wait on the **suite being green and scoped coverage being
adequate** — the two conditions that make a mutation number mean something. The gate's own result
no longer blocks them.

### Two ablations queued, in this order

1. **v13** — v12 with the boundary obligations removed, on the OLD gating. Isolates the
   obligations with everything else held constant.
2. **v14** — v12 with the NEW gating. Predicted before the run so it can be wrong: **~90% at
   v12's cost (833s), not v10's 4203s.** If it lands at 84% again, the gating was not the cause
   and the six points come from something v10 did that neither arm does.

The shared helper is swapped between them, because `~/.zuvo` is one mounted directory for every
container rather than per-arm — swapping at the wrong moment would confound both.

## The shield ablations — my diagnosis was right about the mechanism, and the ablation could not see it

| arm | kill (med) | wall (med) | verification passes |
|---|---|---|---|
| naked | 84.3% | 162s | — |
| zuvo-v10 | 90.7% | 4203s | — |
| **zuvo-v12** (boundary obligations) | **84.3%** | **833s** | `p1: P/F/P/D/D/P` |
| **zuvo-v13** (v12 − obligations) | **90.1%** | 4196s | `p1: P/P/P/P/F/P` |
| zuvo-v14 (v12 + new gating) | 89.7% | 4066s | `p1: P/P/P/P/F/P` |

Read the pass columns rather than the scores. In v12 the coverage **gate FAILED** and mutation
was deferred — on every pass, in all three runs, so the suite finished having never been mutated.
In v13 and v14 the gate PASSED and mutation ran.

So the causal chain is:

1. the boundary obligations add ~60 rows to the inventory;
2. more rows means more chances the validator finds one whose evidence does not hold, so the
   **gate is more likely to fail** — not certain to. v15's first run had the obligations AND a
   passing gate, so this is a probability shift, not a deterministic consequence, and the earlier
   phrasing ("the obligations cause the gate to fail") was too strong;
3. under the old deferral, a failing gate blocked mutation permanently;
4. no mutation means no survivor feedback, and the suite stops at the control's score.

**v14 could not test the fix**, because its gate passed and the deferral therefore never fired —
and separately, its runs all started before the shared helper was swapped, so they carried the old
binary anyway. It is uninformative rather than confirming.

The untested combination is the one that matters: **obligations AND the new gating**, where a
failing gate no longer starves the run. That is `v15`.

### What v15's wall-clock already settles, before it is scored

v15 passed thirty-eight minutes still running. It carries the obligations and it is nowhere near
v12's 833 seconds — it is in v13/v14 territory (~4100s).

So **v12 was not made fast by the obligations. It was fast because it gave up.** With mutation
never running it had no survivors to chase, nothing to fix, and it finished. The trade visible on
shield is not "obligations vs no obligations"; it is **"measuring mutation vs not measuring it"**:

| arm | did mutation run? | kill | wall |
|---|---|---|---|
| v12 | **no** — the gate blocked it | 84.3% | 833s |
| v13 / v14 | yes | 90.1% / 89.7% | ~4100s |
| v15 | yes | pending | >2300s |

If v15 lands near 90%, the obligations are neutral for quality on this file and the whole shield
difference is mutation feedback — which would mean **neither of my two hypotheses was right**,
since both blamed the obligations.

### v15: 89.7%, 4203s. Both hypotheses were wrong.

| arm | kill (med) | wall (med) |
|---|---|---|
| naked | 84.3% | 162s |
| **v12** (obligations, broken gating) | **84.3%** | **833s** |
| v13 (no obligations) | 90.1% | 4196s |
| v14 | 89.7% | 4066s |
| **v15** (obligations + fixed gating) | **89.7%** | 4203s |
| v10 (before any of tonight's changes) | 90.7% | 4203s |

The boundary obligations are **neutral for quality and neutral for cost**. Every arm that
actually measures mutation lands at ~90% and ~4100-4200s; v12 was the outlier only because it
never measured any. One v15 run reached **93.4%**, the highest score on this file by anything.

Two things follow that matter more than the obligations question:

1. **The seventy minutes are not caused by anything changed tonight.** v10 predates all of it and
   costs the same 4203s. Every one of these arms hit the container's 70-minute cap, so they were
   *cut off* — the true cost is unknown and ≥70 minutes.
2. **The budget was an escape an agent could type, and it did — 212 times.** One run made nine
   verification passes against a budget of three, at ~180s each, spending 38.6% of its wall
   inside the helper; its final state file says `passes 1`. `--reset-budget` now requires
   `ZUVO_VERIFY_RESET=1`, and a call past the budget is refused *cheaply* — no suite, no gate,
   no mutation, just the last real measurement reprinted.

### v16: the budget enforcement did NOT cut the time, and the reason is elsewhere

89.3% at 4204s — unchanged. Attribution says why, and it is not the budget:

| | v16-r1 (4140s, 396 turns) | v16-r3 (1265s, 161 turns) |
|---|---|---|
| kill | 89.3% | 83.8% |
| **mutation** | **998s / 14 turns** | *no mutation bucket at all* |
| verify-helper | 574s / 7 calls | — |
| think | 526s / 196 turns | 174s / 83 turns |

The 998 seconds are **not** the helper. The agent wrote its own `stryker.zuvo-inspect.json` and
`jest.zuvo-inspect.config.js`, ran StrykerJS twice by hand, and spent four more turns parsing the
report — because the printed block caps survivors at five and triaging equivalents needs all of
them. It recomputed a report the helper already had in memory and threw away.

So the difference between a 21-minute run and a 70-minute one, on this file, is **whether the
agent re-runs the mutator to see the full survivor list.** And the quality tracks it: 83.8%
without, 89.3% with.

Fixed by writing what was already computed: every survivor goes to
`<manifest>.survivors.json`, each row carrying the boundary obligation on its line, with the path
named in the block. `v17` measures it.

## Shield, the whole ladder — and what "fast and good" actually costs

| arm | kill (med) | wall (med) | tokens (med) | what changed |
|---|---|---|---|---|
| naked | 84.3% | **162s** | 0.24M | no skill |
| v12 | 84.3% | 833s | 3.06M | mutation never ran (gate starved it) |
| v10 | 90.7% | 4203s | 10.20M | before any of tonight's changes |
| v13 / v14 / v15 | 90.1 / 89.7 / 89.7% | ~4200s | ~11M | obligations in/out — no effect either way |
| v16 | 89.3% | 4204s | 14.31M | budget enforced — no effect on cost |
| **v17** | **89.1%** | **3120s** | **7.51M** | full survivor list written to disk |

v17 is the first change that moved cost without moving quality: **−26% wall, −27% tokens**. It
works by removing a specific behaviour — an agent rebuilding its own Stryker config to see
survivors past the printed five — which was 998s across 14 turns in one v16 run.

The per-run numbers say what is left, and they are not noise:

| wall | kill | survivors left |
|---|---|---|
| 599s | 85.3% | 24 |
| 3120s | 90.1% | 18 |
| 4204s | 89.1% | 19 |

**Quality on this file is a count of closed survivors, and each closure costs a measurement
round.** Ten minutes closes none past the first pass; fifty closes six. Nothing measured tonight
gets ~90% in twenty minutes here, and the reason is structural rather than wasteful.

The one lever left that does not trade quality for time is to make a single round close more:
give the run the full survivor list **with the boundary obligation naming the exact case that
kills each one**, so ten survivors close in one round instead of ten. That annotation has existed
since 458e3c3 and has never once run on the rig (stale copy, below). `v18` is the first arm that
actually carries it.

## v19 — measuring mutation FIRST halves the cost at the same quality

| arm | kill (med) | wall (med) | tokens (med) | what changed |
|---|---|---|---|---|
| naked | 84.3% | 162s | 0.24M | no skill |
| v10 | 90.7% | 4203s | 10.20M | best quality before tonight |
| v17 | 89.1% | 3120s | 7.51M | full survivor list on disk |
| v18 | 89.6% | 3890s | 8.13M | + the boundary obligation on each survivor |
| **v19** | **90.1%** | **2147s** | **5.76M** | **mutation measured on pass one** |

v19 matches v10's quality at **half the wall and 56% of the tokens**. v18's annotation, measured
on its own, did not help — 89.6% at 3890s is worse on cost than v17. What helped is *when* the
survivor list arrives, not how well it is labelled.

**The median hides a ten-fold spread, and the spread is the actual result:**

| run | kill | wall | tokens |
|---|---|---|---|
| r2 | 86.9% | **451s** | 1.30M |
| r3 | 90.1% | 2147s | 5.76M |
| r1 | 90.3% | 4205s *(hit the container cap)* | 13.85M |

No earlier arm could buy 86.9% in seven and a half minutes. v12 spent 833s to reach the control's
84.3%. So v19 is not one point on the cost axis — it is a **choice** that did not exist before:
+2.6 points for 7.5 minutes, or +5.8 for 36.

**It did not transfer.** Carried to CASE-03, the same arm scores 72.9% — identical to v12, and
slower (1579s against 1112s). One case is not a stack, and this is shield-specific until something
else shows it too.

## The rig lost a feature by copying a stale file

`boundaries --json` — the machine-readable form the survivor annotation depends on — was added
locally and **never reached the rig**. Every arm from v12 to v17 was built by copying
`/root/bench/test-coverage-gate.py`, which had been scp'd once, before that flag existed. So the
annotation feature ran zero times in the benchmark and every survivor row in every report has
`obligation: null`.

Nothing detected it, because the helper treats a failed `boundaries` call as "no obligations
available" and carries on — a degradation that is correct behaviour for a missing parser and
indistinguishable from a stale copy.

The generalisable part: **a distribution assembled by copying files needs the copy to be part of
the build, not a step someone remembers.** The arms carry a patch for `SKILL.md` and
`shared/includes/` applied from git, which is why those never drifted; `scripts/` was copied by
hand, which is why it did.

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

---

## CORRECTION 2 — mutation never ran on three of the five files (2026-08-23)

The count nobody had taken, over every run in the corpus:

| case | runs that produced a mutation number |
|---|---|
| CASE-01 (root vitest) | 18 of 55 |
| **CASE-02 (React component)** | **1 of 14** |
| **CASE-03 (React hook)** | **0 of 12** |
| **CASE-04 (jest fixture)** | **0 of 11** |
| CASE-05 (jest/NestJS) | 25 of 35 |

On CASE-02, CASE-03 and CASE-04 the mutation step failed for the entire benchmark. It failed
quietly: Stryker reports "No tests were found" or a type error, the helper recorded an ERROR line
inside a long verify block, and the run carried on. So every number on those three files describes
`write-tests` working **blind**, and the headline conclusion of this whole benchmark — that
mutation feedback is the lever — rests on the two files where it happened to work.

The visible tell was there and was misread: CASE-02's arms landed on 75.2%, *exactly* the no-skill
control, and that was written down as "the skill does not help on React".

### Three faults, each hiding the next

1. **`disableTypeChecks` was never scoped.** Stryker's instrumentation assigns to its own helper
   functions, which ts-jest rejects with `TS2630`. Stryker prevents this by inserting `@ts-nocheck`
   — but only into files matching `disableTypeChecks`, whose default glob (`{test,src,lib}/**`)
   matches no monorepo layout (`apps/*/src/**`). The dry run then dies citing a type error in code
   the project does not contain, which reads as a broken project rather than a broken option.
2. **Nothing bounded jest's crawl.** `testFiles` limits which tests kill mutants; it does not limit
   what the dry run collects. Measured: **390 spec files, 36+ minutes** against **83 seconds** once
   `roots` is narrowed. `roots` is the only narrowing knob that needs no knowledge of the project's
   config — overriding `testMatch` on a config that sets `testRegex` is a hard jest validation
   error, and a `.js` config cannot be read from the helper to find out which it uses. Absolute
   paths, because `inPlace` means there is no sandbox to be hostile to them.
3. **`concurrency: 2`** was a good-neighbour guess made before anything was measured.

Measured after, all three stacks, production hash unchanged on each:

| stack | before | after | mutants |
|---|---|---|---|
| jest / NestJS | never completed | **80 s** | 191 |
| vitest / workspace (React) | never ran | **26 s** | 152 |
| vitest / repo root | ~intermittent | **70 s** | 235 |

### The trap found while measuring it

`inPlace` edits the real file, so the original survives only an exit this process controls. A
SIGKILL — harness timeout, OOM, an operator's `kill -9` — skips every `finally` and leaves the file
instrumented. The next run then snapshots *that* as its original, restores it faithfully, and
reports `production-hash PASS`. The corruption is permanent and invisible from then on.

It cost an afternoon here: four consecutive probes all measured an instrumented file, and the dry
run died on `Maximum call stack size exceeded` because instrumenting instrumented code recurses
forever. The stack trace naming `stryMutAct_9fa48` calling itself was the only honest signal, and
it only appears if you stop filtering the output.

Now: the pristine copy is written to disk before anything runs, and a run that finds instrumentation
already present either heals from that copy or refuses. A score measured against an instrumented
file is not a low score — it is not a score.

### What this invalidates

The helper is a **single shared mount**, not per-arm. So every arm scored before 2026-08-23 was
measured with the broken mutation step, and comparing a v21 number against an older arm's number
compares two different measuring instruments as well as two skills.

The one comparison that stays clean is **v21 against `naked`**, because the control never invokes
the helper at all. Arm-versus-arm claims from earlier in this log should be treated as describing
the runs, not the skill versions, until re-measured.

---

## The dominant failure mode is not the tooling — it is that the tooling is declined (2026-08-23)

Once mutation worked everywhere, the next question was why CASE-04's runs still produced no
mutation number. The answer was not a bug.

**On CASE-04 no manifest has ever been written.** Nine runs across three skill versions (v12, v19,
v21 — 3/3 each): no `zuvo/` directory, no inventory, no gate, nothing downstream of it. The
transcripts show the skill loaded and the protocol read — 12 mentions of the coverage gate, 6 of
the manifest. The runs understood it and chose not to do it. One says why in as many words:

> "verify-tests, adversarial review providers, CodeSift, blind-audit reviewers, etc.) that isn't
> practical to run in full here. I'll follow its core spine pragmatically"

That run wrote four spec files, called them "green and validated", and scored 86.0% — **+18.8 over
the no-skill control, achieved entirely outside the mechanism the skill is built around.**

### Measuring the skip correctly took three attempts

| definition | what it actually counts |
|---|---|
| transcript mentions `verify-tests` | every run — the skill names it dozens of times in its own prose |
| a `tool_use` whose input mentions it | includes `ls -la ~/.zuvo/verify-tests` and `head -5` of it: runs that checked whether the helper exists and then did not use it. Two CASE-02 runs scored as compliant this way while measuring nothing |
| a `tool_result` containing `production-hash` | correct — a line only the helper prints, absent from the skill text |

The middle definition is the one I published first, and it understated the problem. Under the
correct one: CASE-04 0/3 in every arm, CASE-02 v21 0/2, CASE-03 2/3, CASE-05 mostly clean (which is
where the helper was developed and tested).

### Two different holes, two different fixes

1. **A manifest exists but nothing measured it.** Closed by a receipt: `verify-tests` stamps the
   manifest with the sha256 of each spec at the moment it measured them, and the gate refuses a
   `final` manifest without one, or with one whose hashes have gone stale. Hashes rather than a
   flag, so a receipt cannot be inherited from an earlier, different suite.
2. **No manifest at all.** A receipt cannot refuse what does not exist. This one is an entry-cost
   problem: 88 branches meant ~90 hand-authored rows, and the runs were right that it was not
   practical. `test-coverage-gate.py scaffold` now generates the inventory from the same extractor
   the validator checks it against — 22 symbols / 197 rows in one command on this repo's own gate
   script, validating clean at inventory phase.

**Rejected: a Stop hook.** Measured directly rather than assumed — Stop hooks do not fire under
`claude -p`, so it would protect interactive sessions and silently skip every headless one, which
is where both the benchmark and CI live.

### What this means for the benchmark's headline numbers

`+18.8` on CASE-04 was never a measurement of the executable machinery; it measures what the
skill's *prose* buys (split by responsibility, sit on boundaries) when an agent skips the rest. That
is a real and useful result — it just is not the result it was being read as.

The monitor now renders `measured N/3` per arm so this cannot go unnoticed again.

### What the verification loop is actually worth

Pooling runs within each file by whether they ever produced a helper verdict:

| file | MEASURED (used the loop) | SKIPPED (prose only) | naked |
|---|---|---|---|
| CASE-01 | 90.9% (n=16, 87.9–91.9) | 88.9% (n=28, 81.8–90.9) | 84.8% |
| CASE-02 | **81.4%** (n=4, 75.2–81.9) | **75.2%** (n=8, 73.3–81.9) | **75.2%** |
| CASE-03 | 72.9% (n=3, 72.9–78.0) | 72.9% (n=5, **61.0**–74.6) | 66.1% |
| CASE-04 | — (n=0) | 85.5% (n=10, 77.8–88.9) | 67.2% |
| CASE-05 | 89.7% (n=26, 83.2–93.4) | 86.1% (n=6, 83.8–90.1) | 84.3% |

Read with its confound stated: arm version is not controlled here — measured runs skew to later
arms, which also have better prose. This says "runs that used the loop landed here, runs that
skipped it landed there", not a clean effect size. Pooling was necessary because no single arm has
enough runs on both sides.

Three things it does establish:

- **The loop is worth roughly +2 to +6 points where it runs**, and on CASE-02 it is the whole
  difference between helping and not: the skipped runs sit at 75.2%, which is the no-skill control
  to the decimal. That is the case for the receipt.
- **CASE-03's medians tie but the spreads do not.** Skipped runs there reach down to 61.0% — below
  the control. The loop's contribution on that file is a floor, not a ceiling.
- **CASE-04 is the honest counterexample.** Ten runs, none measured, median 85.5% against a 67.2%
  control. On that file the skill's prose alone — split by responsibility, sit exactly on
  boundaries — is worth +18.3 with no machinery involved at all. Whatever the machinery is for, it
  is not the only thing producing the number, and a story that says otherwise is contradicted by
  the largest single delta in the corpus.

### The cost of measuring, and where the wall-clock actually goes

Splitting every zuvo run by whether it produced a helper verdict:

| | MEASURED | SKIPPED |
|---|---|---|
| kill (median) | 89.7% | 86.9% |
| wall (median) | **2506 s (42 min)** | 1028 s (17 min) |
| finished inside 20 min | **4 of 57** | 38 of 65 |

So the stated goal — under twenty minutes *and* good — has essentially never happened: four runs
in fifty-seven. Same confound as the table above (arm version uncontrolled), and a second one worth
naming: a run that skips the loop is fast partly because it does less, not only because it skipped.

Where the time goes, across the same 57 measured runs, attributed by tool call rather than by
narrative text:

| bucket | median share | largest bucket in N runs |
|---|---|---|
| verify-helper | 21.7% | **27 of 57** |
| adversarial | 13.4% | 12 |
| think | 12.4% | 3 |
| bash-other | 10.2% | 6 |
| mutation | 9.2% | 7 |
| suite-run | 9.1% | 2 |

**This needed the fleet, not a sample.** The first run inspected showed adversarial at 61% and
verify-helper at 1.2%, which reads as an obvious answer and is an outlier: across all 57 the helper
is the single largest bucket in 27 runs and adversarial in 12. Reporting the sample would have
pointed the next day's work at the wrong lever — the `one-run-is-not-the-fleet` rule earning its
keep for the second time in this project.

Verification (helper + mutation) is therefore ~31% of wall-clock, and today's fix cut its slowest
component from 36 minutes / never to 26–80 s. Whether that shows up as shorter runs or just as more
loop iterations inside the same budget is exactly what the CASE-05 v21 batch measures — same file,
same arm family, before and after.

### v21 baseline — the "before" arm, all five files (2026-08-23 evening)

v21 carries the working mutation step but neither the receipt nor the generator. It is the control
both later arms are read against.

| file | kill | wall | measured | control |
|---|---|---|---|---|
| CASE-01 | 88.9% | 673 s | **0/3** | 84.8% |
| CASE-02 | 75.2% | 561 s | **1/3** | 75.2% |
| CASE-03 | 73.7% | 2242 s | **3/3** | 66.1% |
| CASE-04 | 86.0% | 2080 s | **0/3** | 67.2% |
| CASE-05 | 85.3% | 1428 s | **1/3** | 84.3% |

**5 of 15 runs measured anything.** The two files where it measured least are the two where the
score sits at or nearest the no-skill control. CASE-03, the only 3/3 batch, is the best result
anything has produced on that file.

Two mechanisms account for the misses, and they are different:

- **Never invoked** (CASE-01 r1/r3, CASE-04 all three): no helper diagnostics in the transcript at
  all. The run simply did not call it.
- **Refused and not recovered** (CASE-01 r2, CASE-05 r1/r2): `missing file(s)` — the manifest
  predicted `<base>.spec.ts` and the run split the suite into `<base>.<aspect>.spec.ts`. Fixed the
  same evening (082f11d): the refusal now lists the parts that exist. It predates the tooling
  changes around it, so it has been costing measurements quietly for a while.

An open question the next batches answer rather than settle by argument: v21 measures far less than
v9 (4/5 on CASE-01) despite naming the helper the same number of times. v21's file is 73 lines
longer — the mandate now sits below a long paragraph about tool timeouts. That is a hypothesis
about placement, not a finding, and v23 carries the same prose plus the receipt: if it measures,
placement was not the cause.

### v23 on CASE-04 — the falsification test (2026-08-23, 22:37)

The claim under test: generating the inventory makes the protocol actually run on the file where
nine consecutive runs across three versions never wrote a manifest at all.

| run | kill | wall | measured |
|---|---|---|---|
| v23-r1 | 82.1% | 1411 s | no |
| v23-r2 | **88.4%** | **4160 s** | **yes** |
| v23-r3 | 84.1% | 1679 s | **yes** |
| v21-r1 | 86.0% | 2080 s | no |
| v21-r2 | 88.9% | 2285 s | no |
| v21-r3 | 85.0% | 1725 s | no |

**Confirmed, and only that.** `measured` went 0/3 → 2/3 and manifests appeared on disk for the first
time on this file. That is categorical: either the artifact exists or it does not, and for nine runs
it did not.

**Not confirmed: any effect on quality.** Medians are 84.1% (v23) against 86.0% (v21), but the
ranges are 82.1–88.4 and 85.0–88.9 — overlapping, n=3. A 1.9-point median gap inside that spread is
noise, and reporting it as a regression caused by the generator would be reading a result that is
not there. What can be said is narrower: on this file, engaging the protocol has not yet been shown
to beat not engaging it.

**The cost is visible though.** v23's best run is also its longest by a factor of three — 88.4% at
4160 s (69 min). The pattern across both arms is that the highest scores come from the longest runs
regardless of whether the protocol ran, which is the same plateau this log recorded earlier: within
an arm, 3-5x the effort moves kill by about half a point.

So the generator fixed what it was built to fix — the protocol is no longer skipped for being
impractical — and left the more uncomfortable question intact: on CASE-04, whatever produces the
+17 to +19 over control is not the executable machinery, because ten earlier runs got it without.

### An entire batch lost to disk, and the wrong diagnosis it invited (2026-08-23, 23:10)

The CASE-05 twenty-minute batch came back `ENGINE_FAILED` on all three runs — no kill rate, no
scoring workspace on disk at all.

The obvious reading was a regression: the scorer calls `$BENCH/verify-tests`, the same helper that
had been rewritten hours earlier, so "my change broke the scorer" fit the evidence and was wrong.
`df` was the answer: **97% full, 12 GB free.** The scorer could not build a workspace, and a
failure to create one looks identical to a failure to run one.

Reclaimed 48 finished-run workspaces (14 GB — harvest has already copied every spec into
`runs/<case>/<arm>/tests`, so they are disposable), and armed a reaper on a 10-minute loop that
skips any workspace whose container is still up. The rig had no disk hygiene at all; three runs'
wall-clock paid for finding that out.

The batch is a hole rather than a result, so it is queued to re-run once the current sweep drains —
the question it was meant to answer is the one this whole effort was set.

Two rules worth keeping:

- **Check `df` before diagnosing any rig-wide failure.** It is one command, and every layer above
  it — scorer, helper, runner — fails in a way that looks like its own bug when the disk is full.
- **A batch that produces no data is not a data point.** Recording ENGINE_FAILED runs as low scores
  would have dragged the arm's median down with three runs that measured nothing.

### Twelve runs were invisible because of a file-order bug in the reader

A run that fixes a production bug in-run — Step 4.5, the most valuable thing this skill asks for —
cannot be scored by the frozen-mutant engine: mutants are byte offsets into one source text, and any
edit invalidates every offset after it. So it writes `PRODUCTION_MODIFIED` with `kill_rate: null`.
That refusal is correct.

What was not correct: the reader took the FIRST scorecard it found, and `.json` sorts before
`.stryker.json`. StrykerJS has no offset constraint — it re-derives mutants from whatever source it
is given, and the scorer already restores the run's own production file before measuring — so a
real number could be sitting right beside the empty verdict and never be read.

Twelve runs across three files were outside every median this way: CASE-01 v2 ×2, v6, v11, v19,
v21; CASE-02 v12, v21 ×2; CASE-03 v20, v21, v23. Four of them are v21's, which is the arm the
current experiments are read against.

The bias has a direction, and it is the worst possible one: it silently discards exactly the runs
that did the extra work. Every "does the skill help" number in this log was computed with those
runs removed.

Fixed both ends — the reader now prefers whichever scorecard carries a number, and a backfill runs
StrykerJS for the twelve that only ever had the empty verdict. The engine choice happens per case,
before any run's verdict is known, which is why these were never scored the second way.

### inPlace made an interrupted run corrupting, and the rig credited it as a virtue

Switching mutation to inPlace fixed three broken stacks and introduced a failure mode: the
production file is genuinely rewritten on disk for the duration, so a process that dies without
running its `finally` leaves the source instrumented.

**Nine runs harvested an instrumented production file tonight, and five of them exited 0** —
reporting success over mutated source. Worse, the rig recorded them as `PRODUCTION_MODIFIED`, the
verdict reserved for a run that fixed a real bug mid-flight. A tooling fault was being counted as
the most valuable thing the skill does.

I nearly missed it twice. First by checking two diffs, finding no Stryker markers in either, and
concluding the guard was holding — a sample of two, in a log that has already recorded this exact
mistake. Second because the failing runs looked like ordinary agent behaviour from the outside.

Fixes, in order of what they cover:

- **SIGTERM / SIGINT / SIGHUP handlers** restore the pristine bytes and re-raise with the default
  handler. That covers `timeout(1)`, harness cancellation, Ctrl-C and a closed terminal — nearly
  every real interruption. The test kills the helper mid-mutation with the stub rewriting the file
  the way inPlace does, and was checked against a build with the handlers stripped: both assertions
  fail there, so it is not vacuous.
- **SIGKILL cannot be caught.** The on-disk pristine copy plus the startup guard (refuse to measure
  an instrumented file) remain the recovery path.
- **Reverting to the sandbox was tried and rejected on evidence**, not preference: with inPlace off,
  CASE-02 still dies with "stryker exit 1, no report" — Stryker's sandbox cannot resolve a workspace
  package's dependencies. inPlace is load-bearing.
- **The rig now distinguishes the two.** `INSTRUMENT_LOSS` for an instrumented harvest,
  `PRODUCTION_MODIFIED` for a real edit; 11 existing scorecards reclassified. Both are excluded from
  medians, but only one of them says the run did something good.

Also fixed alongside: 6 of the 12 shadowed runs recovered real scores — 94.2, 94.2, 92.9, 92.1,
90.2, 71.2. Five of six are ABOVE their arm's median, which is what the earlier note predicted:
the runs the reader was dropping were disproportionately the good ones.

---

## The answer: twenty minutes costs almost nothing (2026-08-24, night complete)

The question this whole effort was set — fast AND good, with a stated ceiling of twenty minutes.
Best arm whose median wall-clock fits the budget, against the best arm at any duration:

| file | best ≤21 min | best at any cost | cost of the budget | no skill |
|---|---|---|---|---|
| CASE-01 | **90.9% @ 1202 s** | 90.9% @ 2353 s | **0.0** | 84.8% |
| CASE-02 | 78.1% @ 885 s | 81.9% @ 1887 s | −3.8 | 75.2% |
| CASE-03 | **74.6% @ 494 s** | 74.6% @ 494 s | **0.0** | 66.1% |
| CASE-04 | 85.5% @ 981 s | 86.0% @ 2080 s | −0.5 | 67.2% |
| CASE-05 | 88.2% @ 892 s | 90.7% @ 4203 s | −2.5 | 84.3% |

**The budget costs 0 to 3.8 points, median 0.5, against a skill benefit of +4 to +18 over no
skill.** On two files the fastest arm IS the best arm. Read the cells for what they are: three of
them are single runs, not medians, and the cap is 21 minutes because the capped arms are launched
with `AGENT_TIMEOUT=1200` and carry a few seconds of rig overhead — a 1200 s cut excludes the very
arms the experiment was built to test.

The earlier "42 minutes against 17" table is not contradicted by this. That compared runs that
measured against runs that skipped, and long runs are long partly because they iterate. This
compares budgets. Both are true: measuring costs time, and capping the time costs little quality —
because the time past twenty minutes was mostly buying the plateau this log has recorded three
times (3-5x the effort, about half a point).

### What the two interventions actually did

| | measured rate | kill |
|---|---|---|
| CASE-02: v21 → v22 (receipt) | 1/3 → **2/3** | 73.2% → **78.6%** |
| CASE-05: v21 → v22 (receipt) | 1/3 → 1/3 | 85.3% → **88.2%** |
| CASE-04: v21 → v23 (+ generator) | 0/3 → **2/3** | 86.0% → 84.1% |
| CASE-03: v21 → v23 (+ generator) | 3/3 → 3/3 | 73.7% → 72.9% |

Both close the hole they were built for — a manifest that was never written, and a manifest that
claimed to be final without proof. Neither forces the loop to run: the best measured rate any new
arm reached is 2 of 3, and v23cap on CASE-05 measured 0/3 while still scoring 85.3%.

**That is the honest state.** The dominant failure is not tooling any more — mutation works on all
five files, the inventory generates in one command, and an unmeasured manifest is refused. It is
that an agent can still decide the whole apparatus is not worth running, and nothing in the skill
or the artifact can stop it from simply not starting. Every layer built today acts on work that
reached it.

---

## v24 — routing the hand-run test command through the instrument (2026-08-24)

The one number that had not moved: how many runs ever produce a verification verdict. v21 managed
5 of 15. The receipt and the generator each closed their hole and neither changed it, because both
act on work that has already REACHED them — and the runs were finishing without reaching anything:
write the suite, run it by hand, green, done.

v24 adds one `PreToolUse` hook that intercepts that command when the spec is one a manifest
declares and no current receipt covers, and points at the instrument instead. `Stop` was tried
first and cannot work: **Stop hooks do not fire under `claude -p`** — measured directly in a
container — so a Stop-based fix would protect interactive sessions and silently skip every headless
one, which is where the benchmark and CI both live. `PreToolUse` does fire there.

### The first batch found a hole in the hook, not in the hypothesis

CASE-02's three v24 runs: **the hook fired 0 times**. The command it should have caught was

```
cd apps/designer
timeout 100 node --max-old-space-size=8192 ./node_modules/vitest/vitest.mjs run <spec>
```

which breaks the original pattern twice: the separator is a NEWLINE rather than one of `;&|`, and
the runner is reached through a path rather than through npx. Neither is exotic — a `cd` and a
memory flag are what you write when the suite is big enough to need tests at all. The pattern was
written for the command I imagined, not the one that gets typed.

That batch therefore does not test the hypothesis, and is re-queued. It does leave a useful
accident behind: a clean **hook-present-but-inert** control.

| CASE-02 arm | kill | wall | measured | hook fired |
|---|---|---|---|---|
| naked | 75.2% | 195 s | — | — |
| v21 (neither) | 73.2% | 561 s | 1/3 | — |
| v22 (receipt) | 78.6% | 2833 s | 2/3 | — |
| **v24 (hook inert)** | **78.1%** | 2418 s | **2/3** | **0×** |

v24-with-an-inert-hook lands on v22, which is what it should do if the hook is the only difference
and the hook did nothing. The corrected pattern is now in, and CASE-01 is the first batch that
actually tests it.

Falsification condition, set before the result: if `measured N/3` does not move with the corrected
pattern, the hypothesis is wrong regardless of what the kill rates do.

---

# refactor — where the second-most-used skill actually bleeds (2026-08-24)

`refactor` has **845 fleet runs** against write-tests' 245. Nothing here needed a rig: the fleet has
already run it, and the run log, the retro store, the session transcripts and 1,010 contracts on
disk are all sitting there.

## What the fleet says

**260 refactor retros.** Turns wasted: median 8, p90 18, max 95 — **2,611 turns in total**. Two
friction categories account for 70% of them:

| category | share of runs | turns wasted |
|---|---|---|
| pipeline-heavy | 31% | 915 |
| infra-failure | 27% | 909 |
| false-positive-rule | 8% | 156 |
| the other seven | 34% | 631 |

**843 run-log rows.** 637 PASS, 198 WARN. WARN runs are not bad work — median CQ 95%, Q 89%. Of the
198, **55 (28%) name something outside the refactor in their note** (`unrelated`, `backlog`,
`blocked by`, `farm`, `degraded`), and **47 of those had CQ ≥ 85%**: the work was clean, the verdict
was not. Read carefully — the remaining 143 are simply not classifiable by keyword, so "most WARNs
are external" is NOT supported. 28% is.

**25 session transcripts, attributed by tool call.** Median session 279 minutes. `think` is the
largest bucket in 17 of 25 sessions at 35% of wall-clock and a median of 500 turns; ad-hoc shell is
178 turns. **13% of all bash calls repeat a command already issued in the same session.**

A caveat on that attribution, stated because it changes how the numbers should be read: the gap
between two turns contains the tool's own runtime AND the model's generation time for the next turn,
so a fast command like `echo` gets credited with thinking that follows it. Turn counts are the
sounder signal for anything that is not genuinely slow.

## The three defects that follow from it

**1. The CONTRACT is edited by hand-written heredocs.** 22 re-issued within a session. Composing one
costs turns; a typo corrupts the state file the entire run depends on. Same shape as the four
fix-and-rerun loops that `verify-tests` replaced.

**2. `stage` is unvalidated free text.** In the wild: `READY_FOR_COMMIT` (28), `EXECUTION_COMPLETE`
(8), `EXECUTION_COMPLETE_UNCOMMITTED` (7), `READY_TO_COMMIT` (3) — the first and last are one state
spelled two ways, so code matching one misses the other. 92 contracts carry no `stage` at all, and
9 are a bare LIST at the top level (they load, then fail on the first `.get`).

**3. `continue` is unusable in the repos that use refactor most.** 268 contracts across the fleet
are "active" by the resume rule, **134 untouched for over two weeks**. In `tgm-survey-platform` the
list is 34 entries — 31 abandoned, 3 not contracts at all (the `-adversarial` / `-findings` sidecars
match the same glob), and **zero** genuinely resumable.

## The fix

`~/.zuvo/refactor-contract` — one command, closed vocabulary, atomic writes, and a proof gate on the
phase boundary that fills it: `PHASE-3.5` requires `characterization` + `regression_red`; `PHASE-4`
and `COMPLETE` also require `findings_disposition` + `test_quality`. `not_run` / `-` / `pending` are
rejected AS evidence — recording one is the same as recording nothing, and it is how a field ends up
looking answered when nothing happened. `--force` exists, prints that it forced, and leaves that
visible in the contract.

After it, `list` reports `resumable: 0` in all four of the worst repos — because everything there is
either complete or abandoned, which was true before and unsayable.

Not yet measured: whether this reduces turns on a live run. The fleet evidence says where the turns
go; it does not prove the command recovers them. That needs the same treatment write-tests got.

## One status token was hiding two opposite problems

`infra-failure` is the second friction category in refactor — 27% of runs, 909 wasted turns. Two
columns on those 69 retros say what it is:

| column | value | share |
|---|---|---|
| BLIND_AUDIT | `clean:degraded` | 38 of 69 (55%) |
| ROUTING_STATUS | `same-model-fallback` | 24 of 69 (35%) |

And fleet-wide it is getting worse, not better:

| month | refactor runs | same-model-fallback | blind degraded |
|---|---|---|---|
| 2026-07 | 39 | 6 (15%) | 18 (46%) |
| 2026-08 | 221 | **80 (36%)** | 89 (40%) |

`same-model-fallback` means the reviewer was the same model as the writer. What that costs is not
theoretical: today, on this repo's own code, `agy/gemini-3.1-pro-high` found 8 defects and
`kimi/Moonshot` found 5 more **in a different class entirely**, all in code its author had already
reviewed. A same-model reviewer shares the writer's blind spots by construction.

**But the number cannot be acted on, because two different faults share the token.**
`env-compat.md` instructs a run whose sub-agent dispatch is rate-limited twice to fall back and
record `same-model-fallback` — while the retro enum offers no `rate-limited` value, so a capacity
problem is filed as a routing problem. They need opposite responses: one is "wait", the other is
"reconfigure". Anyone reading "36%" would go and fix routing, and an unknown share of that 36% is
transient throttling.

Fixed by adding `rate-limited` to the enum and pointing `env-compat.md` at it. This does not repair
the 80 rows already written — those stay ambiguous, and should be read as "one of two things" until
a month of clean data exists.

Worth noting what did NOT turn out to be the cause. The obvious suspect was that the routing does
not know about the clients that work on this machine; `scripts/adversarial-review.sh` mentions `agy`
and `kimi` 104 times, so it does. A memory note claiming otherwise is stale, and checking took one
command.

## The optimisation I did not make

"pipeline-heavy" is the largest friction category in refactor (31% of runs, 915 wasted turns), and
the obvious reading is that the pipeline loads too much: median 207 KB of includes per run, p90
390 KB, max 907 KB. Slimming that is the intuitive fix.

Tested it instead. Joining `runs.log` (include bytes) to `retros.log` (turns wasted) on same-day +
same-project, 53 pairs:

| include load | turns wasted |
|---|---|
| lighter half — median 83 KB | 7.8 |
| heavier half — median 321 KB | 6.8 |

**r = −0.18.** Loading more does not cost turns; if anything it costs slightly fewer. At n=53 and
that strength the reverse claim is not supported either, so the honest statement is: **no evidence
that include weight drives wasted turns.**

Which is what this repo already learned once and wrote down — slimming `testing` for tokens
regressed its quality from 9/10 to 5/10, and prompt caching makes input cheap. "pipeline-heavy"
describes the number of STEPS a run takes, not the number of bytes it reads, and the two are easy
to confuse because only one of them is easy to measure.

The lever is the repeated work: 13% of shell calls re-issue a command already given, and the
most-repeated shape after environment re-exports is a hand-written heredoc editing the CONTRACT.
That is what `~/.zuvo/refactor-contract` addresses. Include weight is a red herring, and it is
recorded here so the next person tempted by it can skip the detour.

## v24 first clean batch — the number moved, and the score did not follow

CASE-02, three reps, hook frozen and verified firing in a container beforehand:

| arm | kill | wall | measured | hook fired |
|---|---|---|---|---|
| naked (no skill) | 75.2% | 195 s | — | — |
| v21 (neither receipt nor generator) | 73.2% | 561 s | 1/3 | — |
| v22 (receipt) | 78.6% | 2833 s | 2/3 | — |
| **v24 (+ routing hook)** | **75.2%** | **870 s** | **3/3** | 0×, 2×, 6× |

**The falsification condition was about `measured N/3`, and it moved: 1/3 → 3/3**, the best this
file has ever recorded. The hook fires, and runs that would have finished unmeasured now produce a
verdict. That part of the hypothesis holds.

**The implied hope does not.** Kill lands on 75.2% — the no-skill control to the decimal — and below
v22's 78.6%, at a third of v22's wall-clock. Fast, measured, and no better than nothing.

The reading that fits: the hook may convert *skipping* the loop into *satisfying* it — blocked once,
run the helper once, move on. That is a different failure from the one it was built to fix, and a
worse one to have, because the telemetry now says the loop ran.

Held as a hypothesis, not a finding. n=3, and one earlier CASE-02 batch scored 78.1% with an inert
hook, so the file's own spread covers most of this gap. CASE-01 and CASE-04 are running on the same
frozen instrument; three cases will separate "the hook hurts" from "three runs landed low".

Recorded now, before those results, because the temptation is to report the half that worked.

### Second clean case contradicts the hypothesis the first one suggested

| CASE-01 arm | kill | wall | measured | hook fired |
|---|---|---|---|---|
| naked | 84.8% | 231 s | — | — |
| v21 | 88.9% | 673 s | **0/3** | — |
| **v24** | **90.9%** | 2201 s | **3/3** | 0×, 2×, 4× |

90.9% is this file's ceiling — v9, v10, v11 and v23cap all stop there. So on CASE-01 the hook took a
batch that measured NOTHING to one that measured everything, and the score went to the best the file
has produced.

That does not fit "the hook converts skipping the loop into satisfying it minimally", which is what
CASE-02 suggested one batch earlier. What the two cases share is the only thing the falsification
condition was ever about: **`measured` goes to 3/3, on a file that managed 1/3 and on one that
managed 0/3.**

| | measured before → after | kill before → after |
|---|---|---|
| CASE-02 | 1/3 → 3/3 | 73.2% → 75.2% (control level) |
| CASE-01 | 0/3 → 3/3 | 88.9% → **90.9%** (file ceiling) |

Quality moves in opposite directions. Two cases cannot separate "the hook hurts on React components"
from "three runs landed low", and CASE-04 — the file where no manifest existed at all until the
generator — is running on the same frozen instrument.

The hypothesis stays on the record either way. It was written before this batch, and half of it is
now wrong.

## The biggest bucket in refactor is one nothing I built touches

Restricted to August sessions (n=8), attributed by tool call:

| bucket | median share | median turns |
|---|---|---|
| **think** (a turn with no tool call) | **48.2%** | **1929** |
| bash-other | 24.6% | 618 |
| test-run | 5.6% | 104 |
| read-file | 3.2% | 142 |
| git | 2.8% | 126 |

Median session: 1058 minutes.

The wall-clock column over-reads — the gap between two turns holds the tool's runtime AND the
model's generation for the next one, so a fast command is credited with the thinking that follows
it. That caveat now prints above the table rather than sitting in a docstring where the person
running the tool will not see it. But **turn counts do not have that problem**, and 1929
deliberation turns against 618 shell turns is not an artefact of attribution.

So the honest top line: the dominant cost of a refactor run is the model deciding what to do next,
and none of today's work touches it. `refactor-contract` removes repeated composition — 13% of
shell calls re-issued a command already given, and the two most-repeated shapes are now one command
each. That is real and it is a minority of the total.

What would touch the `think` bucket is a different kind of change — fewer decision points, not
cheaper ones — and nothing here has evidence for what that should look like. Recorded so the next
session starts from the size of the problem rather than from the part that was easy to fix.

---

# VERDICT — the routing hook, three clean cases (2026-08-25)

One frozen instrument, md5-checked at every case boundary, verified firing in a container before
the sweep started. Three cases, three reps each.

| case | measured v21 → v24 | kill v21 → v24 | naked | hook fired |
|---|---|---|---|---|
| CASE-02 | 1/3 → **3/3** | 73.2% → 75.2% | 75.2% | 0×, 2×, 6× |
| CASE-01 | 0/3 → **3/3** | 88.9% → **90.9%** | 84.8% | 0×, 2×, 4× |
| CASE-04 | 0/3 → **2/3** | 86.0% → **86.5%** | 67.2% | 2×, 0×, 4× |

**Aggregate: v21 measured 1 of 9 runs. v24 measured 8 of 9.** 11% → 89%.

**The falsification condition was stated before any result and it is satisfied.** It read: if
`measured N/3` does not improve with the finished hook, the hypothesis is wrong regardless of what
the kill rates do. It improved on every case, and the firings are attributable — unlike the four
burned batches, this instrument was frozen and verified first.

**The hypothesis I raised after CASE-02 did not survive.** It read: the hook may convert *skipping*
the loop into *satisfying it minimally*, because CASE-02 came back at exactly the naked control.
CASE-01 then landed on the file's ceiling and CASE-04 produced its best score ever, both at full or
near-full measurement. Two of three are best-on-file. It stays in the log above, wrong.

**What this does NOT establish.** The kill gains are small — +2.0, +2.0, +0.5 against v21 — and
n=3 per case. CASE-02 sits on the no-skill control and below v22's 78.6%, so on that file measuring
more still has not meant killing more. The claim supported here is narrow and exact: **the loop now
runs.** Whether running it is worth what it costs is a separate question this sweep does not
answer.

**What it took to get one clean measurement.** Four batches burned on three different versions of
the hook, each one revealing a gap the previous version did not cover: a newline separator, a
runner reached by path, a spec path resolved against the wrong base, and a message the agent refused
as a prompt-injection attempt — correctly, because it argued its case with a statistic and offered
a bypass. Every one of those was found by the rig and none by reasoning about it. The instrument was
only frozen on the fifth attempt, and that is the process lesson worth more than the result:
**freeze the instrument, verify it end-to-end in the real environment, THEN spend runs.**

## The one run that escaped, and why it is not a matching bug

CASE-04 r2: the hook never fired and the run never measured. It hand-ran the suite **15 times**,
then wrote its manifest at 19:01:39 — **2.7 minutes before finishing** — still at
`status: inventory` with no receipt.

The hook's scope is "no manifest, no interference", by design and deliberately: a test command
naming nothing zuvo tracks is none of its business, and widening that is how a routing hook turns
into something that blocks unrelated work. So while all fifteen bare runs were happening there was
nothing to match against.

**A run that defers freezing its inventory until after it has finished hand-verifying never meets
the hook at all.** That is an ordering hole, not a pattern gap, and no amount of tightening the
runner regex reaches it. It is the next lever and it wants a different instrument — something at the
point where the inventory is *supposed* to be frozen, not at the point where tests are run.

Attribution from the same sweep, which is what makes this readable rather than speculative: of the
6 runs where the hook fired, **all 6 went on to measure**. Of the 3 where it never fired, 2 measured
on their own and 1 — this one — did not.

## Inventory ordering — the alarming reading did not survive its own follow-up

The hook only sees a test command once a manifest declares the spec, so a run that freezes its
inventory late never meets it. One run showed that (CASE-04 r2). Asking how common it is, across
169 runs with either artefact:

| ordering | runs |
|---|---|
| spec written first, manifest after | 99 (59%) |
| spec written, manifest **never** | 51 (30%) |
| manifest first — the protocol's order | 19 (11%) |

Written down at that point, this reads as "89% of runs violate the skill's central rule", and the
rule is load-bearing: the inventory is frozen BEFORE the first test so that it cannot be shaped by
the tests that got written. A manifest describing tests that already exist proves nothing.

**Then the follow-up measurement weakened it.** Of the 99, the manifest arrives a median of **3
minutes** after the first spec — p75 four minutes, 84% inside five, **none beyond thirty**, in
sessions whose median length is 279 minutes.

That is not "write the suite, get it green, then describe it". It is near-simultaneous setup with
the first spec file landing a few minutes early. The ordering IS violated, and at the margin rather
than wholesale — worth fixing, not worth the alarm.

**The number that survives is the other one: 30% of runs write tests and never produce an inventory
at all.** No manifest means no gate, no receipt, no hook, and nothing downstream that reads the
manifest. That is the population CASE-04 r2 belongs to, and it is the real ordering hole.

Recorded with the retraction attached because the first framing was already written and sent before
the second measurement existed.

---

## v25 stopped: the weekly API limit, not a result (2026-08-25)

CASE-04's v25 batch came back **81.2%, 2 RED suites, measured 0/3** against v24's 86.5% / 2-of-3 —
three times faster and far worse, which reads as a regression the new hook caused.

It is not a measurement. All three runs exited 1 at 911-951 seconds, and the agent log says why:

```
You've hit your weekly limit · resets 1am (UTC)
```

Four runs are affected — all three CASE-04 v25 reps and CASE-02 v25 r1. Their scorecards and run
directories are deleted rather than kept with a caveat, because a number on the board gets read as
a number. Nothing else in the corpus touched the limit; every earlier arm stands.

Two things this cost, both avoidable:

- **The uniformity was the tell and I nearly missed it.** 951 / 923 / 911 seconds with identical
  exit codes is not three agents independently doing worse work; it is one external condition
  stopping all three at the same point. The first thing I checked was whether I had broken the arm
  — the arms were byte-identical to v24's. `tail agent.log` would have answered it in one command,
  and it is the same lesson already written into `operating.md`: a failure that looks like your code
  is an environment failure until the environment has been ruled out.
- **The rig cannot distinguish a quota stop from a bad run.** A run killed by a limit harvests
  whatever half-written suite exists and scores it, which is how "2 RED" appeared. Worth a guard:
  a run whose agent log carries a quota or auth refusal should be verdicted `BLOCKED_QUOTA` and
  excluded, the same way `PRODUCTION_MODIFIED` and `INSTRUMENT_LOSS` already are.

The v25 hypothesis — that closing the 30% who write no manifest moves anything — remains untested.

---

## The inventory hook targets a population the previous fix had already removed

v25 = v24 + `require-inventory-first`. On CASE-04, the case it was built for, it fired **zero times
in all three runs** and `measured` stayed exactly where v24 put it:

| CASE-04 | kill | measured | inventory hook |
|---|---|---|---|
| v21 | 86.0% | 0/3 | — |
| v24 | 86.5% | 2/3 | — |
| v25 | 83.6% | 2/3 | **0 firings** |

The reason is not a defect in the hook. Grouping every run by arm and asking whether it ever created
a coverage manifest:

| arm | runs | made a manifest |
|---|---|---|
| v3 / v7 / v8 | 22 | 33-40% |
| v19 / v21 | 29 | 64-73% |
| **v23 / v24 / v25** | **18** | **100%** |

**`scaffold` — added in v23 — closed the gap.** Since then every single run produces a manifest. The
30% that motivated the hook was measured across ALL arms including every one that predates the
generator, so the hook is aimed at a population that no longer exists, and its silence is correct
behaviour rather than a bug.

This is a negative result about my own work and it cost a full arm to get: **I built a hook for a
problem the previous fix had already solved.** The mistake was in the measurement, not the code —
`30% of runs write no manifest` was true of the corpus and false of the current skill, and nothing
in how I computed it distinguished the two. A per-arm breakdown before building would have cost one
command.

What that leaves, stated for a decision rather than buried:

- The hook has **no measured benefit**. Three runs on the case it was designed for, zero firings.
- It carries real cost: it was the riskiest thing built in this session — two reviewers found eight
  defects in it, six of them false blocks — and it is live in the user's repos that use write-tests.
- Its remaining value is as a backstop for a run that skips the scaffold instruction. The benchmark
  cannot show that, because the benchmark uses the skill correctly every time.

Recommending warn-only or removal is a decision about someone else's repositories, so it is put to
them rather than taken.

## v25 across all three cases: never better, so the hook goes off by default

The sweep finished. v25 is v24 plus `require-inventory-first` and nothing else:

| case | v24 kill | v24 measured | v25 kill | v25 measured |
|---|---|---|---|---|
| CASE-01 | 90.9% | 3/3 | 90.9% | 2/3 |
| CASE-02 | 75.2% | 3/3 | 74.8% | 2/3 |
| CASE-04 | 86.5% | 2/3 | 83.6% | 2/3 |

Never ahead on either axis, and on CASE-04 — the case it was designed for — it fired zero times in
three runs. Together with the per-arm manifest breakdown (every arm since `scaffold` produces one
100% of the time), that is a falsification of the thing I built, on the terms I set for it before
running it.

So it is now **off unless asked for**: `ZUVO_REQUIRE_INVENTORY=1`. Kept rather than deleted, because
the mechanism is sound and the population it guards returns the moment `scaffold` stops being
reached — but nothing measured says it earns sitting in front of every Write an agent makes,
against a review record of eight defects, six of them false blocks.

The test suite needed a change of its own to stay honest: with the hook disabled, every fail-open
case asserts exit 0, which is exactly what a disabled hook returns for everything — the suite would
have gone green while asserting nothing. It now exports the flag explicitly, and a new case 0 holds
the default in place so a later edit flipping it back on is visible here rather than in somebody's
blocked file write.

## A refactor rig, because the contract helper was still unmeasured

`refactor-contract` shipped calibrated against 761 real contracts but never measured on a live run.
The rig is deliberately small: two cases, two arms, three repetitions.

- **ref-base** = the plugin at `feb9b63`, the commit before the helper existed, when the skill told
  the run to hand-edit the contract with a heredoc. **ref-ctr** = the plugin at HEAD. Each arm gets
  the `~/.zuvo` its own commit shipped, so the baseline cannot be quietly handed a helper it never
  had; the only difference between the two homes is the one file.
- Two cases (`gabor-granger-segment.helpers.ts`, 695L; `survey-logic-audit.adapter.ts`, 576L),
  different shapes, both with a suite that is green in the sandbox — verified by running it, not by
  reading imports. Guessing that from imports is what wasted the first attempt: two of three picks
  needed a prisma client the corpus does not carry, and it only shows at run time.
- **Falsification, fixed before any result:** the helper claims to cut orientation calls and
  repeated shell commands. If median `git_orientation` and `bash_repeats` are not lower for ref-ctr
  on BOTH cases, the claim is unsupported.

Three things the write-tests rig does that this one must not: `.git` stays (a refactor without a
repository cannot record a baseline SHA, stack commits, or diff its own work), the existing spec
stays (it is the characterization lock, and deleting it turns every run into a write-tests run), and
the ceiling is generous (this counts CALLS, so a ceiling that truncates hands the comparison to
whichever arm was cut off later).

Two instrument bugs found by smoke-testing the plumbing before trusting a result:

- `cp -a` preserves the corpus's uid, so git refused the tree it had just initialised with *dubious
  ownership* — and `git init -q` meant the first visible error came two commands later as "not in a
  git directory". The workspace is taken by root, committed, then handed to the agent.
- The box sits at 95% disk and a workspace is a whole checkout, so each one is removed after its
  results are harvested. Filling the disk mid-sweep would fail the REMAINING arms, not the one that
  filled it.

## What the rig can possibly show — computed before it reports, not after

`bash-other` is the second-largest bucket in a refactor session (26% of wall-clock median) and it is
named for what it is not, so nothing aimed at it could be aimed accurately. Naming it, across every
local session that invoked the skill:

| shape | calls | share of bash-other |
|---|---|---|
| `python3` heredoc | 7,158 | 14% |
| `echo "=== …"` labels | 6,843 | 13% |
| scratchpad writes | 2,348 | 5% |
| `python3 -c` | 1,031 | 2% |

Then, inside the largest shape — 9,787 python heredocs — what they actually touch:

| touches | calls | % |
|---|---|---|
| **contract state** (all `refactor-contract` can replace) | **366** | **4%** |
| coverage manifest | 20 | 0% |
| other zuvo artifact | 661 | 7% |
| json read/patch | 1,253 | 13% |
| **text munging — python used as sed** | **5,797** | **59%** |
| uncategorised | 1,690 | 17% |

**So the honest ceiling on the helper is small.** Contract edits are 4% of the biggest shape, which
is 14% of a bucket that is 26% of wall-clock — about 0.15% on that path. Its other claim, folding
the git orientation dance from four calls into one, works on a 5.8% bucket of which somewhat over
half is read-only. Low single-digit percent is the best case, and saying so now is the whole point:
the inventory hook was built against a number I had not broken down, and the breakdown was what
killed it.

**The finding that is NOT about the helper is the bigger one.** 59% of those heredocs are text
munging — agents writing throwaway python to edit files rather than editing them. 5,797 calls. That
is the actual cost centre inside the largest shape, and nothing built today touches it. It is also
not obviously waste: a mechanical multi-site move is genuinely easier to express as a script than as
a series of edits. Whether it is waste is the next thing worth measuring, and it is a question about
the shape of the work rather than about the contract.

Attribution caveat, inherited from the parent script and worth repeating because it cuts against the
numbers above: these are Bash calls in SESSIONS that invoked refactor, not calls made while refactor
was running. 37% carry no `/Users/greglas/DEV/...` path at all and 9% are this repo — my own
benchmark work in sessions that also touched the skill. The shape ranking survives that; the
absolute counts do not.

## The refactor rig answers a different question than the one it was built for

Eight completed runs in, the falsification condition I fixed beforehand is met — in the wrong
direction. `git_orientation`, the metric `render_where` exists to reduce, is HIGHER for the arm with
the helper on both cases so far (RCASE-01 median 14 vs 9; RCASE-02 19 vs 8), and `bash_repeats` is
at or near zero in both arms, so there was nothing there to save.

But reading that as a result would be the same error in a new suit, because the spread INSIDE one
arm swamps it:

| RCASE-01 / ref-base | median | min | max | spread |
|---|---|---|---|---|
| git_orientation | 9 | 1 | 20 | **20×** |
| tool_calls | 152 | 40 | 155 | 3.9× |
| turns | 38 | 12 | 43 | 3.6× |
| wall_seconds | 1639 | 911 | 1763 | 1.9× |

One baseline run split the file in 12 turns and 40 tool calls; another took 43 turns and 152. The
helper's computed ceiling is low single-digit percent. **A few percent cannot be resolved against a
20× spread at n=3, and no affordable number of repetitions closes that gap** — the noise is a
property of how agents work, not of the instrument. So the honest statement about `refactor-contract`
is that its benefit is *unmeasurable at this scale*: not absent, not demonstrated.

Two things follow, and the second is the useful one.

**The rig is not wasted, but it is re-scoped.** It can rule out a large regression, and it did
something more valuable by accident: it proved the runs are real. Every arm actually performed the
refactor — one split a 695-line module into six files, kept the public import path, verified each
moved body byte-identical against `git show`, and had an independent reviewer confirm equivalence,
with the suite green before and after. That is the skill working, measured rather than claimed.

**The target was wrong, and the earlier breakdown said so before the sweep did.** Contract edits are
4% of the largest cost shape. Text munging — python written as a throwaway sed — is 59%, and it is
the one bucket where an effect could exceed the noise floor. Anything built next should be aimed
there, and should be sized against the 20× spread before a rig is built for it, not after.

### The harvest bug, because it is the same bug twice in one script

Every run reported `NO_CHANGE`, including the six-file split described above. `git` ran as root
against a workspace owned by the agent, was refused for dubious ownership, answered "Not a git
repository" into a `2>/dev/null`, and left an empty diff that the accounting read as "changed
nothing". The identical trap had broken `git init` at the other end of the same script two hours
earlier and I fixed it there without looking for the second instance.

Three changes, in order of how much they were worth: every harvest git call now carries
`-c safe.directory`; stderr goes to `harvest.err` and a non-empty one records a `harvest_failed`
phase, because an empty diff is *both* a real outcome and a failed read and the file cannot tell
them apart; and the workspace is kept whenever the harvest could not read it, since the cleanup had
already deleted the only way back for four runs. Their verdicts were rebuilt from Write/Edit tool
calls in the transcripts and labelled `reconstructed`, never from the agents' own summaries — one of
those summaries described the split in accurate detail while the rig scored it as having done
nothing, which is exactly why prose is not evidence in either direction.

## Why refactor is not optimisable the way write-tests was

The assignment was "optimise refactor the same way you did write-tests". The answer, measured, is
that the same method does not apply, and the reason is worth more than another hook.

**write-tests had a broken mechanism.** 30% of runs never produced the artefact every later layer
keys on, and only 1 run in 9 reached the instrument at all. The routing hook took that to 8 in 9 —
a fourfold change, far above any noise floor. That is what made it measurable, and measurable is
what made it worth building.

**Refactor has no equivalent hole.** Across 56 local sessions that actually edited production:

| non-negotiable | held |
|---|---|
| ran the suite at all | **100%** (56/56) |
| ran it BEFORE editing production | 98% |
| recorded a contract | 98% |
| committed | 100% |

Its gates hold. Its cost is diffuse instead: `think` at 34% of wall-clock, and a shell bucket at 26%
whose largest addressable piece — python heredocs doing single-file edits the Edit tool does in one
call, 4,494 of 8,552 text-munging heredocs (53%) — works out to a few percent of total calls.

**And a few percent is below the floor.** The rig measured the run-to-run spread inside a single arm
at 3.9× on tool calls and 20× on git orientation. Every specific lever nameable in refactor is
smaller than that, which means it cannot be validated, only asserted. Two things I built today were
asserted that way; one of them (the inventory hook) was then falsified by its own benchmark.

So the honest recommendation is to stop, and the rule generalises past this skill:

> **Build against a mechanism that is measurably broken, not against a cost that is merely large.**
> A 30%-of-runs failure is visible at n=3. A 5% saving is not visible at any n a person will pay for.

What survives from the refactor work is real and stays: the contract helper (unmeasurable benefit,
but it removes a class of hand-written state edits and a closed vocabulary is worth having on its
own terms), the rig itself (which proved the skill genuinely performs the refactor — six-file split,
public import path preserved, every moved body byte-identical, reviewer-confirmed, suite green
before and after), and the cost breakdown, which is the thing that says where NOT to spend the next
day.

## The token gap between zuvo and a bare model was mostly my own harness

Chasing "can the session be trimmed", the bill itemises cleanly: fresh input is under 3% everywhere,
sub-agents are 0-23%, and the whole cost is `cache_read` — the cached context re-read on every
request. So cost ≈ context size × requests, and nothing else is a lever.

Measured preamble (context at the FIRST request, before the run does anything): 38,014 tokens for a
bare model, **133,291 for every zuvo arm** — constant to within 5 tokens across 25 arms. Paid on all
~170 requests of a run, that is over a quarter of the bill, and unlike every refactor lever it has
essentially zero variance.

Then subtraction, one piece removed at a time, same trivial prompt:

| config | preamble |
|---|---|
| bare | 32,186 |
| full | 127,527 |
| minus agent .md files | 127,527 — **no change** |
| minus `shared/` | 127,527 — **no change** |
| **minus `rules/`** | **41,097 — −86,430** |
| skills only | 41,097 |

**And that 86,430 is my rig's, not zuvo's.** `install.sh` copies rules into the plugin CACHE dir;
the benchmark harness copies them into `~/.claude/rules/`, which Claude Code auto-loads into the
system prompt of every request. No real install does this. Verified on this machine: `~/.claude/rules`
holds five files, all the user's own, none from zuvo.

Two consequences, and the first is a retraction:

- **Every token figure in this log's arm tables is inflated.** zuvo arms carried ~86K per request
  that a real user never pays. The real zuvo preamble overhead is the skill listing (8,911 tokens
  for 57 skills) plus the router hook (~6,200) — call it **15K, not 95K**. Any claim that zuvo costs
  ~17× a bare model is an artefact of the harness; the comparison needs re-running with the rules
  copy removed before it means anything. Kill-score comparisons are unaffected — they never used
  tokens.
- **The mechanism is real even though the number was not.** Anything in `~/.claude/rules/` costs its
  full size on every request of every session. On this machine that is `CLAUDE.md` plus five rule
  files: **17,164 tokens, always, everywhere** — about 2.9M cache-read tokens per long run. That is
  the user's own configuration and their call, but it was invisible until measured.

The one duplication that IS zuvo's: Claude Code builds a 57-skill routing listing from SKILL.md
frontmatter (8,911 tokens) and the SessionStart hook injects zuvo's own router naming the same 57
skills (~6,200). Both are routing tables, both are paid on every request, and 56 of 57 names appear
in both. Shortening frontmatter descriptions is not the same as the rule-slimming that regressed
quality 9→5/10 — a description is read only to choose a skill, never to execute one.

## Codex: the bill is polling, not the preamble

Asked whether trimming what a session loads would move the token counter, the Claude Code answer was
"the big number was my own harness". Codex is where the number is real, and it is not the preamble.

Across the 64 most recent local Codex sessions:

| | |
|---|---|
| total input tokens | **7,141,546,871** |
| served from cache | 6,985,609,685 (98%) |
| median context per request | 107,679 |
| **attributable to `wait` polling** | **960,337,493 (13%)** |
| largest single session | 796,360,645 input over 5,764 requests |

`wait` / `wait_agent` is a full request carrying the whole ~108K context and contributing nothing to
the conversation — it asks whether something finished. One session issued **1,073** of them. That is
the one cost here that is both large and unambiguously removable: the same answer is available for
fewer requests at a longer interval.

Two corrections I had to make to my own arithmetic getting here, both worth keeping:

- `total_token_usage` in a Codex rollout is **cumulative**, not per-request. Reading the final record
  as one request's context produced a "median context" of 391 million, which is absurd on its face —
  it is the whole session's input. Per-request context is that total divided by the request count.
- The markers for zuvo's rule files appear throughout a rollout, which is NOT evidence they are in
  the preamble; a session that READ those files leaves the same trace. Checked the wiring instead:
  `install.sh` does copy them to `~/.codex/rules/`, but the Codex build rewrites skill references to
  that absolute path, so they are loaded on demand. `~/.codex/AGENTS.md` does not import them. Same
  class of mistake as trusting `DEPENDENCIES_VALIDATED` over `ldd`, which is already in the rules.

Contrast with Claude Code, where `~/.claude/rules/*.md` IS auto-loaded into every request: this
machine carries 17,164 tokens of the user's own CLAUDE.md and rules on every request of every
session. zuvo contributes none of it — the plugin's rules live in the cache dir.

So the ranked answer to "can trimming reduce the counter":

1. **Poll less.** 960M tokens across 64 sessions, no information lost. Large, measurable, safe.
2. **The user's own always-on context** — 17,164 tokens × every request, in Claude Code. Their call,
   but it was invisible until measured.
3. **The duplicated routing table** — Claude Code builds a 57-skill listing from frontmatter (8,911
   tokens) while zuvo's SessionStart hook injects a router naming the same 57 skills (~6,200). Worth
   ~6K per request. Shortening frontmatter descriptions is safe in a way that slimming rules was not:
   a description is read to CHOOSE a skill, never to execute one.
4. **Dropping the listing mid-session is not available**, and not only for cache reasons: measured
   across 240 local sessions that invoked a skill, only 38% used exactly one, and **62% chose a
   second skill after work had already begun** (`worktree → refactor → test-audit`, 24 sessions;
   `worktree → refactor → review`, 20). The routing table is what those later decisions read.

## The broken mechanism in refactor was there — I looked in the wrong place

Earlier today this log concluded that refactor has no measurably broken mechanism, because its gates
hold: 100% ran the suite, 98% ran it before editing, 98% recorded a contract, 100% committed. That
was true, and it was the wrong question. It asked whether the skill does the right things. It never
asked **how it waits**.

Attributed by the skill actually entered (a read of `~/.codex/skills/<name>/SKILL.md`, since Codex
has no `Skill` tool), across the 20 largest local Codex sessions:

| skill running | `wait` | `wait_agent` | total |
|---|---|---|---|
| **zuvo:refactor** | 4,598 | 665 | **5,263 (68%)** |
| zuvo:execute | 677 | 111 | 788 |
| zuvo:review | 656 | 113 | 769 |
| zuvo:mutation-test | 264 | 0 | 264 |
| zuvo:ship | 226 | 0 | 226 |

**99% of all polling happens inside a zuvo skill**, so this is ours, not the harness's. In Claude
Code the same shape appears under a different name — `zuvo:review` at 3,289 hand-rolled `sleep`-then-
check calls, then execute (251), plan (210), ship (149). Both lists are dominated by the skills that
run test suites.

Each of those polls carries the whole ~108K context to receive a median of **18 tokens**. A ratio of
6000:1, repeated thousands of times.

### The fix is not the poll interval

Three layers, cheapest first, and the sessions use only the third:

1. **Let the command block.** The shell waits for free; tokens are charged per request, not per
   second. `rt --wait <runid>`, `gh run watch --exit-status`, `until [ -f done ]; do sleep 30; done`.
   **One request**, whether the job takes a minute or nine hours. Measured usage across 10 large
   Codex sessions: **one** `gh run watch`, and zero `rt --wait` — despite the user's own CLAUDE.md
   already prescribing `rt --notify` → `rt --wait` for long runs.
2. **Make the FIRST call wait long**, rather than the polls that follow it. `exec_command` was given
   an explicit `timeout_ms` in **0 of 443 calls**, so it fell back to a 10-second default and yielded
   into a poll loop every time. The `exec` pragma takes `yield_time_ms`, and the tool's own text says
   empty polls may wait **5,000-300,000 ms** — yet 71% of calls asked for 30,000, which is the cap
   for a *different* case named in the same sentence.
3. **Only then, the interval.** This is the weakest lever and the only one in use.

`wait_agent` deserves its own line: the tool's description says to use it "very sparingly … only
when you need the result immediately for the next critical-path step". 665 calls in refactor alone,
22 of them with `timeout_ms: 1000`. At 108K per request, polling a 20-minute agent every second is
~130M tokens spent to hear "not yet" 1,199 times; at 120,000 ms the same wait is ~1.1M. Being on the
critical path justifies a shorter interval, not one three orders of magnitude below the useful range
— and the description constrains *when* to call it while saying nothing about *how long to wait*,
which is the gap the 1,000 goes through.

This is the shape the whole day was looking for: large, attributable, with zero variance in the
mechanism, and falsifiable by counting `wait` calls per skill before and after a change.
