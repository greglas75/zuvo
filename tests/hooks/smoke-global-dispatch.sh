#!/usr/bin/env bash
# SMOKE (plan Task 4): the INSTALLED ~/.claude/hooks dispatchers gate a freestyle-agent push
# in a QuotasMobi-like clone (NO local hooks), exempt a human, and honor a local hook.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
HD="$HOME/.claude/hooks"                       # object under test: the INSTALLED dispatchers
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

# Preflight: FULL chain present (a partial install — dispatchers without gates — must FAIL here,
# not silently pass) + INSTALLED copies match the tracked sources (stale-install detection).
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for f in pre-push pre-commit pre-push-gate.sh refactor-safety-gate.sh; do
  [ -x "$HD/$f" ] || { echo "PREFLIGHT FAIL: $HD/$f missing/not executable — run scripts/install.sh"; exit 1; }
done
for d in pre-push pre-commit; do
  cmp -s "$HD/$d" "$ROOT/hooks/git-dispatch/$d" || { echo "PREFLIGHT FAIL: installed $d differs from tracked source (stale install) — run scripts/install.sh"; exit 1; }
done

# QuotasMobi-like repo: substantial (>=3 prod files, >=150 lines) UNREVIEWED range, no local hooks
mkdir -p "$TMP/r"; cd "$TMP/r"
git init -q; git config user.email t@t; git config user.name t
echo base > seed.txt; git add seed.txt; git commit -q -m base
BASE=$(git rev-parse HEAD)
for f in a b c; do for i in $(seq 1 60); do echo "line $i of $f" >> "src_$f.ts"; done; done
git add src_a.ts src_b.ts src_c.ts; git commit -q -m "freestyle feature"
HEADSHA=$(git rev-parse HEAD)
REF="refs/heads/main $HEADSHA refs/heads/main $BASE"

echo "=== S1: agent env, substantial unreviewed push -> BLOCKED ==="
err=$(printf '%s\n' "$REF" | ZUVO_AI_RUN=1 ZUVO_AGENT=1 "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -qiE 'unreviewed|review'; } \
  && ok "S1 freestyle agent push BLOCKED (exit $rc)" || bad "S1 not gated (rc=$rc err=$(printf '%s' "$err" | head -2))"

echo "=== S2: human env (no AI markers) -> exempt, push passes ==="
rc=$(printf '%s\n' "$REF" | env -u ZUVO_AI_RUN -u ZUVO_AGENT -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CURSOR_TRACE_ID -u ANTIGRAVITY_SESSION_ID "$HD/pre-push" >/dev/null 2>&1; echo $?)
[ "$rc" -eq 0 ] && ok "S2 human push passes (exit 0)" || bad "S2 human blocked (rc=$rc)"

echo "=== S3: local type-check hook honored AND gates still run ==="
printf '#!/bin/sh\necho "TypeScript errors found. Push blocked." >&2\nexit 2\n' > .git/hooks/pre-push
chmod +x .git/hooks/pre-push
err=$(printf '%s\n' "$REF" | env -u ZUVO_AI_RUN -u ZUVO_AGENT -u CLAUDECODE -u CLAUDE_PLUGIN_ROOT -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CODE_SESSION -u CODEX_SANDBOX -u CURSOR_TRACE_ID -u ANTIGRAVITY_SESSION_ID "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -q 'TypeScript errors'; } \
  && ok "S3a failing local hook propagates for a human (exit $rc)" || bad "S3a (rc=$rc)"
printf '#!/bin/sh\nexit 0\n' > .git/hooks/pre-push
err=$(printf '%s\n' "$REF" | ZUVO_AI_RUN=1 ZUVO_AGENT=1 "$HD/pre-push" 2>&1); rc=$?
{ [ $rc -ne 0 ] && printf '%s' "$err" | grep -qiE 'unreviewed|review'; } \
  && ok "S3b passing local hook does NOT shadow the gate (agent still blocked, exit $rc)" || bad "S3b shadowed (rc=$rc)"

echo "=== S4: pre-commit dispatcher e2e (no hang + work-gate fires) ==="
mkdir -p zuvo/contracts
printf '{"stage":"PHASE-3","scope_fence":["src_a.ts"],"prove":{"blind_audit":"skipped","adversarial":"clean","findings_disposition":"none"}}' > zuvo/contracts/refactor-s.json
echo more >> src_a.ts; git add src_a.ts
err=$(ZUVO_AI_RUN=1 timeout 10 "$HD/pre-commit" 2>&1); rc=$?
{ [ $rc -ne 0 ] && [ $rc -ne 124 ] && printf '%s' "$err" | grep -q 'BLOCK:'; } \
  && ok "S4a agent prove-skip commit BLOCKED, no hang (exit $rc)" || bad "S4a (rc=$rc)"
rm -f zuvo/contracts/refactor-s.json
rc=$(ZUVO_AI_RUN=1 timeout 10 "$HD/pre-commit" >/dev/null 2>&1; echo $?)
{ [ "$rc" -eq 0 ]; } && ok "S4b no active work -> commit passes, no hang" || bad "S4b (rc=$rc)"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL SMOKE PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
