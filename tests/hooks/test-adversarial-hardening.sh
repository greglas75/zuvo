#!/usr/bin/env bash
#
# test-adversarial-hardening.sh — defects in scripts/adversarial-review.sh (and its modules) found while it
# was split into modules (2026-10-04, zuvo:refactor): by the CQ audits taken before and after the split and
# by the split's cross-model review. One section per defect. Every section was RED on the code before its
# fix and GREEN after it; the refactor's red/green proof ran each one alone:
#   ADV_HARDENING_ONLY=<ID> bash tests/hooks/test-adversarial-hardening.sh     # one section
#   bash tests/hooks/test-adversarial-hardening.sh                              # all of them
# No real provider is called: lanes are test-harness mocks or fake clients first on PATH.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="${ZUVO_TEST_AR:-$ROOT/scripts/adversarial-review.sh}"
T="$(mktemp -d)" || { echo "  ✗ mktemp -d failed"; exit 1; }
trap 'rm -rf "$T"' EXIT

PASS=0; FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS + 1)); }
bad()  { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }
same() { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
has()  { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not in [$(printf '%s' "$3" | head -c 300)]" ;; esac; }
hasnt(){ case "$3" in *"$2"*) bad "$1 — [$2] found in [$(printf '%s' "$3" | head -c 300)]" ;; *) ok "$1" ;; esac; }
only() { [ -z "${ADV_HARDENING_ONLY:-}" ] || [ "$ADV_HARDENING_ONLY" = "$1" ]; }

[ -f "$AR" ] || { echo "  ✗ driver not found: $AR"; exit 1; }
BIN="$T/bin"; mkdir -p "$BIN" "$T/tmp"
REPO="$T/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@t && git config user.name t \
  && printf 'const a = 1;\n' > a.js && git add a.js && git commit -qm init ) >/dev/null 2>&1
DIFF='diff --git a/a.js b/a.js
--- a/a.js
+++ b/a.js
@@ -1 +1 @@
-const a = 1;
+const a = 2;
'
# mock <name> <body> — a test-harness lane on PATH: it reads the prompt from stdin, then runs <body>.
mock() { printf '#!/bin/sh\ncat > /dev/null\n%s\n' "$2" > "$BIN/$1"; chmod +x "$BIN/$1"; }
mock mock-ok 'printf "%s\n" "{\"findings\": []}"'
# drive <tag> [VAR=value...] -- <driver args...> — the driver in $REPO under the test harness, stdin =
# $DIFF unless STDIN_FILE is set; out/err in $T/<tag>.out/.err; prints the exit code. HOME, ZUVO_HOME and
# TMPDIR are the case's own, so nothing reaches the real ~/.zuvo.
drive() {
  local tag="$1" rc=0; shift
  local envs=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  [ $# -gt 0 ] && shift
  mkdir -p "$T/home-$tag/.zuvo"
  ( cd "$REPO" && env HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="${LANES:-mock-ok}" \
      ZUVO_RUN_ID="hardening-$tag-$$" ${envs[@]+"${envs[@]}"} \
      bash "$AR" "$@" < "${STDIN_FILE:-/dev/stdin}" ) > "$T/$tag.out" 2> "$T/$tag.err" <<< "$DIFF" || rc=$?
  echo "$rc"
}
out() { cat "$T/$1.out" 2>/dev/null; }
err() { cat "$T/$1.err" 2>/dev/null; }

if only M1; then
echo "=== M1 a module set from two installs is never loaded (the split's own loader) ==="
# The loader checked one directory, every file present, every required function defined — and a COMPLETE
# set whose files came from two releases passed all three: an install interrupted between two modules, or
# a review started while one was copying, ran code no single checkout ever held. install.sh now writes
# adversarial-modules.cksum beside every set it installs, last; the loader refuses a set that does not
# match it (after waiting briefly for an install still in progress) and moves on to the next candidate.
. "$ROOT/tests/lib/adversarial-driver.sh"
# shellcheck disable=SC2046  # module names, one word each: split on purpose
m1_sum() { ( cd "$1" && cat $(adv_driver_modules "$AR") ) | cksum; }
m1_copy() {   # <dir> <layout> — a driver copy with its modules (no stamp yet)
  rm -rf "$1"; adv_driver_copy "$AR" "$1/adversarial-review.sh" "$2" || bad "M1 premise: copying the driver into $1 failed"
}
m1_run() {    # <tag> <driver> [VAR=value...] — a dry run; prints the exit code
  local tag="$1" drv="$2" rc=0; shift 2
  mkdir -p "$T/home-$tag/.zuvo"
  ( cd "$REPO" && env HOME="$T/home-$tag" ZUVO_HOME="$T/home-$tag/.zuvo" TMPDIR="$T/tmp" PATH="$BIN:$PATH" \
      ZUVO_NO_CAFFEINATE=1 ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-ok "$@" \
      bash "$drv" --dry-run <<< "$DIFF" ) > "$T/$tag.out" 2> "$T/$tag.err" || rc=$?
  echo "$rc"
}
# A stamp that matches: the set runs.
m1_copy "$T/m1-ok" lib; m1_sum "$T/m1-ok/lib" > "$T/m1-ok/lib/adversarial-modules.cksum"
same "M1 a set that matches its stamp runs (dry run, exit 0)" "0" "$(m1_run m1-ok "$T/m1-ok/adversarial-review.sh")"
# A set changed after its stamp was written — an install that stopped half way — and nothing else to use.
m1_copy "$T/m1-mixed" lib; m1_sum "$T/m1-mixed/lib" > "$T/m1-mixed/lib/adversarial-modules.cksum"
printf '\n# a module from another release\n' >> "$T/m1-mixed/lib/$(adv_driver_modules "$AR" | tail -1)"
rc="$(m1_run m1-mixed "$T/m1-mixed/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=1)"
same "M1 a set that does not match its stamp is refused (exit 2)" "2" "$rc"
has "M1 …saying why" "does not match its install stamp" "$(err m1-mixed)"
# The same in lib/, with a complete flat set that matches its own stamp beside the driver: the flat set is
# used. The lib/ set is unloadable on purpose (a module that does not parse), so only skipping it passes.
m1_copy "$T/m1-fall" lib; m1_sum "$T/m1-fall/lib" > "$T/m1-fall/lib/adversarial-modules.cksum"
printf '\nif then\n' >> "$T/m1-fall/lib/$(adv_driver_modules "$AR" | tail -1)"
for m in $(adv_driver_modules "$AR"); do cp "$(adv_driver_module_dir "$AR")/$m" "$T/m1-fall/$m"; done
m1_sum "$T/m1-fall" > "$T/m1-fall/adversarial-modules.cksum"
same "M1 lib/ out of step with its stamp, a stamped flat set beside it: the flat set runs (exit 0)" "0" \
  "$(m1_run m1-fall "$T/m1-fall/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=1)"
