#!/usr/bin/env bash
# test-byteplus-stream.sh — the byteplus lanes STREAM, and the streamed body is read correctly.
#
# Why streaming at all: the ModelArk Coding Plan closes a non-streaming chat/completions request
# after ~60 s without a byte (curl 16 over HTTP/2, 52 over HTTP/1.1). A reasoning model thinks for
# minutes on a real diff, so every such review died at ~62 s and the production `byteplus` lane
# answered 11 of 43 calls (2026-10-04/05). With "stream": true the same request completed.
# The fake curl returns fixture bytes and records the payload; no network, no plan quota.

ADV="$ROOT/scripts/adversarial-review.sh"
BS_HOME="$(mktemp -d "$ADV_TEST_HOME/byteplus-stream.XXXXXX")"
mkdir -p "$BS_HOME/bin"
export ZUVO_HOME="$BS_HOME" ZUVO_ADVERSARIAL_TEST_HARNESS=1
export PATH="$BS_HOME/bin:$PATH"
trap 'rm -rf "$BS_HOME"' EXIT
( umask 077; printf 'fixture-byteplus-key' > "$BS_HOME/byteplus.key" )
export ZUVO_BYTEPLUS_KEY_FILE="$BS_HOME/byteplus.key"
unset ZUVO_BYTEPLUS_BASE_URL OPENROUTER_API_KEY

