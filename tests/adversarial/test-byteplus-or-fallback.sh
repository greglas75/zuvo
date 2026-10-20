#!/usr/bin/env bash
# test-byteplus-or-fallback.sh — step 3 of the BytePlus fallback chain (_byteplus_fallback / _byteplus_or_step,
# adversarial-dispatch.sh): with the plan's quota spent and the Alibaba Token Plan out too, glm and deepseek run on
# OpenRouter pinned to named endpoints, no fallbacks, and the run log names the model and endpoint that answered.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

OTMP="$HERE/.tmp/bpor.$$"; mkdir -p "$OTMP/bin"
cleanup_bpor() { rm -rf "$OTMP"; }
trap cleanup_bpor EXIT
KEYFILE="$OTMP/byteplus.key"
( umask 077; printf 'fake-plan-key' > "$KEYFILE" )

# Fake curl: records each URL (curl.urls) and each chat request's body (bodies.jsonl). /key answers a spend of $0;
# OpenRouter's chat answers a review served by "InferenceNet"; nothing else is expected here.
cat > "$OTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev="" url=""
for a in "$@"; do
  [ "$prev" = "-d" ] && jq -c . "${a#@}" >> "$BOR_REC/bodies.jsonl"
  case "$a" in *://*) url="$a"; printf '%s\n' "$a" >> "$BOR_REC/curl.urls" ;; esac
  prev="$a"
done
case "$url" in
  */key) printf '{"data":{"usage_daily":0}}'; exit 0 ;;
esac
printf '%s\n%s' '{"provider":"InferenceNet","choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}' 200
EOF
chmod +x "$OTMP/bin/curl"

# Fake qwen CLI: a review, or with $BOR_ALI_MSG a spent Token Plan (as qwen 0.25.3 answers it), or with $BOR_ALI_FAIL
# an ordinary failure.
cat > "$OTMP/bin/qwen" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf 'called\n' >> "$BOR_REC/qwen.calls"
if [ -n "${BOR_ALI_MSG:-}" ]; then
  jq -cn --arg m "$BOR_ALI_MSG" '[{type: "result", subtype: "error_during_execution", is_error: true, error: {message: $m}}]'
  exit 1
fi
if [ -n "${BOR_ALI_FAIL:-}" ]; then
  printf '%s' '[{"type":"result","is_error":true,"error":{"message":"internal server error"}}]'; exit 1
