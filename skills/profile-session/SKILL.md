---
name: profile-session
description: "Answers \"why was that session slow?\" from the agent transcript's own timestamps. Attributes wall-clock time to categories (tests/build, subagent dispatch, adversarial review, model thinking, stalls, user-away), ranks the biggest gaps, and names the specific commands behind them. Reads Claude Code session JSONL and Codex rollout JSONL. Modes: [transcript], --last, --skill <name>, --since <iso>, --compare <a> <b>."
category: Utility
---

# zuvo:profile-session — Where a session's wall-clock actually went

Sessions get slow for boring, measurable reasons: a full suite re-run per task, four-minute
adversarial passes that fired ten times, a sub-agent nobody was waiting on, an API stall. Guessing
at which one is expensive — the 2026-07 pipeline forensics measured 28 sessions and found the
dominant cost (thread-polling dead-air, ~88h) was **not** the one everyone blamed (adversarial
review, 38 minutes total across all 28).

This skill measures instead of guessing. It reads the transcript's timestamps, charges each gap to
the activity that preceded it, and reports the ranked truth.

**Scope:** wall-clock attribution for a single session, or a comparison of two, plus the token
totals the profiler computes (`tokens` block).
**Out of scope:** per-file / per-include context budgeting (`zuvo:context-audit`), skill quality
(`zuvo:skill-eval`), fleet-wide trends (`~/.zuvo/runs.log` + `zuvo:retro`).

### Tokens come from the script or they do not get reported

This line used to read *"Out of scope: token cost"*, and the profiler computed none — so every run
asked for a token breakdown produced one **by hand**. Five profiles of the SAME Codex session then
reported gross 202,362,002 vs 203,519,738, model calls 1,395 vs 1,406, and a "strict lower bound"
for polling of **45 / 55 / 83 / 396 / 400** calls — a 9x spread, each figure labelled `[M] MEASURED`.

The trap is not carelessness, it is the data: **the two transcript formats define `input_tokens`
with opposite cache semantics.** Codex's `last_token_usage.input_tokens` already includes
`cached_input_tokens`; Claude's `message.usage.input_tokens` excludes both cache fields. A reader
who aliases the key names together under-counts every Claude session by nearly its entire volume.

So:

- **Report only the `tokens` block the profiler emits.** It handles each format explicitly and is
  reproducible — same file in, same numbers out.
- **If `tokens.model_calls` is 0, the answer is UNKNOWN.** The transcript carries no usage records.
  Say that. Do not estimate from message sizes, character counts, or gap durations.
- **Never label a hand-derived figure `MEASURED`.** If you computed it yourself rather than reading
  it out of the profiler JSON, it is `[E] ESTIMATE` and the method belongs next to it.
- **`polling` is a fixed regex** (`tokens.classifier`), not a per-run judgement about which calls
  felt like waiting. Quote the classifier when you quote the number. Widening it is a code change
  to `profile-session.py`, reviewed once — not a decision re-made each run.
- **`gross` vs `fresh`:** `gross` is everything billed on the way in (cache reads included) plus
  output — the quota-shaped number. `fresh` excludes cache reads. Sub-agent spend is reported
  separately under `tokens.subagents` and is deliberately NOT folded into `gross`.

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ | Same as `--last` |
| `<path.jsonl>` | Profile that transcript |
| `--last` | Profile the most recent transcript for the CURRENT project |
| `--last N` | Profile the N most recent transcripts for this project, ranked by span |
| `--skill <name>` | Restrict the window to runs of that skill (uses `~/.zuvo/runs.log` timestamps) |
| `--since <iso>` / `--until <iso>` | Bound the analysis window |
| `--compare <a> <b>` | Two transcripts side by side — the before/after form for "did the fix help?" |
| `--json` | Emit the raw profiler JSON, no narrative |
| `--force` | Re-profile a transcript that already has a report. Without it a repeat is refused — see Phase 0.5 |

Non-interactive environments: no arguments defaults to `--last`.

## Mandatory File Loading

```
CORE FILES LOADED:
  1. ../../shared/includes/run-logger.md       -- READ
  2. ../../shared/includes/retrospective.md    -- READ
  3. ../../shared/includes/test-metrics.md     -- READ (frozen COST/SPEED formulas: FRESH_TOKENS, POLLING_CALL, TASK_WINDOW, ACTIVE_MIN — cite, never re-derive)
```

