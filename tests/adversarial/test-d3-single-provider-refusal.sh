#!/usr/bin/env bash
# test-d3-single-provider-refusal.sh — D3: hard refusal when post-exclusion
# provider count < 2 AND --multi or --rotate requested.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── Case 1 (AC5): 1 provider + --multi → exit non-zero, single_provider_only ─

start_test "D3.1 1 provider + --multi → exit non-zero, stderr single_provider_only"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "3" "$ec" "exit code (D3 single_provider_only = 3)"
assert_contains "$err" "single_provider_only" "stderr contains single_provider_only"

# ─── Case 2: 1 provider + --rotate → exit non-zero, single_provider_only ────

start_test "D3.2 1 provider + --rotate → exit non-zero, stderr single_provider_only"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --rotate --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "3" "$ec" "exit code (D3 single_provider_only = 3)"
assert_contains "$err" "single_provider_only" "stderr contains single_provider_only"

# ─── Case 3: 1 provider + --single → exit 0 (unchanged) ─────────────────────

start_test "D3.3 1 provider + --single → exit 0 (no refusal)"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --single --json --files "$EMPTY" 2>/dev/null)
ec=$?
assert_exit_code "0" "$ec" "exit code (--single unaffected)"

# ─── Case 4: 1 provider + --provider mock-success → exit 0 ──────────────────

start_test "D3.4 1 provider + --provider mock-success → exit 0 (explicit)"
out=$(bash "$ADV" --provider mock-success --json --files "$EMPTY" 2>/dev/null)
ec=$?
assert_exit_code "0" "$ec" "exit code (explicit --provider unaffected)"

# ─── Case 5: 2 providers + --multi → no refusal, normal run ─────────────────

start_test "D3.5 2 providers + --multi → no refusal"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "0" "$ec" "exit code (2 providers OK)"
[[ "$err" == *"single_provider_only"* ]] && fail "no refusal" "stderr unexpectedly contains single_provider_only" || pass "no false refusal"
