#!/usr/bin/env bash
# test-openrouter-budget.sh — the OpenRouter daily spend cap (openrouter_budget_ok, adversarial-lanes-http.sh).
#
# 2026-10-15: one OpenRouter lane ran on ~1,700 reviews and the key spent $91 in a day. Every OpenRouter call now
# answers to the key's spend today (GET /api/v1/key → usage_daily) against ZUVO_OPENROUTER_DAILY_USD.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

BTMP="$HERE/.tmp/orb.$$"; mkdir -p "$BTMP/bin"
cleanup_orb() { rm -rf "$BTMP"; }
trap cleanup_orb EXIT

# Fake curl: records every URL (curl.urls). /key answers $ORB_KEY_BODY (a spend of $ORB_USED by default);
# everything else answers a review.
cat > "$BTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
url=""
for a in "$@"; do case "$a" in *://*) url="$a"; printf '%s\n' "$a" >> "$ORB_REC/curl.urls" ;; esac; done
case "$url" in
  */key) printf '%s' "${ORB_KEY_BODY-{\"data\":{\"usage_daily\":${ORB_USED:-1.5}}}}"; exit 0 ;;
esac
body='{"choices":[{"message":{"content":"NO ISSUES FOUND."}}]}'
printf '%s\n%s' "${ORB_CHAT_BODY:-$body}" 200
EOF
chmod +x "$BTMP/bin/curl"

# run_b <case> <lane> [VAR=value…] -> the lane's captured stderr; exit code in <home>/rc. The cap is set explicitly
# in every case: the harness skips the check otherwise.
run_b() {
  local home="$BTMP/$1" lane="$2"; shift 2
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key"; printf 'fake-plan-key' > "$home/bp.key" )
  env -u OPENROUTER_API_KEY -u ZUVO_OPENROUTER_BASE_URL -u ZUVO_OPENROUTER_USAGE_FILE -u ORB_KEY_BODY -u ORB_USED -u ORB_CHAT_BODY \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" \
    PATH="$BTMP/bin:$PATH" ORB_REC="$home" HOME="$home" ZUVO_HOME="$home" ZUVO_BYTEPLUS_KEY_FILE="$home/bp.key" \
    ZUVO_PROVIDER_HEALTH_FILE="$home/health" ZUVO_BYTEPLUS_QUOTA_FILE="$home/bpquota" \
    ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 ZUVO_OPENROUTER_DAILY_USD=5 "$@" \
    bash "$ADV" --provider "$lane" --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
urls() { cat "$BTMP/$1/curl.urls" 2>/dev/null; }
chats() { urls "$1" | awk '/chat\/completions/' | wc -l | tr -d ' '; }
keys() { urls "$1" | awk '/\/key$/' | wc -l | tr -d ' '; }

# Bug caught: an HTTP lane's tokens lost — DeepSeek reports its cache as prompt_cache_hit_tokens, not
# prompt_tokens_details.cached_tokens; a lane that never reported usage must leave the cells empty, not 0.
start_test "b.0 the response's usage lands in the row's token columns"
run_b c0 openrouter-alt ORB_USED=1.5 ORB_CHAT_BODY='{"choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":1200,"prompt_cache_hit_tokens":800,"completion_tokens":90,"completion_tokens_details":{"reasoning_tokens":40}}}' >/dev/null
assert_eq "1200 800 90 40" "$(awk -F'\t' '$14 == "openrouter-alt" { r = $19 " " $20 " " $21 " " $22 } END { print r }' "$BTMP/c0/adversarial.log" 2>/dev/null)" "in/cached/out/reasoning"
run_b c0b openrouter-alt ORB_USED=1.5 >/dev/null
assert_eq "[|||]" "$(awk -F'\t' '$14 == "openrouter-alt" { r = "[" $19 "|" $20 "|" $21 "|" $22 "]" } END { print r }' "$BTMP/c0b/adversarial.log" 2>/dev/null)" "no usage reported -> empty cells"

# Bug caught: the cap blocking a key that is under it, so the cheap lanes never review.
start_test "b.1 under the cap the review runs, and the day's spend is kept for the other lanes"
run_b c1 openrouter-alt ORB_USED=1.5 >/dev/null
assert_eq "1" "$(chats c1)" "one review request"
assert_eq "0" "$(cat "$BTMP/c1/rc")" "the review completes"
assert_contains "$(cat "$BTMP/c1/openrouter-usage" 2>/dev/null)" "1.5000" "the spend is cached"

# Bug caught: the $91 day — a lane that keeps calling after the key has spent the day's budget.
start_test "b.2 at the cap no review request is sent, and the lane is not held against"
out=$(run_b c2 openrouter-3 ORB_USED=5.00)
assert_eq "0" "$(chats c2)" "no review request"
assert_contains "$out" "OpenRouter daily budget reached" "the lane says why"
case "$(cat "$BTMP/c2/health" 2>/dev/null)" in
  *openrouter-3*) fail "the skip was recorded in the provider-health ledger" "$(cat "$BTMP/c2/health")" ;;
  *) pass "the provider-health ledger holds nothing against openrouter-3" ;;
esac

# Bug caught: spending blind when the spend cannot be read (an error body, an outage).
start_test "b.3 an unreadable spend sends no review request"
out=$(run_b c3 openrouter ORB_KEY_BODY='{"error":{"message":"Unauthorized"}}')
assert_eq "0" "$(chats c3)" "no review request"
assert_contains "$out" "could not be read" "the lane says why"

# Bug caught: one /key request per lane and chunk — or a stale spend trusted for good.
start_test "b.4 a fresh cached spend is reused; a stale one is read again"
mkdir -p "$BTMP/c4" "$BTMP/c4b"
printf '%s 9.0\n' "$(date +%s)" > "$BTMP/c4/openrouter-usage"
run_b c4 openrouter-4 ORB_USED=0.1 >/dev/null
assert_eq "0 0" "$(keys c4) $(chats c4)" "the cached \$9 stops it without asking /key"
printf '%s 9.0\n' "$(( $(date +%s) - 600 ))" > "$BTMP/c4b/openrouter-usage"
run_b c4b openrouter-4 ORB_USED=0.1 >/dev/null
assert_eq "1 1" "$(keys c4b) $(chats c4b)" "a ten-minute-old spend is read again, and \$0.10 runs"

# Bug caught: the cap lifted by accident, or the prepaid BytePlus plan stopped by the OpenRouter bill.
start_test "b.5 'off' lifts the cap; a BytePlus plan call never asks /key"
run_b c5 openrouter-alt ZUVO_OPENROUTER_DAILY_USD=off ORB_USED=500 >/dev/null
assert_eq "0 1" "$(keys c5) $(chats c5)" "off: no /key request, the review runs"
run_b c5b byteplus ZUVO_ADV_BYTEPLUS=1 ORB_USED=500 >/dev/null
assert_eq "0 1" "$(keys c5b) $(chats c5b)" "byteplus: no /key request, the review runs"

# Bug caught: yesterday's spend, cached minutes before UTC midnight, stopping today's first reviews.
start_test "b.6 a spend cached on another UTC day is read again"
mkdir -p "$BTMP/c6"
printf '%s 9.0\n' "$(( ($(date +%s) / 86400) * 86400 - 30 ))" > "$BTMP/c6/openrouter-usage"
run_b c6 openrouter-alt ORB_USED=0.1 ZUVO_OPENROUTER_USAGE_TTL=999999 >/dev/null
assert_eq "1 1" "$(keys c6) $(chats c6)" "yesterday's \$9 is not trusted today; \$0.10 runs"
