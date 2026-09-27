#!/usr/bin/env bash
#
# test-smoke-reviewer-subprocess.sh — the aggregation logic of tests/hooks/smoke-reviewer-subprocess.sh
# on SYNTHETIC inputs. A real smoke run always finds every chained file and every chained suite green,
# so its two defensive branches — link()'s "required file missing → FAIL, link not run" and suite()'s
# "exited 0 but no proof of work" — and the "nothing executed" verdict never run there. This file
# sources the harness (sourcing defines it and runs no link) and drives each branch directly:
#   * sourcing runs no link and prints nothing; a DIRECT run still runs the links and the verdict;
#   * link(): a missing required file (listed after a present one) → FAILED+1, the verdict function
#     never runs, EXECUTED unchanged; a present file → the verdict runs and PASS/FAIL follow its rc;
#     a failed link does not stop or corrupt a later one;
#   * suite(): exit 0 with no PASS line → 3; exit 0 with a FAIL line → 3; a real pass → 0; a non-zero
#     exit → that exit code; its temp file sits in TMPDIR while the suite runs and is removed every time;
#   * smoke_verdict: EXECUTED=0 → exit 1 (even with FAILED=0), any failure → exit 1, else exit 0.
#
# Hermetic: temp dir per run, fake suites written there, TMPDIR pointed into it. No chained suite runs.
# ZUVO_TEST_SMOKE points the file at ANOTHER copy of the harness (a deliberately broken one, to show
# each case is red there); default: the working tree's.
#
# Run (bash 3.2 and 5.x):
#   TF_ALLOW_LOCAL=1 bash tests/hooks/test-smoke-reviewer-subprocess.sh
#   TF_ALLOW_LOCAL=1 /bin/bash tests/hooks/test-smoke-reviewer-subprocess.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd -P)"
SMOKE="${ZUVO_TEST_SMOKE:-$ROOT/tests/hooks/smoke-reviewer-subprocess.sh}"
T_PASS=0; T_FAIL=0
ok()  { echo "  PASS $1"; T_PASS=$((T_PASS+1)); }
bad() { echo "  FAIL $1"; T_FAIL=$((T_FAIL+1)); }
expect_eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
expect_has() { if grep -qF -- "$2" "$3"; then ok "$1"; else bad "$1 — [$2] not in: $(tr '\n' ' ' < "$3")"; fi; }
expect_not() { if grep -qF -- "$2" "$3"; then bad "$1 — [$2] found in: $(tr '\n' ' ' < "$3")"; else ok "$1"; fi; }

echo "== smoke-reviewer-subprocess.sh aggregation logic (test bash $BASH_VERSION) =="
[ -f "$SMOKE" ] || { echo "  FAIL harness not found: $SMOKE"; exit 1; }

T="$(mktemp -d)" || { echo "  FAIL mktemp -d failed" >&2; exit 1; }
[ -n "$T" ] && [ -d "$T" ] || { echo "  FAIL mktemp -d returned an empty path or no directory" >&2; exit 1; }
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/tmp" "$T/suites"

# ── 1. sourcing defines the harness and runs NO link ────────────────────────────────────────────
( . "$SMOKE"; echo "COUNTERS=$EXECUTED/$PASSED/$FAILED" ) > "$T/source.out" 2>&1
expect_has "sourcing leaves every counter at zero (and returns to the caller)" "COUNTERS=0/0/0" "$T/source.out"
expect_not "sourcing runs no link" "=== SMOKE-" "$T/source.out"
expect_not "sourcing prints no verdict" "RESULT:" "$T/source.out"

# Into THIS shell from here on: link/suite/smoke_verdict and the counters. stdout and stderr of the
# source itself go to a file (it must stay silent — checked above).
# shellcheck source=tests/hooks/smoke-reviewer-subprocess.sh
. "$SMOKE" > "$T/source-main.out" 2>&1
for _fn in link suite smoke_verdict; do
  if declare -F "$_fn" >/dev/null; then ok "sourcing defines $_fn()"; else bad "sourcing does not define $_fn()"; fi
done

# ── 2. link() ────────────────────────────────────────────────────────────────────────────────────
PRESENT="tests/hooks/smoke-reviewer-subprocess.sh"   # relative to the harness's own ROOT, like its links
MISSING="tests/hooks/no-such-link-file-$$.sh"
reset_counts() { EXECUTED=0; PASSED=0; FAILED=0; rm -f "$T/verdict.ran"; }
verdict_pass() { echo x >> "$T/verdict.ran"; return 0; }
verdict_fail() { echo x >> "$T/verdict.ran"; return 5; }
ran_count() { if [ -f "$T/verdict.ran" ]; then wc -l < "$T/verdict.ran" | tr -d ' '; else echo 0; fi; }

