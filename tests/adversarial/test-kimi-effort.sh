#!/usr/bin/env bash
# test-kimi-effort.sh — the `kimi` lane: model/effort per call, a tool-less reviewer, and an
# exhausted plan reported as `quota`, not `empty`.
#
# Pinned here:
#   1. defaults come from THIS repo's model-registry.sh (not an installed ~/.zuvo copy):
#      -m kimi-code/k3-256k, effort high (bench 2026-09-24)
#   2. ZUVO_KIMI_EFFORT / ZUVO_KIMI_CLI_MODEL override them; an unknown effort falls back to high
#   3. the effort travels as KIMI_MODEL_THINKING_EFFORT on the one call — the owner's
#      ~/.kimi-code/config.toml (which drives interactive kimi) is never the mechanism
#   4. the reviewer runs with an agent profile declaring `tools: []` — the default agent ran
#      shell commands on its own and listed the owner's home directory during a review
#   5. a 403 plan limit is outcome `kimi:quota`; it used to be `kimi:empty`, which reads as
#      "the model answered nothing" and hid 32 consecutive limit hits in the health ledger
#
# Everything runs against a FAKE `kimi` on PATH — no real endpoint, no quota spent. The PATH is
# host-neutral (host_neutral_path, assert.sh): with the runner's ~/.kimi-code/bin left in, the
# driver detects a Kimi Code host, excludes both kimi lanes, and every case here reads empty.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

KTMP="$HERE/.tmp/kimi-effort.$$"; mkdir -p "$KTMP/bin"
cleanup_kimi_effort() { rm -rf "$KTMP"; }
trap cleanup_kimi_effort EXIT

INPUT="$KTMP/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

cat > "$KTMP/bin/kimi" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_KIMI_DIR"
printf '%s' "${KIMI_MODEL_THINKING_EFFORT-<unset>}" > "$d/effort"
printf '%s\n' "$@" > "$d/argv"
prev=""; for a in "$@"; do [[ "$prev" == "--agent-file" ]] && cp "$a" "$d/agent.md"; prev="$a"; done
case "${FAKE_KIMI_MODE:-ok}" in
  ok)    printf '{"role":"assistant","content":"SEVERITY: CRITICAL\\nFILE: input.py:2\\nISSUE: division by zero KIMI-FAKE-FINDING"}\n' ;;
  quota) printf '{"role":"meta","type":"system.version","version":"2.1.0"}\n'
         echo "error: failed to run prompt: provider.auth_error: 403 You've reached your 5-hour usage limit. Your quota will reset when the current 5-hour window ends." >&2
         exit 1 ;;
  fail)  echo "error: something unrelated broke" >&2; exit 1 ;;
  errbody) printf '{"role":"assistant","content":"error: rate limit exceeded"}\n' ;;
esac
EOF
chmod +x "$KTMP/bin/kimi"

# run_kimi_case <case> <mode> [VAR=value ...] — extra args are env assignments for the driver
# HOME is an empty per-case directory: the driver sources ~/.zuvo/model-registry.sh FIRST when it exists, so
# under the runner's HOME the defaults ke.1 pins would be whatever the host last installed, not this
# repository's shared/includes/model-registry.sh — an edited default there would never reach a case.
run_kimi_case() {
  local c="$KTMP/$1" mode="$2"; shift 2; mkdir -p "$c/home"
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u KIMI_MODEL_THINKING_EFFORT \
    -u ZUVO_KIMI_EFFORT -u ZUVO_KIMI_CLI_MODEL -u ZUVO_MODEL_KIMI_CLI -u ZUVO_MODEL_KIMI_CLI_EFFORT \
    -u MOONSHOT_API_KEY "$@" \
    PATH="$KTMP/bin:$(host_neutral_path)" FAKE_KIMI_DIR="$c" FAKE_KIMI_MODE="$mode" ZUVO_HOME="$c" HOME="$c/home" \
    ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    bash "$ADV" --provider kimi --mode code --files "$INPUT" --artifact "$c/art" \
    > "$c/stdout" 2>"$c/stderr"
}
argv_after() { awk -v f="$2" 'p{print; exit} $0==f{p=1}' "$KTMP/$1/argv" 2>/dev/null; }
outcome()    { awk -F= '/^provider_outcomes=/{print $2; exit}' "$KTMP/$1/art" 2>/dev/null; }

