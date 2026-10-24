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
# After an account switch (the rotate seam touches $MOCK_AGY_FLAG) the new account has quota.
[ -n "${MOCK_AGY_FLAG:-}" ] && [ -f "$MOCK_AGY_FLAG" ] && MOCK_AGY_MODE=ok
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
  json-ok)
    printf '{"status":"success","response":"SEVERITY: CRITICAL - mock json finding from %s","error":null,"usage":{"input_tokens":10,"output_tokens":5,"total_tokens":15}}\n' "$model" ;;
  json-error)
    printf '{"status":"error","response":null,"error":"MOCK-UNSEEN-ERROR something new broke"}\n' ;;
  json-bare)
    printf '{"status":"reviewed","error":"unchecked","note":"SEVERITY: CRITICAL - mock bare json finding"}\n' ;;
esac
MOCK
chmod +x "$BIN/agy"

run_adv() {  # run_adv <mode> [extra env assignments via caller's environment]
  MOCK_AGY_MODE="$1" MOCK_AGY_CALLS="$CALLS" \
  PATH="$BIN:$PATH" ZUVO_HOME="$AGYHOME" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT="${ADV_T:-20}" \
  ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" \
  ZUVO_AGY_FALLBACK_MODEL="${FB-Mock Fallback (Test)}" \
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

# ─── 2b. the retry goes to the SAME model; the fallback stays unspent ─────
# _agy_attempt classes a 503 as transient: run_agy retries it once on the model that failed. Read as a
# plain failure it would skip the retry and spend the fallback model — the fake answers any second call, so
# only the model each call asked for tells the two apart.
start_test "agy.2b a 503 is retried on the primary model, not handed to the fallback"
reset_calls
out=$(run_adv transient-then-ok)
assert_eq "Gemini 3.8 Flash (High)|Gemini 3.8 Flash (High)" "$(tr '\n' '|' < "$CALLS" | sed 's/|$//')" \
  "both calls asked for the primary model"
if [[ "$out" == *"[agy] fallback model:"* ]]; then fail "the review is not announced as a fallback's" "$out"
else pass "the review is not announced as a fallback's"; fi

# ─── 2c. --output-format json: the reply is .response; an error object is no review ───
# Bug caught: an error object agy exits 0 with (an error text the classifier does not know yet) read as the
# review body — a non-empty "review" with zero findings, i.e. a false-clean pass.
start_test "agy.2c the JSON reply's .response is the review, and an error object fails the lane"
reset_calls
out=$(run_adv json-ok)
assert_contains "$out" "mock json finding" "the .response text is the review"
if [[ "$out" == *'"status":"success"'* ]]; then fail "the JSON envelope is not passed on as the review" "$out"
else pass "the JSON envelope is not passed on as the review"; fi
reset_calls
out=$(FB='' run_adv json-error)
if [[ "$out" == *"MOCK-UNSEEN-ERROR"* ]]; then fail "an error object is not consumed as a review" "$out"
else pass "an error object is not consumed as a review"; fi

# Bug caught: a reply that is itself JSON with a "status"/"error" key taken for agy's envelope and emptied.
start_test "agy.2d a JSON reply that is not agy's three-key envelope is the review as it came"
reset_calls
out=$(run_adv json-bare)
assert_contains "$out" "mock bare json finding" "the reply's own JSON is kept as the review"

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
assert_contains "$(cat "$CALLS")" "Mock Fallback (Test)" "the fallback model was the one called"

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

# Bug caught: a stated reset days away held agy out of every review until then (backlog
# B-20261020-CURSOR-AGY-DEAD-STATE-COOLDOWN) — the stop is capped at the lane cooldown's maximum.
start_test "agy.5a a quota stop never outlasts ZUVO_ADV_COOLDOWN_MAX; ZUVO_ADV_NO_COOLDOWN=1 keeps the stated reset"
# stop_left — seconds left on the one stop this run wrote ("none" when it wrote none: no stale file can answer).
stop_left() {
  local f; f=$(ls "$AGYHOME"/agy-cooldown-* 2>/dev/null | head -1)
  [[ -n "$f" ]] || { echo none; return; }
  echo $(( $(tr -cd '0-9' < "$f" | cut -c1-10) - $(date +%s) ))
}
reset_calls; rm -f "$AGYHOME"/agy-cooldown-*
ZUVO_ADV_COOLDOWN_BASE=10 ZUVO_ADV_COOLDOWN_MAX=30 run_adv quota-primary >/dev/null
left=$(stop_left)
assert_eq "capped" "$( [[ "$left" != none && "$left" -gt 0 && "$left" -le 30 ]] && echo capped || echo "$left" )" "a 120 s reset under a 30 s cap"
reset_calls; rm -f "$AGYHOME"/agy-cooldown-*
ZUVO_ADV_NO_COOLDOWN=1 ZUVO_ADV_COOLDOWN_BASE=10 ZUVO_ADV_COOLDOWN_MAX=30 run_adv quota-primary >/dev/null
left=$(stop_left)
assert_eq "stated" "$( [[ "$left" != none && "$left" -gt 60 ]] && echo stated || echo "$left" )" "the old rule keeps the 120 s reset"

# ─── 5b. the LOG must name the model that actually answered ───────────────
# Caught on the first live run after the fallback shipped: the row said
#   Gemini 3.8 Flash (High) | agy | ok | 12s
# while Gemini was out of quota for 17 hours and Opus 4.6 had written the review. The log row,
# the health ledger and every future bench of this lane are keyed on the MODEL, so a fallback
# that reports the primary corrupts all three — and it looks like the lane recovered.
start_test "agy.5b the run log records the model that actually answered, not the primary"
reset_calls
LOGF="$AGYHOME/adv.log"; : > "$LOGF"
MOCK_AGY_MODE=quota-primary MOCK_AGY_CALLS="$CALLS" \
PATH="$BIN:$PATH" ZUVO_HOME="$AGYHOME" ZUVO_ADVERSARIAL_LOG_FILE="$LOGF" \
ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 \
ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" \
ZUVO_AGY_FALLBACK_MODEL="Mock Fallback (Test)" \
  bash "$ADV" --provider agy --mode code --files "$EMPTY" >/dev/null 2>&1
logged=$(awk -F'\t' '$14=="agy"{print $4; exit}' "$LOGF" 2>/dev/null)
assert_eq "Mock Fallback (Test)" "${logged:-<no agy row>}" "logged model is the fallback"

# ─── 5c. …and the reader of the review can see it happened ────────────────
start_test "agy.5c a fallback is announced in the review body, not only in captured stderr"
reset_calls
out=$(run_adv quota-primary)
assert_contains "$out" "[agy] fallback model: Mock Fallback (Test)" "the body names the model that wrote it"

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
  *Fallback*) assert_eq "no fallback call" "fallback called" "empty fallback must not invoke a second model" ;;
  *)      assert_eq "ok" "ok" "only the primary was attempted" ;;
