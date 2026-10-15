#!/usr/bin/env bash
# test-byteplus-quota-fallback.sh — a spent BytePlus Coding Plan quota (run_byteplus, adversarial-dispatch.sh;
# byteplus_quota_*, adversarial-lanes-http.sh).
#
# The plan answers a spent quota with HTTP 429 AccountQuotaExceeded and names its reset: recorded once, the plan
# not asked again until then, glm and deepseek on OpenRouter, dola-seed left out without counting against it.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

QTMP="$HERE/.tmp/bpq.$$"; mkdir -p "$QTMP/bin"
cleanup_bpq() { rm -rf "$QTMP"; }
trap cleanup_bpq EXIT
KEYFILE="$QTMP/byteplus.key"
( umask 077; printf 'fake-plan-key' > "$KEYFILE" )

# Fake curl: records each request's URL (curl.urls) and model (curl.models). The plan's host answers the body in
# $BPQ_BODY with HTTP 429 when one is set (after $BPQ_SLOW seconds, when set), else a review; every other host
# answers a review.
cat > "$QTMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
prev="" url=""
for a in "$@"; do
  [ "$prev" = "-d" ] && jq -r '.model' "${a#@}" >> "$BPQ_REC/curl.models"
  case "$a" in *://*) url="$a"; printf '%s\n' "$a" >> "$BPQ_REC/curl.urls" ;; esac
  prev="$a"
done
case "$url" in
  *bytepluses.com*) [ -n "${BPQ_SLOW:-}" ] && sleep "$BPQ_SLOW"
                    [ -n "${BPQ_BODY:-}" ] && { printf '%s\n%s' "$BPQ_BODY" 429; exit 0; } ;;
esac
printf '%s\n%s' '{"choices":[{"message":{"content":"NO ISSUES FOUND."}}]}' 200
EOF
chmod +x "$QTMP/bin/curl"

epoch_fmt() { date -u -d "@$1" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%M:%S'; }
quota_body() { # quota_body <message>
  jq -cn --arg m "$1" '{error: {code: "AccountQuotaExceeded", message: $m, type: "TooManyRequests"}}'
}

# run_q <case> <lane> [VAR=value…] -> the lane's captured stderr; exit code in <home>/rc. Each case its own home,
# OpenRouter key and quota file (<home>/quota); ZUVO_PROVIDER_HEALTH_FILE is <home>/health.
run_q() {
  local home="$QTMP/$1" lane="$2"; shift 2
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  env -u ZUVO_BYTEPLUS_BASE_URL -u ZUVO_OPENROUTER_BASE_URL -u OPENROUTER_API_KEY -u BPQ_BODY \
    -u BPQ_SLOW -u ZUVO_MODEL_BYTEPLUS -u ZUVO_BYTEPLUS_OR_FALLBACK_BYTEPLUS -u ZUVO_BYTEPLUS_OR_FALLBACK_BYTEPLUS_ALT -u ZUVO_BYTEPLUS_OR_FALLBACK_BYTEPLUS_3 \
    PATH="$QTMP/bin:$PATH" BPQ_REC="$home" ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_BYTEPLUS_QUOTA_FILE="$home/quota" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 "$@" \
    bash "$ADV" --provider "$lane" --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
urls()   { cat "$QTMP/$1/curl.urls" 2>/dev/null; }
models() { cat "$QTMP/$1/curl.models" 2>/dev/null; }
until_of() { cut -f1 "$QTMP/$1/quota" 2>/dev/null; }

NOW=$(date +%s)
RESET=$(( NOW + 5 * 86400 ))
FUTURE=$(( NOW + 86400 ))

# Bug caught: the quota 429 retried as transient (three requests a lane), the reset never recorded, the lane failed.
start_test "q.1 a quota 429 is asked once, its reset recorded, and glm reviews on OpenRouter"
run_q c1 byteplus BPQ_BODY="$(quota_body "You have exceeded the monthly usage quota. It will reset at $(epoch_fmt "$RESET") +0000 CST. Request id: x")" >/dev/null
assert_eq "https://ark.ap-southeast.bytepluses.com/api/coding/v3/chat/completions
https://openrouter.ai/api/v1/chat/completions" "$(urls c1)" "one plan request, no retry, then one OpenRouter request"
assert_eq "glm-5.3-flash
z-ai/glm-5.3-flash" "$(models c1)" "…the OpenRouter one with glm's stand-in"
assert_eq "$RESET" "$(until_of c1)" "the reset the message names is recorded"
assert_eq "0" "$(cat "$QTMP/c1/rc")" "the review completes"

# Bug caught: a recorded stop ignored — every later run pays a failing plan request first.
start_test "q.2 while the stop is ahead the plan is not asked; deepseek reviews on OpenRouter"
mkdir -p "$QTMP/c2"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c2/quota"
run_q c2 byteplus-alt >/dev/null
assert_eq "https://openrouter.ai/api/v1/chat/completions" "$(urls c2)" "no plan request, one OpenRouter request"
assert_eq "deepseek/deepseek-v4.1-flash" "$(models c2)" "…with deepseek's stand-in"
assert_eq "0" "$(cat "$QTMP/c2/rc")" "the review completes"
assert_contains "$(cat "$QTMP/c2/adversarial.log" 2>/dev/null)" "deepseek/deepseek-v4.1-flash" "the run log names the model that answered"

# Bug caught: dola-seed sent to OpenRouter (~$7.6 a day), or its skip benching the lane in the health ledger.
start_test "q.3 dola-seed has no stand-in: no request, and the lane is not held against"
mkdir -p "$QTMP/c3"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c3/quota"
out=$(run_q c3 byteplus-3)
assert_eq "" "$(urls c3)" "no request at all"
assert_contains "$out" "no OpenRouter fallback for dola-seed-2.0-code" "the lane says why it did not run"
case "$(cat "$QTMP/c3/health" 2>/dev/null)" in
  *byteplus-3*) fail "the skip was recorded in the provider-health ledger" "$(cat "$QTMP/c3/health")" ;;
  *) pass "the provider-health ledger holds nothing against byteplus-3" ;;
