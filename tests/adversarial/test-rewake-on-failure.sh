#!/usr/bin/env bash
# test-rewake-on-failure.sh — the StopFailure + asyncRewake universal auto-resume.
#
# This is the PRIMARY stall-recovery mechanism: a StopFailure hook fires when a
# turn dies on an API error and, via asyncRewake, exits 2 to wake Claude with a
# "resume" reminder. The contract that must hold:
#   - a transient error increments per-session counters and exits 2 (wake) with
#     a RESUME message on stderr
#   - the Stop hook clears the counter on a clean turn end (cap = CONSECUTIVE
#     failures, not lifetime)
#   - a rate limit without reset evidence stays silent; both caps stop rewaking
#   - hooks.json registers StopFailure with asyncRewake + the Stop reset

RWF="$ROOT/hooks/zuvo-rewake-on-failure.sh"
RST="$ROOT/hooks/zuvo-rewake-reset.sh"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }
# Zero the backoffs so the test never actually sleeps.
export ZUVO_REWAKE_BACKOFF_RL=0 ZUVO_REWAKE_BACKOFF_SE=0 ZUVO_REWAKE_BACKOFF_OTHER=0

start_test "both rewake hook scripts exist and are executable"
assert_exit_code 0 "$(rc_of test -x "$RWF")" "zuvo-rewake-on-failure.sh executable"
assert_exit_code 0 "$(rc_of test -x "$RST")" "zuvo-rewake-reset.sh executable"

start_test "rate_limit without reset evidence → no duplicate wake"
Z=$(_z)
ERR=$(printf '{"session_id":"X1","error":"rate_limit"}' | ZUVO_HOME="$Z" bash "$RWF" 2>&1 >/dev/null); RC=$?
assert_exit_code 0 "$RC" "does not wake without a reset instant or transient evidence"
assert_exit_code 1 "$(rc_of test -f "$Z/rewake/X1.count")" "no retry counted"
assert_contains "$(cat "$Z/rewake/payloads.log")" "limit-no-evidence-no-rewake" "silent decision is journaled"

start_test "transient rate limit → exit 2 (wake) + count=1 + RESUME"
Z=$(_z)
ERR=$(printf '{"session_id":"X1","error":"rate_limit","error_details":"too many requests"}' | ZUVO_HOME="$Z" bash "$RWF" 2>&1 >/dev/null); RC=$?
assert_exit_code 2 "$RC" "transient limit wakes Claude"
assert_eq "1" "$(cat "$Z/rewake/X1.count" 2>/dev/null)" "consecutive counter incremented"
assert_eq "1" "$(cat "$Z/rewake/X1.total" 2>/dev/null)" "lifetime counter incremented"
assert_contains "$ERR" "RESUME" "stderr instructs resume"

start_test "consecutive failures increment the counter"
Z=$(_z)
printf '{"session_id":"X1","error_type":"server_error"}' | ZUVO_HOME="$Z" bash "$RWF" >/dev/null 2>&1
printf '{"session_id":"X1","error_type":"server_error"}' | ZUVO_HOME="$Z" bash "$RWF" >/dev/null 2>&1
assert_eq "2" "$(cat "$Z/rewake/X1.count" 2>/dev/null)" "two failures → count 2"

start_test "Stop hook clears the counter on a clean turn end"
Z=$(_z)
printf '{"session_id":"X1","error":"server_error"}' | ZUVO_HOME="$Z" bash "$RWF" >/dev/null 2>&1
printf '{"session_id":"X1"}' | ZUVO_HOME="$Z" bash "$RST"
assert_exit_code 1 "$(rc_of test -f "$Z/rewake/X1.count")" "counter file removed after clean Stop"
assert_eq "1" "$(cat "$Z/rewake/X1.total" 2>/dev/null)" "lifetime cap survives clean Stop"

start_test "consecutive cap → silent stop without another wake"
Z=$(_z); mkdir -p "$Z/rewake"; printf '5' > "$Z/rewake/X2.count"; printf '5' > "$Z/rewake/X2.total"
ERR=$(printf '{"session_id":"X2","error":"server_error"}' | ZUVO_HOME="$Z" bash "$RWF" 2>&1 >/dev/null); RC=$?
assert_exit_code 0 "$RC" "cap stops rewaking"
assert_eq "" "$ERR" "no final wake message"
assert_eq "5" "$(cat "$Z/rewake/X2.total")" "cap does not increment lifetime count"

start_test "lifetime cap survives a cleared consecutive counter"
Z=$(_z); mkdir -p "$Z/rewake"; printf '10' > "$Z/rewake/X4.total"
ERR=$(printf '{"session_id":"X4","error":"server_error"}' | ZUVO_HOME="$Z" bash "$RWF" 2>&1 >/dev/null); RC=$?
assert_exit_code 0 "$RC" "lifetime cap stops rewaking"
assert_eq "" "$ERR" "no cap wake message"

start_test "unknown error type still rewakes (default backoff branch)"
Z=$(_z)
RC=$(printf '{"session_id":"X3","error_type":"unknown"}' | ZUVO_HOME="$Z" bash "$RWF" >/dev/null 2>&1; echo $?)
assert_exit_code 2 "$RC" "unknown → wake"
assert_eq "1" "$(cat "$Z/rewake/X3.count" 2>/dev/null)" "counted"

start_test "reset hook is a no-op without a session id"
Z=$(_z)
printf '{}' | ZUVO_HOME="$Z" bash "$RST"
assert_exit_code 0 "$?" "no crash, exits clean"

start_test "hooks.json registers StopFailure (asyncRewake) + Stop reset"
HJ=$(cat "$ROOT/hooks/hooks.json")
assert_contains "$HJ" "zuvo-rewake-on-failure.sh" "StopFailure hook registered"
assert_contains "$HJ" "zuvo-rewake-reset.sh" "Stop reset hook registered"
assert_exit_code 0 "$(printf '%s' "$HJ" | jq -e '.hooks.StopFailure[] | .hooks[] | select(.command|test("rewake-on-failure")) | (.async==true and .asyncRewake==true)' >/dev/null 2>&1; echo $?)" "StopFailure hook is async + asyncRewake"
assert_exit_code 0 "$(printf '%s' "$HJ" | jq -e '.hooks.StopFailure[] | .matcher | test("rate_limit")' >/dev/null 2>&1; echo $?)" "matcher restricts to retryable errors (rate_limit…)"
assert_exit_code 0 "$(printf '%s' "$HJ" | jq -e '.hooks.Stop[] | .hooks[] | select(.command|test("rewake-reset")) | .async==true' >/dev/null 2>&1; echo $?)" "Stop reset registered async"

start_test "include documents StopFailure as the PRIMARY mechanism"
INC=$(cat "$ROOT/shared/includes/stall-recovery.md")
assert_contains "$INC" "StopFailure" "primary mechanism documented"
assert_contains "$INC" "asyncRewake" "asyncRewake documented"
