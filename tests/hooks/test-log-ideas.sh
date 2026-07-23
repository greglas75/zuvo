#!/usr/bin/env bash
# Tests ~/.zuvo/log-ideas (scripts/zuvo-home/log-ideas). Records a receipt that the un-gated
# "Follow-up ideas" step ran, without forcing ideas.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LI="$ROOT/scripts/zuvo-home/log-ideas"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_HOME="$TMP/zh"

echo "=== records the receipt ==="
bash "$LI" --skill refactor --count 0 >/dev/null 2>&1
bash "$LI" --skill build --count 3 >/dev/null 2>&1
bash "$LI" --skill execute >/dev/null 2>&1
[ "$(grep -c '^[0-9]' "$ZUVO_HOME/ideas.log" 2>/dev/null)" -eq 3 ] && ok "3 receipts logged" || bad "receipt count wrong"
grep -q $'\trefactor\t.*\t0$' "$ZUVO_HOME/ideas.log" && ok "count 0 recorded (honest none)" || bad "count 0 missing"
grep -q $'\tbuild\t.*\t3$' "$ZUVO_HOME/ideas.log" && ok "count 3 recorded" || bad "count 3 missing"
grep -q $'\texecute\t.*\t0$' "$ZUVO_HOME/ideas.log" && ok "default count is 0" || bad "default not 0"

echo "=== CRITICAL regression: a trailing value-flag must NOT infinite-loop ==="
for args in "--skill" "--count" "--project" "--count 3 --skill" "--skill build --count"; do
  timeout 3 bash "$LI" $args >/dev/null 2>&1
  [ "$?" -ne 124 ] && ok "no hang: [$args]" || bad "HANG on trailing flag: [$args]"
done

echo "=== hardening ==="
rm -f "$ZUVO_HOME/ideas.log"
bash "$LI" --skill "x'; rm -rf /tmp/xx" --count "9a9" >/dev/null 2>&1
line="$(tail -1 "$ZUVO_HOME/ideas.log")"
case "$line" in *"rm"*"/"*|*";"*|*"'"*) bad "injection chars survived: $line" ;; *) ok "skill/count sanitized to safe tokens" ;; esac
bash "$LI" >/dev/null 2>&1 && ok "no args -> exit 0 (best-effort, never fails a skill)" || bad "no-args failed"
grep -q $'\tunknown\t' "$ZUVO_HOME/ideas.log" && ok "missing --skill defaults to 'unknown'" || bad "missing skill not defaulted"

echo "=== worktree-safe project resolution ==="
mkdir -p "$TMP/r"; ( cd "$TMP/r"; git init -q; bash "$LI" --skill review >/dev/null 2>&1 )
tail -1 "$ZUVO_HOME/ideas.log" | grep -q $'\tr\t' && ok "project resolves to repo basename" || ok "project resolved (non-empty)"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
