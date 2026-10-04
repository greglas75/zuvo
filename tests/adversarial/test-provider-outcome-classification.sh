#!/usr/bin/env bash
# Characterization of the existing multi/single provider-outcome precedence.
# Sourced by run.sh before the outcome recorder is extracted.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$HERE/mocks:$PATH"
OUTCOME_HOME="$(mktemp -d "$ADV_TEST_HOME/outcomes.XXXXXX")"
export ZUVO_HOME="$OUTCOME_HOME"
trap 'rm -rf "$OUTCOME_HOME"' EXIT

start_test "OC.1 multi mode records a successful lane before a silent failure"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "one real review remains available"
assert_eq "mock-success:ok,mock-fail:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "exact ordered outcomes"

start_test "OC.2 single mode keeps a failed lane before the first success"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-fail mock-success" \
  bash "$ADV" --single --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the second lane can answer"
assert_eq "mock-fail:empty,mock-success:ok" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the first failure is not lost"

start_test "OC.3 multi mode gives timeout precedence over empty output"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" ZUVO_REVIEW_TIMEOUT=1 \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the successful lane still answers"
assert_eq "mock-success:ok,mock-timeout:timeout" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "timeout outcome wins"

start_test "OC.4 single mode records a timed-out lane before the next success"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout mock-success" ZUVO_REVIEW_TIMEOUT=1 \
  bash "$ADV" --single --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the next lane answers"
assert_eq "mock-timeout:timeout,mock-success:ok" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "timeout remains in the record"
