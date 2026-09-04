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
#   3  ERROR     — NO VERDICT. Failing baseline, dirty file, ambiguous/missing anchor, timeout,
#                  command-not-found, signal death, concurrent edit, or an unverified restore.
#                  ERROR is never a verdict in disguise: only exit 0 and 1 are claims about tests.
#
# SURVIVED here is worth more than a report line: it was produced by running the code.
#
# The probe runs --test-cmd TWICE: once on the unmutated file to prove it passes at all, then once
# with the mutant applied. Without that baseline a broken command exits non-zero on both runs, and
# every real gap in the file is silently reclassified KILLED — confident false coverage, which is
# strictly worse than the noise this tool was built to remove.
#
# A timeout binary is REQUIRED (`timeout` or `gtimeout`). Running --test-cmd unbounded is not a
# degraded timeout, it is no timeout, and this tool's entire output is a claim about a bounded run.
#
# ⚠️ BUILD-CACHE HAZARD — read before choosing --test-cmd. Running the suite twice primes whatever
# compile cache the runner keeps, and many caches are keyed on (mtime-in-SECONDS, size). A mutation
# that does not change the file SIZE and lands in the same second as the baseline therefore looks
# unchanged to the cache, the stale artifact is reused, the mutant never executes, and the probe
# reports SURVIVED — a fabricated gap. Measured here with CPython: `+` → `-` is size-preserving, and
# `__pycache__` masked it every time until the baseline run was made cache-free.
# So: --test-cmd must not depend on a stale-able build cache. Disable it explicitly
# (`python3 -B` / `PYTHONDONTWRITEBYTECODE=1`, `ts-node --files`, a clean `--no-cache` flag) or
# point the command at a runner that hashes content rather than metadata.
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
#
# Two rules here are the difference between a safety net and a shredder, and BOTH were defects in
# the first version of this file (found by cross-model review, 2026-09-05):
#
#   1. `$BACKUP` is assigned ONLY after a verified copy. `mktemp` creates the file before `cp`
#      runs, so assigning first meant a FAILED backup (disk full, ACL, FS error) left a zero-byte
#      file that the EXIT trap then copied over the production source. The script's own error path
#      destroyed the file it exists to protect.
#   2. The backup is NOT deleted by `restore()`. It is deleted only after the post-restore hash
#      matches. A `cp` that fails or half-writes during restore used to unlink the only copy of the
#      original, leaving the source mutated and unrecoverable — reported as "restore by hand" with
#      nothing left to restore from.
restore() {
  [ -n "$BACKUP" ] && [ -f "$BACKUP" ] || return 0
  cp -p "$BACKUP" "$FILE" 2>/dev/null || {
    echo "reprobe: RESTORE FAILED — the original is still at $BACKUP; recover with: cp '$BACKUP' '$FILE'" >&2
    return 1
  }
}

# Kill the test command's whole process group, then restore. Without this the child survives a
# TERM sent to THIS script by PID (how an orchestrator kills a hung helper — terminal Ctrl-C
# signals the group and hides the bug): the file is restored correctly and a detached suite keeps
# running. Worse than the wasted CPU: if --test-cmd ever writes to the target (a codegen or
# lint --fix step wired in by mistake) it can re-corrupt the file AFTER this run reported success.
kill_child() {
  [ -n "${CHILD_PGID:-}" ] || return 0
  kill -TERM "-$CHILD_PGID" 2>/dev/null
  CHILD_PGID=""
}
trap 'kill_child; restore' EXIT
trap 'kill_child; restore; exit 3' INT TERM

# Every value-taking flag must prove its value exists BEFORE `shift 2`. With a trailing valueless
# flag, `shift 2` on one remaining arg fails without consuming it, so `while [ $# -gt 0 ]` re-enters
# on the same token forever — a silent infinite loop instead of the documented exit 2. Reproduced
# on bash 3.2 in review; it burned a farm slot with zero output.
need_val() { [ "$1" -ge 2 ] || die "missing value for $2"; }

