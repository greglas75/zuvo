#!/usr/bin/env bash
# Characterization of run_openrouter (scripts/lib/adversarial-lanes-http.sh): its response decoder
# (openrouter_review_text) and content guard, the transient-retry loop and its time budget, the
# `.error.message` refusal, and where the key comes from (env, else a private key file).
# Sourced by run.sh; every case runs the real driver with --provider openrouter.
# The fake curl returns fixture bytes; no network or paid API is used. The retry cases run on a fake
# clock (the fake date/sleep below): the backoff is never waited out, and no verdict depends on real time.
# Case ids OR.6-OR.10 belong to the sibling test-openrouter-response-refactor-regression.sh.

ADV="$ROOT/scripts/adversarial-review.sh"
OR_HOME="$(mktemp -d "$ADV_TEST_HOME/openrouter-response.XXXXXX")"
mkdir -p "$OR_HOME/bin"
export ZUVO_HOME="$OR_HOME" OPENROUTER_API_KEY="fixture-key"
# The real date and sleep, resolved before the fakes below shadow them on PATH; the fakes call these.
OR_REAL_DATE="$(command -v date)"; OR_REAL_SLEEP="$(command -v sleep)"
export OR_REAL_DATE OR_REAL_SLEEP
export PATH="$OR_HOME/bin:$PATH"
trap 'rm -rf "$OR_HOME"' EXIT
# The fake curl. One request answers $OR_RESPONSE_FILE with HTTP $OR_HTTP_STATUS (default 200) and exits 0 —
# or, with $OR_CURL_PLAN, line N of that file ("<curl exit> <http status> [<body file>]") for request N, its
# last line for every request after. A dropped connection is "52 000": curl's -w prints 000 when no response
# came. Every request appends a line to $OR_CURL_LOG (when set): how many requests the case made.
# $OR_PAYLOAD_COPY gets a copy of the request body (-d @file), $OR_AUTH_COPY of the header config (-K file).
cat > "$OR_HOME/bin/curl" <<'EOF'
#!/usr/bin/env bash
n=1
if [ -n "${OR_CURL_LOG:-}" ]; then echo request >> "$OR_CURL_LOG"; n="$(wc -l < "$OR_CURL_LOG" | tr -d ' ')"; fi
prev=""
for a in "$@"; do
  [ "$prev" = "-d" ] && [ -n "${OR_PAYLOAD_COPY:-}" ] && cp "${a#@}" "$OR_PAYLOAD_COPY"
  [ "$prev" = "-K" ] && [ -n "${OR_AUTH_COPY:-}" ] && cp "$a" "$OR_AUTH_COPY"
  prev="$a"
done
rc=0; code="${OR_HTTP_STATUS:-200}"; body="${OR_RESPONSE_FILE:-}"
if [ -n "${OR_CURL_PLAN:-}" ]; then
  line="$(sed -n "${n}p" "$OR_CURL_PLAN")"; [ -n "$line" ] || line="$(tail -n 1 "$OR_CURL_PLAN")"
  read -r rc code body <<< "$line"
fi
[ -z "$body" ] || cat "$body"
printf '\n%s' "$code"
exit "$rc"
EOF
# The fake clock, active only when $OR_CLOCK names a file holding the time: `date +%s` reads it, and a whole
# 1-10 s sleep (the lane's backoff: 3, then 6) is not waited — it moves the clock on by that much and
# is logged, one per line, in $OR_CLOCK.sleeps. Time passes ONLY by those sleeps, so the budget arithmetic
# is exact. Any other date or sleep (the run's watchdog, a lock's sub-second poll) is the real one.
cat > "$OR_HOME/bin/date" <<'EOF'
#!/bin/sh
if [ -n "${OR_CLOCK:-}" ] && [ "$#" -eq 1 ] && [ "$1" = +%s ]; then cat "$OR_CLOCK"; exit 0; fi
exec "$OR_REAL_DATE" "$@"
EOF
cat > "$OR_HOME/bin/sleep" <<'EOF'
#!/bin/sh
case "${1:-}" in ''|*[!0-9]*) exec "$OR_REAL_SLEEP" "$@" ;; esac
if [ -n "${OR_CLOCK:-}" ] && [ "$#" -eq 1 ] && [ "$1" -ge 1 ] && [ "$1" -le 10 ]; then
  echo "$1" >> "$OR_CLOCK.sleeps"
  echo $(( $(cat "$OR_CLOCK") + $1 )) > "$OR_CLOCK"
  exit 0