fi
printf '%s' '[{"type":"result","is_error":false,"result":"NO ISSUES FOUND."}]'
EOF
chmod +x "$OTMP/bin/qwen"
QSET="$OTMP/qwen-settings.json"
jq -n '{modelProviders: {openai: [("glm-5.3","deepseek-v4.1-flash") as $m
  | {id: $m, baseUrl: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"}]}}' > "$QSET"

# run_o <case> <lane> [VAR=value…] — the BytePlus stop is on file (an hour ahead) and the Alibaba one too, unless a
# case clears it (ZUVO_ALIBABA_QUOTA_FILE=…). Stderr -> <home>/err, exit code -> <home>/rc.
run_o() {
  local home="$OTMP/$1" lane="$2"; shift 2
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$home/quota"
  printf '%s\tqwen\n' "$(( $(date +%s) + 3600 ))" > "$home/aquota"
  env -u ZUVO_BYTEPLUS_BASE_URL -u ZUVO_OPENROUTER_BASE_URL -u OPENROUTER_API_KEY -u BYTEPLUS_API_KEY \
    -u ZUVO_GLM_OR_MODEL -u ZUVO_GLM_OR_PROVIDERS -u ZUVO_DEEPSEEK_OR_MODEL -u ZUVO_DEEPSEEK_OR_PROVIDERS \
    -u ZUVO_MODEL_BYTEPLUS -u ZUVO_MODEL_BYTEPLUS_ALT -u ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS -u ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS_ALT \
    PATH="$OTMP/bin:$PATH" BOR_REC="$home" ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_BYTEPLUS_QUOTA_FILE="$home/quota" ZUVO_ALIBABA_QUOTA_FILE="$home/aquota" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" ZUVO_OPENROUTER_USAGE_FILE="$home/usage" \
    ZUVO_QWEN_SETTINGS="$QSET" ZUVO_ADV_QWEN=1 ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 "$@" \
    bash "$ADV" --provider "$lane" --mode code --files "$EMPTY" >/dev/null 2>"$home/err"
  echo "$?" > "$home/rc"
}
chats()   { awk '/openrouter\.ai.*chat\/completions/' "$OTMP/$1/curl.urls" 2>/dev/null | wc -l | tr -d ' '; }
routing() { jq -c 'select(.model | contains("/")) | {model, provider}' "$OTMP/$1/bodies.jsonl" 2>/dev/null; }
logged()  { awk -F'\t' '$14 == "'"$2"'" { m = $4 } END { print m }' "$OTMP/$1/adversarial.log" 2>/dev/null; }

# Bug caught: deepseek left out (or sent unpinned, to any endpoint OpenRouter picks — the $72 day) once BytePlus and
# the Token Plan are both spent; or a fallback allowed past the named endpoints.
start_test "or.1 deepseek, BytePlus and the Token Plan out: one OpenRouter request pinned to the three fp8 endpoints"
run_o c1 byteplus-alt
assert_eq '{"model":"deepseek/deepseek-v4.1-flash-1017","provider":{"order":["inference-net/fp8","parasail/fp8","atlas-cloud/fp8"],"allow_fallbacks":false,"quantizations":["fp8"]}}' \
  "$(routing c1)" "model, endpoint order, no fallbacks, fp8 only"
assert_eq "1 0" "$(chats c1) $(cat "$OTMP/c1/rc")" "asked once, and it reviews"
assert_contains "$(cat "$OTMP/c1/err")" "Done: byteplus-alt (fallback step 3: OpenRouter deepseek/deepseek-v4.1-flash-1017@InferenceNet)" \
  "the step, the model and the endpoint are named on the driver's own stderr"

# Bug caught: the run log crediting the BytePlus model (or the bare OpenRouter one) with a review an OpenRouter
# endpoint wrote, so the ledger and the stats bill and judge the wrong thing.
start_test "or.2 the run log names the OpenRouter model and the endpoint that answered"
assert_eq "deepseek/deepseek-v4.1-flash-1017@InferenceNet" "$(logged c1 byteplus-alt)" "model column of the lane's row"

# Bug caught: glm restored without its chain, or pinned with an fp8-only filter that removes its own Wafer (nvfp4)
# endpoint (OpenRouter answers 404).
start_test "or.3 glm: BaseTen fp8, BaseTen fp8 US, then Wafer, with exactly those quantizations"
run_o c3 byteplus
assert_eq '{"model":"z-ai/glm-5.3-flash","provider":{"order":["baseten/fp8","baseten/fp8/us","wafer/nvfp4"],"allow_fallbacks":false,"quantizations":["fp8","nvfp4"]}}' \
  "$(routing c3)" "model, endpoint order, no fallbacks"

# Bug caught: OpenRouter billed while the prepaid Token Plan could still answer.
start_test "or.4 the Token Plan answers: no OpenRouter request"
run_o c4 byteplus-alt ZUVO_ALIBABA_QUOTA_FILE="$OTMP/c4/none"
assert_eq "0 0 1" "$(chats c4) $(cat "$OTMP/c4/rc") $(wc -l < "$OTMP/c4/qwen.calls" | tr -d ' ')" "no OpenRouter call; the Token Plan reviewed"

# Bug caught: a Token Plan spent DURING the call ending the lane although step 3 could still review.
start_test "or.5 a Token Plan quota answer mid-run passes to step 3"
run_o c5 byteplus-alt ZUVO_ALIBABA_QUOTA_FILE="$OTMP/c5/none" BOR_ALI_MSG="Quota exhausted: Your token-plan 1-month quota has been exhausted. (cause: insufficient_quota: 429)"
assert_eq "1 0" "$(chats c5) $(cat "$OTMP/c5/rc")" "OpenRouter asked, and it reviews"

# Bug caught: an ordinary Token Plan failure (not its quota) silently billed to OpenRouter.
start_test "or.6 a Token Plan failure that is not its quota does not reach OpenRouter"
run_o c6 byteplus-alt ZUVO_ALIBABA_QUOTA_FILE="$OTMP/c6/none" BOR_ALI_FAIL=1
assert_eq "0" "$(chats c6)" "no OpenRouter call"
assert_eq "no" "$([ "$(cat "$OTMP/c6/rc")" = 0 ] && echo yes || echo no)" "the lane fails"

# Bug caught: an emptied override still running step 3 (unpinned or with the default), or failing the lane for it.
start_test "or.7 ZUVO_DEEPSEEK_OR_MODEL / _PROVIDERS set empty turn step 3 off: not run, not a failure"
run_o c7 byteplus-alt ZUVO_DEEPSEEK_OR_MODEL=
run_o c7b byteplus-alt ZUVO_DEEPSEEK_OR_PROVIDERS=
assert_eq "0 0" "$(chats c7) $(chats c7b)" "no OpenRouter call"
assert_contains "$(cat "$OTMP/c7/err")" "no OpenRouter step for deepseek-v4-1-flash-260910" "the lane says why"
case "$(cat "$OTMP/c7/health" 2>/dev/null)" in *byteplus-alt*) held=yes ;; *) held=no ;; esac
assert_eq "no" "$held" "not held against the lane"

