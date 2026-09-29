#!/usr/bin/env bash
# zuvo-heartbeat.sh — PostToolUse hook (matcher "*", async).
#
# Touches a per-session heartbeat file on every tool call. Its mtime is the
# "last agent action" clock the todo-keyed stall watchdog reads: fresh beat =
# actively working, stale beat = the turn stopped (died on an API/rate-limit/
# socket error, or is waiting on the user). MUST stay minimal — it runs on every
# single tool call — so it only resolves the session id and touches one file.
#
# Skips the watchdog's OWN poll command: refreshing the beat there would reset
# the staleness clock and mask a real stall (or a genuine wait-on-user).
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0

sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
# The id names a file below: accept only the characters a session id is made of.
case "$sid" in *[!A-Za-z0-9_-]*) exit 0 ;; esac

# The command is only worth a second jq when the payload mentions the poll at all (or carries a
# JSON \u / \/ escape that could be hiding its letters).
case "$input" in
  *zuvo-watchdog-check*|*'\u'*|*'\/'*)
    cmd=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null)
    case "$cmd" in *zuvo-watchdog-check*) exit 0 ;; esac ;;
esac

ZH="${ZUVO_HOME:-$HOME/.zuvo}"
[ -d "$ZH/heartbeats" ] || mkdir -p "$ZH/heartbeats" 2>/dev/null || true
touch "$ZH/heartbeats/$sid.beat" 2>/dev/null || true
exit 0