fi
exec "$OR_REAL_SLEEP" "$@"
EOF
chmod +x "$OR_HOME/bin/curl" "$OR_HOME/bin/date" "$OR_HOME/bin/sleep"

# openrouter_case <response file> [<http status>] — one request answered with that body and status.
openrouter_case() {
  rm -f "$OR_HOME/curl.calls"
  OR_CURL_LOG="$OR_HOME/curl.calls" OR_RESPONSE_FILE="$1" OR_HTTP_STATUS="${2:-200}" \
    bash "$ADV" --provider openrouter --single --json --files "$ADV_TEST_EMPTY" 2>"$OR_HOME/driver.err"
}
# curl_calls — how many requests the last run made.
curl_calls() { if [ -f "$OR_HOME/curl.calls" ]; then wc -l < "$OR_HOME/curl.calls" | tr -d ' '; else echo 0; fi; }

# or_run <tag> <ZUVO_REVIEW_TIMEOUT> <plan line>... [-- VAR=value...] — one run whose requests are answered
# by the plan, on the fake clock (starting at the real time now), with a fixed model id (the lane's notes
# name it) and a ZUVO_HOME of its own: its provider-health ledger starts empty, and the failure evidence
# under it is this run's alone (read with lane_err). JSON on stdout, the driver's stderr in driver.err.
or_run() {
  local tag="$1" t="$2" envs=(); shift 2
  local d="$OR_HOME/case-$tag"
  mkdir -p "$d"; : > "$d/plan"
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do printf '%s\n' "$1" >> "$d/plan"; shift; done
  [ $# -gt 0 ] && shift
  envs=("$@")
  "$OR_REAL_DATE" +%s > "$d/clock"; rm -f "$d/clock.sleeps" "$OR_HOME/curl.calls"
  env ZUVO_HOME="$d/zh" ZUVO_REVIEW_TIMEOUT="$t" ZUVO_OPENROUTER_MODEL=vendor/or-fixture \
    OR_CURL_PLAN="$d/plan" OR_CLOCK="$d/clock" OR_CURL_LOG="$OR_HOME/curl.calls" ${envs[@]+"${envs[@]}"} \
    bash "$ADV" --provider openrouter --single --json --files "$ADV_TEST_EMPTY" 2>"$OR_HOME/driver.err"
}
# lane_err <tag> — the lane's own stderr, as the run kept it in its failure evidence.
lane_err() { cat "$OR_HOME/case-$1/zh"/adversarial-failures/*/provider_openrouter.stderr 2>/dev/null; }
# slept <tag> — the backoff sleeps the lane took on the fake clock, space-joined.
slept() { tr '\n' ' ' 2>/dev/null < "$OR_HOME/case-$1/clock.sleeps" | sed 's/ $//'; }

jq -n '{choices:[{message:{content:"OPENROUTER_RETRIED_REVIEW_41"}}]}' > "$OR_HOME/ok.json"
printf 'upstream busy' > "$OR_HOME/busy.txt"
jq -n '{error:{message:"Invalid API key"}}' > "$OR_HOME/api-error.json"

start_test "OR.1 scalar review content is returned without JSON wrapper text"
jq -n '{choices:[{message:{content:"OPENROUTER_SCALAR_REVIEW_927"}}],usage:{prompt_tokens:12,completion_tokens:34}}' > "$OR_HOME/scalar.json"
out=$(openrouter_case "$OR_HOME/scalar.json"); rc=$?
assert_exit_code "0" "$rc" "scalar review accepted"
assert_eq "OPENROUTER_SCALAR_REVIEW_927" "$(printf '%s' "$out" | jq -r '.results.openrouter')" "exact scalar review text"
# run_openrouter (adversarial-lanes-http.sh) — a 2xx answer leaves the retry loop at once: no second request.
assert_eq "1" "$(curl_calls)" "a 200 answer took exactly one request"
start_test "OR.2 typed text blocks are concatenated and non-text blocks omitted"
jq -n '{choices:[{message:{content:[{type:"text",text:"PART_A_"},{type:"image",url:"decoy"},{type:"text",text:"PART_B"}]}}],usage:{prompt_tokens:2,completion_tokens:3}}' > "$OR_HOME/blocks.json"
out=$(openrouter_case "$OR_HOME/blocks.json"); rc=$?
assert_exit_code "0" "$rc" "typed content accepted"
assert_eq "PART_A_PART_B" "$(printf '%s' "$out" | jq -r '.results.openrouter')" "text blocks joined without image data"

start_test "OR.3 short quota content is refused as an error"
jq -n '{choices:[{message:{content:"quota reached"}}]}' > "$OR_HOME/quota.json"
out=$(openrouter_case "$OR_HOME/quota.json"); rc=$?
assert_exit_code "2" "$rc" "quota text is no review"
assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "JSON status reports no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "quota content was excluded"
assert_contains "$(cat "$OR_HOME/driver.err")" "failed or returned empty" "the driver reports the refusal"

start_test "OR.4 a long genuine review may quote rate limit"
long_review="$(printf 'x%.0s' {1..1100}) rate limit discussed in a finding"
jq -n --arg text "$long_review" '{choices:[{message:{content:$text}}]}' > "$OR_HOME/long.json"
out=$(openrouter_case "$OR_HOME/long.json"); rc=$?
assert_exit_code "0" "$rc" "quoted phrase does not reject a long review"
assert_contains "$(printf '%s' "$out" | jq -r '.results.openrouter')" "rate limit discussed in a finding" "review content is preserved"

start_test "OR.5 long error-prefixed content is refused"
long_error="error: $(printf 'x%.0s' {1..1100})"
jq -n --arg text "$long_error" '{choices:[{message:{content:$text}}]}' > "$OR_HOME/long-error.json"
out=$(openrouter_case "$OR_HOME/long-error.json"); rc=$?
assert_exit_code "2" "$rc" "error prefix still rejects long output"
assert_eq "error" "$(printf '%s' "$out" | jq -r '.status')" "JSON status reports no review"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "long error content was excluded"
assert_contains "$(cat "$OR_HOME/driver.err")" "failed or returned empty" "the driver reports the refusal"

# Not OR.6: the sibling regression file uses that id for a different case.
start_test "OR.11 the request body carries the model, the prompt and temperature 0.2"
jq -n '{choices:[{message:{content:"OPENROUTER_REQUEST_BODY_REVIEW"}}]}' > "$OR_HOME/request.json"
rm -f "$OR_HOME/payload.json"
OR_PAYLOAD_COPY="$OR_HOME/payload.json" ZUVO_OPENROUTER_MODEL=qwen/qwen3.8-flash openrouter_case "$OR_HOME/request.json" >/dev/null
assert_eq "0.2" "$(jq -r '.temperature' "$OR_HOME/payload.json" 2>/dev/null)" "temperature 0.2 is in the request"
assert_eq "qwen/qwen3.8-flash" "$(jq -r '.model' "$OR_HOME/payload.json" 2>/dev/null)" "the lane's model is in the request"
assert_eq "user" "$(jq -r '.messages[0].role' "$OR_HOME/payload.json" 2>/dev/null)" "the prompt goes as the user message"

# ─── the transient-retry loop (run_openrouter, adversarial-lanes-http.sh) ───────
start_test "OR.12 a 429 is retried after the backoff, and the answer that follows is the review"
out=$(or_run r429 240 "0 429 $OR_HOME/busy.txt" "0 200 $OR_HOME/ok.json"); rc=$?
assert_exit_code "0" "$rc" "the retried request produced a review"
assert_eq "OPENROUTER_RETRIED_REVIEW_41" "$(printf '%s' "$out" | jq -r '.results.openrouter')" "the review is the second answer's content"
assert_eq "openrouter:ok" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the lane is ok"
# run_openrouter: 429 is transient; retried while _or_try < OR_ATTEMPTS, after a sleep of _or_try * 3
assert_eq "2" "$(curl_calls)" "two requests: the throttled one and its retry"
assert_eq "3" "$(slept r429)" "one backoff of 3 s before the retry"

start_test "OR.13 5xx answers are transient: three requests in all, then the last status is the failure"
out=$(or_run r5xx 240 "0 503 $OR_HOME/busy.txt" "0 502 $OR_HOME/busy.txt" "0 500 $OR_HOME/busy.txt"); rc=$?
assert_exit_code "2" "$rc" "no review after the attempts ran out"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the lane failed"
# run_openrouter: 5?? is transient, each retry gets its NOTE, OR_ATTEMPTS=3 (a module constant), then its
# non-2xx check fails the lane, body quoted
assert_eq "3" "$(curl_calls)" "OR_ATTEMPTS: three requests, no fourth"
assert_eq "3 6" "$(slept r5xx)" "backoffs of 3 s then 6 s"
assert_eq "  NOTE: openrouter [vendor/or-fixture] transient (HTTP 503, curl 0) — retry 1/2
  NOTE: openrouter [vendor/or-fixture] transient (HTTP 502, curl 0) — retry 2/2
  WARN: openrouter HTTP 500: upstream busy" "$(lane_err r5xx)" "the lane notes each retry, then quotes the last status and body"

start_test "OR.14 dropped connections (curl 52, 56, 35) are transient too"
out=$(or_run rdrop 240 "52 000" "56 000" "35 000"); rc=$?
assert_exit_code "2" "$rc" "no review after the attempts ran out"
assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the lane failed"
# run_openrouter: curl 52/56/35 are transient, then a curl failure goes through lane_exit_warn with its exit code
assert_eq "3" "$(curl_calls)" "three requests"
assert_eq "3 6" "$(slept rdrop)" "the same backoff as for an HTTP status"
assert_eq "  NOTE: openrouter [vendor/or-fixture] transient (HTTP 000, curl 52) — retry 1/2
  NOTE: openrouter [vendor/or-fixture] transient (HTTP 000, curl 56) — retry 2/2
  WARN: openrouter failed (exit 35)" "$(lane_err rdrop)" "each dropped connection is noted, the last one fails the lane"

start_test "OR.15 an OpenAI-style .error.message is a refusal, never retried — even under HTTP 200"
# run_openrouter reads .error.message when curl succeeded, and an error is a WARN + status 1. 401 is not
# transient, and a 200 carrying an error body is caught by the api_err check, before the 2xx check could pass
# it.
for _code in 401 200; do
  out=$(openrouter_case "$OR_HOME/api-error.json" "$_code"); rc=$?
  assert_exit_code "2" "$rc" "HTTP $_code with an error body: no review"
  assert_eq "openrouter:empty" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "HTTP $_code: the lane failed"
  assert_eq "1" "$(curl_calls)" "HTTP $_code: one request, no retry"
  assert_contains "$(cat "$OR_HOME/driver.err")" "openrouter returned error: Invalid API key" "HTTP $_code: the API's message is the reason given"
done

start_test "OR.16 a curl failure outside 52/56/35 is not retried; curl's own timeout (28) is a timeout"
out=$(or_run c7 240 "7 000"); rc=$?
assert_exit_code "2" "$rc" "curl 7 (connection refused): no review"
assert_eq "1" "$(curl_calls)" "curl 7: one request, no retry"
assert_eq "" "$(slept c7)" "curl 7: no backoff"
assert_eq "  WARN: openrouter failed (exit 7)" "$(lane_err c7)" "curl 7: the lane names the exit code"
out=$(or_run c28 240 "28 000"); rc=$?
# run_openrouter's curl-failure arm — lane_exit_warn with 28 as the timeout status, and return 124
assert_exit_code "124" "$rc" "curl 28: the run reports a timeout"
assert_eq "openrouter:timeout" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "curl 28: the outcome is timeout"
assert_eq "1" "$(curl_calls)" "curl 28: one request, no retry"
assert_eq "  WARN: openrouter timed out after 240s" "$(lane_err c28)" "curl 28: the lane says how long it had"

start_test "OR.17 retries live inside PROVIDER_TIMEOUT: an attempt needs OR_MIN_ATTEMPT_SECONDS (15 s) left"
# run_openrouter's _or_deadline, and its OR_MIN_ATTEMPT_SECONDS check before every attempt. 23 s: 23 left,
# then 20, then 14 — out of budget before the third request, status 124.
out=$(or_run budget23 23 "0 429 $OR_HOME/busy.txt"); rc=$?
assert_exit_code "124" "$rc" "out of budget: the run reports a timeout"
assert_eq "openrouter:timeout" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "out of budget: the outcome is timeout"
assert_eq "2" "$(curl_calls)" "two requests fitted the budget"
assert_eq "  NOTE: openrouter [vendor/or-fixture] transient (HTTP 429, curl 0) — retry 1/2
  NOTE: openrouter [vendor/or-fixture] transient (HTTP 429, curl 0) — retry 2/2
  WARN: openrouter out of time budget after 2 attempt(s)" "$(lane_err budget23)" "the lane says how many attempts it made"
# The boundary: 24 s leaves exactly 15 before the third request — enough (the check is `-lt`), so the third
# request goes out and its 429, the last attempt, is the failure.
out=$(or_run budget24 24 "0 429 $OR_HOME/busy.txt"); rc=$?
assert_exit_code "2" "$rc" "15 s left is enough: the third attempt runs and fails"
assert_eq "3" "$(curl_calls)" "three requests"
assert_eq "  WARN: openrouter HTTP 429: upstream busy" "$(lane_err budget24 | tail -n 1)" "the third 429 is quoted as the failure"
# 14 s from the start: not even a first request.
out=$(or_run budget14 14 "0 200 $OR_HOME/ok.json"); rc=$?
assert_exit_code "124" "$rc" "a budget under 15 s: a timeout"
assert_eq "0" "$(curl_calls)" "no request at all"
assert_eq "  WARN: openrouter out of time budget after 0 attempt(s)" "$(lane_err budget14)" "…said with zero attempts"
# 15 s from the start: the first request goes out (the same `-lt` boundary, at the first attempt).
out=$(or_run budget15 15 "0 200 $OR_HOME/ok.json"); rc=$?
assert_exit_code "0" "$rc" "a budget of exactly 15 s: the request is made and answers"
assert_eq "1" "$(curl_calls)" "one request"

# ─── where the key comes from (run_openrouter, adversarial-lanes-http.sh) ───────
start_test "OR.18 a key file readable by group or others is refused; a private one is used"
mkdir -p "$OR_HOME/keys"
for _mode in 640 604; do
  _kf="$OR_HOME/keys/k$_mode.key"; printf 'file-key-%s' "$_mode" > "$_kf"; chmod "$_mode" "$_kf"
  out=$(or_run "key$_mode" 240 "0 200 $OR_HOME/ok.json" -- OPENROUTER_API_KEY= ZUVO_OR_KEY_FILE="$_kf"); rc=$?
  # run_openrouter's mode check — the mode, normalised to three digits, must be 600 or 400; anything else:
  # WARN, key unread
  assert_eq "0" "$(curl_calls)" "mode $_mode: no request is made"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.results')" "mode $_mode: no review"
  assert_eq "  WARN: openrouter has no usable API key ($_kf is mode $_mode — refusing to read a non-private key file) — not run, and not held against the lane" \
    "$(lane_err "key$_mode")" "mode $_mode: the lane says why, in one line"
  assert_contains "$(cat "$OR_HOME/driver.err")" "$_kf is mode $_mode — refusing to read a non-private key file" "mode $_mode: the driver relays the reason"
  # lane_no_key (lanes-http.sh) — a refused key file is no-key, never a failure of the lane
  assert_eq "openrouter:no-key" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "mode $_mode: the outcome is no-key"
done
for _mode in 600 400; do
  _kf="$OR_HOME/keys/k$_mode.key"; printf 'file-key-%s' "$_mode" > "$_kf"; chmod "$_mode" "$_kf"
  rm -f "$OR_HOME/auth.cfg"
  out=$(or_run "key$_mode" 240 "0 200 $OR_HOME/ok.json" -- OPENROUTER_API_KEY= ZUVO_OR_KEY_FILE="$_kf" OR_AUTH_COPY="$OR_HOME/auth.cfg"); rc=$?
  # run_openrouter reads a private file — its key is the one the request carries (curl_auth_config, -K)
  assert_exit_code "0" "$rc" "mode $_mode: the review runs"
  assert_eq "1" "$(curl_calls)" "mode $_mode: one request"
  assert_eq 'header = "Authorization: Bearer file-key-'"$_mode"'"' "$(grep Authorization "$OR_HOME/auth.cfg" 2>/dev/null)" \
    "mode $_mode: the request carries the file's key"
done

start_test "OR.19 no key at all: the lane makes no request, says why, and is no-key — not benched"
out=$(or_run nokey 240 "0 200 $OR_HOME/ok.json" -- OPENROUTER_API_KEY= ZUVO_OR_KEY_FILE="$OR_HOME/keys/absent.key"); rc=$?
# No env key, no key file: return before anything is built or sent (lane_no_key), and say so as no-key — an
# `empty` would be a failure row in the provider-health ledger, benching the lane once the key is set.
assert_exit_code "2" "$rc" "no lane ran: no review"
assert_eq "0" "$(curl_calls)" "no request is made"
assert_eq "null" "$(printf '%s' "$out" | jq -r '.results')" "no review"
_ev="$(ls "$OR_HOME/case-nokey/zh"/adversarial-failures/*/provider_openrouter.stderr 2>/dev/null)"
assert_ne "" "$_ev" "premise: the run kept the lane's stderr"
assert_eq "  WARN: openrouter has no usable API key (no key in the environment and no key file $OR_HOME/keys/absent.key) — not run, and not held against the lane" \
  "$(lane_err nokey)" "the lane says why it did not run"
assert_eq "openrouter:no-key" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "the outcome is no-key, not empty"
assert_eq "" "$(awk -F'\t' '$1 == "openrouter"' "$OR_HOME/case-nokey/zh/provider-health.tsv" 2>/dev/null)" \
  "no failure row in the provider-health ledger"
assert_contains "$(cat "$OR_HOME/driver.err")" "no lane could run — no usable API key for: openrouter" "the run says no lane could run"

start_test "OR.20 a key holding a quote, a backslash or a line break is refused before any request"
# lanes-http.sh (run_openrouter, and curl_auth_config — the same pattern): such a key would end the curl config's quoted
# `header = "Authorization: Bearer …"` string and add a directive of its own, so the lane refuses it as no-key with one
# WARN, status 1, before the config, the payload or a request is made.
OR20_N=0
for or20_key in 'abc"def' 'abc\def' $'abc\ndef'; do
  OR20_N=$(( OR20_N + 1 ))
  out=$(or_run "badkey$OR20_N" 240 "0 200 $OR_HOME/ok.json" -- OPENROUTER_API_KEY="$or20_key" OR_AUTH_COPY="$OR_HOME/auth-badkey$OR20_N.cfg"); rc=$?
  assert_exit_code "2" "$rc" "key $OR20_N: no review"
  assert_eq "0" "$(curl_calls)" "key $OR20_N: no request is made"
  assert_eq "null" "$(printf '%s' "$out" | jq -r '.results')" "key $OR20_N: no review in the JSON"
  assert_eq "  WARN: openrouter has no usable API key (its key contains a quote, backslash or line break — refusing to build a curl config) — not run, and not held against the lane" \
    "$(lane_err "badkey$OR20_N")" "key $OR20_N: the lane says why, in exactly that one line"
  assert_contains "$(cat "$OR_HOME/driver.err")" "openrouter was not run: openrouter has no usable API key (its key contains a quote, backslash or line break — refusing to build a curl config)" \
    "key $OR20_N: the driver relays the reason, and names the lane not run (lane_failed_verb)"
  # A malformed key is the configuration's fault: no-key, never a failure of the lane (lane_no_key).
  assert_eq "openrouter:no-key" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "key $OR20_N: the outcome is no-key"
  assert_eq "absent" "$([ -e "$OR_HOME/auth-badkey$OR20_N.cfg" ] && echo present || echo absent)" "key $OR20_N: no curl config ever reached curl"
done

start_test "OR.21 an EMPTY private key file is no-key: '<file> is empty', no request, not held against the lane"
# run_openrouter (adversarial-lanes-http.sh) — a mode-600 file is read; nothing in it (or only a newline,
# which $(<f) drops) leaves no key, and lane_no_key says why and records no-key.
OR21_N=0
for or21_body in '' $'\n'; do
  OR21_N=$(( OR21_N + 1 ))
  _kf="$OR_HOME/keys/empty$OR21_N.key"; mkdir -p "$OR_HOME/keys"; printf '%s' "$or21_body" > "$_kf"; chmod 600 "$_kf"
  out=$(or_run "emptykey$OR21_N" 240 "0 200 $OR_HOME/ok.json" -- OPENROUTER_API_KEY= ZUVO_OR_KEY_FILE="$_kf"); rc=$?
  assert_exit_code "2" "$rc" "file $OR21_N: no lane ran: no review"
  assert_eq "0" "$(curl_calls)" "file $OR21_N: no request is made"
  assert_eq "  WARN: openrouter has no usable API key ($_kf is empty) — not run, and not held against the lane" \
    "$(lane_err "emptykey$OR21_N")" "file $OR21_N: the lane names the empty file, in one line"
  assert_eq "openrouter:no-key" "$(printf '%s' "$out" | jq -r '.provider_outcomes')" "file $OR21_N: the outcome is no-key, never empty"
  # The run's ledger exists (ar_bench_failing_lanes creates it under ZUVO_HOME), so an empty read below is a
  # ledger with no openrouter row — not a ledger that was never written.
  assert_eq "present" "$([ -f "$OR_HOME/case-emptykey$OR21_N/zh/provider-health.tsv" ] && echo present || echo absent)" \
    "file $OR21_N: premise: the run kept a provider-health ledger"
  assert_eq "" "$(awk -F'\t' '$1 == "openrouter"' "$OR_HOME/case-emptykey$OR21_N/zh/provider-health.tsv" 2>/dev/null)" \
    "file $OR21_N: no failure row in the provider-health ledger"
done
