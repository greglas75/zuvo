#!/usr/bin/env bash
# Task 5 dogfood guard: the live zuvo-plugin repo is activated, AND a clone is gated after setup.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

echo "=== live repo dogfood active ==="
hp=$(git -C "$ROOT" config --get core.hooksPath 2>/dev/null || true)
[ "$hp" = ".githooks" ] && ok "zuvo-plugin core.hooksPath=.githooks (its own pushes are gated)" || bad "live repo not activated (hp='$hp')"

echo "=== .githooks/pre-push chains BOTH the pipeline-entry gate and the work-gate ==="
grep -q 'hooks/pre-push-gate.sh' "$ROOT/.githooks/pre-push" && ok "wires pipeline-entry gate" || bad "missing pipeline-entry wiring"
grep -q 'hooks/refactor-safety-gate.sh' "$ROOT/.githooks/pre-push" && ok "wires work-gate" || bad "missing work-gate wiring"

echo "=== clone-simulation: a substantial unreviewed push is rejected ==="
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/c/.githooks" "$TMP/c/hooks"; cd "$TMP/c"
git init -q; git config user.email t@t; git config user.name t
cp "$ROOT/.githooks/pre-push" .githooks/; chmod +x .githooks/*
# stand-in pipeline-entry gate: a real one would block a substantial unreviewed range; assert the
# CHAIN propagates that block through the tracked .githooks/pre-push after setup activates it.
printf '#!/bin/sh\necho "zuvo pre-push: substantial unreviewed change — run zuvo:review" >&2\nexit 1\n' > hooks/pre-push-gate.sh
chmod +x hooks/pre-push-gate.sh
cp "$ROOT/scripts/setup-dev-hooks.sh" setup.sh; sh setup.sh >/dev/null
err=$(printf 'refs/heads/main aaaa refs/heads/main bbbb\n' | .githooks/pre-push 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qiE 'pipeline|review'; } \
  && ok "clone push blocked after setup (exit $rc, stderr token)" || bad "clone not gated (rc=$rc err=$err)"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
