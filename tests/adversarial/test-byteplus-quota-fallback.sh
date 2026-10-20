#!/usr/bin/env bash
# test-byteplus-quota-fallback.sh — a spent BytePlus Coding Plan quota (run_byteplus, adversarial-dispatch.sh;
# byteplus_quota_*, adversarial-lanes-http.sh).
#
# The plan answers a spent quota with HTTP 429 AccountQuotaExceeded and names its reset: recorded once, the plan
# not asked again until then, glm and deepseek on the Alibaba Token Plan (qwen CLI) — never on OpenRouter, which
# bills per call — and dola-seed left out without counting against it.

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

# Fake qwen CLI: records the -m model (qwen.models) and answers a review as Qwen Code's -o json does. With
# $BPQ_ALI_MSG set it answers as qwen 0.25.3 does on a spent Token Plan: an is_error result naming the reset, exit 1,
# and a usage record of zero tokens.
cat > "$QTMP/bin/qwen" <<'EOF'
#!/usr/bin/env bash
prev=""
for a in "$@"; do [ "$prev" = "-m" ] && printf '%s\n' "$a" >> "$BPQ_REC/qwen.models"; prev="$a"; done
cat > /dev/null
if [ -n "${BPQ_ALI_MSG:-}" ]; then
  mkdir -p "$HOME/.qwen"
  jq -cn --arg p "$PWD" '{project: $p, models: {m: {inputTokens: 0, cachedTokens: 0, outputTokens: 0, thoughtsTokens: 0}}}' \
    >> "$HOME/.qwen/usage_record.jsonl"
  jq -cn --arg m "$BPQ_ALI_MSG" '[{type: "result", subtype: "error_during_execution", is_error: true, error: {message: $m}}]'
  exit 1
fi
printf '%s' '[{"type":"result","is_error":false,"result":"NO ISSUES FOUND."}]'
EOF
chmod +x "$QTMP/bin/qwen"

