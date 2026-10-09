#!/usr/bin/env bash
# Behaviour tests for scripts/stryker-run-watchdog.sh — the no-progress limit around a Stryker run.
#
# Why: Stryker has no whole-run idle limit. rdesigner B-20260928-STRYKER-TRANSLATIONS-COMBINED-HANG
# passed its initial run and then went silent, and Stryker's `progress-append-only` reporter keeps
# printing a heartbeat line on a timer through exactly such a hang. Each case below names the defect it catches: a hang that is never aborted, a healthy run that
# is aborted, an exit code that is swallowed, or a process that outlives the run.
#
# Timing: a short idle limit; every bound is generous (the farm is shared) and every invocation runs
# under `timeout -s KILL`, so a hung watchdog reads as 137, never as the 124 it should print. The
# children's sleeps are short enough that even a leak expires on its own.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WD="$ROOT/scripts/stryker-run-watchdog.sh"
. "$ROOT/tests/lib/hermetic-tools.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

for tool in timeout ps mkfifo; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'SKIP: %s not installed — nothing was tested\n' "$tool"; exit 0; }
done
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { printf 'SKIP: bash %s < 4 — the watchdog refuses it (125); nothing was tested\n' "$BASH_VERSION"; exit 0; }
[ -f "$WD" ] || { bad "missing scripts/stryker-run-watchdog.sh"; echo "SOME FAILED"; exit 1; }

