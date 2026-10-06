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

start_test "HT.3b a NEGATIVE ZUVO_RUN_DEADLINE still arms the watchdog, at the computed deadline"
# ar_decimal refuses a negative value by returning its default — and the default used to be "", so
# ZUVO_RUN_DEADLINE=-3600 armed NO watchdog at all: the unbounded run HT.3 exists to rule out. The
# computed deadline is the fallback now — far past what a test can wait for, so the proof is the
# watchdog's own `sleep`: a shim first on PATH logs its argv and execs the real one, and exactly one
# call must carry the deadline. The lane answers after 1 s, so the watchdog's sleep has long started
# (and logged) before the run ends.
HT3B_SHIM="$ADV_TEST_HOME/ht3b-shim"; HT3B_LOG="$ADV_TEST_HOME/ht3b.sleeps"
mkdir -p "$HT3B_SHIM"; : > "$HT3B_LOG"
# Resolved HERE, on its own line: inside the command's prefix assignments below, PATH already names
# the shim, and a shim that resolves to itself re-execs forever.
HT3B_REAL="$(command -v sleep)"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$HT3B_LOG"\nexec "$HT3B_REAL" "$@"\n' > "$HT3B_SHIM/sleep"
chmod +x "$HT3B_SHIM/sleep"
# The armed deadline is read from the watchdog's own `sleep`, never restated from the driver's formula: a
# copy of `timeout + grace + 70` here would pass whatever the driver computes, as long as both agree. What is
# asserted is what the deadline is FOR (the DEADLINE_SLACK_SECONDS comment and ar_arm_deadline,
# adversarial-run.sh):
#   * it never fires before the lane's own timeout + kill grace could — a lane that answers late but
#     inside its own budget is not cut off by the whole-run ceiling;
#   * it is ONE lane window plus a fixed slack — it moves with the lane timeout one for one (two control
#     runs 10 s apart), never N windows;
#   * at the default lane timeout (as the driver itself reports it) it fires inside the callers' own Bash
#     wrappers — 590 s for write-tests, the tightest of them — or a wedged lane ends with the caller's kill
#     and no evidence instead of this run's exit 124.
# ht3b_armed <timeout|""> <grace> -> the longest sleep the run started (the watchdog's), from a clean log.
ht3b_armed() {
  : > "$HT3B_LOG"
  env -u ZUVO_REVIEW_TIMEOUT ${1:+ZUVO_REVIEW_TIMEOUT=$1} PATH="$HT3B_SHIM:$PATH" HT3B_LOG="$HT3B_LOG" HT3B_REAL="$HT3B_REAL" \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" MOCK_HANG_SECONDS=1 ZUVO_TIMEOUT_GRACE="$2" \
    bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1
  awk '/^[0-9]+$/ && $0 + 0 > m { m = $0 + 0 } END { print m + 0 }' "$HT3B_LOG"
}
HT3B_TIMEOUT=7; HT3B_GRACE=2
HT3B_ARMED="$(ht3b_armed "$HT3B_TIMEOUT" "$HT3B_GRACE")"
HT3B_ARMED_LONGER="$(ht3b_armed $(( HT3B_TIMEOUT + 10 )) "$HT3B_GRACE")"
if [[ "$HT3B_ARMED" -gt $(( HT3B_TIMEOUT + HT3B_GRACE )) ]]; then
  pass "premise: the watchdog (${HT3B_ARMED}s) arms past the lane's own timeout + grace ($(( HT3B_TIMEOUT + HT3B_GRACE ))s)"
else
  fail "premise: the watchdog arms past the lane's own timeout + grace" "armed ${HT3B_ARMED}s, lane budget $(( HT3B_TIMEOUT + HT3B_GRACE ))s"
fi
assert_eq "10" "$(( HT3B_ARMED_LONGER - HT3B_ARMED ))" \
  "premise: a lane timeout 10 s longer moves the deadline exactly 10 s (one window plus a fixed slack)"