# The plan guard reads the CLI's settings: every stand-in is declared on a Token Plan endpoint.
QSET="$QTMP/qwen-settings.json"
jq -n '{modelProviders: {openai: [("glm-5.3","deepseek-v4.1-flash","qwen3.8-flash") as $m
  | {id: $m, baseUrl: "https://token-plan.ap-southeast-1.maas.aliyuncs.com/compatible-mode/v1"}]}}' > "$QSET"

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
    -u BPQ_SLOW -u ZUVO_MODEL_BYTEPLUS -u ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS -u ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS_ALT -u ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS_3 -u ZUVO_QWEN_MODEL -u BPQ_ALI_MSG \
    PATH="$QTMP/bin:$PATH" BPQ_REC="$home" ZUVO_BYTEPLUS_KEY_FILE="$KEYFILE" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_BYTEPLUS_QUOTA_FILE="$home/quota" ZUVO_ALIBABA_QUOTA_FILE="$home/aquota" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_QWEN_SETTINGS="$QSET" ZUVO_ADV_QWEN=1 ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=25 "$@" \
    bash "$ADV" --provider "$lane" --mode code --files "$EMPTY" >/dev/null 2>&1
  echo "$?" > "$home/rc"
  cat "$home"/adversarial-failures/*/provider_*.stderr 2>/dev/null
}
urls()   { cat "$QTMP/$1/curl.urls" 2>/dev/null; }
models() { cat "$QTMP/$1/curl.models" 2>/dev/null; }
qmodels() { cat "$QTMP/$1/qwen.models" 2>/dev/null; }
until_of() { cut -f1 "$QTMP/$1/quota" 2>/dev/null; }

NOW=$(date +%s)
RESET=$(( NOW + 5 * 86400 ))
FUTURE=$(( NOW + 86400 ))

# Bug caught: the quota 429 retried as transient (three requests a lane), the reset never recorded, the lane failed.
# The $72 day (2026-10-15): the first cut sent the stand-in to OpenRouter, metered per call. ZUVO_ADV_OPENROUTER=1
# is set in every case here, so a path back to OpenRouter shows up as a request to it.
start_test "q.1 a quota 429 is asked once, its reset recorded, and glm reviews on the Token Plan, not OpenRouter"
run_q c1 byteplus BPQ_BODY="$(quota_body "You have exceeded the monthly usage quota. It will reset at $(epoch_fmt "$RESET") +0000 CST. Request id: x")" >/dev/null
assert_eq "https://ark.ap-southeast.bytepluses.com/api/coding/v3/chat/completions" "$(urls c1)" "one plan request, no retry, nothing to OpenRouter"
assert_eq "glm-5.3" "$(qmodels c1)" "…then the Token Plan with glm's stand-in"
assert_eq "$RESET" "$(until_of c1)" "the reset the message names is recorded"
assert_eq "0" "$(cat "$QTMP/c1/rc")" "the review completes"

# Bug caught: a recorded stop ignored — every later run pays a failing plan request first.
start_test "q.2 while the stop is ahead the plan is not asked; deepseek reviews on the Token Plan"
mkdir -p "$QTMP/c2"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c2/quota"
run_q c2 byteplus-alt >/dev/null
assert_eq "" "$(urls c2)" "no HTTP request at all (plan or OpenRouter)"
assert_eq "deepseek-v4.1-flash" "$(qmodels c2)" "…the Token Plan with deepseek's stand-in"
assert_eq "0" "$(cat "$QTMP/c2/rc")" "the review completes"
assert_contains "$(cat "$QTMP/c2/adversarial.log" 2>/dev/null)" "deepseek-v4.1-flash" "the run log names the model that answered"

# Bug caught: dola-seed sent to a metered endpoint (~$7.6 a day on OpenRouter), or its skip benching the lane.
start_test "q.3 dola-seed has no stand-in: no request, and the lane is not held against"
mkdir -p "$QTMP/c3"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c3/quota"
out=$(run_q c3 byteplus-3)
assert_eq "" "$(urls c3)$(qmodels c3)" "no request at all"
assert_contains "$out" "no Token Plan stand-in for dola-seed-2.0-code" "the lane says why it did not run"
case "$(cat "$QTMP/c3/health" 2>/dev/null)" in
  *byteplus-3*) fail "the skip was recorded in the provider-health ledger" "$(cat "$QTMP/c3/health")" ;;
  *) pass "the provider-health ledger holds nothing against byteplus-3" ;;
esac

# Bug caught: a set-but-empty override ignored, so a lane the owner turned off still runs.
start_test "q.4 ZUVO_BYTEPLUS_FALLBACK_<LANE> set empty turns the stand-in off"
mkdir -p "$QTMP/c4"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c4/quota"
run_q c4 byteplus ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS= >/dev/null
assert_eq "" "$(urls c4)$(qmodels c4)" "no request at all"

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

# Bug caught: the stand-in running on a host that never opted into the Token Plan lane.
start_test "q.8 without ZUVO_ADV_QWEN=1 the lane is left out instead"
mkdir -p "$QTMP/c8"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c8/quota"
out=$(run_q c8 byteplus ZUVO_ADV_QWEN=0)
assert_eq "" "$(urls c8)$(qmodels c8)" "no request at all"
assert_contains "$out" "Token Plan not enabled" "the lane says why"

# Bug caught: a nonempty override ignored, or a lane moved to another model inheriting the old model's stand-in.
start_test "q.9 the stand-in follows the override and the lane's model"
mkdir -p "$QTMP/c9" "$QTMP/c9b"
printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c9/quota"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c9b/quota"
run_q c9 byteplus ZUVO_BYTEPLUS_FALLBACK_BYTEPLUS=qwen3.8-flash >/dev/null
assert_eq "qwen3.8-flash" "$(qmodels c9)" "an override names the Token Plan model"
run_q c9b byteplus ZUVO_MODEL_BYTEPLUS=other-model >/dev/null
assert_eq "" "$(urls c9b)$(qmodels c9b)" "a lane on a model with no stand-in is left out"

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
# The unwritable target sits under a regular file, not a chmod-ed dir: root writes through permissions.
mkdir -p "$QTMP/c13/quota.lock"; : > "$QTMP/c13/notadir"
( source "$ROOT/scripts/lib/adversarial-lanes-http.sh"
  body=$(quota_body "You have exceeded the monthly usage quota. It will reset at $(epoch_fmt "$RESET") +0000 CST.")
  ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/c13/notadir/quota" byteplus_quota_record byteplus "$body" 2>&1 >/dev/null | awk '/could not be written/' | wc -l | tr -d ' '
  ZUVO_BYTEPLUS_QUOTA_FILE="$QTMP/c13/quota" byteplus_quota_record byteplus "$body" 2>/dev/null
) > "$QTMP/c13/out"
assert_eq "1" "$(head -1 "$QTMP/c13/out")" "the unwritable stop is reported"
assert_eq "$RESET" "$(until_of c13)" "a stale lock delays the write, never stops it"
assert_eq "" "$(ls -d "$QTMP/c13/quota.lock" 2>/dev/null)" "…and the stale lock is cleared"

ali_msg() { # ali_msg <reset text> — qwen 0.25.3's message for a spent Token Plan (2026-10-20)
  printf 'Quota exhausted: Your token-plan 1-month quota has been exhausted. The quota will reset at %s.\n\nPlease retry after the reset time, or switch to another API key / auth method. (cause: insufficient_quota: 429 Your token-plan 1-month quota has been exhausted. The quota will reset at %s.)' "$1" "$1"
}

# Bug caught: the spent Token Plan asked on every review (one refused call per lane per diff for days), the stand-in
# counted as a failure, and the refusal's zero tokens logged as a measured, free call.
start_test "q.14 a spent Token Plan is recorded and not held against the lane"
mkdir -p "$QTMP/c14"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c14/quota"
ali_reset=$(( NOW + 3 * 86400 ))
ali_text="$(date -u -d "@$ali_reset" '+%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$ali_reset" '+%m-%d %H:%M:%S') UTC"
out=$(run_q c14 byteplus-alt BPQ_ALI_MSG="$(ali_msg "$ali_text")")
assert_contains "$out" "Alibaba Token Plan quota exhausted until" "the lane says why"
assert_eq "$ali_reset" "$(cut -f1 "$QTMP/c14/aquota" 2>/dev/null)" "the reset the message names (no year) is recorded"
case "$(cat "$QTMP/c14/health" 2>/dev/null)" in
  *byteplus-alt*) fail "the quota stop was recorded in the provider-health ledger" "$(cat "$QTMP/c14/health")" ;;
  *) pass "the provider-health ledger holds nothing against byteplus-alt" ;;
esac

# Bug caught: a recorded Token Plan stop ignored, so every later run pays the refused call again.
start_test "q.15 while the Token Plan stop is ahead the stand-in is not called; once past, it is"
mkdir -p "$QTMP/c15" "$QTMP/c15b"
printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c15/quota"; printf '%s\tbyteplus\n' "$FUTURE" > "$QTMP/c15b/quota"
printf '%s\tbyteplus-alt\n' "$FUTURE" > "$QTMP/c15/aquota"; printf '%s\tbyteplus-alt\n' "$(( NOW - 60 ))" > "$QTMP/c15b/aquota"
out=$(run_q c15 byteplus-alt)
assert_eq "" "$(urls c15)$(qmodels c15)" "no request at all"
assert_contains "$out" "Alibaba Token Plan quota exhausted until" "the lane says why"
run_q c15b byteplus-alt >/dev/null
assert_eq "deepseek-v4.1-flash 0" "$(qmodels c15b) $(cat "$QTMP/c15b/rc")" "a past stop: the stand-in runs and reviews"

# Bug caught: a reset without a usable date shutting the plan out for good, or a year-end reset read as last January.
start_test "q.16 the Token Plan reset: no date is an hour, a date behind this year's is next year's"
( source "$ROOT/scripts/lib/adversarial-lanes.sh"
  now=$(date +%s)
  e=$(_alibaba_reset_epoch "$(ali_msg "soon")")
  (( e >= now + 3600 && e <= $(date +%s) + 3600 )) && echo hour || echo "other:$e"
  # Two days behind today, without a year: either next year's (more than 40 days ahead → an hour) — never the past.
  past="$(date -u -d "@$(( now - 2 * 86400 ))" '+%m-%d %H:%M:%S' 2>/dev/null || date -u -r "$(( now - 2 * 86400 ))" '+%m-%d %H:%M:%S') UTC"
  e=$(_alibaba_reset_epoch "$(ali_msg "$past")")
  (( e > now )) && echo ahead || echo "past:$e"
) > "$QTMP/q16.out" 2>&1
assert_eq "hour
ahead" "$(cat "$QTMP/q16.out")" "no date → an hour; a date already behind is never taken as past"

# Bug caught: a refused call's all-zero usage (qwen records a spent-plan call as 0 in / 0 out) logged as 0 in
# columns 19-22 — a measured, free call — instead of empty; a real call next to it must still be summed.
start_test "q.17 a call reporting only zeros leaves the token columns empty"
mkdir -p "$QTMP/c17a" "$QTMP/c17b"
( source "$ROOT/scripts/lib/adversarial-ledger.sh"
  export ADV_USAGE_LANE=byteplus-alt
  JSON_TMPDIR="$QTMP/c17a"; lane_usage_add 0 0 0 0; lane_usage_add - 0 - -
  printf '%s|' "$(lane_usage_cols byteplus-alt | tr '\t' ',')"
  JSON_TMPDIR="$QTMP/c17b"; lane_usage_add 0 0 0 0; lane_usage_add 120 40 9 -
  printf '%s\n' "$(lane_usage_cols byteplus-alt | tr '\t' ',')"
) > "$QTMP/q17.out" 2>&1
assert_eq ",,,|120,40,9," "$(cat "$QTMP/q17.out")" "zeros-only calls: empty cells; a real call beside them: its numbers"
