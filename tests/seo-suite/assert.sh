#!/bin/bash
set -euo pipefail

fail() {
  echo "FAIL: $*"
  exit 1
}

pass() {
  echo "PASS: $*"
}

assert_file_exists() {
  local path="$1"
  if [ ! -f "$path" ]; then
    fail "expected file to exist: $path"
  fi
}

assert_contains() {
  local path="$1"
  local needle="$2"
  if ! grep -Fq -- "$needle" "$path"; then
    fail "expected '$needle' in $path"
  fi
}

assert_equals() {
  local expected="$1"
  local actual="$2"
  local message="${3:-expected '$expected' but got '$actual'}"
  if [ "$expected" != "$actual" ]; then
    fail "$message (expected '$expected', got '$actual')"
  fi
}

require_file() {
  assert_file_exists "$1"
}

require_grep() {
  local pattern="$1"
  local path="$2"
  if ! grep -Eq -- "$pattern" "$path"; then
    fail "pattern not found in $(basename "$path"): $pattern"
  fi
}

require_text() {
  local text="$1"
  local path="$2"
  if ! grep -Fq -- "$text" "$path"; then
    fail "text not found in $(basename "$path"): $text"
  fi
}

require_eq() {
  local actual="$1"
  local expected="$2"
  local label="$3"
  assert_equals "$expected" "$actual" "$label"
}