# Resolved before any PATH narrowing below: the hermetic rows must not lose `timeout` itself.
TIMEOUT="$(command -v timeout)"
TMP="$(mktemp -d)"
# Dead = no such process, or a zombie. Polls briefly: the kernel reaps asynchronously.
dead() {
  local pid="$1" st
  [ -n "$pid" ] || return 1  # no pid recorded means the child never ran: not proof of a kill
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    st="$(ps -o stat= -p "$pid" 2>/dev/null | tr -d ' ')"
    case "$st" in ''|Z*) return 0 ;; esac
    sleep 0.1
  done
  return 1
}
cleanup() {  # only pids still alive: a reaped one may already be reused by another process
  for f in "$TMP"/*.pid; do [ -f "$f" ] && ! dead "$(cat "$f")" && kill -KILL "$(cat "$f")" 2>/dev/null; done
  rm -rf "$TMP"
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM

# Run the watchdog; sets RC, ELAPSED, OUT (stdout) and ERR (stderr).
run_wd() {
  local start=$SECONDS
  "$TIMEOUT" -s KILL 40 bash "$WD" "$@" >"$TMP/out" 2>"$TMP/err"
  RC=$?
  ELAPSED=$((SECONDS - start))
  OUT="$(cat "$TMP/out")"; ERR="$(cat "$TMP/err")"
}
pid_of() { cat "$TMP/$1.pid" 2>/dev/null; }

# ── 1. a command that ends by itself: its exit code and all its output come through ──────────────
run_wd --idle-timeout 2 -- sh -c 'echo out; echo err >&2; printf no-eol; exit 7'
case "$RC|$OUT" in
  "7|"*out*err*no-eol*) pass "pass-through: exit 7 kept, stdout+stderr forwarded, unterminated last line kept" ;;
  *) bad "pass-through: rc=$RC out=[$OUT] (want 7 with out, err, no-eol)" ;;
esac
run_wd --idle-timeout 2 -- sh -c 'exit 0'
[ "$RC" = 0 ] && pass "pass-through: a clean exit stays 0 (no silent 124)" || bad "pass-through: exit 0 came back as $RC"

# ── 2. the command exits but a grandchild holds the output pipe open ───────────────────────────
# Waiting for an EOF that grandchild never sends would turn a finished run into a 124.
run_wd --idle-timeout 2 -- sh -c "sleep 30 & echo \$! > '$TMP/linger.pid'; echo done; exit 0"
if [ "$RC" = 0 ] && [ "$ELAPSED" -le 10 ] && dead "$(pid_of linger)"; then
  pass "lingering grandchild: command's exit 0 returned in ${ELAPSED}s, grandchild killed with the group"
else
  bad "lingering grandchild: rc=$RC elapsed=${ELAPSED}s grandchild-dead=$(dead "$(pid_of linger)" && echo yes || echo no)"
fi

# ── 3. no progress: the run is aborted and NOTHING of it survives ────────────────────────────
# Table over the two ways the watchdog makes a process group: setsid, and perl when setsid is absent.
HB="$TMP/hermetic"; mkdir -p "$HB"
hermetic_link_tools "$HB" bash sh sleep ps tr mktemp mkfifo rm rmdir cat awk perl
idle_case() {  # $1 = label, $2 = PATH for the watchdog
  local label="$1" path="$2" start=$SECONDS
  PATH="$path" "$TIMEOUT" -s KILL 40 bash "$WD" --idle-timeout 2 -- \
    sh -c "echo \$\$ > '$TMP/$label-child.pid'; sleep 30 & echo \$! > '$TMP/$label-grand.pid'; echo first; sleep 30" \
    >"$TMP/out" 2>"$TMP/err"
  RC=$?; ELAPSED=$((SECONDS - start)); ERR="$(cat "$TMP/err")"
  if [ "$RC" = 124 ] && [ "$ELAPSED" -ge 2 ] && [ "$ELAPSED" -le 17 ] \
     && [ "$ERR" = "ERROR: stryker made no progress for 2s (last: first)" ] \
     && dead "$(pid_of "$label-child")" && dead "$(pid_of "$label-grand")"; then
    pass "idle abort ($label): 124 after ${ELAPSED}s, ERROR line names the last output, child and grandchild dead"
  else
    bad "idle abort ($label): rc=$RC elapsed=${ELAPSED}s err=[$ERR]"
  fi
}
if command -v setsid >/dev/null 2>&1; then idle_case setsid "$PATH"; else printf 'SKIP: setsid row (no setsid here)\n'; fi
if [ -e "$HB/perl" ]; then idle_case perl "$HB"; else bad "perl fallback row: perl not available to link"; fi

# The command closes its output but keeps running: EOF on the pipe is not the end of the run.
run_wd --idle-timeout 2 -- sh -c "echo \$\$ > '$TMP/mute.pid'; echo first; exec >/dev/null 2>&1; sleep 30"
[ "$RC" = 124 ] && [ "$ELAPSED" -le 17 ] && dead "$(pid_of mute)" \
  && pass "output closed, command still running: 124 after ${ELAPSED}s, command killed" \
  || bad "output closed, command still running: rc=$RC elapsed=${ELAPSED}s"

# The command dies (an OOM kill of `npx`, say) while a process it started keeps printing a frozen
# heartbeat: neither "the command ended" nor "no progress" may be skipped because output keeps coming.
run_wd --idle-timeout 2 -- sh -c "( while :; do printf 'Mutation testing 5%% (elapsed: x, remaining: n/a) 1/9 tested (0 survived, 0 timed out)\n'; sleep 0.3; done ) & echo \$! > '$TMP/chatty.pid'; exit 3"
if [ "$RC" = 3 ] && [ "$ELAPSED" -le 10 ] && dead "$(pid_of chatty)"; then
  pass "dead command, chatty orphan: its exit 3 returned in ${ELAPSED}s, orphan killed"
else
  bad "dead command, chatty orphan: rc=$RC elapsed=${ELAPSED}s orphan-dead=$(dead "$(pid_of chatty)" && echo yes || echo no)"
fi

# A child that ignores TERM (and passes the ignored disposition on to its sleep) needs the KILL, which
# comes only after the documented 10 s grace: idle limit + grace is the lower bound.
run_wd --idle-timeout 2 -- sh -c "trap '' TERM; echo \$\$ > '$TMP/stubborn.pid'; echo x; sleep 30"
if [ "$RC" = 124 ] && [ "$ELAPSED" -ge 11 ] && [ "$ELAPSED" -le 27 ] && dead "$(pid_of stubborn)"; then
  pass "TERM-ignoring child: KILLed after the 10 s grace (${ELAPSED}s), 124"
else
  bad "TERM-ignoring child: rc=$RC elapsed=${ELAPSED}s dead=$(dead "$(pid_of stubborn)" && echo yes || echo no)"
fi

# ── 4. what counts as progress ──────────────────────────────────────────────────────────────
# A heartbeat whose `T/M tested` counter never moves is the rdesigner hang: elapsed (and a NaN
# percent) change on their own, so "new output" alone would never fire. Each row prints for three
# idle limits: an abort means 124, outlasting them means the command's own 0.
hb_row() {  # $1 label, $2 expected rc, $3 printf format taking the loop index
  run_wd --idle-timeout 2 -- bash -c "for i in 1 2 3 4 5 6 7 8 9 10 11 12; do printf '$3\n' \$i; sleep 0.5; done"
  [ "$RC" = "$2" ] && pass "progress: $1 → $2" || bad "progress: $1 gave rc=$RC, want $2 (err=[$ERR])"
}
hb_row "frozen counter, moving elapsed" 124 'Mutation testing 50%% (elapsed: ~%ds, remaining: n/a) 3/10 tested (0 survived, 0 timed out)'
hb_row "frozen counter, NaN percent" 124 'Mutation testing NaN%% (elapsed: ~%ds, remaining: n/a) 3/10 tested (0 survived, 0 timed out)'
hb_row "moving counter" 0 'Mutation testing 50%% (elapsed: <1m, remaining: n/a) %d/20 tested (0 survived, 0 timed out)'
hb_row "plain log lines" 0 'INFO line %d'
hb_row "blank lines only" 124 ''
hb_row "frozen counter behind a prefix and CR" 124 '> Mutation testing 50%% (elapsed: ~%ds, remaining: n/a) 3/10 tested (0 survived, 0 timed out)\r'

run_wd --idle-timeout 09 -- sh -c 'echo x; sleep 0.5; exit 5'
[ "$RC" = 5 ] && pass "--idle-timeout 09: zero-padded value read as decimal (not as broken octal)" || bad "--idle-timeout 09 gave rc=$RC"

# ── 5. usage errors are 125 and never run anything ───────────────────────────────────────────
for args in "--idle-timeout 2 touch $TMP/ran" "--idle-timeout x -- touch $TMP/ran" \
            "--idle-timeout 0 -- touch $TMP/ran" "--idle-timeout" "--idle-timeout 2 --"; do
  # shellcheck disable=SC2086  # the row is a word list on purpose
  run_wd $args
  if [ "$RC" = 125 ] && [ ! -e "$TMP/ran" ]; then pass "usage: [$args] → 125, nothing ran"
  else bad "usage: [$args] gave rc=$RC ran=$([ -e "$TMP/ran" ] && echo yes || echo no)"; fi
done
NOGROUP="$TMP/nogroup"; mkdir -p "$NOGROUP"
hermetic_link_tools "$NOGROUP" bash sh touch ps tr mktemp mkfifo rm rmdir cat awk sleep
PATH="$NOGROUP" "$TIMEOUT" -s KILL 40 bash "$WD" --idle-timeout 2 -- touch "$TMP/ran" >/dev/null 2>"$TMP/err"; RC=$?
[ "$RC" = 125 ] && [ ! -e "$TMP/ran" ] \
  && pass "no setsid and no perl: 125, the command never ran (it could not have been killed as a group)" \
  || bad "no setsid/perl: rc=$RC ran=$([ -e "$TMP/ran" ] && echo yes || echo no)"
run_wd --help
case "$RC|$OUT" in "0|"*Usage:*) pass "--help: exit 0, prints Usage:" ;; *) bad "--help: rc=$RC out=[$OUT]" ;; esac

# ── 6. the watchdog itself is stopped: the run must not be orphaned ──────────────────────────
bash "$WD" --idle-timeout 20 -- sh -c "echo \$\$ > '$TMP/orphan.pid'; sleep 30" >/dev/null 2>&1 &
wdpid=$!
for _ in $(seq 1 50); do [ -s "$TMP/orphan.pid" ] && break; sleep 0.1; done
kill -TERM "$wdpid" 2>/dev/null
wait "$wdpid"; RC=$?
[ "$RC" = 143 ] && dead "$(pid_of orphan)" \
  && pass "TERM to the watchdog: group killed, exit 143" \
  || bad "TERM to the watchdog: rc=$RC child-dead=$(dead "$(pid_of orphan)" && echo yes || echo no)"

# HUP (a closed terminal or ssh session) takes the same exit as TERM: the group dies, 128+1.
bash "$WD" --idle-timeout 20 -- sh -c "echo \$\$ > '$TMP/hup.pid'; sleep 30" >/dev/null 2>&1 &
wdpid=$!
for _ in $(seq 1 50); do [ -s "$TMP/hup.pid" ] && break; sleep 0.1; done
kill -HUP "$wdpid" 2>/dev/null
wait "$wdpid"; RC=$?
[ "$RC" = 129 ] && dead "$(pid_of hup)" && pass "HUP to the watchdog: group killed, exit 129" \
  || bad "HUP to the watchdog: rc=$RC child-dead=$(dead "$(pid_of hup)" && echo yes || echo no)"

# ── 7. the reader goes away: the watchdog must take the run down with it ────────────────────
( bash "$WD" --idle-timeout 20 -- sh -c "echo \$\$ > '$TMP/piped.pid'; while :; do echo line; sleep 0.1; done" | head -n 1 ) >/dev/null 2>&1
dead "$(pid_of piped)" && pass "reader closed the pipe: the run was killed, not orphaned" \
  || bad "reader closed the pipe: child $(pid_of piped) still alive"

if [ "$fail" = 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
