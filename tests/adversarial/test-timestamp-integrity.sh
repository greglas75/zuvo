#!/usr/bin/env bash
# test-timestamp-integrity.sh — field-1 timestamps are machine-owned and a
# FUTURE timestamp can never enter either log. Closes M3 (the fabricated
# 2026-05-29T22:30:00Z run+retro pair that was hand-stamped ~20h ahead to
# satisfy the gate's ts>=run_start branch for stale work).

ARET="$ROOT/scripts/zuvo-home/append-retro"
ARUN="$ROOT/scripts/zuvo-home/append-runlog"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }

start_test "append-runlog REJECTS a future field1 (>now+300s)"
Z=$(_z)
printf '%s\n' "$(printf '2099-01-01T00:00:00Z\tbacklog\tP\t-\t-\tPASS\t-\ts\tn\tmain\tabc\t-\t-')" \
  | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
assert_exit_code 2 "$?" "future run-line rejected"
assert_eq 0 "$(grep -c . "$Z/runs.log" 2>/dev/null || echo 0)" "nothing appended"

start_test "append-retro REJECTS a future --date"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=P --friction=other --date=2099-01-01T00:00:00Z >/dev/null 2>&1
assert_exit_code 2 "$?" "future retro date rejected"

start_test "a PAST git-commit-time field1 is ACCEPTED (backfill stays possible)"
Z=$(_z)
printf '%s\n' "$(printf '2026-01-15T08:30:00Z\tbacklog\tP\t-\t-\tPASS\t-\ts\tbackfilled\tmain\tabc\t-\t-')" \
  | ZUVO_HOME="$Z" "$ARUN" >/dev/null 2>&1
assert_exit_code 0 "$?" "historical (past) timestamp accepted for backfill"
f1=$(awk -F'\t' '{print $1}' "$Z/runs.log")
assert_eq "2026-01-15T08:30:00Z" "$f1" "past timestamp preserved verbatim (not re-stamped to now)"

start_test "a future-dated retro can NOT be written, so it can NOT satisfy the gate"
Z=$(_z)
# Attempt the exact 2026-05-29 forgery: write a far-future retro, then try to
# log a run that relies on it. The retro write must fail at the source.
ZUVO_HOME="$Z" "$ARET" --skill=execute --project=P --friction=other --date=2099-12-31T23:59:59Z >/dev/null 2>&1
assert_exit_code 2 "$?" "forged future retro refused at write time"
assert_eq 0 "$(grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0)" "no future retro on disk to abuse"
