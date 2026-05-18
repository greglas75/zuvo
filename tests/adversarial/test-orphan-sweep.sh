#!/usr/bin/env bash
# test-orphan-sweep.sh — Plan Task 5 (SC1, passive next-boundary capture).
# retro-stub --sweep: for each run-marker with NO matching full retro, emit
# exactly one ABANDONED stub and clear the marker; a marker WITH a matching
# full retro is cleared WITHOUT a stub; idempotent; >7d unparseable removed.

STUB="$ROOT/scripts/zuvo-home/retro-stub"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; mkdir -p "$d/run-markers"; printf '%s' "$d"; }
H=$(git -C "$ROOT" rev-parse --short HEAD)
_marker(){ printf 'start_ts=%s\nskill=%s\nproject=%s\nsha7=%s\nsession_id=%s\n' \
  "${5:-2026-05-18T10:00:00Z}" "$2" "$3" "$4" "S1" > "$1"; }

start_test "T5.a orphan marker (no full retro) -> one ABANDONED stub + marker cleared"
Z=$(_z)
_marker "$Z/run-markers/brainstorm-demo-$H.marker" brainstorm demo "$H"
ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
assert_exit_code 0 "$?" "sweep exits 0"
n=$(grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0)
assert_eq 1 "$n" "exactly one stub emitted for the orphan"
f5=$(grep '^RETRO:' "$Z/retros.log" | head -1 | sed 's/^RETRO: //' | awk -F'\t' '{print $5}')
assert_eq "abandoned" "$f5" "stub friction = abandoned"
sk=$(grep '^RETRO:' "$Z/retros.log" | head -1 | sed 's/^RETRO: //' | awk -F'\t' '{print $2}')
assert_eq "brainstorm" "$sk" "stub skill = marker skill"
[ -z "$(ls -A "$Z/run-markers" 2>/dev/null)" ] && pass "marker cleared" || fail "T5.a" "marker not removed"

start_test "T5.b marker WITH matching FULL retro -> cleared, NO stub"
Z=$(_z)
printf 'RETRO: 2026-05-18T11:59:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t0\t9\t2\t1\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$H" >> "$Z/retros.log"
_marker "$Z/run-markers/plan-demo-$H.marker" plan demo "$H"
ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
n=$(grep -c '^RETRO:' "$Z/retros.log")
assert_eq 1 "$n" "no stub added (full retro already present)"
# clean count: $(grep -c) captures the printed "0" on no-match (exit 1);
# NO `|| echo 0` (that double-prints -> "0\n0" -> invalid integer compare).
acount=$(grep -c $'\tabandoned\t' "$Z/retros.log" 2>/dev/null) || true
[ "${acount:-0}" -eq 0 ] && pass "no abandoned stub written" || fail "T5.b" "stub written despite full retro"
[ -z "$(ls -A "$Z/run-markers" 2>/dev/null)" ] && pass "marker cleared anyway" || fail "T5.b" "marker not removed"

start_test "T5.c --sweep idempotent + empty/no marker dir -> exit 0 no-op"
Z=$(_z)
_marker "$Z/run-markers/build-proj-$H.marker" build proj "$H"
ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
first=$(grep -c '^RETRO:' "$Z/retros.log")
ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1; rc=$?
second=$(grep -c '^RETRO:' "$Z/retros.log")
assert_exit_code 0 "$rc" "second sweep exits 0"
assert_eq "$first" "$second" "second sweep is a no-op (markers already gone)"
Z2=$(mktemp -d); _o="$_o $Z2"   # no run-markers dir at all
ZUVO_HOME="$Z2" "$STUB" --sweep >/dev/null 2>&1
assert_exit_code 0 "$?" "sweep with no run-markers dir exits 0 cleanly"

start_test "T5.e lock-busy during sweep -> marker PRESERVED (no telemetry loss)"
Z=$(_z)
_marker "$Z/run-markers/ship-app-$H.marker" ship app "$H"
mkdir "$Z/.retro.lock.d"; echo $$ > "$Z/.retro.lock.d/pid"   # our pid = live, never stolen
ZUVO_HOME="$Z" ZUVO_LOCK_WAIT=1 "$STUB" --sweep >/dev/null 2>&1; rc=$?
rm -f "$Z/.retro.lock.d/pid"; rmdir "$Z/.retro.lock.d" 2>/dev/null
assert_ne 0 "$rc" "sweep reports non-zero when a marker could not be handled"
if [ -e "$Z/run-markers/ship-app-$H.marker" ]; then
  pass "orphan marker PRESERVED for a later sweep (no permanent loss)"
else
  fail "T5.e" "marker deleted despite lock-busy — passive capture permanently lost"
fi

start_test "T5.d >7d unparseable marker removed defensively, no stub"
Z=$(_z)
echo "garbage-no-fields" > "$Z/run-markers/junk.marker"
# backdate mtime 8 days
if touch -t "$(date -u -v-8d +%Y%m%d%H%M 2>/dev/null || date -u -d '8 days ago' +%Y%m%d%H%M)" "$Z/run-markers/junk.marker" 2>/dev/null; then
  ZUVO_HOME="$Z" "$STUB" --sweep >/dev/null 2>&1
  assert_exit_code 0 "$?" "sweep exits 0"
  [ -z "$(ls -A "$Z/run-markers" 2>/dev/null)" ] && pass ">7d unparseable marker removed" || fail "T5.d" "stale junk marker not removed"
  [ ! -s "$Z/retros.log" ] && pass "no stub from unparseable marker" || fail "T5.d" "stub emitted from junk marker"
else
  pass "skipped (touch -t backdate unsupported on host)"
fi
