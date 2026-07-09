#!/usr/bin/env bash
# Tests the REAL hooks/refactor-safety-gate.sh + hooks/lib/refactor-gate-lib.sh.
# 6 gate cases + cross-harness (POSIX sh) + --no-verify pre-push backstop.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
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
contract(){ # $1 file  $2 blind_audit  $3 adversarial  [$4 characterization (default green)]
  cat > zuvo/contracts/refactor-aaaa1111.json <<J
{ "version":3, "file":"$1", "stage":"PHASE-3", "scope_fence":["$1"],
  "prove": { "characterization":"${4:-green:aaaa111:2u}", "blind_audit":"$2", "adversarial":"$3", "findings_disposition":"none" } }
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

echo "=== characterization lock gated (eval finding 2026-07-09: prose alone was skipped) ==="
# prove.characterization missing/not_run must BLOCK even when blind_audit+adversarial are green
contract app.ts clean:strict clean not_run
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "BLOCK (characterization=not_run)" || bad "BLOCK characterization=not_run"
cat > zuvo/contracts/refactor-aaaa1111.json <<'J'
{ "version":3, "file":"app.ts", "stage":"PHASE-3", "scope_fence":["app.ts"],
  "prove": { "blind_audit":"clean:strict", "adversarial":"clean", "findings_disposition":"none" } }
J
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "BLOCK (characterization field absent)" || bad "BLOCK characterization absent"
contract app.ts clean:strict clean "green:abc1234:4u"
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "PASS (characterization recorded)" || bad "PASS characterization recorded"

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

echo "=== regression: regex-metachar path gated (grep -F, not BRE) ==="
newrepo; install_hook "$GATE"
contract 'x[1].ts' skipped clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit 'x[1].ts'")" -ne 0 ] && ok "regex-char path blocked (no BRE bypass)" || bad "regex-char path bypassed gate"

echo "=== regression: renamed scope-fence file still gated (--no-renames) ==="
newrepo; install_hook "$GATE"
echo a > old.ts; git add old.ts; git commit -q -m base >/dev/null 2>&1
contract old.ts skipped clean
git mv old.ts new.ts
ZUVO_AI_RUN=1 git commit -q -m rename >/dev/null 2>&1
[ $? -ne 0 ] && ok "renamed fence file blocked (old path surfaced)" || bad "rename evaded gate"

echo "=== regression: pre-push gates the FULL range, not just the tip ==="
newrepo; install_hook "$GATE"
echo base > app.ts; git add app.ts; git commit -q -m base >/dev/null 2>&1
git init -q --bare "$TMP/rem3.git"; git remote add origin "$TMP/rem3.git"; git push -q origin HEAD >/dev/null 2>&1
br=$(git branch --show-current); contract app.ts skipped clean
echo a >> app.ts; git add app.ts; ZUVO_AI_RUN=1 git commit -q --no-verify -m "A violates app.ts" >/dev/null 2>&1
echo z > unrelated.ts; git add unrelated.ts; ZUVO_AI_RUN=1 git commit -q --no-verify -m "B clean tip" >/dev/null 2>&1
ZUVO_AI_RUN=1 git push origin "$br" >/dev/null 2>&1
[ $? -ne 0 ] && ok "non-tip violation caught (full-range pre-push)" || bad "non-tip commit slipped (range bug regressed)"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
