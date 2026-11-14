#!/usr/bin/env bash
# test-anthropic-api-lane.sh — the `anthropic-api` lane: the Claude API paid from prepaid Anthropic credits. Where its
# requests go and how the key travels, the reviewer model, exact per-call pricing, and when it stops spending (a spent
# balance, a refusal). The key rotation and the daily cap are the openai-api machinery (test-openai-api-lane.sh).

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

ATMP="$HERE/.tmp/anthropic.$$"; mkdir -p "$ATMP/bin"
cleanup_anthropic() { rm -rf "$ATMP"; }
trap cleanup_anthropic EXIT
KEYFILE="$ATMP/anthropic.key"
( umask 077; printf 'sk-ant-api-secret-for-test' > "$KEYFILE" )
API_URL="https://api.anthropic.com/v1/messages"

# No case reaches a real host: this fake curl is first on PATH. It records the URL, the -K config (where the key
# travels) and the -d payload under $A_REC, and answers $A_BODY with HTTP $A_CODE (default 200, a clean review) — or,
# when the request's key is one of the space-separated $A_SPENT_KEYS, Anthropic's "credit balance is too low" 400.
cat > "$ATMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev="" cfg=""
for a in "$@"; do
  case "$prev" in
    -K) cfg="$(cat "$a")"; printf '%s\n' "$cfg" >> "$A_REC/curl.cfg" ;;
    -d) cp "${a#@}" "$A_REC/payload.json" ;;
  esac
  case "$a" in *://*) printf '%s\n' "$a" >> "$A_REC/curl.urls" ;; esac
  prev="$a"
done
for k in ${A_SPENT_KEYS:-}; do
  case "$cfg" in *"$k"*)
    printf '%s\n' "$k" >> "$A_REC/keys.used"
    printf '%s\n400' '{"type":"error","error":{"type":"invalid_request_error","message":"Your credit balance is too low to access the Anthropic API. Please go to Plans & Billing to upgrade or purchase credits."}}'; exit 0 ;;
  esac
done
for k in k-one k-two; do case "$cfg" in *"$k"*) printf '%s\n' "$k" >> "$A_REC/keys.used" ;; esac; done
ok='{"id":"msg_T1","type":"message","model":"claude-sonnet-5-5","stop_reason":"end_turn","content":[{"type":"thinking","thinking":""},{"type":"text","text":"NO ISSUES FOUND."}],"usage":{"input_tokens":6000,"cache_read_input_tokens":4000,"cache_creation_input_tokens":1000,"output_tokens":2000,"output_tokens_details":{"thinking_tokens":1500}}}'
printf '%s\n%s' "${A_BODY:-$ok}" "${A_CODE:-200}"
EOF
chmod +x "$ATMP/bin/curl"

# run_anthropic <case> [VAR=value…] -> the lane's captured stderr. Exit code in <home>/rc, the run log in <home>/adv.log.
# A Claude Code host with no CLAUDE_MODEL: the reviewer is the author's opposite, Sonnet.
run_anthropic() {
  local home="$ATMP/$1"; shift
  mkdir -p "$home"
  env -u ZUVO_ANTHROPIC_API_KEY -u ZUVO_ANTHROPIC_MODEL -u ZUVO_ANTHROPIC_PRICE -u ZUVO_ANTHROPIC_DAILY_USD \
    -u CLAUDE_MODEL -u ZUVO_CLAUDE_REVIEWER_MODEL CLAUDECODE=1 \
    PATH="$ATMP/bin:$PATH" A_REC="$home" ZUVO_ANTHROPIC_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adv.log" ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=40 "$@" \
    bash "$ADV" --provider anthropic-api --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
requests() { [ -s "$ATMP/$1/curl.urls" ] && wc -l < "$ATMP/$1/curl.urls" | tr -d ' ' || echo 0; }
lane_row() { awk -F'\t' '$14 == "anthropic-api"' "$ATMP/$1/adv.log" 2>/dev/null | cut -f "$2"; }

# ─── 1. the request ──────────────────────────────────────────────────────
# Bugs caught: the key sent as a Bearer token (Anthropic answers 401 to every call) or to another host; the generic
# ANTHROPIC_API_KEY spent instead of the credits' key; Opus reviewing an Opus author (self-review); a temperature
# field, which API version 2026-10-21 rejects with HTTP 400.
start_test "anthropic.1 one request to api.anthropic.com, the key file's key as x-api-key, the author's opposite model"
ANTHROPIC_API_KEY=sk-ant-other-must-not-leak run_anthropic c1 >/dev/null
assert_eq "$API_URL" "$(cat "$ATMP/c1/curl.urls" 2>/dev/null)" "exactly one request, to Anthropic"
assert_eq "0" "$(cat "$ATMP/c1/rc")" "the review completes (exit 0)"
cfg="$(cat "$ATMP/c1/curl.cfg" 2>/dev/null)"
assert_contains "$cfg" 'header = "x-api-key: sk-ant-api-secret-for-test"' "the key travels as x-api-key"
assert_contains "$cfg" 'anthropic-version: 2026-10-21' "the API version header is sent"
case "$cfg" in *Bearer*|*sk-ant-other-must-not-leak*) fail "a Bearer header or the generic ANTHROPIC_API_KEY was sent" ;;
  *) pass "no Bearer header, no generic ANTHROPIC_API_KEY" ;; esac
