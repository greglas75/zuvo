#!/usr/bin/env bash
# test-suite-e2e.sh — infra-audit end-to-end test suite driver
#
# Runs every tests/infra-suite/test-infra-*.sh in sequence.
# Counts PASS / SKIP / FAIL independently — SKIP ≠ FAIL.
#   - FAIL: test exits non-zero AND output does not begin with "SKIP:"
#   - SKIP: test exits 0 AND output begins with "SKIP:" (docker-guard clean skip)
#   - PASS: test exits 0 AND output does not begin with "SKIP:"
#
# Docker-dependent tests emit "SKIP: docker not available" and exit 0 when
# docker is absent — they are counted as SKIP, not FAIL.
#
# The smoke harnesses (smoke-fleet-audit.sh, smoke-resume.sh) are Phase-Final-
# only — they require a completed skill run-dir and are NOT included here.
# Run them manually after the skill completes:
#   bash tests/infra-suite/smoke-fleet-audit.sh <run-dir>
#   bash tests/infra-suite/smoke-resume.sh <run-dir>
#
# Exit 0 only when TOTAL_FAIL == 0.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TOTAL_PASS=0
TOTAL_SKIP=0
TOTAL_FAIL=0

run_test() {
  local name="$1"
  local path="$DIR/$name"

  echo "--- Running: $name ---"

  if [ ! -f "$path" ]; then
    echo "FAIL: $name (file not found)"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
    return
  fi

  # Capture output; preserve exit status without aborting the driver.
  local output exit_code
  set +e
  output="$(bash "$path" 2>&1)"
  exit_code=$?
  set -e

  echo "$output"

  if [ "$exit_code" -eq 0 ]; then
    # Detect clean SKIP: first non-empty line starts with "SKIP:"
    FIRST_LINE="$(echo "$output" | grep -m1 . || true)"
    if echo "$FIRST_LINE" | grep -q '^SKIP:'; then
      echo "SKIP: $name"
      TOTAL_SKIP=$((TOTAL_SKIP+1))
    else
      echo "PASS: $name"
      TOTAL_PASS=$((TOTAL_PASS+1))
    fi
  else
    echo "FAIL: $name (exit $exit_code)"
    TOTAL_FAIL=$((TOTAL_FAIL+1))
  fi

  echo ""
}

# ── test files (static-assert; no docker required) ───────────────────────────
run_test test-infra-protocol.sh
run_test test-infra-registry.sh
run_test test-infra-collector-cli.sh
run_test test-infra-agents.sh
run_test test-infra-skill-contract.sh
run_test test-infra-wiring.sh

# ── test files (docker-dependent; SKIP cleanly when docker absent) ────────────
run_test test-infra-fixtures.sh
run_test test-infra-collector-live.sh
run_test test-infra-collector-hardening.sh
run_test test-infra-collector-external.sh

# ── summary ──────────────────────────────────────────────────────────────────
echo "=== infra-audit Suite Results ==="
echo "PASS: $TOTAL_PASS  SKIP: $TOTAL_SKIP  FAIL: $TOTAL_FAIL"
echo ""
echo "NOTE: Smoke harnesses (smoke-fleet-audit.sh, smoke-resume.sh) are Phase-Final"
echo "      only — run them manually after a completed skill run with a <run-dir>."

if [ "$TOTAL_FAIL" -eq 0 ]; then
  echo "ALL PASSED (SKIPs do not count as failures)"
  exit 0
else
  echo "SOME FAILED: $TOTAL_FAIL test file(s) failed"
  exit 1
fi
