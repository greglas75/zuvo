#!/usr/bin/env bash
# test-install-verify-plan-dag.sh — Plan v1.3.110 T2 RED.
# install_zuvo_home() must install scripts/zuvo-home/verify-plan-dag the same
# way the other zuvo-home helpers are (cp + chmod +x + ok/warn clause), and
# reach Claude/Codex/Cursor via the real distribution invariant (the shared
# ~/.zuvo dir; the build scripts deliberately do NOT copy zuvo-home).

I="$ROOT/scripts/install.sh"

# ── T2.1 structural: clause present in install_zuvo_home() body ────────────
start_test "T2.1 install_zuvo_home has a verify-plan-dag cp+chmod+ok/warn clause"
FN=$(awk '/^install_zuvo_home\(\) *\{/{f=1} f{print} f&&/^\}/{exit}' "$I")
if printf '%s' "$FN" | grep -q 'scripts/zuvo-home/verify-plan-dag' \
   && printf '%s' "$FN" | grep -q 'cp .*verify-plan-dag.*\.zuvo/verify-plan-dag' \
   && printf '%s' "$FN" | grep -q 'chmod +x .*\.zuvo/verify-plan-dag' \
   && printf '%s' "$FN" | grep -qi 'verify-plan-dag installed' \
   && printf '%s' "$FN" | grep -qi 'verify-plan-dag not found'; then
  pass "verify-plan-dag clause mirrors the retro-stub pattern"
else
  fail "T2.1" "install_zuvo_home missing a complete verify-plan-dag cp/chmod/ok/warn clause"
fi

# ── T2.2 in-repo binary is present + +x (T1 already shipped it) ────────────
start_test "T2.2 scripts/zuvo-home/verify-plan-dag exists and is executable in-repo"
if [ -f "$ROOT/scripts/zuvo-home/verify-plan-dag" ] && [ -x "$ROOT/scripts/zuvo-home/verify-plan-dag" ]; then
  pass "scripts/zuvo-home/verify-plan-dag present + executable"
else
  fail "T2.2" "scripts/zuvo-home/verify-plan-dag missing or not +x"
fi

# ── T2.3 distribution invariant: install_zuvo_home is in default both|all ──
start_test "T2.3 install_zuvo_home runs in default all/both dispatch"
if grep -qE '^[[:space:]]*both\|all\)[^)]*install_zuvo_home' "$I"; then
  pass "install_zuvo_home invoked in the all/both dispatch"
else
  fail "T2.3" "install_zuvo_home not reachable from the default all/both install"
fi
# Gate on existence first — `! grep` would silently PASS on read-error
# (grep exit 2 != 1; negation makes either look like "absent").
BCX="$ROOT/scripts/build-codex-skills.sh"
BCU="$ROOT/scripts/build-cursor-skills.sh"
if [ ! -f "$BCX" ] || [ ! -f "$BCU" ]; then
  fail "T2.3" "expected both build scripts present; got BCX=$([ -f "$BCX" ] && echo yes || echo NO) BCU=$([ -f "$BCU" ] && echo yes || echo NO)"
elif grep -qE 'verify-plan-dag' "$BCX" "$BCU"; then
  fail "T2.3" "a build script references verify-plan-dag — distribution model assumption is wrong"
else
  pass "build scripts do NOT reference verify-plan-dag (invariant confirmed — shared ~/.zuvo)"
fi

# ── T2.4 EMPIRICAL dry-run (iter3 CRITICAL: NOT grep-only theater) ────────
# Discovery during T2 execution: the spec's "run full install.sh all under
# overridden HOME" approach fails because install_claude requires an existing
# Claude plugin-cache dir (a fresh HOME has none → install_claude returns 1
# → `set -e` halts the script before install_zuvo_home runs). Per
# proper-solutions-only: extract install_zuvo_home AND define ok()/warn() in
# the subshell (this addresses iter4's CRITICAL — helpers UNDEFINED — by
# defining them, not by accepting verification theater).
start_test "T2.4 EMPIRICAL: install_zuvo_home (extracted) lands +x verify-plan-dag in overridden HOME"
TMP=$(mktemp -d)
# Cleanup even on early exit. set -e in parent runner or fail() short-circuit
# would otherwise leak TMP across runs.
trap 'rm -rf "$TMP"' EXIT INT TERM
FN_TEXT=$(awk '/^install_zuvo_home\(\) *\{/{f=1} f{print} f&&/^\}/{exit}' "$I")
LOG=$(HOME="$TMP" ZUVO_DIR="$ROOT" bash -c "
  set -euo pipefail
  GREEN=''; YELLOW=''; RED=''; NC=''
  ok()   { echo \"  + \$1\"; }
  warn() { echo \"  ! \$1\"; }
  fail() { echo \"  X \$1\"; }
  $FN_TEXT
  install_zuvo_home
" 2>&1)
RC=$?
# [-f] guard rejects directory-with-+x-traversal-bit edge case.
if [ "$RC" -eq 0 ] \
   && [ -f "$TMP/.zuvo/verify-plan-dag" ] \
   && [ -x "$TMP/.zuvo/verify-plan-dag" ] \
   && printf '%s' "$LOG" | grep -q 'verify-plan-dag installed'; then
  pass "verify-plan-dag landed +x file in \$HOME/.zuvo and 'verify-plan-dag installed' emitted"
else
  fail "T2.4" "RC=$RC; -f: $([ -f "$TMP/.zuvo/verify-plan-dag" ] && echo yes || echo NO); -x: $([ -x "$TMP/.zuvo/verify-plan-dag" ] && echo yes || echo NO); log: $(printf '%s' "$LOG" | tail -5 | tr '\n' '|')"
fi
rm -rf "$TMP"
trap - EXIT INT TERM
