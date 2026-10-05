#!/usr/bin/env bash
# test-d1-no-retry.sh — D1: retry block removed; first timeout is final timeout.
# Asserts that an all-timeout run exits 124 having dispatched the lane ONCE, with the outcome `timeout`
# (a retry would dispatch it twice — counted, not inferred from a wall-clock window).

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$MOCKS:$PATH"
# A sandboxed HOME and ZUVO_HOME: these runs fail on purpose, and the real ~/.zuvo would collect their run
# rows, failure evidence and provider-health entries.
D1_HOME="$(mktemp -d "$ADV_TEST_HOME/d1.XXXXXX")"
trap 'rm -rf "$D1_HOME"' EXIT
mkdir -p "$D1_HOME/bin" "$D1_HOME/zuvo"
export HOME="$D1_HOME" ZUVO_HOME="$D1_HOME/zuvo"
# mock-timeout-counted — mock-timeout that also counts its invocations, as the sleeper itself (exec).
cat > "$D1_HOME/bin/mock-timeout-counted" <<EOF
#!/bin/sh
echo call >> "$D1_HOME/timeout.calls"
cat > /dev/null
exec sleep 300
EOF
# mock-sigkilled — dies of SIGKILL at once: what an OOM killer or a `kill -9` does to a client.
cat > "$D1_HOME/bin/mock-sigkilled" <<'EOF'
#!/bin/sh
cat > /dev/null
kill -KILL $$
EOF
chmod +x "$D1_HOME/bin/mock-timeout-counted" "$D1_HOME/bin/mock-sigkilled"
export PATH="$D1_HOME/bin:$PATH"

# ─── Case 1 (AC1): single-provider timeout → exit 124, dispatched once ─────

start_test "D1.1 AC1 single-timeout → exit 124, the lane dispatched once, outcome timeout"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout-counted" ZUVO_REVIEW_TIMEOUT=2 \
  bash "$ADV" --json --files "$EMPTY" 2>/dev/null)
ec=$?
assert_exit_code "124" "$ec"           "exit code (AC1)"
assert_eq "mock-timeout-counted:timeout" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "the outcome is timeout"
assert_eq "1" "$(grep -c . "$D1_HOME/timeout.calls" 2>/dev/null || echo 0)" "the timed-out lane was dispatched once (no retry)"

# ─── Case 2 (AC2): mixed succ+timeout → exit 0, partial status, succeeded result kept ─

start_test "D1.2 AC2 mixed succ+timeout → exit 0, status=partial, succeeded result present"
out=$(ZUVO_REVIEW_TEST_PROVIDERS="mock-success mock-timeout" ZUVO_REVIEW_TIMEOUT=2 MOCK_HANG_SECONDS=30 \
  bash "$ADV" --multi --json --files "$EMPTY" 2>/dev/null)
ec=$?
status=$(echo "$out" | jq -r '.status' 2>/dev/null)
if echo "$out" | jq -e '.results | keys | contains(["mock-success"])' >/dev/null 2>&1; then has_succ=yes; else has_succ=no; fi
assert_exit_code "0"        "$ec"        "exit code (AC2 keeps results)"
assert_eq        "partial"  "$status"    "status (AC2)"
assert_eq        "yes"      "$has_succ"  "mock-success result preserved"

# ─── Case 2b: a SIGKILL well inside the budget is NOT a timeout ───────────
# `timeout` exits 137 both when its hard kill ends a lane that ignored TERM (a timeout) and when something
# else SIGKILLs the client early (OOM, kill -9). Only the first is remapped to 124: an early kill stays a
# failure, with a WARN that says so, instead of sending the reader after a slowness that is not there.

start_test "D1.4 an early SIGKILL is a failure, not a timeout"
out=$(ZUVO_HOME="$D1_HOME/zuvo-d14" ZUVO_REVIEW_TEST_PROVIDERS="mock-sigkilled" ZUVO_REVIEW_TIMEOUT=30 \
  bash "$ADV" --json --files "$EMPTY" 2>"$D1_HOME/d14.err")
ec=$?
assert_exit_code "2" "$ec" "no review, and not exit 124"
assert_eq "mock-sigkilled:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "the outcome is a failure (empty), not timeout"
# The lane's own WARN is in its stderr, kept as failure evidence (this case's own ZUVO_HOME holds that one
# run); the driver repeats it on its line about the lane.
ev="$(ls -d "$D1_HOME/zuvo-d14"/adversarial-failures/*/ 2>/dev/null)"
assert_contains "$(cat "${ev%/}/provider_mock-sigkilled.stderr" 2>/dev/null)" \
  "WARN: mock-sigkilled was SIGKILLed after" "the lane's WARN names the early SIGKILL"
assert_contains "$(cat "$D1_HOME/d14.err")" "mock-sigkilled was SIGKILLed after" "…the driver's line on the lane repeats it"
assert_contains "$(cat "$D1_HOME/d14.err")" "well inside its 30s budget — not a timeout" "…and says it is not a timeout"

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
