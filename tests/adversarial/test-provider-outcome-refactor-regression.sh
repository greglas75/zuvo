#!/usr/bin/env bash
# test-provider-outcome-refactor-regression.sh — how a lane's answer becomes its outcome, in both collection
# loops (scripts/lib/adversarial-dispatch.sh): the outcome recorder (record_provider_failure_outcome), the
# auth-stub exclusion (exclude_auth_stub), the empty-answer test (result_has_text) and the no-runner path.
# The lane outcomes in provider_outcomes, the counts and the credited lanes are what an artifact gate reads.
# Every case is self-contained: its own ZUVO_HOME, its own mock lanes on its own PATH entry.
ADV="${ADV_OVERRIDE:-$ROOT/scripts/adversarial-review.sh}"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$HERE/mocks:$PATH"
OUTCOME_HOME="$(mktemp -d "$ADV_TEST_HOME/outcome-regression.XXXXXX")"
trap 'rm -rf "$OUTCOME_HOME"' EXIT
# home_for <case> — that case's own ZUVO_HOME. One home shared by every case made them order-dependent: a
# lane's failure recorded in one case's provider-health ledger could bench it in the next.
home_for() { mkdir -p "$OUTCOME_HOME/home-$1" && printf '%s' "$OUTCOME_HOME/home-$1"; }
# bin_for <case> — that case's own directory of mock lanes, put first on PATH by the case's run only, so no
# case depends on another having made its mock first.
bin_for() { mkdir -p "$OUTCOME_HOME/bin-$1" && printf '%s' "$OUTCOME_HOME/bin-$1"; }
# mock_lane <bin> <name> <body> — an executable lane <name> in <bin> that reads its prompt, appends its name
# to $OC_TRACE (when set: proof it was invoked) and then runs <body>.
mock_lane() {
  printf '#!/usr/bin/env bash\ncat > /dev/null\n[[ -z "${OC_TRACE:-}" ]] || printf "%%s\\n" "%s" >> "$OC_TRACE"\n%s\n' "$2" "$3" > "$1/$2"
  chmod +x "$1/$2"
}
# OC_LANE_BUDGET — ZUVO_REVIEW_TIMEOUT where one lane must TIME OUT (it hangs far past this) while another
# must ANSWER inside it, even when a loaded farm host starts it late. The answering mock is instant; the
# budget is margin, not a race.
OC_LANE_BUDGET=5
outcomes_of() { printf '%s' "$1" | jq -r '.provider_outcomes' 2>/dev/null; }   # outcomes_of <json>

