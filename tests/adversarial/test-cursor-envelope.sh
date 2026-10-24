#!/usr/bin/env bash
# test-cursor-envelope.sh — cursor-agent --output-format json: its own envelope is unpacked, a reply that
# is itself JSON is not. Fake cursor-agent in a per-test dir (not mocks/, which other tests put on PATH).

ADV="$ROOT/scripts/adversarial-review.sh"
EMPTY="$ADV_TEST_EMPTY"

export ZUVO_ADVERSARIAL_TEST_HARNESS=1

BIN="$HERE/.tmp/curbin.$$"; mkdir -p "$BIN"
CURHOME="$HERE/.tmp/curhome.$$"; mkdir -p "$CURHOME"
cleanup_cur() { rm -rf "$BIN" "$CURHOME"; }
trap cleanup_cur EXIT

cat > "$BIN/cursor-agent" <<'MOCK'
#!/usr/bin/env bash
cat > /dev/null
case "$MOCK_CUR_MODE" in
  envelope)
    printf '{"type":"result","subtype":"success","is_error":false,"result":"SEVERITY: CRITICAL - mock cursor finding","session_id":"s","usage":{"inputTokens":100,"outputTokens":7,"cacheReadTokens":40,"cacheWriteTokens":0}}\n' ;;
  error)
    printf '{"type":"result","subtype":"error","is_error":true,"result":"Rate limit reached","session_id":"s"}\n' ;;
  bare)
    printf '{"type":"review","result":{"ok":false},"note":"SEVERITY: CRITICAL - mock bare cursor finding"}\n' ;;
esac
MOCK
chmod +x "$BIN/cursor-agent"

run_cur() {
  MOCK_CUR_MODE="$1" PATH="$BIN:$PATH" ZUVO_HOME="$CURHOME" ZUVO_PROVIDER_BENCH=0 ZUVO_REVIEW_TIMEOUT=20 \
  ZUVO_ADVERSARIAL_LOG_FILE="$CURHOME/adv.log" \
  bash "$ADV" --provider cursor-agent --mode code --files "$EMPTY" 2>"$CURHOME/err.txt"
}

# Bug caught: the envelope's JSON passed on as the review, and its tokens never logged.
start_test "cur.1 cursor's own envelope: .result is the review and its tokens reach the log"
out=$(run_cur envelope)
assert_contains "$out" "mock cursor finding" "the .result text is the review"
assert_eq "140|40|7|" "$(awk -F'\t' '!/^#/ && NF==25 {r=$19"|"$20"|"$21"|"$22} END{print r}' "$CURHOME/adv.log")" \
  "tokens_in counts cache reads, cached and output as reported, reasoning left empty (not reported)"

# Bug caught: a reply that is itself JSON with "type"/"result" keys taken for the envelope and emptied.
start_test "cur.2 a JSON reply without cursor's type=result+is_error signature is the review as it came"
out=$(run_cur bare)
assert_contains "$out" "mock bare cursor finding" "the reply's own JSON is kept as the review"

# Bug caught: cursor's error envelope (is_error true, a string .result) recorded as a clean zero-finding review.
start_test "cur.3 cursor's error envelope fails the lane instead of passing as a clean review"
out=$(run_cur error)
assert_eq "all-failed" "$(awk -F'\t' '!/^#/ && NF==25 {r=$15} END{print r}' "$CURHOME/adv.log")" \
  "the run is logged as failed, not as a clean review"
