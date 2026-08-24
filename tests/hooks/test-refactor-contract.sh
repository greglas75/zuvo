#!/usr/bin/env bash
# Contract for ~/.zuvo/refactor-contract — the one command that reads and advances a refactor
# CONTRACT.
#
# Every case here is drawn from something the fleet actually did across 1,010 contracts on disk:
# four invented stage spellings, 92 contracts with no stage at all, sidecar files offered as resume
# candidates, and 134 abandoned contracts that made `continue` unusable. The gate cases matter most
# — a contract that records a phase without its evidence is what a resumed run, the commit gate and
# the retro all go on to read as fact.
#
# bash 3.2-compatible (macOS default). Accumulate-and-report.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/refactor-contract"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$BIN" ] || { bad "scripts/zuvo-home/refactor-contract does not exist"; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
R="$TMP/repo"
mkdir -p "$R/.git" "$R/src" "$R/zuvo/contracts"

mkcontract() { # mkcontract <name> <python-mutation>
  python3 - "$R/zuvo/contracts/$1" "$2" <<'PY'
import json, sys
path, mut = sys.argv[1], sys.argv[2]
c = {"version": 5, "file": "src/order.service.ts", "type": "EXTRACT_METHODS", "mode": "full",
     "stage": "PHASE-1", "cq_before": {"score": "11/18"}, "modules_created": [],
     "prove": {k: "not_run" for k in
               ("characterization", "blind_audit", "adversarial", "regression_red",
                "test_quality", "split_coverage", "complexity_before", "complexity_reduced")},
     "progress": []}
c["prove"]["findings_disposition"] = "pending"
if mut:
    exec(mut)
json.dump(c, open(path, "w"), indent=1)
PY
}

run() { ( cd "$R" && python3 "$BIN" "$@" ) > "$TMP/out" 2> "$TMP/err"; }

# ── 1. the gate: a phase cannot be entered without the evidence it depends on ─
mkcontract "refactor-aaaaaaaa.json" ""
run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" stage PHASE-4; rc=$?
if [ "$rc" -eq 1 ] && grep -q 'REFUSED' "$TMP/err"; then
  pass "a phase whose prerequisites are unproven is REFUSED"
else
  bad "PHASE-4 accepted with every prove field at not_run (exit=$rc)"
fi
grep -q 'prove.characterization' "$TMP/err" \
  && pass "the refusal names which evidence is missing" \
  || bad "refusal does not say what is missing"
grep -q 'refactor-contract prove' "$TMP/err" \
  && pass "the refusal says how to satisfy it" \
  || bad "refusal gives no way forward"

# The stage must NOT have been written by a refused call.
python3 -c "
import json,sys
sys.exit(0 if json.load(open('$R/zuvo/contracts/refactor-aaaaaaaa.json'))['stage']=='PHASE-1' else 1)" \
  && pass "a refused advance leaves the contract untouched" \
  || bad "the contract was mutated by a call that was refused"

# ── 2. recording the evidence unlocks the phase ───────────────────────────────
for f in characterization regression_red test_quality; do
  run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" prove "$f" "PASS 41 tests, 0 failures"
done
run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" prove findings_disposition "3 fixed, 1 preserved"
run --contract "$R/zuvo/contracts/refactor-aaaaaaaa.json" stage PHASE-4; rc=$?
[ "$rc" -eq 0 ] && pass "the same advance succeeds once the evidence is recorded" \
  || bad "PHASE-4 still refused after its prerequisites were proven (exit=$rc): $(head -3 "$TMP/err")"

# ── 3. "not_run" is not evidence ──────────────────────────────────────────────
mkcontract "refactor-bbbbbbbb.json" ""
run --contract "$R/zuvo/contracts/refactor-bbbbbbbb.json" prove characterization "not_run"; rc=$?
[ "$rc" -eq 2 ] && pass "recording 'not_run' as evidence is rejected" \
  || bad "'not_run' was accepted as proof (exit=$rc)"
run --contract "$R/zuvo/contracts/refactor-bbbbbbbb.json" prove characterization "-"; rc=$?
[ "$rc" -eq 2 ] && pass "a placeholder is rejected too" || bad "'-' accepted as proof (exit=$rc)"

