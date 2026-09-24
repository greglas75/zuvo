#!/usr/bin/env bash
# test-kimi-effort.sh — the `kimi` lane: model/effort per call, a tool-less reviewer, and an
# exhausted plan reported as `quota`, not `empty`.
#
# Pinned here:
#   1. defaults come from model-registry.sh: -m kimi-code/k3-256k, effort high (bench 2026-09-24)
#   2. ZUVO_KIMI_EFFORT / ZUVO_KIMI_CLI_MODEL override them; an unknown effort falls back to high
#   3. the effort travels as KIMI_MODEL_THINKING_EFFORT on the one call — the owner's
#      ~/.kimi-code/config.toml (which drives interactive kimi) is never the mechanism
#   4. the reviewer runs with an agent profile declaring `tools: []` — the default agent ran
#      shell commands on its own and listed the owner's home directory during a review
#   5. a 403 plan limit is outcome `kimi:quota`; it used to be `kimi:empty`, which reads as
#      "the model answered nothing" and hid 32 consecutive limit hits in the health ledger
#
# Everything runs against a FAKE `kimi` on PATH — no real endpoint, no quota spent.

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
esac
EOF
chmod +x "$KTMP/bin/kimi"

# run_kimi_case <case> <mode> [VAR=value ...] — extra args are env assignments for the driver
run_kimi_case() {
  local c="$KTMP/$1" mode="$2"; shift 2; mkdir -p "$c"
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u KIMI_MODEL_THINKING_EFFORT \
    -u ZUVO_KIMI_EFFORT -u ZUVO_KIMI_CLI_MODEL -u ZUVO_MODEL_KIMI_CLI -u ZUVO_MODEL_KIMI_CLI_EFFORT \
    -u MOONSHOT_API_KEY "$@" \
    PATH="$KTMP/bin:$PATH" FAKE_KIMI_DIR="$c" FAKE_KIMI_MODE="$mode" ZUVO_HOME="$c" \
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
run_kimi_case k3 ok 'ZUVO_KIMI_EFFORT=extreme; rm -rf /'
assert_eq "high" "$(cat "$KTMP/k3/effort" 2>/dev/null)" "invalid value never reaches the CLI"

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