# Read a file argument WITHOUT losing trailing newlines. `$(cat f)` strips every trailing newline,
# and --original-file exists precisely for line-exact multi-line anchors — most of which end in
# one. A stripped anchor does not match, which surfaces as the misleading "the file moved on since
# the report was produced" and sends the reader chasing drift that never happened.
# NB: this ASSIGNS to a named variable instead of echoing. Returning the text through stdout
# would put it back inside a `$( )` at the call site, and command substitution strips trailing
# newlines unconditionally — undoing the very thing the `printf x` guard is here to prevent.
# `printf -v` rather than `eval`: the escaped-eval form is in fact safe (the file's contents are
# expanded as a VALUE, never re-parsed — verified with a `$(...)` payload that stayed literal), but
# two independent reviewers read it as injection on sight. A construct that costs a reviewer a
# repro every time is worth replacing even when it is correct.
read_arg_file() {   # read_arg_file <dest-var-name> <path>
  local __content
  __content="$(cat "$2"; printf x)"
  printf -v "$1" '%s' "${__content%x}"
}

while [ $# -gt 0 ]; do
  case "$1" in
    --file)          need_val $# "$1"; FILE="$2"; shift 2 ;;
    --original)      need_val $# "$1"; ORIGINAL="$2"; HAVE_ORIGINAL=1; shift 2 ;;
    --mutated)       need_val $# "$1"; MUTATED="$2"; HAVE_MUTATED=1; shift 2 ;;
    --original-file) need_val $# "$1"; [ -f "$2" ] || die "--original-file: no such file: $2"
                     read_arg_file ORIGINAL "$2"; HAVE_ORIGINAL=1; shift 2 ;;
    --mutated-file)  need_val $# "$1"; [ -f "$2" ] || die "--mutated-file: no such file: $2"
                     read_arg_file MUTATED "$2"; HAVE_MUTATED=1; shift 2 ;;
    --test-cmd)      need_val $# "$1"; TEST_CMD="$2"; shift 2 ;;
    --timeout)       need_val $# "$1"; TIMEOUT_SECONDS="$2"; shift 2 ;;
    --label)         need_val $# "$1"; LABEL="$2"; shift 2 ;;
    -h|--help)       sed -n '2,45p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)               die "unknown argument: $1" ;;
  esac
done

[ -n "$FILE" ]      || die "--file is required"
[ -f "$FILE" ]      || die "--file: no such file: $FILE"
[ "$HAVE_ORIGINAL" = 1 ] || die "--original / --original-file is required"
[ "$HAVE_MUTATED" = 1 ]  || die "--mutated / --mutated-file is required"
[ -n "$TEST_CMD" ]  || die "--test-cmd is required"
# `>= 1`, not `>= 0`: GNU timeout treats DURATION=0 as "no timeout at all", so `--timeout 0` would
# silently restore the unbounded run this script refuses to perform — the documented 679-minute
# incident, reachable through an argument instead of a missing binary.
[[ "$TIMEOUT_SECONDS" =~ ^[1-9][0-9]*$ ]] || die "--timeout must be an integer >= 1 (0 disables GNU timeout entirely)"
[ "$ORIGINAL" != "$MUTATED" ] || die "--original and --mutated are identical: nothing to probe"

# Normalize to an absolute path BEFORE anything consults git. `git -C <dir> … -- <pathspec>`
# resolves the pathspec relative to <dir>, so `--file src/foo.ts` used to send git looking for
# `src/src/foo.ts` — no match, empty porcelain output, and the dirty-file check below passed
# silently on exactly the input it was written to refuse.
FILE_DIR="$(cd "$(dirname "$FILE")" && pwd)" || die "--file: cannot resolve directory of $FILE"
FILE="$FILE_DIR/$(basename "$FILE")"

SHA_BEFORE="$(sha_of "$FILE")"

# A dirty target is refused, not worked around. After the probe runs, a hash mismatch has to mean
# "the probe failed to restore" — if the file was already modified going in, that signal is gone
# and a restore would overwrite the user's uncommitted work with the committed version.
if git -C "$FILE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  if [ -n "$(git -C "$FILE_DIR" status --porcelain -- "$FILE" 2>/dev/null)" ]; then
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

