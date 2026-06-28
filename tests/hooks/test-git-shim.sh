#!/usr/bin/env bash
# Task 9 — PATH-shim git wrapper. Uses a stub "real git" (prints REAL_GIT_CALLED)
# and asserts: agent --no-verify/-n blocked; human + dry-runs pass through;
# real-git-not-found errors clearly; ZUVO_UNINSTALL_GIT_SHIM removes the shim.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIM="$ROOT/scripts/git-noverify-shim.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# stub real git
REALBIN="$TMP/realbin"; mkdir -p "$REALBIN"
cat > "$REALBIN/git" <<'EOF'
#!/usr/bin/env bash
echo "REAL_GIT_CALLED $*"
exit 0
EOF
chmod +x "$REALBIN/git"

BASH_BIN="$(command -v bash)"

# (1) agent commit --no-verify → block (exit 1), real git NOT called
out=$(PATH="$REALBIN:$PATH" ZUVO_AGENT=1 bash "$SHIM" commit -m x --no-verify 2>&1); rc=$?
if [ "$rc" -eq 1 ] && ! printf '%s' "$out" | grep -q REAL_GIT_CALLED; then
  pass "(1) agent commit --no-verify → BLOCKED (exit 1, real git not called)"
else
  bad "(1) expected block (rc=$rc, out=$out)"
fi

# (2) agent commit -n → block (exit 1)
out=$(PATH="$REALBIN:$PATH" ZUVO_AGENT=1 bash "$SHIM" commit -n 2>&1); rc=$?
[ "$rc" -eq 1 ] && pass "(2) agent commit -n → BLOCKED (exit 1)" || bad "(2) expected block (rc=$rc)"

# (3) human commit --no-verify → pass-through (real git called, exit 0)
out=$(env -i PATH="$REALBIN:$(dirname "$BASH_BIN"):/usr/bin:/bin" bash "$SHIM" commit -m x --no-verify 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'REAL_GIT_CALLED commit -m x --no-verify'; then
  pass "(3) human commit --no-verify → pass-through (G8)"
else
  bad "(3) human pass-through failed (rc=$rc, out=$out)"
fi

# (4) agent push -n (dry-run) → pass-through
out=$(PATH="$REALBIN:$PATH" ZUVO_AGENT=1 bash "$SHIM" push -n 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'REAL_GIT_CALLED push -n'; then
  pass "(4) agent push -n (dry-run) → pass-through"
else
  bad "(4) push -n should pass through (rc=$rc, out=$out)"
fi

# (5) agent status → pass-through
out=$(PATH="$REALBIN:$PATH" ZUVO_AGENT=1 bash "$SHIM" status 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'REAL_GIT_CALLED status'; then
  pass "(5) agent status → pass-through"
else
  bad "(5) status should pass through (rc=$rc)"
fi

# (6) real git not found → clear error, non-zero
mkdir -p "$TMP/nogit"; ln -s "$BASH_BIN" "$TMP/nogit/bash"
out=$(env -i PATH="$TMP/nogit" bash "$SHIM" status 2>&1); rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qi "not found"; then
  pass "(6) real git not found → clear error (exit $rc)"
else
  bad "(6) expected clear not-found error (rc=$rc, out=$out)"
fi

# (7) ZUVO_UNINSTALL_GIT_SHIM=1 → removes ~/bin/git
mkdir -p "$TMP/home/bin"; cp "$SHIM" "$TMP/home/bin/git"
out=$(env ZUVO_UNINSTALL_GIT_SHIM=1 HOME="$TMP/home" PATH="$REALBIN:$PATH" bash "$SHIM" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && [ ! -e "$TMP/home/bin/git" ]; then
  pass "(7) ZUVO_UNINSTALL_GIT_SHIM=1 → shim removed"
else
  bad "(7) uninstall failed (rc=$rc, exists=$([ -e "$TMP/home/bin/git" ] && echo yes || echo no))"
fi

# (8) shim self-skip: invoking via a PATH where the shim is the only 'git' but a
#     real git exists later → still finds real git (skips shim copies by marker)
cp "$SHIM" "$TMP/realbin2-shim-git" 2>/dev/null || true
mkdir -p "$TMP/shimbin"; cp "$SHIM" "$TMP/shimbin/git"
out=$(PATH="$TMP/shimbin:$REALBIN:$PATH" ZUVO_AGENT=1 bash "$SHIM" status 2>&1); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'REAL_GIT_CALLED status'; then
  pass "(8) skips other shim copies on PATH, finds real git"
else
  bad "(8) shim self-skip failed (rc=$rc, out=$out)"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
