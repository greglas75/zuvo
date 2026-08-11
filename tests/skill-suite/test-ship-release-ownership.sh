#!/usr/bin/env bash
# test-ship-release-ownership.sh — the version belongs to the RELEASE, not the PR.
#
# Regression under contract (2026-08-04): ship's Phase 3 had exactly ONE skip
# gate, `--no-bump`. Nothing about branch flow. Phase 0 already distinguishes
# direct flow from PR flow, but only to decide how to PUSH — so ship on a feature
# branch wrote VERSION and prepended to CHANGELOG.md ON THE BRANCH. Two failures:
#
#   1. Every PR conflicts with every other PR. VERSION is a single line and a
#      changelog entry is always prepended at the top, so two open branches edit
#      the same line of both files by construction — always, not occasionally.
#   2. Worse, and invisible to merge resolution: both branches bump 1.6.55 ->
#      1.6.56, so whichever merges SECOND ships a version number already taken.
#      Both sides are individually correct, so resolving the conflict either way
#      still leaves the duplicate.
#
# Ground truth this encodes: every version bump in this repo's history is a plain
# single-parent commit on the default branch, produced by release.sh/dev-push.sh
# AFTER the merge. Not one arrived through a PR. (Assertion (d) re-checks that
# premise, so the rule fails loudly rather than going quietly stale.)
#
# STANDALONE, like every other test in this directory: run-all.sh globs
# tests/skill-suite/test-*.sh and EXECUTES them, it does not source them into a
# harness. The first cut of this file assumed injected `start_test`/`pass`/`bad`/
# `$ROOT` (the tests/adversarial/ convention) and therefore died under the real
# runner while passing against a hand-rolled stub — which is how it blocked a
# release. Verify a new test by running it the way the runner does.
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SHIP="$ROOT/skills/ship/SKILL.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ─── (a) the skip gate must name PR flow, not only --no-bump ─────────────────
if [ ! -f "$SHIP" ]; then
  bad "(a) skills/ship/SKILL.md not found at $SHIP"
elif grep -q 'PR flow' "$SHIP" \
     && grep -q 'version + changelog deferred to the release' "$SHIP"; then
  pass "(a) Phase 3 skip gate covers PR flow, not only --no-bump"
else
  bad "(a) no PR-flow skip in ship's version-bump phase — a feature branch will bump on the branch, conflicting with every other PR"
fi

# ─── (b) the rule must be repeated where the staging happens ─────────────────
# A skip is worthless if Phase 4 still stages the files: an agent that bumped
# anyway would quietly commit them. RANGE-BOUNDED on purpose — the first cut was
# `/Only if bump/{f=1} f && /PR flow/`, which never turns the range off, so it
# matched "PR flow" from the *push* section further down and passed even with the
# staging note deleted. An unterminated range asserts that the file contains the
# words somewhere, not that the staging block carries the condition.
if [ -f "$SHIP" ] && awk '
      /Only if bump was performed/ { f = 1; next }
      f && /NEVER\*\* use `git add -A`/ { f = 0 }
      f && /PR flow/ { found = 1 }
      END { exit !found }' "$SHIP"; then
  pass "(b) Phase 4 staging repeats the PR-flow condition"
else
  bad "(b) staging block does not mention PR flow — the Phase 3 skip can be silently undone one phase later"
fi

# ─── (c) the plausible wrong fix must be named and rejected ──────────────────
# `CHANGELOG.md merge=union` in .gitattributes is the tempting one-liner. It
# hides the changelog collision and does NOTHING for VERSION, where a union merge
# yields a two-line version file — a broken release instead of a visible conflict.
if [ -f "$SHIP" ] && grep -q 'merge=union' "$SHIP"; then
  pass "(c) the union-merge shortcut is named and rejected in the text"
else
  bad "(c) nothing warns against CHANGELOG.md merge=union, the plausible wrong fix"
fi

# ─── (d) the historical premise still holds ──────────────────────────────────
# If this fails, either a bump reached main through a PR or the release path
# changed — both worth knowing before trusting (a). Skipped, not failed, outside
# a git work tree: a missing repo is not evidence about the release path.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  pass "(d) skipped — not a git work tree, no history to check"
else
  merged=""
  for c in $(git -C "$ROOT" log --format='%h' -8 -- VERSION 2>/dev/null); do
    n=$(git -C "$ROOT" rev-list --parents -n1 "$c" 2>/dev/null | wc -w)
    [ "$((n - 1))" -gt 1 ] && merged="$merged $c"
  done
  if [ -z "$merged" ]; then
    pass "(d) last 8 VERSION commits are all single-parent (released on the default branch)"
  else
    bad "(d) VERSION changed in a merge commit:$merged — a version bump reached main through a PR"
  fi
fi

# ─── (e) every release commit must have its tag ──────────────────────────────
# A ship that dies between `git commit` and `git tag` leaves a released version with no tag, and
# the skill's half-done detector only looks at HEAD — so the moment one more commit lands, the gap
# becomes invisible and permanent. It happened twice here before anyone diffed the two by hand:
# v1.6.50 (2026-08-01) and v1.6.67 (2026-08-11) both shipped bumps that were never tagged, and
# v1.6.67 sat undetected while v1.6.68 shipped straight past it. Ship now sweeps history for this
# (Phase 0 step 3); this is the mechanical check that the sweep is not just documented prose.
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  pass "(e) skipped — not a git work tree"
elif [ "$(git -C "$ROOT" tag --list 'v*' | head -1)" = "" ]; then
  pass "(e) skipped — no version tags fetched (shallow/tagless clone), nothing to compare"
else
  untagged=""
  # -20 bounds the sweep to recent releases: an ancient pre-convention commit is not a regression
  # anyone is going to act on, and failing on it forever would train people to ignore this check.
  while read -r sha msg; do
    ver=$(printf '%s' "$msg" | sed -n 's/^release: v\([0-9A-Za-z.+-]*\).*/\1/p')
    [ -n "$ver" ] || continue
    git -C "$ROOT" rev-parse -q --verify "refs/tags/v$ver" >/dev/null 2>&1 \
      || untagged="$untagged v$ver@${sha}"
  done <<EOF
$(git -C "$ROOT" log --format='%h %s' -20 --grep='^release: v' 2>/dev/null)
EOF
  if [ -z "$untagged" ]; then
    pass "(e) every one of the last 20 release commits has its tag"
  else
    bad "(e) released but never tagged:$untagged — create the tag AT ITS COMMIT (never at HEAD: a tag on later code misstates what shipped)"
  fi
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
