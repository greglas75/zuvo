#!/usr/bin/env bash
# test-d2-partial-status.sh — D2: JSON gains status="partial" + always-present
#                            attempted_count / timeout_count
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

# Common env for all tests in this file
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── Case 1: All providers succeed → status=ok, attempted=2, timeout=0 ─────

start_test "D2.1 all-succeed → status=ok, attempted_count=2, timeout_count=0"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
timeouts=$(echo "$out" | jq -r '.timeout_count' 2>/dev/null)
assert_eq "ok"       "$status"     "status"
assert_eq "2"        "$attempted"  "attempted_count"
assert_eq "0"        "$timeouts"   "timeout_count"

# ─── Case 2: 1 of 2 times out → status=partial, attempted=2, timeout=1 ────

start_test "D2.2 mixed succ+timeout → status=partial, attempted_count=2, timeout_count=1"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" \
  ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
timeouts=$(echo "$out" | jq -r '.timeout_count' 2>/dev/null)
provider_count=$(echo "$out" | jq -r '.provider_count' 2>/dev/null)
assert_eq "partial"  "$status"          "status"
assert_eq "2"        "$attempted"       "attempted_count"
assert_eq "1"        "$timeouts"        "timeout_count"
assert_eq "1"        "$provider_count"  "provider_count"

# ─── Case 3: Both timeout → status=timeout, attempted=2, timeout=2 ─
# NOTE: exit-code-on-timeout assertion (must be 124) is owned by Task 3
# (test-d1-no-retry.sh), since the current retry path interaction confuses
# the exit code. Task 3 removes that retry path → clean exit 124.

start_test "D2.3 all-timeout → status=timeout, attempted_count=2, timeout_count=2"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout mock-hang" \
  ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
timeouts=$(echo "$out" | jq -r '.timeout_count' 2>/dev/null)
assert_eq "timeout"  "$status"     "status"
assert_eq "2"        "$attempted"  "attempted_count"
assert_eq "2"        "$timeouts"   "timeout_count"

# ─── Case 4: Single-provider success → status=ok, attempted=1, timeout=0 ───

start_test "D2.4 single-provider success → status=ok, attempted_count=1"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --single --json --files "$EMPTY" 2>/dev/null)
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
timeouts=$(echo "$out" | jq -r '.timeout_count' 2>/dev/null)
assert_eq "ok"       "$status"     "status"
assert_eq "1"        "$attempted"  "attempted_count"
assert_eq "0"        "$timeouts"   "timeout_count"

# ─── Case 5 (AC11): non-timeout failure → status=partial, timeout=0, provider=1 ───

start_test "D2.5 AC11 success+fail → status=partial, attempted=2, timeout=0, provider_count=1"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
timeouts=$(echo "$out" | jq -r '.timeout_count' 2>/dev/null)
provider_count=$(echo "$out" | jq -r '.provider_count' 2>/dev/null)
assert_eq "partial"  "$status"          "status (AC11)"
assert_eq "2"        "$attempted"       "attempted_count"
assert_eq "0"        "$timeouts"        "timeout_count (no timeout)"
assert_eq "1"        "$provider_count"  "provider_count (1 succeeded)"
