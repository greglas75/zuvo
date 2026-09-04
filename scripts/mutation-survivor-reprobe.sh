#!/usr/bin/env bash
#
# mutation-survivor-reprobe.sh — physically apply ONE mutant, run the tests, restore, report.
#
# Why this exists: the retro log's single largest recorded burn (140 turns, one session) is
# "physical-ablation harness for stryker survivors", and the same need shows up under
# `Stryker static module re-probe`, `native survivor reprobe harness`, `exact mutant re-probe`,
# `static-mutant normalization`, `survivor equivalence ledger`. They are all one question:
#
#     "Stryker says this mutant SURVIVED. Is that a real test gap, or an artifact of the run?"
#
# A native runner's survivor list is NOT that answer. Under `coverageAnalysis: perTest`, a
# module-level ("static") mutant is reported SURVIVED because per-test coverage cannot attribute
# code that executed at import time — the tests may kill it perfectly well. Reasoning about that
# from the report is how sessions disappear; applying the mutation and running the suite settles
# it in one command.
#
# The script is deliberately narrow: one mutant, one file, content-anchored, always restored.
#
# Usage:
#   mutation-survivor-reprobe.sh --file <path> --original <text> --mutated <text> --test-cmd <cmd>
#   mutation-survivor-reprobe.sh --file <path> --original-file <p> --mutated-file <p> --test-cmd <cmd>
#
# Options:
#   --file <path>          the production file to mutate
#   --original <text>      the EXACT current text to replace — must occur exactly once
#   --mutated <text>       what to put in its place
#   --original-file <p>    read --original from a file (for multi-line / quote-heavy snippets)
#   --mutated-file <p>     read --mutated from a file
#   --test-cmd <cmd>       command that runs the RELEVANT tests (run via `bash -c`)
#   --timeout <seconds>    kill the test command after N seconds (default 600)
#   --label <id>           mutant id echoed back in the output (default: -)
#
# Output — KEY=VALUE lines:
#   label=<id>
#   file=<path>
#   verdict=KILLED|SURVIVED|ERROR
#   test_exit=<code>|-
#   restored=yes|no
#   sha_before=<sha256>
#   sha_after=<sha256>
#   reason=<one line>
#
# Exit codes:
#   0  KILLED    — tests failed with the mutant applied: the mutant is covered, not a gap
#   1  SURVIVED  — tests passed with the mutant applied: a REAL gap, confirmed by execution
#   2  usage error
#   3  ERROR     — could not run the probe (dirty file, ambiguous anchor, timeout, restore failure)
#
# SURVIVED here is worth more than a report line: it was produced by running the code.
set -uo pipefail

FILE=""
ORIGINAL=""
MUTATED=""
HAVE_ORIGINAL=0
HAVE_MUTATED=0
TEST_CMD=""
TIMEOUT_SECONDS=600
LABEL="-"
BACKUP=""

die() { echo "$1" >&2; exit "${2:-2}"; }

emit() {
  # emit <verdict> <test_exit> <restored> <reason>
  printf 'label=%s\n' "$LABEL"
  printf 'file=%s\n' "$FILE"
  printf 'verdict=%s\n' "$1"
  printf 'test_exit=%s\n' "$2"
  printf 'restored=%s\n' "$3"
  printf 'sha_before=%s\n' "${SHA_BEFORE:--}"
  printf 'sha_after=%s\n' "${SHA_AFTER:--}"
  printf 'reason=%s\n' "$4"
}

sha_of() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
  elif command -v shasum   >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
  else echo "-"; fi
}

# Restore on EVERY exit path — normal, error, and signal. This is the shape that leaves a mutated
# production file behind when a run is interrupted: the probe writes real source, and an
# un-restored mutant is indistinguishable from a bug the next reader has to chase.
restore() {
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || return 0
  cp -p "$BACKUP" "$FILE" 2>/dev/null
  rm -f "$BACKUP"
  BACKUP=""
}
trap 'restore' EXIT
trap 'restore; exit 3' INT TERM

while [ $# -gt 0 ]; do
  case "$1" in
    --file)          FILE="${2:-}"; shift 2 ;;
    --original)      ORIGINAL="${2:-}"; HAVE_ORIGINAL=1; shift 2 ;;
    --mutated)       MUTATED="${2:-}"; HAVE_MUTATED=1; shift 2 ;;
    --original-file) [ -f "${2:-}" ] || die "--original-file: no such file: ${2:-}"
                     ORIGINAL="$(cat "$2")"; HAVE_ORIGINAL=1; shift 2 ;;
    --mutated-file)  [ -f "${2:-}" ] || die "--mutated-file: no such file: ${2:-}"
                     MUTATED="$(cat "$2")"; HAVE_MUTATED=1; shift 2 ;;
    --test-cmd)      TEST_CMD="${2:-}"; shift 2 ;;
    --timeout)       TIMEOUT_SECONDS="${2:-}"; shift 2 ;;
    --label)         LABEL="${2:-}"; shift 2 ;;
    -h|--help)       sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

