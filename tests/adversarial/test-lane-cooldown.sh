# test-lane-cooldown.sh — the lane cooldown (ar_lane_cooldown, scripts/lib/adversarial-providers.sh): a lane in a
# dead state is skipped instead of costing a PROVIDER_TIMEOUT per review, and comes back through a cheap canary.
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
MOCKS="$HERE/mocks"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

LC="$ADV_TEST_HOME/lane-cooldown.$$"
rm -rf "$LC"; mkdir -p "$LC/bin" "$LC/home"
HF="$LC/health.tsv"; LOG="$LC/adversarial.log"; ERR="$LC/err"; CALLS="$LC/calls"

# Test lanes. mock-lc-flaky answers the canary and nothing else; mock-lc-slowprobe answers the canary after 2 s and
# notes every call in $CALLS; mock-lc-toolong refuses the input the way an API over its context window does.
cat > "$LC/bin/mock-lc-flaky" <<'EOF'
#!/usr/bin/env bash
in="$(cat)"; case "$in" in "Reply with exactly: PROVIDER-OK") echo PROVIDER-OK; exit 0 ;; esac; exit 1
EOF
cat > "$LC/bin/mock-lc-slowprobe" <<EOF
#!/usr/bin/env bash
in="\$(cat)"
case "\$in" in "Reply with exactly: PROVIDER-OK") echo probe >> "$CALLS"; sleep 2; echo PROVIDER-OK; exit 0 ;; esac
echo review >> "$CALLS"; echo '{"findings":[]}'
EOF
cat > "$LC/bin/mock-lc-toolong" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null; echo "  WARN: mock-lc-toolong HTTP 400: This model's maximum context length is 8192 tokens" >&2; exit 1
EOF
chmod +x "$LC/bin"/mock-lc-*

# lc_run <lanes> [VAR=value ...] — one review; stderr in $ERR, status in LC_RC.
lc_run() {
  local lanes="$1"; shift
  env PATH="$LC/bin:$MOCKS:$PATH" ZUVO_HOME="$LC/home" ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_BENCH=1 \
    ZUVO_ADVERSARIAL_LOG_FILE="$LOG" ZUVO_REVIEW_TEST_PROVIDERS="$lanes" ZUVO_REVIEW_TIMEOUT=10 "$@" \
    bash "$ADV" --multi --files "$ADV_TEST_EMPTY" >/dev/null 2>"$ERR"
  LC_RC=$?
}
row() { awk -F'\t' -v l="$1" '$1 == l { print $3, $5 }' "$HF" 2>/dev/null; }      # count + last outcome
logged() { awk -F'\t' -v l="$1" '$14 == l' "$LOG" 2>/dev/null | wc -l | tr -d ' '; }  # run-log rows of a lane
seed() { printf '%b' "$1" > "$HF"; }
NOW=$(date +%s)

start_test "LC.1 two empties in a row put a lane on cooldown; the next run skips it without counting a failure"
: > "$HF"; : > "$LOG"
lc_run "mock-success mock-findings-a mock-fail"; lc_run "mock-success mock-findings-a mock-fail"
assert_eq "2 empty" "$(row mock-fail)" "two empties: count 2"
before="$(logged mock-fail)"
lc_run "mock-success mock-findings-a mock-fail"
assert_exit_code "0" "$LC_RC" "the review ran on the other two lanes"
assert_contains "$(cat "$ERR")" "mock-fail: cooldown until" "the skip says until when"
assert_eq "2 empty" "$(row mock-fail)" "the skip is not a third strike"
assert_eq "$before" "$(logged mock-fail)" "the skip leaves no failure row in the run log"

start_test "LC.2 an expired cooldown re-probes first: a lane that answers the canary runs, and a real answer resets it"
seed "mock-probe-ok\tunknown\t2\t$(( NOW - 1900 ))\tempty\n"
lc_run "mock-success mock-probe-ok"
assert_contains "$(cat "$ERR")" "mock-probe-ok: cooldown over" "the canary was announced"
assert_eq "0 ok" "$(row mock-probe-ok)" "canary answered, review answered: count reset"

