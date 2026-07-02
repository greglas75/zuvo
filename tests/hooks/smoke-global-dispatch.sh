#!/usr/bin/env bash
# SMOKE (plan Task 4): the INSTALLED ~/.claude/hooks dispatchers gate a freestyle-agent push
# in a QuotasMobi-like clone (NO local hooks), exempt a human, and honor a local hook.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
HD="$HOME/.claude/hooks"                       # object under test: the INSTALLED dispatchers
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

[ -x "$HD/pre-push" ] && [ -x "$HD/pre-push-gate.sh" ] || { echo "installed dispatchers/gates missing — run scripts/install.sh"; exit 1; }

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

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL SMOKE PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
