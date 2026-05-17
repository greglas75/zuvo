#!/usr/bin/env bash
# test-smoke-all.sh — Task 13 (G1): runs SMOKE1/2/3 from the plan as the
# whole-feature final gate. Each smoke verbatim from
# docs/specs/2026-05-17-adversarial-robustness-plan.md "Whole-feature Smoke Proofs".

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── SMOKE1: mixed success/timeout end-to-end ─────────────────────────────

start_test "SMOKE1 mixed success/timeout via mocks"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" \
  ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
if echo "$out" | jq -e '.status == "partial" and .attempted_count == 2 and .timeout_count == 1 and .provider_count == 1 and (.results | keys | contains(["mock-success"]))' >/dev/null 2>&1; then
  pass "SMOKE1 ok"
else
  fail "SMOKE1" "JSON did not match expected partial+counts+results invariants"
fi

# ─── SMOKE2: single-provider hard refusal end-to-end ──────────────────────

start_test "SMOKE2 single-provider hard refusal"
err=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>&1 >/dev/null)
ec=$?
if [[ "$ec" -eq 3 ]] && echo "$err" | grep -qF 'single_provider_only'; then
  pass "SMOKE2 ok"
else
  fail "SMOKE2" "expected exit 3 + stderr single_provider_only, got ec=$ec stderr=<$err>"
fi

# ─── SMOKE3: cross-call rotation via --exclude-last ───────────────────────

start_test "SMOKE3 cross-call rotation via --exclude-last"
first=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --rotate --json --files "$EMPTY" 2>/dev/null \
  | jq -r '.providers_used' 2>/dev/null)
second=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --rotate --exclude-last "$first" --json --files "$EMPTY" 2>/dev/null \
  | jq -r '.providers_used // .status' 2>/dev/null)
if [[ -n "$first" && -n "$second" && "$first" != "$second" ]]; then
  pass "SMOKE3 ok (first=$first, second=$second)"
else
  fail "SMOKE3" "expected distinct providers, got first=$first second=$second"
fi