start_test "LC.3 a canary that fails puts the lane back on a longer cooldown, with no review call"
seed "mock-fail\tunknown\t2\t$(( NOW - 1900 ))\tempty\n"; : > "$LOG"
lc_run "mock-success mock-fail"
assert_eq "3 empty" "$(row mock-fail)" "the failed canary is one more strike"
assert_contains "$(cat "$ERR")" "re-probe failed" "the skip names the failed re-probe"
assert_eq "0" "$(logged mock-fail)" "the lane was not dispatched to review"
lc_run "mock-success mock-fail" ZUVO_ADV_COOLDOWN_BASE=1000
assert_contains "$(cat "$ERR")" "mock-fail: cooldown until" "3 strikes: the doubled window still holds it"

start_test "LC.4 a canary pass does not reset the count: a lane that then fails its review backs off longer"
seed "mock-lc-flaky\tunknown\t2\t$(( NOW - 1900 ))\tempty\n"
lc_run "mock-success mock-lc-flaky"
assert_eq "3 empty" "$(row mock-lc-flaky)" "canary ok, review empty: 3 strikes, not 1"

start_test "LC.5 concurrent runs re-probe a lane once"
seed "mock-lc-slowprobe\tunknown\t2\t$(( NOW - 1900 ))\tempty\n"; : > "$CALLS"
lc_run "mock-success mock-lc-slowprobe" & p1=$!
lc_run "mock-success mock-lc-slowprobe" & p2=$!
wait "$p1"; wait "$p2"
assert_eq "1" "$(grep -c '^probe$' "$CALLS")" "one canary for two runs"
assert_eq "2" "$(grep -c '^review$' "$CALLS")" "both runs then reviewed with the lane"

start_test "LC.6 an input the lane refuses as too large never cools it"
: > "$HF"; : > "$LOG"
lc_run "mock-success mock-lc-toolong"; lc_run "mock-success mock-lc-toolong"; lc_run "mock-success mock-lc-toolong"
assert_eq "" "$(row mock-lc-toolong)" "no strike recorded"
assert_eq "3" "$(awk -F'\t' '$14 == "mock-lc-toolong" && $15 == "input"' "$LOG" | wc -l | tr -d ' ')" "the run log says input, three times"

start_test "LC.7 when every lane is cooling, all are retried rather than no review at all"
seed "mock-success\tunknown\t5\t$NOW\tempty\nmock-fail\tunknown\t5\t$NOW\tempty\n"
lc_run "mock-success mock-fail"
assert_exit_code "0" "$LC_RC" "the review ran"
assert_contains "$(cat "$ERR")" "every provider is benched" "the fallback said so"

start_test "LC.8 ZUVO_ADV_COOLDOWN_OFF exempts a lane; ZUVO_ADV_NO_COOLDOWN=1 keeps the old 3-strike bench"
seed "mock-fail\tunknown\t2\t$NOW\tempty\n"
lc_run "mock-success mock-fail" ZUVO_ADV_COOLDOWN_OFF=mock-fail
assert_eq "3 empty" "$(row mock-fail)" "the exempt lane was dispatched"
seed "mock-fail\tunknown\t2\t$NOW\tempty\n"
lc_run "mock-success mock-fail" ZUVO_ADV_NO_COOLDOWN=1
assert_eq "3 empty" "$(row mock-fail)" "two strikes do not bench under the old rule"

start_test "LC.9 --doctor lists the cooldowns still standing after its probes"
seed "mock-fail\tunknown\t2\t$NOW\tempty\n"
env PATH="$LC/bin:$MOCKS:$PATH" ZUVO_HOME="$LC/home" ZUVO_PROVIDER_HEALTH_FILE="$HF" ZUVO_PROVIDER_BENCH=1 \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-probe-ok mock-fail" ZUVO_DOCTOR_TIMEOUT=5 bash "$ADV" --doctor > "$LC/doc" 2>&1
assert_contains "$(cat "$LC/doc")" "mock-fail: cooldown until" "the doctor shows the cooling lane"

rm -rf "$LC"
rm -rf "$LC"
