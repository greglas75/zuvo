#!/usr/bin/env bash
# test-byteplus-stream.sh — the byteplus lanes STREAM, and the streamed body is read correctly.
#
# Why streaming at all: the ModelArk Coding Plan closes a non-streaming chat/completions request
# after ~60 s without a byte (curl 16 over HTTP/2, 52 over HTTP/1.1). A reasoning model thinks for
# minutes on a real diff, so every such review died at ~62 s and the production `byteplus` lane
# answered 11 of 43 calls (2026-10-04/05). With "stream": true the same request completed.
#
# Test level: MEDIUM. Every case runs the real driver as a subprocess (`--provider <lane> --single
# --json`) against a fake curl on PATH that serves fixture bytes and records each request; temp
# files only, no network, no plan quota. The driver's own retry backoff sleeps (3 s, 6 s) in the
# retry cases. Fixtures follow the OpenAI chat.completion.chunk shape BytePlus sends.
#
# Isolation: each case calls new_case, which gives it its own directory, key file, ZUVO_HOME,
# request log and fixtures. No case reads a file another case wrote; any one can run alone.

ADV="$ROOT/scripts/adversarial-review.sh"
BS_ROOT="$(mktemp -d "$ADV_TEST_HOME/byteplus-stream.XXXXXX")"
trap 'rm -rf "$BS_ROOT"' EXIT
REAL_JQ="$(command -v jq)"
unset ZUVO_BYTEPLUS_BASE_URL OPENROUTER_API_KEY ZUVO_OR_STREAM ZUVO_MODEL_BYTEPLUS ZUVO_REVIEW_TIMEOUT

