#!/usr/bin/env bash
# Regression assertions added after the provider outcome recorder was extracted.
ADV="${ADV_OVERRIDE:-$ROOT/scripts/adversarial-review.sh}"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$HERE/mocks:$PATH"
OUTCOME_HOME="$(mktemp -d "$ADV_TEST_HOME/outcome-regression.XXXXXX")"
trap 'rm -rf "$OUTCOME_HOME"' EXIT
# home_for <case> — that case's own ZUVO_HOME. One home shared by every case made them order-dependent: a
# lane's failure recorded in one case's provider-health ledger could bench it in the next.
home_for() { mkdir -p "$OUTCOME_HOME/home-$1" && printf '%s' "$OUTCOME_HOME/home-$1"; }

start_test "OC.5 multi mode retains the original duplicate-timeout record"
out=$(ZUVO_HOME="$(home_for oc5)" ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout mock-timeout mock-success" ZUVO_REVIEW_TIMEOUT=1 \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the successful lane still answers"
assert_eq "mock-timeout:timeout,mock-timeout:timeout,mock-success:ok" \
  "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "parallel timeout remains unconditional"

cat > "$OUTCOME_HOME/mock-authstub" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo 'Error: Not logged in. Please run /login'
EOF
chmod +x "$OUTCOME_HOME/mock-authstub"
export PATH="$OUTCOME_HOME:$PATH"

start_test "OC.6 multi mode does not reclassify an auth stub"
out=$(ZUVO_HOME="$(home_for oc6)" ZUVO_RUN_ID="oc6-$$" ZUVO_REVIEW_TEST_PROVIDERS="mock-authstub mock-success" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the real review remains available"
assert_eq "mock-authstub:auth,mock-success:ok" \
  "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "auth has exactly one outcome"

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
  "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "missing runner never counts as empty output"
assert_eq "0" "$(printf '%s' "$out" | jq -r '.provider_count')" "no review is counted"

cat > "$OUTCOME_HOME/mock-nonzero-body" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo 'UNTRUSTED_REVIEW_BODY_927'
printf 'x%.0s' {1..700}
exit 1
EOF
chmod +x "$OUTCOME_HOME/mock-nonzero-body"

start_test "OC.8 multi mode rejects output from a failing process"
out=$(ZUVO_HOME="$(home_for oc8)" ZUVO_REVIEW_TEST_PROVIDERS="mock-nonzero-body mock-success" \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "a healthy second lane still answers"
assert_eq "mock-nonzero-body:empty,mock-success:ok" \
  "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the failed lane is not successful"
assert_eq "null" "$(printf '%s' "$out" | jq -r '.results["mock-nonzero-body"] // "null"')" "failed body is excluded"
if [[ "$out" == *UNTRUSTED_REVIEW_BODY_927* ]]; then
  fail "failed body is absent from every JSON field"
else
  pass "failed body is absent from every JSON field"
fi
assert_eq "1" "$(printf '%s' "$out" | jq -r '.provider_count')" "only the healthy lane is counted"
assert_eq "mock-success" "$(printf '%s' "$out" | jq -r '.providers_used')" "only the healthy lane is credited"
assert_eq "partial" "$(printf '%s' "$out" | jq -r '.status')" "a failed lane makes the run partial"

cat > "$OUTCOME_HOME/mock-timeout-with-body" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo 'UNTRUSTED_PARTIAL_TIMEOUT_927'
printf 'x%.0s' {1..700}
sleep 30   # past the 1 s budget and the kill grace, so a timeout; bounded if the kill ever misses
EOF
chmod +x "$OUTCOME_HOME/mock-timeout-with-body"

start_test "OC.9 multi mode discards a timed-out partial response"
out=$(ZUVO_HOME="$(home_for oc9)" ZUVO_REVIEW_TEST_PROVIDERS="mock-timeout-with-body mock-success" ZUVO_REVIEW_TIMEOUT=1 \
  bash "$ADV" --multi --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the healthy lane still answers"
assert_eq "mock-timeout-with-body:timeout,mock-success:ok" \
  "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "partial output does not override timeout"
assert_eq "1" "$(printf '%s' "$out" | jq -r '.timeout_count')" "timed-out lane is counted"
if [[ "$out" == *UNTRUSTED_PARTIAL_TIMEOUT_927* ]]; then
  fail "timed-out body is absent from every JSON field"
else
  pass "timed-out body is absent from every JSON field"
fi

start_test "OC.7 single mode skips an auth stub before a real review"
out=$(ZUVO_HOME="$(home_for oc7)" ZUVO_RUN_ID="oc7-$$" ZUVO_REVIEW_TEST_PROVIDERS="mock-authstub mock-success" \
  bash "$ADV" --single --json --files "$ADV_TEST_EMPTY" 2>/dev/null); rc=$?
assert_exit_code "0" "$rc" "the real review remains available"
assert_eq "mock-authstub:auth,mock-success:ok" \
  "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "auth has exactly one outcome"