esac

# ─── 8. the registry's own variable, set EMPTY, is an opt-out too ─────────
# model-registry.sh keeps an explicitly empty ZUVO_MODEL_AGY_FALLBACK empty (`-`, not `:-`), so with
# ZUVO_AGY_FALLBACK_MODEL unset the fallback stays off instead of being reset to a default. HOME is an empty
# directory: the driver sources an installed ~/.zuvo/model-registry.sh FIRST, and only without one does
# this repository's registry decide.
start_test "agy.8 ZUVO_MODEL_AGY_FALLBACK='' (ZUVO_AGY_FALLBACK_MODEL unset) disables the fallback"
reset_calls
mkdir -p "$AGYHOME/home"
env -u ZUVO_AGY_FALLBACK_MODEL MOCK_AGY_MODE=quota-primary MOCK_AGY_CALLS="$CALLS" \
  PATH="$BIN:$PATH" HOME="$AGYHOME/home" ZUVO_HOME="$AGYHOME" ZUVO_MODEL_AGY_FALLBACK="" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" \
  bash "$ADV" --provider agy --mode code --files "$EMPTY" >/dev/null 2>&1
assert_eq "Gemini 3.8 Flash (High)" "$(sort -u "$CALLS" | tr '\n' '|' | sed 's/|$//')" \
  "only the primary was called; no fallback model"

