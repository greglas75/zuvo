#!/usr/bin/env bash
#
# stryker-run-watchdog.sh — run a command in its own process group and abort it when its output
# stops showing progress.
#
# Why this exists: Stryker has no whole-run idle limit. `timeoutMS`/`timeoutFactor` bound ONE mutant
# and `dryRunTimeoutMinutes` bounds the initial run; nothing bounds the mutation phase as a whole
# (rdesigner B-20260928-STRYKER-TRANSLATIONS-COMBINED-HANG, RD-121). A run that stops making progress
# must END, loudly, with its whole process tree.
#
# Progress, not output: Stryker's `progress-append-only` reporter prints a heartbeat on a timer for
# as long as the mutation phase lasts, whether or not a mutant finished:
#     Mutation testing 42% (elapsed: ~1m, remaining: ~2m) 21/50 tested (3 survived, 0 timed out)
# Elapsed/remaining (and the percent, which reads NaN% when every covering test took 0 ms) change on
# their own, so a heartbeat counts as progress only when its `T/M tested (S survived, X timed out)`
# counter differs from the previous heartbeat. Every other non-blank line counts as progress.
#
# Usage: stryker-run-watchdog.sh [--idle-timeout <s>] -- <command> [args...]
#   --idle-timeout <s>   seconds without progress before the run is aborted (integer >= 1, default 600)
#
# The command runs in its own process group (setsid, else perl setpgrp). Its stdout and stderr are
# merged and forwarded to stdout line by line.
#
# Exit codes: the command's own exit code when it ends by itself
#             · 124 no progress for --idle-timeout seconds: the whole process group got TERM, then KILL
#               after a 10 s grace, and stderr carries
#               `ERROR: stryker made no progress for <s>s (last: <last line>)`
#               (a command that exits 124 by itself is told apart only by the missing ERROR line)
#             · 125 usage error, bash older than 4, or no way to start the command in its own group
#             · 128+n the watchdog itself got signal n (INT/TERM/HUP/PIPE); the group was killed first
set -u

IDLE=600
GRACE=10
ME="stryker-run-watchdog"

usage_die() { echo "$ME: $1" >&2; exit 125; }

while [ $# -gt 0 ]; do
  case "$1" in
    --idle-timeout)
      [ $# -ge 2 ] || usage_die "missing value for --idle-timeout"
      IDLE="$2"; shift 2 ;;
    --) shift; break ;;
    -h|--help) awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"; exit 0 ;;
    *) usage_die "unknown argument: $1 (the command goes after --)" ;;
  esac
