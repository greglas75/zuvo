#!/usr/bin/env bash
# test-hard-timeout-and-suspend.sh — the failure-classification contract.
#
# Background: "Końcowy strict audit zablokowała infrastruktura wszystkich providerów"
# (2026-07-30). The host had gone to Clamshell Sleep one minute into the run; every provider
# came back empty after 5998s of wall time and the skill relayed it as dead provider
# infrastructure. Three separate defects made that misdiagnosis possible and each has a case
# below: no hard kill, no whole-run ceiling, and one exit code for three different causes.
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"
# Keep run rows, saved inputs and failure evidence out of the real ~/.zuvo.
export ZUVO_HOME="$ADV_TEST_HOME/zuvo-home"
mkdir -p "$ZUVO_HOME"

# ─── 1: a TERM-ignoring provider is still killed at the budget ────────────────

start_test "HT.1 SIGTERM-ignoring provider is SIGKILLed, run stays inside the budget"
t0=$(date +%s)
ZUVO_REVIEW_TEST_PROVIDERS="mock-term-ignoring" \
ZUVO_REVIEW_TIMEOUT=2 \
ZUVO_TIMEOUT_GRACE=2 \
  bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - t0 ))
assert_exit_code "124" "$rc" "exit 124 (timed out, not hung)"
if [[ "$elapsed" -le 30 ]]; then
  pass "returned in ${elapsed}s (budget 2s + 2s grace)"
else
  fail "returned in ${elapsed}s" "hard kill did not fire; plain timeout only sends SIGTERM"
fi

# ─── 2: the caller is not held open by the watchdog ───────────────────────────
# A command substitution does not return until every process holding the pipe closes it.
# Skills invoke this script as out=$(...), so a watchdog inheriting stdout would block the
# caller for the whole deadline even after the review finished.

start_test "HT.2 command substitution returns as soon as the review does"
t0=$(date +%s)
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --json --files "$EMPTY" 2>/dev/null)
elapsed=$(( $(date +%s) - t0 ))
assert_contains "$out" '"status"' "produced JSON"
if [[ "$elapsed" -le 20 ]]; then
  pass "caller unblocked in ${elapsed}s"
else
  fail "caller blocked ${elapsed}s" "a background helper is holding the caller's stdout open"
fi

# ─── 3: whole-run deadline is a real ceiling ──────────────────────────────────

start_test "HT.3 ZUVO_RUN_DEADLINE bounds a wedged run → exit 124"
t0=$(date +%s)
ZUVO_REVIEW_TEST_PROVIDERS="mock-hang" \
ZUVO_REVIEW_TIMEOUT=600 \
ZUVO_RUN_DEADLINE=5 \
  bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1
rc=$?
elapsed=$(( $(date +%s) - t0 ))
assert_exit_code "124" "$rc" "deadline reports timeout, not SIGTERM (143)"
if [[ "$elapsed" -le 40 ]]; then
  pass "deadline fired after ${elapsed}s (limit 5s, provider budget 600s)"
else
  fail "ran ${elapsed}s" "whole-run deadline did not fire"
fi

# ─── 4: host suspension is its own status, not a provider fault ───────────────
# ZUVO_SUSPEND_THRESHOLD=0 makes any measured drift count, which exercises the branch without
# actually sleeping the machine.

start_test "HT.4 suspension → exit 125, status=suspended, retryable=true"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" \
      ZUVO_SUSPEND_THRESHOLD=0 \
      bash "$ADV" --json --files "$EMPTY" 2>/dev/null)
rc=$?
assert_exit_code "125" "$rc" "exit 125 (distinct from 2 = provider error)"
assert_eq "suspended" "$(echo "$out" | jq -r '.status' 2>/dev/null)" "status"
assert_eq "true"      "$(echo "$out" | jq -r '.retryable' 2>/dev/null)" "retryable"

start_test "HT.4b sequential dispatch of N slow providers is NOT 'suspended' without a monotonic clock"
# Regression for the review of b45603e..26299e4. suspended_seconds()'s no-python3 fallback used to
# be measured against ONE provider's budget, so --single walking three genuinely-timed-out
# candidates (a legitimate N × budget) was reported as `suspended … safe to repeat` — a false free
# retry, in exactly the no-python3 environment this release's Windows work targets.
STUB_PATH="$ADV_TEST_HOME/nopy-bin"
mkdir -p "$STUB_PATH"
# Every external binary the script may reach BEFORE dispatch has to be here, or the run dies
# with 127 and empty output and the assertions below report the wrong cause. `chmod` was missing
# from this list once the run-scoped cache dir started hardening its own permissions — the test
# then failed permanently on a 127 that looks nothing like the timeout/suspend behaviour it is
# actually asserting. Add to this list when the script gains a new pre-dispatch dependency.
for b in bash sh env timeout cat date grep sed awk wc tr head tail mkdir rm cp ls find jq \
         printf sleep pgrep pkill kill git dirname basename id mktemp shasum sort uniq cut \
         chmod; do
  p=$(command -v "$b" 2>/dev/null) && ln -sf "$p" "$STUB_PATH/$b" 2>/dev/null
