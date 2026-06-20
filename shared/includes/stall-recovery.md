# Stall Recovery — Self-Arming Watchdog

**Purpose:** When a long-running skill is mid-run and the turn **dies** — an API error, a rate-limit, a `socket connection closed unexpectedly` — the whole pipeline just freezes. Nobody re-runs it; the user comes back hours later to a stalled run. This protocol arms a watchdog at skill start that re-fires the skill from its saved state every ~3 minutes until it reaches **full completion**.

**Scope:** Long, multi-step, stall-prone skills — `execute` (canonical), the audits (`code-audit`, `test-audit`, `api-audit`, `security-audit`, `db-audit`, `performance-audit`, `structure-audit`, `dependency-audit`), `pentest`, `write-tests`, `write-e2e`, `content-expand`, `write-article`, `review`, `refactor`, `ship`. Quick utility skills do NOT load this.

---

## PRIMARY mechanism — `StopFailure` + `asyncRewake` (universal, no arming)

The cleanest recovery is a **harness hook**, not a cron — it catches **every** turn killed by an API error, with no TodoWrite, no cron, and no agent-arming. Claude Code fires a `StopFailure` hook **exactly when a turn ends due to an API error** (matchable by type: `rate_limit`, `server_error`, `unknown`, …). Registered with `asyncRewake: true`, a hook "runs in the background and wakes Claude on exit code 2" with its stderr shown as a system reminder.

So `hooks/zuvo-rewake-on-failure.sh` (StopFailure, matcher `rate_limit|server_error|unknown`, `async`+`asyncRewake`): on a retryable death it backs off (rate_limit → 90s for the window to reopen; server/transient → 20–30s), then exits 2 → Claude wakes → resumes the work right where it stopped (the conversation context is intact). `hooks/zuvo-rewake-reset.sh` (Stop) clears the per-session counter on every clean turn end, so the runaway cap (`ZUVO_REWAKE_CAP`, default 20) counts *consecutive* failures, not lifetime. Non-retryable errors (auth / billing / invalid_request / model_not_found) are excluded by the matcher and never rewake.

**This covers ALL work** — any skill, any ad-hoc turn — the moment it dies on rate-limit / overloaded / socket-closed. It needs only that the hooks be installed (a Claude Code **restart** loads them), and it cannot save a turn that died *before* the hook existed.

The cron/heartbeat machinery below is now **secondary**: it adds *granular* resume for `execute` (re-enter at the next task via `execution-state.md`, vs. the rewake's "resume where you stopped") and a `/loop 3m` story for runtimes with no `StopFailure`/`asyncRewake` (Codex / Cursor). For ordinary Claude Code stalls, the `StopFailure` hook above is the mechanism that actually fires.

---

## Rate-limit is a RETRY condition, NEVER a quality lever (read this — it overrides any "degraded" path)

A rate-limit / API-error / overload is **Anthropic infrastructure being slow**, not a signal about the work. It is therefore a **retry** condition and NOTHING else. It is NEVER a valid reason to skip, defer, downgrade, mark CONDITIONAL, or otherwise weaken ANY mandatory gate (per-task adversarial, sub-agent fan-out, quality scoring, spec review, retro, runlog). The rule is mechanical:

> If a mandatory step cannot complete this turn because of a rate-limit, **end the turn and let the watchdog resume — then RE-RUN the exact same step.** Repeat until it actually runs. The gate is *delayed*, never *skipped*. Quality is identical to a rate-limit-free run; only wall-clock grows — and that is Anthropic's problem to fix, not a license to lower the bar.

What this forbids, explicitly — none of these are allowed "because rate-limit":
- "per-task adversarial is too slow under rate-limit → I'll do one aggregate instead" — NO. Re-run each per-task pass across resumes.
- "I couldn't run the sub-agent fan-out → CONDITIONAL / DEGRADED-COVERAGE" — NO. Re-run the fan-out across resumes; the verdict is clean only once it actually ran.
- "20 auto-resumes failed, so I'll ship the substance and skip the ceremony" — NO. The run stays unfinished and keeps retrying; an unfinished run is honest, a fake-complete run is not.

`rate_limit` therefore must NOT appear as a skip-reason / degraded-coverage trigger in any skill's Validity Gate. The only honest states under sustained rate-limit are: **still-running (retrying)** or **genuinely-complete (every gate actually ran)** — never "complete-but-degraded-because-rate-limit". (Genuine *capability* limits are different and keep their own handling: `single_provider_only` = only one model exists so cross-model truly can't run; `BLOCKED_CONTEXT_BUDGET` = the context window is full. Those do not clear by retrying; rate-limit does.)

