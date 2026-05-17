#!/usr/bin/env bash
# test-backward-compat.sh — Task 13 (AC9): backward compat + hook smoke.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"
HOOK="$ROOT/hooks/pre-commit-adversarial-gate.sh"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"

# ─── Case 1: Old `jq -r '.status' | grep -q '^ok$'` does NOT match "partial" ─

start_test "BC.1 old-style ok-grep does NOT match new partial status"
partial_out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
# Old caller pattern: jq -r '.status' returns bareword "partial" (not "ok"). The
# `grep -q '^ok$'` regex anchored at line boundaries must NOT match.
if echo "$partial_out" | jq -r '.status' 2>/dev/null | grep -q '^ok$'; then
  fail "BC.1" "old caller's grep ^ok$ incorrectly matched partial — fail-CLOSED contract violated"
else
  pass "old ^ok$ regex correctly fails-closed on partial"
fi

# ─── Case 2: pre-commit-adversarial-gate hook accepts new artifact ─────────

start_test "BC.2 pre-commit-adversarial-gate accepts artifact from updated script"
ART="$ADV_TEST_HOME/bc-art.txt"
rm -f "$ART"
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" \
  bash "$ADV" --json --artifact "$ART" --files "$EMPTY" >/dev/null 2>&1
if [[ -f "$ART" && -s "$ART" ]]; then
  pass "artifact written and non-empty"
else
  fail "BC.2" "artifact missing or empty"
fi
# The pre-commit hook checks artifact_kind header — verify it's there
if grep -q '^artifact_kind=adversarial-review' "$ART" 2>/dev/null; then
  pass "artifact has artifact_kind header (hook contract preserved)"
else
  fail "BC.2" "artifact missing artifact_kind=adversarial-review header"
fi

# ─── Case 3: JSON valid in all 4 status modes ──────────────────────────────

start_test "BC.4 providers_used_list is a JSON array, [0] indexes correctly (R-1 fix)"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
list_type=$(echo "$out" | jq -r '.providers_used_list | type' 2>/dev/null)
first=$(echo "$out" | jq -r '.providers_used_list[0]' 2>/dev/null)
str_type=$(echo "$out" | jq -r '.providers_used | type' 2>/dev/null)
assert_eq "array"        "$list_type"  "providers_used_list type is array"
assert_eq "mock-success" "$first"      "providers_used_list[0] indexes correctly"
assert_eq "string"       "$str_type"   "providers_used remains string (back-compat)"

start_test "BC.5 grep -Fx exclusion handles dotted provider names (R-2 fix)"
# Simulate a dotted provider name. mock-success-5.4 doesn't exist but the
# regex-correctness applies to detect_providers list. Easier test: --exclude
# with a value containing `.` should match literally, not as wildcard.
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --multi --exclude "mock.fail" --json --files "$EMPTY" 2>/dev/null)
# Without -F, `mock.fail` (regex) would match `mock-fail` (any single char between).
# With -Fx, `mock.fail` (literal) does not match `mock-fail` — so mock-fail remains in PROVIDERS.
providers=$(echo "$out" | jq -r '.providers_used' 2>/dev/null)
# Test passes if mock-fail wasn't accidentally excluded by regex over-match
# (i.e., we see both providers were attempted).
attempted=$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)
assert_eq "2" "$attempted" "literal exclusion does not over-match dotted names"

start_test "BC.3 JSON output is valid jq-parseable in all status modes"
# ok
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "ok status JSON valid" || fail "BC.3" "ok JSON invalid"
# partial
ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "partial status JSON valid" || fail "BC.3" "partial JSON invalid"
# timeout
ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" ZUVO_REVIEW_TIMEOUT=2 bash "$ADV" --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "timeout status JSON valid" || fail "BC.3" "timeout JSON invalid"
# single_provider_only
ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null | jq . >/dev/null 2>&1 \
  && pass "single_provider_only status JSON valid" || fail "BC.3" "single_provider_only JSON invalid"