[ -n "$FILE" ]      || die "--file is required"
[ -f "$FILE" ]      || die "--file: no such file: $FILE"
[ "$HAVE_ORIGINAL" = 1 ] || die "--original / --original-file is required"
[ "$HAVE_MUTATED" = 1 ]  || die "--mutated / --mutated-file is required"
[ -n "$TEST_CMD" ]  || die "--test-cmd is required"
[[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || die "--timeout must be an integer"
[ "$ORIGINAL" != "$MUTATED" ] || die "--original and --mutated are identical: nothing to probe"

SHA_BEFORE="$(sha_of "$FILE")"

# A dirty target is refused, not worked around. After the probe runs, a hash mismatch has to mean
# "the probe failed to restore" — if the file was already modified going in, that signal is gone
# and a restore would overwrite the user's uncommitted work with the committed version.
if git -C "$(dirname "$FILE")" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C "$(dirname "$FILE")" status --porcelain -- "$FILE" 2>/dev/null)" ]; then
    emit "ERROR" "-" "yes" "target file has uncommitted changes; commit or stash before probing"
    exit 3
  fi
fi

# Content anchoring, per the skill's 2.3b rule: line numbers move, content does not. The anchor
# must be UNIQUE — replacing the first of several identical snippets probes a different mutant
# than the one the report named, and the verdict would be attributed to the wrong site.
OCCURRENCES="$(ORIGINAL="$ORIGINAL" python3 - "$FILE" <<'PY'
import os, sys
src = open(sys.argv[1], encoding='utf-8', errors='surrogateescape').read()
print(src.count(os.environ['ORIGINAL']))
PY
)" || die "failed to scan the file for the anchor" 3

case "$OCCURRENCES" in
  0) emit "ERROR" "-" "yes" "anchor text not found in $FILE — the file moved on since the report was produced"; exit 3 ;;
  1) ;;
  *) emit "ERROR" "-" "yes" "anchor text occurs $OCCURRENCES times — widen --original until it is unique"; exit 3 ;;
esac

BACKUP="$(mktemp "${TMPDIR:-/tmp}/reprobe.XXXXXX")"
cp -p "$FILE" "$BACKUP" || die "failed to back up $FILE" 3

ORIGINAL="$ORIGINAL" MUTATED="$MUTATED" python3 - "$FILE" <<'PY' || { emit "ERROR" "-" "yes" "failed to apply the mutation"; exit 3; }
import os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='surrogateescape').read()
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(
    src.replace(os.environ['ORIGINAL'], os.environ['MUTATED'], 1))
PY

# `timeout -k` so a runner that ignores SIGTERM still dies: a probe that leaves a suite running is
# the 679-minute failure this fleet already paid for once.
if command -v timeout >/dev/null 2>&1; then
  timeout -k 10 "$TIMEOUT_SECONDS" bash -c "$TEST_CMD" >/dev/null 2>&1
  TEST_EXIT=$?
else
  bash -c "$TEST_CMD" >/dev/null 2>&1
  TEST_EXIT=$?
fi

restore
SHA_AFTER="$(sha_of "$FILE")"

if [ "$SHA_AFTER" != "$SHA_BEFORE" ]; then
  emit "ERROR" "$TEST_EXIT" "no" "file did not restore to its pre-probe hash — restore by hand before continuing"
  exit 3
fi

# 124 = timeout's own exit, 137 = SIGKILL after -k. Neither is a test verdict: a suite that never
# finished says nothing about whether it would have caught the mutant, and scoring it KILLED
# (non-zero exit) would manufacture coverage out of an infrastructure failure.
if [ "$TEST_EXIT" -eq 124 ] || [ "$TEST_EXIT" -eq 137 ]; then
  emit "ERROR" "$TEST_EXIT" "yes" "test command exceeded ${TIMEOUT_SECONDS}s — no verdict; raise --timeout or narrow --test-cmd"
  exit 3
fi

if [ "$TEST_EXIT" -eq 0 ]; then
  emit "SURVIVED" "$TEST_EXIT" "yes" "tests passed with the mutant applied — confirmed gap, not a coverageAnalysis artifact"
  exit 1
fi

emit "KILLED" "$TEST_EXIT" "yes" "tests failed with the mutant applied — the reported survivor was a run artifact, not a gap"
exit 0
