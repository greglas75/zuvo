#!/bin/sh
# sum.sh — fixture for SMOKE-B2 (Task 10, live blind-audit panel): a tiny production function with
# exactly ONE deliberately untested BRANCH. sum.test.sh below exercises only the non-empty path, so
# the empty-input guard (the `if [ -z "$1" ]` branch) is the one gap a real reviewer should surface as
# a non-FULL row. Kept small on purpose — this file is sent whole to real model CLIs.
# Note: an all-whitespace argument (e.g. `"   "`) is NOT the same untested branch — `-z` is false for
# it, so it falls through to the for-loop path, which happens to print "0" too (word-splitting on
# whitespace yields zero iterations). That is a third, distinct path this fixture does not track and
# a reviewer is not expected to flag; the "exactly ONE" claim above is about the guard branch only.
sum_or_zero() {
  if [ -z "$1" ]; then
    echo 0
    return 0
  fi
  t=0
  for n in $1; do
    t=$((t + n))
  done
  echo "$t"
}