HT3B_DEFAULT_T="$(env -u ZUVO_REVIEW_TIMEOUT ZUVO_REVIEW_TEST_PROVIDERS="mock-success" bash "$ADV" --dry-run --files "$EMPTY" 2>&1 >/dev/null | sed -n 's/^Timeout: \([0-9][0-9]*\)s$/\1/p' | head -1)"
HT3B_ARMED_DEFAULT="$(ht3b_armed "" 15)"
if [[ -n "$HT3B_DEFAULT_T" && "$HT3B_ARMED_DEFAULT" -gt $(( HT3B_DEFAULT_T + 15 )) && "$HT3B_ARMED_DEFAULT" -lt 590 ]]; then
  pass "at the default lane timeout (${HT3B_DEFAULT_T}s, as --dry-run reports it) the deadline (${HT3B_ARMED_DEFAULT}s) fires inside the callers' 590 s wrapper"
else
  fail "the default deadline fits between the lane budget and the callers' 590 s wrapper" \
    "default timeout=[${HT3B_DEFAULT_T}] armed=${HT3B_ARMED_DEFAULT}s"
fi
: > "$HT3B_LOG"
err=$(PATH="$HT3B_SHIM:$PATH" HT3B_LOG="$HT3B_LOG" HT3B_REAL="$HT3B_REAL" \
      ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" MOCK_HANG_SECONDS=1 \
      ZUVO_REVIEW_TIMEOUT="$HT3B_TIMEOUT" ZUVO_TIMEOUT_GRACE="$HT3B_GRACE" ZUVO_RUN_DEADLINE=-3600 \
      bash "$ADV" --json --files "$EMPTY" 2>&1 >/dev/null)
assert_contains "$err" "is negative — using $HT3B_ARMED" "the WARN names the computed deadline it fell back to"
assert_eq "1" "$(_W="$HT3B_ARMED" awk '$0 == ENVIRON["_W"] { n++ } END { print n + 0 }' "$HT3B_LOG")" \
  "the watchdog was armed: one sleep with the computed deadline $HT3B_ARMED"
assert_eq "0" "$(awk '$0 == "3600" || $0 == "-3600" { n++ } END { print n + 0 }' "$HT3B_LOG")" \
  "no sleep ever ran with the refused value"

start_test "HT.3c ZUVO_RUN_DEADLINE=0 arms NO watchdog; unset or empty arms the computed one"
# ar_arm_deadline (adversarial-run.sh) keeps an explicit 0 ("000" too) through its ar_decimal override, and
# its watchdog gate (`RUN_DEADLINE -gt 0`) then arms no whole-run ceiling; unset or EMPTY (its `-z` test) mean
# the computed deadline. Read from the watchdog's `sleep` through this case's own shim; the lane sleeps once
# for 1 s, any other whole-number sleep is a watchdog.
HT3C_SHIM="$ADV_TEST_HOME/ht3c-shim"; HT3C_LOG="$ADV_TEST_HOME/ht3c.sleeps"; HT3C_REAL="$(command -v sleep)"
mkdir -p "$HT3C_SHIM"
printf '#!/bin/sh\nprintf "%%s\\n" "$*" >> "$HT3C_LOG"\nexec "$HT3C_REAL" "$@"\n' > "$HT3C_SHIM/sleep"
chmod +x "$HT3C_SHIM/sleep"
# ht3c_run <unset|value> -> "<exit code> <every whole-number sleep but the lane's own 1, sorted, comma-joined>"
ht3c_run() {
  local dl=(env -u ZUVO_RUN_DEADLINE) rc=0
  [[ "$1" == unset ]] || dl=(env ZUVO_RUN_DEADLINE="$1")
  : > "$HT3C_LOG"
  "${dl[@]}" PATH="$HT3C_SHIM:$PATH" HT3C_LOG="$HT3C_LOG" HT3C_REAL="$HT3C_REAL" ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout" \
    MOCK_HANG_SECONDS=1 ZUVO_REVIEW_TIMEOUT=7 ZUVO_TIMEOUT_GRACE=2 bash "$ADV" --json --files "$EMPTY" >/dev/null 2>&1 || rc=$?
  printf '%s %s' "$rc" "$(awk '/^[0-9]+$/ && $0 != "1"' "$HT3C_LOG" | sort -n | tr '\n' ',' | sed 's/,$//')"
}
# The lane really slept through the shim — otherwise "no watchdog sleep" below would hold for a shim never run.
ht3c_zero="$(ht3c_run 0)"
assert_eq "1" "$(grep -cx 1 "$HT3C_LOG")" "premise: the shim saw the lane's own 1 s sleep"
assert_eq "0 " "$ht3c_zero" "ZUVO_RUN_DEADLINE=0: the review completes (exit 0) and no watchdog sleep ever started (ar_arm_deadline)"
assert_eq "0 " "$(ht3c_run 000)" "ZUVO_RUN_DEADLINE=000 is 0 (leading zeros stripped, ar_arm_deadline): no watchdog either"
ht3c_unset="$(ht3c_run unset)"
ht3c_armed="${ht3c_unset#* }"
if [[ "$ht3c_armed" =~ ^[0-9]+$ && "$ht3c_armed" -gt 9 ]]; then
  pass "unset: exactly one watchdog sleep, of the computed deadline (${ht3c_armed}s), past the lane's own 7 + 2"
else
  fail "unset: exactly one watchdog sleep, of the computed deadline, past the lane's own 7 + 2" "got [$ht3c_unset]"
fi
assert_eq "0 $ht3c_armed" "$ht3c_unset" "unset: the review completes (exit 0) under that deadline"
assert_eq "0 $ht3c_armed" "$(ht3c_run '')" "an EMPTY value counts as unset (ar_arm_deadline tests -z): the same one computed deadline"
# What no deadline means for --single (the walk-budget check in ar_dispatch_lanes): with none armed there is
# no walk budget (ar_arm_deadline leaves LANE_WALK_BUDGET empty), so a lane after a timed-out one still
# starts — with the computed deadline it does not: T + G - elapsed - G is <= 0 once the first lane has used
# its whole T. No upper time bound decides it.
for ht3c_dl in 0 unset; do
  ht3c_env=(env -u ZUVO_RUN_DEADLINE); [[ "$ht3c_dl" == unset ]] || ht3c_env=(env ZUVO_RUN_DEADLINE="$ht3c_dl")
  ht3c_out="$("${ht3c_env[@]}" ZUVO_HOME="$ADV_TEST_HOME/ht3c-walk-$ht3c_dl" ZUVO_PROVIDER_BENCH=0 \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout mock-success" ZUVO_REVIEW_TIMEOUT=2 ZUVO_TIMEOUT_GRACE=2 \
    bash "$ADV" --single --json --files "$EMPTY" 2>"$ADV_TEST_HOME/ht3c-walk-$ht3c_dl.err")"; ht3c_rc=$?
  ht3c_seen="$ht3c_rc $(printf '%s' "$ht3c_out" | jq -r '"\(.provider_outcomes) \(.dispatched_count)"' 2>/dev/null)"
  ht3c_note="$(grep -cE "^  NOTE: not starting mock-success — -?[0-9]+s left of the run's [0-9]+s\$" "$ADV_TEST_HOME/ht3c-walk-$ht3c_dl.err")"
  if [[ "$ht3c_dl" == 0 ]]; then
    assert_eq "0 mock-timeout:timeout,mock-success:ok 2" "$ht3c_seen" "deadline 0, --single: the lane after the timed-out one still runs and answers"
    assert_eq "0" "$ht3c_note" "…and no lane is held back for want of a budget"
  else
    assert_eq "124 mock-timeout:timeout 1" "$ht3c_seen" "deadline unset, --single: the walk budget is spent, the second lane never starts (exit 124)"
    assert_eq "1" "$ht3c_note" "…and the run says so, once (ar_dispatch_lanes)"
  fi
