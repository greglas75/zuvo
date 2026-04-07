#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
TOTAL_PASS=0; TOTAL_FAIL=0

run_test() {
  echo "--- Running: $1 ---"
  if bash "$DIR/$1"; then
    echo "PASS: $1"
  else
    echo "FAIL: $1"
    ((TOTAL_FAIL++))
  fi
}

run_test test-geo-check-registry.sh
run_test test-geo-fix-registry.sh
run_test test-geo-skills-contract.sh

echo ""
echo "=== GEO Suite Results ==="
echo "Failed test files: $TOTAL_FAIL"
if [ "$TOTAL_FAIL" -eq 0 ]; then echo "ALL PASSED"; else echo "SOME FAILED"; exit 1; fi