start_test "OC.5 multi mode retains the original duplicate-timeout record"
out=$(ZUVO_HOME="$(home_for oc5)" ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout mock-timeout mock-success" ZUVO_REVIEW_TIMEOUT="$OC_LANE_BUDGET" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the successful lane still answers"
assert_eq "mock-timeout:timeout,mock-timeout:timeout,mock-success:ok" \
  "$(outcomes_of "$out")" "parallel timeout remains unconditional"

start_test "OC.6 multi mode does not reclassify an auth stub"
oc6_bin="$(bin_for oc6)"; mock_lane "$oc6_bin" mock-authstub "echo 'Error: Not logged in. Please run /login'"
out=$(PATH="$oc6_bin:$PATH" ZUVO_HOME="$(home_for oc6)" ZUVO_RUN_ID="oc6-$$" ZUVO_REVIEW_TEST_PROVIDERS="mock-authstub mock-success" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the real review remains available"
assert_eq "mock-authstub:auth,mock-success:ok" \
  "$(outcomes_of "$out")" "auth has exactly one outcome"

start_test "OC.7 single mode skips an auth stub before a real review — and stops at that review"
# --single walks its lanes in order and stops at the FIRST real answer (dispatch.sh:436-460): the auth stub
# is skipped (exclude_auth_stub, :202-209), mock-success answers, and the lane after it is never asked.
oc7_bin="$(bin_for oc7)"
mock_lane "$oc7_bin" mock-authstub "echo 'Error: Not logged in. Please run /login'"
mock_lane "$oc7_bin" mock-answers 'echo "{\"findings\":[]}"'
mock_lane "$oc7_bin" mock-after "echo 'should never be asked'"
: > "$OUTCOME_HOME/trace-oc7"
out=$(PATH="$oc7_bin:$PATH" OC_TRACE="$OUTCOME_HOME/trace-oc7" ZUVO_HOME="$(home_for oc7)" ZUVO_RUN_ID="oc7-$$" \
  ZUVO_REVIEW_TEST_PROVIDERS="mock-authstub mock-answers mock-after" \
  bash "$ADV" --single --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the real review remains available"
assert_eq "mock-authstub:auth,mock-answers:ok" \
  "$(outcomes_of "$out")" "auth has exactly one outcome"
assert_eq "mock-authstub mock-answers" "$(tr '\n' ' ' < "$OUTCOME_HOME/trace-oc7" | sed 's/ $//')" \
  "the stub and the answering lane were each invoked once, in order — the lane after the answer never was"
assert_eq "2" "$(printf '%s' "$out" | jq -r '.dispatched_count' 2>/dev/null)" "dispatched_count counts the two lanes asked"

start_test "OC.8 multi mode rejects output from a failing process"
oc8_bin="$(bin_for oc8)"
mock_lane "$oc8_bin" mock-nonzero-body "echo 'UNTRUSTED_REVIEW_BODY_927'
printf 'x%.0s' {1..700}
exit 1"
out=$(PATH="$oc8_bin:$PATH" ZUVO_HOME="$(home_for oc8)" ZUVO_REVIEW_TEST_PROVIDERS="mock-nonzero-body mock-success" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "a healthy second lane still answers"
assert_eq "mock-nonzero-body:empty,mock-success:ok" \
  "$(outcomes_of "$out")" "the failed lane is not successful"
assert_eq "null" "$(printf '%s' "$out" | jq -r '.results["mock-nonzero-body"] // "null"')" "failed body is excluded"
if [[ "$out" == *UNTRUSTED_REVIEW_BODY_927* ]]; then
  fail "failed body is absent from every JSON field"
else
  pass "failed body is absent from every JSON field"
fi
assert_eq "1" "$(printf '%s' "$out" | jq -r '.provider_count')" "only the healthy lane is counted"
assert_eq "mock-success" "$(printf '%s' "$out" | jq -r '.providers_used')" "only the healthy lane is credited"
assert_eq "partial" "$(printf '%s' "$out" | jq -r '.status')" "a failed lane makes the run partial"

start_test "OC.9 multi mode discards a timed-out partial response"
oc9_bin="$(bin_for oc9)"
# Prints part of an answer, then hangs far past OC_LANE_BUDGET and the kill grace: a timeout; bounded if the
# kill ever misses.
mock_lane "$oc9_bin" mock-timeout-with-body "echo 'UNTRUSTED_PARTIAL_TIMEOUT_927'
printf 'x%.0s' {1..700}
sleep 60"
out=$(PATH="$oc9_bin:$PATH" ZUVO_HOME="$(home_for oc9)" ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout-with-body mock-success" ZUVO_REVIEW_TIMEOUT="$OC_LANE_BUDGET" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the healthy lane still answers"
assert_eq "mock-timeout-with-body:timeout,mock-success:ok" \
  "$(outcomes_of "$out")" "partial output does not override timeout"
assert_eq "1" "$(printf '%s' "$out" | jq -r '.timeout_count')" "timed-out lane is counted"
if [[ "$out" == *UNTRUSTED_PARTIAL_TIMEOUT_927* ]]; then
  fail "timed-out body is absent from every JSON field"
else
  pass "timed-out body is absent from every JSON field"
fi

mkdir -p "$OUTCOME_HOME/no-runner-bin" "$OUTCOME_HOME/no-runner-home"
. "$ROOT/tests/lib/adversarial-driver.sh"
# The driver with its own modules (scripts/lib/adversarial-*.sh) but no shared runner beside it.
start_test "OC.10 premise: a driver copy with its modules and without the shared runner"
if adv_driver_copy "$ADV" "$OUTCOME_HOME/no-runner-bin/adversarial-review.sh" \
   && [ ! -e "$OUTCOME_HOME/no-runner-bin/lib/model-subprocess.sh" ] && [ ! -e "$OUTCOME_HOME/no-runner-bin/model-subprocess.sh" ]; then
  pass "modules copied, model-subprocess.sh absent"
else
  fail "the copy is not the scenario: adv_driver_copy failed, or it brought model-subprocess.sh along"
fi
start_test "OC.10 missing shared runner is not a provider failure"
out=$(HOME="$OUTCOME_HOME/no-runner-home" ZUVO_HOME="$OUTCOME_HOME/no-runner-home/zuvo" \
  ZUVO_RUN_ID="oc10-$$" ZUVO_REVIEW_TEST_PROVIDERS="codex-5.3 claude" \
  bash "$OUTCOME_HOME/no-runner-bin/adversarial-review.sh" --multi --json --files "$ADV_TEST_EMPTY" 2>"$OUTCOME_HOME/oc10.err"); rc=$?
# Exit 2 is also the module loader's refusal: this case is about the RUNNER, so the run must get past it.
# Shown positively, not by the refusal's absence (which a driver that never ran satisfies too): the
# bootstrap's one warning names the missing runner, and the reason note comes from the report phase — a
# module, so the modules loaded and the run went all the way through them.
if grep -q 'adversarial-review cannot run' "$OUTCOME_HOME/oc10.err"; then
  fail "the run stopped at the module loader, not at the missing runner" "$(head -c 300 "$OUTCOME_HOME/oc10.err")"
else
  pass "the module loader did not refuse"
fi
assert_eq "1" "$(grep -c 'model-subprocess.sh (the shared codex/claude runner) not loaded' "$OUTCOME_HOME/oc10.err")" \
  "the bootstrap warns ONCE that the shared runner is missing"
assert_contains "$(cat "$OUTCOME_HOME/oc10.err")" "no lane could run — the shared runner model-subprocess.sh was not loaded" \
  "the report phase (a module) names the missing runner as the reason"
assert_exit_code "2" "$rc" "neither lane could start"
assert_eq "codex-5.3:no-runner,claude:no-runner" \
  "$(outcomes_of "$out")" "missing runner never counts as empty output"
assert_eq "0" "$(printf '%s' "$out" | jq -r '.provider_count')" "no review is counted"

start_test "OC.11 an exit-0 answer of only whitespace is 'empty', never a review (multi and single)"
# result_has_text (dispatch.sh:213-216): a lane that printed only blank lines exited 0 with a non-empty
# result file and was recorded `ok` — a review with zero findings, and a REVIEW BY: in the artifact the push
# gate reads, for an answer that said nothing.
oc11_bin="$(bin_for oc11)"
mock_lane "$oc11_bin" mock-blank "printf '   \\n\\n\\t\\n  \\n'
exit 0"
out=$(PATH="$oc11_bin:$PATH" ZUVO_HOME="$(home_for oc11)" ZUVO_REVIEW_TEST_PROVIDERS="mock-blank mock-success" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "multi: the real review still answers"
assert_eq "mock-blank:empty,mock-success:ok" "$(outcomes_of "$out")" "multi: the blank answer is recorded empty"
assert_eq "1 mock-success partial" "$(printf '%s' "$out" | jq -r '"\(.provider_count) \(.providers_used) \(.status)"' 2>/dev/null)" \
  "multi: only the real review is counted and credited; the run is partial"
out=$(PATH="$oc11_bin:$PATH" ZUVO_HOME="$(home_for oc11s)" ZUVO_REVIEW_TEST_PROVIDERS="mock-blank mock-success" \
  bash "$ADV" --single --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "single: the walk goes on to the real review"
assert_eq "mock-blank:empty,mock-success:ok" "$(outcomes_of "$out")" "single: the blank answer does not stop the walk as a success"
assert_eq "mock-success" "$(printf '%s' "$out" | jq -r '.providers_used' 2>/dev/null)" "single: only the real review is credited"

start_test "OC.12 a lane with no API key is 'no-key', never 'empty', and the walk goes on past it (multi and single)"
# lane_no_key (lanes-http.sh:59-66) leaves the nokey_<lane> marker, and record_provider_failure_outcome
# (dispatch.sh:219-235) reads it after the timeout and no-runner arms (:228): `no-key`, which the provider-health
# ledger does not count. Recorded `empty`, a lane that never ran read as a reviewer that failed. codestral with
# CODESTRAL_API_KEY empty (lanes-http.sh:70) beside a mock lane that answers; the mock logs each call.
oc12_bin="$(bin_for oc12)"; mock_lane "$oc12_bin" mock-answers 'echo "{\"findings\":[]}"'
for oc12_mode in --multi --single; do
  : > "$OUTCOME_HOME/trace-oc12$oc12_mode"
  out=$(PATH="$oc12_bin:$PATH" OC_TRACE="$OUTCOME_HOME/trace-oc12$oc12_mode" ZUVO_HOME="$(home_for "oc12$oc12_mode")" CODESTRAL_API_KEY='' \
    ZUVO_REVIEW_TEST_PROVIDERS="codestral mock-answers" bash "$ADV" "$oc12_mode" --json --files "$ADV_TEST_EMPTY" 2>"$OUTCOME_HOME/oc12$oc12_mode.err"); rc=$?
  assert_exit_code "0" "$rc" "$oc12_mode: the answering lane's review stands"
  assert_eq "codestral:no-key,mock-answers:ok" "$(outcomes_of "$out")" "$oc12_mode: the keyless lane is no-key, the answer ok, in order"
  if [[ ",$(outcomes_of "$out")," == *",codestral:empty,"* ]]; then
    fail "$oc12_mode: the keyless lane is never recorded empty" "$(outcomes_of "$out")"
  else
    pass "$oc12_mode: the keyless lane is never recorded empty"
  fi
  assert_eq "1 mock-answers null" "$(printf '%s' "$out" | jq -r '"\(.provider_count) \(.providers_used) \(.results.codestral // "null")"' 2>/dev/null)" \
    "$oc12_mode: only the answering lane is counted and credited; the keyless lane has no result"
  assert_eq "mock-answers" "$(tr '\n' ' ' < "$OUTCOME_HOME/trace-oc12$oc12_mode" | sed 's/ $//')" \
    "$oc12_mode: the lane after the keyless one was asked, once"
  assert_eq "2" "$(printf '%s' "$out" | jq -r '.dispatched_count' 2>/dev/null)" "$oc12_mode: both lanes were dispatched"
  assert_contains "$(cat "$OUTCOME_HOME/oc12$oc12_mode.err")" \
    "codestral has no usable API key (CODESTRAL_API_KEY is not set) — not run, and not held against the lane" \
    "$oc12_mode: the run relays the lane's own reason (lane_reason, dispatch.sh:295, :389, :459)"
done
