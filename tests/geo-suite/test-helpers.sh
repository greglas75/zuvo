#!/usr/bin/env bash
PASS=0; FAIL=0

assert_file_exists() {
  if [ -f "$1" ]; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: file missing: $1"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  if grep -q "$2" "$1" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: '$2' not found in $1"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  if ! grep -q "$2" "$1" 2>/dev/null; then
    PASS=$((PASS + 1))
  else
    echo "FAIL: '$2' should not be found in $1"
    FAIL=$((FAIL + 1))
  fi
}

print_result() {
  local name="${1:-test}"
  echo "$name: $PASS passed, $FAIL failed"
}
