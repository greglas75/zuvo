#!/usr/bin/env bash
# Isolate the v6 reader verdicts at each shell gate boundary.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/zuvo/contracts"
cd "$TMP" || exit 1
export ZUVO_AI_RUN=1 ZUVO_CONTRACTS_DIR="$TMP/zuvo/contracts"
cat > "$ZUVO_CONTRACTS_DIR/refactor-abc123.json" <<'JSON'
{"version":6,"file":"src/in.ts","type":"MOVE","stage":"PHASE-3",
 "scope_fence":["src/in.ts"],"modules_created":[],
 "prove":{"characterization":"green:abc1234:2u","blind_audit":"clean:strict",
          "adversarial":"clean","findings_disposition":"none",
          "test_quality":"N/A","split_coverage":"N/A"}}
JSON
. "$LIB"

# The structural reader is tested through its own CLI elsewhere. Here it is a
# collaborator: force one verdict at a time, with every other proof green.
_refactor_state() {
  printf '%s|%s%s\n' "$2" "$1" "${3:+|$3}" >> "$TMP/reader-calls"
  case "$2" in
    valid|intersects) return 0 ;;
    evidence|quality)
      if [ "${FAKE_FAIL:-}" = "$2" ]; then
        return 1
      fi
      return 0 ;;
    fixes) [ "${FAKE_FIXES:-0}" = 1 ]; return $? ;;
    count) printf '0\n' ;;
    field)
      case "$3" in
        version) printf '6\n' ;;
        stage) printf 'PHASE-3\n' ;;
        type) printf 'MOVE\n' ;;
        prove.blind_audit) printf 'clean:strict\n' ;;
        prove.adversarial) printf 'clean\n' ;;
        prove.characterization) printf 'green:abc1234:2u\n' ;;
        prove.findings_disposition) printf 'none\n' ;;
        prove.test_quality|prove.split_coverage) printf 'N/A\n' ;;
      esac ;;
  esac
  return 0
}

fails=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

echo '=== v6 pre-commit evidence verdict is causal ==='
FAKE_FAIL=evidence FAKE_FIXES=0
: > "$TMP/reader-calls"
if refactor_gate_check 'src/in.ts' > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] &&
   grep -Fxq "evidence|$ZUVO_CONTRACTS_DIR/refactor-abc123.json" "$TMP/reader-calls" &&
   grep -Fxq "field|$ZUVO_CONTRACTS_DIR/refactor-abc123.json|prove.blind_audit" "$TMP/reader-calls" &&
   ! grep -q '^quality|' "$TMP/reader-calls" &&
   [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then
  ok 'evidence reader failure alone blocks the in-flight gate'
else
  bad "evidence result was lost: rc=$rc; calls=$(cat "$TMP/reader-calls"); output=$(cat "$TMP/out" "$TMP/err")"
fi

echo '=== v6 pre-push evidence verdict is causal ==='
ZUVO_GATE_MODE=pre-push; export ZUVO_GATE_MODE
FAKE_FAIL=evidence
: > "$TMP/reader-calls"
if refactor_prove_v4_check 'src/in.ts' > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] &&
   grep -Fxq "evidence|$ZUVO_CONTRACTS_DIR/refactor-abc123.json" "$TMP/reader-calls" &&
   [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then
  ok 'evidence reader failure alone blocks the push gate'
else
  bad "push evidence result was lost: rc=$rc; output=$(cat "$TMP/out" "$TMP/err")"
fi

echo '=== v6 pre-push quality verdict is causal ==='
FAKE_FAIL=quality
: > "$TMP/reader-calls"
if refactor_prove_v4_check 'src/in.ts' > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] &&
   grep -Fxq "quality|$ZUVO_CONTRACTS_DIR/refactor-abc123.json" "$TMP/reader-calls" &&
   [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then
  ok 'quality reader failure alone blocks the push gate'
else
  bad "quality result was lost: rc=$rc; output=$(cat "$TMP/out" "$TMP/err")"
fi
FAKE_FAIL=
if refactor_prove_v4_check 'src/in.ts' > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then
  ok 'green evidence and quality readers allow the v6 push'
else
  bad "green v6 push was blocked: rc=$rc; output=$(cat "$TMP/out" "$TMP/err")"
fi
unset ZUVO_GATE_MODE

echo '=== v6 fix claim requires a demonstrated red regression ==='
FAKE_FAIL= FAKE_FIXES=1
: > "$TMP/reader-calls"
if refactor_gate_check 'src/in.ts' > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 1 ] &&
   grep -Fxq "fixes|$ZUVO_CONTRACTS_DIR/refactor-abc123.json" "$TMP/reader-calls" &&
   grep -Fq "prove.regression_red=''" "$TMP/out"; then
  ok 'fixes reader claim makes regression_red mandatory'
else
  bad "fix claim was ignored: rc=$rc; output=$(cat "$TMP/out" "$TMP/err")"
fi
FAKE_FIXES=0
if refactor_gate_check 'src/in.ts' > "$TMP/out" 2> "$TMP/err"; then rc=0; else rc=$?; fi
if [ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ ! -s "$TMP/err" ]; then
  ok 'no fix claim leaves regression_red optional'
else
  bad "non-fix contract was blocked: rc=$rc; output=$(cat "$TMP/out" "$TMP/err")"
fi

echo '=== RESULT ==='
[ "$fails" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
echo "$fails FAILED"; exit 1
