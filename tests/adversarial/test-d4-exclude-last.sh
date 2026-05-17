#!/usr/bin/env bash
# test-d4-exclude-last.sh — D4: --exclude-last <name> flag for cross-call rotation.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── Case 1 (AC6): --exclude-last removes named provider ────────────────────

start_test "D4.1 --exclude-last mock-success → providers_used drops mock-success"
# Without --exclude-last: both providers tried (mock-success will succeed)
out_baseline=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
providers_baseline=$(echo "$out_baseline" | jq -r '.providers_used' 2>/dev/null)
# With --exclude-last mock-success: only mock-fail tried (and fails) — script exits 2 (all-failed)
out_excluded=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --exclude-last mock-success --json --files "$EMPTY" 2>/dev/null)
ec_excluded=$?
providers_excluded=$(echo "$out_excluded" | jq -r '.providers_used // .providers_attempted // .providers_available' 2>/dev/null)
assert_contains "$providers_baseline" "mock-success"  "baseline used mock-success"
# After excluding mock-success, only mock-fail remains — it fails → status=error
[[ "$providers_excluded" != *"mock-success"* ]] && pass "exclusion removed mock-success" || fail "exclusion" "providers_excluded=$providers_excluded"

# ─── Case 2: empty --exclude-last is noop ───────────────────────────────────

start_test "D4.2 --exclude-last '' (empty) is noop"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --exclude-last "" --json --files "$EMPTY" 2>/dev/null)
ec=$?
providers=$(echo "$out" | jq -r '.providers_used' 2>/dev/null)
assert_contains "$providers" "mock-success"  "noop preserves provider list"

# ─── Case 3: --exclude-last with unknown name → stderr warning, proceeds ────

start_test "D4.3 --exclude-last bogus-name → stderr warning, proceeds"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --exclude-last bogus-name --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
assert_exit_code "0" "$ec" "exit code (proceeds despite unknown name)"
assert_contains "$err" "exclude-last" "stderr mentions exclude-last warning"

# ─── Case 4: --help mentions --exclude-last ─────────────────────────────────

start_test "D4.4 --help documents --exclude-last"
help_out=$(bash "$ADV" --help 2>&1)
assert_contains "$help_out" "exclude-last" "--help mentions --exclude-last"