echo "-- 2a. a missing required file (listed AFTER a present one)"
reset_counts
link "T-MISSING" "synthetic missing file" verdict_pass "$PRESENT" "$MISSING" > "$T/l-missing.out"
expect_eq "missing file: link() returns 0 (the smoke keeps going)" "0" "$?"
expect_eq "missing file: FAILED is incremented" "1" "$FAILED"
expect_eq "missing file: the link does not count as executed" "0" "$EXECUTED"
expect_eq "missing file: PASSED is untouched" "0" "$PASSED"
expect_eq "missing file: the verdict function never ran" "0" "$(ran_count)"
expect_has "missing file: the failure names the file and says the link was not run" \
  "FAIL T-MISSING: required file $MISSING is missing — link not run" "$T/l-missing.out"
expect_not "missing file: no PASS line for the link" "PASS T-MISSING" "$T/l-missing.out"

echo "-- 2b. every file present, verdict passes"
reset_counts
link "T-OK" "synthetic passing link" verdict_pass "$PRESENT" > "$T/l-ok.out"
expect_eq "passing link: EXECUTED=1" "1" "$EXECUTED"
expect_eq "passing link: PASSED=1" "1" "$PASSED"
expect_eq "passing link: FAILED=0" "0" "$FAILED"
expect_eq "passing link: the verdict function ran once" "1" "$(ran_count)"
expect_has "passing link: reported as passed" "PASS T-OK (exit 0)" "$T/l-ok.out"

echo "-- 2c. every file present, verdict fails with 5"
reset_counts
link "T-BAD" "synthetic failing link" verdict_fail "$PRESENT" > "$T/l-bad.out"
expect_eq "failing link: EXECUTED=1" "1" "$EXECUTED"
expect_eq "failing link: FAILED=1" "1" "$FAILED"
expect_eq "failing link: PASSED=0" "0" "$PASSED"
expect_has "failing link: reported with the verdict's exit code" "FAIL T-BAD (exit 5)" "$T/l-bad.out"

echo "-- 2d. missing, failing, passing in one run: a failure does not stop or corrupt a later link"
reset_counts
{ link "T-1" "missing" verdict_pass "$MISSING"
  link "T-2" "fails" verdict_fail "$PRESENT"
  link "T-3" "passes" verdict_pass "$PRESENT"; } > "$T/l-seq.out"
expect_eq "sequence: EXECUTED counts only the two links that ran" "2" "$EXECUTED"
expect_eq "sequence: FAILED counts the missing and the failing link" "2" "$FAILED"
expect_eq "sequence: PASSED counts the last link" "1" "$PASSED"
expect_eq "sequence: verdict functions ran for T-2 and T-3 only" "2" "$(ran_count)"
expect_has "sequence: the link after two failures still passed" "PASS T-3 (exit 0)" "$T/l-seq.out"

