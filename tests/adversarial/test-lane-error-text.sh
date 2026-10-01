#!/usr/bin/env bash
# test-lane-error-text.sh — every lane's error-as-output guard, as one table.
#
# Five lanes read an exit-0 body that may really be an error or quota notice (the agy lesson: such a body
# must never travel on as a CLEAN review with zero findings): kimi, kimi-api, openrouter, qwen and muse.
# Each had its own copy of the guard, with its own phrase list and its own length rule:
#   kimi / kimi-api / openrouter — a body under 1000 chars is scanned in full (empty, `error:` first, or a
#                                  phrase); a longer one is a real review that may QUOTE a phrase, so only
#                                  an `error:` prefix refuses it. Case-insensitive.
#   qwen                         — the same 1000-char gate, its own phrases, and no prefix rule above it.
#   muse                         — no length gate and case-SENSITIVE phrases.
# The table pins what each lane accepts and refuses, so one shared guard can replace the copies without
# changing a single verdict. Every short probe is padded past 600 chars: the driver's auth-stub filter
# (≤600 B) must not decide a row this table is about.
#
# Everything runs against fakes on PATH (kimi, curl, qwen, muse) — no endpoint, no key, no quota.

ADV="$ROOT/scripts/adversarial-review.sh"
export ZUVO_ADVERSARIAL_TEST_HARNESS=1

LET="$HERE/.tmp/lane-error-text.$$"; mkdir -p "$LET/bin"
cleanup_let() { rm -rf "$LET"; }
trap cleanup_let EXIT

INPUT="$LET/input.py"
printf 'def f(x):\n    return x / 0\n' > "$INPUT"

# Every fake answers with the bytes of $LET_BODY_FILE, in its own lane's wire format.
cat > "$LET/bin/kimi" <<'EOF'
#!/usr/bin/env bash
jq -cn --rawfile t "$LET_BODY_FILE" '{role:"assistant",content:$t}'
EOF
cat > "$LET/bin/curl" <<'EOF'
#!/usr/bin/env bash
jq -cn --rawfile t "$LET_BODY_FILE" '{choices:[{message:{content:$t}}],usage:{prompt_tokens:1,completion_tokens:1}}'
# The openrouter lane reads the HTTP status from the last line (curl -w); kimi-api reads the body only.
[[ "${LET_CURL_STATUS:-}" == 1 ]] && printf '\n200'
exit 0
EOF
cat > "$LET/bin/qwen" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
jq -cn --rawfile t "$LET_BODY_FILE" '[{type:"result",subtype:"success",is_error:false,result:$t}]'
EOF
cat > "$LET/bin/muse" <<'EOF'
#!/usr/bin/env bash
cat "$LET_BODY_FILE"
EOF
chmod +x "$LET/bin/kimi" "$LET/bin/curl" "$LET/bin/qwen" "$LET/bin/muse"
cat > "$LET/qwen-settings.json" <<'EOF'
{"modelProviders":{"openai":[{"id":"qwen3.8-flash","baseUrl":"https://coding-intl.dashscope.aliyuncs.com/v1","envKey":"BAILIAN_CODING_PLAN_API_KEY"}]},
 "security":{"auth":{"selectedType":"openai"}},"$version":3}
EOF

PAD="$(printf 'z%.0s' {1..680})"           # short probes: 680 + phrase, well under 1000, over 600
LONG="$(printf 'x%.0s' {1..1100})"          # long probes: over the 1000-char gate
# name|body — short probes get PAD appended (after the phrase, so `error:` stays a prefix).
PROBES=(
  "quota-reached|quota reached $PAD"
  "rate-limit|Rate limit exceeded $PAD"
  "error-prefix|Error: boom $PAD"
  "login-required|Login required $PAD"
  "not-authenticated|not authenticated $PAD"
  "insufficient-credits|insufficient credits $PAD"
  "unauthorized|Unauthorized $PAD"
  "unauthorized-lc|unauthorized $PAD"
  "arrearage|Arrearage notice $PAD"
  "invalid-api-key|Invalid API key $PAD"
  "invalidapikey|InvalidApiKey $PAD"
  "muse-login|run muse login first $PAD"
  "not-logged-in|not logged in $PAD"
  "permission-profile|Permission profile read-only is unavailable $PAD"
  "quota-word|monthly quota $PAD"
  "quota-cap|Quota exceeded $PAD"
  "clean-short|SEVERITY: INFO FILE: input.py:2 ISSUE: division by zero $PAD"
  "long-quotes-rate-limit|$LONG rate limit quoted in a finding"
  "long-quotes-unauthorized|$LONG Unauthorized quoted in a finding"
  "long-error-prefix|error: $LONG"
  "empty|"
)

