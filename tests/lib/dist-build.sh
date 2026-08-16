#!/usr/bin/env bash
#
# dist-build.sh <codex|cursor|antigravity|kimi>
#
# Drop-in replacement for `bash scripts/build-<platform>-skills.sh "$ROOT"` inside
# tests, with a per-suite-run cache in front of it.
#
# WHY THIS EXISTS
# ---------------
# This repo ships 57 markdown skills and nothing else executable, yet its test suite
# took ~13 minutes. Measured 2026-08-13/16: the fast suite ran SIX full distribution
# builds — reviewer-model-builds.bats builds codex+cursor+antigravity, test-install-
# wiring.sh builds codex+antigravity again, test-kimi-build.sh builds kimi — and each
# build re-processes all 57 skills (path rewrites, unicode normalization, TOML agent
# generation, validation) for 18-31s. Four of those six builds were recomputing a tree
# a sibling test had already produced from the identical source.
#
# The second, worse effect was correctness: every builder writes to `$ROOT/dist/<p>`
# and reviewer-model-builds.bats `rm -rf`s that tree in its per-test `setup()`, so one
# child could truncate the directory another child was asserting against. That is
# B-DIST-BUILD-RACE — green standalone, red about twice in ten suite runs, and it cost
# a full debugging session before it was recognised as a race rather than a real bug.
#
# CONTRACT (identical to calling the builder directly)
#   stdout      the build log, byte-for-byte
#   exit code   the build's exit code
#   side effect $ROOT/dist/<platform> holds that build's output
#
# With ZUVO_DIST_CACHE unset — running a test file by hand — this is a pure
# pass-through and behaves exactly as before. tests/run-all.sh sets the variable to a
# temp dir it creates and removes per run, so a cache can never outlive one invocation
# and can never be stale with respect to the working tree.
#
# The replay copies the cached tree back into place (252ms for 311 files, versus a
# 18-31s rebuild), so a test that wipes dist/ in its setup still sees a materialized
# tree, and its assertions still run against real files on disk.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

PLATFORM="${1:-}"
case "$PLATFORM" in
  codex|cursor|antigravity|kimi) ;;
  *)
    echo "usage: tests/lib/dist-build.sh <codex|cursor|antigravity|kimi>" >&2
    exit 2 ;;
esac

BUILDER="$ROOT/scripts/build-$PLATFORM-skills.sh"
if [ ! -f "$BUILDER" ]; then
  echo "dist-build: builder not found: $BUILDER" >&2
  exit 2
fi

CACHE="${ZUVO_DIST_CACHE:-}"

# ── uncached path: exact previous behaviour ──────────────────────────────────
if [ -z "$CACHE" ] || [ ! -d "$CACHE" ]; then
  bash "$BUILDER" "$ROOT" 2>&1
  exit $?
fi

LOG="$CACHE/$PLATFORM.log"
RC="$CACHE/$PLATFORM.rc"
TREE="$CACHE/$PLATFORM.tree"

# ── replay ───────────────────────────────────────────────────────────────────
# The .rc file is the sentinel and is written LAST, so a half-populated cache entry
# (interrupted run, killed build) is never mistaken for a complete one.
if [ -f "$RC" ]; then
  rm -rf "$ROOT/dist/$PLATFORM"
  mkdir -p "$ROOT/dist"
  # A failed build may have produced no tree; that is faithfully replayed as no tree.
  if [ -d "$TREE" ]; then
    cp -R "$TREE" "$ROOT/dist/$PLATFORM"
  fi
  cat "$LOG"
  exit "$(cat "$RC")"
fi

# ── first caller for this platform: run the real build, then memoize ──────────
# Redirect straight to the log rather than capturing in a variable: `$(...)` strips
# trailing newlines, and a test that diffs or greps anchored patterns out of the log
# must see the builder's exact bytes.
bash "$BUILDER" "$ROOT" > "$LOG" 2>&1
rc=$?

if [ -d "$ROOT/dist/$PLATFORM" ]; then
  rm -rf "$TREE.tmp.$$"
  # Snapshot under a PID-unique name and rename into place, so a concurrent reader
  # sees either no entry or a complete one — never a tree mid-copy.
  if cp -R "$ROOT/dist/$PLATFORM" "$TREE.tmp.$$" 2>/dev/null; then
    mv "$TREE.tmp.$$" "$TREE" 2>/dev/null || rm -rf "$TREE.tmp.$$"
  else
    rm -rf "$TREE.tmp.$$"
  fi
fi

printf '%s' "$rc" > "$RC"
cat "$LOG"
exit "$rc"
