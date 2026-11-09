#!/usr/bin/env bash
# test-openai-api-lane.sh — the `openai-api` lane: the OpenAI API paid from the ChatGPT subscriber credits. Where its
# requests go and with which key, that every call is priced exactly into the run log, and when it stops spending
# (credits gone, today's cap reached, a model with no price).

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

OTMP="$HERE/.tmp/openai.$$"; mkdir -p "$OTMP/bin"
cleanup_openai() { rm -rf "$OTMP"; }
trap cleanup_openai EXIT
KEYFILE="$OTMP/openai.key"
( umask 077; printf 'sk-proj-openai-secret-for-test' > "$KEYFILE" )
API_URL="https://api.openai.com/v1/chat/completions"

# No case reaches a real host: this fake curl is first on PATH. It records the URL, the -K config (where the key
# travels) and the -d payload under $O_REC, and answers $O_BODY with HTTP $O_CODE (default 200, a clean review).
cat > "$OTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do
  case "$prev" in
    -K) cat "$a" >> "$O_REC/curl.cfg" ;;
    -d) cp "${a#@}" "$O_REC/payload.json" ;;
  esac
  case "$a" in *://*) printf '%s\n' "$a" >> "$O_REC/curl.urls" ;; esac
  prev="$a"
done
ok='{"id":"chatcmpl-T1","choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":10000,"prompt_tokens_details":{"cached_tokens":4000},"completion_tokens":2000,"completion_tokens_details":{"reasoning_tokens":1500}}}'
printf '%s\n%s' "${O_BODY:-$ok}" "${O_CODE:-200}"
EOF
chmod +x "$OTMP/bin/curl"

# run_openai <case> [VAR=value…] -> the lane's captured stderr. Exit code in <home>/rc, the run log in <home>/adv.log.
run_openai() {
  local home="$OTMP/$1"; shift
  mkdir -p "$home"
  env -u ZUVO_OPENAI_API_KEY -u ZUVO_OPENAI_MODEL -u ZUVO_OPENAI_PRICE -u ZUVO_OPENAI_DAILY_USD \
    PATH="$OTMP/bin:$PATH" O_REC="$home" ZUVO_OPENAI_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adv.log" ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=40 "$@" \
    bash "$ADV" --provider openai-api --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
requests() { [ -s "$OTMP/$1/curl.urls" ] && wc -l < "$OTMP/$1/curl.urls" | tr -d ' ' || echo 0; }
# lane_row <case> <cols> — the openai-api row's columns (cut -f list) from the case's run log.
lane_row() { awk -F'\t' '$14 == "openai-api"' "$OTMP/$1/adv.log" 2>/dev/null | cut -f "$2"; }

# ─── 1. the request: OpenAI only, the lane's own key, no temperature ─────
# Bugs caught: the key sent to another host or the generic OPENAI_API_KEY used (some other org's bill); a temperature
# field, which OpenAI's reasoning models reject with HTTP 400 on every call.
start_test "openai.1 one request to api.openai.com with the lane's key file, gpt-6.1-sol, effort medium, no temperature"
OPENAI_API_KEY=sk-other-org-must-not-leak run_openai c1 >/dev/null
assert_eq "$API_URL" "$(cat "$OTMP/c1/curl.urls" 2>/dev/null)" "exactly one request, to OpenAI"
assert_eq "0" "$(cat "$OTMP/c1/rc")" "the review completes (exit 0)"
cfg="$(cat "$OTMP/c1/curl.cfg" 2>/dev/null)"
assert_contains "$cfg" "sk-proj-openai-secret-for-test" "the key file's key is the one sent"
case "$cfg" in *sk-other-org-must-not-leak*) fail "the generic OPENAI_API_KEY was sent" ;; *) pass "the generic OPENAI_API_KEY is never used" ;; esac
assert_eq "gpt-6.1-sol medium null" "$(jq -r '"\(.model) \(.reasoning_effort) \(.temperature)"' "$OTMP/c1/payload.json" 2>/dev/null)" \
  "default model, effort sent, no temperature"

# ─── 2. exact accounting ─────────────────────────────────────────────────
# Bug caught: cached tokens billed at the full input price, or reasoning tokens counted twice — the credits' spend in
# the log would not match OpenAI's usage page. 6000·$2 + 4000·$0.10 + 2000·$10 per 1M = $0.0324.
start_test "openai.2 the call's tokens and cost land in the run log, priced at the list price"
assert_eq "$(printf '10000\t4000\t2000\t1500')" "$(lane_row c1 19-22)" "tokens: in, cached, out, reasoning"
assert_eq "$(printf 'openai\t0.03240000\tchatcmpl-T1')" "$(lane_row c1 23-25)" "served_by, cost_usd, the response id"

