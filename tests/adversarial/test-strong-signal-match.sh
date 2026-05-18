#!/usr/bin/env bash
# test-strong-signal-match.sh — Plan Task 4 (SC2, SC5, G-SUPER, lock).
# The gate must match ONLY a FULL retro (canonical predicate) with
# skill+project AND (SHA7==HEAD or ts>=run-start). A stale retro or a stub
# must NOT satisfy a fresh completed run. Happy path must not regress.

ADV="$ROOT/scripts/zuvo-home/append-runlog"
_s4=""; _s4c(){ for d in $_s4; do rm -rf "$d" 2>/dev/null; done; }; trap _s4c EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _s4="$_s4 $d"; printf '%s' "$d"; }
H=$(git -C "$ROOT" rev-parse --short HEAD)
RUN='2026-05-18T12:00:00Z\tplan\tdemo\t-\t-\tPASS\t3\t3-phase\tx\tmain\t'"$H"'\t-\tdefault'
_call(){ ZUVO_HOME="$1" bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' >/dev/null 2>&1; }

start_test "T4.a stale FULL retro (old SHA, 30d old) does NOT satisfy a fresh run"
Z=$(_z)
printf 'RETRO: 2026-04-18T00:00:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t1\t0\t0\tmain\t0ldldld\tnot_run\tclean\tindexed\tok\n' >> "$Z/retros.log"
_call "$Z"; assert_exit_code 2 "$?" "stale full retro -> RETRO_REQUIRED (exit 2)"

start_test "T4.b fresh FULL retro at HEAD SHA satisfies the run"
printf 'RETRO: 2026-05-18T11:59:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t9\t2\t1\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
_call "$Z"; rc=$?
assert_exit_code 0 "$rc" "fresh full retro -> appended (exit 0)"
[ -s "$Z/runs.log" ] && pass "runs.log written" || fail "T4.b" "runs.log not written"

start_test "T4.c a STUB at HEAD SHA never satisfies a fresh completed run (SC2/G-SUPER)"
Z=$(_z)
printf 'RETRO: 2026-05-18T11:59:00Z\tplan\tdemo\tOTHER\tabandoned\t-\tnone\t0\t1\t0\t0\tmain\t%s\tnot_run\tnot_run\tN/A\tN/A\n' "$H" >> "$Z/retros.log"
_call "$Z"; assert_exit_code 2 "$?" "stub (field5=abandoned) at HEAD SHA -> still RETRO_REQUIRED"
[ ! -s "$Z/runs.log" ] && pass "runs.log NOT written for stub-only" || fail "T4.c" "runs.log written off a stub"

start_test "T4.d ZUVO_MATCH_LOOSE=1 lets a stale full retro satisfy"
Z=$(_z)
printf 'RETRO: 2026-04-18T00:00:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t1\t0\t0\tmain\t0ldldld\tnot_run\tclean\tindexed\tok\n' >> "$Z/retros.log"
ZUVO_HOME="$Z" ZUVO_MATCH_LOOSE=1 bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' >/dev/null 2>&1
assert_exit_code 0 "$?" "loose override accepts stale full retro"

start_test "T4.e happy-path regression: full retro + run line same SHA -> exit 0 + write"
Z=$(_z)
printf 'RETRO: 2026-05-18T11:59:30Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t9\t2\t1\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
_call "$Z"; rc=$?
assert_exit_code 0 "$rc" "canonical completed flow still gates green (SC5)"
grep -q . "$Z/runs.log" 2>/dev/null && pass "runs.log line present" || fail "T4.e" "runs.log empty"

start_test "T4.k malformed/column-drifted RETRO line is SKIPPED (fail-safe)"
Z=$(_z)
# A line with EXTRA tabs (column drift) carrying the right skill/project but
# garbage where $13 lands must NOT satisfy the gate (it is skipped, not
# misaligned-matched). Only a well-formed 17-field full retro counts.
printf 'RETRO: 2026-05-18T11:59:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\tEXTRA\tTABS\tHERE\t-\tnone\t0\t9\t2\t1\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
_call "$Z"; assert_exit_code 2 "$?" "malformed (NF!=17) retro does NOT satisfy the gate"
# adding a well-formed one alongside the malformed one then DOES satisfy
printf 'RETRO: 2026-05-18T11:59:10Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t9\t2\t1\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
_call "$Z"; assert_exit_code 0 "$?" "well-formed retro alongside malformed still works (scan continues)"

start_test "T4.j gate append lock held -> non-zero, bounded, no silent drop"
Z=$(_z)
printf 'RETRO: 2026-05-18T11:59:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t9\t2\t1\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
mkdir "$Z/.runlog.lock.d"; touch "$Z/.runlog.lock.d"
start=$(date +%s)
ZUVO_HOME="$Z" ZUVO_LOCK_WAIT=2 bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' >/dev/null 2>&1
rc=$?; el=$(( $(date +%s) - start ))
rmdir "$Z/.runlog.lock.d" 2>/dev/null
assert_ne 0 "$rc" "lock-busy exits non-zero (not a silent drop / not a false success)"
assert_le 6 "$el" "returned within bounded wait (no indefinite hang)"
