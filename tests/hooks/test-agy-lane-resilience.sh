#!/usr/bin/env bash
# test-agy-lane-resilience.sh — runs the two adversarial-suite tests that guard the agy lane's
# quota/retry behaviour and the health ledger's cooldown sizing, IN THE DEFAULT GATE.
#
# Why a wrapper instead of putting them here directly: they are written against the adversarial
# suite's harness (start_test/assert_* from tests/adversarial/assert.sh, the ADV_TEST_EMPTY
# fixture, the mocks/ directory), and that harness lives with run.sh.
#
# Why they need pulling into the default gate at all: tests/run-all.sh only emits
# tests/adversarial/run.sh under ZUVO_TEST_SCOPE=full, because most of that suite reaches for
# real provider CLIs and real auth. These two do not — one builds a fake `agy` in its own temp
# directory, the other seeds a temp health ledger and drives mock providers — so they are
# hermetic, fast, and exactly the kind of thing that must not wait for an opt-in scope.
# Without this file both would have sat green and unrun, which is the same as not existing.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT/tests/adversarial/run.sh"

if [[ ! -f "$RUNNER" ]]; then
  echo "FAIL: tests/adversarial/run.sh is missing — the agy lane tests cannot run"
  exit 1
fi

out=$(bash "$RUNNER" test-agy-quota-fallback test-provider-bench-cooldown 2>&1)
rc=$?
printf '%s\n' "$out" | grep -E "SUMMARY|\[FAIL\]" | sed 's/\x1b\[[0-9;]*m//g'

if [[ $rc -eq 0 ]]; then
  echo "PASS: agy quota/fallback + provider bench cooldown"
  exit 0
fi
echo "FAIL: agy lane resilience tests (exit $rc)"
exit 1
