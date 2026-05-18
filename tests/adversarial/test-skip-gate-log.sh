#!/usr/bin/env bash
# test-skip-gate-log.sh — Plan Task 4 (SC4, SC4b, CQ6 rotation).
# ZUVO_SKIP_RETRO_GATE=1 must record a parseable, rotated SKIP: line so the
# next zuvo:context-audit can surface the bypass.

ADV="$ROOT/scripts/zuvo-home/append-runlog"
_sg=""; _sgc(){ for d in $_sg; do rm -rf "$d" 2>/dev/null; done; }; trap _sgc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _sg="$_sg $d"; printf '%s' "$d"; }
RUN='2026-05-18T12:00:00Z\tplan\tdemo\t-\t-\tPASS\t3\t3-phase\tx\tmain\tabc1234\t-\tdefault'

start_test "T4.f+g ZUVO_SKIP_RETRO_GATE=1 writes a SKIP: line + warns about context-audit"
Z=$(_z)
out=$(ZUVO_HOME="$Z" ZUVO_SKIP_RETRO_GATE=1 bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' 2>&1)
assert_exit_code 0 "$?" "bypass still exits 0 (non-blocking escape hatch)"
if [ -f "$Z/skip-retro-gate.log" ] && grep -q '^SKIP:' "$Z/skip-retro-gate.log"; then
  pass "skip-retro-gate.log has a SKIP: line"
else
  fail "T4.f" "no SKIP: line in skip-retro-gate.log"
fi
assert_contains "$out" "context-audit" "WARN references zuvo:context-audit"
# parseable contract: SKIP: <ISO> <skill> <project> ... with >=4 tab fields
nf=$(grep '^SKIP:' "$Z/skip-retro-gate.log" | head -1 | awk -F'\t' '{print NF}')
if [ "${nf:-0}" -ge 4 ]; then pass "SKIP: line is tab-parseable (>=4 fields)"
else fail "T4.f" "SKIP: line not parseable (NF=$nf)"; fi
sk=$(grep '^SKIP:' "$Z/skip-retro-gate.log" | head -1 | awk -F'\t' '{print $3}')
assert_eq "plan" "$sk" "SKIP: field 3 = skill"

start_test "T4.i skip-log lock busy -> does NOT falsely claim 'Recorded' (honesty)"
Z=$(_z)
# Pre-hold the lock with OUR pid (provably alive -> never stolen), forcing the
# locked path to fail. Invariant under test: the script must NEVER print
# "Recorded to skip-retro-gate.log" unless a SKIP: line actually exists.
mkdir "$Z/.runlog.lock.d"; echo $$ > "$Z/.runlog.lock.d/pid"
out=$(ZUVO_HOME="$Z" ZUVO_LOCK_WAIT=1 ZUVO_SKIP_RETRO_GATE=1 bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' 2>&1)
rm -f "$Z/.runlog.lock.d/pid" 2>/dev/null; rmdir "$Z/.runlog.lock.d" 2>/dev/null
if echo "$out" | grep -q 'Recorded to skip-retro-gate.log'; then
  grep -q '^SKIP:' "$Z/skip-retro-gate.log" 2>/dev/null \
    && pass "claimed Recorded AND a SKIP: line exists (consistent)" \
    || fail "T4.i" "FALSE CLAIM: said 'Recorded' but no SKIP: line written"
else
  pass "did not falsely claim Recorded when it could not record"
fi

start_test "T4.h skip-retro-gate.log rotates (header + last 100)"
Z=$(_z)
for i in $(seq 1 105); do
  ZUVO_HOME="$Z" ZUVO_SKIP_RETRO_GATE=1 bash -c 'printf "%b\n" "'"$RUN"'" | "'"$ADV"'"' >/dev/null 2>&1
done
total=$(grep -c '^SKIP:' "$Z/skip-retro-gate.log")
hdr=$(head -1 "$Z/skip-retro-gate.log" | grep -c '^#')
assert_eq 100 "$total" "exactly 100 SKIP: lines retained (CQ6 rotation)"
assert_eq 1 "$hdr" "schema header preserved on rotation"
