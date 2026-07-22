#!/usr/bin/env bash
# Tests refactor_scope_gate_check via the REAL entry (hooks/refactor-safety-gate.sh).
#
# The scenario being reproduced is the 2026-07-22 field failure: `zuvo:refactor` was invoked
# ONCE, then ~39 further changes were hand-rolled with a self-described "lighter process" and
# reported as done+verified. refactor_gate_check could not see any of them, because it only
# inspects files that are already inside some contract's scope_fence — and the hand-rolled
# files were in none. This gate closes that, and (by construction) forces the skill to be
# re-invoked, which re-injects the 861-line protocol that compaction had dropped.
set -u
# Neutralize the developer's real git config (this machine sets a global core.hooksPath).
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_HOME="$TMP/zuvohome"; mkdir -p "$ZUVO_HOME/run-markers"

HUMAN=(env -u ZUVO_AGENT -u ZUVO_AI_RUN -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT \
       -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CODEX_WORKSPACE \
       -u CODEX_HOME -u CURSOR_TRACE_ID -u CURSOR_AGENT -u GEMINI_CLI -u ANTIGRAVITY \
       -u GEMINI_ANTIGRAVITY -u ANTIGRAVITY_SESSION_ID)

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/zuvo/contracts" "$TMP/r/src"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  printf '#!/bin/sh\nexec "%s" pre-commit\n' "$GATE" > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit; }

# An ACTIVE contract (stage != COMPLETE) whose fence covers only $1.
contract(){ printf '{"stage":"PHASE-3","scope_fence":["%s"],"prove":{"blind_audit":"clean:strict","adversarial":"clean","characterization":"locked","findings_disposition":"none"}}' "$1" > zuvo/contracts/refactor-a.json; }
complete_contract(){ printf '{"stage":"COMPLETE","scope_fence":["%s"],"prove":{"blind_audit":"clean:strict","adversarial":"clean","characterization":"locked","findings_disposition":"none"}}' "$1" > zuvo/contracts/refactor-a.json; }

trycommit(){ mkdir -p "$(dirname "$1")"; echo "x$RANDOM" >> "$1"; git add "$1"
  git commit -q -m t >/dev/null 2>&1; rc=$?; [ $rc -ne 0 ] && git reset -q >/dev/null 2>&1; echo $rc; }
AI(){ ZUVO_AI_RUN=1 bash -c "$(declare -f trycommit); trycommit $1"; }

chmod +x "$GATE" "$ROOT/hooks/lib/refactor-gate-lib.sh" 2>/dev/null

echo "=== the field failure: one skill run, then hand-rolled files ==="
newrepo; contract "src/a.ts"
[ "$(AI src/a.ts)" -eq 0 ] && ok "in-fence file with a proven contract commits" || bad "in-fence file blocked"
[ "$(AI src/b.ts)" -ne 0 ] && ok "BLOCK off-contract src/b.ts while a refactor is active" || bad "off-contract file sailed through (the actual bug)"
[ "$(AI src/deep/nested/c.ts)" -ne 0 ] && ok "BLOCK off-contract nested path" || bad "nested off-contract file passed"

echo "=== only fires while a refactor is genuinely in flight ==="
newrepo
[ "$(AI src/b.ts)" -eq 0 ] && ok "no contracts at all -> gate silent" || bad "blocked with no active refactor"
newrepo; complete_contract "src/a.ts"
[ "$(AI src/b.ts)" -eq 0 ] && ok "contract COMPLETE -> gate silent" || bad "completed refactor still binds"
newrepo; contract "src/a.ts"; touch -t 200001010000 zuvo/contracts/refactor-a.json
[ "$(AI src/b.ts)" -eq 0 ] && ok "stale/abandoned contract (past TTL) -> gate silent" || bad "abandoned run blocks forever"