## Prerequisite

The profiler is `~/.zuvo/profile-session.py`, installed by `scripts/install.sh`. Resolve it the
same way every zuvo helper is resolved, and if it is absent say so and STOP — do not hand-roll a
timestamp analysis, because an ad-hoc one will not use the same attribution rules and its numbers
will not be comparable to any other run.

```bash
PS="$(command -v profile-session 2>/dev/null || ls ~/.zuvo/profile-session.py 2>/dev/null | head -1)"
[ -n "$PS" ] || { echo "profile-session.py not installed — run scripts/install.sh"; exit 1; }
```

## Phase 0: Locate the transcript

Transcripts are per-host, and the path encodes the project directory:

```bash
# Claude Code — directory name is the project path with / replaced by -
CC_DIR="$HOME/.claude/projects/$(pwd | sed 's|/|-|g')"
ls -t "$CC_DIR"/*.jsonl 2>/dev/null | head -5

# Codex — rollouts are not project-scoped; pick by mtime and confirm from the content
ls -t "$HOME"/.codex/sessions/**/rollout-*.jsonl 2>/dev/null | head -5
```

**The newest file is often not the interesting one.** A fresh session that just started is the
newest and has nine events in it. When the user says "that run was slow", rank by SIZE or by span,
not by mtime, and say which file you picked and why. `ls -tS` gives you the largest-first order.

If the transcript cannot be found, say so plainly and ask for the path — do not profile an
arbitrary file and present it as theirs.

## Phase 0.5: Refuse to profile the same transcript twice

**Do this BEFORE the analysis, not after it.** The check is one hash of a path; the analysis is
25-45 minutes of agent work.

```bash
ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)/zuvo}"
KEY="$(python3 "$PS" --run-key "$TRANSCRIPT" ${SINCE:+"$SINCE"} ${UNTIL:+"$UNTIL"})"
REPORT="$ZUVO_DIR/reports/profile-session-$KEY.md"

if [ -s "$REPORT" ] && [ "${FORCE:-0}" != "1" ]; then
  echo "ALREADY PROFILED — $REPORT"
  echo "  transcript: $TRANSCRIPT"
  echo "  Re-run with --force to profile it again."
  exit 0
fi
```

Write the report to `$REPORT`. A report is an artifact with a path, so the early exit can hand the
caller the actual file instead of telling them a matching retro "exists" somewhere.

**Why the key is the transcript and not the caller.** The retro layer deduplicates on
`skill + project + sha7`, and `project` is the directory the skill was INVOKED in. For most skills
that is correct — a review of repo A is not a review of repo B. Here it is wrong: the artifact
being analysed is a TRANSCRIPT, and a transcript is the same transcript whichever worktree the
agent happened to sit in.

Measured 2026-08-18: ONE Codex rollout was profiled at least **eight** times in a day, logged under
five different "projects" (`mutation-data-flush-final`, `rs_be`, `tgm-survey-platform`,
`ResearchShieldNew`, `mutation-data-flush-profile-detailed`), so the key never matched and every run
looked new — 12 `profile-session` runs that day, hours of duplicated analysis. It also explains the
contradictory self-reports: some runs printed "append-retro correctly performed an idempotent
no-op", others did the full analysis, purely by invocation site.

`--run-key` hashes the transcript's REALPATH plus the window bounds — the inputs that determine the
answer — and nothing about the caller. It reads none of the transcript, which is what makes it
cheap enough to run here. Keep `project` as a display field; it is a property of the invocation
site, never of the artifact's identity.

## Phase 1: Run the profiler

```bash
python3 "$PS" <transcript> [window_start_iso] [window_end_iso]
```

Output is JSON:

| Field | Meaning |
|-------|---------|
| `span_h` | Wall-clock hours from first to last event |
| `categories_min` | Minutes charged to each category, largest first |
| `top_gaps` | The 20 biggest individual gaps, each with its timestamp, category, and the command/message that preceded it |
| `counts` | Tool uses, adversarial calls, sub-agent dispatches, user messages |

Thresholds are tunable when a project's shape demands it —
`ZUVO_PROFILE_LONG_GAP_S` (default 1800) and `ZUVO_PROFILE_MAX_GAP_S` (default 14400). Say so in the
report if you change them; the numbers are not comparable across different thresholds.

## Phase 2: Read the categories honestly

