#!/usr/bin/env bash
# test-openrouter-free-quota.sh — the free OpenRouter lane `openrouter-mini` (minimax/minimax-m3.1-flash:free):
# in the default roster, never priced against the daily spend cap, and a 429 (its free ration spent) kept as a
# quota stop (openrouter_free_quota_*, adversarial-lanes-http.sh) instead of retried on every chunk.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

FTMP="$HERE/.tmp/orfree.$$"; mkdir -p "$FTMP/bin"
cleanup_orfree() { rm -rf "$FTMP"; }
trap cleanup_orfree EXIT

# Fake curl: records each URL (curl.urls) and each request's model (curl.models). /key answers a spend of
# $ORF_USED; a chat request answers $ORF_429 with HTTP 429 when it is set, else a review.
cat > "$FTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev="" url=""
for a in "$@"; do
  [ "$prev" = "-d" ] && jq -r '.model' "${a#@}" >> "$ORF_REC/curl.models"
  case "$a" in *://*) url="$a"; printf '%s\n' "$a" >> "$ORF_REC/curl.urls" ;; esac
  prev="$a"
done
case "$url" in
  */key) printf '{"data":{"usage_daily":%s}}' "${ORF_USED:-0}"; exit 0 ;;
esac
[ -n "${ORF_429:-}" ] && { printf '%s\n%s' "$ORF_429" 429; exit 0; }
printf '%s\n%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":10,"completion_tokens":2,"cost":0}}' 200
EOF
chmod +x "$FTMP/bin/curl"

# run_f <case> [VAR=value…] -> the lane's captured stderr; exit code in <home>/rc; stop file <home>/quota.
run_f() {
  local home="$FTMP/$1"; shift
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  env -u OPENROUTER_API_KEY -u ZUVO_OPENROUTER_BASE_URL -u ZUVO_MODEL_OPENROUTER_MINI -u ORF_429 -u ORF_USED \
    PATH="$FTMP/bin:$PATH" ORF_REC="$home" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_OPENROUTER_FREE_QUOTA_FILE="$home/quota" ZUVO_OPENROUTER_USAGE_FILE="$home/usage" \
    ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 ZUVO_OPENROUTER_DAILY_USD=5 "$@" \
    bash "$ADV" --provider openrouter-mini --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
chats() { awk '/chat\/completions/' "$FTMP/$1/curl.urls" 2>/dev/null | wc -l | tr -d ' '; }
keys()  { awk '/\/key$/' "$FTMP/$1/curl.urls" 2>/dev/null | wc -l | tr -d ' '; }
held_against() { # held_against <case> — "yes" when the provider-health ledger names the lane
  case "$(cat "$FTMP/$1/health" 2>/dev/null)" in *openrouter-mini*) echo yes ;; *) echo no ;; esac
}
rl_body() { # rl_body <message> [<X-RateLimit-Reset ms>] — OpenRouter's 429 shape
  jq -cn --arg m "$1" --arg r "${2:-}" \
    '{error: ({message: $m, code: 429} + (if $r == "" then {} else {metadata: {headers: {"X-RateLimit-Reset": $r}}} end))}'
}

# Bug caught: the lane missing from the default roster, so the owner's ZUVO_ADV_OPENROUTER=1 never runs it.
start_test "fq.1 ZUVO_ADV_OPENROUTER=1 with a key puts openrouter-mini in the default roster"
mkdir -p "$FTMP/c1/.zuvo"; ( umask 077; printf 'k' > "$FTMP/c1/.zuvo/openrouter.key" )
listed=$(env -u OPENROUTER_API_KEY -u ZUVO_ADV_OPENROUTER_LANES HOME="$FTMP/c1" ZUVO_HOME="$FTMP/c1" ZUVO_ADV_OPENROUTER=1 \
  bash "$ADV" --list-providers 2>/dev/null | awk '$1 == "openrouter-mini"')
assert_eq "openrouter-mini" "$listed" "listed by detection"

# Bug caught: the wrong model sent (a paid id, or "unknown"), or a $0 model stopped by the spend cap that bounds
# the paid lanes — today's spend is over the cap here, and the free lane still reviews without asking /key.
start_test "fq.2 the review goes to OpenRouter with the exact :free model id, and the spend cap does not stop it"
run_f c2 ORF_USED=9 >/dev/null
assert_eq "minimax/minimax-m3.1-flash:free" "$(cat "$FTMP/c2/curl.models" 2>/dev/null)" "the exact model id"
assert_eq "https://openrouter.ai/api/v1/chat/completions" "$(cat "$FTMP/c2/curl.urls" 2>/dev/null)" "one chat request to OpenRouter, no /key"
assert_eq "0" "$(cat "$FTMP/c2/rc")" "the review completes"

# Bug caught: the free ration's 429 retried as transient (three requests a chunk), never remembered, and benching
# the lane in the health ledger as if it had failed.
start_test "fq.3 a 429 is asked once, its reset recorded, and not held against the lane"
reset=$(( $(date +%s) + 7200 ))
out=$(run_f c3 ORF_429="$(rl_body "Rate limit exceeded: free-models-per-day." "${reset}000")")
assert_eq "1" "$(chats c3)" "one request, no retry"
assert_eq "$reset" "$(cut -f1 "$FTMP/c3/quota" 2>/dev/null)" "the X-RateLimit-Reset epoch is recorded"
assert_contains "$out" "OpenRouter free-model quota spent until" "the lane says why"
assert_eq "no" "$(held_against c3)" "the provider-health ledger holds nothing against it"

# Bug caught: every later chunk and run paying another refused request while the ration is spent — or a stop that
# never lifts once its reset has passed.
start_test "fq.4 while the stop is ahead nothing is sent; once it has passed the lane reviews again"
mkdir -p "$FTMP/c4" "$FTMP/c4b"
printf '%s\topenrouter-mini\n' "$(( $(date +%s) + 600 ))" > "$FTMP/c4/quota"
run_f c4 >/dev/null
assert_eq "0 0 no" "$(chats c4) $(keys c4) $(held_against c4)" "no request (chat or /key) while the stop is ahead, not held against"
printf '%s\topenrouter-mini\n' "$(( $(date +%s) - 60 ))" > "$FTMP/c4b/quota"
run_f c4b >/dev/null
assert_eq "1 0" "$(chats c4b) $(cat "$FTMP/c4b/rc")" "a past stop: asked, and it reviews"

# Bug caught: a reset the 429 does not name stopping the lane for good, or not at all.
start_test "fq.5 a daily 429 with no reset named stops until the next UTC midnight; an upstream throttle for minutes"
now=$(date +%s)
run_f c5 ORF_429="$(rl_body "Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day")" >/dev/null
assert_eq "$(( (now / 86400 + 1) * 86400 ))" "$(cut -f1 "$FTMP/c5/quota" 2>/dev/null)" "per-day -> next UTC midnight"
run_f c5b ORF_429="$(rl_body "Provider returned error")" >/dev/null
got=$(cut -f1 "$FTMP/c5b/quota" 2>/dev/null); got=${got:-0}
if (( got >= now + 300 && got <= $(date +%s) + 300 )); then pass "upstream throttle -> about five minutes"
else fail "expected about now + 300, got $got (now $now)"; fi