esac

# Bug caught: a set-but-empty override ignored, so a lane the owner turned off still bills OpenRouter.
start_test "q.4 ZUVO_BYTEPLUS_OR_FALLBACK_<LANE> set empty turns the stand-in off"
mkdir -p "$QTMP/c4"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c4/quota"
run_q c4 byteplus ZUVO_BYTEPLUS_OR_FALLBACK_BYTEPLUS= >/dev/null
assert_eq "" "$(urls c4)" "no request at all"

# Bug caught: a stop that never lifts — the plan shut out after its reset.
start_test "q.5 a stop that has passed asks the plan again"
mkdir -p "$QTMP/c5"; printf '%s\tbyteplus\n' "$(( NOW - 60 ))" > "$QTMP/c5/quota"
run_q c5 byteplus >/dev/null
assert_eq "https://ark.ap-southeast.bytepluses.com/api/coding/v3/chat/completions" "$(urls c5)" "the plan is asked"
assert_eq "0" "$(cat "$QTMP/c5/rc")" "…and reviews"

# Bug caught: a message without a usable date shutting the plan out for good (or not at all).
start_test "q.6 a reset the message does not name is taken as one hour"
run_q c6 byteplus BPQ_BODY="$(quota_body "You have exceeded the 5-hour usage quota.")" >/dev/null
got=$(until_of c6); got=${got:-0}
if (( got >= NOW + 3600 && got <= $(date +%s) + 3600 )); then pass "recorded about an hour ahead"
else fail "expected about now + 3600, got $got (now $NOW)"; fi