done
ln -sf "$MOCKS/mock-hang" "$STUB_PATH/mock-hang" 2>/dev/null
if [[ -n "$(PATH="$STUB_PATH" command -v python3 2>/dev/null)" ]]; then
  fail "stub PATH still exposes python3" "cannot exercise the no-monotonic-clock fallback"
else
  out=$(PATH="$STUB_PATH" ZUVO_HOME="$ADV_TEST_HOME/nopy-home" \
        ZUVO_REVIEW_TEST_PROVIDERS="mock-hang mock-hang mock-hang" \
        ZUVO_REVIEW_TIMEOUT=8 ZUVO_TIMEOUT_GRACE=2 \
        bash "$ADV" --single --json --files "$EMPTY" 2>/dev/null)
  rc=$?
  assert_exit_code "124" "$rc" "exit 124 (timeout), not 125 (suspended)"
  assert_eq "timeout" "$(echo "$out" | jq -r '.status' 2>/dev/null)" "status"
  assert_eq "0" "$(echo "$out" | jq -r '.suspended_seconds' 2>/dev/null)" "suspended_seconds stays 0"
fi

start_test "HT.5 genuine provider failure stays exit 2, not retryable"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" bash "$ADV" --json --files "$EMPTY" 2>/dev/null)
rc=$?
assert_exit_code "2" "$rc" "exit 2 (all providers reached and failed)"
assert_eq "error" "$(echo "$out" | jq -r '.status' 2>/dev/null)" "status"
assert_eq "false" "$(echo "$out" | jq -r '.retryable' 2>/dev/null)" "retryable"

# ─── 5: provider stderr survives an all-fail run ──────────────────────────────

start_test "HT.6 all-fail run keeps provider stderr for diagnosis"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" bash "$ADV" --json --files "$EMPTY" 2>/dev/null)
evidence=$(echo "$out" | jq -r '.evidence_dir // ""' 2>/dev/null)
if [[ -n "$evidence" && -d "$evidence" && -f "$evidence/meta.txt" ]]; then
  pass "evidence kept at $evidence"
  rm -rf "$evidence"
else
  fail "no evidence directory" "cleanup deleted the tmpdir with every provider's stderr"
fi

# ─── 6: the run log distinguishes not-attempted from failed ───────────────────
# --single stops at the first success. The remaining candidates were never asked, and logging
# them as exit=1 with zero bytes is what made a healthy day read as a mass provider outage.

start_test "HT.7 --single logs unreached candidates as not-attempted"
TEST_LOG="$ADV_TEST_HOME/test-hard-timeout.log"
: > "$TEST_LOG"
ZUVO_ADVERSARIAL_LOG_FILE="$TEST_LOG" \
ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
  bash "$ADV" --single --json --files "$EMPTY" >/dev/null 2>&1
row=$(grep -v '^SUMMARY' "$TEST_LOG" | grep 'mock-fail' | tail -1)
assert_eq "16" "$(echo "$row" | awk -F'\t' '{print NF}')" "row has the widened 16 columns"
assert_eq "mock-fail"     "$(echo "$row" | awk -F'\t' '{print $14}')" "provider column names the provider"
assert_eq "not-attempted" "$(echo "$row" | awk -F'\t' '{print $15}')" "outcome column (never dispatched)"
ok_row=$(grep -v '^SUMMARY' "$TEST_LOG" | grep 'mock-success' | tail -1)
assert_eq "ok" "$(echo "$ok_row" | awk -F'\t' '{print $15}')" "outcome column for the provider that answered"

start_test "HT.8 --single success is status=ok, not partial"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-fail" \
      bash "$ADV" --single --json --files "$EMPTY" 2>/dev/null)
assert_eq "ok" "$(echo "$out" | jq -r '.status' 2>/dev/null)" "status (first-success is the contract, not a shortfall)"
assert_eq "1"  "$(echo "$out" | jq -r '.dispatched_count' 2>/dev/null)" "dispatched_count"
assert_eq "2"  "$(echo "$out" | jq -r '.attempted_count' 2>/dev/null)" "attempted_count still counts candidates"
