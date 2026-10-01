#!/usr/bin/env bash
# An early exit must not let the adversarial test runner invent a green summary.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/tests/adversarial/mocks"
cp "$ROOT/tests/adversarial/run.sh" "$ROOT/tests/adversarial/assert.sh" "$TMP/tests/adversarial/"
printf 'exit 0\n' > "$TMP/tests/adversarial/test-early-exit.sh"

out="$(bash "$TMP/tests/adversarial/run.sh" test-early-exit 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"test-early-exit.sh"* && "$out" == *"missing summary"* ]]; then
  echo 'PASS: early exit before __SUMMARY__ is a failed test file'
else
  echo "FAIL: early exit returned $rc with output: $out" >&2
  exit 1
fi

printf 'printf "__SUMMARY__ 1 0\\n"\nexit 7\n' > "$TMP/tests/adversarial/test-fake-summary-exit.sh"
out="$(bash "$TMP/tests/adversarial/run.sh" test-fake-summary-exit 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"premature exit (7)"* ]]; then
  echo 'PASS: a forged summary cannot hide a nonzero child exit'
else
  echo "FAIL: forged summary fixture returned $rc with output: $out" >&2
  exit 1
fi

: > "$TMP/tests/adversarial/test-no-assertions.sh"
out="$(bash "$TMP/tests/adversarial/run.sh" test-no-assertions 2>&1)"; rc=$?
if [[ "$rc" -ne 0 && "$out" == *"missing summary"* ]]; then
  echo 'PASS: zero executed assertions are not a green test'
else
  echo "FAIL: zero-assertion fixture returned $rc with output: $out" >&2
  exit 1
fi

printf 'pass "executed assertion"\n' > "$TMP/tests/adversarial/test-positive.sh"
out="$(bash "$TMP/tests/adversarial/run.sh" test-positive 2>&1)"; rc=$?
if [[ "$rc" -eq 0 && "$out" == *"SUMMARY: 1 run, 1 passed, 0 failed"* ]]; then
  echo 'PASS: real assertion summary remains green'
else
  echo "FAIL: positive fixture returned $rc with output: $out" >&2
  exit 1
fi