assert_eq "claude-sonnet-5-5 medium default null" \
  "$(jq -r '"\(.model) \(.output_config.effort) \(.fallbacks) \(.temperature)"' "$ATMP/c1/payload.json" 2>/dev/null)" \
  "Sonnet reviews the Opus author, effort sent, refusal fallback on, no temperature"
run_anthropic c1b ZUVO_ANTHROPIC_MODEL=claude-opus-5-5 >/dev/null
assert_eq "claude-opus-5-5" "$(jq -r .model "$ATMP/c1b/payload.json" 2>/dev/null)" "ZUVO_ANTHROPIC_MODEL names another model"

# ─── 2. exact accounting ─────────────────────────────────────────────────
# Bug caught: cache reads billed at the full input price, cache writes not billed, or a fallback answer priced at the
# requested model. Sonnet 5.5: 6000·$2 + 4000·$0.10 + 1000·$2·1.25 + 2000·$10 per 1M = $0.0349.
start_test "anthropic.2 the call's tokens and cost land in the run log, priced at the model that answered"
assert_eq "$(printf '11000\t4000\t2000\t1500')" "$(lane_row c1 19-22)" "tokens: in (cached included), cached, out, thinking"
assert_eq "$(printf 'anthropic\t0.03490000\tmsg_T1')" "$(lane_row c1 23-25)" "served_by, cost_usd, the message id"
FB='{"id":"msg_F","model":"claude-opus-4-8","stop_reason":"end_turn","content":[{"type":"text","text":"NO ISSUES FOUND."}],"usage":{"input_tokens":1000,"output_tokens":1000}}'
A_BODY="$FB" run_anthropic c2 >/dev/null
# Opus 4.8: 1000·$5 + 1000·$25 per 1M = $0.03
assert_eq "0.03000000" "$(lane_row c2 24)" "a fallback answer is priced at the fallback model's rate"

# ─── 3. a spent balance: the next key, then stop ─────────────────────────
# Bug caught: Anthropic's spent balance is a 400, not OpenAI's 429 — unrecognized, it would end the review as a lane
# failure on every run all day instead of moving to the next account's credits.
start_test "anthropic.3 'credit balance is too low' passes to the next key, is remembered, and all spent stops the lane"
MULTI="$ATMP/multi.key"
( umask 077; printf 'k-one\nk-two\n' > "$MULTI" )
run_anthropic c3 ZUVO_ANTHROPIC_KEY_FILE="$MULTI" ZUVO_ANTHROPIC_CREDITS_FILE="$ATMP/c3/credits" A_SPENT_KEYS=k-one >/dev/null
assert_eq "0" "$(cat "$ATMP/c3/rc")" "the review completes on the second key"
assert_eq "k-one k-two" "$(tr '\n' ' ' < "$ATMP/c3/keys.used" | sed 's/ $//')" "key 1 spent, then key 2 used"
rm -f "$ATMP/c3/curl.urls"
out=$(run_anthropic c3 ZUVO_ANTHROPIC_KEY_FILE="$MULTI" ZUVO_ANTHROPIC_CREDITS_FILE="$ATMP/c3/credits" A_SPENT_KEYS=k-two)
assert_eq "1" "$(requests c3)" "key 1 is skipped unasked; key 2 asked once"
assert_eq "2" "$(cat "$ATMP/c3/rc")" "no key left: no review (exit 2)"
assert_contains "$out" "Anthropic credits spent on all 2 key(s)" "…and the WARN says so"

# ─── 4. a refusal is no review ───────────────────────────────────────────
# Bug caught: a declined request (HTTP 200, stop_reason refusal) read as an empty "no issues" review.
start_test "anthropic.4 a refused review is a failed lane, not a clean one"
out=$(A_BODY='{"id":"msg_R","model":"claude-sonnet-5-5","stop_reason":"refusal","stop_details":{"category":"cyber"},"content":[],"usage":{"input_tokens":10,"output_tokens":0}}' run_anthropic c4)
assert_eq "2" "$(cat "$ATMP/c4/rc")" "no review (exit 2)"
assert_contains "$out" "declined the review (refusal: cyber)" "the WARN names the refusal"

# ─── 5. opt-in ───────────────────────────────────────────────────────────
start_test "anthropic.5 the key alone does not enable the lane; ZUVO_ADV_ANTHROPIC_API=1 or the opt-in file does"
mkdir -p "$ATMP/c5"
listed() { env -u ZUVO_ANTHROPIC_API_KEY -u ZUVO_ADV_ANTHROPIC_API ZUVO_ANTHROPIC_KEY_FILE="$KEYFILE" HOME="$ATMP/c5" ZUVO_HOME="$ATMP/c5" "$@" \
  bash "$ADV" --list-providers 2>/dev/null | awk '$1 == "anthropic-api"' | tr -d '\n'; }
assert_eq "" "$(listed)" "no opt-in: not detected"
assert_eq "anthropic-api" "$(listed ZUVO_ADV_ANTHROPIC_API=1)" "the variable turns it on"
printf 'ZUVO_ADV_ANTHROPIC_API=1\n' > "$ATMP/c5/review-lanes.conf"
assert_eq "anthropic-api" "$(listed)" "review-lanes.conf turns it on for a process without the variable"
