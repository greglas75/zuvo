#!/usr/bin/env bash
# test-ship-release-ownership.sh — the version belongs to the RELEASE, not the PR.
#
# Regression under contract (2026-08-04): ship's Phase 3 had exactly ONE skip
# gate, `--no-bump`. Nothing about branch flow. So on a feature branch it bumped
# VERSION and prepended to CHANGELOG.md ON THE BRANCH, which produces two
# distinct failures:
#
#   1. Every PR conflicts with every other PR. VERSION is a single line and a
#      changelog entry is always prepended at the top, so two open branches edit
#      the same line of both files by construction.
#   2. Worse, and invisible to merge resolution: both branches bump 1.6.55 ->
#      1.6.56, so whichever merges SECOND ships a version number that is already
#      taken. Both sides look correct in isolation.
#
# Ground truth this encodes: every version bump in this repo's history is a plain
# single-parent commit on the default branch, produced by release.sh/dev-push.sh
# after the merge. Not one arrived through a PR.

SHIP="$ROOT/skills/ship/SKILL.md"

start_test "SR.1 ship declares a PR-flow skip for the version bump"
if [ ! -f "$SHIP" ]; then
  bad "SR.1" "skills/ship/SKILL.md not found"
else
  # The skip gate must name PR flow, not just --no-bump.
  if grep -q 'PR flow' "$SHIP" && grep -qi 'version + changelog deferred to the release' "$SHIP"; then
    pass "Phase 3 skip gate covers PR flow, not only --no-bump"
  else
    bad "SR.1" "no PR-flow skip in ship's version-bump phase — a feature branch will bump on the branch"
  fi
fi

start_test "SR.2 the rule is stated where the staging happens too"
# The skip is worthless if Phase 4 still stages the files: an agent that bumped
# anyway would quietly commit them. The staging step must repeat the condition.
# RANGE-BOUNDED on purpose. The first cut was `/Only if bump/{f=1} f && /PR flow/`,
# which never turns f back off — so it matched "PR flow" from the *push* section
# further down and passed even with the staging note deleted. An unterminated
# range is not an assertion about the staging block, it is an assertion about the
# file containing the words somewhere.
if awk '/Only if bump was performed/{f=1; next}
        f && /NEVER\*\* use `git add -A`/{f=0}
        f && /PR flow/{found=1}
        END{exit !found}' "$SHIP"; then
  pass "Phase 4 staging repeats the PR-flow condition"
else
  bad "SR.2" "staging block does not mention PR flow — the skip can be silently undone one phase later"
fi

start_test "SR.3 the union-merge shortcut is explicitly ruled out"
# `CHANGELOG.md merge=union` is the tempting one-line 'fix'. It hides the
# changelog collision and does NOTHING for VERSION, where a union merge yields a
# two-line version file — a broken release instead of a visible conflict.
if grep -q 'merge=union' "$SHIP"; then
  pass "the union-merge shortcut is named and rejected"
else
  bad "SR.3" "nothing warns against CHANGELOG.md merge=union, the plausible wrong fix"
fi

start_test "SR.4 history still matches the rule (no version bump arrived via a merge)"
# If this ever fails, either someone shipped a bump through a PR or the release
# path changed — both worth knowing before trusting the rule above.
_bad=""
for c in $(git -C "$ROOT" log --format='%h' -8 -- VERSION 2>/dev/null); do
  _p=$(git -C "$ROOT" rev-list --parents -n1 "$c" | wc -w)
  [ "$((_p - 1))" -gt 1 ] && _bad="$_bad $c"
done
if [ -z "$_bad" ]; then
  pass "last 8 VERSION commits are all single-parent (released on the default branch)"
else
  bad "SR.4" "VERSION changed in a merge commit:$_bad — a bump reached main through a PR"
fi
