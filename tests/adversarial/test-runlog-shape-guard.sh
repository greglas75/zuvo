#!/usr/bin/env bash
# test-runlog-shape-guard.sh — append-runlog must REJECT the runs.log
# contamination classes (the `-e 2026-...` and `Run: 2026-...` lines) and
# defensively strip a stray label prefix. Uses the gate-exempt `backlog` skill
# so the shape guard is tested in isolation from the retro gate.

ARUN="$ROOT/scripts/zuvo-home/append-runlog"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }
T="2026-05-29T00:00:00Z"
GOOD=$(printf '%s\tbacklog\tProjX\t-\t-\tPASS\t-\tstd\tnote\tmain\tabc1234\t-\t-' "$T")

start_test "well-formed 13-field line APPENDS (exempt skill)"
Z=$(_z)
printf '%b\n' "$GOOD" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
assert_exit_code 0 "$?" "clean line accepted"
assert_eq 1 "$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)" "one row written"

start_test "leading 'Run: ' prefix STRIPPED, row clean"
Z=$(_z)
printf '%s\n' "Run: $GOOD" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
f1c=$(awk -F'\t' '{print substr($1,1,1)}' "$Z/runs.log" 2>/dev/null)
assert_eq "2" "$f1c" "field1 starts with a digit (Run: prefix removed)"

start_test "leading '-e ' (echo -e leak) STRIPPED, row clean"
Z=$(_z)
printf '%s\n' "-e $GOOD" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
f1c=$(awk -F'\t' '{print substr($1,1,1)}' "$Z/runs.log" 2>/dev/null)
assert_eq "2" "$f1c" "field1 starts with a digit (-e prefix removed)"

start_test "wrong field count REJECTED (no append)"
Z=$(_z)
printf '%s\n' "$(printf '%s\tbacklog\tProjX\tPASS\tnote' "$T")" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
assert_exit_code 2 "$?" "5-field line rejected"
assert_eq 0 "$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)" "nothing appended"

start_test "non-ISO garbage field1 -> stamped, but extra field count still REJECTED"
Z=$(_z)
# 14 fields (one too many) with junk field1 -> after stamp it is still 14 -> reject
printf '%s\n' "$(printf 'junk\tbacklog\tProjX\t-\t-\tPASS\t-\tstd\tnote\tmain\tabc\t-\t-\textra')" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
assert_exit_code 2 "$?" "14-field line rejected even after field1 stamp"

start_test "embedded newline REJECTED"
Z=$(_z)
printf '%b\n' "$GOOD\nINJECTED malicious second line" | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
rc=$?
# %b expands the \n into a real newline -> append-runlog sees a 2-line stdin.
# Either the newline guard (exit 2) or the shape guard must reject it.
assert_exit_code 2 "$rc" "newline-bearing input rejected"