# lane_verdicts <lane> -> "probe=outcome ..." for every probe, one fresh HOME per call.
lane_verdicts() {
  local lane="$1" p name body c out oc verdicts=""
  for p in "${PROBES[@]}"; do
    name="${p%%|*}"; body="${p#*|}"
    c="$LET/$lane/$name"; mkdir -p "$c"
    printf '%s' "$body" > "$c/body"
    local -a extra=()
    case "$lane" in
      kimi-api)   extra=(MOONSHOT_API_KEY=fixture-key) ;;
      openrouter) extra=(OPENROUTER_API_KEY=fixture-key LET_CURL_STATUS=1) ;;
      qwen)       extra=(ZUVO_QWEN_SETTINGS="$LET/qwen-settings.json" ZUVO_QWEN_MODEL=qwen3.8-flash) ;;
    esac
    out=$(env -u CLAUDECODE -u CODEX_SANDBOX -u CODEX_SHELL -u QWEN_CODE -u MOONSHOT_API_KEY -u OPENROUTER_API_KEY \
      PATH="$LET/bin:$PATH" LET_BODY_FILE="$c/body" ZUVO_HOME="$c" HOME="$c" ZUVO_PROVIDER_BENCH=0 \
      ZUVO_REVIEW_TIMEOUT=25 ZUVO_NO_CAFFEINATE=1 ${extra[@]+"${extra[@]}"} \
      bash "$ADV" --provider "$lane" --single --json --files "$INPUT" 2>"$c/stderr")
    oc="$(printf '%s' "$out" | jq -r '.provider_outcomes // "none"' 2>/dev/null)"
    verdicts="${verdicts:+$verdicts }$name=${oc#"$lane":}"
  done
  printf '%s' "$verdicts"
}

# The verdict table — recorded from the per-lane copies before they were merged into one guard.
EXPECT_KIMI="quota-reached=empty rate-limit=empty error-prefix=empty login-required=empty not-authenticated=empty insufficient-credits=ok unauthorized=ok unauthorized-lc=ok arrearage=ok invalid-api-key=ok invalidapikey=ok muse-login=ok not-logged-in=ok permission-profile=ok quota-word=ok quota-cap=ok clean-short=ok long-quotes-rate-limit=ok long-quotes-unauthorized=ok long-error-prefix=empty empty=empty"
EXPECT_KIMI_API="$EXPECT_KIMI"
EXPECT_OPENROUTER="quota-reached=empty rate-limit=empty error-prefix=empty login-required=ok not-authenticated=empty insufficient-credits=empty unauthorized=ok unauthorized-lc=ok arrearage=ok invalid-api-key=ok invalidapikey=ok muse-login=ok not-logged-in=ok permission-profile=ok quota-word=empty quota-cap=empty clean-short=ok long-quotes-rate-limit=ok long-quotes-unauthorized=ok long-error-prefix=empty empty=empty"
EXPECT_QWEN="quota-reached=empty rate-limit=empty error-prefix=ok login-required=ok not-authenticated=ok insufficient-credits=ok unauthorized=empty unauthorized-lc=empty arrearage=empty invalid-api-key=empty invalidapikey=empty muse-login=ok not-logged-in=ok permission-profile=ok quota-word=empty quota-cap=empty clean-short=ok long-quotes-rate-limit=ok long-quotes-unauthorized=ok long-error-prefix=ok empty=empty"
EXPECT_MUSE="quota-reached=empty rate-limit=ok error-prefix=ok login-required=ok not-authenticated=ok insufficient-credits=ok unauthorized=empty unauthorized-lc=ok arrearage=ok invalid-api-key=ok invalidapikey=ok muse-login=empty not-logged-in=empty permission-profile=empty quota-word=empty quota-cap=ok clean-short=ok long-quotes-rate-limit=empty long-quotes-unauthorized=empty long-error-prefix=ok empty=empty"

check_lane() { # check_lane <lane> <expected>
  local got exp_row got_row p name
  got="$(lane_verdicts "$1")"
  for p in "${PROBES[@]}"; do
    name="${p%%|*}"
    exp_row=" $2 "; exp_row="${exp_row#* "$name"=}"; exp_row="${exp_row%% *}"
    got_row=" $got "; got_row="${got_row#* "$name"=}"; got_row="${got_row%% *}"
    assert_eq "$exp_row" "$got_row" "$1 / $name"
  done
}

start_test "LET.1 kimi CLI — length-gated phrases, case-insensitive"
check_lane kimi "$EXPECT_KIMI"
start_test "LET.2 kimi-api — the same rule as the kimi CLI"
check_lane kimi-api "$EXPECT_KIMI_API"
start_test "LET.3 openrouter — length-gated, its own phrases"
check_lane openrouter "$EXPECT_OPENROUTER"
start_test "LET.4 qwen — length-gated phrases, no prefix rule"
check_lane qwen "$EXPECT_QWEN"
start_test "LET.5 muse — no length gate, case-sensitive phrases"
check_lane muse "$EXPECT_MUSE"
