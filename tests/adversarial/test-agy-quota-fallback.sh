#!/usr/bin/env bash
# test-agy-quota-fallback.sh — the agy lane's three failure shapes, measured 2026-09-21/22:
#
#   quota, spoken   "Individual quota reached ... Resets in 3h12m58s"  -> honour that reset
#   quota, SILENT   an exhausted Gemini says NOTHING: agy hangs ~150-175s, exits with
#                   "error: interrupted" and an empty body. Five real reviews on 2026-09-21
#                   each burned ~160s for nothing, on a PINNED lane, all day.
#   transient       503 "No capacity available" / "Eligibility check failed: failed to get
#                   profile picture" (agy fetches the account avatar on EVERY call and fails
#                   the review when that dial times out). One retry recovered 3 of 8 and 3 of 4
#                   over the model bench.
#
# The case that must never go red is D1: a TIMEOUT is still not retried. The retry added here
# is for errors that come back in 1-15s, so it cannot reopen a second timeout window — and a
# test that only proved "retry works" would happily pass while doing exactly that.
#
# The fake `agy` lives in a per-test directory, NOT in mocks/: a file named `agy` there would
# shadow the real CLI for every other test that puts mocks/ on PATH, and detect_providers()
# would then find an "agy" that is a shell script.

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

BIN="$HERE/.tmp/agybin.$$"; mkdir -p "$BIN"
AGYHOME="$HERE/.tmp/agyhome.$$"; mkdir -p "$AGYHOME"
CALLS="$AGYHOME/calls.txt"
cleanup_agy() { rm -rf "$BIN" "$AGYHOME"; }
trap cleanup_agy EXIT

cat > "$BIN/agy" <<'MOCK'
#!/usr/bin/env bash
# Fake agy. Reads --model, logs every call, behaves per MOCK_AGY_MODE.
model=""
while [ $# -gt 0 ]; do
  case "$1" in
    --model) model="$2"; shift 2 ;;
    *) shift ;;
  esac
done
printf '%s\n' "$model" >> "$MOCK_AGY_CALLS"
n=$(grep -c . "$MOCK_AGY_CALLS")
case "${MOCK_AGY_MODE:-ok}" in
  ok)
    echo "SEVERITY: CRITICAL - mock finding from $model" ;;
  transient-then-ok)
    if [ "$n" -le 1 ]; then
      echo "error: Our servers are experiencing high traffic right now, please try again in a minute. (UNAVAILABLE (code 503): No capacity available for model x on the server)" >&2
      exit 3
    fi
    echo "SEVERITY: CRITICAL - mock finding after retry from $model" ;;
  avatar-then-ok)
    if [ "$n" -le 1 ]; then
      echo 'error: Eligibility check failed: failed to get profile picture: Get "https://lh3.googleusercontent.com/a/x=s96-c": dial tcp 142.250.130.132:443: i/o timeout' >&2
      exit 3
    fi
    echo "SEVERITY: CRITICAL - mock finding after retry from $model" ;;
  quota-primary)
    case "$model" in
      *Gemini*)
        echo "error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 0h2m0s." >&2
        exit 3 ;;
      *) echo "SEVERITY: CRITICAL - mock finding from fallback $model" ;;
    esac ;;
  silent-primary)
    case "$model" in
      *Gemini*) echo "error: interrupted" >&2; exit 1 ;;
      *) echo "SEVERITY: CRITICAL - mock finding from fallback $model" ;;
    esac ;;
  quota-all)
    echo "error: Individual quota reached. Please upgrade your subscription to increase your limits. Resets in 0h2m0s." >&2
    exit 3 ;;
  hang)
    sleep 30 ;;
esac
MOCK
chmod +x "$BIN/agy"

run_adv() {  # run_adv <mode> [extra env assignments via caller's environment]
  MOCK_AGY_MODE="$1" MOCK_AGY_CALLS="$CALLS" \
  PATH="$BIN:$PATH" ZUVO_HOME="$AGYHOME" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT="${ADV_T:-20}" \
  ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" \
  ZUVO_AGY_FALLBACK_MODEL="${FB-Claude Opus 4.6 (Thinking)}" \
  bash "$ADV" --provider agy --mode code --files "$EMPTY" 2>"$AGYHOME/err.txt"
}

reset_calls() { : > "$CALLS"; rm -f "$AGYHOME"/agy-cooldown-* 2>/dev/null; }