done
# bash 3.2 (macOS /bin/bash) returns 1 from a timed-out `read -t`, the same status as EOF, so the
# watch would end on the first silent second and then block in `wait` with nobody draining the pipe.
[ "${BASH_VERSINFO[0]}" -ge 4 ] || usage_die "needs bash >= 4 (running ${BASH_VERSION})"
[ $# -gt 0 ] || usage_die "no command given (usage: $ME [--idle-timeout <s>] -- <command> [args...])"
[[ "$IDLE" =~ ^[0-9]{1,9}$ ]] && [ "$((10#$IDLE))" -ge 1 ] || usage_die "--idle-timeout must be an integer >= 1, got '$IDLE'"
IDLE=$((10#$IDLE))  # base 10: shell arithmetic would read a zero-padded 0600 as octal 384

if command -v setsid >/dev/null 2>&1; then
  NEWGROUP=(setsid)
elif command -v perl >/dev/null 2>&1; then
  NEWGROUP=(perl -e 'setpgrp(0, 0) or die "setpgrp: $!\n"; exec { $ARGV[0] } @ARGV or die "exec $ARGV[0]: $!\n"')
else
  usage_die "neither setsid nor perl is available — refusing to run without a process group to kill"
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/stryker-watchdog.XXXXXX")" || usage_die "mktemp failed"
FIFO="$WORK/out"
mkfifo "$FIFO" || { rmdir "$WORK" 2>/dev/null; usage_die "mkfifo failed"; }

PID=""
group_alive() { [ -n "$PID" ] && kill -0 -- "-$PID" 2>/dev/null; }
# TERM the whole group, wait up to GRACE seconds, then KILL whatever is left.
kill_group() {
  group_alive || return 0
  kill -TERM -- "-$PID" 2>/dev/null
  local waited=0
  while group_alive && [ "$waited" -lt $((GRACE * 10)) ]; do sleep 0.1; waited=$((waited + 1)); done
  group_alive && kill -KILL -- "-$PID" 2>/dev/null
  return 0
}
cleanup() { exec 3<&- 2>/dev/null; rm -f "$FIFO"; rmdir "$WORK" 2>/dev/null; }
on_signal() { kill_group; cleanup; exit "$1"; }
trap 'on_signal 130' INT
trap 'on_signal 143' TERM
trap 'on_signal 129' HUP
# A reader that goes away (`… | head`) must not kill the watchdog alone and orphan the run.
trap 'on_signal 141' PIPE
trap 'kill_group; cleanup' EXIT

# The redirect opens the FIFO in the child; the `exec 3<` below opens the read end. Opening in this
# order means neither side can block forever on the other.
"${NEWGROUP[@]}" "$@" >"$FIFO" 2>&1 </dev/null &
PID=$!
exec 3<"$FIFO"

# setsid/setpgrp runs inside the child, a moment after `&` returns: poll for it briefly. A child
# that is not its own group leader cannot be killed as a group, so that is a start failure.
pgid_of() {  # procps/BSD ps, else /proc (BusyBox ps has no -o pgid)
  local g
  g="$(ps -o pgid= -p "$1" 2>/dev/null | tr -d ' ')"
  [ -z "$g" ] && [ -r "/proc/$1/stat" ] && g="$(sed 's/^.*) //' "/proc/$1/stat" | awk '{print $3}')"
  printf '%s' "$g"
}
pg=""
for ((_try = 0; _try < 30; _try++)); do
  pg="$(pgid_of "$PID")"
  [ "$pg" = "$PID" ] && break
  kill -0 "$PID" 2>/dev/null || break
  sleep 0.1
done
if [ "$pg" != "$PID" ] && kill -0 "$PID" 2>/dev/null; then
  kill -KILL "$PID" 2>/dev/null
  usage_die "could not put the command in its own process group (pgid=$pg, pid=$PID)"
fi

HEARTBEAT='Mutation testing [^ ]+ \(elapsed: .*\) ([0-9]+/[0-9]+ tested \([^)]*\))'
last_line=""
last_counter=""
buf=""
deadline=$((SECONDS + IDLE))
child_gone_at=""

progress() { deadline=$((SECONDS + IDLE)); }
consume() {  # one complete line; a blank one is not progress
  local line="$1"
  printf '%s\n' "$line"
  line="${line%$'\r'}"
  [[ "$line" =~ [^[:space:]] ]] || return 0
  last_line="$line"
  if [[ "$line" =~ $HEARTBEAT ]]; then
    if [ "${BASH_REMATCH[1]}" != "$last_counter" ]; then last_counter="${BASH_REMATCH[1]}"; progress; fi
  else
    progress
  fi
}

abort_idle() {
  kill_group
  printf 'ERROR: stryker made no progress for %ss (last: %s)\n' "$IDLE" "${last_line:-<no output>}" >&2
  wait "$PID" 2>/dev/null
  exit 124
}

while :; do
  # Both checks run on EVERY pass, not only after a silent slice: a periodic heartbeat that never
  # moves its counter keeps `read` returning lines, and that is precisely the hang this exists to stop.
  if ! kill -0 "$PID" 2>/dev/null; then
    # The command ended but something it started still holds the pipe open (and may keep writing to
    # it). After a short grace, stop waiting for an EOF that may never come: the command's own exit
    # code is the verdict, and the group is killed below.
    [ -n "$child_gone_at" ] || child_gone_at=$SECONDS
    if [ $((SECONDS - child_gone_at)) -ge 2 ]; then
      # Drain what is already queued before giving up on the pipe, so the last words are not lost.
      # Bounded: an orphan that keeps writing would otherwise keep this loop alive forever.
      drain_until=$((SECONDS + 1))
      chunk=""
      while [ "$SECONDS" -le "$drain_until" ] && IFS= read -r -t 0.2 chunk <&3; do consume "$buf$chunk"; buf=""; chunk=""; done
      [ -n "$buf$chunk" ] && printf '%s' "$buf$chunk"
      break
    fi
  elif [ "$SECONDS" -ge "$deadline" ]; then
    abort_idle
  fi
  # Status captured on its own line: after `if read …; then …; fi` with no else, $? is the if's 0,
  # which reads as a clean EOF on the very first silent slice and ends the watch.
  rc=0
  IFS= read -r -t 1 chunk <&3 || rc=$?
  if [ "$rc" -eq 0 ]; then
    consume "$buf$chunk"; buf=""
    continue
  fi
  if [ "$rc" -le 128 ]; then
    # EOF: every writer closed the pipe. A final line without a newline arrives with the EOF.
    if [ -n "$buf$chunk" ]; then printf '%s' "$buf$chunk"; last_line="$buf$chunk"; fi
    break
  fi
  # A silent slice: keep any partial line for the next one.
  buf="$buf$chunk"
  # Output without newlines (a CR-redrawn bar) is still output; never let it grow without bound.
  if [ "${#buf}" -ge 4096 ]; then consume "$buf"; buf=""; fi
done

# The pipe can close while the command keeps running (it redirected its own output away): the idle
# limit still applies, there is just no output left that could reset it.
while kill -0 "$PID" 2>/dev/null; do
  [ "$SECONDS" -ge "$deadline" ] && abort_idle
  sleep 1
done
wait "$PID"
code=$?
# Nothing of the run may outlive it: an orphan still in the group would keep working on the
# sandbox after the caller has read the verdict.
kill_group
exit "$code"
