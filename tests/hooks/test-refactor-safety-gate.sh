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
  #           [$5 findings_disposition (default none)]  [$6 regression_red (omitted when empty)]
  local rr=""
  [ -n "${6:-}" ] && rr="\"regression_red\":\"$6\", "
  cat > zuvo/contracts/refactor-aaaa1111.json <<J
{ "version":3, "file":"$1", "stage":"PHASE-3", "scope_fence":["$1"],
  "prove": { "characterization":"${4:-green:aaaa111:2u}", ${rr}"blind_audit":"$2", "adversarial":"$3", "findings_disposition":"${5:-none}" } }
J
}
# Unstage after a blocked commit: the file stays in the index otherwise, so the NEXT case
# carries it along and can be blocked for the previous case's reason — one failure cascading
# into unrelated assertions.
trycommit(){ echo "x$RANDOM" >> "$1"; git add "$1"; git commit -q -m t >/dev/null 2>&1; rc=$?
  [ $rc -ne 0 ] && git reset -q >/dev/null 2>&1; echo $rc; }

chmod +x "$GATE" "$LIB" 2>/dev/null

echo "=== refactor-safety-gate: gate cases ==="
newrepo; install_hook "$GATE"
contract app.ts skipped clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "BLOCK (prove incomplete)" || bad "BLOCK"
contract app.ts clean:strict clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "PASS (prove complete)" || bad "PASS"
# A source file outside every fence used to be a NOOP here — and that hole IS the 2026-07-22
# field failure: one `zuvo:refactor` run, then ~39 files hand-rolled, none of them in any
# fence, gate silent for all of them. refactor_scope_gate_check now binds them (its own suite
# is tests/hooks/test-refactor-scope-gate.sh). refactor_gate_check itself still ignores
# out-of-fence files — that separation is what this case pins down.
contract other.ts skipped clean
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "off-fence source file now blocked (scope gate)" || bad "off-fence file still sails through"
# ...and a NON-source file outside the fence stays a genuine NOOP: the scope gate is narrow,
# so an active refactor must not block docs/config churn.
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit notes.md")" -eq 0 ] && ok "NOOP (non-source outside fence)" || bad "NOOP non-source"
contract app.ts skipped clean; install_hook "$TMP/NOPE.sh"
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "FAIL-OPEN (gate missing)" || bad "FAIL-OPEN"
install_hook "$GATE"
contract app.ts skipped clean
# A "human" fixture must clear EVERY var _is_agent_env() inspects. Clearing only a subset
# tests "agent with some vars missing", which is exactly the hole the widened detection closed.
# HUMAN env fixture — DERIVED from the two agent-detector libraries, not copied (B-gate-8).
# This literal array used to live in four test files. See tests/lib/human-env.sh for why a
# hardcoded copy is worse than useless here: the libraries it mirrors drifted (B-gate-2) and a
# frozen fixture cannot notice, it just keeps unsetting the old set while every test passes.
# shellcheck source=/dev/null
. "$ROOT/tests/lib/human-env.sh"
[ "$("${HUMAN[@]}" bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "HUMAN-BYPASS" || bad "HUMAN-BYPASS"
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

echo "=== regression-red gated when fix-now items applied (eval finding 2026-07-10: red implied, never demonstrated) ==="
# disposition says a fix was applied but regression_red missing -> BLOCK
contract app.ts clean:strict 3findings "green:abc1234:4u" "fixed:2/backlog:4" ""
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "BLOCK (disposition has fix, regression_red absent)" || bad "BLOCK regression_red absent"
# disposition has fix and regression_red=not_run -> BLOCK
contract app.ts clean:strict 3findings "green:abc1234:4u" "1fixed,1backlogged" "not_run"
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -ne 0 ] && ok "BLOCK (regression_red=not_run)" || bad "BLOCK regression_red=not_run"
# disposition has fix and regression_red recorded -> PASS
contract app.ts clean:strict 3findings "green:abc1234:4u" "fixed:2/backlog:4" "red@abc1234:green@def5678:src/x.test.ts"
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "PASS (regression_red recorded)" || bad "PASS regression_red recorded"
# NO fix applied (disposition=backlogged only) and regression_red absent -> PASS (field not required)
contract app.ts clean:strict 3findings "green:abc1234:4u" "backlogged:3" ""
[ "$(ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit app.ts")" -eq 0 ] && ok "PASS (no fix applied, regression_red not required)" || bad "PASS no-fix regression_red optional"

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

echo "=== _expand_plan_files: parenthetical annotations (B-gate-5) ==="
# Plans annotate entries inline — `svc.ts (modify — line 559, extract helper)` — and 136 such
# commas were counted across real plan files. The tokenizer tracked only {} depth, so that entry
# split into two non-paths and the declared file vanished from what the gate can see. Fail-open
# only, but a silent under-scope is precisely what this gate exists to prevent.
( . "$LIB"
  _p="$TMP/plan-annot.md"
  printf '%s\n' '**Files:** src/svc.ts (modify — line 559, extract helper), src/other.ts' \
                '**Files:** apps/{web,api}/main.ts, lib/util.ts' \
                '**Files:** weird/name(v2).ts, plain.ts' > "$_p"
  _got="$(_expand_plan_files "$_p" | tr '\n' '|')"
  _want='src/svc.ts|src/other.ts|apps/web/main.ts|apps/api/main.ts|lib/util.ts|weird/name(v2).ts|plain.ts|'
  if [ "$_got" = "$_want" ]; then
    echo "  ✓ annotations stripped, braces expanded, glued parens in a real path preserved"
  else
    echo "  ✗ _expand_plan_files: got [$_got] want [$_want]"; exit 1
  fi
) || fails=$((fails+1))

echo "=== execution-state.md dialects (B-gate-1, B-gate-7) ==="
# Three forms of the same field exist in live repos. Two were already parsed; the INDENTED one
# matched neither branch of _ap_field and fail-opened — the gate simply saw no status and let the
# commit through. A gate that silently sees nothing is worse than one that blocks, because the
# transcript looks identical to a pass.
( . "$LIB"
  _d="$TMP/dialects"; mkdir -p "$_d"
  _chk(){ printf '%s\n' "$2" > "$_d/s.md"
          _got="$(_ap_status "$_d/s.md")"
          if [ "$_got" = "$3" ]; then echo "  ✓ dialect $1 → [$_got]"; else echo "  ✗ dialect $1 → [$_got], expected [$3]"; exit 1; fi; }
  _chk "plain"    'status: in-progress'          'in-progress'
  _chk "comment"  '<!-- status: in-progress -->' 'in-progress'
  _chk "indented" '  status: in-progress'        'in-progress'
  _chk "tabbed"   "$(printf '\tstatus: in-progress')" 'in-progress'
  _chk "negative" 'status: done'                 'done'
) || fails=$((fails+1))

# B-gate-1: the pre-commit gate must ask the LIBRARY, not grep one dialect literally. Asserted on
# the source because the alternative is staging a full execute-run fixture for a one-line contract.
if grep -q "_ap_status" "$ROOT/hooks/pre-commit-adversarial-gate.sh" \
   && ! grep -qE "^\s*if ! grep -q '<!-- status: in-progress -->'" "$ROOT/hooks/pre-commit-adversarial-gate.sh"; then
  ok "pre-commit gate reads status via _ap_status, not a literal single-dialect grep (B-gate-1)"
else
  bad "pre-commit gate still greps one dialect literally — misses ~half of live execution-state.md files"
fi

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
