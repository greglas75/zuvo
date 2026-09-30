# shellcheck shell=bash
# tests/lib/assert.sh — the assertion helpers the routing suites share (test-model-run.sh,
# test-reviewer-preflight-isolation.sh, test-reviewer-route-cross-vendor.sh). Sourced, never run; never
# named test-*.sh (tests/run-all.sh globs those). Each suite used to carry its own copy of these.
#
# Counters: PASS / FAIL, started at 0 when this file is sourced. Output: one "  PASS <label>" or
# "  FAIL <label> — <why>" line per assertion; assert_result prints the trailer every suite ends with
# and returns 0 only when nothing failed. bash 3.2 compatible; no external command at source time.

PASS=0; FAIL=0
ok()  { echo "  PASS $1"; PASS=$((PASS+1)); }
bad() { echo "  FAIL $1"; FAIL=$((FAIL+1)); }
# die <why> — a setup step failed: the run cannot prove anything, so it stops here and counts as a failure.
die() { echo "  FAIL setup: $1" >&2; echo "RESULT: PASS=$PASS FAIL=$((FAIL+1)) (setup aborted)"; exit 1; }
expect_eq()      { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
expect_has()     { case "$3" in *"$2"*) ok "$1" ;; *) bad "$1 — [$2] not found in [$3]" ;; esac; }
expect_not_has() { case "$3" in *"$2"*) bad "$1 — [$2] found in [$3]" ;; *) ok "$1" ;; esac; }
# re_lit <text> — <text> as an ERE that matches exactly itself (temp paths hold `.`, "any character" to
# pgrep -f, so a raw path could match — and pkill kill — a process whose command line merely looks like it).
re_lit() { printf '%s' "$1" | sed 's/[][\.*^$(){}+?|]/\\&/g'; }
# kv_field <key> <text> — the value of the FIRST `<key>=` line of <text> (a six-key route block, say).
kv_field() { printf '%s\n' "$2" | awk -v k="$1" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }'; }
# phys <path> — <path> made physical (pwd -P) while it exists, else as given.
phys() { (cd "$1" 2>/dev/null && pwd -P) || printf '%s' "$1"; }
# assert_result — the trailer; status 0 only when no assertion failed.
assert_result() {
  echo "=== RESULT ==="
  echo "RESULT: PASS=$PASS FAIL=$FAIL"
  [ "$FAIL" -eq 0 ]
}
