#!/usr/bin/env bash
# test-openrouter-free-quota.sh — an OpenRouter lane on a `:free` model (here `openrouter-mini` set to
# minimax/minimax-m3.1-flash:free, the model it ran 2026-10-20..22; its default is the paid id since 2026-10-24):
# never priced against the daily spend cap, and a 429 (its free ration spent) kept as a quota stop
# (openrouter_free_quota_*, adversarial-lanes-http.sh) instead of retried on every chunk.

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

FREE_MODEL="minimax/minimax-m3.1-flash:free"
# [RUN_LANE=<lane>] run_f <case> [VAR=value…] -> the stderr of the lane (default openrouter-mini); exit code in <home>/rc; stop file <home>/quota.
run_f() {
  local home="$FTMP/$1"; shift
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  env -u OPENROUTER_API_KEY -u ZUVO_OPENROUTER_BASE_URL -u ORF_429 -u ORF_USED \
    PATH="$FTMP/bin:$PATH" ORF_REC="$home" HOME="$home" ZUVO_HOME="$home" ZUVO_MODEL_OPENROUTER_MINI="$FREE_MODEL" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_OPENROUTER_FREE_QUOTA_FILE="$home/quota" ZUVO_OPENROUTER_USAGE_FILE="$home/usage" \
    ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 ZUVO_OPENROUTER_DAILY_USD=5 "$@" \
    bash "$ADV" --provider "${RUN_LANE:-openrouter-mini}" --mode code --files "$EMPTY" >/dev/null 2>&1
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

# Bug caught: the paid lane the owner turned off (2026-10-30) still billed through the default roster.
start_test "fq.1 ZUVO_ADV_OPENROUTER=1 with a key leaves openrouter-mini out of the default roster"
mkdir -p "$FTMP/c1/.zuvo"; ( umask 077; printf 'k' > "$FTMP/c1/.zuvo/openrouter.key" )
listed=$(env -u OPENROUTER_API_KEY -u ZUVO_ADV_OPENROUTER_LANES HOME="$FTMP/c1" ZUVO_HOME="$FTMP/c1" ZUVO_ADV_OPENROUTER=1 \
  bash "$ADV" --list-providers 2>/dev/null | awk '$1 == "openrouter-mini"')
assert_eq "" "$listed" "not listed by detection"
listed=$(env -u OPENROUTER_API_KEY HOME="$FTMP/c1" ZUVO_HOME="$FTMP/c1" ZUVO_ADV_OPENROUTER=1 ZUVO_ADV_OPENROUTER_LANES=openrouter-mini \
  bash "$ADV" --list-providers 2>/dev/null | awk '$1 == "openrouter-mini"')
assert_eq "openrouter-mini" "$listed" "still listed when named in ZUVO_ADV_OPENROUTER_LANES"

# Bug caught: the wrong model sent (a paid id, or "unknown"), or a $0 model stopped by the spend cap that bounds
# the paid lanes — today's spend is over the cap here, and the free lane still reviews without asking /key.
start_test "fq.2 the review goes to OpenRouter with the exact :free model id set, and the spend cap does not stop it"
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

LIB="$ROOT/scripts/lib/adversarial-lanes-http.sh"
# lib <fn> [args…] — one helper of the HTTP lane module, run alone (stdout; stderr dropped). QF names the stop file.
lib() { ZUVO_OPENROUTER_FREE_QUOTA_FILE="${QF:-}" bash -c '. "$1" || exit 9; shift; "$@"' _ "$LIB" "$@" 2>/dev/null; }

# Bug caught: a reset taken on trust (already past, or days out) stopping the lane for nothing or for days; the
# seconds form read as milliseconds; the daily ration and an upstream throttle given the same stop.
start_test "fq.5 the 429's reset: a plausible one is kept, otherwise next UTC midnight (daily) or five minutes"
N=1000000000   # a fixed now, 2001-09-09 01:46:40 UTC; its next UTC midnight is 1000080000
day='Rate limit exceeded: free-models-per-day.'
assert_eq "1000000600" "$(lib _openrouter_free_reset_epoch "$(rl_body "$day" 1000000600000)" $N)" "milliseconds -> seconds"
assert_eq "1000000600" "$(lib _openrouter_free_reset_epoch "$(rl_body "$day" 1000000600)" $N)" "seconds kept as seconds"
assert_eq "1000080000" "$(lib _openrouter_free_reset_epoch "$(rl_body "$day" 999999000000)" $N)" "a past reset, daily -> next UTC midnight"
assert_eq "1000080000" "$(lib _openrouter_free_reset_epoch "$(rl_body "$day" 1000777600000)" $N)" "nine days out, daily -> next UTC midnight"
assert_eq "1000080000" "$(lib _openrouter_free_reset_epoch "$(rl_body "$day")" $N)" "no reset, daily -> next UTC midnight"
assert_eq "1000000300" "$(lib _openrouter_free_reset_epoch "$(rl_body "Provider returned error")" $N)" "no reset, upstream throttle -> five minutes"

# Bug caught: a short per-minute 429 overwriting a daily stop, so the next run asks a spent ration again.
start_test "fq.6 a nearer reset does not shorten a later stop on file; a later one replaces it"
QF="$FTMP/c6.quota"; far=$(( $(date +%s) + 21600 ))
printf '%s\topenrouter-mini\n' "$far" > "$QF"
assert_eq "$far" "$(lib openrouter_free_quota_record openrouter-mini "$(rl_body x "$(( $(date +%s) + 300 ))000")")" "the later stop stays in force"
assert_eq "$far" "$(cut -f1 "$QF")" "the file still holds it"
farther=$(( far + 3600 ))
lib openrouter_free_quota_record openrouter-mini "$(rl_body x "${farther}000")" >/dev/null
assert_eq "$farther" "$(cut -f1 "$QF")" "a later reset is written"

# Bug caught: a torn or foreign stop file read as a stop, silencing the lane on garbage.
start_test "fq.7 a stop file that is empty or not an epoch is no stop"
QF="$FTMP/c7.quota"; : > "$QF"
assert_eq "1" "$(lib openrouter_free_quota_until >/dev/null; echo $?)" "empty file"
printf 'soon\topenrouter-mini\n' > "$QF"
assert_eq "1" "$(lib openrouter_free_quota_until >/dev/null; echo $?)" "not an epoch"
QF=""

# Bug caught: a paid lane's ordinary 429 (transient, retried) parked as a free-ration stop.
start_test "fq.8 a paid OpenRouter lane's 429 writes no free-model stop"
RUN_LANE=openrouter-alt run_f c8 ORF_429="$(rl_body "Rate limit exceeded")" ZUVO_OPENROUTER_FREE_QUOTA_FILE="$FTMP/c8/quota" >/dev/null
assert_eq "no" "$([ -e "$FTMP/c8/quota" ] && echo yes || echo no)" "no free-model stop file"

# Bug caught: the paid default of openrouter-mini (since 2026-10-24) still exempt from the spend cap like the :free id
# it replaced — billed with no ceiling.
start_test "fq.10 the paid default of openrouter-mini is stopped by the spend cap"
run_f c10 ORF_USED=9 ZUVO_MODEL_OPENROUTER_MINI= >/dev/null
assert_eq "0" "$(chats c10)" "no chat request over the cap"
assert_eq "1" "$(keys c10)" "the spend asked of /key"

# Bug caught: a spent free ration still drawn into the fan-out, taking a slot a working lane could fill.
start_test "fq.9 a free-model stop ahead leaves openrouter-mini out before the fan-out draw"
mkdir -p "$FTMP/c9"; printf '%s\topenrouter-mini\n' "$(( $(date +%s) + 3600 ))" > "$FTMP/c9/quota"
out=$(PATH="$HERE/mocks:$PATH" ZUVO_MODEL_OPENROUTER_MINI="$FREE_MODEL" ZUVO_OPENROUTER_FREE_QUOTA_FILE="$FTMP/c9/quota" ZUVO_REVIEW_PROVIDER_PICK=ranked ZUVO_REVIEW_MAX_PROVIDERS=2 \
  ZUVO_REVIEW_TEST_PROVIDERS="openrouter-mini mock-success mock-success" \
  bash "$ADV" --multi --json --files "$EMPTY" 2>"$FTMP/c9/err")
assert_contains "$(cat "$FTMP/c9/err")" "openrouter-mini (OpenRouter free-model quota until" "named among the known stops, with its reason"
assert_eq "mock-success, mock-success" "$(printf '%s' "$out" | python3 -c 'import sys,json;print(json.load(sys.stdin).get("providers_used","?"))' 2>/dev/null)" "only the working lanes ran"
