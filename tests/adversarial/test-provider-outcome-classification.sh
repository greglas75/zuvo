#!/usr/bin/env bash
# test-provider-outcome-classification.sh — the order and precedence of lane outcomes in provider_outcomes,
# in multi (parallel) and single (walk) mode: record_provider_failure_outcome and the two collection loops in
# scripts/lib/adversarial-dispatch.sh. The auth, no-runner and duplicate-timeout arms are pinned in
# test-provider-outcome-refactor-regression.sh, quota in test-kimi-effort.sh.
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$HERE/mocks:$PATH"
OUTCOME_HOME="$(mktemp -d "$ADV_TEST_HOME/outcomes.XXXXXX")"
trap 'rm -rf "$OUTCOME_HOME"' EXIT
# OC_LANE_BUDGET — ZUVO_REVIEW_TIMEOUT where mock-timeout must TIME OUT (it sleeps 300 s) while mock-success
# must ANSWER inside it. It was 1 s: a loaded farm host that starts the answering lane late then times it
# out too, and the case fails with nothing wrong. mock-success is instant; 5 s is margin, not a race.
OC_LANE_BUDGET=5

# run_oc <case> <dispatch flag> <lanes> [VAR=value ...] — one review of the empty input over <lanes>, in its
# OWN ZUVO_HOME (one shared home let a lane's failure in one case's provider-health ledger bench it in the
# next, so the cases depended on their order) and with each lane's invocation logged in order. Leaves the
# JSON in OC_OUT, the exit code in OC_RC and the invoked lanes, space-separated, in OC_ASKED.
run_oc() {
  local c="$OUTCOME_HOME/$1" mode="$2" lanes="$3" m; shift 3
  mkdir -p "$c/home" "$c/bin"; : > "$c/trace"
  for m in mock-success mock-fail mock-timeout; do   # pass-throughs that log the call, then run the real mock
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "%s" >> "%s"\nexec "%s" "$@"\n' "$m" "$c/trace" "$HERE/mocks/$m" > "$c/bin/$m"
    chmod +x "$c/bin/$m"
  done
  OC_OUT=$(env PATH="$c/bin:$PATH" ZUVO_HOME="$c/home" ZUVO_REVIEW_TEST_PROVIDERS="$lanes" "$@" \
    bash "$ADV" "$mode" --json --files "$ADV_TEST_EMPTY" 2>/dev/null); OC_RC=$?
  OC_ASKED=$(tr '\n' ' ' < "$c/trace" | sed 's/ $//')
}
outcomes_of() { printf '%s' "$OC_OUT" | jq -r '.provider_outcomes' 2>/dev/null; }   # the last run's ledger

start_test "OC.1 multi mode records a successful lane before a silent failure"
run_oc oc1 --multi "mock-success mock-fail"
assert_exit_code "0" "$OC_RC" "one real review remains available"
assert_eq "mock-success:ok,mock-fail:empty" "$(outcomes_of)" "exact ordered outcomes"
# Parallel: both are asked, in either order.
assert_eq "mock-fail mock-success" "$(printf '%s\n' $OC_ASKED | sort | tr '\n' ' ' | sed 's/ $//')" "both lanes were invoked, once each"

start_test "OC.2 single mode keeps a failed lane before the first success"
run_oc oc2 --single "mock-fail mock-success"
assert_exit_code "0" "$OC_RC" "the second lane can answer"
assert_eq "mock-fail:empty,mock-success:ok" "$(outcomes_of)" "the first failure is not lost"
assert_eq "mock-fail mock-success" "$OC_ASKED" "the walk asked the failing lane, then the next"

start_test "OC.3 multi mode gives timeout precedence over empty output"
run_oc oc3 --multi "mock-success mock-timeout" ZUVO_REVIEW_TIMEOUT="$OC_LANE_BUDGET"
assert_exit_code "0" "$OC_RC" "the successful lane still answers"
assert_eq "mock-success:ok,mock-timeout:timeout" "$(outcomes_of)" "timeout outcome wins"
assert_eq "1" "$(printf '%s' "$OC_OUT" | jq -r '.timeout_count' 2>/dev/null)" "the timed-out lane is counted as one"

start_test "OC.4 single mode records a timed-out lane before the next success"
# --single walks its lanes within ONE lane's budget by default (it must fit the callers' wrappers), so a
# lane that timed out leaves nothing for the next; ZUVO_RUN_DEADLINE=120 gives this walk room for two.
run_oc oc4 --single "mock-timeout mock-success" ZUVO_REVIEW_TIMEOUT="$OC_LANE_BUDGET" ZUVO_RUN_DEADLINE=120
assert_exit_code "0" "$OC_RC" "the next lane answers"
assert_eq "mock-timeout:timeout,mock-success:ok" "$(outcomes_of)" "timeout remains in the record"
assert_eq "mock-timeout mock-success" "$OC_ASKED" "the walk asked the hanging lane, then the next"

start_test "OC.5 a failing lane listed twice is recorded ONCE, in both modes"
# dispatch.sh:221-222: a failure other than a parallel timeout is deduplicated per lane — a lane name twice
# in the candidate list is one reviewer, and two `empty` entries would read as two reviewers that failed.
for oc5_mode in --multi --single; do
  run_oc "oc5${oc5_mode}" "$oc5_mode" "mock-fail mock-fail mock-success"
  assert_exit_code "0" "$OC_RC" "$oc5_mode: the real review answers"
  assert_eq "mock-fail:empty,mock-success:ok" "$(outcomes_of)" "$oc5_mode: one empty outcome for the twice-listed lane"
  assert_eq "3" "$(printf '%s' "$OC_OUT" | jq -r '.dispatched_count' 2>/dev/null)" "$oc5_mode: …though both listings were dispatched"
done
