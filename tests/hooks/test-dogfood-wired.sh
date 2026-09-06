#!/usr/bin/env bash
# Medium integration test: setup activates the tracked hook in a fresh clone.
# A source-only farm mirror need not have the developer's unversioned git config.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

echo "=== .githooks/pre-push chains BOTH the pipeline-entry gate and the work-gate ==="
grep -q 'hooks/pre-push-gate.sh' "$ROOT/.githooks/pre-push" && ok "wires pipeline-entry gate" || bad "missing pipeline-entry wiring"
grep -q 'hooks/refactor-safety-gate.sh' "$ROOT/.githooks/pre-push" && ok "wires work-gate" || bad "missing work-gate wiring"

echo "=== clone-simulation: a substantial unreviewed push is rejected ==="
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES
unset GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_COUNT
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/c/.githooks" "$TMP/c/hooks"; cd "$TMP/c" || exit 1
git init -q || exit 1
git config user.email t@t; git config user.name t
git -c core.hooksPath=/dev/null commit --allow-empty -qm fixture || exit 1
git init --bare -q "$TMP/remote.git" || exit 1
cp "$ROOT/.githooks/pre-push" .githooks/; chmod +x .githooks/*
# stand-in pipeline-entry gate: a real one would block a substantial unreviewed range; assert the
# CHAIN propagates that block through the tracked .githooks/pre-push after setup activates it.
printf '#!/bin/sh\necho "zuvo pre-push: substantial unreviewed change — run zuvo:review" >&2\nexit 1\n' > hooks/pre-push-gate.sh
chmod +x hooks/pre-push-gate.sh
printf '#!/bin/sh\necho "work-gate invoked: $1" >&2\nexit 0\n' > hooks/refactor-safety-gate.sh
chmod +x hooks/refactor-safety-gate.sh
cp "$ROOT/scripts/setup-dev-hooks.sh" setup.sh
sh setup.sh >/dev/null || bad "first setup run failed"
hp=$(git config --local --get core.hooksPath 2>/dev/null || true)
[ "$hp" = ".githooks" ] && ok "setup activates clone-local core.hooksPath=.githooks" || bad "setup did not activate hooks (hp='$hp')"
again=$(sh setup.sh 2>&1); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git config --local --get core.hooksPath)" = ".githooks" ]; } \
  && ok "setup is idempotent" || bad "repeated setup changed configuration or failed: $again"
# Use git itself, not a direct hook invocation: a missing hooksPath must fail this test.
err=$(git push "$TMP/remote.git" HEAD:refs/heads/main 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qiE 'pipeline|review'; } \
  && ok "clone push blocked after setup (exit $rc, stderr token)" || bad "clone not gated (rc=$rc err=$err)"
grep -Fq 'work-gate invoked: pre-push' <<< "$err" \
  && ok "git push invokes the work-gate with pre-push mode" || bad "work-gate was not invoked: $err"
if git --git-dir="$TMP/remote.git" rev-parse --verify refs/heads/main >/dev/null 2>&1; then
  bad "blocked push created the remote branch"
else
  ok "blocked push leaves the remote unchanged"
fi

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