# ─── 1. transient 503 → ONE retry → success ───────────────────────────────
start_test "agy.1 a 503 is retried once and the second attempt's review is returned"
reset_calls
out=$(run_adv transient-then-ok)
calls=$(grep -c . "$CALLS")
assert_contains "$out" "after retry" "the retried attempt's body is what comes back"
assert_eq "2" "$calls" "exactly two calls: the 503 and its single retry"

# ─── 2. the avatar eligibility failure is the same class ──────────────────
start_test "agy.2 'Eligibility check failed: profile picture' is retried too"
reset_calls
out=$(run_adv avatar-then-ok)
assert_contains "$out" "after retry" "avatar-check failure recovered by the retry"
assert_eq "2" "$(grep -c . "$CALLS")" "one retry, not a loop"

# ─── 3. D1 HOLDS: a timeout is NOT retried ────────────────────────────────
# This is the regression guard for the whole change. If a future edit retries on timeout, the
# lane silently starts spending 2x PROVIDER_TIMEOUT, which is the contract D1 removed.
start_test "agy.3 a timeout is NOT retried (D1: first timeout is final)"
reset_calls
start=$(date +%s)
ADV_T=2 run_adv hang >/dev/null 2>&1
elapsed=$(( $(date +%s) - start ))
assert_eq "1" "$(grep -c . "$CALLS")" "the hung model is called once, never twice"
assert_le "9" "$elapsed" "no second timeout window opened"

# ─── 4. spoken quota on the primary → fallback model answers ──────────────
start_test "agy.4 a quota'd primary falls back to the fallback model"
reset_calls
out=$(run_adv quota-primary)
assert_contains "$out" "fallback" "the fallback model's review is returned"
assert_contains "$(cat "$CALLS")" "Claude Opus 4.6 (Thinking)" "the fallback model was the one called"

# ─── 5. …and the stated reset time becomes the cooldown ───────────────────
start_test "agy.5 'Resets in 0h2m0s' is honoured as the cooldown, and the primary is then skipped"
cool=$(ls "$AGYHOME"/agy-cooldown-* 2>/dev/null | head -1)
if [[ -n "$cool" ]]; then
  until=$(tr -cd '0-9' < "$cool"); now=$(date +%s); delta=$(( until - now ))
  # 120s stated; allow the seconds the run itself took.
  if [[ "$delta" -gt 60 && "$delta" -le 121 ]]; then
    assert_eq "ok" "ok" "cooldown deadline came from the error text (${delta}s left of 120s)"
  else
    assert_eq "60<delta<=121" "$delta" "cooldown deadline derived from 'Resets in 0h2m0s'"
  fi
else
  assert_eq "a cooldown file" "none" "quota must write a cooldown file"
fi

# The second run must NOT call the primary at all — that is the whole point: before this, every
# chunk of every run paid ~160s to rediscover the same exhaustion.
: > "$CALLS"
out=$(run_adv quota-primary)
assert_contains "$out" "fallback" "second run still produces a review"
if grep -q "Gemini" "$CALLS"; then
  assert_eq "no Gemini call" "Gemini called" "a cooling-down model must not be invoked"
else
  assert_eq "ok" "ok" "the cooling-down primary was skipped without spending a call"
fi

# ─── 6. SILENT exhaustion (empty body + 'interrupted') is treated as quota ─
start_test "agy.6 silent exhaustion (empty + 'interrupted') falls back and cools down"
reset_calls
out=$(run_adv silent-primary)
assert_contains "$out" "fallback" "silent exhaustion still yields a review via the fallback"
ls "$AGYHOME"/agy-cooldown-* >/dev/null 2>&1 \
  && assert_eq "ok" "ok" "a cooldown was recorded for the silently-exhausted model" \
  || assert_eq "cooldown file" "none" "silent exhaustion must cool the model down"

# ─── 7. the fallback is opt-out-able, and no fallback means no extra call ──
start_test "agy.7 ZUVO_AGY_FALLBACK_MODEL='' disables the fallback entirely"
reset_calls
FB="" run_adv quota-primary >/dev/null 2>&1
models=$(sort -u "$CALLS" | tr '\n' ' ')
case "$models" in
  *Opus*) assert_eq "no fallback call" "fallback called" "empty fallback must not invoke a second model" ;;
  *)      assert_eq "ok" "ok" "only the primary was attempted" ;;
esac
