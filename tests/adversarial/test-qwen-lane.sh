#!/usr/bin/env bash
# test-qwen-lane.sh — the `qwen` lane (Qwen Code CLI on an Alibaba Model Studio Coding Plan).
#
# Three properties are worth pinning, in this order of cost-if-broken:
#   1. MONEY. The general dashscope endpoint bills per token. The lane must refuse any model
#      whose configured baseUrl is not a Token Plan or Coding Plan host, and
#      refuse BEFORE the CLI runs — a refusal after the call is a bill with a warning attached.
#   2. CONSENT. The vendor's terms forbid scripted use of the plan key; enabling the lane is the
#      owner's decision, so a `qwen` binary on PATH must not enable it.
#   3. HONESTY. `qwen -o json` exits 0 with an is_error result; that must count as a failure,
#      not as a clean review with zero findings.
#
# Everything runs against a FAKE `qwen` on PATH — no real endpoint, no quota spent.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

QTMP="$HERE/.tmp/qwen.$$"; mkdir -p "$QTMP/bin"
cleanup_qwen() { rm -rf "$QTMP"; }
trap cleanup_qwen EXIT

INPUT="$QTMP/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

# The fake records how it was called and answers according to $FAKE_QWEN_MODE.
cat > "$QTMP/bin/qwen" <<'EOF'
#!/usr/bin/env bash
d="$FAKE_QWEN_DIR"
printf '%s\n' "$*" > "$d/argv"
cat > "$d/stdin"
printf '%s' "${OPENAI_BASE_URL-<unset>}" > "$d/openai_base_url"
pwd > "$d/cwd"
case "${FAKE_QWEN_MODE:-ok}" in
  ok)    printf '[{"type":"system"},{"type":"result","subtype":"success","is_error":false,"result":"SEVERITY: CRITICAL\\nFILE: input.py:2\\nISSUE: division by zero QWEN-FAKE-FINDING"}]\n' ;;
  error) printf '[{"type":"result","subtype":"error_during_execution","is_error":true,"error":{"message":"Arrearage: plan quota exhausted QWEN-FAKE-ERR"}}]\n' ;;
  wander) printf '[{"type":"result","subtype":"success","is_error":false,"result":"No findings - nothing to review. The workspace qwen_ws is empty. QWEN-FAKE-WANDER"}]\n' ;;
esac
EOF
chmod +x "$QTMP/bin/qwen"

write_settings() { # write_settings <file> <baseUrl> [model-id]
  cat > "$1" <<EOF
{"modelProviders":{"openai":[{"id":"${3:-qwen3.8-flash}","baseUrl":"$2","envKey":"BAILIAN_CODING_PLAN_API_KEY"}]},
 "security":{"auth":{"selectedType":"openai"}},"\$version":3}
EOF
}

# One HOME/dir per case — see test-byteplus-billing-guard.sh for why shared state lies.
run_qwen_case() { # run_qwen_case <case> <settings-file> [mode] -> "stdout<SEP>provider stderr"
  local c="$QTMP/$1"; mkdir -p "$c"
  env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u QWEN_CODE \
    PATH="$QTMP/bin:$PATH" FAKE_QWEN_DIR="$c" FAKE_QWEN_MODE="${3:-ok}" \
    ZUVO_QWEN_SETTINGS="$2" ZUVO_HOME="$c" ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    OPENAI_BASE_URL="https://openrouter.ai/api/v1" \
    bash "$ADV" --provider qwen --mode code --files "$INPUT" > "$c/stdout" 2>"$c/stderr"
  cat "$c/stdout"; printf '\n<SEP>\n'
  cat "$c/stderr" "$c"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}

# ─── 1. pay-as-you-go endpoint refused, and the CLI never runs ─────────────
start_test "qw.1 a general dashscope baseUrl is refused before the CLI is called"
S="$QTMP/payg.json"; write_settings "$S" "https://dashscope-intl.aliyuncs.com/compatible-mode/v1"
out=$(run_qwen_case c1 "$S")
assert_contains "$out" "bill per token" "refusal names the money reason"
if [[ -e "$QTMP/c1/argv" ]]; then
  assert_eq "not called" "called" "the CLI must not run on a metered endpoint"
else
  assert_eq "ok" "ok" "the CLI was never invoked"
fi

# ─── 2. a lookalike host is refused too ────────────────────────────────────
start_test "qw.2 a host that merely contains 'coding' is refused"
S="$QTMP/lookalike.json"; write_settings "$S" "https://coding-intl.dashscope.aliyuncs.com.evil.example/v1"
out=$(run_qwen_case c2 "$S")
assert_contains "$out" "bill per token" "lookalike host refused"

