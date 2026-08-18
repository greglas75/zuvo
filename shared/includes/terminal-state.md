# Terminal State

> Shared include — a skill may not declare itself complete while work it started is still running.

## The Rule

A run reaches its terminal state when **every process it launched has exited** and **every external
check it triggered has concluded**. Until both hold, the completion block is a claim about the
future, not a report about the system. Print `<SKILL> INCOMPLETE` instead, and say what is still
outstanding.

This is not the same as `verification-protocol.md`. That one forbids claiming a result you never
measured. This one forbids claiming a result the system has not finished producing — the command
ran, you read real output, and the work is still in flight behind it.

## Why it exists

Both shapes were measured in a single profiled `refactor → mutation-test → ship` run
(2026-08-16/17, RShieldBE):

- **A live process.** The mutation run's Tier 2 full suite was launched, the task ended, and the
  Jest process stayed alive for **679 minutes** on the developer's laptop — burning cores against
  the global vitest/jest worker cap for eleven hours after the skill said it was done. The skill's
  "clean state on exit" rule restored every mutated FILE and said nothing about processes.
- **A pending check.** `ship` merged the PR and printed its banner. The post-merge CI run on the
  target branch then went **red** (setup-node 503/502/429) and the production gate was **cancelled**.
  The release was reported shipped over a broken target branch, ~3.6 min before the first failure
  was even visible.

Neither was caught by anything, because every skill's completion gate asks "did I do the steps?"
and no step's own success proves the work behind it finished.

## Shape A — a process you launched is still alive

Applies to any runner started in the background, with `&`, via a background Bash call, or under a
`timeout` wrapper that returned before the child did.

**Record the PID when you launch it, and reap it before you finish:**

```bash
# At launch — capture the PID, never rely on finding it later by name (`pkill -f jest` on a shared
# machine kills OTHER repos' runs; this is a developer workstation with ~40 repos).
npm test > "$LOG" 2>&1 &
RUNNER_PID=$!
echo "[<SKILL>] runner pid=$RUNNER_PID log=$LOG"

# Before the completion block — for EVERY pid recorded this run:
if kill -0 "$RUNNER_PID" 2>/dev/null; then
  # Still running. Two legitimate outcomes, no third:
  #   1. It is still needed  -> WAIT for it and read its verdict.
  #   2. It is abandoned     -> terminate it, and SAY SO in the output.
  wait "$RUNNER_PID"; RUNNER_RC=$?
  # or, when the run is being abandoned (budget exceeded, early termination):
  #   kill -TERM "$RUNNER_PID" 2>/dev/null; sleep 2
  #   kill -0 "$RUNNER_PID" 2>/dev/null && kill -KILL "$RUNNER_PID" 2>/dev/null
fi
```

**Terminate on EVERY exit path, not just the happy one.** Early termination (budget exceeded, restore
failures, user interrupt) is exactly the path the 679-minute process took: the skill stopped issuing
mutations and never went back for the runner it had already started. An abandoned runner must be
killed on the abort path *before* the partial report is written.

**Report it.** A terminated runner is a fact about the run:
`processes: 1 launched, 1 reaped (terminated at abort)`. Silence here reads as "nothing was left
behind", which is the claim that failed.

## Shape B — an external check you triggered has not concluded

Applies to CI runs, deploy gates, scans, and any queue a push or merge dispatches.

**Wait with ONE blocking call, never a model-loop poll.** The distinction is not stylistic:

```bash
gh pr checks "$PR" --watch --fail-fast      # one tool call, blocks until every check concludes
gh run watch "$RUN_ID" --exit-status        # same, for a specific run
```

versus re-invoking `gh run list` from the model every 30 seconds — measured at **399 polling calls**
in the profiled run, 24.5% of that session's model invocations, for information a single blocking
call delivers. Passive waiting costs nothing; asking repeatedly is what costs.

**A merge is not the end of the check surface.** Post-merge workflows (CI on the target branch,
deploy gates, scheduled scans) are dispatched BY the merge, so they cannot have concluded when it
returns. Watch the run the merge commit produced:

```bash
MERGE_SHA=$(git rev-parse "$PUSH_REMOTE/$TARGET_BRANCH")
# Runs appear a few seconds after the merge — an empty list means "not dispatched yet", not "none".
gh run list --commit "$MERGE_SHA" --json databaseId,name,status,conclusion
```

**Read state, not exit codes**, and distinguish the three shapes that look alike:

| Observed | Meaning | Action |
|---|---|---|
| Zero runs, and none appear after a short wait | Nothing is configured for this branch | Proceed; say "no post-merge checks configured" |
| Runs exist, `status != completed` | Still in flight | Keep waiting on the blocking call |
| `conclusion` is `failure` / `cancelled` / `timed_out` | The work is not done | `<SKILL> INCOMPLETE` with the run URL |

A `cancelled` conclusion is **not** a pass. A job cancelled by a timeout ignores
`continue-on-error` and reds the check anyway, so treating cancellation as "inconclusive, proceed"
converts a real block into a green banner.

## Shape C — an artifact you created never reached its destination

Applies to a PR opened, a branch pushed, a tag created, a queue entry submitted: anything the run
brought into existence that is only *useful* once it lands somewhere.

This is the shape A and B both miss, and in the profiled run it was the single largest cost. The
task created PR #404, its checks went green, and the run ended. Processes alive: zero. Unconcluded
checks: zero. Both gates above are satisfied by a PR sitting open forever — the work is finished
and delivered nowhere. It stayed that way for **500 minutes**, until a human typed "finish the
task". That one gap outweighed every queue, mirror and CI-setup problem in the same run combined.

**Read the destination state from the system, never from the fact that you ran the command:**

```bash
gh pr view "$PR" --json state,mergeStateStatus -q '.state'   # MERGED is the terminal state
```

| State | Meaning | Terminal? |
|---|---|---|
| `MERGED` | landed | yes |
| `OPEN`, checks green | delivered nowhere — merge it | **no** |
| `OPEN`, checks red or pending | Shape B still applies first | **no** |
| `CLOSED` unmerged | abandoned — say so explicitly, do not report success | no (but terminal) |

A green PR is not a shipped PR. If the run cannot merge it — a required human review, a protected
branch, a policy the agent may not satisfy — that is a legitimate stop, but it is `<SKILL>
INCOMPLETE` naming the blocker, not a completion banner with a link attached.

## Completion Gate

Every skill that loads this file adds these two lines to its completion gate, with the evidence
filled in — not as a checkbox that is always ticked:

```
- [ ] Terminal state A: processes launched = N, still alive = 0   (list PIDs and how each ended)
- [ ] Terminal state B: external checks triggered = N, unconcluded = 0   (list run IDs + conclusions)
- [ ] Terminal state C: artifacts created = N, not landed = 0   (list PR/branch/tag + its state)
```

If ANY of the three counts is non-zero, the run prints `<SKILL> INCOMPLETE` naming what is outstanding. A
completion banner over a live process or a pending check is the failure this include exists to
prevent, and "it will probably pass" is not evidence.

## Scope

Applies to `zuvo:ship`, `zuvo:deploy`, `zuvo:mutation-test`, `zuvo:refactor`, `zuvo:execute`, and any
skill that launches a background runner or dispatches remote work.

It does NOT apply to analysis-only skills that neither start processes nor trigger checks, and it
does NOT require waiting on work the run did not cause — a CI run someone else pushed is not this
run's terminal state.