---

## The hard constraint (read this first)

A markdown skill **cannot revive its own dead turn.** When the API errors mid-run, the agent loop is gone — no instruction in this file can run. The thing that re-fires MUST be the **harness** — the `StopFailure` hook above, or (secondary) a cron. So cron-based recovery has two halves, and BOTH are required:

1. **Resumability** — a re-fire must *continue from saved state*, never restart from zero. `execute` has this (`zuvo/context/execution-state.md`, per-task). A skill with no per-step state file resumes *from the beginning* — acceptable only for idempotent read-then-report skills (audits); never wire a destructive non-resumable skill here.
2. **The 3-minute watchdog** — a self-armed cron (this file). On runtimes with no scheduler (Codex / Cursor), it degrades to printing a `/loop 3m` instruction the user can run.

**Why a cron is safe against false resumes (the key insight):** a Claude Code cron fires **only while the REPL is idle**. While a task is genuinely running — even a 10-minute adversarial pass with a sub-agent in flight — the REPL is *busy*, so the watchdog **does not fire**. It fires only once the turn has ended. If the turn ended cleanly we already disarmed; if it ended on an error, the run is unfinished and idle — exactly the stall we want to catch. The staleness threshold (below) is belt-and-suspenders on top of this.

---

## The heartbeat file

A dedicated file, refreshed (rewritten) after **every** action/task the skill completes. Its **mtime** is the "last action" clock; its `status:` line is the terminal signal.

Path: `zuvo/context/<skill>.heartbeat` (e.g. `zuvo/context/execute.heartbeat`). Lives under `zuvo/` → already git-ignored.

Format:

```
status: running
skill: <skill-name-without-zuvo:>
resume: <exact command to resume, e.g. zuvo:execute or zuvo:security-audit ./src>
cron_id: <id returned by CronCreate at arm time, or - >
note: <free text — e.g. "task 7/21"; diagnostic only>
```

- `status: running` while work is ongoing.
- `status: done` at the named terminal completion block (clean finish).
- `status: halted` on a **deliberate** stop the watchdog must NOT auto-resume — a genuine `BLOCKED_*` irreversible decision or an explicit user "stop"/"pause" (see no-pause-protocol). Auto-resuming a deliberately-halted run would loop every 3 min.
- `resume:` is what the watchdog invokes. For `execute` it is just `zuvo:execute` (it reads `execution-state.md`). For an audit, include the original target args.

**Refresh cadence:** rewrite the heartbeat (which updates its mtime) after each task/finding/file — wherever the skill already writes its per-item state. For `execute` that is alongside the `execution-state.md` write after each task commit. No separate timer needed; the per-item write IS the heartbeat.

---

## ARM — at skill start (right after the run-marker / state init)

**Only if the `CronCreate` tool is available** (Claude Code). If it is not (Codex / Cursor), skip to the Fallback below.

1. Resolve the watchdog script and absolute heartbeat path:

```bash
# >>> zuvo:stall-watchdog (arm)
_WD=$(command -v zuvo-watchdog-check 2>/dev/null \
      || ls ~/.zuvo/zuvo-watchdog-check 2>/dev/null \
      || ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/zuvo-home/zuvo-watchdog-check 2>/dev/null | head -1)
_SK="${SKILL:-execute}"
_PR=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
_HBDIR="$(git rev-parse --show-toplevel 2>/dev/null || pwd)/.zuvo/context"
_HB="$_HBDIR/$_SK.heartbeat"
mkdir -p "$_HBDIR" 2>/dev/null || true
# Seed the heartbeat (status: running). Fill resume: with the real resume command.
[ -f "$_HB" ] || printf 'status: running\nskill: %s\nresume: zuvo:%s\ncron_id: -\nnote: started\n' "$_SK" "$_SK" > "$_HB"
printf 'WD=%s\nHB=%s\nTAG=[zuvo-watchdog skill=%s project=%s]\n' "${_WD:-MISSING}" "$_HB" "$_SK" "$_PR"
# <<< zuvo:stall-watchdog (arm)
```

2. If `WD=MISSING` → the helper is not installed. Do **not** arm. Print one line: `[watchdog] zuvo-watchdog-check not installed — run ./scripts/install.sh; auto-resume disabled this run.` and continue (the run still works, it just won't self-heal).

3. **Idempotency:** call `CronList`. If any job's prompt already contains this run's `TAG`, a watchdog is already armed — **do not create a second** (this happens when a watchdog-triggered resume re-enters skill start). Skip to step 5.

4. Arm the cron with `CronCreate`:
   - `cron`: `"*/3 * * * *"` (every ~3 min)
   - `recurring`: `true`
   - `durable`: `false` (session-scoped — dies with the session, which is correct: a dead session has nothing to resume)
   - `prompt`: the block below, with `<WD>`, `<HB>`, `<TAG>` substituted from step 1:

```
<TAG> zuvo stall-recovery check — unattended, do not ask the user anything.
Run exactly: <WD> "<HB>" 150
Read the FIRST output line:
- DONE  → the run finished or was deliberately halted. Call CronList, find the job whose prompt contains "<TAG>", and CronDelete it. Then stop — output nothing else.
- ALIVE → the run is still progressing. Do nothing at all. Do NOT delete the cron.
- RESUME → the turn died (API error / rate-limit / socket closed) and the run is unfinished. The SECOND output line is the resume command (e.g. "zuvo:execute"). Invoke that skill now via the Skill tool to resume from its saved state in zuvo/context/. Do not re-plan, do not ask — just resume.
```

5. Record the cron id into the heartbeat (`cron_id:`) so disarm is exact:

```bash
# After CronCreate returns <id>, update the heartbeat's cron_id line:
sed -i.bak "s/^cron_id:.*/cron_id: <id>/" "$_HB" 2>/dev/null && rm -f "$_HB.bak" || true
```

Print one line so the run is auditable: `[watchdog] armed — */3 min, resumes on stall, heartbeat <HB>`.

### Fallback (no `CronCreate` — Codex / Cursor)

Do not fail. Print exactly one line and continue:

```
[watchdog] no scheduler on this runtime — for auto-resume on stall, run this skill under:  /loop 3m <resume-command>
```

The skill still runs normally; the user opts into recovery with `/loop`.

---

## HEARTBEAT — after every task/item

Wherever the skill writes its per-item state, also refresh the heartbeat mtime + note:

```bash
printf 'status: running\nskill: %s\nresume: %s\ncron_id: %s\nnote: %s\n' \
  "$_SK" "$RESUME_CMD" "$CRON_ID" "$PROGRESS_NOTE" > "$_HB"
```

(Re-using the variables from arm; `$PROGRESS_NOTE` e.g. `"task 7/21"`.) The mtime update is what keeps the watchdog seeing the run as ALIVE while it works.

---

## DISARM — at the named terminal block

At the skill's completion block (e.g. `EXECUTION COMPLETE`), AND on a deliberate halt:

```bash
# >>> zuvo:stall-watchdog (disarm)
# Clean finish:
sed -i.bak 's/^status:.*/status: done/'   "$_HB" 2>/dev/null && rm -f "$_HB.bak" || true
# Deliberate halt (BLOCKED_* irreversible / user "stop") — use 'halted' instead of 'done':
#   sed -i.bak 's/^status:.*/status: halted/' "$_HB" ...
# <<< zuvo:stall-watchdog (disarm)
```

Then, if `CronCreate` was used, **delete the cron** explicitly: read `cron_id:` from the heartbeat and `CronDelete` it (and as belt-and-suspenders, `CronList` → `CronDelete` any job whose prompt contains this run's `TAG`).

**Two-layer disarm is intentional:** writing `status: done`/`halted` means that even if the explicit `CronDelete` is missed (e.g. the terminal block was reached in an odd path), the **next** cron fire reads the heartbeat, gets `DONE`, and self-deletes the cron. The run can never be auto-resumed after it has finished.

---

## Normal (non-skill) work — the todo-keyed watchdog

A long *skill* run is resumable because it has a state file and a `status: done` signal. Plain interactive work has neither — so a blind "re-fire every 3 min" cron can't tell a turn that **died** from one that **finished** (both leave the REPL idle), and would nag after every completed turn. The fix is to borrow the one done-signal ad-hoc multi-step work usually has: **the TodoWrite list.** Open todos = work in progress; all completed = nothing to resume.

This is wired with two hooks (Claude Code only — they no-op where there is no scheduler) plus the same `zuvo-watchdog-check` clock:

1. **`hooks/zuvo-heartbeat.sh`** — PostToolUse, matcher `"*"`, **async**. Touches `~/.zuvo/heartbeats/<session>.beat` on every tool call. Fresh beat = actively working; stale beat = the turn stopped. Skips the watchdog's own poll command so a check never resets the clock.
2. **`hooks/zuvo-todo-watchdog.sh`** — PostToolUse, matcher `"TodoWrite"`, **sync** (required for `additionalContext`). Writes the open-todo count to `<session>.todos`, and on the first TodoWrite with open items injects an instruction asking the agent to **arm the watchdog cron once** (`CronCreate "*/3 * * * *"`, recurring, non-durable, tagged `[zuvo-todo-watchdog session=…]`). A hook cannot call `CronCreate` itself — only the agent can — so this injection is the trigger. Idempotent via the CronList tag + an `.armed` flag.

When the cron fires (only while idle), it runs `zuvo-watchdog-check <beat> 150` and reads the open-todo count from context + `<session>.todos`:

- **0 open todos** → work done → `CronDelete` self, stop.
- **open + ALIVE** → actively working → do nothing.
- **open + RESUME** (stale) **and the last turn was not a question awaiting the user** → the turn was killed by an API/rate-limit/socket error → resume the next incomplete todo, unattended.
- **open + RESUME but waiting on the user** → do nothing (don't nag a genuine wait).

**Honest limits (don't oversell this):**
- It needs the work to use **TodoWrite**. A single-shot turn with no todos has no done-signal and is not auto-resumed — for that, run the work under `/loop 3m "<prompt>"`.
- Arming depends on the agent acting on the injected instruction (a hook can't arm a cron directly). The CronList tag makes it safe to re-attempt but the first arm is soft.
- The "were you waiting on the user?" guard is a judgment call by the cron-fired agent, not a hard signal — it can occasionally mis-decide. Erring toward *not* resuming a genuine wait is the safer bias and the prompt is written that way.
- For a true **rate-limit/quota** stall, resuming only succeeds once the limit window reopens — the `*/3` cron keeps retrying until it does (the session context is intact, so the resumed turn has full history). Do NOT assume Claude Code self-retries these; in practice it frequently does not, which is the whole reason this exists.

## Interaction with no-pause-protocol

This protocol does not relax `no-pause-protocol`. The watchdog catches *unexpected death* (API/network), not *legitimate stops*. A skill that hits a real `BLOCKED_*` or an explicit user interrupt writes `status: halted` precisely so the watchdog leaves it alone. Everything no-pause already mandates — ride auto-compaction, Post-Cap auto-disposition, never ask between items — stays in force. The watchdog is the layer below: it only matters when the turn itself stopped existing.
