#!/usr/bin/env bash
# Contract for which commit a release tags.
#
# Measured incident, 2026-09-19: dev-push.sh tagged `git tag "v$VERSION"` with no commit — i.e.
# HEAD — and read `NEW_SHA=$(git rev-parse HEAD)` only AFTER the push and the tag. A sibling agent
# committed between the release commit and the tag, so v1.6.77 was published pointing at an
# unrelated gate fix, and the marketplace sha and installPath were computed from the same moving
# HEAD. Several agents commit into this repo at once, so "nothing else will land in those three
# lines" is not an assumption this script may make.
#
# This is a static contract test: it asserts the ORDER and the ARGUMENTS in the script, because
# reproducing the race for real would mean committing from a second process mid-release. What it
# cannot prove is that the pinned value is threaded everywhere downstream — the grep for NEW_SHA
# use-sites below is the closest honest check.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
DP="$ROOT/scripts/dev-push.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$DP" ] || { bad "scripts/dev-push.sh missing"; exit 1; }

# 1. The tag must name a commit. A bare `git tag "v$VERSION"` follows HEAD.
if grep -qE 'git tag "v\$\{NEW_VERSION\}" "\$NEW_SHA"' "$DP"; then
  pass "the tag is created on the pinned release commit, not on HEAD"
else
  bad "git tag does not pass an explicit commit — it will follow HEAD and can tag a sibling agent's work"
fi

# 2. NEW_SHA must be read BEFORE the push/tag block, i.e. while the release commit is still HEAD.
sha_line=$(grep -n '^NEW_SHA=\$(git rev-parse HEAD)' "$DP" | head -1 | cut -d: -f1)
push_line=$(grep -n '^git push origin main' "$DP" | head -1 | cut -d: -f1)
if [ -n "$sha_line" ] && [ -n "$push_line" ] && [ "$sha_line" -lt "$push_line" ]; then
  pass "NEW_SHA is pinned at line $sha_line, before the push/tag at $push_line"
else
  bad "NEW_SHA is read at line ${sha_line:-?} but the push/tag starts at ${push_line:-?} — it resolves to whatever HEAD has become"
fi

# 3. It must be pinned exactly once. A second `NEW_SHA=$(git rev-parse HEAD)` later in the file
# would silently re-introduce the race for everything after it.
n=$(grep -cE '^NEW_SHA=\$\(git rev-parse HEAD\)' "$DP")
if [ "$n" -eq 1 ]; then
  pass "the release sha is pinned exactly once ($n)"
else
  bad "NEW_SHA is assigned from HEAD $n times — a later re-read undoes the pin"
fi

# 4. An existing tag on a DIFFERENT commit must be reported, not swallowed. The old form ended in
# `2>/dev/null || true`, so a tag already sitting on the wrong commit produced a clean-looking run.
if grep -q 'already exists on' "$DP"; then
  pass "a pre-existing tag on another commit is surfaced rather than silently kept"
else
  bad "a tag that already exists elsewhere is swallowed — the release looks clean while pointing at the wrong commit"
fi

# 5. The marketplace sha and the installPath must use the pinned value, not re-derive it.
if grep -q 'sha\\": \\"\${NEW_SHA}' "$DP" || grep -q 'NEW_SHA}' "$DP"; then
  pass "downstream steps consume the pinned NEW_SHA"
else
  bad "downstream steps do not reference NEW_SHA — they may re-derive a moving HEAD"
fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