# Bug caught: a 5-hour window's answer, arriving while another run records the monthly stop, overwriting it — so
# later runs ask the spent plan again. Called directly: through the driver a stop on file means no plan request.
start_test "q.7 a later reset already on file is kept"
mkdir -p "$QTMP/c7"; printf '%s\tbyteplus\n' "$RESET" > "$QTMP/c7/quota"
( source "$ROOT/scripts/lib/adversarial-lanes-http.sh"
  JSON_TMPDIR="$QTMP/c7" ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/c7/quota" \
    byteplus_quota_record byteplus "$(quota_body "You have exceeded the 5-hour usage quota. It will reset at $(epoch_fmt "$FUTURE") +0000 CST.")" ) 2>/dev/null
assert_eq "$RESET" "$(until_of c7)" "the monthly reset stays"
mkdir -p "$QTMP/c7b"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c7b/quota"
( source "$ROOT/scripts/lib/adversarial-lanes-http.sh"
  JSON_TMPDIR="$QTMP/c7b" ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/c7b/quota" \
    byteplus_quota_record byteplus "$(quota_body "You have exceeded the monthly usage quota. It will reset at $(epoch_fmt "$RESET") +0000 CST.")" ) 2>/dev/null
assert_eq "$RESET" "$(until_of c7b)" "…while a later reset replaces an earlier one"

# Bug caught: the stand-in spending on OpenRouter on a host that never opted into the paid lanes.
start_test "q.8 without ZUVO_ADV_OPENROUTER=1 the lane is left out instead"
mkdir -p "$QTMP/c8"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c8/quota"
out=$(run_q c8 byteplus ZUVO_ADV_OPENROUTER=0)
assert_eq "" "$(urls c8)" "no request at all"
assert_contains "$out" "OpenRouter not enabled" "the lane says why"

# Bug caught: a nonempty override ignored, or a lane moved to another model inheriting the old model's stand-in.
start_test "q.9 the stand-in follows the override and the lane's model"
mkdir -p "$QTMP/c9" "$QTMP/c9b"
printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c9/quota"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c9b/quota"
run_q c9 byteplus ZUVO_BYTEPLUS_OR_FALLBACK_BYTEPLUS=vendor/stand-in >/dev/null
assert_eq "vendor/stand-in" "$(models c9)" "an override names the OpenRouter model"
run_q c9b byteplus ZUVO_MODEL_BYTEPLUS=other-model >/dev/null
assert_eq "" "$(urls c9b)" "a lane on a model with no stand-in is left out"

# Bug caught: an ordinary throttling 429 from the plan taken for a spent quota — the plan shut out for an hour.
start_test "q.10 a 429 that is not a quota stop is retried and records nothing"
run_q c10 byteplus BPQ_BODY='{"error":{"code":"RateLimitExceeded","message":"slow down"}}' >/dev/null
assert_eq "3" "$(urls c10 | awk '/bytepluses/' | wc -l | tr -d ' ')" "the plan is asked again (three attempts)"
assert_eq "" "$(until_of c10)" "no quota stop is recorded"

# Bug caught: the stand-in started with no time left, or a quota stop lost without saying so.
start_test "q.11 a quota answer that leaves too little of the budget starts no stand-in"
run_q c11 byteplus BPQ_SLOW=16 ZUVO_REVIEW_TIMEOUT=20 \
  BPQ_BODY="$(quota_body "You have exceeded the monthly usage quota. It will reset at $(epoch_fmt "$RESET") +0000 CST.")" >/dev/null
assert_eq "https://ark.ap-southeast.bytepluses.com/api/coding/v3/chat/completions" "$(urls c11)" "only the plan request"
assert_eq "$RESET" "$(until_of c11)" "…and the stop is still recorded for the next run"

# Bug caught: an implausible or unreadable stop shutting the plan out (a month, forever) or crashing the lane.
start_test "q.12 implausible resets and unreadable stop files"
( source "$ROOT/scripts/lib/adversarial-lanes-http.sh"
  now=$(date +%s)
  for when in "$(epoch_fmt $(( now + 60 * 86400 )))" "$(epoch_fmt $(( now - 86400 )))"; do
    e=$(_byteplus_reset_epoch "It will reset at $when +0000 CST.")
    (( e >= now + 3600 && e <= $(date +%s) + 3600 )) && echo hour || echo "other:$e"
  done
  printf 'not-a-number\tbyteplus\n' > "$QTMP/q12.quota"
  ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/q12.quota" byteplus_quota_until && echo stopped || echo open
) > "$QTMP/q12.out" 2>&1
assert_eq "hour
hour
open" "$(cat "$QTMP/q12.out")" "60 days ahead and yesterday are taken as an hour; a garbage file stops nothing"

# Bug caught: a stop that could not be written passing silently, or a lock left by a killed run blocking it forever.
start_test "q.13 a failed write says so, and a stale lock is waited out"
mkdir -p "$QTMP/c13/ro" "$QTMP/c13/quota.lock"; chmod 500 "$QTMP/c13/ro"
( source "$ROOT/scripts/lib/adversarial-lanes-http.sh"
  body=$(quota_body "You have exceeded the monthly usage quota. It will reset at $(epoch_fmt "$RESET") +0000 CST.")
  ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/c13/ro/quota" byteplus_quota_record byteplus "$body" 2>&1 >/dev/null | awk '/could not be written/' | wc -l | tr -d ' '
  ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/c13/quota" byteplus_quota_record byteplus "$body" 2>/dev/null
) > "$QTMP/c13/out"
chmod 700 "$QTMP/c13/ro"
assert_eq "1" "$(head -1 "$QTMP/c13/out")" "the unwritable stop is reported"
assert_eq "$RESET" "$(until_of c13)" "a stale lock delays the write, never stops it"
