#!/usr/bin/env bash
# test-adversarial-stable-path.sh — adversarial-review must be reachable at a
# version-INDEPENDENT path.
#
# Regression under contract (2026-08-05). Claude Code adds {installPath}/bin to
# PATH once, at session start. A release creates a new cache dir and removes the
# old one, so any session open across a release keeps a PATH entry pointing at a
# deleted directory — `adversarial-review` becomes "command not found" mid-run,
# and every call dies 127 with nothing in the output explaining why. Measured
# after four same-day releases (1.6.53 -> .57): a live session's PATH still held
# .../zuvo/1.6.53/bin while only 1.6.56 and 1.6.57 existed on disk. Agents
# reported "adversarial doesn't work"; it was never a provider fault.
#
# ~/.zuvo/ is version-independent, which is why append-runlog, build-review-patch
# and verify-plan-dag have always lived there. adversarial-review was the one
# critical helper left out — an inconsistency, not a decision.
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ─── (a) install.sh must install it to ~/.zuvo/ ──────────────────────────────
if [ ! -f "$INSTALL" ]; then
  bad "(a) scripts/install.sh not found"
elif grep -q 'scripts/adversarial-review.sh' "$INSTALL" \
     && grep -q 'adversarial-review.sh".*_name="adversarial-review"' "$INSTALL"; then
  pass "(a) install.sh installs adversarial-review into the ~/.zuvo/ helper set"
else
  bad "(a) install.sh does not install adversarial-review to ~/.zuvo/ — it stays cache-only and dies when a release removes the session's PATH dir"
fi

# ─── (b) no skill may document the ambiguous cache glob ──────────────────────
# `cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh` expands to EVERY
# installed version with no ordering guarantee, so the documented fallback could
# itself run an old build. Checked across skills AND shared includes.
_glob_hits=""
for f in "$ROOT"/skills/*/SKILL.md "$ROOT"/shared/includes/*.md; do
  [ -f "$f" ] || continue
  if grep -q 'cache/zuvo-marketplace/zuvo/\*/scripts/adversarial-review\.sh' "$f"; then
    _glob_hits="$_glob_hits $(basename "$(dirname "$f")")/$(basename "$f")"
  fi
done
if [ -z "$_glob_hits" ]; then
  pass "(b) no skill or include documents the ambiguous version glob"
else
  bad "(b) ambiguous cache glob still documented in:$_glob_hits — it can resolve to an older version than the one installed"
fi

# ─── (c) the stable path is the one actually documented ──────────────────────
_n=$(grep -l '~/.zuvo/adversarial-review' "$ROOT"/skills/*/SKILL.md 2>/dev/null | wc -l | tr -d ' ')
if [ "$_n" -ge 20 ]; then
  pass "(c) ~/.zuvo/adversarial-review is the documented fallback in $_n skills"
else
  bad "(c) only $_n skills point at the stable path — the rest still rely on PATH alone"
fi

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