done

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
  # type -P, not command -v: for a builtin (printf, kill) command -v prints the bare name, and the link then
  # points at itself — a loop that breaks anything that later copies this directory.
  p=$(type -P "$b" 2>/dev/null) && ln -sf "$p" "$STUB_PATH/$b" 2>/dev/null
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

# ─── 4c-4e: the measured sleep, on clocks the case sets ──────────────────────
# suspended_seconds (adversarial-run.sh) measures the sleep as wall time less monotonic time, both read in
# whole seconds; ar_report_no_review classes the run `suspended` when that reaches ZUVO_SUSPEND_THRESHOLD.
# A real run makes both readings a second either way, so these cases set the clocks: the shims below put a
# `python3` and a `date` on PATH that answer the driver's monotonic reading and its `date +%s` with the
# case's values — the first reading of each is the run's start, every later one its end — and pass every
# other call to the real tool. No case here sleeps.
HT_REAL_PY="$(command -v python3)"; HT_REAL_DATE="$(command -v date)"
HT_SHIM="$ADV_TEST_HOME/clock-shim"; mkdir -p "$HT_SHIM"
cat > "$HT_SHIM/python3" <<'SHIM'
#!/bin/sh
if [ "$#" -eq 2 ] && [ "$1" = "-c" ] && [ "$2" = "import time;print(int(time.monotonic()))" ]; then
  if [ -e "$HT_CLOCK_STATE/mono" ]; then echo "$HT_MONO_END"; else : > "$HT_CLOCK_STATE/mono"; echo "$HT_MONO_START"; fi
  exit 0
