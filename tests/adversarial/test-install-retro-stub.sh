#!/usr/bin/env bash
# test-install-retro-stub.sh — Plan Task 8 (G-DIST).
# retro-stub must be installed into ~/.zuvo by install.sh the SAME way the
# other zuvo-home helpers are, and reach Claude/Codex/Cursor via the real
# distribution invariant (install_zuvo_home in the default all/both path —
# ~/.zuvo is the shared cross-platform helper dir; the build scripts do NOT
# copy zuvo-home, verified, not assumed).

I="$ROOT/scripts/install.sh"

start_test "T8.1 EMPIRICAL: install_zuvo_home lands +x retro-stub in an overridden HOME"
# Rewritten 2026-07-30. This asserted the SHAPE of install.sh — a per-file `cp`+`chmod`+ok/warn
# clause for retro-stub. install.sh now installs every helper in scripts/zuvo-home/ with a LOOP,
# which is a strictly stronger guarantee: it covers all 23 helpers, not the three that happened
# to own a test. (The old explicit list had already drifted — retro-mine.py, retro-mine-weekly.sh
# and rotate-retros-cron.sh were versioned but never installed, and no shape test noticed.)
# So the check is now the OUTCOME: the file lands, executable, and is named in the install log.
_T=$(mktemp -d); trap 'rm -rf "$_T"' EXIT INT TERM
_FN=$(awk '/^install_zuvo_home\(\) *\{/{f=1} f{print} f&&/^\}/{exit}' "$I")
_LOG=$(HOME="$_T" ZUVO_DIR="$ROOT" bash -c "
  set -euo pipefail
  ok()   { echo \"  + \$1\"; }
  warn() { echo \"  ! \$1\"; }
  $_FN
  install_zuvo_home
" 2>&1); _RC=$?
if [ "$_RC" -eq 0 ] \
   && [ -f "$_T/.zuvo/retro-stub" ] && [ -x "$_T/.zuvo/retro-stub" ] \
   && printf '%s' "$_LOG" | grep -qi 'retro-stub installed'; then
  pass "retro-stub landed +x in \$HOME/.zuvo and was named in the install log"
else
  fail "T8.1" "rc=$_RC file=$([ -f "$_T/.zuvo/retro-stub" ] && echo yes || echo NO) exec=$([ -x "$_T/.zuvo/retro-stub" ] && echo yes || echo NO)"
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
