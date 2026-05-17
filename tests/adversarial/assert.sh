#!/usr/bin/env bash
# assert.sh — Shell test assertion helpers for tests/adversarial/
# Source from individual test scripts. Increments TESTS_RUN and TESTS_FAILED.

: "${TESTS_RUN:=0}"
: "${TESTS_FAILED:=0}"
: "${CURRENT_TEST:=unknown}"

_red()   { printf '\033[31m%s\033[0m' "$*"; }
_green() { printf '\033[32m%s\033[0m' "$*"; }
_yellow(){ printf '\033[33m%s\033[0m' "$*"; }

pass() {
  TESTS_RUN=$((TESTS_RUN + 1))
  printf '  [%s] %s\n' "$(_green PASS)" "$CURRENT_TEST${1:+ — $1}"
}

fail() {
  TESTS_RUN=$((TESTS_RUN + 1))
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf '  [%s] %s\n' "$(_red FAIL)" "$CURRENT_TEST${1:+ — $1}"
  [[ -n "${2:-}" ]] && printf '         %s\n' "$2"
}

assert_eq() {
  local expected="$1" actual="$2" label="${3:-values}"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label" "expected=<$expected> actual=<$actual>"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="${3:-contains}"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass "$label"
  else
    fail "$label" "haystack did not contain <$needle>"
  fi
}

assert_exit_code() {
  local expected="$1" actual="$2" label="${3:-exit code}"
  if [[ "$expected" == "$actual" ]]; then
    pass "$label"
  else
    fail "$label" "expected exit=<$expected> actual exit=<$actual>"
  fi
}

assert_le() {
  local upper="$1" actual="$2" label="${3:-bound}"
  if [[ "$actual" -le "$upper" ]]; then
    pass "$label"
  else
    fail "$label" "expected <= $upper, got $actual"
  fi
}

assert_ne() {
  local a="$1" b="$2" label="${3:-distinct}"
  if [[ "$a" != "$b" ]]; then
    pass "$label"
  else
    fail "$label" "values were both <$a>"
  fi
}

start_test() {
  CURRENT_TEST="$1"
  printf '\n%s\n' "→ $CURRENT_TEST"
}
