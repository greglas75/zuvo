#!/usr/bin/env bash
# zuvo-todo-watchdog.sh — PostToolUse hook (matcher "TodoWrite", SYNC).
#
# Gives ad-hoc (non-skill) multi-step work the same stall recovery the skills
# get. The todo list is the "done" signal a bare interactive turn otherwise
# lacks: open todos = work in progress, all completed = nothing to resume.
#
# A cron can only be created by the AGENT (a hook cannot call CronCreate), so on
# the first TodoWrite that has open items this hook injects `additionalContext`
# asking the agent to arm the todo-keyed watchdog cron once. additionalContext is
# honored only on a SYNCHRONOUS hook (async:false) — hence this hook is sync, and
# matched to the infrequent TodoWrite tool so it never taxes the hot path.
#
# Idempotent: the agent checks CronList for the session tag before creating, and
# an .armed flag stops us re-injecting on every subsequent TodoWrite.
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0

ZH="${ZUVO_HOME:-$HOME/.zuvo}"
hbdir="$ZH/heartbeats"
beat="$hbdir/$sid.beat"
todos_f="$hbdir/$sid.todos"
armed="$ZH/watchdogs/$sid.armed"
mkdir -p "$hbdir" "$ZH/watchdogs" 2>/dev/null || true

# Open todos = those whose status is not "completed".
open=$(printf '%s' "$input" | jq -r '[.tool_input.todos[]? | select(.status != "completed")] | length' 2>/dev/null)
case "$open" in ''|*[!0-9]*) open=0 ;; esac
printf '%s' "$open" > "$todos_f" 2>/dev/null || true

# Nothing open → work done / not started. No arm needed (cron self-disarms).
[ "$open" -gt 0 ] || exit 0
# Already injected this session → stay quiet (CronList tag is the real guard).
[ -f "$armed" ] && exit 0
: > "$armed" 2>/dev/null || true

CRON_PROMPT="[zuvo-todo-watchdog session=$sid] Unattended stall recovery. Run exactly: $ZH/zuvo-watchdog-check \"$beat\" 150 — then read $todos_f and your own todo list. (A) If 0 open todos (all completed): the work is finished — CronList, find the job whose prompt contains \"[zuvo-todo-watchdog session=$sid]\", CronDelete it, then stop with no output. (B) If open todos remain: if the check printed ALIVE, do nothing (you are actively working). If it printed RESUME (the heartbeat is stale, so the turn ended without finishing) AND your last turn did NOT end by asking the user a question or waiting for their reply, then a prior turn was killed by an API / rate-limit / socket error — resume the next in-progress or pending todo NOW, without asking. If you were waiting on the user, do nothing."

ARM_CTX=$(printf 'Multi-step work is in progress (open todos) and the zuvo stall-watchdog is not yet armed this session. Arm it ONCE now so this work auto-resumes if a turn is killed by an API / rate-limit / socket error (Claude Code does NOT reliably self-retry these). Steps: (1) Call CronList; if any job prompt already contains "[zuvo-todo-watchdog session=%s]" it is already armed — stop. (2) Otherwise call CronCreate with cron="*/3 * * * *", recurring=true, durable=false, and prompt set to EXACTLY this string:\n\n%s' "$sid" "$CRON_PROMPT")

jq -cn --arg c "$ARM_CTX" '{hookSpecificOutput:{hookEventName:"PostToolUse",additionalContext:$c}}'
exit 0