# ─── 9. NO fallback by default ─────────────────────────────────────────────
# Both variables unset. The old default, Opus 4.6, was retired by Antigravity and answered 0 of
# thousands of calls while it stayed the default — run_adv's own `${FB-…}` masked that here.
start_test "agy.9 with neither fallback variable set, only the primary is called"
reset_calls
env -u ZUVO_AGY_FALLBACK_MODEL -u ZUVO_MODEL_AGY_FALLBACK MOCK_AGY_MODE=quota-primary MOCK_AGY_CALLS="$CALLS" \
  PATH="$BIN:$PATH" HOME="$AGYHOME/home" ZUVO_HOME="$AGYHOME" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" \
  bash "$ADV" --provider agy --mode code --files "$EMPTY" >/dev/null 2>&1
assert_eq "Gemini 3.8 Flash (High)" "$(sort -u "$CALLS" | tr '\n' '|' | sed 's/|$//')" \
  "only the primary was called; no default fallback"

# ─── 10. the log's effort column follows the model that answered ──────────
# agy has no effort switch: the level is part of the model's display name. The row names the model that
# answered (agy.5b), and its effort must be read from that same name — never from the primary's.
start_test "agy.10 the effort column is the level in the name of the model that answered"
agy_effort_row() { # agy_effort_row <log> -> "<model>|<effort>" of the agy row, columns found by name
  awk -F'\t' 'NR == 1 { for (i = 1; i <= NF; i++) { if ($i == "effort") e = i; if ($i == "provider") p = i; if ($i == "model") m = i }; next }
              e && $p == "agy" { r = $m "|" $e } END { print r }' "$1" 2>/dev/null
}
reset_calls
LOGF="$AGYHOME/adv10.log"; : > "$LOGF"
MOCK_AGY_MODE=ok MOCK_AGY_CALLS="$CALLS" PATH="$BIN:$PATH" ZUVO_HOME="$AGYHOME" ZUVO_ADVERSARIAL_LOG_FILE="$LOGF" \
ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" ZUVO_AGY_FALLBACK_MODEL="" \
  bash "$ADV" --provider agy --mode code --files "$EMPTY" >/dev/null 2>&1
assert_eq "Gemini 3.8 Flash (High)|high" "$(agy_effort_row "$LOGF")" "the primary answered: (High) → high"
reset_calls
LOGF="$AGYHOME/adv10b.log"; : > "$LOGF"
MOCK_AGY_MODE=quota-primary MOCK_AGY_CALLS="$CALLS" PATH="$BIN:$PATH" ZUVO_HOME="$AGYHOME" ZUVO_ADVERSARIAL_LOG_FILE="$LOGF" \
ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" ZUVO_AGY_FALLBACK_MODEL="Claude Sonnet 5.5 (Low)" \
  bash "$ADV" --provider agy --mode code --files "$EMPTY" >/dev/null 2>&1
assert_eq "Claude Sonnet 5.5 (Low)|low" "$(agy_effort_row "$LOGF")" "the fallback answered: its (Low), not the primary's (High)"