start_test "ke.1 defaults: kimi-code/k3-256k at effort=high"
run_kimi_case k1 ok
assert_eq "high" "$(cat "$KTMP/k1/effort" 2>/dev/null)" "default effort"
assert_eq "kimi-code/k3-256k" "$(argv_after k1 -m)" "default model"
assert_contains "$(cat "$KTMP/k1/stdout")" "KIMI-FAKE-FINDING" "the review still flows through"
assert_eq "kimi:ok" "$(outcome k1)" "outcome ok"

start_test "ke.2 ZUVO_KIMI_EFFORT and ZUVO_KIMI_CLI_MODEL override the defaults"
run_kimi_case k2 ok ZUVO_KIMI_EFFORT=low ZUVO_KIMI_CLI_MODEL=kimi-code/k3
assert_eq "low" "$(cat "$KTMP/k2/effort" 2>/dev/null)" "override effort"
assert_eq "kimi-code/k3" "$(argv_after k2 -m)" "override model"

start_test "ke.3 an unknown effort value falls back to high"
# The payload is a CANARY, not a weapon. It used to be `rm -rf /`, which inverts the test's own
# risk model: this assertion exists precisely to catch the day sanitisation stops working, and on
# that day the payload would have run. `rm` refusing `/` without --no-preserve-root is a safety
# net belonging to someone else's tool, not a property of this test. A canary file proves MORE
# anyway — it lets the test assert that nothing executed, instead of inferring it from the
# absence of a catastrophe.
_canary="$KTMP/k3-injection-canary"
rm -f "$_canary"
run_kimi_case k3 ok "ZUVO_KIMI_EFFORT=extreme; touch '$_canary'"
assert_eq "high" "$(cat "$KTMP/k3/effort" 2>/dev/null)" "invalid value never reaches the CLI"
[ -e "$_canary" ] \
  && fail "shell injection" "the appended command EXECUTED — $_canary exists" \
  || pass "the appended command did not execute (canary absent)"

start_test "ke.4 the reviewer is a tool-less agent profile"
assert_contains "$(cat "$KTMP/k1/argv")" "--agent-file" "an agent file is passed"
assert_contains "$(cat "$KTMP/k1/agent.md" 2>/dev/null)" "tools: []" "the profile declares no tools"
case "$(cat "$KTMP/k1/argv")" in
  *$'\n-y\n'*|*"--yolo"*|*"--auto"*) assert_eq "no auto-approval" "auto-approval" "never -y/--yolo/--auto" ;;
  *) assert_eq "ok" "ok" "no auto-approval flag" ;;
esac

start_test "ke.5 a plan limit (403) is outcome quota, not empty"
run_kimi_case k5 quota
assert_eq "kimi:quota" "$(outcome k5)" "quota outcome"
assert_contains "$(cat "$KTMP/k5/stderr" "$KTMP"/k5/adversarial-failures/*/provider_kimi.stderr 2>/dev/null)" \
  "plan limit reached" "the reason is named"

start_test "ke.6 an unrelated CLI failure is still empty"
run_kimi_case k6 fail
assert_eq "kimi:empty" "$(outcome k6)" "non-quota failure unchanged"

# kimi_logged_effort <case> -> "<header has effort>|<kimi rows>|<the kimi row's effort>" from the case's
# adversarial.log (ZUVO_HOME=<case>), columns found by NAME. The row count keeps an empty effort from passing
# when no kimi row was written at all.
kimi_logged_effort() {
  awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "effort") e = i; if ($i == "provider") p = i }; next }
              e && $p == "kimi" { v = $e; n++ } END { print (e ? "yes" : "no") "|" n + 0 "|" v }' "$KTMP/$1/adversarial.log" 2>/dev/null
}

start_test "ke.7 the log row carries the effort the CLI got"
assert_eq "yes|1|high" "$(kimi_logged_effort k1)" "default run: high, as the fake received (ke.1)"
assert_eq "yes|1|low" "$(kimi_logged_effort k2)" "override run: low (ke.2)"
assert_eq "yes|1|high" "$(kimi_logged_effort k3)" "an invalid ZUVO_KIMI_EFFORT is logged as the high that actually ran (ke.3)"

