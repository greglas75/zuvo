#!/usr/bin/env bash
# test-provider-outcome-classification.sh — the order and precedence of lane outcomes in provider_outcomes,
# in multi (parallel) and single (walk) mode: record_provider_failure_outcome and the two collection loops in
# scripts/lib/adversarial-dispatch.sh. The auth, no-runner and duplicate-timeout arms are pinned in
# test-provider-outcome-refactor-regression.sh, quota in test-kimi-effort.sh; the whole precedence ladder and
# the no-key arm here (OC.6, OC.7).
# Sourced by run.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$HERE/mocks:$PATH"
OUTCOME_HOME="$(mktemp -d "$ADV_TEST_HOME/outcomes.XXXXXX")"
trap 'rm -rf "$OUTCOME_HOME"' EXIT
# OC_LANE_BUDGET — ZUVO_REVIEW_TIMEOUT where mock-timeout must TIME OUT (it hangs far past this) while
# mock-success must ANSWER inside it, even when a loaded farm host starts it late. mock-success is instant;
# the budget is margin, not a race.
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
# record_provider_failure_outcome (adversarial-dispatch.sh): a failure other than a parallel timeout is
# deduplicated per lane — a lane name twice in the candidate list is one reviewer, and two `empty` entries
# would read as two reviewers that failed.
for oc5_mode in --multi --single; do
  run_oc "oc5${oc5_mode}" "$oc5_mode" "mock-fail mock-fail mock-success"
  assert_exit_code "0" "$OC_RC" "$oc5_mode: the real review answers"
  assert_eq "mock-fail:empty,mock-success:ok" "$(outcomes_of)" "$oc5_mode: one empty outcome for the twice-listed lane"
  assert_eq "3" "$(printf '%s' "$OC_OUT" | jq -r '.dispatched_count' 2>/dev/null)" "$oc5_mode: …though both listings were dispatched"
done

start_test "OC.6 precedence: timeout > no-runner > no-key > quota > empty (record_provider_failure_outcome)"
# The marker arms of record_provider_failure_outcome (adversarial-dispatch.sh) — when several markers a lane
# can leave in the run's temp dir are present at once, the first arm that matches decides. Called as the
# collection loops call it: the program's own function (assembled from the modules, never restated), one
# lane `x` from an empty ledger, with the markers each rung needs.
. "$ROOT/tests/lib/adversarial-driver.sh"
OC_REC_FN=""
if adv_driver_source "$ADV" > "$OUTCOME_HOME/program.sh"; then
  OC_REC_FN="$(awk '/^record_provider_failure_outcome\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$OUTCOME_HOME/program.sh")"
fi
# oc_record <status> <parallel|sequential> [<marker>...] -> PROVIDER_OUTCOMES after one call for lane x, whose
# temp dir holds <marker>_x for each marker named (norunner, nokey, quota).
oc_record() {
  local st="$1" md="$2" d m; shift 2
  d="$(mktemp -d "$OUTCOME_HOME/rec.XXXXXX")"
  for m in "$@"; do : > "$d/${m}_x"; done
  ( eval "$OC_REC_FN" || exit 97
    declare -F record_provider_failure_outcome >/dev/null || exit 97
    # shellcheck disable=SC2034  # read by record_provider_failure_outcome, defined by the eval above
    JSON_TMPDIR="$d"; PROVIDER_OUTCOMES=""
    record_provider_failure_outcome x "$st" "$md"
    printf '%s' "$PROVIDER_OUTCOMES" )
}
if [[ -z "$OC_REC_FN" ]]; then
  fail "premise: record_provider_failure_outcome read from the assembled program" "not found (reason above)"
else
  assert_eq "x:timeout"   "$(oc_record 124 parallel norunner nokey quota)" "status 124 outranks every marker"
  assert_eq "x:no-runner" "$(oc_record 1 parallel norunner nokey quota)"   "no-runner outranks no-key and quota"
  assert_eq "x:no-key"    "$(oc_record 1 parallel nokey quota)"            "no-key outranks quota"
  assert_eq "x:no-key"    "$(oc_record 1 sequential nokey quota)"          "…in the walk (sequential) too"
  assert_eq "x:quota"     "$(oc_record 1 parallel quota)"                  "quota outranks empty"
  assert_eq "x:empty"     "$(oc_record 1 parallel)"                        "no marker, not 124: empty"
fi

start_test "OC.7 a keyless lane is 'no-key' in its place in the ledger, and the walk goes on past it"
# The whole run: codestral with CODESTRAL_API_KEY empty (run_codestral, lane_no_key) never runs a request. In
# --single it is the first lane walked, then a lane that fails, then one that answers: each keeps its own outcome,
# in order, and neither failure stops the walk. In --multi it sits after the answering lane.
run_oc oc7s --single "codestral mock-fail mock-success" CODESTRAL_API_KEY=
assert_exit_code "0" "$OC_RC" "--single: the third lane answers"
assert_eq "codestral:no-key,mock-fail:empty,mock-success:ok" "$(outcomes_of)" "--single: no-key, then empty, then ok — each its own, in walk order"
assert_eq "mock-fail mock-success" "$OC_ASKED" "--single: the walk went on past the keyless lane to both mocks, in order"
assert_eq "3" "$(printf '%s' "$OC_OUT" | jq -r '.dispatched_count' 2>/dev/null)" "--single: all three lanes were dispatched"
run_oc oc7m --multi "mock-success codestral" CODESTRAL_API_KEY=
assert_exit_code "0" "$OC_RC" "--multi: the answering lane's review stands"
assert_eq "mock-success:ok,codestral:no-key" "$(outcomes_of)" "--multi: ok, then no-key — never empty"
