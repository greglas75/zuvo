#!/usr/bin/env bash
# Call the real hook entrypoint with staged work and a new-branch push line.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/src" "$TMP/repo/zuvo/contracts"
cd "$TMP/repo" || exit 1
git init -q
git config user.name Test
git config user.email test@example.invalid
printf 'base\n' > src/in.ts
git add src/in.ts
git commit -q -m base
cat > zuvo/contracts/refactor-entry.json <<'JSON'
{"version":3,"stage":"PHASE-3","scope_fence":["src/in.ts"],
 "prove":{"characterization":"green:abc1234:2u","blind_audit":"not_run",
          "adversarial":"clean","findings_disposition":"none"}}
JSON
export ZUVO_AI_RUN=1
export ZUVO_CONTRACTS_DIR="$PWD/zuvo/contracts"
fails=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }

printf 'change\n' >> src/in.ts
git add src/in.ts
echo '=== default invocation judges the staged commit ==='
if "$GATE" > "$TMP/default.out" 2> "$TMP/default.err"; then
  default_status=0
else
  default_status=$?
fi
if [ "$default_status" -eq 1 ] &&
   grep -Fq "prove.blind_audit='not_run'" "$TMP/default.out"; then
  ok 'default mode is pre-commit and blocks missing proof'
else
  bad "default mode missed staged proof: status=$default_status; output=$(cat "$TMP/default.out" "$TMP/default.err")"
fi

git commit -q -m 'fixture change'
head_sha=$(git rev-parse HEAD)
zero=0000000000000000000000000000000000000000
echo '=== new branch push judges every introduced commit ==='
if printf 'refs/heads/feature %s refs/heads/feature %s\n' "$head_sha" "$zero" \
     | "$GATE" pre-push > "$TMP/push.out" 2> "$TMP/push.err"; then
  push_status=0
else
  push_status=$?
fi
if [ "$push_status" -eq 1 ] &&
   grep -Fq "prove.blind_audit='not_run'" "$TMP/push.out"; then
  ok 'zero remote SHA takes the new-branch range path'
else
  bad "new branch missed proof: status=$push_status; output=$(cat "$TMP/push.out" "$TMP/push.err")"
fi

echo '=== RESULT ==='
[ "$fails" -eq 0 ] && { echo 'ALL PASS'; exit 0; }
echo "$fails FAILED"; exit 1