start_test "agy.11 every model failing: the row names the primary, at the primary's level; none tried: no effort"
# quota-all: both models are tried and refuse. The row then names the configured primary (the bench key), so the
# effort is the primary's, not the fallback's that was tried last. The second run finds both on cooldown and tries
# nothing: same model column, empty effort. mock-success answers alongside: a run in which NO lane answers logs one
# `none` row and no lane rows at all, so without it there would be no agy row to read.
reset_calls
LOGF="$AGYHOME/adv11.log"; : > "$LOGF"
agy11() {
  MOCK_AGY_MODE=quota-all MOCK_AGY_CALLS="$CALLS" PATH="$BIN:$HERE/mocks:$PATH" ZUVO_HOME="$AGYHOME" ZUVO_ADVERSARIAL_LOG_FILE="$LOGF" \
  ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 ZUVO_AGY_MODEL="Gemini 3.8 Flash (High)" ZUVO_AGY_FALLBACK_MODEL="Claude Sonnet 5.5 (Low)" \
  ZUVO_REVIEW_TEST_PROVIDERS="agy mock-success" bash "$ADV" --mode code --files "$EMPTY" >/dev/null 2>&1
}
agy11
assert_eq "Gemini 3.8 Flash (High)|Claude Sonnet 5.5 (Low)" "$(tr '\n' '|' < "$CALLS" | sed 's/|$//')" "premise: both models were tried"
assert_eq "Gemini 3.8 Flash (High)|high" "$(agy_effort_row "$LOGF")" "row: the primary, at its level high (not the fallback's low)"
: > "$CALLS"; : > "$LOGF"
agy11
assert_eq "0" "$(grep -c . "$CALLS")" "premise: the second run tried no model (both on cooldown)"
assert_eq "Gemini 3.8 Flash (High)|" "$(agy_effort_row "$LOGF")" "row: the primary, effort empty — nothing ran"

# agy_token <file> <email> — an agy login whose id_token names <email> (header.payload.signature, base64url).
agy_token() {
  local p; p=$(printf '{"email":"%s"}' "$2" | base64 | tr -d '=\n' | tr '/+' '_-')
  printf '{"auth_method":"oauth","token":{},"id_token":"h.%s.s"}' "$p" > "$1"
}

# Bug caught (2026-10-17): the owner moved agy to a fresh account and the old account's stops (until 10-20) kept
# Gemini out of every review until someone moved them away by hand.
start_test "agy.12 a quota stop left by another account does not stop the live one"
reset_calls
agy_token "$AGYHOME/tok-new" "new@example.com"
for slug in $(printf '%s' "Gemini 3.8 Flash (High)" | tr 'A-Z ()' 'a-z---' | tr -cd 'a-z0-9.-'); do
  printf '%s old@example.com\n' "$(( $(date +%s) + 86400 ))" > "$AGYHOME/agy-cooldown-$slug"
done
out=$(ZUVO_AGY_TOKEN_FILE="$AGYHOME/tok-new" run_adv ok)
assert_eq "Gemini 3.8 Flash (High)" "$(head -1 "$CALLS")" "the primary is called on the new account"
printf '%s new@example.com\n' "$(( $(date +%s) + 86400 ))" > "$AGYHOME/agy-cooldown-$slug"
: > "$CALLS"
out=$(ZUVO_AGY_TOKEN_FILE="$AGYHOME/tok-new" ZUVO_AGY_ROTATE=0 run_adv ok)
assert_eq "Mock Fallback (Test)" "$(head -1 "$CALLS")" "control: the live account's own stop still holds"

# Bug caught: one spent account taking Gemini out of every review while the owner's other accounts sit unused.
start_test "agy.13 a spent primary switches to another stored account and asks the primary again"
reset_calls
agy_token "$AGYHOME/tok-live" "spent@example.com"; rm -f "$AGYHOME/flag13"
agy_token "$AGYHOME/tok-fresh" "fresh@example.com"
printf '#!/usr/bin/env bash\ntouch "%s"; cp "%s" "%s"\n' "$AGYHOME/flag13" "$AGYHOME/tok-fresh" "$AGYHOME/tok-live" > "$AGYHOME/rotate13"
chmod +x "$AGYHOME/rotate13"
out=$(ZUVO_AGY_TOKEN_FILE="$AGYHOME/tok-live" MOCK_AGY_FLAG="$AGYHOME/flag13" ZUVO_AGY_ROTATE_CMD="$AGYHOME/rotate13" \
  run_adv quota-primary)
assert_eq "Gemini 3.8 Flash (High)|Gemini 3.8 Flash (High)" "$(tr '\n' '|' < "$CALLS" | sed 's/|$//')" "the primary twice: spent, then on the new account — never the fallback"
assert_contains "$out" "mock finding from Gemini 3.8 Flash (High)" "the review is the primary's"
