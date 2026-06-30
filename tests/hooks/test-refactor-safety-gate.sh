#!/usr/bin/env bash
# Tests the REAL hooks/refactor-safety-gate.sh + hooks/lib/refactor-gate-lib.sh.
# 6 gate cases + cross-harness (POSIX sh) + --no-verify pre-push backstop.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
LIB="$ROOT/hooks/lib/refactor-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/zuvo/contracts"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t; }
install_hook(){ # $1 = gate path to bake
  cat > .git/hooks/pre-commit <<H
#!/bin/sh
G="$1"; [ -x "\$G" ] || exit 0
exec "\$G" pre-commit
H
  cat > .git/hooks/pre-push <<H
#!/bin/sh
G="$1"; [ -x "\$G" ] || exit 0
exec "\$G" pre-push
H
  chmod +x .git/hooks/pre-commit .git/hooks/pre-push; }
contract(){ cat > zuvo/contracts/refactor-aaaa1111.json <<J
{ "version":3, "file":"$1", "stage":"PHASE-3", "scope_fence":["$1"],
  "prove": { "blind_audit":"$2", "adversarial":"$3", "findings_disposition":"none" } }
J
}
trycommit(){ echo "x$RANDOM" >> "$1"; git add "$1"; git commit -q -m t >/dev/null 2>&1; echo $?; }

chmod +x "$GATE" "$LIB" 2>/dev/null

echo "=== refactor-safety-gate: gate cases ==="
newrepo; install_hook "$GATE"
contract app.ts skipped clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "BLOCK (prove incomplete)" || bad "BLOCK"
contract app.ts clean:strict clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "PASS (prove complete)" || bad "PASS"
contract other.ts skipped clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "NOOP (outside fence)" || bad "NOOP"
contract app.ts skipped clean; install_hook "$TMP/NOPE.sh"
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "FAIL-OPEN (gate missing)" || bad "FAIL-OPEN"
install_hook "$GATE"
contract app.ts skipped clean
[ "$(env -u ZUVO_AI_RUN -u CLAUDECODE -u CURSOR_TRACE_ID -u CODEX_SANDBOX bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "HUMAN-BYPASS" || bad "HUMAN-BYPASS"
contract app.ts skipped clean; touch -t 202001010000 zuvo/contracts/*.json
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "STALE-BYPASS" || bad "STALE-BYPASS"

echo "=== cross-harness: lib runs under POSIX sh ==="
sh -c ". '$LIB'; type refactor_gate_check >/dev/null 2>&1" && ok "lib loads under /bin/sh" || bad "lib /bin/sh"

echo "=== --no-verify bypass caught by pre-push backstop ==="
newrepo; install_hook "$GATE"
git commit -q --allow-empty -m base >/dev/null 2>&1
( cd "$TMP" && git init -q --bare remote.git ) ; git remote add origin "$TMP/remote.git"
git push -q origin master >/dev/null 2>&1 || git push -q origin main >/dev/null 2>&1
br=$(git branch --show-current)
contract app.ts skipped clean
echo y >> app.ts; git add app.ts
ZUVO_AI_RUN=1 git commit -q --no-verify -m bypass >/dev/null 2>&1   # skips pre-commit
out=$(ZUVO_AI_RUN=1 git push origin "$br" 2>&1); rc=$?
[ "$rc" -ne 0 ] && ok "pre-push blocks --no-verify-bypassed refactor commit" || bad "pre-push backstop (push succeeded)"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