# Bug caught: the overrides ignored, or seed (BytePlus-only) given an OpenRouter stand-in.
start_test "or.8 the overrides set model and endpoints; dola-seed gets no step 3"
run_o c8 byteplus-alt ZUVO_DEEPSEEK_OR_MODEL=deepseek/deepseek-v4.1-flash ZUVO_DEEPSEEK_OR_PROVIDERS=parasail/fp8
assert_eq '{"model":"deepseek/deepseek-v4.1-flash","provider":{"order":["parasail/fp8"],"allow_fallbacks":false,"quantizations":["fp8"]}}' \
  "$(routing c8)" "the override's model and single endpoint"
run_o c8b byteplus-3
assert_eq "0" "$(chats c8b)" "dola-seed: no OpenRouter call"

# Bug caught: step 3 without the paid-lane opt-in.
start_test "or.9 without ZUVO_ADV_OPENROUTER=1 step 3 does not run"
run_o c9 byteplus-alt ZUVO_ADV_OPENROUTER=0
assert_eq "0" "$(chats c9)" "no OpenRouter call"
assert_contains "$(cat "$OTMP/c9/err")" "OpenRouter step not enabled" "the lane says why"

# run_m <case> [VAR=value…] — a fan-out of byteplus-alt and two mock lanes with both plan stops on file; stderr ->
# <home>/err, the lanes that ran on stdout.
run_m() {
  local home="$OTMP/$1"; shift
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  printf '%s\n' "$(( $(date +%s) + 3600 ))" > "$home/quota"
  printf '%s\tqwen\n' "$(( $(date +%s) + 3600 ))" > "$home/aquota"
  env -u ZUVO_BYTEPLUS_BASE_URL -u ZUVO_OPENROUTER_BASE_URL -u OPENROUTER_API_KEY -u BYTEPLUS_API_KEY \
    -u ZUVO_DEEPSEEK_OR_MODEL -u ZUVO_DEEPSEEK_OR_PROVIDERS -u ZUVO_MODEL_BYTEPLUS_ALT -u ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS_ALT \
    PATH="$OTMP/bin:$HERE/mocks:$PATH" BOR_REC="$home" ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_BYTEPLUS_QUOTA_FILE="$home/quota" ZUVO_ALIBABA_QUOTA_FILE="$home/aquota" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" ZUVO_OPENROUTER_USAGE_FILE="$home/usage" \
    ZUVO_QWEN_SETTINGS="$QSET" ZUVO_ADV_QWEN=1 ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 \
    ZUVO_REVIEW_PROVIDER_PICK=ranked ZUVO_REVIEW_MAX_PROVIDERS=2 \
    ZUVO_REVIEW_TEST_PROVIDERS="byteplus-alt mock-success mock-success" "$@" \
    bash "$ADV" --multi --json --files "$EMPTY" 2>"$home/err" \
    | python3 -c 'import sys,json;print(json.load(sys.stdin).get("providers_used","?"))' 2>/dev/null
}

# Bug caught: the pre-run stop list dropping a lane whose step 3 can still review (both plans out, OpenRouter under
# its cap), or drawing it once today's OpenRouter cap is spent.
start_test "or.10 both plans out: the lane is drawn while OpenRouter is under its cap, left out once the cap is spent"
assert_contains "$(run_m c10 ZUVO_OPENROUTER_DAILY_USD=5)" "byteplus-alt" "under the cap: drawn"
mkdir -p "$OTMP/c10b"; printf '%s 6.5\n' "$(date +%s)" > "$OTMP/c10b/usage"
assert_eq "mock-success, mock-success" "$(run_m c10b ZUVO_OPENROUTER_DAILY_USD=5)" "cap spent: left out"
assert_contains "$(cat "$OTMP/c10b/err")" 'OpenRouter daily budget $6.5/$5' "named among the known stops, with the spend"
