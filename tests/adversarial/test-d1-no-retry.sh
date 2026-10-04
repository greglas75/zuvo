#!/usr/bin/env bash
# test-d1-no-retry.sh — D1: retry block removed; first timeout is final timeout.
# Asserts that all-timeout exits 124 within PROVIDER_TIMEOUT + 5s (no 2× window).

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── Case 1 (AC1): single-provider timeout → exit 124 within budget ────────

start_test "D1.1 AC1 single-timeout → exit 124 within PROVIDER_TIMEOUT+5s"
start=$(date +%s)
ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1
ec=$?
end=$(date +%s)
elapsed=$((end - start))
assert_exit_code "124" "$ec"           "exit code (AC1)"
assert_le        "7"   "$elapsed"      "elapsed ≤ 7s (no retry double-wait)"

# ─── Case 2 (AC2): mixed succ+timeout → exit 0, partial status, succeeded result kept ─

start_test "D1.2 AC2 mixed succ+timeout → exit 0, status=partial, succeeded result present"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
ec=$?
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
if echo "$out" | jq -e '.results | keys | contains(["mock-success"])' >/dev/null 2>&1; then has_succ=yes; else has_succ=no; fi
assert_exit_code "0"        "$ec"        "exit code (AC2 keeps results)"
assert_eq        "partial"  "$status"    "status (AC2)"
assert_eq        "yes"      "$has_succ"  "mock-success result preserved"

# ─── Case 3: retry-block dead code removed ────────────────────────────────

start_test "D1.3 RETRY_* variables removed (no dead code after D1)"
# The whole program, driver + modules (tests/lib/adversarial-driver.sh): against the driver file alone
# this absence check would pass whatever the modules hold.
. "$ROOT/tests/lib/adversarial-driver.sh"
if d1_src="$(adv_driver_source "$ROOT/scripts/adversarial-review.sh")"; then
  retry_refs=$(grep -cE 'RETRY_PROVIDERS|RETRY_CHARS|RETRY_INPUT|RETRY_PIDS|RETRY_PNAMES|SAVED_INPUT' <<< "$d1_src")
  assert_eq "0" "${retry_refs:-0}" "RETRY_* references"
else
  fail "D1.3" "the program text could not be assembled (reason above) — the absence check cannot run"
fi
