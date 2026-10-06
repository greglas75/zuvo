#!/usr/bin/env bash
# test-d1-no-retry.sh — D1: retry block removed; first timeout is final timeout.
# Asserts that an all-timeout run exits 124 having dispatched the lane ONCE, with the outcome `timeout`
# (a retry would dispatch it twice — counted, not inferred from a wall-clock window).
# D1.5-D1.7: where a hard kill (137) stops counting as a timeout — the 2 s slack of dispatch_provider —
# driven on a fake clock, so no verdict waits on real time near the boundary.

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
# The other half of the pair (dispatch.sh:383-391, record_provider_failure_outcome): the lane that timed out
# is recorded as exactly that, once, and contributes nothing to the results.
assert_eq "mock-timeout:timeout" \
  "$(echo "$out" | jq -r '.provider_outcomes | split(",") | map(select(startswith("mock-timeout:"))) | join(",")' 2>/dev/null)" \
  "mock-timeout's outcome is timeout, recorded once"
assert_eq "false" "$(echo "$out" | jq -r '.results | has("mock-timeout")' 2>/dev/null)" "the timed-out lane is absent from .results"
assert_eq "1" "$(echo "$out" | jq -r '.timeout_count' 2>/dev/null)" "one lane counted as timed out"

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

# ─── Case 2c: the 2 s KILL slack (dispatch.sh:124-130), on a fake clock ──────────
# A 137 is remapped to 124 only when the lane used its budget: d_elapsed >= PROVIDER_TIMEOUT -
# KILL_ROUNDING_SLACK_SECONDS (2), or >= the whole budget when that is 2 s or less. Driven without a real
# wait: a fake `timeout` stands in for GNU timeout's hard kill of the lane `mock-killed-late` — it moves a
# fake clock on by D1_KILL_AFTER seconds and exits 137 — and a fake `date` answers `date +%s` from that
# clock, so d_elapsed is exactly D1_KILL_AFTER. Every other timeout/date call is the real one.
D1_REAL_DATE="$(command -v date)"; D1_REAL_TIMEOUT="$(command -v timeout)"
export D1_REAL_DATE D1_REAL_TIMEOUT
mkdir -p "$D1_HOME/clockbin"
cat > "$D1_HOME/clockbin/timeout" <<'EOF'
#!/bin/sh
for last in "$@"; do :; done
if [ -n "${D1_CLOCK:-}" ] && [ "${last:-}" = mock-killed-late ]; then
  cat > /dev/null
  echo $(( $(cat "$D1_CLOCK") + ${D1_KILL_AFTER:?} )) > "$D1_CLOCK"
  echo call >> "$D1_CLOCK.calls"
  exit 137
fi
exec "$D1_REAL_TIMEOUT" "$@"
EOF
cat > "$D1_HOME/clockbin/date" <<'EOF'
#!/bin/sh
if [ -n "${D1_CLOCK:-}" ] && [ "$#" -eq 1 ] && [ "$1" = +%s ]; then cat "$D1_CLOCK"; exit 0; fi
exec "$D1_REAL_DATE" "$@"
EOF
# The lane itself: run_mock needs it on PATH; the fake timeout never starts it.
printf '#!/bin/sh\ncat > /dev/null\necho "mock-killed-late ran: the fake timeout did not intercept it"\n' > "$D1_HOME/clockbin/mock-killed-late"
chmod +x "$D1_HOME/clockbin/timeout" "$D1_HOME/clockbin/date" "$D1_HOME/clockbin/mock-killed-late"
# killed_at <tag> <ZUVO_REVIEW_TIMEOUT> <seconds before the kill> — one mock-killed-late run, its own ZUVO_HOME,
# the clock starting at the real time now. JSON on stdout, the driver's stderr in $D1_HOME/<tag>.err.
killed_at() {
  mkdir -p "$D1_HOME/$1"; "$D1_REAL_DATE" +%s > "$D1_HOME/$1/clock"; rm -f "$D1_HOME/$1/clock.calls"
  ZUVO_HOME="$D1_HOME/$1/zuvo" ZUVO_REVIEW_TEST_PROVIDERS=mock-killed-late ZUVO_REVIEW_TIMEOUT="$2" \
    D1_KILL_AFTER="$3" D1_CLOCK="$D1_HOME/$1/clock" PATH="$D1_HOME/clockbin:$PATH" \
    bash "$ADV" --json --files "$EMPTY" 2>"$D1_HOME/$1.err"
}
kill_calls() { if [ -f "$D1_HOME/$1/clock.calls" ]; then wc -l < "$D1_HOME/$1/clock.calls" | tr -d ' '; else echo 0; fi; }

start_test "D1.5 a hard kill 2 s short of a 30 s budget is still a timeout (inside the rounding slack)"
out=$(killed_at k28 30 28); ec=$?
assert_eq "1" "$(kill_calls k28)" "premise: the fake timeout ended the lane, once"
assert_exit_code "124" "$ec" "28 s of 30: exit 124"
assert_eq "mock-killed-late:timeout" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "28 s of 30: the outcome is timeout"
assert_eq "" "$(grep -F 'SIGKILLed after' "$D1_HOME/k28.err")" "28 s of 30: no early-kill WARN"

start_test "D1.6 a hard kill 3 s short of a 30 s budget is a kill, not a timeout (outside the slack)"
out=$(killed_at k27 30 27); ec=$?
assert_eq "1" "$(kill_calls k27)" "premise: the fake timeout ended the lane, once"
assert_exit_code "2" "$ec" "27 s of 30: exit 2, not 124"
assert_eq "mock-killed-late:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "27 s of 30: the outcome is a failure (empty)"
assert_contains "$(cat "$D1_HOME/k27.err")" "mock-killed-late was SIGKILLed after 27s, well inside its 30s budget — not a timeout" \
  "27 s of 30: the WARN names the elapsed time and the budget"

start_test "D1.7 a budget of 2 s or less gets no slack: only the whole budget counts as a timeout"
# The other arm of :125's ternary: PROVIDER_TIMEOUT > 2 is false, so the threshold is the budget itself — not
# 0, which would turn every SIGKILL of a short-budget lane into a "timeout".
out=$(killed_at k1of2 2 1); ec=$?
assert_eq "1" "$(kill_calls k1of2)" "premise: the fake timeout ended the lane, once"
assert_exit_code "2" "$ec" "1 s of 2: exit 2"
assert_eq "mock-killed-late:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "1 s of 2: a kill, not a timeout"
assert_contains "$(cat "$D1_HOME/k1of2.err")" "mock-killed-late was SIGKILLed after 1s, well inside its 2s budget" "1 s of 2: the early-kill WARN"
out=$(killed_at k2of2 2 2); ec=$?
assert_exit_code "124" "$ec" "2 s of 2: exit 124"
assert_eq "mock-killed-late:timeout" "$(printf '%s' "$out" | jq -r '.provider_outcomes' 2>/dev/null)" "2 s of 2: a timeout"

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