fi
exec @REAL@ "$@"
SHIM
cat > "$HT_SHIM/date" <<'SHIM'
#!/bin/sh
if [ "$#" -eq 1 ] && [ "$1" = "+%s" ]; then
  if [ -e "$HT_CLOCK_STATE/wall" ]; then echo "$HT_WALL_END"; else : > "$HT_CLOCK_STATE/wall"; echo "$HT_WALL_START"; fi
  exit 0
fi
exec @REAL@ "$@"
SHIM
sed -i.bak "s|@REAL@|$HT_REAL_PY|" "$HT_SHIM/python3"; sed -i.bak "s|@REAL@|$HT_REAL_DATE|" "$HT_SHIM/date"
rm -f "$HT_SHIM"/*.bak; chmod +x "$HT_SHIM/python3" "$HT_SHIM/date"
# ht_clock_run <case> <wall seconds> <monotonic seconds> <threshold> — one all-fail run (mock-fail) whose wall
# clock advances <wall seconds> and monotonic clock <monotonic seconds>. Its JSON goes to HT_OUT, its exit to HT_RC.
ht_clock_run() {
  local st="$ADV_TEST_HOME/clock-$1" t0
  rm -rf "$st"; mkdir -p "$st/home"
  t0=$("$HT_REAL_DATE" +%s)
  HT_RC=0
  PATH="$HT_SHIM:$PATH" HT_CLOCK_STATE="$st" HT_WALL_START="$t0" HT_WALL_END=$(( t0 + $2 )) \
    HT_MONO_START=5000 HT_MONO_END=$(( 5000 + $3 )) ZUVO_HOME="$st/home" ZUVO_SUSPEND_THRESHOLD="$4" \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-fail" bash "$ADV" --json --files "$EMPTY" >"$st/out" 2>"$st/err" || HT_RC=$?
  HT_OUT="$(cat "$st/out")"
}

start_test "HT.4c a measured sleep of exactly ZUVO_SUSPEND_THRESHOLD is classed suspended"
# 40 s of wall time, 10 s of it running: 30 s asleep, and the threshold is 30.
ht_clock_run 4c 40 10 30
assert_exit_code "125" "$HT_RC" "exit 125: a sleep AT the threshold counts"
assert_eq "suspended 30" "$(echo "$HT_OUT" | jq -r '"\(.status) \(.suspended_seconds)"' 2>/dev/null)" \
  "status suspended, suspended_seconds is the wall time less the monotonic time: 30"

start_test "HT.4d a run whose monotonic clock kept pace with the wall clock is not suspended"
# 40 s of wall time, all 40 running: no sleep at all, however long the run.
ht_clock_run 4d 40 40 30
assert_exit_code "2" "$HT_RC" "exit 2: the providers' failure, not a sleep"
assert_eq "error 0" "$(echo "$HT_OUT" | jq -r '"\(.status) \(.suspended_seconds)"' 2>/dev/null)" "status error, suspended_seconds 0"

start_test "HT.4e a monotonic reading a second AHEAD of the wall clock is 0 s asleep, never negative"
# Two whole-second clocks round apart: 40 s of wall time against 41 monotonic is a -1 s "sleep".
ht_clock_run 4e 40 41 30
assert_exit_code "2" "$HT_RC" "exit 2: the providers' failure"
assert_eq "0" "$(echo "$HT_OUT" | jq -r '.suspended_seconds' 2>/dev/null)" "suspended_seconds is clamped to 0"

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
assert_eq "17" "$(echo "$row" | awk -F'\t' '{print NF}')" "row matches the 17-column log schema"
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

# ─── 7: an outside signal is not a timeout ────────────────────────────────────
# ar_install_traps (adversarial-run.sh): INT exits 130 and an outside TERM 143 — only the deadline's own TERM
# (its marker file present) is 124: otherwise a Ctrl-C or an orchestrator's kill reads as "every provider
# timed out" and is retried as one. The lane marks the moment it starts — with its
# pid, as it then becomes the `sleep` (exec) — so each signal lands mid-flight by a handshake, not after a
# guessed delay. `set -m`: a background job of a non-interactive shell IGNORES SIGINT, and a signal
# ignored on entry cannot be trapped — without job control the INT case would test nothing.
HT_SIG="$ADV_TEST_HOME/ht-signals"; rm -rf "$HT_SIG"; mkdir -p "$HT_SIG/bin"
cat > "$HT_SIG/bin/mock-hang-marked" <<'MOCK'
#!/bin/sh
echo "$$" > "$HT_STARTED"
cat > /dev/null
exec sleep 120
MOCK
chmod +x "$HT_SIG/bin/mock-hang-marked"
# ht_signal_run <SIG> -> "<exit code> <lane pid>" of a run sent <SIG> while its lane runs ("never-started"
# when the lane never started; the run is then killed outright).
ht_signal_run() {
  local started="$HT_SIG/started-$1"; rm -f "$started"
  ( set -m
    HT_STARTED="$started" PATH="$HT_SIG/bin:$PATH" ZUVO_HOME="$HT_SIG/home-$1" ZUVO_PROVIDER_BENCH=0 \
      ZUVO_REVIEW_TEST_PROVIDERS="mock-hang-marked" ZUVO_REVIEW_TIMEOUT=120 \
      bash "$ADV" --json --files "$EMPTY" >/dev/null 2>"$HT_SIG/err-$1" &
    p=$!
    for _ in $(seq 1 300); do [ -s "$started" ] && break; sleep 0.1; done
    if [ ! -s "$started" ]; then kill -KILL "$p"; wait "$p"; echo "never-started"; exit 0; fi
    kill -"$1" "$p"
    wait "$p"; echo "$? $(cat "$started")" ) 2>/dev/null
}
# ht_lane_gone <pid> — the lane's process is gone before the poll gives up (cleanup, in adversarial-run.sh,
# TERMs every descendant).
ht_lane_gone() {
  local _
  for _ in $(seq 1 100); do kill -0 "$1" 2>/dev/null || return 0; sleep 0.1; done
  return 1
}

start_test "HT.9 Ctrl-C (INT) ends the run as 130 — never the deadline's 124 or TERM's 143"
read -r ht9_rc ht9_lane <<< "$(ht_signal_run INT)"
assert_exit_code "130" "$ht9_rc" "INT → 130 (ar_install_traps)"
if [[ "$ht9_lane" =~ ^[0-9]+$ ]] && ht_lane_gone "$ht9_lane"; then
  pass "the lane still running at the INT was stopped with the run"
else
  fail "the lane still running at the INT was stopped with the run" "lane pid [$ht9_lane] still alive"
fi

start_test "HT.10 an outside TERM ends the run as 143 — the deadline marker is absent, so never 124"
read -r ht10_rc ht10_lane <<< "$(ht_signal_run TERM)"
assert_exit_code "143" "$ht10_rc" "TERM from outside → 143 (ar_install_traps, no deadline marker)"
if [[ "$ht10_lane" =~ ^[0-9]+$ ]] && ht_lane_gone "$ht10_lane"; then
  pass "the lane still running at the TERM was stopped with the run"
else
  fail "the lane still running at the TERM was stopped with the run" "lane pid [$ht10_lane] still alive"
fi
