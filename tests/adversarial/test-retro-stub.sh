#!/usr/bin/env bash
# test-retro-stub.sh — Plan Task 3 (SC1, G-CONC, G-SUPER).
# retro-stub: flock-safe, idempotent (canonical full-retro predicate),
# enum-valid 17-field degraded emitter that PRESERVES friction counts.

STUB="$ROOT/scripts/zuvo-home/retro-stub"
_t3=""; _t3c(){ for d in $_t3; do rm -rf "$d" 2>/dev/null; done; }; trap _t3c EXIT INT TERM
_mkz(){ local d; d=$(mktemp -d); _t3="$_t3 $d"; printf '%s' "$d"; }

start_test "T3.0 retro-stub exists and is executable"
if [ -x "$STUB" ]; then pass "scripts/zuvo-home/retro-stub is executable"
else fail "T3.0" "scripts/zuvo-home/retro-stub missing or not +x"; fi

start_test "T3.1 emits ONE enum-valid 17-field stub + retros.md block"
Z=$(_mkz)
ZUVO_HOME="$Z" "$STUB" --status=ABANDONED --friction=abandoned --skill=brainstorm --project=demo --turns=37 >/dev/null 2>&1
rc=$?
assert_exit_code 0 "$rc" "emit exits 0"
n=$(grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0)
assert_eq 1 "$n" "exactly one RETRO line"
line=$(grep '^RETRO:' "$Z/retros.log" | head -1)
# strip the literal "RETRO: " prefix, then count tab-separated fields
nf=$(printf '%s' "${line#RETRO: }" | awk -F'\t' '{print NF}')
assert_eq 17 "$nf" "17 tab-separated fields"
f5=$(printf '%s' "${line#RETRO: }" | awk -F'\t' '{print $5}')
assert_eq "abandoned" "$f5" "field 5 = abandoned"
# friction count preserved (NOT destructive 0): --turns=37 -> TURNS_WASTED col 8
f8=$(printf '%s' "${line#RETRO: }" | awk -F'\t' '{print $8}')
assert_eq "37" "$f8" "TURNS_WASTED preserves passed-in count (no destructive 0)"
# enum-valid neutrals
assert_eq "N/A" "$(printf '%s' "${line#RETRO: }" | awk -F'\t' '{print $16}')" "CODESIFT=N/A (enum-valid)"
assert_eq "not_run" "$(printf '%s' "${line#RETRO: }" | awk -F'\t' '{print $14}')" "BLIND_AUDIT=not_run (enum-valid)"
if grep -q '^<!-- RETRO -->' "$Z/retros.md" 2>/dev/null; then pass "retros.md block appended"
else fail "T3.1" "no <!-- RETRO --> block in retros.md"; fi

start_test "T3.2 invalid --status exits non-zero and writes nothing"
Z=$(_mkz)
out=$(ZUVO_HOME="$Z" "$STUB" --status=BOGUS --skill=plan --project=demo 2>&1); rc=$?
assert_ne 0 "$rc" "invalid status exits non-zero"
if [ ! -s "$Z/retros.log" ]; then pass "no retros.log written on invalid status"
else fail "T3.2" "retros.log written despite invalid status"; fi

start_test "T3.3 idempotent: no-op when a FULL retro for skill+project+SHA7 exists"
Z=$(_mkz); S=$(git -C "$ROOT" rev-parse --short HEAD)
# canonical full retro (field 5 NOT a stub value) at HEAD SHA
printf 'RETRO: 2026-05-18T00:00:00Z\tplan\tdemo\tMIXED\tpipeline-heavy\t-\tnone\t9\t40\t12\t3\tmain\t%s\tnot_run\tclean\tindexed\tok\n' "$S" >> "$Z/retros.log"
before=$(grep -c '^RETRO:' "$Z/retros.log")
ZUVO_HOME="$Z" "$STUB" --status=ABANDONED --friction=abandoned --skill=plan --project=demo >/dev/null 2>&1
after=$(grep -c '^RETRO:' "$Z/retros.log")
assert_eq "$before" "$after" "stub is a no-op when full retro already exists (idempotent)"

start_test "T3.4 concurrency: 10 parallel emits -> 10 well-formed, 0 malformed"
Z=$(_mkz)
for i in $(seq 1 10); do
  ZUVO_HOME="$Z" "$STUB" --status=ABANDONED --friction=abandoned --skill="s$i" --project=p &
done
wait
total=$(grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0)
malformed=$(grep '^RETRO:' "$Z/retros.log" | sed 's/^RETRO: //' | awk -F'\t' 'NF!=17' | wc -l | tr -d ' ')
assert_eq 10 "$total" "all 10 concurrent emits landed"
assert_eq 0 "$malformed" "0 malformed/interleaved lines (flock works)"

start_test "T3.5 lock held past bounded wait -> non-zero, no hang, no write"
Z=$(_mkz)
# Hold the lock using the SAME portable primitive the stub uses:
# a mkdir-atomic lock DIR at <ZUVO_HOME>/.retro.lock.d (no flock dependency).
mkdir "$Z/.retro.lock.d"
touch "$Z/.retro.lock.d"   # fresh mtime so stale-reclaim (60s) does NOT fire
start=$(date +%s)
ZUVO_HOME="$Z" ZUVO_LOCK_WAIT=2 "$STUB" --status=ABANDONED --friction=abandoned --skill=x --project=p >/dev/null 2>&1
rc=$?; elapsed=$(( $(date +%s) - start ))
rmdir "$Z/.retro.lock.d" 2>/dev/null
assert_ne 0 "$rc" "lock-busy exits non-zero (does not silently drop)"
assert_le 6 "$elapsed" "returned within bounded wait (<=6s, not an indefinite hang)"
if [ ! -s "$Z/retros.log" ]; then pass "nothing written when lock unavailable"
else fail "T3.5" "wrote despite not holding the lock"; fi
