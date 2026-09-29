#!/usr/bin/env bash
# Exercise the structural reader through its CLI and the contract consumer.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
STATE="$ROOT/hooks/lib/refactor-state.py"
CONTRACT="$ROOT/scripts/zuvo-home/refactor-contract"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/zuvo/contracts"
cd "$TMP/repo" || exit 1
git init -q
fails=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

cat > zuvo/contracts/refactor-bbb222.json <<'JSON'
{"kind":"refactor-contract","file":"src/blocked.ts","stage":"BLOCKED"}
JSON
cat > zuvo/contracts/refactor-aaa111.json <<'JSON'
{"kind":"refactor-contract","file":"src/active.ts","stage":"PHASE-2"}
JSON

echo '=== terminal stage is excluded from resumable contracts ==='
if python3 "$CONTRACT" list --json > "$TMP/list.json" 2> "$TMP/list.err" &&
   python3 - "$TMP/list.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding='utf-8'))
assert data['complete'] == 1, data
assert [row['file'] for row in data['resumable']] == ['src/active.ts'], data
PY
then
  ok 'BLOCKED is terminal while PHASE-2 remains resumable'
else
  bad "terminal-stage list is wrong: $(cat "$TMP/list.json" "$TMP/list.err")"
fi

cat > zuvo/contracts/refactor-reader.json <<'JSON'
{"kind":"refactor-contract","file":"src/a.ts","stage":"PHASE-3",
 "findings_outcome":"fixed","fix_findings":[],
 "scope_fence":["src/a.ts","src/b.ts"]}
JSON

echo '=== fixed finding outcome is sufficient evidence of a fix claim ==='
if python3 "$STATE" zuvo/contracts/refactor-reader.json fixes; then
  ok 'fixed outcome is recognized without a redundant fix_findings array'
else
  bad 'fixed outcome was ignored'
fi

echo '=== scope membership is exact ==='
if python3 "$STATE" zuvo/contracts/refactor-reader.json contains scope_fence src/a.ts &&
   ! python3 "$STATE" zuvo/contracts/refactor-reader.json contains scope_fence src/c.ts; then
  ok 'present path is contained and absent path is rejected'
else
  bad 'contains inverted or ignored scope membership'
fi

echo '=== RESULT ==='
[ "$fails" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
echo "$fails FAILED"; exit 1
