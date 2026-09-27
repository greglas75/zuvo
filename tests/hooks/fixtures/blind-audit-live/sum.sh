#!/bin/sh
# sum.sh — fixture for SMOKE-B2 (Task 10, live blind-audit panel): a tiny production function with
# exactly ONE deliberately untested branch. sum.test.sh below exercises only the non-empty path, so
# the empty-input guard (the `if [ -z "$1" ]` branch) is the one gap a real reviewer should surface as
# a non-FULL row. Kept small on purpose — this file is sent whole to real model CLIs.
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