# ── 4. the four spellings the fleet invented map onto the vocabulary ──────────
# READY_FOR_COMMIT (28 in the wild), READY_TO_COMMIT (3), EXECUTION_COMPLETE (8),
# EXECUTION_COMPLETE_UNCOMMITTED (7). Two of those are one state spelled two ways.
mkcontract "refactor-cccccccc.json" "c['prove']['characterization']='PASS'; c['prove']['regression_red']='RED then GREEN'"
for spelling in READY_FOR_COMMIT READY_TO_COMMIT EXECUTION_COMPLETE EXECUTION_COMPLETE_UNCOMMITTED; do
  run --contract "$R/zuvo/contracts/refactor-cccccccc.json" stage "$spelling"; rc=$?
  st=$(python3 -c "import json;print(json.load(open('$R/zuvo/contracts/refactor-cccccccc.json'))['stage'])")
  if [ "$rc" -eq 0 ] && [ "$st" = "PHASE-3.5" ]; then
    pass "$spelling is recorded as PHASE-3.5"
  else
    bad "$spelling became '$st' (exit=$rc)"
  fi
done

run --contract "$R/zuvo/contracts/refactor-cccccccc.json" stage NONSENSE_STAGE; rc=$?
[ "$rc" -eq 2 ] && grep -q 'is not a stage' "$TMP/err" \
  && pass "a stage outside the vocabulary is rejected with the list" \
  || bad "free text was accepted as a stage (exit=$rc)"

# ── 5. sidecars are never resume candidates ──────────────────────────────────
# `refactor-*.json` also matches the adversarial/findings files the skill writes beside a contract.
# In tgm-survey-platform three of those — unparseable as well — were being offered by `continue`.
printf '[]\n' > "$R/zuvo/contracts/refactor-dddddddd-adversarial.json"
printf '{"findings": []}\n' > "$R/zuvo/contracts/refactor-dddddddd-findings.json"
run list
grep -q 'adversarial' "$TMP/out" \
  && bad "a sidecar was listed as a contract" \
  || pass "sidecars are excluded from the listing"

# ── 6. abandoned contracts are not offered ───────────────────────────────────
# A distinct target, so the assertion below cannot match one of the fresh fixtures by accident —
# every other fixture here shares the same `file`, and the first version of this test matched those.
mkcontract "refactor-eeeeeeee.json" "c['stage']='PHASE-2'; c['file']='src/abandoned-target.ts'"
python3 -c "
import os,time
p='$R/zuvo/contracts/refactor-eeeeeeee.json'
old=time.time()-40*86400
os.utime(p,(old,old))"
run list
awk '/RESUMABLE/,/stale/' "$TMP/out" | grep -q 'abandoned-target' \
  && bad "a 40-day-old contract was offered as resumable" \
  || pass "an abandoned contract is counted, not offered"
grep -qE 'stale \(>14d, not offered\): [1-9]' "$TMP/out" \
  && pass "the listing says how many were withheld and why" \
  || bad "stale contracts were hidden without saying so"

# ── 7. a malformed contract is reported, not crashed on ──────────────────────
# Nine contracts on disk are a bare LIST at the top level; ten do not parse at all.
printf '[1,2,3]\n' > "$R/zuvo/contracts/refactor-ffffffff.json"
run list; rc=$?
[ "$rc" -eq 0 ] && pass "a malformed contract does not crash the listing" \
  || bad "listing crashed on a malformed contract (exit=$rc): $(head -3 "$TMP/err")"

# ── 8. --force is available, and says what it did ────────────────────────────
mkcontract "refactor-99999999.json" ""
run --contract "$R/zuvo/contracts/refactor-99999999.json" stage COMPLETE --force; rc=$?
[ "$rc" -eq 0 ] && pass "--force records an unproven stage (a human's call)" \
  || bad "--force did not work (exit=$rc)"
grep -q 'forced past' "$TMP/out" \
  && pass "a forced advance says so in the output" \
  || bad "a forced advance is indistinguishable from a proven one"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