echo "=== narrow by design: only source code blocks ==="
newrepo; contract "src/a.ts"
for f in README.md docs/guide.md package.json memory/backlog.md zuvo/notes.txt .gitignore; do
  [ "$(AI "$f")" -eq 0 ] && ok "non-source $f does not block" || bad "$f blocked (too broad)"
done
[ "$(AI node_modules/pkg/index.js)" -eq 0 ] && ok "node_modules ignored" || bad "node_modules blocked"
[ "$(AI dist/bundle.js)" -eq 0 ] && ok "dist ignored" || bad "dist blocked"

echo "=== adversarial CRITICAL: fence paths containing ] (Next.js dynamic routes) ==="
# `[^]]*` stops at the first `]` anywhere after the array opens — including one inside a
# filename. Measured on ["app/[id]/page.tsx","src/normal.ts"] the old sed returned NOTHING,
# so every fence entry vanished: gate silently dead, or (other entry order) real in-scope
# files read as off-fence and got FALSE-BLOCKED. Parser is quote-aware now.
newrepo
printf '{"stage":"PHASE-3","scope_fence":["app/[id]/page.tsx","src/normal.ts","app/[...slug]/x.ts"],"prove":{"blind_audit":"clean:strict","adversarial":"clean","characterization":"locked","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
[ "$(AI 'app/[id]/page.tsx')" -eq 0 ] && ok "bracketed fence path recognized as IN scope" || bad "bracketed path false-blocked"
[ "$(AI src/normal.ts)" -eq 0 ] && ok "entry AFTER a bracketed path still parsed" || bad "later fence entry lost to bracket"
[ "$(AI 'app/[...slug]/x.ts')" -eq 0 ] && ok "catch-all route path recognized" || bad "catch-all path false-blocked"
[ "$(AI src/elsewhere.ts)" -ne 0 ] && ok "off-fence file still blocked (fence not silently empty)" || bad "gate went dead — empty fence set"

echo "=== escapes preserved ==="
newrepo; contract "src/a.ts"
[ "$("${HUMAN[@]}" bash -c "$(declare -f trycommit); trycommit src/b.ts")" -eq 0 ] && ok "human committer bypass" || bad "human blocked"
newrepo; contract "src/a.ts"
[ "$(ZUVO_AI_RUN=1 ZUVO_ALLOW_ADHOC=1 bash -c "$(declare -f trycommit); trycommit src/b.ts")" -eq 0 ] && ok "ZUVO_ALLOW_ADHOC escape" || bad "allow-adhoc did not escape"

echo "=== fail-OPEN: a malformed contract must never brick a commit ==="
newrepo; printf 'not json at all\n' > zuvo/contracts/refactor-a.json
[ "$(AI src/b.ts)" -eq 0 ] && ok "unparseable contract -> fail-open" || bad "malformed contract BLOCKED (contract broken)"
newrepo; printf '{"stage":"PHASE-3","prove":{}}' > zuvo/contracts/refactor-a.json
[ "$(AI src/b.ts)" -eq 0 ] && ok "contract with no scope_fence -> fail-open" || bad "missing scope_fence BLOCKED"

echo "=== the two gates stay independent ==="
newrepo
printf '{"stage":"PHASE-3","scope_fence":["src/a.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-a.json
[ "$(AI src/a.ts)" -ne 0 ] && ok "prove-incomplete still blocks an IN-fence file (refactor_gate_check)" || bad "prove gate regressed"

echo "=== message names the offending files (so the fix is obvious) ==="
newrepo; contract "src/a.ts"
mkdir -p src; echo y >> src/zzz.ts; git add src/zzz.ts
msg=$(ZUVO_AI_RUN=1 git commit -m t 2>&1 || true); git reset -q >/dev/null 2>&1
printf '%s' "$msg" | grep -q 'src/zzz.ts' && ok "BLOCK message names the off-contract file" || bad "message does not name the file"
printf '%s' "$msg" | grep -q 'zuvo:refactor' && ok "BLOCK message names the remedy" || bad "message lacks the remedy"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