A gap is charged to whatever ran immediately before it, which is sound only while that activity
could plausibly still be running. The profiler bounds this, and you must read the result with the
same care:

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates, so a session rule about unprompted Agent use does not
apply here. Only a harness with NO dispatch capability takes the documented single-agent fallback,
and it still runs every gate inline — see `../../shared/includes/env-compat.md`. Skipping a mandated
agent and self-scoring the result is a substituted gate, not a degraded run.

| Category | What it means | What it does NOT mean |
|----------|---------------|----------------------|
| `session-boundary/away(excluded)` | A gap over 4h — the user left, or the session resumed the next day | Never a performance problem. Subtract it before quoting a total. |
| `stall-or-idle>30m` | 30m–4h charged to something that does not plausibly run that long | Not proof of an API stall; it is the "unexplained" bucket and needs a look at the matching `top_gaps` row |
| `tests/build`, `subagent-dispatch`, `adversarial-review` | Genuinely long-running work, attributed even above 30m | This IS the signal — these are the ones worth optimizing |
| `model-api-thinking` | Time between a tool result and the next assistant action | Includes retries and rate-limit backoff, not only "thinking" |
| `system-hooks` | Time after a hook/system message | A hook takes milliseconds; a large number here on a bounded gap means something ELSE was happening that the transcript did not record |

**Report the span three ways, not one:** total span, span minus session boundaries (the real
working time), and the top three attributable categories. A single "the session took 83 hours"
number is true and useless.

## Phase 3: Name the specific cause

`categories_min` says *what kind*; `top_gaps` says *which one*. Always go to the rows — a category
total of 200 minutes means something different when it is one 200-minute gap versus forty
5-minute ones.

For each of the top 3 attributable gaps, state: the minutes, the timestamp, and the exact command
or agent prompt from the `what` field. "adversarial-review: 4 min × 11 calls on the same task" is
actionable; "adversarial-review: 47 minutes" is not.

Cross-check the count fields against the categories. `adversarial_calls: 11` on a single task is a
finding regardless of the minutes — it means a re-run loop, which `adversarial-loop.md` caps at 2.

## Phase 4: Report

```
SESSION PROFILE — <file>
────────────────────────────────────────────────
Span:            <N>h total  |  <M>h working (boundaries excluded)
Events:          <N>  (tools <N>, sub-agents <N>, adversarial <N>)

Where the working time went
  <mins>  <category>     <one-line reading>
  ...

Biggest single gaps
  1. <mins>  <at>  <category>
     <the command or prompt>
  2. ...

What to change
  1. <specific, measurable change> — expected saving <N> min/session, based on <the row above>
  2. ...

Not the problem (measured, so nobody re-litigates it)
  <category>: <mins> — <why this is fine>
```

The last block matters as much as the first. The 2026-07 forensics' most useful output was
proving adversarial review was innocent, which stopped an optimization that would have removed a
quality gate for no gain. **If a suspected cause turns out to be cheap, say so explicitly.**

Every recommendation must cite a row from `top_gaps`. A suggestion with no measurement behind it
is exactly the guessing this skill exists to replace — leave it out.

### `--compare` mode

Profile both, then print the categories side by side with deltas. State plainly whether the change
moved the category it was supposed to move; a total that dropped while the target category did not
means something else changed (different work, different day), not that the fix worked.

## Completion Gate Check

```
COMPLETION GATE CHECK
[ ] Transcript identified, and WHY that file was chosen is stated
[ ] Profiler ran (never a hand-rolled timestamp analysis)
[ ] Session boundaries excluded from the working-time figure
[ ] Every recommendation cites a specific top_gaps row
[ ] Cheap-but-suspected causes reported explicitly as not-the-problem
[ ] Run: line printed and appended to log
```

## Completion

```
PROFILE COMPLETE
-----
Transcript: <file>
Span: <N>h total / <M>h working
Top cost:  <category> <mins>
Run: <ISO-8601-Z>	profile-session	<project>	-	-	<VERDICT>	-	<mode>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion.

`<mode>`: the mode label (`last`, `path`, `skill`, `compare`).

## Principles

1. **Measure, then cut.** Every session-speed change in this repo's history that was made without a
   measurement first either did nothing or removed a gate that was not the problem.
2. **A total is not a finding.** Attribute it, then name the command.
3. **Exonerate as loudly as you accuse.** "This is not the bottleneck" is a result worth reporting.