# Resolve a timeout binary ONCE, and refuse to run without one.
#
# The first version fell back to running the command unbounded when `timeout` was absent — which
# is stock macOS, the stated target platform (GNU coreutils installs it as `gtimeout`, and only
# if the user installed coreutils at all). So `--timeout 2` against a 6-second command waited the
# full six seconds and reported SURVIVED: the safety mechanism silently did nothing and then
# handed back a confident verdict. An unbounded run is not a degraded timeout, it is no timeout,
# and this tool's whole output is a claim about a bounded execution.
TIMEOUT_BIN=""
if command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"
fi
[ -n "$TIMEOUT_BIN" ] || die "no timeout binary found (need 'timeout' or 'gtimeout'; on macOS: brew install coreutils) — refusing to run --test-cmd unbounded" 3

# run_tests — one place, so the baseline and the mutated run are provably the SAME command.
# `-k` so a runner that ignores SIGTERM still dies: a probe that leaves a suite running is the
# 679-minute failure this fleet already paid for once. `set -m` puts the child in its own process
# group so kill_child can take the whole tree down, not just the wrapper.
run_tests() {
  set -m
  "$TIMEOUT_BIN" -k 10 "$TIMEOUT_SECONDS" bash -c "$TEST_CMD" >/dev/null 2>&1 &
  CHILD_PGID=$!
  wait "$CHILD_PGID"
  local rc=$?
  CHILD_PGID=""
  set +m
  return "$rc"
}

# Classify an exit code from run_tests. Only a clean 0 or an ordinary test failure is a VERDICT;
# everything else is the harness failing, and must not be dressed up as one.
#
#   124/137  timeout family — the suite never finished, so it said nothing about the mutant
#   126/127  not executable / command not found — nothing ran at all
#   >=128    killed by a signal — same
#
# The first version special-cased only 124/137 and funnelled every other non-zero exit into
# KILLED with the text "the reported survivor was a run artifact, not a gap". A typo in
# --test-cmd therefore certified coverage for a real gap. That is the exact failure this tool
# exists to prevent, arriving through a different exit code.
classify_exit() {   # echoes: verdict-ok | infra:<reason>
  case "$1" in
    0)       echo "verdict-ok" ;;
    124|137) echo "infra:test command exceeded ${TIMEOUT_SECONDS}s — no verdict; raise --timeout or narrow --test-cmd" ;;
    126)     echo "infra:test command is not executable (exit 126) — check --test-cmd" ;;
    127)     echo "infra:test command not found (exit 127) — check --test-cmd" ;;
    *)       if [ "$1" -ge 128 ]; then
               echo "infra:test command killed by signal $(( $1 - 128 )) (exit $1) — no verdict"
             else
               echo "verdict-ok"
             fi ;;
  esac
}

# ── BASELINE: the tests must PASS on the unmutated file ─────────────────────
# Without this the tool has an inverted failure mode that is worse than the one it was built to
# prevent. A misconfigured --test-cmd (wrong glob, missing module, an unrelated red test, a
# compile error) exits non-zero on EVERY probe; the verdict logic below reads any non-zero exit as
# KILLED, so every real gap in the file is silently reclassified as a "run artifact" and dropped.
# That manufactures coverage out of a broken command — exactly the class the timeout→ERROR rule
# already refuses, arriving through the front door. Establish the baseline first, or return no
# verdict at all.
run_tests
BASELINE_EXIT=$?
if [ "$BASELINE_EXIT" -ne 0 ]; then
  BASELINE_CLASS="$(classify_exit "$BASELINE_EXIT")"
  case "$BASELINE_CLASS" in
    infra:*) emit "ERROR" "$BASELINE_EXIT" "yes" "baseline: ${BASELINE_CLASS#infra:}" ;;
    *)       emit "ERROR" "$BASELINE_EXIT" "yes" \
               "baseline FAILED: --test-cmd does not pass on the unmutated file (exit $BASELINE_EXIT) — no verdict is possible; fix the command or the suite first" ;;
  esac
  exit 3
fi

