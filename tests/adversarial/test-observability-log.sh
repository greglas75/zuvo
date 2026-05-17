#!/usr/bin/env bash
# test-observability-log.sh — Task 6 (AC10): adversarial.log SUMMARY row contains
# attempted_count + timeout_count per invocation.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# Use a scoped log file so we do not pollute ~/.zuvo/adversarial.log
TEST_LOG="$ADV_TEST_HOME/test-adversarial.log"
: > "$TEST_LOG"

start_test "T6.1 SUMMARY row appended after successful run"
ZUVO_ADVERSARIAL_LOG_FILE="$TEST_LOG" \
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1
last=$(tail -1 "$TEST_LOG")
# Format: SUMMARY \t ts \t mode \t status \t attempted \t timeouts \t duration \t providers
assert_contains "$last" "SUMMARY"      "SUMMARY prefix present"
assert_contains "$last" "code"          "mode column present"
# Validate the TSV column count: SUMMARY + 7 fields = 8 tab-separated
field_count=$(echo "$last" | awk -F'\t' '{print NF}')
assert_eq "8" "$field_count" "TSV column count (SUMMARY + 7 fields)"
# Specific assertions on attempted_count / timeout_count fields (cols 5 and 6)
attempted=$(echo "$last" | awk -F'\t' '{print $5}')
timeouts=$(echo "$last" | awk -F'\t' '{print $6}')
assert_eq "1" "$attempted"  "attempted_count column"
assert_eq "0" "$timeouts"   "timeout_count column"

start_test "T6.2 SUMMARY row for partial-timeout run includes timeout count"
: > "$TEST_LOG"
ZUVO_ADVERSARIAL_LOG_FILE="$TEST_LOG" \
ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" \
ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --multi --json --files "$EMPTY" >/dev/null 2>&1
last=$(tail -1 "$TEST_LOG")
assert_contains "$last" "SUMMARY"  "SUMMARY prefix"
attempted=$(echo "$last" | awk -F'\t' '{print $5}')
timeouts=$(echo "$last" | awk -F'\t' '{print $6}')
status=$(echo "$last" | awk -F'\t' '{print $4}')
assert_eq "2" "$attempted"  "attempted_count (partial)"
assert_eq "1" "$timeouts"   "timeout_count (partial)"
assert_eq "partial" "$status" "status column (partial)"