cat > "$BS_HOME/bin/curl" <<'EOF'
#!/usr/bin/env bash
# records every payload, can fail the FIRST call with a given curl exit code
n=$(( $(cat "$BS_CALLS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BS_CALLS"
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then cp "${a#@}" "$BS_PAYLOADS/payload-$n.json"; fi
  prev="$a"
done
if [ -n "${BS_FAIL_ALL:-}" ]; then
  echo "curl: ($BS_FAIL_ALL) Error in the HTTP2 framing layer" >&2
  exit "$BS_FAIL_ALL"
fi
if [ "$n" = 1 ] && [ -n "${BS_FAIL_FIRST:-}" ]; then
  echo "curl: ($BS_FAIL_FIRST) Error in the HTTP2 framing layer" >&2
  exit "$BS_FAIL_FIRST"
fi
cat "$BS_FIXTURE"
printf '\n%s' "${BS_HTTP:-200}"
EOF
chmod +x "$BS_HOME/bin/curl"

bs_case() {  # bs_case <provider> <fixture> -> driver JSON on stdout
  rm -rf "$BS_HOME/payloads"; mkdir -p "$BS_HOME/payloads"; : > "$BS_HOME/calls"
  BS_FIXTURE="$2" BS_CALLS="$BS_HOME/calls" BS_PAYLOADS="$BS_HOME/payloads" \
    bash "$ADV" --provider "$1" --single --json --files "$ADV_TEST_EMPTY" 2>"$BS_HOME/driver.err"
}

sse() {  # sse <file> <json-event>... — writes an SSE body ending in [DONE]
  local f="$1"; shift
  : > "$f"
  for ev in "$@"; do printf 'data: %s\n\n' "$ev" >> "$f"; done
  printf 'data: [DONE]\n\n' >> "$f"
}

REVIEW_A="SEVERITY: WARNING CONFIDENCE: high FILE: a.ts:1 ISSUE: $(printf 'streamed review text %.0s' {1..40})"
start_test "BS.1 a streamed review is assembled from delta.content; reasoning is dropped; stream is requested"
sse "$BS_HOME/ok.sse" \
  '{"choices":[{"delta":{"reasoning_content":"SCRATCHPAD_MUST_NOT_LEAK"}}]}' \
  "$(jq -cn --arg t "${REVIEW_A:0:200}" '{choices:[{delta:{content:$t}}]}')" \
  "$(jq -cn --arg t "${REVIEW_A:200}" '{choices:[{delta:{content:$t}}]}')" \
  '{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":22,"completion_tokens_details":{"reasoning_tokens":7}}}'
out=$(bs_case byteplus "$BS_HOME/ok.sse"); rc=$?
assert_exit_code "0" "$rc" "streamed review accepted"
assert_eq "$REVIEW_A" "$(printf '%s' "$out" | jq -r '.results.byteplus')" "content = all delta.content joined, exactly"
if [[ "$(printf '%s' "$out" | jq -r '.results.byteplus')" == *SCRATCHPAD_MUST_NOT_LEAK* ]]; then
  fail "reasoning_content leaked into the review"
else
  pass "reasoning_content is not the review"
fi
assert_eq "true" "$(jq -r '.stream' "$BS_HOME/payloads/payload-1.json")" "byteplus asks for a stream"
assert_eq "true" "$(jq -r '.stream_options.include_usage' "$BS_HOME/payloads/payload-1.json")" "and for usage in the stream"
# the assembler itself, extracted from the driver: usage comes from the LAST chunk that carries it
awk '/^openrouter_assemble_stream\(\) \{/{p=1} p{print} p&&/^\}$/{exit}' "$ADV" > "$BS_HOME/assemble.sh"
assembled=$(bash -c '. "$1"; openrouter_assemble_stream "$(cat "$2")"' _ "$BS_HOME/assemble.sh" "$BS_HOME/ok.sse")
assert_eq '{"prompt_tokens":11,"completion_tokens":22,"completion_tokens_details":{"reasoning_tokens":7}}' \
  "$(printf '%s' "$assembled" | jq -c '.usage')" "usage folded from the final chunk"
assert_eq "$REVIEW_A" "$(printf '%s' "$assembled" | jq -r '.choices[0].message.content')" "assembled content, exactly"
assert_eq '{"x":1}' "$(bash -c '. "$1"; openrouter_assemble_stream "{\"x\":1}"' _ "$BS_HOME/assemble.sh")" "a non-SSE body passes through unchanged"

start_test "BS.2 an error event inside the stream fails the lane loudly"
sse "$BS_HOME/err.sse" '{"error":{"message":"Coding Plan quota exhausted","code":"QuotaExceeded"}}'
out=$(bs_case byteplus "$BS_HOME/err.sse"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "byteplus:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the lane produced nothing"
assert_contains "$(cat "$ZUVO_HOME"/adversarial-failures/*/provider_byteplus.stderr 2>/dev/null; cat "$BS_HOME/driver.err")" "Coding Plan quota exhausted" "the provider's message is kept"

start_test "BS.3 a stream with reasoning but no content is an empty review, not a clean one"
sse "$BS_HOME/empty.sse" '{"choices":[{"delta":{"reasoning_content":"thinking only"}}]}' '{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9}}'
out=$(bs_case byteplus "$BS_HOME/empty.sse"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "byteplus:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "empty content is excluded"

start_test "BS.4 curl exit 16 (HTTP/2 stream reset) is retried, and its reason is visible"
out=$(BS_FAIL_FIRST=16 bs_case byteplus "$BS_HOME/ok.sse"); rc=$?
assert_exit_code "0" "$rc" "second attempt succeeds"
assert_eq "2" "$(cat "$BS_HOME/calls")" "exactly one retry"
rm -rf "$ZUVO_HOME/adversarial-failures"
out=$(BS_FAIL_ALL=16 bs_case byteplus "$BS_HOME/ok.sse"); rc=$?
assert_exit_code "2" "$rc" "every attempt reset → no review"
assert_eq "3" "$(cat "$BS_HOME/calls")" "two retries, then give up"
ev=$(cat "$ZUVO_HOME"/adversarial-failures/*/provider_byteplus.stderr 2>/dev/null)
assert_contains "$ev" "transient (HTTP" "the retry note is kept"
assert_contains "$ev" "curl: (16) Error in the HTTP2 framing layer" "the failure line carries curl's own reason (it used to be empty)"

start_test "BS.5 the other byteplus lanes stream too; OpenRouter does not"
out=$(bs_case byteplus-3 "$BS_HOME/ok.sse"); rc=$?
assert_exit_code "0" "$rc" "byteplus-3 streamed review accepted"
assert_eq "true" "$(jq -r '.stream' "$BS_HOME/payloads/payload-1.json")" "byteplus-3 asks for a stream"
jq -n --arg t "$REVIEW_A" '{choices:[{message:{content:$t}}]}' > "$BS_HOME/or.json"
out=$(OPENROUTER_API_KEY=fixture-or-key bs_case openrouter "$BS_HOME/or.json"); rc=$?
assert_exit_code "0" "$rc" "openrouter non-streaming review accepted"
assert_eq "null" "$(jq -r '.stream' "$BS_HOME/payloads/payload-1.json")" "openrouter payload carries no stream flag"

start_test "BS.6 a non-SSE error body on a streamed lane still fails on its HTTP status"
printf '{"error":{"message":"invalid model id"}}' > "$BS_HOME/400.json"
out=$(BS_HTTP=400 bs_case byteplus "$BS_HOME/400.json"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(cat "$ZUVO_HOME"/adversarial-failures/*/provider_byteplus.stderr 2>/dev/null; cat "$BS_HOME/driver.err")" "invalid model id" "the error body is reported"

start_test "BS.7 the billing guard still refuses a metered base URL before any request"
out=$(ZUVO_BYTEPLUS_BASE_URL="https://ark.ap-southeast.bytepluses.com/api/v3" bs_case byteplus "$BS_HOME/ok.sse"); rc=$?
assert_exit_code "2" "$rc" "refused"
assert_eq "" "$(cat "$BS_HOME/calls")" "no request was sent"

start_test "BS.8 a stream event that does not parse is reported, not silently dropped"
printf 'data: %s\n\ndata: {"choices":[{"delta":{"content":"tail"}}\n\ndata: [DONE]\n\n' \
  "$(jq -cn --arg t "$REVIEW_A" '{choices:[{delta:{content:$t}}]}')" > "$BS_HOME/torn.sse"
warn=$(bash -c '. "$1"; openrouter_assemble_stream "$(cat "$2")" >/dev/null' _ "$BS_HOME/assemble.sh" "$BS_HOME/torn.sse" 2>&1)
assert_contains "$warn" "1 of 2 stream event(s) did not parse" "a torn chunk is counted and named"

start_test "BS.9 delta.content as typed text parts is joined like message.content"
sse "$BS_HOME/parts.sse" '{"choices":[{"delta":{"content":[{"type":"text","text":"PART_A_"},{"type":"image","url":"x"},{"type":"text","text":"PART_B"}]}}]}'
assembled=$(bash -c '. "$1"; openrouter_assemble_stream "$(cat "$2")"' _ "$BS_HOME/assemble.sh" "$BS_HOME/parts.sse")
assert_eq "PART_A_PART_B" "$(printf '%s' "$assembled" | jq -r '.choices[0].message.content')" "text parts joined, image part dropped"

start_test "BS.10 a stream error with only a code still fails loudly with that code"
sse "$BS_HOME/code.sse" '{"error":{"code":"InvalidSubscription"}}'
rm -rf "$ZUVO_HOME/adversarial-failures"
out=$(bs_case byteplus "$BS_HOME/code.sse"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(cat "$ZUVO_HOME"/adversarial-failures/*/provider_byteplus.stderr 2>/dev/null)" "returned error: InvalidSubscription" "the code is the reported reason"

start_test "BS.11 a multi-MB stream (a real reasoning model) is assembled under the driver's pipefail"
# The live run that found this: 401 s of glm-5.3-flash reasoning, a several-MB SSE body, and
# `printf | grep -q` under pipefail returned 141 → the body was read as "not SSE" and lost.
python3 - "$BS_HOME/big.sse" "$REVIEW_A" <<'PY'
import json, sys
out, review = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    for i in range(40000):
        f.write("data: " + json.dumps({"choices": [{"delta": {"content": "", "reasoning_content": "thinking step %d " % i}}]}) + "\n\n")
    f.write("data: " + json.dumps({"choices": [{"delta": {"content": review}}]}) + "\n\n")
    f.write("data: " + json.dumps({"choices": [], "usage": {"prompt_tokens": 6932, "completion_tokens": 23645}}) + "\n\n")
    f.write("data: [DONE]\n\n")
PY
[ "$(wc -c < "$BS_HOME/big.sse")" -gt 2000000 ] && pass "fixture is multi-MB" || fail "fixture too small to reproduce SIGPIPE"
out=$(bs_case byteplus "$BS_HOME/big.sse"); rc=$?
assert_exit_code "0" "$rc" "a large streamed review is accepted"
assert_eq "$REVIEW_A" "$(printf '%s' "$out" | jq -r '.results.byteplus')" "the review comes out of a multi-MB stream intact"
