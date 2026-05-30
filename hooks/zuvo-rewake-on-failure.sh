#!/usr/bin/env bash
# zuvo-rewake-on-failure.sh — StopFailure hook (async + asyncRewake).
#
# Fires EXACTLY when a turn dies on an API error (matcher restricts to RETRYABLE
# types: rate_limit / server_error / unknown). Because it is registered with
# asyncRewake, it runs in the background, sleeps a backoff appropriate to the
# error, then exits 2 — which WAKES Claude and shows this script's stderr as a
# system reminder. Claude then resumes the work right where the killed turn
# stopped (the conversation context is intact). No cron, no TodoWrite, no agent
# arming — this catches ANY work, which the cron/todo watchdog could not.
#
# Runaway guard: a per-session consecutive-failure counter caps auto-resumes; the
# Stop hook (zuvo-rewake-reset.sh) clears it on every clean turn end, so the cap
# is consecutive failures, not lifetime. Non-retryable errors (auth/billing/
# invalid_request/model_not_found) are excluded by the matcher and never rewake.
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 1   # no jq: cannot parse → let the turn stay dead rather than rewake blindly

sid=$(printf '%s' "$input" | jq -r '.session_id // "unknown"' 2>/dev/null)
# The error type field name varies across versions — try the likely keys.
etype=$(printf '%s' "$input" | jq -r '.error_type // .stop_failure_reason // .reason // .matcher // "unknown"' 2>/dev/null)
case "$etype" in ''|null) etype="unknown" ;; esac

ZH="${ZUVO_HOME:-$HOME/.zuvo}"
cdir="$ZH/rewake"
mkdir -p "$cdir" 2>/dev/null || true
cf="$cdir/$sid.count"

n=$(cat "$cf" 2>/dev/null || echo 0)
case "$n" in ''|*[!0-9]*) n=0 ;; esac

CAP="${ZUVO_REWAKE_CAP:-20}"
if [ "$n" -ge "$CAP" ]; then
  # Stop auto-retrying a turn that keeps dying — surface it once and let the user
  # decide. (exit 2 still wakes Claude so the message reaches the user.)
  printf 'zuvo-watchdog: the turn keeps failing (%s) after %s consecutive auto-resumes — stopping auto-retry. Resume manually when ready.\n' "$etype" "$n" >&2
  exit 2
fi
printf '%s' "$((n + 1))" > "$cf" 2>/dev/null || true

# Backoff by error type. rate_limit needs the window to reopen; server_error /
# transient clear faster. asyncRewake runs in the background, so the sleep blocks
# nothing the user is doing.
case "$etype" in
  rate_limit)            sleep "${ZUVO_REWAKE_BACKOFF_RL:-90}" ;;
  server_error|overloaded) sleep "${ZUVO_REWAKE_BACKOFF_SE:-20}" ;;
  *)                     sleep "${ZUVO_REWAKE_BACKOFF_OTHER:-30}" ;;
esac

printf 'zuvo-watchdog: the previous turn was killed by an API error (%s) and the backoff has elapsed. The conversation context is intact — RESUME the work you were doing, right where it stopped. Do not ask the user; just continue. (auto-resume %s/%s)\n' \
  "$etype" "$((n + 1))" "$CAP" >&2
exit 2