start_test "openai.3 a model the price table lacks is refused, unless ZUVO_OPENAI_PRICE prices it"
out=$(run_openai c3a ZUVO_OPENAI_MODEL=gpt-7-preview)
assert_eq "0" "$(requests c3a)" "an unpriceable call is never made"
assert_contains "$out" "ZUVO_OPENAI_PRICE" "…and the WARN says how to price it"
run_openai c3b ZUVO_OPENAI_MODEL=gpt-7-preview ZUVO_OPENAI_PRICE=1,0.5,4 >/dev/null
# 6000·$1 + 4000·$0.5 + 2000·$4 per 1M = $0.016
assert_eq "0.01600000" "$(lane_row c3b 24)" "the override's price is the one used"

# ─── 4-5. a spent balance stops the lane; a rate limit does not ──────────
# Bug caught: a 429 insufficient_quota retried on every chunk of every review, all day, as if it were throttling.
start_test "openai.4 a spent credit balance is one request, recorded, and the next run sends none"
SPENT='{"error":{"type":"insufficient_quota","code":"insufficient_quota","message":"You exceeded your current quota."}}'
out=$(O_CODE=429 O_BODY="$SPENT" run_openai c4 ZUVO_OPENAI_CREDITS_FILE="$OTMP/c4/credits")
assert_eq "1" "$(requests c4)" "one request only"
assert_contains "$out" "credit balance spent" "the WARN names the cause"
assert_eq "2" "$(cat "$OTMP/c4/rc")" "no review (exit 2)"
rm -f "$OTMP/c4/curl.urls"
run_openai c4 ZUVO_OPENAI_CREDITS_FILE="$OTMP/c4/credits" >/dev/null
assert_eq "0" "$(requests c4)" "the recorded stop keeps the next run from asking"

start_test "openai.4b the credits answer naming the cause only in .type is a spent balance too"
O_CODE=429 O_BODY='{"error":{"type":"credit_balance_exhausted","code":null,"message":"Credit balance exhausted."}}' run_openai c4b >/dev/null
assert_eq "1" "$(requests c4b)" "one request, not retried as a rate limit"

start_test "openai.5 a plain rate limit IS retried"
O_CODE=429 O_BODY='{"error":{"type":"requests","code":"rate_limit_exceeded","message":"Rate limit reached"}}' run_openai c5 >/dev/null
assert_eq "3" "$(requests c5)" "all OR_ATTEMPTS requests were made"

# ─── 6. today's cap, from the log's own cost column ──────────────────────
# Bug caught: no ceiling — one looping agent could spend the month's credits in a day.
start_test "openai.6 a host at today's cap sends nothing; yesterday's spend does not count"
mkdir -p "$OTMP/c6"
row() { printf '%s' "$1"; for _ in $(seq 2 13); do printf '\t'; done; printf '\topenai-api'; for _ in $(seq 15 23); do printf '\t'; done; printf '\t%s\t\n' "$2"; }
{ row "$(date -u +%Y-%m-%dT00:00:01Z)" 3.5; row "$(date -u +%Y-%m-%dT00:00:02Z)" 1.5; row "2000-01-01T00:00:00Z" 99; } > "$OTMP/c6/adv.log"
out=$(run_openai c6 ZUVO_OPENAI_DAILY_USD=5)
assert_eq "0" "$(requests c6)" "\$5.00 spent today, cap \$5: no request"
assert_contains "$out" "daily cap" "…and the WARN says why"
run_openai c6b ZUVO_OPENAI_DAILY_USD=5 >/dev/null
assert_eq "1" "$(requests c6b)" "an empty log is under the cap"

# ─── 7. opt-in: a key on disk is not consent to spend the credits ────────
start_test "openai.7 the key alone does not enable the lane; ZUVO_ADV_OPENAI_API=1 or the opt-in file does"
mkdir -p "$OTMP/c7"
listed() { env -u ZUVO_OPENAI_API_KEY -u ZUVO_ADV_OPENAI_API ZUVO_OPENAI_KEY_FILE="$KEYFILE" HOME="$OTMP/c7" ZUVO_HOME="$OTMP/c7" "$@" \
  bash "$ADV" --list-providers 2>/dev/null | awk '$1 == "openai-api"' | tr -d '\n'; }
assert_eq "" "$(listed)" "no opt-in: not detected"
assert_eq "openai-api" "$(listed ZUVO_ADV_OPENAI_API=1)" "the variable turns it on"
printf 'ZUVO_ADV_OPENAI_API=1\n' > "$OTMP/c7/review-lanes.conf"
assert_eq "openai-api" "$(listed)" "review-lanes.conf turns it on for a process without the variable"
