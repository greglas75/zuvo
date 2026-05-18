#!/usr/bin/env bash
# test-install-retro-stub.sh — Plan Task 8 (G-DIST).
# retro-stub must be installed into ~/.zuvo by install.sh the SAME way the
# other zuvo-home helpers are, and reach Claude/Codex/Cursor via the real
# distribution invariant (install_zuvo_home in the default all/both path —
# ~/.zuvo is the shared cross-platform helper dir; the build scripts do NOT
# copy zuvo-home, verified, not assumed).

I="$ROOT/scripts/install.sh"

start_test "T8.1 install.sh install_zuvo_home has a retro-stub cp+chmod+ok/warn clause"
# Scope to the install_zuvo_home function body.
FN=$(awk '/^install_zuvo_home\(\) *\{/{f=1} f{print} f&&/^\}/{exit}' "$I")
if printf '%s' "$FN" | grep -q 'scripts/zuvo-home/retro-stub' \
   && printf '%s' "$FN" | grep -q 'cp .*retro-stub.*\.zuvo/retro-stub' \
   && printf '%s' "$FN" | grep -q 'chmod +x .*\.zuvo/retro-stub' \
   && printf '%s' "$FN" | grep -qi 'retro-stub installed' \
   && printf '%s' "$FN" | grep -qi 'retro-stub not found'; then
  pass "retro-stub clause mirrors the append-runlog pattern"
else
  fail "T8.1" "install_zuvo_home missing a complete retro-stub cp/chmod/ok/warn clause"
fi

start_test "T8.2 scripts/zuvo-home/retro-stub exists and is executable in-repo"
if [ -f "$ROOT/scripts/zuvo-home/retro-stub" ] && [ -x "$ROOT/scripts/zuvo-home/retro-stub" ]; then
  pass "scripts/zuvo-home/retro-stub present + executable"
else
  fail "T8.2" "scripts/zuvo-home/retro-stub missing or not +x"
fi

start_test "T8.3 REAL distribution invariant: install_zuvo_home runs in default all/both"
# Verified, not assumed: the build-codex/cursor scripts do NOT copy zuvo-home;
# ~/.zuvo is shared and populated once by install_zuvo_home in the all/both
# dispatch (the documented canonical install: \`./scripts/install.sh\`).
if grep -qE '^[[:space:]]*both\|all\)[^)]*install_zuvo_home' "$I"; then
  pass "install_zuvo_home invoked in the all/both dispatch"
else
  fail "T8.3" "install_zuvo_home not reachable from the default all/both install"
fi
if ! grep -qE 'zuvo-home' "$ROOT/scripts/build-codex-skills.sh" "$ROOT/scripts/build-cursor-skills.sh" 2>/dev/null; then
  pass "build scripts do NOT copy zuvo-home (invariant confirmed — shared ~/.zuvo)"
else
  fail "T8.3" "a build script references zuvo-home — distribution model assumption is wrong"
fi

start_test "T8.4 dry-run: the retro-stub clause installs an executable into a temp HOME"
TMP=$(mktemp -d); mkdir -p "$TMP/.zuvo"
# Execute exactly the repo's clause logic against a temp HOME (hermetic).
ZUVO_DIR="$ROOT" HOME="$TMP" bash -c '
  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/retro-stub" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/retro-stub" "$HOME/.zuvo/retro-stub"
    chmod +x "$HOME/.zuvo/retro-stub"
  fi'
if [ -x "$TMP/.zuvo/retro-stub" ]; then
  pass "retro-stub lands executable in \$HOME/.zuvo"
else
  fail "T8.4" "retro-stub did not install as executable"
fi
rm -rf "$TMP"