# ── 3. suite() ───────────────────────────────────────────────────────────────────────────────────
printf 'echo "all good, nothing counted"\nexit 0\n' > "$T/suites/no-pass.sh"
printf 'echo "  PASS one"\necho "  FAIL two"\nexit 0\n' > "$T/suites/has-fail.sh"
printf 'echo "  PASS one"\necho "PASS: two"\nexit 0\n' > "$T/suites/good.sh"
printf 'echo "  PASS one"\nexit 7\n' > "$T/suites/nonzero.sh"
# A suite that lists TMPDIR WHILE it runs: the capture file suite() writes its output to must be there.
printf 'echo "  PASS one"\necho "TMPDIR-NOW: $(ls -A "$TMPDIR" | tr "\\n" " ")"\nexit 0\n' > "$T/suites/tmp-probe.sh"
export TMPDIR="$T/tmp"   # suite() creates its capture file under $TMPDIR — it must remove it again
# suite_case <label> <suite> <want rc> — runs suite(), leaves its output in $T/suite-<suite>.out. "The
# capture file is removed" needs TMPDIR to still BE a directory: `ls` of a TMPDIR that a cleanup deleted
# whole prints nothing either.
suite_case() {
  local rc=0
  suite "$T/suites/$2" > "$T/suite-$2.out" || rc=$?
  expect_eq "$1: suite() returns $3" "$3" "$rc"
  if [ -d "$T/tmp" ]; then expect_eq "$1: the capture file is removed" "" "$(ls -A "$T/tmp")"
  else bad "$1: TMPDIR itself was removed — the capture-file check has nothing to look at"; fi
}
echo "-- 3. suite()"
suite_case "exit 0 without a single PASS line" no-pass.sh 3
expect_has "no PASS line: reported as no proof of work" "reported PASS=0 FAIL=0 — no proof of work" "$T/suite-no-pass.sh.out"
suite_case "exit 0 with a FAIL line" has-fail.sh 3
expect_has "FAIL line: reported as no proof of work" "reported PASS=1 FAIL=1 — no proof of work" "$T/suite-has-fail.sh.out"
suite_case "exit 0, PASS lines, no FAIL" good.sh 0
expect_has "good suite: its own output is passed through" "PASS: two" "$T/suite-good.sh.out"
expect_not "good suite: no proof-of-work complaint" "no proof of work" "$T/suite-good.sh.out"
suite_case "non-zero exit" nonzero.sh 7
expect_not "non-zero exit: returned as is, not as a proof-of-work failure" "no proof of work" "$T/suite-nonzero.sh.out"
# The removal checks above are only worth something if the capture file was IN $TMPDIR: one written
# anywhere else (a hard-coded /tmp) and never deleted would leave $TMPDIR empty as well.
suite_case "a suite listing TMPDIR while it runs" tmp-probe.sh 0
expect_has "while a suite runs, its capture file (smoke-suite.*) is in TMPDIR" "TMPDIR-NOW: smoke-suite." "$T/suite-tmp-probe.sh.out"

# ── 4. smoke_verdict (exits — always in a subshell) ─────────────────────────────────────────────
echo "-- 4. smoke_verdict"
# verdict_case <label> <EXECUTED> <PASSED> <FAILED> <want exit> <want line>
verdict_case() {
  local rc=0
  ( EXECUTED="$2"; PASSED="$3"; FAILED="$4"; smoke_verdict ) > "$T/verdict.out" 2>&1 || rc=$?
  expect_eq "$1: exits $5" "$5" "$rc"
  expect_has "$1: prints '$6'" "$6" "$T/verdict.out"
}
verdict_case "nothing executed, nothing failed" 0 0 0 1 "SMOKE FAIL: no check executed"
verdict_case "nothing executed, links missing" 0 0 4 1 "SMOKE FAIL: no check executed"
verdict_case "one of two links failed" 2 1 1 1 "SMOKE FAIL"
expect_not "one of two links failed: never reads as a pass" "SMOKE PASS" "$T/verdict.out"
verdict_case "every link passed" 2 2 0 0 "SMOKE PASS"

# ── 5. a DIRECT run still runs the links and the verdict ─────────────────────────────────────────
# The harness copied into an empty tree: every link's files are missing there, so a direct run must
# print all four links as failed and exit 1 — "no check executed" — without running any chained suite.
echo "-- 5. direct execution"
mkdir -p "$T/empty-root/tests/hooks"
cp "$SMOKE" "$T/empty-root/tests/hooks/smoke-reviewer-subprocess.sh"
rc=0
# "$BASH", the shell running THIS file: under `/bin/bash tests/hooks/…` the direct-run path (the
# _SMOKE_MAIN guard, `exec 2>&1`) is then exercised by bash 3.2 too, not by whatever `bash` is first on PATH.
"$BASH" "$T/empty-root/tests/hooks/smoke-reviewer-subprocess.sh" > "$T/direct.out" 2>&1 || rc=$?
expect_eq "direct run with every link file missing: exits 1" "1" "$rc"
for _id in SMOKE-A1 SMOKE-A2 SMOKE-A3a SMOKE-A3b; do
  expect_has "direct run: link $_id runs (and fails on its missing files)" "FAIL $_id: required file" "$T/direct.out"
done
expect_has "direct run: the verdict counts four failed, none executed" "RESULT: EXECUTED=0 PASS=0 FAIL=4" "$T/direct.out"
expect_has "direct run: the verdict says nothing executed" "SMOKE FAIL: no check executed" "$T/direct.out"

echo "=== RESULT ==="
echo "  $T_PASS passed, $T_FAIL failed"
[ "$T_FAIL" -eq 0 ] || exit 1