# run_kimi_api_case <case> <fake-kimi mode> [fail] — the CLI fails as <mode> says, MOONSHOT_API_KEY is set and a fake
# curl answers for kimi-api (or, with `fail`, exits 22 as curl --fail does on an HTTP error) from the case's own bin
# directory, so no other case can reach it. With `fail` nothing answers for kimi, and a run in which no lane answers
# logs one `none` row and no lane rows — so mock-success runs alongside and the kimi row is written.
run_kimi_api_case() {
  local c="$KTMP/$1" sel=(--provider kimi); mkdir -p "$c/home" "$c/bin"
  if [ "${3:-}" = fail ]; then
    sel=()   # both lanes from ZUVO_REVIEW_TEST_PROVIDERS
    printf '#!/bin/sh\necho "curl: (22) The requested URL returned error: 503" >&2\nexit 22\n' > "$c/bin/curl"
  else
    cat > "$c/bin/curl" <<'CURL'
#!/bin/sh
printf '%s' '{"choices":[{"message":{"content":"SEVERITY: WARNING\nFILE: input.py:2\nISSUE: KIMI-API-FAKE"}}],"usage":{"prompt_tokens":1,"completion_tokens":1}}'
CURL
  fi
  chmod +x "$c/bin/curl"
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u KIMI_MODEL_THINKING_EFFORT \
    -u ZUVO_KIMI_EFFORT -u ZUVO_KIMI_CLI_MODEL -u ZUVO_MODEL_KIMI_CLI -u ZUVO_MODEL_KIMI_CLI_EFFORT \
    PATH="$c/bin:$KTMP/bin:$HERE/mocks:$(host_neutral_path)" FAKE_KIMI_DIR="$c" FAKE_KIMI_MODE="$2" ZUVO_HOME="$c" HOME="$c/home" \
    MOONSHOT_API_KEY=fixture-key ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    ZUVO_REVIEW_TEST_PROVIDERS="kimi${3:+ mock-success}" \
    bash "$ADV" ${sel[@]+"${sel[@]}"} --mode code --files "$INPUT" --artifact "$c/art" > "$c/stdout" 2>"$c/stderr"
}

start_test "ke.8 when kimi-api answers for a CLI that exited non-zero, the row's effort is empty"
# The API fallback takes no thinking effort, so the CLI's value must not stay on the row.
run_kimi_api_case k8 fail
assert_eq "high" "$(cat "$KTMP/k8/effort" 2>/dev/null)" "premise: the CLI was tried at effort high"
assert_contains "$(cat "$KTMP/k8/stdout")" "KIMI-API-FAKE" "premise: kimi-api's review is the one returned"
assert_eq "yes|1|" "$(kimi_logged_effort k8)" "one kimi row, effort empty: the answer came from the API, which has none"

start_test "ke.9 when kimi-api answers for a CLI that exited 0 with an error body, the row's effort is empty"
run_kimi_api_case k9 errbody
assert_eq "high" "$(cat "$KTMP/k9/effort" 2>/dev/null)" "premise: the CLI was tried at effort high"
assert_contains "$(cat "$KTMP/k9/stdout")" "KIMI-API-FAKE" "premise: kimi-api's review is the one returned"
assert_eq "yes|1|" "$(kimi_logged_effort k9)" "one kimi row, effort empty (the error-body fallback clears it too)"

start_test "ke.10 when kimi-api fails too, the row keeps the effort the CLI ran at"
# Nothing answered: the last call that ran with an effort was the CLI's, so its value stays.
run_kimi_api_case k10 fail fail
assert_eq "high" "$(cat "$KTMP/k10/effort" 2>/dev/null)" "premise: the CLI was tried at effort high"
assert_not_contains_k() { case "$1" in *"$2"*) fail "$3" "found <$2>" ;; *) pass "$3" ;; esac; }
assert_not_contains_k "$(cat "$KTMP/k10/stdout")" "KIMI-API-FAKE" "premise: no review came back"
assert_eq "yes|1|high" "$(kimi_logged_effort k10)" "one kimi row, effort high"
