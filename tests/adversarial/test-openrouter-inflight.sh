#!/usr/bin/env bash
# test-openrouter-inflight.sh — the per-model in-flight cap of the OpenRouter lanes (openrouter_inflight_cap,
# or_inflight_acquire/release in adversarial-lanes-http.sh) and the HTTP 429 policy of `openrouter-5`
# (inception/mercury-3, whose only host throttles overlapping calls): calls beyond the cap wait for a slot inside
# their budget, a dead holder's slot is broken, a call that never gets one is not held against the lane, and a 429
# is retried a bounded number of times and then counted as the lane's own failure.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1
unset SLOTS

ITMP="$HERE/.tmp/orinflight.$$"; mkdir -p "$ITMP/bin"
cleanup_orinflight() { rm -rf "$ITMP"; }
trap cleanup_orinflight EXIT

# Fake curl: each chat request appends "<start> <end>" (epoch ms) to <rec>/spans and its model to <rec>/models;
# /key answers a spend of $0. A chat answers HTTP 429 when IF_429 is set, else a review after IF_SLEEP seconds.
cat > "$ITMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
now_ms() { perl -MTime::HiRes=time -e 'printf "%.0f\n", time * 1000'; }   # date +%N is GNU only
prev="" url="" model=""
for a in "$@"; do
  [ "$prev" = "-d" ] && model="$(jq -r '.model' "${a#@}")"
  case "$a" in *://*) url="$a" ;; esac
  prev="$a"
done
case "$url" in */key) printf '{"data":{"usage_daily":0}}'; exit 0 ;; esac
printf '%s\n' "$model" >> "$IF_REC/models"
t0=$(now_ms)
if [ -n "${IF_429:-}" ]; then
  printf '%s %s\n' "$t0" "$(now_ms)" >> "$IF_REC/spans"
  printf '%s\n%s' '{"error":{"message":"Provider returned error","code":429,"metadata":{"provider_name":"Inception"}}}' 429
  exit 0
fi
sleep "${IF_SLEEP:-0}"
printf '%s %s\n' "$t0" "$(now_ms)" >> "$IF_REC/spans"
printf '%s\n%s' '{"provider":"Inception","choices":[{"message":{"content":"NO ISSUES FOUND."}}],"usage":{"prompt_tokens":10,"completion_tokens":2}}' 200
EOF
chmod +x "$ITMP/bin/curl"

# run_i <case> [VAR=value…] — one openrouter-5 review; its stderr in <case>/err, its exit code
# in <case>/rc. Every case shares one slot root unless SLOTS names another.
run_i() {
  local home="$ITMP/$1"; shift
  mkdir -p "$home/.zuvo"
  ( umask 077; printf 'fake-or-key' > "$home/.zuvo/openrouter.key" )
  env -u OPENROUTER_API_KEY -u ZUVO_OPENROUTER_BASE_URL -u ZUVO_MODEL_OPENROUTER_5 -u ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3 \
    -u ZUVO_OR_PROVIDER_ORDER -u IF_429 -u IF_SLEEP \
    PATH="$ITMP/bin:$PATH" IF_REC="$home" HOME="$home" ZUVO_HOME="$home" \
    ZUVO_OR_INFLIGHT_DIR="${SLOTS:-$ITMP/slots}" \
    ZUVO_ADVERSARIAL_LOG_FILE="$home/adversarial.log" ZUVO_PROVIDER_HEALTH_FILE="$home/health" \
    ZUVO_OPENROUTER_USAGE_FILE="$home/usage" ZUVO_OPENROUTER_FREE_QUOTA_FILE="$home/openrouter-free-quota-until" \
    ZUVO_ADV_OPENROUTER=1 ZUVO_PROVIDER_BENCH=1 \
    ZUVO_REVIEW_TIMEOUT=40 ZUVO_OPENROUTER_DAILY_USD=5 "$@" \
    bash "$ADV" --provider openrouter-5 --mode code --files "$EMPTY" >/dev/null 2>"$home/err"
  echo "$?" > "$home/rc"
}
chats() { if [[ -f "$ITMP/$1/spans" ]]; then wc -l < "$ITMP/$1/spans" | tr -d ' '; else echo 0; fi; }
strikes() { # strikes <case> — the provider-health ledger's failure count for openrouter-5 (0 when no row)
  [[ -f "$ITMP/$1/health" ]] || { echo 0; return; }
  awk -F'\t' '$1 == "openrouter-5" {print $3; f=1} END {if (!f) print 0}' "$ITMP/$1/health"
}
slots_left() { find "${1:-$ITMP/slots}" -mindepth 2 -maxdepth 2 -name 'slot.*' 2>/dev/null | wc -l | tr -d ' '; }

LIB="$ROOT/scripts/lib/adversarial-lanes-http.sh"
cap() { bash -c '. "$1" || exit 9; shift; openrouter_inflight_cap "$@"' _ "$LIB" "$@" 2>"$ITMP/cap.err"; }

# Bug caught: mercury sent uncapped into its host's rate limit, a cap leaking onto models that do not need it, an
# owner's 0 not lifting it, a typo or a negative silently removing the cap, or the override keyed by a lane while the
# slots are shared by every lane on the model.
start_test "if.1 the cap: 3 for mercury-3, none for other models, the model's env var wins, a malformed one falls back"
assert_eq "3" "$(cap inception/mercury-3)" "mercury-3 default"
assert_eq "0" "$(cap minimax/minimax-m3.1-flash)" "no cap for another model"
assert_eq "1" "$(ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=1 cap inception/mercury-3)" "env sets it"
assert_eq "0" "$(ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=0 cap inception/mercury-3)" "env 0 lifts it"
assert_eq "0" "$(ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3= cap inception/mercury-3)" "set but empty lifts it"
assert_eq "3" "$(ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=lots cap inception/mercury-3)" "malformed -> the default"
assert_contains "$(cat "$ITMP/cap.err")" "ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3='lots' is not a number" "the typo is reported"
assert_eq "3" "$(ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=-1 cap inception/mercury-3)" "negative -> the default"
assert_eq "2" "$(ZUVO_OR_MAX_INFLIGHT_XIAOMI_MIMO_V2_6_FLASH=2 cap xiaomi/mimo-v2.6-flash)" "any model can be capped"