mkdir -p "$BS_ROOT/bin" "$BS_ROOT/badjq"
cat > "$BS_ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
# Records argv and payload per call. Per-call curl exit codes (BS_EXIT_SEQ) and HTTP statuses
# (BS_HTTP_SEQ), comma-separated; an empty field means success / BS_HTTP (default 200).
n=$(( $(cat "$BS_CALLS" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$BS_CALLS"
printf '%s\n' "$@" > "$BS_PAYLOADS/args-$n"
prev=""
for a in "$@"; do
  if [ "$prev" = "-d" ]; then cp "${a#@}" "$BS_PAYLOADS/payload-$n.json"; fi
  prev="$a"
done
# trailing comma: cut prints a comma-less line whole for ANY field, which made "92" fail every call
xc=$(printf '%s,' "${BS_EXIT_SEQ:-}" | cut -d, -f"$n")
if [ -n "$xc" ] && [ "$xc" != 0 ]; then
  echo "curl: ($xc) simulated transport failure" >&2
  exit "$xc"
fi
hc=$(printf '%s,' "${BS_HTTP_SEQ:-}" | cut -d, -f"$n")
fx_var="BS_FIXTURE_$n"   # a per-call body (BS_FIXTURE_2=…) wins over the shared one
cat "${!fx_var:-$BS_FIXTURE}"
printf '\n%s' "${hc:-${BS_HTTP:-200}}"
EOF
# sleep: the retry backoff (a whole number of seconds <= 10) returns at once and is recorded in
# $BS_SLEEPS, so retry cases neither wait on the real clock nor lose the backoff they asked for.
# Every other sleep — the driver's watchdogs sleep for the whole provider budget — runs for real.
cat > "$BS_ROOT/bin/sleep" <<EOF
#!/usr/bin/env bash
case "\$1" in
  [0-9]|10) [ -n "\${BS_SLEEPS:-}" ] && echo "\$1" >> "\$BS_SLEEPS"; exit 0 ;;
esac
exec "$(command -v sleep)" "\$@"
EOF
# jq that fails ONLY on the driver's stream-assembly call (the one that binds $lane), so a case can
# make assembly fail through the public entry point while every other jq call still works.
cat > "$BS_ROOT/badjq/jq" <<EOF
#!/usr/bin/env bash
prev=""
for a in "\$@"; do
  if [ "\$prev" = "--arg" ] && [ "\$a" = "lane" ]; then echo assembly >> "\$BS_JQFAIL"; exit 5; fi
  prev="\$a"
done
exec "$REAL_JQ" "\$@"
EOF
chmod +x "$BS_ROOT/bin/curl" "$BS_ROOT/bin/sleep" "$BS_ROOT/badjq/jq"
export PATH="$BS_ROOT/bin:$PATH"

REVIEW_A="SEVERITY: WARNING CONFIDENCE: high FILE: a.ts:1 ISSUE: $(printf 'streamed review text %.0s' {1..40})"
readonly REVIEW_A

new_case() {  # a fresh, private world for one case
  BS_CASE="$(mktemp -d "$BS_ROOT/case.XXXXXX")"
  mkdir -p "$BS_CASE/payloads" "$BS_CASE/home"
  : > "$BS_CASE/calls"; : > "$BS_CASE/sleeps"
  ( umask 077; printf 'fixture-byteplus-key' > "$BS_CASE/byteplus.key" )
}
run_lane() {  # run_lane <provider> <fixture> [NAME=value ...] -> driver JSON on stdout
  local p="$1" fx="$2"; shift 2
  env ZUVO_HOME="$BS_CASE/home" ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_BYTEPLUS_KEY_FILE="$BS_CASE/byteplus.key" \
      BS_FIXTURE="$fx" BS_CALLS="$BS_CASE/calls" BS_PAYLOADS="$BS_CASE/payloads" BS_SLEEPS="$BS_CASE/sleeps" "$@" \
      bash "$ADV" --provider "$p" --single --json --files "$ADV_TEST_EMPTY" 2>"$BS_CASE/driver.err"
}
calls()    { cat "$BS_CASE/calls"; }                       # "" = no request was sent
backoff()  { tr '\n' ' ' < "$BS_CASE/sleeps" | sed 's/ $//'; }   # the retry sleeps, in order ("" = none)
assert_not_contains() { # local: assert.sh has the positive form only
  local haystack="$1" needle="$2" label="${3:-does not contain}"
  if [[ "$haystack" != *"$needle"* ]]; then pass "$label"; else fail "$label" "haystack contained <$needle>"; fi
}
evidence() { cat "$BS_CASE"/home/adversarial-failures/*/provider_"$1".stderr "$BS_CASE/driver.err" 2>/dev/null; }
outcome()  { printf '%s' "$1" | jq -r '.provider_outcomes'; }
review()   { printf '%s' "$1" | jq -r --arg p "$2" '.results[$p]'; }
payload()  { jq -r "$2" "$BS_CASE/payloads/payload-$1.json"; }
sse() {  # sse <name> <json-event>... -> path of a body ending in [DONE]
  local f="$BS_CASE/$1"; shift
  : > "$f"
  for ev in "$@"; do printf 'data: %s\n\n' "$ev" >> "$f"; done
  printf 'data: [DONE]\n\n' >> "$f"
  printf '%s' "$f"
}
chunk() { jq -cn --arg t "$1" '{choices:[{delta:{content:$t}}]}'; }
ok_stream() {  # the canonical good stream: reasoning, the review in two chunks, a usage chunk
  sse ok.sse '{"choices":[{"delta":{"reasoning_content":"SCRATCHPAD_MUST_NOT_LEAK"}}]}' \
    "$(chunk "${REVIEW_A:0:200}")" "$(chunk "${REVIEW_A:200}")" \
    '{"choices":[],"usage":{"prompt_tokens":11,"completion_tokens":22,"completion_tokens_details":{"reasoning_tokens":7}}}'
}

# ═══ Request: what each lane sends ═════════════════════════════════════════════════════════════

start_test "BS.1 byteplus sends ONE streamed request to the Coding Plan, key only via -K"
new_case; out=$(run_lane byteplus "$(ok_stream)"); rc=$?
assert_exit_code "0" "$rc" "accepted"
assert_eq "1" "$(calls)" "exactly one request"
args=$(cat "$BS_CASE/payloads/args-1")
assert_contains "$args" "https://ark.ap-southeast.bytepluses.com/api/coding/v3/chat/completions" "the Coding Plan endpoint"
assert_contains "$args" "-K" "headers come from a config file"
assert_not_contains "$args" "fixture-byteplus-key" "the key is not in argv (it would be visible in ps)"
assert_eq "true" "$(payload 1 '.stream')" "stream requested"
assert_eq "true" "$(payload 1 '.stream_options.include_usage')" "usage requested in the stream"
assert_eq "glm-5.3-flash" "$(payload 1 '.model')" "the lane's default model"

start_test "BS.2 byteplus-alt and byteplus-3 stream too, each with its own default model"
for lane_model in byteplus-alt:deepseek-v4-flash byteplus-3:dola-seed-2.0-code; do
  lane="${lane_model%%:*}"; model="${lane_model#*:}"
  new_case; out=$(run_lane "$lane" "$(ok_stream)"); rc=$?
  assert_exit_code "0" "$rc" "$lane accepted"
  assert_eq "true" "$(payload 1 '.stream')" "$lane asks for a stream"
  assert_eq "$model" "$(payload 1 '.model')" "$lane model"
  assert_eq "$REVIEW_A" "$(review "$out" "$lane")" "$lane review assembled"
done

start_test "BS.3 OpenRouter never streams — not even with ZUVO_OR_STREAM=1 exported"
new_case
jq -n --arg t "$REVIEW_A" '{choices:[{message:{content:$t}}]}' > "$BS_CASE/or.json"
out=$(run_lane openrouter "$BS_CASE/or.json" OPENROUTER_API_KEY=fixture-or-key ZUVO_OR_STREAM=1); rc=$?
assert_exit_code "0" "$rc" "openrouter review accepted"
assert_eq "null" "$(payload 1 '.stream')" "no stream flag in the payload"
assert_contains "$(cat "$BS_CASE/payloads/args-1")" "https://openrouter.ai/api/v1/chat/completions" "OpenRouter endpoint"
assert_eq "$REVIEW_A" "$(review "$out" openrouter)" "its JSON answer is the review"

# ═══ Assembly: what becomes the review ═════════════════════════════════════════════════════════

start_test "BS.4 the review is delta.content joined exactly; reasoning is dropped"
new_case; out=$(run_lane byteplus "$(ok_stream)"); rc=$?
assert_exit_code "0" "$rc" "accepted"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "content joined, byte for byte"
assert_not_contains "$(review "$out" byteplus)" "SCRATCHPAD_MUST_NOT_LEAK" "reasoning_content is not the review"

start_test "BS.5 delta.content as typed text parts is joined; non-text parts are dropped"
new_case
f=$(sse parts.sse "$(jq -cn --arg a "${REVIEW_A:0:300}" --arg b "${REVIEW_A:300}" \
  '{choices:[{delta:{content:[{type:"text",text:$a},{type:"image",url:"x"},{type:"text",text:$b}]}}]}')")
out=$(run_lane byteplus "$f"); rc=$?
assert_exit_code "0" "$rc" "accepted"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "text parts joined, image part dropped"

start_test "BS.6 a BOM and blank lines before the first event do not hide the stream"
new_case
{ printf '\xef\xbb\xbf\n\n'; cat "$(ok_stream)"; } > "$BS_CASE/bom.sse"
out=$(run_lane byteplus "$BS_CASE/bom.sse"); rc=$?
assert_exit_code "0" "$rc" "accepted"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "assembled despite the BOM"

start_test "BS.7 a multi-MB stream (a real reasoning model) is assembled under the driver's pipefail"
# The live run that found this: 401 s of glm-5.3-flash reasoning, a several-MB SSE body, and
# `printf | grep -q` under pipefail returned 141 → the body was read as "not SSE" and lost.
new_case
python3 - "$BS_CASE/big.sse" "$REVIEW_A" <<'PY'
import json, sys
out, review = sys.argv[1], sys.argv[2]
with open(out, "w") as f:
    for i in range(40000):
        f.write("data: " + json.dumps({"choices": [{"delta": {"content": "", "reasoning_content": "thinking step %d " % i}}]}) + "\n\n")
    f.write("data: " + json.dumps({"choices": [{"delta": {"content": review}}]}) + "\n\n")
    f.write("data: [DONE]\n\n")
PY
[ "$(wc -c < "$BS_CASE/big.sse")" -gt 2000000 ] && pass "fixture is multi-MB" || fail "fixture too small to reproduce SIGPIPE"
out=$(run_lane byteplus "$BS_CASE/big.sse"); rc=$?
assert_exit_code "0" "$rc" "a large streamed review is accepted"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "the review comes out of a multi-MB stream intact"

start_test "BS.8 a finish_reason without [DONE] is a complete stream"
new_case
{ chunk "$REVIEW_A"; jq -cn '{choices:[{delta:{},finish_reason:"stop"}]}'; } | sed 's/^/data: /' > "$BS_CASE/fin.sse"
out=$(run_lane byteplus "$BS_CASE/fin.sse"); rc=$?
assert_exit_code "0" "$rc" "accepted"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "its text is the review"

BS_SEED="${BS_SEED:-$RANDOM}"
start_test "BS.9 property (seed $BS_SEED): any chunking, interleaved reasoning, BOM and usage placement reassemble the review exactly"
# Re-run a failure with BS_SEED=<seed>. Each generated stream splits REVIEW_A at random points,
# interleaves reasoning-only and empty-content events, optionally prefixes a BOM and blank lines,
# and puts the usage chunk anywhere; the invariant is that the review is the original, exactly.
new_case
python3 - "$BS_CASE" "$REVIEW_A" "$BS_SEED" <<'PY'
import json, random, sys
d, review, seed = sys.argv[1], sys.argv[2], int(sys.argv[3])
rng = random.Random(seed)
for k in range(10):
    cuts = sorted(rng.sample(range(1, len(review)), rng.randint(0, 25)))
    parts = [review[a:b] for a, b in zip([0] + cuts, cuts + [len(review)])]
    ev = []
    for p in parts:
        if rng.random() < 0.3: ev.append({"choices": [{"delta": {"reasoning_content": "r%d" % rng.randint(0, 9)}}]})
        if rng.random() < 0.2: ev.append({"choices": [{"delta": {"content": ""}}]})
        ev.append({"choices": [{"delta": {"content": p}}]})
    ev.insert(rng.randint(0, len(ev)), {"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 2}})
    with open("%s/prop-%d.sse" % (d, k), "w", encoding="utf-8") as f:
        if rng.random() < 0.3: f.write("﻿" + "\n" * rng.randint(0, 3))
        for e in ev: f.write("data: " + json.dumps(e) + "\n" + ("\n" if rng.random() < 0.8 else ""))
        f.write("data: [DONE]\n\n")
PY
bad=0
for k in 0 1 2 3 4 5 6 7 8 9; do
  out=$(run_lane byteplus "$BS_CASE/prop-$k.sse")
  [[ "$(review "$out" byteplus)" == "$REVIEW_A" ]] || { bad=$((bad + 1)); echo "    seed $BS_SEED stream $k did not reassemble" >&2; }
done
assert_eq "0" "$bad" "10 generated streams, 0 that did not reassemble exactly"

# ═══ Failures: a stream that is not a whole review is never accepted ════════════════════════════

start_test "BS.10 an error event inside the stream fails the lane with the provider's message"
new_case
f=$(sse err.sse '{"error":{"message":"Coding Plan quota exhausted","code":"QuotaExceeded"}}')
out=$(run_lane byteplus "$f"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "byteplus:empty" "$(outcome "$out")" "the lane produced nothing"
assert_contains "$(evidence byteplus)" "returned error: Coding Plan quota exhausted" "the provider's message is the reason"
assert_eq "1" "$(calls)" "a refusal is not retried"
assert_eq "" "$(backoff)" "and nothing waited for a retry"

start_test "BS.11 an error event with only a code still fails with that code"
new_case
out=$(run_lane byteplus "$(sse code.sse '{"error":{"code":"InvalidSubscription"}}')"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(evidence byteplus)" "returned error: InvalidSubscription" "the code is the reported reason"

start_test "BS.12 reasoning without any content is an empty review, not a clean one; usage is the LAST usage chunk"
# The provider's stderr is kept only when a lane fails, so this is where the folded usage is visible.
new_case
f=$(sse empty.sse '{"choices":[],"usage":{"prompt_tokens":1,"completion_tokens":1}}' \
  '{"choices":[{"delta":{"reasoning_content":"thinking only"}}]}' \
  '{"choices":[],"usage":{"prompt_tokens":5,"completion_tokens":9,"completion_tokens_details":{"reasoning_tokens":7}}}')
out=$(run_lane byteplus "$f"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "byteplus:empty" "$(outcome "$out")" "empty content is excluded"
assert_contains "$(evidence byteplus)" "tokens: 5 in / 9 out (7 reasoning)" "usage folded from the last chunk that carries it"

start_test "BS.13 an event that does not parse fails the lane — a review with a hole is not a review"
new_case
printf 'data: %s\n\ndata: {"choices":[{"delta":{"content":"tail"}}\n\ndata: [DONE]\n\n' "$(chunk "$REVIEW_A")" > "$BS_CASE/torn.sse"
out=$(run_lane byteplus "$BS_CASE/torn.sse"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "null" "$(review "$out" byteplus)" "the partial text is not offered as a review"
assert_contains "$(evidence byteplus)" "byteplus: 1 of 2 stream event(s) did not parse" "the torn chunk is counted and named"
assert_eq "3" "$(calls)" "a stream broken in transit is asked for again, twice"

start_test "BS.14 a stream cut off mid-answer (no [DONE], no finish_reason) fails"
new_case
chunk "$REVIEW_A" | sed 's/^/data: /' > "$BS_CASE/cut.sse"
out=$(run_lane byteplus "$BS_CASE/cut.sse"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(evidence byteplus)" "byteplus: the stream ended without [DONE] or a finish_reason" "the truncation is named"
assert_eq "3" "$(calls)" "retried like a dropped connection"
assert_eq "3 6" "$(backoff)" "with the same backoff"

start_test "BS.15 an assembly that fails is an error, never an empty-looking answer"
new_case; out=$(run_lane byteplus "$(ok_stream)" PATH="$BS_ROOT/badjq:$PATH" BS_JQFAIL="$BS_CASE/jqfail"); rc=$?
assert_eq "assembly assembly assembly" "$(tr '\n' ' ' < "$BS_CASE/jqfail" | sed 's/ $//')" "the failing jq was hit once per attempt, on the assembly call only"
assert_exit_code "2" "$rc" "no review"
assert_contains "$(evidence byteplus)" "byteplus: the stream body could not be assembled" "the assembly failure is named"
assert_contains "$(evidence byteplus)" "returned error: the stream body could not be assembled" "and it takes the error path, not the empty-answer path"

start_test "BS.16 HTTP refusals fail fast with their own reason: 400, 401, 402"
for spec in "400:invalid model id" "401:invalid api key" "402:insufficient balance"; do
  code="${spec%%:*}"; msg="${spec#*:}"
  new_case
  jq -cn --arg m "$msg" '{error:{message:$m}}' > "$BS_CASE/refusal.json"
  out=$(run_lane byteplus "$BS_CASE/refusal.json" BS_HTTP="$code"); rc=$?
  assert_exit_code "2" "$rc" "HTTP $code: no review"
  assert_eq "1" "$(calls)" "HTTP $code: not retried"
  assert_contains "$(evidence byteplus)" "$msg" "HTTP $code: the body's reason is reported"
done

start_test "BS.17 the billing guard refuses a metered base URL before any request"
new_case; out=$(run_lane byteplus "$(ok_stream)" ZUVO_BYTEPLUS_BASE_URL="https://ark.ap-southeast.bytepluses.com/api/v3"); rc=$?
assert_exit_code "2" "$rc" "refused"
assert_eq "" "$(calls)" "no request was sent"
assert_contains "$(evidence byteplus)" "is not the Coding Plan path (/api/coding/v3) — refusing" "the reason is named"

start_test "BS.18 a malformed model id is refused, never repaired, before any request"
new_case; out=$(run_lane byteplus "$(ok_stream)" ZUVO_MODEL_BYTEPLUS='glm 5.3;rm'); rc=$?
assert_exit_code "2" "$rc" "refused"
assert_eq "" "$(calls)" "no request was sent"
assert_contains "$(evidence byteplus)" "model id 'glm 5.3;rm' is empty or has characters outside" "the bad id is named"

start_test "BS.19 a key file others can read is refused, and no request goes out"
new_case; chmod 644 "$BS_CASE/byteplus.key"
out=$(run_lane byteplus "$(ok_stream)"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "" "$(calls)" "no request was sent"
assert_contains "$(evidence byteplus)" "is mode 644 — refusing to read a non-private key file" "the reason is named"
assert_eq "null" "$(review "$out" byteplus)" "no review"

start_test "BS.20 a time budget too small for a request stops before sending one"
new_case; out=$(run_lane byteplus "$(ok_stream)" ZUVO_REVIEW_TIMEOUT=10); rc=$?
assert_exit_code "124" "$rc" "a timeout outcome"
assert_eq "" "$(calls)" "no request was sent"
assert_contains "$(evidence byteplus)" "byteplus out of time budget after 0 attempt(s)" "the budget is the reason"
assert_eq "null" "$(review "$out" byteplus)" "no review"

# ═══ Retries: transport deaths and throttling ══════════════════════════════════════════════════

start_test "BS.21 every transient curl exit (16, 92, 18, 35, 52, 56) is retried once after a 3 s backoff"
for xc in 16 92 18 35 52 56; do
  new_case; out=$(run_lane byteplus "$(ok_stream)" BS_EXIT_SEQ="$xc"); rc=$?
  assert_exit_code "0" "$rc" "curl $xc, then a whole stream"
  assert_eq "2" "$(calls)" "curl $xc: exactly one retry"
  assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "curl $xc: the retried stream is the review"
  assert_eq "3" "$(backoff)" "curl $xc: one 3 s backoff"
done

start_test "BS.22 a transport failure on every attempt gives up after two retries, with curl's reason"
new_case; out=$(run_lane byteplus "$(ok_stream)" BS_EXIT_SEQ=16,16,16); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "3" "$(calls)" "two retries, then give up"
assert_eq "3 6" "$(backoff)" "backoff grows: 3 s, then 6 s"
assert_contains "$(evidence byteplus)" "transient (HTTP" "the retry note is kept"
assert_contains "$(evidence byteplus)" "curl: (16) simulated transport failure" "the failure line carries curl's own reason"

start_test "BS.23 HTTP 429 is retried, then the stream is read"
new_case; out=$(run_lane byteplus "$(ok_stream)" BS_HTTP_SEQ=429,200); rc=$?
assert_exit_code "0" "$rc" "second attempt succeeds"
assert_eq "2" "$(calls)" "one retry"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "the retried stream is assembled"

start_test "BS.24 three 5xx give up on the status; a 5xx body is never folded as a stream"
new_case
printf 'data: %s\n\ndata: {"choices":[{"delta":{"content":"tail"}}\n\ndata: [DONE]\n\n' "$(chunk "$REVIEW_A")" > "$BS_CASE/torn.sse"
out=$(run_lane byteplus "$BS_CASE/torn.sse" BS_HTTP_SEQ=503,503,503); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "3" "$(calls)" "two retries, then give up"
assert_contains "$(evidence byteplus)" "HTTP 503" "failed on the status"
assert_not_contains "$(evidence byteplus)" "did not parse" "the 503 body was never assembled as a stream"

start_test "BS.25 a curl timeout (28) is a timeout outcome, not retried"
new_case; out=$(run_lane byteplus "$(ok_stream)" BS_EXIT_SEQ=28); rc=$?
assert_exit_code "124" "$rc" "the driver's timeout exit (124), distinct from a failed provider (2)"
assert_eq "1" "$(calls)" "a timeout is not retried"
assert_eq "" "$(backoff)" "no backoff after a timeout"
assert_eq "byteplus:timeout" "$(outcome "$out")" "reported as a timeout"

# ═══ Keys and bodies the lane must not trust ═══════════════════════════════════════════════════

start_test "BS.26 no key file: the lane is not attempted and sends nothing"
new_case; rm -f "$BS_CASE/byteplus.key"
out=$(run_lane byteplus "$(ok_stream)"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "" "$(calls)" "no request was sent"
assert_eq "null" "$(review "$out" byteplus)" "no review"
assert_eq "byteplus:empty" "$(outcome "$out")" "no review from the lane"
assert_contains "$(evidence byteplus)" "byteplus has no key (env or $BS_CASE/byteplus.key) — not attempted" "the missing key is the named reason, not a silent empty"

start_test "BS.27 a key holding a quote is refused before it reaches a curl config"
new_case; ( umask 077; printf 'abc"def' > "$BS_CASE/byteplus.key" )
out=$(run_lane byteplus "$(ok_stream)"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "" "$(calls)" "no request was sent"
assert_contains "$(evidence byteplus)" "byteplus key contains quote/backslash/newline — refusing" "the reason is named"

start_test "BS.28 a 200 JSON answer on a streamed lane (a gateway that ignored stream:true) is still read"
new_case
jq -n --arg t "$REVIEW_A" '{choices:[{message:{content:$t}}]}' > "$BS_CASE/plain.json"
out=$(run_lane byteplus "$BS_CASE/plain.json"); rc=$?
assert_exit_code "0" "$rc" "accepted"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "the non-SSE body passes through to the normal decoder"

start_test "BS.29 a foreign error body (an HTML gateway page) fails on the status, quoted printable and bounded"
new_case
{ printf '<html><body>\033[31mBad Gateway\033[0m '; printf 'x%.0s' {1..400}; printf '</body></html>'; } > "$BS_CASE/gw.html"
out=$(run_lane byteplus "$BS_CASE/gw.html" BS_HTTP_SEQ=502,502,502); rc=$?
assert_exit_code "2" "$rc" "no review"
ev=$(evidence byteplus)
assert_contains "$ev" "byteplus HTTP 502: <html><body>?[31mBad Gateway" "the lane, the status and the page start, escape bytes neutralised"
assert_not_contains "$ev" $'\033' "no raw escape byte reaches the log"
assert_not_contains "$ev" "</body></html>" "the quote is bounded (160 bytes), not the whole page"

start_test "BS.30 a stream whose content is only non-text parts is an empty review"
new_case
f=$(sse img.sse '{"choices":[{"delta":{"content":[{"type":"image","url":"x"}]}}]}')
out=$(run_lane byteplus "$f"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "byteplus:empty" "$(outcome "$out")" "nothing textual, nothing reviewed"
assert_eq "1" "$(calls)" "not retried"

start_test "BS.31 a non-2xx with an empty body and no error object fails fast on its status"
new_case; : > "$BS_CASE/blank"
out=$(run_lane byteplus "$BS_CASE/blank" BS_HTTP=404); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "1" "$(calls)" "a 404 is not retried"
assert_eq "" "$(backoff)" "and nothing waited"
assert_contains "$(evidence byteplus)" "byteplus HTTP 404:" "the status is the reason"

start_test "BS.32 a non-transient curl exit (6, host not resolved) fails at once with curl's reason"
new_case; out=$(run_lane byteplus "$(ok_stream)" BS_EXIT_SEQ=6); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "1" "$(calls)" "not retried"
assert_eq "" "$(backoff)" "nothing waited"
assert_contains "$(evidence byteplus)" "byteplus failed (exit 6): curl: (6) simulated transport failure" "the exit and curl's reason are named"

start_test "BS.33 an error event that is a bare string fails with that string"
new_case
out=$(run_lane byteplus "$(sse bare.sse '{"error":"plan suspended"}')"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(evidence byteplus)" "returned error: plan suspended" "the string is the reason"

start_test "BS.34 HTTP 429 on every attempt gives up after two retries with the status"
new_case
jq -cn '{error:{message:"rate limited"}}' > "$BS_CASE/429.json"
out=$(run_lane byteplus "$BS_CASE/429.json" BS_HTTP_SEQ=429,429,429); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "3" "$(calls)" "two retries, then give up"
assert_eq "3 6" "$(backoff)" "3 s, then 6 s"
assert_contains "$(evidence byteplus)" "rate limited" "the provider's reason is kept"

start_test "BS.35 the billing guard allows /api/coding without /v3, a trailing slash, and a query on the right path"
for url in "https://ark.ap-southeast.bytepluses.com/api/coding" \
           "https://ark.ap-southeast.bytepluses.com/api/coding/v3/" \
           "https://ark.ap-southeast.bytepluses.com/api/coding/v3?x=1"; do
  new_case; out=$(run_lane byteplus "$(ok_stream)" ZUVO_BYTEPLUS_BASE_URL="$url"); rc=$?
  assert_exit_code "0" "$rc" "$url accepted"
  assert_eq "1" "$(calls)" "$url: one request"
  assert_contains "$(cat "$BS_CASE/payloads/args-1")" "${url}/chat/completions" "$url: sent where it was configured"
done

start_test "BS.36 a stream cut off once, then whole on the retry, is the review"
new_case
chunk "$REVIEW_A" | sed 's/^/data: /' > "$BS_CASE/cut.sse"
out=$(run_lane byteplus "$(ok_stream)" BS_FIXTURE_1="$BS_CASE/cut.sse"); rc=$?
assert_exit_code "0" "$rc" "the second attempt succeeds"
assert_eq "2" "$(calls)" "one retry"
assert_eq "$REVIEW_A" "$(review "$out" byteplus)" "the whole stream is the review"

start_test "BS.37 an event that is valid JSON but not an object counts as broken, not as nothing"
new_case
f=$(sse nonobj.sse "$(chunk "$REVIEW_A")" 'null' '"stray"')
out=$(run_lane byteplus "$f"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(evidence byteplus)" "byteplus: 2 of 3 stream event(s) did not parse" "both non-object events are counted"

start_test "BS.38 an empty finish_reason does not complete a stream that has no [DONE]"
new_case
{ chunk "$REVIEW_A"; jq -cn '{choices:[{delta:{},finish_reason:""}]}'; } | sed 's/^/data: /' > "$BS_CASE/emptyfin.sse"
out=$(run_lane byteplus "$BS_CASE/emptyfin.sse"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_contains "$(evidence byteplus)" "cut off mid-answer" "treated as truncated"

start_test "BS.39 a provider error event is NOT retried — asking again does not fix a refusal"
new_case
out=$(run_lane byteplus "$(sse q.sse '{"error":{"message":"quota exhausted"}}')"); rc=$?
assert_exit_code "2" "$rc" "no review"
assert_eq "1" "$(calls)" "one request only"
