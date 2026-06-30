#!/usr/bin/env bash
# Tests scripts/setup-dev-hooks.sh + the tracked .githooks/ wiring. Exact exit codes + tokens.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SETUP="$ROOT/scripts/setup-dev-hooks.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/.githooks" "$TMP/r/hooks"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  cp "$ROOT/.githooks/pre-push" "$ROOT/.githooks/pre-commit" .githooks/; chmod +x .githooks/*; }

echo "=== setup-dev-hooks: activation ==="
# 1 sets core.hooksPath=.githooks, exit 0
newrepo
out=$(sh "$SETUP"); rc=$?
{ [ "$rc" -eq 0 ] && [ "$(git config --get core.hooksPath)" = ".githooks" ]; } \
  && ok "core.hooksPath=.githooks set (exit 0)" || bad "activation (rc=$rc hp=$(git config --get core.hooksPath))"
echo "$out" | grep -q "now gated" && ok "stdout token 'now gated'" || bad "no activation token"

# 2 idempotent
out=$(sh "$SETUP"); rc=$?
{ [ "$rc" -eq 0 ] && echo "$out" | grep -qi "idempotent"; } && ok "idempotent (exit 0, 'idempotent')" || bad "idempotent"

echo "=== .githooks/pre-push chains the pipeline gate (block propagates) ==="
# stub pipeline-entry gate that blocks
printf '#!/bin/sh\necho "pipeline: substantial unreviewed change" >&2\nexit 1\n' > hooks/pre-push-gate.sh
chmod +x hooks/pre-push-gate.sh
err=$(printf 'refs/heads/main aaaa refs/heads/main bbbb\n' | .githooks/pre-push 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qi pipeline; } \
  && ok "pre-push blocks + stderr 'pipeline' (exit $rc)" || bad "pre-push chain (rc=$rc err=$err)"

echo "=== fail-OPEN when the gate script is absent ==="
rm -f hooks/pre-push-gate.sh hooks/refactor-safety-gate.sh
printf 'refs/heads/main aaaa refs/heads/main bbbb\n' | .githooks/pre-push >/dev/null 2>&1
[ $? -eq 0 ] && ok "fail-open (no gate -> exit 0, never bricks push)" || bad "fail-open"

echo "=== empty pre-push stdin -> no synthetic ref, exit 0 ==="
printf '#!/bin/sh\nwhile read -r a b c d; do [ -n "$b" ] || { echo "blank-ref" >&2; exit 7; }; done\nexit 0\n' > hooks/pre-push-gate.sh
chmod +x hooks/pre-push-gate.sh
printf '' | .githooks/pre-push >/dev/null 2>&1
[ $? -eq 0 ] && ok "empty stdin -> exit 0 (no blank-ref synthesised)" || bad "empty stdin synthesised a blank ref"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
