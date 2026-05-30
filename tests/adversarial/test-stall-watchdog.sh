#!/usr/bin/env bash
# test-stall-watchdog.sh — the self-arming stall-recovery watchdog.
#
# zuvo-watchdog-check turns "heartbeat file + clock" into ALIVE | RESUME | DONE.
# It is the decision core the cron prompt branches on, so its verdicts MUST be
# exact: never resume a finished/halted run, never resume a fresh one, always
# resume a stale unfinished one — and never mistake an execution-state
# `blocked: []` bucket line for `status: blocked`.

WD="$ROOT/scripts/zuvo-home/zuvo-watchdog-check"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }

# Portable "set this file's mtime N minutes in the past".
_age_file(){ # <file> <minutes-ago>
  local f="$1" m="$2"
  touch -t "$(date -v-"${m}"M +%Y%m%d%H%M 2>/dev/null || date -d "${m} min ago" +%Y%m%d%H%M)" "$f" 2>/dev/null
}
# First output line (verdict) and second line (resume cmd).
_v(){ "$WD" "$@" 2>/dev/null | sed -n '1p'; }
_r(){ "$WD" "$@" 2>/dev/null | sed -n '2p'; }

start_test "script exists and is executable"
assert_exit_code 0 "$([ -x "$WD" ]; echo $?)" "zuvo-watchdog-check is executable"

start_test "missing heartbeat file -> DONE (nothing to resume)"
D=$(_z)
assert_eq "DONE" "$(_v "$D/nope.heartbeat")" "absent file => DONE"

start_test "fresh running heartbeat -> ALIVE"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: running\nskill: execute\nresume: zuvo:execute\n' > "$HB"
assert_eq "ALIVE" "$(_v "$HB" 150)" "just-written running => ALIVE"

start_test "stale running heartbeat -> RESUME + resume command"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: running\nskill: execute\nresume: zuvo:execute\n' > "$HB"; _age_file "$HB" 10
assert_eq "RESUME" "$(_v "$HB" 150)" "stale running => RESUME"
assert_eq "zuvo:execute" "$(_r "$HB" 150)" "resume: line surfaced as resume command"

start_test "status: done -> DONE even when stale (clean finish, never resume)"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: done\nskill: execute\n' > "$HB"; _age_file "$HB" 10
assert_eq "DONE" "$(_v "$HB" 150)" "done => DONE"

start_test "status: halted -> DONE (deliberate stop, never auto-resume)"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: halted\nskill: execute\n' > "$HB"; _age_file "$HB" 10
assert_eq "DONE" "$(_v "$HB" 150)" "halted => DONE"

start_test "status: completed and aborted both -> DONE"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: completed\nskill: execute\n' > "$HB"; _age_file "$HB" 10
assert_eq "DONE" "$(_v "$HB" 150)" "completed => DONE"
printf 'status: aborted\nskill: execute\n' > "$HB"; _age_file "$HB" 10
assert_eq "DONE" "$(_v "$HB" 150)" "aborted => DONE"

start_test "execution-state 'blocked: []' bucket is NOT mistaken for status: blocked"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: running\nblocked: []\nskill: execute\nresume: zuvo:execute\n' > "$HB"; _age_file "$HB" 10
assert_eq "RESUME" "$(_v "$HB" 150)" "running+blocked-bucket+stale => RESUME (not DONE)"

start_test "resume command derives from skill: when resume: is absent"
D=$(_z); HB="$D/sec.heartbeat"
printf 'status: running\nskill: security-audit\n' > "$HB"; _age_file "$HB" 10
assert_eq "RESUME" "$(_v "$HB" 150)" "no resume: line still RESUMEs"
assert_eq "zuvo:security-audit" "$(_r "$HB" 150)" "derived zuvo:<skill>"

start_test "custom stall threshold honored (2 min old, 60s threshold -> RESUME)"
D=$(_z); HB="$D/execute.heartbeat"
printf 'status: running\nskill: execute\nresume: zuvo:execute\n' > "$HB"; _age_file "$HB" 2
assert_eq "RESUME" "$(_v "$HB" 60)" "120s>60s threshold => RESUME"
assert_eq "ALIVE" "$(_v "$HB" 600)" "120s<600s threshold => ALIVE"

# ---- wiring assertions: the include + skill + installer must reference it ----

start_test "shared include stall-recovery.md exists"
assert_exit_code 0 "$([ -f "$ROOT/shared/includes/stall-recovery.md" ]; echo $?)" "include present"

start_test "include defines arm/heartbeat/disarm + fallback; execute wires them"
INC="$ROOT/shared/includes/stall-recovery.md"
assert_contains "$(cat "$INC")" "zuvo:stall-watchdog (arm)" "arm block lives in the include"
assert_contains "$(cat "$INC")" "CronCreate" "arm uses CronCreate"
assert_contains "$(cat "$INC")" "/loop 3m" "no-scheduler fallback documented"
EX="$ROOT/skills/execute/SKILL.md"
assert_contains "$(cat "$EX")" "shared/includes/stall-recovery.md" "execute references the include"
assert_contains "$(cat "$EX")" "Arm the stall-recovery watchdog" "execute Phase 0.2 arms the watchdog"
assert_contains "$(cat "$EX")" "zuvo:stall-watchdog (heartbeat after each task)" "per-task heartbeat hook present in execute"
assert_contains "$(cat "$EX")" "zuvo:stall-watchdog (disarm" "disarm hook present in execute"

start_test "install.sh installs the watchdog helper into ~/.zuvo"
assert_contains "$(cat "$ROOT/scripts/install.sh")" "zuvo-home/zuvo-watchdog-check" "installer copies the helper"

start_test "no-pause-protocol points to stall-recovery as the layer below"
assert_contains "$(cat "$ROOT/shared/includes/no-pause-protocol.md")" "stall-recovery.md" "no-pause references stall-recovery"
