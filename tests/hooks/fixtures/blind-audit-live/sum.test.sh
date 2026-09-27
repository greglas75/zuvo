#!/bin/sh
# sum.test.sh — covers the non-empty path of sum.sh only. The empty-input branch
# (`sum_or_zero ""` -> 0) is deliberately never called here.
. "$(dirname "$0")/sum.sh"
[ "$(sum_or_zero "1 2 3")" = "6" ] || { echo "FAIL: sum_or_zero '1 2 3' expected 6"; exit 1; }
echo "PASS"