# ─── 3. model not configured → refused with the setup hint ─────────────────
start_test "qw.3 a model absent from settings is refused with the /auth hint"
S="$QTMP/other-model.json"; write_settings "$S" "https://coding-intl.dashscope.aliyuncs.com/v1" "glm-5"
out=$(run_qwen_case c3 "$S")
assert_contains "$out" "/auth" "setup hint shown"

# ─── 4. unreadable settings fail CLOSED ────────────────────────────────────
start_test "qw.4 missing settings file is a refusal, not a pass"
out=$(run_qwen_case c4 "$QTMP/does-not-exist.json")
assert_contains "$out" "cannot be verified" "fails closed"

# ─── 5. plan endpoint → review flows through; prompt on stdin; env scrubbed ─
start_test "qw.5 the plan endpoint produces a review"
S="$QTMP/plan.json"; write_settings "$S" "https://coding-intl.dashscope.aliyuncs.com/v1"
out=$(run_qwen_case c5 "$S")
assert_contains "$out" "QWEN-FAKE-FINDING" "the result text reaches the review output"
assert_contains "$(cat "$QTMP/c5/stdin" 2>/dev/null)" "return x / 0" "the reviewed code travels on stdin, not argv"
assert_contains "$(cat "$QTMP/c5/argv" 2>/dev/null)" "--safe-mode" "owner customisations are disabled"
assert_contains "$(cat "$QTMP/c5/argv" 2>/dev/null)" "--max-tool-calls 0" "a tool attempt is a hard failure"
assert_eq "<unset>" "$(cat "$QTMP/c5/openai_base_url" 2>/dev/null)" "OPENAI_BASE_URL cannot re-route the lane"
case "$(cat "$QTMP/c5/cwd" 2>/dev/null)" in
  *qwen_ws) assert_eq "ok" "ok" "runs in an empty workspace" ;;
  *)        assert_eq "*qwen_ws" "$(cat "$QTMP/c5/cwd" 2>/dev/null)" "runs in an empty workspace" ;;
esac

# ─── 5b. the Token Plan endpoint is a plan endpoint too ────────────────────
start_test "qw.5b the Token Plan endpoint passes the guard"
S2="$QTMP/token-plan.json"; write_settings "$S2" "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"
out=$(run_qwen_case c5b "$S2")
assert_contains "$out" "QWEN-FAKE-FINDING" "Token Plan host reaches the CLI"

# ─── 6. exit-0 is_error result is a failure, not a clean review ────────────
start_test "qw.6 an is_error result is not consumed as a review"
out=$(run_qwen_case c6 "$S" error)
assert_contains "$out" "QWEN-FAKE-ERR" "the vendor's error is surfaced"
case "${out%%<SEP>*}" in
  *QWEN-FAKE-ERR*) assert_eq "not a review" "treated as review" "error text must not land in the review output" ;;
  *)               assert_eq "ok" "ok" "error text stayed out of the review output" ;;
esac

# ─── 6b. "workspace is empty" is a non-review, not a clean verdict ─────────
start_test "qw.6b a reviewer that looked on disk instead of reading the prompt is rejected"
out=$(run_qwen_case c6b "$S" wander)
assert_contains "$out" "instead of reviewing the prompt" "the wander is named"
case "${out%%<SEP>*}" in
  *QWEN-FAKE-WANDER*) assert_eq "not a review" "treated as review" "a no-look answer must not count as clean" ;;
  *)                  assert_eq "ok" "ok" "the no-look answer stayed out of the review output" ;;
esac

# ─── 7. opt-in: a qwen binary alone does not enable the lane ───────────────
start_test "qw.7 the lane is detected only with ZUVO_ADV_QWEN=1"
off=$(PATH="$QTMP/bin:$PATH" ZUVO_ADV_QWEN=0 bash "$ADV" --list-providers 2>/dev/null | grep -cx qwen || true)
on=$(PATH="$QTMP/bin:$PATH" ZUVO_ADV_QWEN=1 bash "$ADV" --list-providers 2>/dev/null | grep -cx qwen || true)
assert_eq "0" "${off:-0}" "not detected without the flag"
assert_eq "1" "${on:-0}" "detected with the flag"

# ─── 8. a run launched from inside Qwen Code does not ask Qwen ─────────────
start_test "qw.8 QWEN_CODE=1 (Qwen Code's shell tool) excludes the qwen lane"
c="$QTMP/c8"; mkdir -p "$c"
env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL QWEN_CODE=1 \
  PATH="$QTMP/bin:$PATH" FAKE_QWEN_DIR="$c" ZUVO_QWEN_SETTINGS="$S" ZUVO_HOME="$c" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
  bash "$ADV" --provider qwen --mode code --files "$INPUT" >/dev/null 2>&1
if [[ -e "$c/argv" ]]; then
  assert_eq "excluded" "called" "qwen must not review from inside Qwen Code"
else
  assert_eq "ok" "ok" "qwen was excluded on its own host"
fi