# Assign BACKUP only after a VERIFIED copy. mktemp creates the file before cp runs, so assigning
# first meant a failed cp left a zero-byte file that the EXIT trap copied over the real source.
BACKUP_TMP="$(mktemp "${TMPDIR:-/tmp}/reprobe.XXXXXX")" || die "failed to create a backup file" 3
if cp -p "$FILE" "$BACKUP_TMP"; then
  # macOS `cp -p` preserves BSD file FLAGS too, not just the mode. A flag-protected source
  # (`chflags uchg`) makes the backup itself undeletable, so cleanup fails with a raw `rm:
  # Operation not permitted` on stderr — outside this script's KEY=VALUE contract — and leaks a
  # temp file. Clearing the flags on our own copy costs nothing and is a no-op elsewhere.
  chflags nouchg,noschg "$BACKUP_TMP" 2>/dev/null || true
  BACKUP="$BACKUP_TMP"
else
  rm -f "$BACKUP_TMP"
  die "failed to back up $FILE" 3
fi

ORIGINAL="$ORIGINAL" MUTATED="$MUTATED" python3 - "$FILE" <<'PY' || { emit "ERROR" "-" "yes" "failed to apply the mutation"; exit 3; }
import os, sys
p = sys.argv[1]
src = open(p, encoding='utf-8', errors='surrogateescape').read()
open(p, 'w', encoding='utf-8', errors='surrogateescape').write(
    src.replace(os.environ['ORIGINAL'], os.environ['MUTATED'], 1))
PY

SHA_MUTATED="$(sha_of "$FILE")"

# The mutation must have actually changed something on disk. A silent no-op — line-ending
# translation, an --original that normalizes to --mutated, a filter in the write path — leaves the
# ORIGINAL code running while the probe believes a mutant is in place. The tests then pass for the
# most boring reason possible and the run reports SURVIVED: a fabricated gap, indistinguishable in
# the output from a real one.
if [ "$SHA_MUTATED" = "$SHA_BEFORE" ]; then
  emit "ERROR" "-" "yes" "the mutation did not change the file on disk (hash unchanged) — no mutant was ever applied, so no verdict is possible"
  exit 3
fi

run_tests
TEST_EXIT=$?

# Concurrent-modification check, BEFORE restoring. The pre-probe hash cannot see this: if someone
# saved the file while the suite ran, restoring the backup silently discards their edit and the
# post-restore hash still matches SHA_BEFORE, so the run reports a clean restore over lost work.
# Comparing against the hash we WROTE is the only way to tell "nobody touched it" from "somebody did".
SHA_PRE_RESTORE="$(sha_of "$FILE")"
if [ "$SHA_PRE_RESTORE" != "$SHA_MUTATED" ]; then
  emit "ERROR" "$TEST_EXIT" "no" \
    "file changed while the probe was running — NOT restoring over it; the pre-probe copy is kept at $BACKUP"
  BACKUP=""   # disarm the trap: restoring here would destroy the concurrent edit
  exit 3
fi

restore
SHA_AFTER="$(sha_of "$FILE")"

if [ "$SHA_AFTER" != "$SHA_BEFORE" ]; then
  # Keep the backup — it is the only remaining copy of the original, and the recovery step below
  # needs it. Deleting it here is what turned a failed restore into unrecoverable loss.
  emit "ERROR" "$TEST_EXIT" "no" "file did not restore to its pre-probe hash — recover with: cp '$BACKUP' '$FILE'"
  BACKUP=""   # disarm the EXIT trap so it cannot retry the copy that just failed
  exit 3
fi

# Restore verified — only now is the backup safe to drop.
rm -f "$BACKUP"
BACKUP=""

# Anything the harness did to itself is ERROR, never a verdict — see classify_exit.
CLASS="$(classify_exit "$TEST_EXIT")"
case "$CLASS" in
  infra:*) emit "ERROR" "$TEST_EXIT" "yes" "${CLASS#infra:}"; exit 3 ;;
esac

if [ "$TEST_EXIT" -eq 0 ]; then
  emit "SURVIVED" "$TEST_EXIT" "yes" "tests passed with the mutant applied — confirmed gap, not a coverageAnalysis artifact"
  exit 1
fi

emit "KILLED" "$TEST_EXIT" "yes" "tests failed with the mutant applied — the reported survivor was a run artifact, not a gap"
exit 0