# An install still copying: the stamp is rewritten a moment later, and the run waits for it.
m1_copy "$T/m1-wait" lib; printf '1 2\n' > "$T/m1-wait/lib/adversarial-modules.cksum"
( sleep 1; m1_sum "$T/m1-wait/lib" > "$T/m1-wait/lib/adversarial-modules.cksum.new" \
  && mv "$T/m1-wait/lib/adversarial-modules.cksum.new" "$T/m1-wait/lib/adversarial-modules.cksum" ) &
same "M1 a stamp that catches up within the wait: the set runs (exit 0)" "0" \
  "$(m1_run m1-wait "$T/m1-wait/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=5)"
wait
# An install that knew it failed says so in the stamp: refused at once, no wait.
m1_copy "$T/m1-inc" lib; printf 'install-incomplete\n' > "$T/m1-inc/lib/adversarial-modules.cksum"
m1_t0=$(date +%s)
rc="$(m1_run m1-inc "$T/m1-inc/adversarial-review.sh" ZUVO_ADV_MODULE_STAMP_WAIT=10)"
m1_el=$(( $(date +%s) - m1_t0 ))
same "M1 a set its install marked incomplete is refused (exit 2)" "2" "$rc"
[ "$m1_el" -lt 5 ] && ok "M1 …at once, without the wait (${m1_el}s)" || bad "M1 …after ${m1_el}s — it waited for a stamp that cannot change"
# No stamp at all — a git checkout, the plugin cache, a copy a test made: loaded as before.
m1_copy "$T/m1-none" lib
same "M1 a set with no stamp loads as before (exit 0)" "0" "$(m1_run m1-none "$T/m1-none/adversarial-review.sh")"
fi

echo "RESULT: PASS=$PASS FAIL=$FAIL"
echo "Tests: $PASS passed, $FAIL failed"   # the summary shape the refactor contract's red/green proof reads
[ "$FAIL" -eq 0 ]
