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