# Bug caught: parallel reviews overlapping their calls past the cap — the 429 storm the cap exists to prevent.
start_test "if.2 with a cap of 1, two concurrent reviews' calls never overlap, and both complete"
run_i c2a ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=1 IF_SLEEP=2 &
run_i c2b ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=1 IF_SLEEP=2 &
wait
assert_eq "0 0" "$(cat "$ITMP/c2a/rc") $(cat "$ITMP/c2b/rc")" "both reviews complete"
assert_eq "1 1" "$(chats c2a) $(chats c2b)" "one request each"
a0="" a1="" b0="" b1=""
read -r a0 a1 < "$ITMP/c2a/spans"; read -r b0 b1 < "$ITMP/c2b/spans"
assert_eq "yes" "$([[ -n "$a1" && -n "$b1" ]] && echo yes || echo no)" "both spans recorded"
assert_eq "yes" "$( (( a1 <= b0 || b1 <= a0 )) && echo yes || echo no)" "the two calls ran one after the other"
assert_eq "0" "$(slots_left)" "every slot given back"

# Bug caught: a call that cannot get a slot hanging past its budget, still sending its request, or benching a
# healthy lane for its own ZUVO_HOME's queue.
start_test "if.3 every slot held by a live call for the whole budget: not run, nothing sent, not held against the lane"
mkdir -p "$ITMP/slots3/inception_mercury-3/slot.1"; printf '%s\n' "$$" > "$ITMP/slots3/inception_mercury-3/slot.1/pid"
SLOTS="$ITMP/slots3" run_i c3 ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=1 ZUVO_REVIEW_TIMEOUT=20
assert_eq "0" "$(chats c3)" "no chat request"
assert_contains "$(cat "$ITMP/c3/err")" "in-flight slots for inception/mercury-3 under this ZUVO_HOME stayed busy" "the lane says why"
assert_eq "yes" "$(grep -Eq 'stayed busy for [1-9][0-9]*s' "$ITMP/c3/err" && echo yes || echo no)" "it waited before giving up"
assert_eq "0" "$(strikes c3)" "no strike in the provider-health ledger"

# Bug caught: a review killed by a timeout leaving its slot taken forever, so the lane's capacity shrinks to nothing.
start_test "if.4 a slot whose holder is dead is broken, the call runs, and the slot is given back"
dead=2147483646   # above every pid_max: no process can hold it
mkdir -p "$ITMP/slots4/inception_mercury-3/slot.1"; printf '%s\n' "$dead" > "$ITMP/slots4/inception_mercury-3/slot.1/pid"
SLOTS="$ITMP/slots4" run_i c4 ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=1
assert_eq "1 0" "$(chats c4) $(cat "$ITMP/c4/rc")" "one request, the review completes"
assert_eq "0" "$(slots_left "$ITMP/slots4")" "no slot left behind"

# Bug caught: a throttled mercury retried without end (a storm against its host), parked as a free-model quota stop,
# or never counted, so the cooldown never benches a lane its host keeps refusing.
start_test "if.5 a 429 on openrouter-5: three requests in all, then one lane-side strike, and the slot given back"
run_i c5 IF_429=1
assert_eq "3" "$(chats c5)" "bounded retries (OR_ATTEMPTS)"
assert_eq "inception/mercury-3" "$(sort -u "$ITMP/c5/models")" "the default model of openrouter-5"
assert_eq "1" "$(strikes c5)" "counted against the lane"
assert_eq "no" "$([ -e "$ITMP/c5/openrouter-free-quota-until" ] && echo yes || echo no)" "no free-model stop written"
assert_eq "0" "$(slots_left)" "the slot given back after the failure"

# Bug caught: a stray file where a slot belongs read as a busy slot forever, so every call queued out its budget.
start_test "if.6 a file in a slot's place: the call runs uncapped instead of queuing out its budget"
mkdir -p "$ITMP/slots6/inception_mercury-3"; : > "$ITMP/slots6/inception_mercury-3/slot.1"
SLOTS="$ITMP/slots6" run_i c6 ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=1
assert_eq "1 0" "$(chats c6) $(cat "$ITMP/c6/rc")" "one request, the review completes"

# Bug caught: one unusable slot dropping the whole cap, so every call ran uncapped while other slots were in use.
start_test "if.7 one unusable slot is skipped: with the rest busy, the call still waits for its cap"
mkdir -p "$ITMP/slots7/inception_mercury-3/slot.2"; : > "$ITMP/slots7/inception_mercury-3/slot.1"
printf '%s\n' "$$" > "$ITMP/slots7/inception_mercury-3/slot.2/pid"
SLOTS="$ITMP/slots7" run_i c7 ZUVO_OR_MAX_INFLIGHT_INCEPTION_MERCURY_3=2 ZUVO_REVIEW_TIMEOUT=20
assert_eq "0" "$(chats c7)" "no request past the busy cap"
assert_contains "$(cat "$ITMP/c7/err")" "stayed busy" "not run, with the reason"
