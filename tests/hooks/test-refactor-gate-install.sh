#!/usr/bin/env bash
# Tests scripts/install-refactor-gate.sh: idempotent, absolute-path, fail-open,
# never clobbers user hooks, never mutates a tracked hooksPath.
# HERMETIC: neutralises global/system git config so the host's core.hooksPath
# (zuvo's global ~/.claude/hooks) does not leak into the scenarios.
set -u
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/scripts/install-refactor-gate.sh"
GATE="$ROOT/hooks/refactor-safety-gate.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r"; cd "$TMP/r"; git init -q; git config user.email t@t; git config user.name t; }

echo "=== refactor-gate self-install (hermetic) ==="

# 1 fresh repo -> installs both hooks, absolute gate path baked
newrepo; sh "$INSTALL" "$GATE" "$TMP/r" >/dev/null
{ [ -f .git/hooks/pre-commit ] && [ -f .git/hooks/pre-push ]; } && ok "installed pre-commit + pre-push" || bad "install (pre-commit=$([ -f .git/hooks/pre-commit ]&&echo y||echo n) pre-push=$([ -f .git/hooks/pre-push ]&&echo y||echo n))"
grep -q "$GATE" .git/hooks/pre-commit 2>/dev/null && ok "absolute gate path baked" || bad "absolute path"

# 2 idempotent (no duplicate marker block)
sh "$INSTALL" "$GATE" "$TMP/r" >/dev/null
[ "$(grep -c 'zuvo:refactor-gate' .git/hooks/pre-commit 2>/dev/null || echo 9)" -le 2 ] && ok "idempotent (no duplicate)" || bad "idempotent"

# 3 foreign existing hook -> NOT clobbered; pre-push still installed
newrepo; printf '#!/bin/sh\necho mine\nexit 0\n' > .git/hooks/pre-commit; chmod +x .git/hooks/pre-commit
before="$(cat .git/hooks/pre-commit)"
sh "$INSTALL" "$GATE" "$TMP/r" >/dev/null
[ "$(cat .git/hooks/pre-commit)" = "$before" ] && ok "foreign pre-commit preserved" || bad "foreign hook clobbered"
[ -f .git/hooks/pre-push ] && grep -q "$GATE" .git/hooks/pre-push && ok "pre-push installed alongside foreign pre-commit" || bad "pre-push install"

# 4 tracked hooksPath (Husky-style) -> NOT mutated, instruction printed
newrepo; mkdir -p .husky; printf '#!/bin/sh\nexit 0\n' > .husky/pre-commit
git add .husky/pre-commit >/dev/null 2>&1; git commit -q -m husky >/dev/null 2>&1
git config core.hooksPath .husky
hbefore="$(cat .husky/pre-commit)"
out="$(sh "$INSTALL" "$GATE" "$TMP/r")"
[ "$(cat .husky/pre-commit)" = "$hbefore" ] && ok "tracked .husky NOT mutated" || bad "tracked hooksPath mutated (infra leak!)"
echo "$out" | grep -qi "version-controlled" && ok "manual-install instruction printed" || bad "no instruction for tracked hooksPath"

# 5 fail-open: empty gate path -> graceful exit 0
newrepo
sh "$INSTALL" "" "$TMP/r" >/dev/null 2>&1 && ok "empty gate path -> graceful exit 0" || bad "empty path crashed"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
