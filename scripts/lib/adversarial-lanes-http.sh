# shellcheck shell=bash
# adversarial-lanes-http.sh — the HTTP review lanes: codestral, the OpenAI-compatible openrouter body
# (also serving the byteplus lanes) and kimi-api. Keys travel in a umask'd curl config file, never in
# argv; a short body that is an error notice is never a review; a lane with no usable key is `no-key`
# (lane_no_key), never a failure of the lane.
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Cut from the driver (afd4ed0d, byte for byte then). Linted as part of the whole program:
# tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on the driver with every module inlined.


# chat_payload <file> <model> [<temperature>] [<stream 1|0>] [<extra JSON object>] — the OpenAI-style chat request for
# REVIEW_PROMPT, written by jq into <file> (a file, never argv: a large prompt would hit ARG_MAX). One builder for the
# three HTTP lanes; <extra> is merged in last (a vendor field such as Z.ai's `thinking`).
chat_payload() {
  local extra='{}'
  [[ "${4:-0}" != 1 ]] || extra='{"stream":true,"stream_options":{"include_usage":true}}'
  [[ -z "${5:-}" ]] || extra="$(jq -cn --argjson a "$extra" --argjson b "$5" '$a + $b')" || return 1
  if [[ -n "${3:-}" ]]; then
    printf '%s' "$REVIEW_PROMPT" | jq -Rs --arg m "$2" --argjson t "$3" --argjson x "$extra" \
      '{model:$m, messages:[{role:"user", content:.}], temperature:$t} + $x' > "$1"
  else
    printf '%s' "$REVIEW_PROMPT" | jq -Rs --arg m "$2" --argjson x "$extra" \
      '{model:$m, messages:[{role:"user", content:.}]} + $x' > "$1"
  fi
}

# chat_tokens <response> — "<prompt> in / <completion> out" from a chat response's usage ("?" when absent).
chat_tokens() {
  printf '%s in / %s out' "$(printf '%s' "$1" | jq -r '.usage.prompt_tokens // "?"' 2>/dev/null)" \
    "$(printf '%s' "$1" | jq -r '.usage.completion_tokens // "?"' 2>/dev/null)"
}

# OR_MIN_ATTEMPT_SECONDS — the least time left of PROVIDER_TIMEOUT worth another OpenRouter/BytePlus request;
# OR_ATTEMPTS — how many requests a transient failure (HTTP 429/5xx, a dropped connection) may take in all.
OR_MIN_ATTEMPT_SECONDS=15
OR_ATTEMPTS=3

# curl_auth_config <file> <lane> <key> [<header>...] — the request's headers as a curl config file (-K):
# never argv, where `-H "Bearer …"` is readable through ps by every process on the host. Owner-only FROM
# CREATION (umask 077 before the redirect): a chmod after the write leaves a window. A key with a quote, a
# backslash or a line break would end the config's quoted string and add a directive of its own: refused as
# no-key (lane_no_key: the configuration's fault, not the lane's), status 1.
curl_auth_config() {
  local file="$1" lane="$2" key="$3" h
  shift 3
  case "$key" in
    *['"\\'$'\n\r']*)
      lane_no_key "$lane" "its key contains a quote, backslash or line break — refusing to build a curl config"
      return 1 ;;
  esac
  ( umask 077
    { printf 'header = "Authorization: Bearer %s"\nheader = "Content-Type: application/json"\n' "$key"
      for h in "$@"; do printf 'header = "%s"\n' "$h"; done
    } > "$file" )
}

# lane_no_key <lane> <where the key would come from> — the lane has no usable API key: said, recorded as the
# outcome `no-key` (a marker the outcome recorder reads, as runner_ready's no-runner), status 1. Not a failure
# of the lane, which never ran: the provider-health ledger must not bench it, and the run must not read as
# "every provider was reached".
lane_no_key() {
  echo "  WARN: $1 has no usable API key ($2) — not run, and not held against the lane" >&2
  # The marker is named after the lane, and a name with a slash never becomes a path (the "nokey_" prefix keeps
  # any other name — codex-5.3's dot included — a plain file in the run's dir).
  if [[ -n "$1" && "$1" != */* && -n "${JSON_TMPDIR:-}" && -d "$JSON_TMPDIR" ]]; then
    : > "$JSON_TMPDIR/nokey_$1" 2>/dev/null || true
  fi
  return 1
}

# lane_not_run <lane> <reason> — a lane deliberately left out for a reason that is not the lane's fault (a
# prepaid plan out of quota, with no fallback): said, and recorded through lane_no_key's marker, so the outcome
# is `no-key` — "not run, not held against the lane" — and the health ledger never benches it. Status 1.
lane_not_run() {
  echo "  WARN: $1 not run — $2 — not held against the lane" >&2
  if [[ -n "$1" && "$1" != */* && -n "${JSON_TMPDIR:-}" && -d "$JSON_TMPDIR" ]]; then
    : > "$JSON_TMPDIR/nokey_$1" 2>/dev/null || true
  fi
  return 1
}

# A spent BytePlus plan (any of its quota windows) answers HTTP 429 AccountQuotaExceeded naming the reset. Asking
# again cannot help before it, so the reset is kept in a HOME-level file that every lane, chunk and run reads.

# byteplus_quota_file — where the reset is kept; status 1 (none) under the test harness unless a test names one,
# so no case writes the machine's ~/.zuvo.
byteplus_quota_file() {
  if [[ -n "${ZUVO_BYTEPLUS_QUOTA_FILE:-}" ]]; then printf '%s\n' "$ZUVO_BYTEPLUS_QUOTA_FILE"
  elif [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-0}" == "1" ]]; then return 1
  else printf '%s\n' "${ZUVO_HOME:-$HOME/.zuvo}/byteplus-quota-until"; fi
}

# byteplus_quota_until — the recorded reset epoch, status 0 while it is still ahead; status 1 when there is none,
# it has passed or the file holds anything but a number.
byteplus_quota_until() {
  local f until=""
  f="$(byteplus_quota_file)" || return 1
  [[ -f "$f" ]] || return 1
  { read -r until _ < "$f"; } 2>/dev/null || [[ -n "$until" ]] || return 1
  [[ "$until" =~ ^[0-9]{1,12}$ ]] || return 1
  (( until > $(date +%s) )) || return 1
  printf '%s\n' "$until"
}

# _ar_epoch_text <epoch> — "2026-10-22 15:59Z", for a WARN. GNU date first: BSD has no -d, and GNU's -r reads a file.
_ar_epoch_text() {
  date -u -d "@$1" '+%Y-%m-%d %H:%MZ' 2>/dev/null || date -u -r "$1" '+%Y-%m-%d %H:%MZ' 2>/dev/null || printf '%s\n' "$1"
}

# _byteplus_quota_error <body> — status 0 when the body is the plan's quota refusal.
_byteplus_quota_error() {
  printf '%s' "$1" | jq -e '(.error.code // "") | tostring | test("QuotaExceeded")' >/dev/null 2>&1
}

# _zai_plan_refusal <body> — status 0 when a 429 is the Z.ai plan refusing (spent window, no package, expired,
# model outside the plan, Fair Usage, wrong key type): a retry within the lane's budget cannot change those.
# 1302/1305 (rate limit, overload) stay retryable. Codes: https://docs.z.ai/api-reference/api-code
_zai_plan_refusal() {
  printf '%s' "$1" | jq -e '(.error.code // "") | tostring
    | test("^(1113|1308|1309|1310|1311|1313|1314|1315|1316|1317|1318|1319|1320|1321)$")' >/dev/null 2>&1
}

# _plan_endpoint <lane> <base-url> — the plan (byteplus | zai) a request spends; nothing off those API hosts. A plan
# host on any other path (BytePlus /api/v3, Z.ai /api/paas/v4: metered) WARNs, status 1. Host and path are parsed
# and compared whole, never as substrings (api.xyz.ai is not Z.ai; `/api/v3?from=/api/coding` was once allowed).
# A plan LANE fails closed: anything but https to its own vendor's API host is refused, so its key goes nowhere else.
_plan_endpoint() {
  local lane="$1" url="$2" rest host path="" plan="" want need=""
  case "$lane" in byteplus*) need=byteplus ;; zai) need=zai ;; esac
  case "$url" in *[[:space:][:cntrl:]]*)
    echo "  WARN: $lane base URL holds whitespace or a control character — refusing" >&2; return 1 ;;
  esac
  local port=""
  rest="${url#*://}"; host="${rest%%[/?#]*}"; host="${host##*@}"
  [[ "$host" == *:* ]] && port="${host#*:}"; host="${host%%:*}"
  host="$(printf '%s' "$host" | tr 'A-Z' 'a-z')"; host="${host%.}"
  [[ -z "$port" || "$port" == 443 ]] || host=""   # another port on the host is another service
  case "$host" in
    *[%\\]*) ;;
    ark.*.bytepluses.com|ark.*.volces.com) plan=byteplus want="/api/coding/v3" ;;
    api.z.ai|open.bigmodel.cn)             plan=zai want="/api/coding/paas/v4" ;;
  esac
  if [[ -n "$need" && ( "$plan" != "$need" || "$url" != https://* ) ]]; then
    echo "  WARN: $lane base URL '$url' is not https:// on the $need plan's host — refusing to send the plan key there" >&2
    return 1
  fi
  [[ -n "$plan" ]] || return 0
  rest="${rest%%[?#]*}"
  [[ "$rest" == */* ]] && path="/${rest#*/}"
  path="${path%/}"
  case "$plan:$path" in
    byteplus:/api/coding/v3|byteplus:/api/coding|zai:/api/coding/paas/v4)
      printf '%s\n' "$plan"; return 0 ;;
  esac
  echo "  WARN: $lane base URL '$url' is not the Coding Plan path ($want) — refusing, it would bill the account balance instead of the plan" >&2
  return 1
}

# _byteplus_reset_epoch <message> — the reset the message names ("reset at YYYY-MM-DD HH:MM:SS +ZZZZ"), as an
# epoch; now + 1 h when it names none, cannot be parsed, is past or is over 40 days ahead.
_byteplus_reset_epoch() {
  local now e="" ts re='reset at ([0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}) ([+-][0-9]{4})'
  now=$(date +%s)
  if [[ "$1" =~ $re ]]; then
    ts="${BASH_REMATCH[1]} ${BASH_REMATCH[2]}"
    e=$(date -d "$ts" +%s 2>/dev/null || date -j -f '%Y-%m-%d %H:%M:%S %z' "$ts" +%s 2>/dev/null) || e=""
  fi
  if [[ ! "$e" =~ ^[0-9]+$ ]] || (( e <= now || e > now + 40 * 86400 )); then e=$(( now + 3600 )); fi
  printf '%s\n' "$e"
}

# byteplus_quota_record <lane> <body> — the quota stop: the reset into the HOME file and into the run's marker
# bpquota_<lane>, which run_byteplus reads. Runs hit the stop at once, so the file is compared and replaced under
# a mkdir lock (a lock left by a killed run is waited out for ~2 s, then ignored) through a temp file and mv, and a
# later reset already on file is kept: a shorter window's answer must not cut a monthly stop short.
byteplus_quota_record() {
  local lane="$1" msg until f tmp="" held n=0 locked
  msg=$(printf '%s' "$2" | jq -r '.error.message // empty' 2>/dev/null) || msg=""
  until=$(_byteplus_reset_epoch "$msg")
  echo "  WARN: $lane: BytePlus Coding Plan quota exhausted until $(_ar_epoch_text "$until") — not retried" >&2
  if [[ "$lane" != */* && -n "${JSON_TMPDIR:-}" && -d "$JSON_TMPDIR" ]]; then
    printf '%s\n' "$until" > "$JSON_TMPDIR/bpquota_$lane" 2>/dev/null || true
  fi
  f="$(byteplus_quota_file)" || return 0
  mkdir -p -- "${f%/*}" 2>/dev/null || true
  until mkdir -- "$f.lock" 2>/dev/null; do
    (( ++n > 20 )) && break
    sleep 0.1
  done
  # Held past ~2 s means its holder died (the section below takes microseconds): taken over, so the rmdir
  # below clears it instead of leaving every later write to wait it out.
  locked=1
  if ! { held="$(byteplus_quota_until)" && (( held >= until )); }; then
    tmp="$f.$$.$RANDOM"
    if ! { printf '%s\t%s\n' "$until" "$lane" > "$tmp" && mv -f -- "$tmp" "$f"; } 2>/dev/null; then
      rm -f -- "$tmp" 2>/dev/null || true
      echo "  WARN: $lane: the quota stop could not be written to $f — later runs will ask the plan again" >&2
    fi
  fi
  (( locked == 0 )) || rmdir -- "$f.lock" 2>/dev/null || true
  return 0
}

# A `:free` OpenRouter model is rationed, not billed: its 429 is the ration spent, so the reset is kept in a HOME file
# (as for BytePlus, Alibaba, Muse) and the lane is not run until then, nor held against it.
openrouter_is_free() { [[ "$1" == *:free ]]; }
# _openrouter_free_quota_file — status 1 (none) under the test harness unless a test names one.
_openrouter_free_quota_file() {
  if [[ -n "${ZUVO_OPENROUTER_FREE_QUOTA_FILE:-}" ]]; then printf '%s\n' "$ZUVO_OPENROUTER_FREE_QUOTA_FILE"; return 0; fi
  [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-0}" == 1 ]] && return 1
  printf '%s\n' "${ZUVO_HOME:-$HOME/.zuvo}/openrouter-free-quota-until"
}
openrouter_free_quota_until() {   # prints the stop epoch while it is ahead; status 1 otherwise
  local f until=""
  f="$(_openrouter_free_quota_file)" || return 1
  [[ -f "$f" ]] || return 1
  { read -r until _ < "$f"; } 2>/dev/null || [[ -n "$until" ]] || return 1
  [[ "$until" =~ ^[1-9][0-9]{8,10}$ ]] && (( until > $(date +%s) )) || return 1
  printf '%s\n' "$until"
}
# _openrouter_free_reset_epoch <body> [<now>] — the reset the 429 names in error.metadata.headers X-RateLimit-Reset
# (epoch ms; seconds accepted). Without a usable one (missing, past, or over two days ahead): the next UTC midnight
# for the daily ration ("free-models-per-day"), else now + 5 min — an upstream throttle names no reset.
_openrouter_free_reset_epoch() {
  local now="${2:-$(date +%s)}" r e="" msg
  r=$(printf '%s' "$1" | jq -r '.error.metadata.headers["X-RateLimit-Reset"] // empty | tostring' 2>/dev/null) || r=""
  msg=$(printf '%s' "$1" | jq -r '.error.message // empty | tostring' 2>/dev/null) || msg=""
  [[ "$r" =~ ^[1-9][0-9]{9,12}$ ]] && e=$(( ${#r} > 10 ? r / 1000 : r ))
  if [[ -z "$e" ]] || (( e <= now || e > now + 2 * 86400 )); then
    if [[ "$msg" == *free-models-per-day* ]]; then e=$(( (now / 86400 + 1) * 86400 )); else e=$(( now + 300 )); fi
  fi
  printf '%s\n' "$e"
}
# openrouter_free_quota_record <lane> <body> — the reset into the HOME file, unless a later one is already there (a
# per-minute answer must not cut a daily stop short); compare and temp-file + mv under a mkdir lock, as
# alibaba_quota_record does. Prints the reset in force.
openrouter_free_quota_record() {
  local until f tmp held n=0
  until=$(_openrouter_free_reset_epoch "$2")
  f="$(_openrouter_free_quota_file)" || { printf '%s\n' "$until"; return 0; }
  mkdir -p -- "${f%/*}" 2>/dev/null || true
  # Held past ~2 s means its holder died (the section takes microseconds): taken over, and cleared below.
  until mkdir -- "$f.lock" 2>/dev/null; do
    (( ++n > 20 )) && break
    sleep 0.1
  done
  if held="$(openrouter_free_quota_until)" && (( held >= until )); then
    until="$held"
  else
    tmp="$f.$$.$RANDOM"
    if ! { printf '%s\t%s\n' "$until" "$1" > "$tmp" && mv -f -- "$tmp" "$f"; } 2>/dev/null; then
      rm -f -- "$tmp" 2>/dev/null || true
      echo "  WARN: $1: the quota stop could not be written to $f — later runs will ask OpenRouter again" >&2
    fi
  fi
  rmdir -- "$f.lock" 2>/dev/null || true
  printf '%s\n' "$until"
}

run_codestral() {
  # Codestral API — Mistral's coding model, OpenAI-compatible chat endpoint
  [[ -n "${CODESTRAL_API_KEY:-}" ]] || { lane_no_key codestral "CODESTRAL_API_KEY is not set"; return 1; }

  local model
  model="$(lane_model codestral)"
  lane_model_ok codestral "$model" || return 1

  # Build JSON payload via temp file (avoids ARG_MAX on large prompts)
  local payload_file="$JSON_TMPDIR/codestral_payload.json"
  chat_payload "$payload_file" "$model" || { echo "  WARN: codestral: the request could not be built (jq failed)" >&2; return 1; }

  local curl_cfg="$JSON_TMPDIR/codestral_curl.cfg"
  curl_auth_config "$curl_cfg" codestral "$CODESTRAL_API_KEY" || return 1

  local err_file="$JSON_TMPDIR/err_codestral.txt"
  local response
  local status=0
  response=$(curl -sf --max-time "$PROVIDER_TIMEOUT" \
    "https://codestral.mistral.ai/v1/chat/completions" \
    -K "$curl_cfg" \
    -d @"$payload_file" \
    2>"$err_file") || status=$?
  if [[ $status -ne 0 ]]; then
    lane_exit_warn codestral "$status" 28 "$err_file"
    [[ $status -eq 28 ]] && return 124
    return "$status"
  fi

  # Log token usage to stderr
  echo "  Codestral tokens: $(chat_tokens "$response")" >&2
  lane_usage_from_chat "$response"

  local text
  text=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty')
  [[ -z "$text" ]] && return 1
  printf '%s\n' "$text"
}

# openrouter_assemble_stream <body> [<lane>] — fold an OpenAI-compatible SSE body into the NON-streaming
# shape openrouter_review_text and the error guard already read:
#   {"choices":[{"message":{"content":"<all delta.content joined>"}}],"usage":{…last usage chunk…}}
# An `error` object in any event becomes {"error":…} (the caller's api_err path); reasoning_content is the
# model's scratchpad, not the review, and is dropped. A body that is not SSE at all (a non-2xx JSON error, a
# gateway page) passes through unchanged. A whole stream that carried no content yields content "", which the
# decoder reports as an empty answer. A stream that is NOT whole — an event that does not parse, no
# `data: [DONE]` and no finish_reason, or an assembly that fails — is {"error":{stream_integrity:true,…}}, never
# a review with a hole in it. Lines other than `data:` (SSE comments, `event:`, `id:`) carry nothing here.
openrouter_assemble_stream() {
  local body="$1" _lane="${2:-stream}"
  # Pure-bash test, never `printf | grep -q`: under pipefail grep's early exit kills printf with SIGPIPE and a
  # real stream reads as "not SSE". A BOM or blank lines before the first event must not hide it; they are
  # stripped from a 256-char head only, since a `%%[![:space:]]*` match over the whole body is quadratic.
  local _head="${body:0:256}" _skip
  _skip=${#_head}
  _head="${_head#$'\xef\xbb\xbf'}"
  _head="${_head#"${_head%%[![:space:]]*}"}"
  _skip=$(( _skip - ${#_head} ))
  if [[ "$_head" != data:* && "$body" != *$'\n'data:* ]]; then
    printf '%s' "$body"; return 0
  fi
  body="${body:_skip}"
  local _out
  if ! _out=$(printf '%s\n' "$body" | jq -Rn --arg lane "$_lane" '
    [inputs | select(startswith("data:")) | sub("^data: ?"; "")] as $raw
    | ($raw | map(select(test("^\\s*\\[DONE\\]\\s*$")))) as $done
    # Every event is wrapped, never tagged in place: a sentinel key inside the payload could collide
    # with a real one. Valid JSON that is not an object (null, 0, "x") is no event either.
    | ($raw | map(select(test("^\\s*\\[DONE\\]\\s*$") | not)
                 | (try {ev: fromjson} catch {bad: true})
                 | if .bad or (.ev | type) != "object" then {bad: true} else . end)) as $all
    | ($all | map(select(.bad)) | length) as $bad
    | ($all | map(select(.bad | not) | .ev)) as $ev
    | ($ev | map(select(.error != null)) | first) as $err
    | ($ev | any((.choices // [])[0].finish_reason | type == "string" and length > 0)) as $fin
    # stream_integrity marks a stream that broke in transit (retryable), unlike an error the
    # provider sent on purpose (quota, bad model), which asking again does not fix.
    | if $err != null then {error: $err.error}
      elif $bad > 0 then {error: {stream_integrity: true, message: "\($lane): \($bad) of \($all | length) stream event(s) did not parse — the review would be incomplete"}}
      elif ($done | length) == 0 and ($fin | not) then
        {error: {stream_integrity: true, message: "\($lane): the stream ended without [DONE] or a finish_reason — cut off mid-answer"}}
      else {choices: [{message: {content: ($ev
               | map((.choices // [])[0].delta.content // empty
                     | if type == "array" then (map(select(type == "object" and .type == "text") | .text) | join(""))
                       elif type == "string" then . else empty end)
               | join(""))}}],
            usage: ($ev | map(select(.usage != null) | .usage) | last)}
      end' 2>/dev/null) || [[ -z "$_out" ]]; then
    # A literal, not jq: this branch is reached exactly when jq could not run.
    echo "  WARN: $_lane: the stream body could not be assembled" >&2
    _out='{"error":{"stream_integrity":true,"message":"the stream body could not be assembled"}}'
  fi
  printf '%s' "$_out"
}

openrouter_review_text() {
  local response="$1" model="$2" _lane="$3"
  local reasoning_tokens
  # Reasoning tokens are the cost driver on this lane and are invisible in completion_tokens
  # on some models: glm-5.3 spends ~30k of them per review, which is 90% of its bill.
  reasoning_tokens=$(printf '%s' "$response" | jq -r '.usage.completion_tokens_details.reasoning_tokens // 0' 2>/dev/null)
  echo "  OpenRouter [$model] tokens: $(chat_tokens "$response") (${reasoning_tokens} reasoning)" >&2
  lane_usage_from_chat "$response"

  local text
  # content is a string for every model measured here, but the OpenAI-compatible schema also
  # allows an array of typed blocks and a router upgrade can flip a model to it. `jq -r` on an
  # array yields a serialized blob whose LENGTH then drives the <1000 heuristic below, so a parse
  # failure would read as either a skip or a review depending on size. Handle both shapes.
  text=$(printf '%s' "$response" | jq -r '
    .choices[0].message.content
    | if type == "array" then (map(select(.type == "text") | .text) | join(""))
      elif type == "string" then .
      else "" end' 2>/dev/null)
  # Same length-gated error-as-output guard as the other lanes: a short body that IS an error
  # must never be consumed as a clean review, while a long real review may legitimately quote
  # "rate limit" inside a finding.
  local verdict
  if verdict="$(lane_error_text openrouter "$text")"; then
    if [[ "$verdict" == short ]]; then
      echo "  WARN: $_lane returned empty/error content: $(printf '%s' "$response" | _ar_quote_line first - "$LANE_ERR_RESPONSE_QUOTE_CHARS")" >&2
    else
      echo "  WARN: $_lane returned error-prefixed content: $(printf '%s' "$text" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
    fi
    return 1
  fi
  printf '%s\n' "$text"
}

# openrouter_budget_ok <lane> <key> — 0 while the OpenRouter key's spend TODAY (UTC, the vendor's usage_daily) is under
# ZUVO_OPENROUTER_DAILY_USD (default 5; "off" lifts it). Over it, or when the spend cannot be read, the lane is not run
# (no-key: not held against it). Why a cap at all: on 2026-10-15 one lane (deepseek on OpenRouter) ran on ~1,700
# reviews and the key spent $91 that day — benchmark prices had put it at a tenth of a cent a review, while real diffs
# made the model think for ~60k output tokens a call. A per-call price is a guess; the day's spend is a fact.
# One GET to /api/v1/key, shared by every lane, chunk and run for ZUVO_OPENROUTER_USAGE_TTL seconds (default 120)
# through $ZUVO_HOME/openrouter-usage. Fails CLOSED: this is a money check. A soft cap: lanes already in flight when
# the day crosses it finish, so the overshoot is bounded by one round of calls, not a reservation. The test harness skips it unless the
# cap is set explicitly — its fake curls answer every URL with a review.
# _openrouter_daily_cap [warn] — the daily cap in USD on stdout; status 1 when there is none ("off", or the test
# harness without an explicit cap). Not a number → 5 (with a WARN when asked). One copy for the check and the draw.
_openrouter_daily_cap() {
  local cap="${ZUVO_OPENROUTER_DAILY_USD-5}"
  [[ "$cap" == off ]] && return 1
  [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-0}" == 1 && -z "${ZUVO_OPENROUTER_DAILY_USD+x}" ]] && return 1
  if [[ ! "$cap" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
    [[ "${1:-}" == warn ]] && echo "  WARN: ZUVO_OPENROUTER_DAILY_USD='$cap' is not a number — using 5" >&2
    cap=5
  fi
  printf '%s\n' "$cap"
}
_openrouter_usage_file() { printf '%s\n' "${ZUVO_OPENROUTER_USAGE_FILE:-${ZUVO_HOME:-$HOME/.zuvo}/openrouter-usage}"; }

openrouter_budget_ok() {
  local lane="$1" key="$2" cap f ttl now at="" used="" cfg body
  cap="$(_openrouter_daily_cap warn)" || return 0
  f="$(_openrouter_usage_file)"
  ttl="${ZUVO_OPENROUTER_USAGE_TTL:-120}"
  [[ "$ttl" =~ ^[0-9]{1,6}$ ]] || ttl=120
  now=$(date +%s)
  { read -r at used _ < "$f"; } 2>/dev/null || true
  # Stale: unreadable, older than the TTL, from the future (clock skew), or from another UTC day — usage_daily
  # restarts at UTC midnight, so yesterday's spend must not stop today's first reviews (nor today's be missed).
  if ! [[ "$at" =~ ^[0-9]{1,12}$ && "$used" =~ ^[0-9]+(\.[0-9]+)?$ ]] || (( now - at > ttl || at > now )) \
     || (( at / 86400 != now / 86400 )); then
    cfg="$JSON_TMPDIR/openrouter_budget_${lane//[^a-zA-Z0-9-]/_}.cfg"
    curl_auth_config "$cfg" "$lane" "$key" || return 1
    body=$(curl -sS --max-time 10 -K "$cfg" "${ZUVO_OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}/key" 2>/dev/null) || body=""
    used=$(printf '%s' "$body" | jq -r '.data.usage_daily | numbers' 2>/dev/null) || used=""
    if [[ ! "$used" =~ ^[0-9]+(\.[0-9]+)?([eE]-?[0-9]+)?$ ]]; then
      lane_no_key "$lane" "today's OpenRouter spend could not be read from /key — refusing to spend blind"
      return 1
    fi
    used=$(awk -v u="$used" 'BEGIN{printf "%.4f", u}')
    mkdir -p "$(dirname "$f")" 2>/dev/null
    printf '%s %s\n' "$now" "$used" > "$f.$$" 2>/dev/null && mv -f "$f.$$" "$f" 2>/dev/null || rm -f "$f.$$" 2>/dev/null
  fi
  if awk -v u="$used" -v c="$cap" 'BEGIN{exit !(u >= c)}'; then
    lane_no_key "$lane" "OpenRouter daily budget reached: \$$used spent today, cap \$$cap (ZUVO_OPENROUTER_DAILY_USD)"
    return 1
  fi
  return 0
}

# openrouter_budget_spent — status 0 (printing "<spent> <cap>") when the cached reading of today's OpenRouter spend
# already meets the cap: read from openrouter_budget_ok's cache only, no request. The TTL is deliberately ignored —
# usage_daily only grows within a UTC day, so a same-day reading at or over the cap stays true until midnight. For
# the fan-out (ar_skip_stopped_lanes): a lane that cannot spend is not drawn. Status 1 when unknown or under.
openrouter_budget_spent() {
  local cap f at="" used="" now
  cap="$(_openrouter_daily_cap)" || return 1
  f="$(_openrouter_usage_file)"
  { read -r at used _ < "$f"; } 2>/dev/null || true   # a last line without a newline still fills the fields
  [[ "$at" =~ ^[0-9]{1,12}$ && "$used" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  now=$(date +%s)
  (( at <= now && at / 86400 == now / 86400 )) || return 1
  awk -v u="$used" -v c="$cap" 'BEGIN{exit !(u >= c)}' || return 1
  printf '%s %s\n' "$used" "$cap"
}

run_openrouter() {
  # OpenRouter — OpenAI-compatible chat completions over HTTP. The ONLY paid lane in this
  # script that is not a vendor CLI, so it is the only way to reach models no CLI fronts.
  # Added 2026-09-01 on measurement: 20 real review diffs through every candidate, every
  # finding judged REAL / FALSE_POSITIVE by an independent Opus judge against the diff.
  # Model defaults and the rejected-candidate list live in model-registry.sh.
  #
  # Key resolution, in order: env, then the on-disk file. The file is the normal case here
  # (an interactive `op read` cannot run inside a headless review), and it is read ONLY if
  # it is not group/world readable — a benchmark key that lands in a shared checkout must
  # not be picked up silently.
  # Lane label + key file are overridable so a second OpenAI-compatible vendor can reuse this
  # whole hardened body (retry policy, umask'd curl config, model-id validation) instead of
  # growing a near-copy that will drift. Defaults are exactly the previous behaviour.
  local _lane="${ZUVO_OR_LANE_LABEL:-openrouter}"
  local key="${OPENROUTER_API_KEY:-}" why=""
  if [[ -z "$key" ]]; then
    local kf="${ZUVO_OR_KEY_FILE:-$HOME/.zuvo/openrouter.key}"
    if [[ -f "$kf" ]]; then
      # GNU FIRST, and the order is the whole point. On Linux `stat -f` means "filesystem
      # status": it SUCCEEDS on a regular file and prints a multi-line ext2/ext3 report, so the
      # `||` never reached the GNU form and $mode held that blob instead of an octal number.
      # The comparison then failed for a correctly-private key and the lane refused to read it —
      # on every Linux host (farm, CI runners), silently, while the Mac was fine because there
      # `stat -f` is the format flag. BSD has no `-c`, so probing GNU first works on both.
      # Mode is normalised to its last three digits: GNU prints 600, some stats print 0600.
      local mode
      mode=$(stat -c '%a' "$kf" 2>/dev/null || stat -f '%OLp' "$kf" 2>/dev/null)
      mode="${mode##*[!0-9]}"
      [[ "${#mode}" -gt 3 ]] && mode="${mode: -3}"
      if [[ "$mode" == "600" || "$mode" == "400" ]]; then
        key=$(<"$kf")
        [[ -n "$key" ]] || why="$kf is empty"
      else
        why="$kf is mode ${mode:-?} — refusing to read a non-private key file"
      fi
    else
      why="no key in the environment and no key file $kf"
    fi
  fi
  # No key is a SKIP, not a failure: this lane is opt-in. lane_no_key says why in ONE line (the driver relays a
  # failed lane's last WARN) and records `no-key`, which the health ledger does not hold against the lane.
  [[ -n "$key" ]] || { lane_no_key "$_lane" "${why:-no key}"; return 1; }
  case "$key" in
    *['"\\'$'\n\r']*)
      lane_no_key "$_lane" "its key contains a quote, backslash or line break — refusing to build a curl config"
      return 1 ;;
  esac

  # Billing guard: one wrong character in a plan's base URL would meter every chunk in silence. Refuse instead.
  # _plan = the plan this request spends (byteplus | zai), empty off any plan.
  local _plan
  _plan="$(_plan_endpoint "$_lane" "${ZUVO_OPENROUTER_BASE_URL:-}")" || return 1

  # Model id is attacker-adjacent only via env, but checked anyway: ids are vendor/name[:tag]. Rejected
  # when malformed, never repaired (lane_model_ok). The router sets ZUVO_OPENROUTER_MODEL for the other
  # OpenRouter and BytePlus lanes; lane_model openrouter reads it first.
  local model
  model="$(lane_model openrouter)"
  lane_model_ok "$_lane" "$model" || return 1

  # Every metered OpenRouter call answers to the day's budget. A plan call (BytePlus, Z.ai) is prepaid and a
  # `:free` model costs nothing: neither does — the free one answers to its quota stop instead.
  local _free=0 _until
  [[ -z "$_plan" ]] && openrouter_is_free "$model" && _free=1
  if (( _free )); then
    if _until="$(openrouter_free_quota_until)"; then
      lane_not_run "$_lane" "OpenRouter free-model quota spent until $(_ar_epoch_text "$_until")"
      return 1
    fi
  elif [[ -z "$_plan" ]]; then
    openrouter_budget_ok "$_lane" "$key" || return 1
  fi

  # Temp names carry the LANE and the MODEL. `openrouter` and `openrouter-alt` are two
  # providers in the SAME parallel dispatch, so one fixed name means each overwrites the other's
  # payload and curl config mid-flight — the request goes out with the wrong model while the
  # artifact still labels it correctly. Silent mislabeling is the exact failure this change set
  # exists to remove. The lane's slug, a '.' (which neither slug holds), the model's: no two lanes share a name.
  local slug
  slug="$(printf '%s' "$_lane" | LC_ALL=C tr -c 'a-zA-Z0-9-' '_').$(printf '%s' "$model" | LC_ALL=C tr -c 'a-zA-Z0-9' '_')"
  local payload_file="$JSON_TMPDIR/openrouter_${slug}_payload.json"
  # STREAMING (byteplus and zai lanes only): a plan drops a request silent for a minute while a model reasons
  # for several. Lane-tied so an exported ZUVO_OR_STREAM=1 leaves OpenRouter on its measured non-stream path.
  local _or_stream=0
  [[ "${ZUVO_OR_STREAM:-0}" == "1" && ( "$_lane" == byteplus* || "$_lane" == zai ) ]] && _or_stream=1
  # Z.ai: reasoning_effort LOW by default (ZUVO_ZAI_REASONING=low|medium|high, or off = thinking disabled). Measured
  # 2026-10-18 on the plan, glm-5.3-flash, one 3k-char diff: default reasoning 158 s (8,000 reasoning chunks to 480
  # of content) — on real review prompts every 300 s lane budget ran out, four timeouts in a row benched the lane
  # for 6 h; thinking off 11 s with no reasoning at all; effort low 11 s with ~190 reasoning chunks kept. A token
  # budget (thinking.budget_tokens) is ignored by the API (106 s).
  local _or_extra=""
  if [[ "$_lane" == zai ]]; then
    # ZUVO_ZAI_THINKING (v1.6.91, on/off) still counts when the new name is unset: off → off, on → high.
    local _zr="${ZUVO_ZAI_REASONING:-}"
    if [[ -z "$_zr" && -n "${ZUVO_ZAI_THINKING:-}" ]]; then
      case "$(printf '%s' "$ZUVO_ZAI_THINKING" | tr 'A-Z' 'a-z')" in enabled|on|1|true) _zr=high ;; *) _zr=off ;; esac
    fi
    _zr="$(printf '%s' "${_zr:-low}" | tr 'A-Z' 'a-z')"
    case "$_zr" in
      low|medium|high) _or_extra="{\"reasoning_effort\":\"$_zr\"}" ;;
      off|disabled|0|false|no) _or_extra='{"thinking":{"type":"disabled"}}' ;;
      *) echo "  WARN: ZUVO_ZAI_REASONING='$_zr' is not low/medium/high/off — using low" >&2
         _or_extra='{"reasoning_effort":"low"}' ;;
    esac
  fi
  chat_payload "$payload_file" "$model" 0.2 "$_or_stream" "$_or_extra" || { echo "  WARN: $_lane: the request could not be built (jq failed)" >&2; return 1; }

  local curl_cfg="$JSON_TMPDIR/openrouter_${slug}_curl.cfg"
  curl_auth_config "$curl_cfg" "$_lane" "$key" "X-Title: zuvo-adversarial-review" || return 1

  local err_file="$JSON_TMPDIR/err_openrouter_${slug}.txt"
  local response status=0
  # RETRY on transient failures only. A single 429 used to kill this lane for the whole run,
  # and on a host where the CLI reviewers fail at the ACCOUNT level (codex tier, gemini
  # IneligibleTier) the OpenRouter lanes are the only reviewers there are — so one throttled
  # request collapses a cross-model review to a single model. It reports honestly as
  # status=partial, which is exactly why nobody notices. The benchmark harness retried and
  # measured gpt-oss-120b at 20/20; production did not and the same model looked flaky.
  #
  # Retries live INSIDE the existing per-provider budget, never on top of it: each attempt gets
  # what is left of PROVIDER_TIMEOUT, and the loop stops when too little remains to be worth a
  # request. Extending the budget here would silently break the whole-run deadline, which is
  # derived from PROVIDER_TIMEOUT, and the outer `timeout` wrappers that sit above it.
  local _or_deadline=$(( $(date +%s) + PROVIDER_TIMEOUT ))
  local _or_try=0 _or_left http_code api_err
  while : ; do
    _or_try=$(( _or_try + 1 ))
    _or_left=$(( _or_deadline - $(date +%s) ))
    if [[ $_or_left -lt $OR_MIN_ATTEMPT_SECONDS ]]; then
      echo "  WARN: $_lane out of time budget after $((_or_try - 1)) attempt(s)" >&2
      return 124
    fi
    status=0
    # No -f: it would discard HTTP>=400 bodies, which is exactly where the {"error":...}
    # diagnostics live (401 bad key, 402 out of credit, 429 throttled).
    # -S: with -s alone curl writes nothing on failure, and a stream reset reads like a model that said nothing.
    response=$(curl -sS --max-time "$_or_left" -w '\n%{http_code}' \
      "${ZUVO_OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}/chat/completions" \
      -K "$curl_cfg" -d @"$payload_file" 2>"$err_file") || status=$?
    http_code="${response##*$'\n'}"; response="${response%$'\n'*}"
    # Only a 2xx body is a stream to fold; a 429/5xx keeps its raw bytes for the retry and the failure quote.
    if [[ $status -eq 0 && $_or_stream -eq 1 && "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      response=$(openrouter_assemble_stream "$response" "$_lane")
    fi
    api_err=""
    # .message is the OpenAI shape; some gateways send only a code, or a bare string
    [[ $status -eq 0 ]] && api_err=$(printf '%s' "$response" | jq -r '.error | if . == null then empty
      elif type == "object" then (.message // .code // tostring) else tostring end' 2>/dev/null)

    # A spent BytePlus plan is a 429 too, but asking again cannot help until its reset: recorded, never retried.
    # Keyed on the endpoint, not the lane label, which a stand-in on another endpoint keeps.
    if [[ "$_plan" == byteplus && "$http_code" == 429 ]] && _byteplus_quota_error "$response"; then
      byteplus_quota_record "$_lane" "$response"
      return 1
    fi
    # A free model's 429 is its ration spent (per minute, per day, or upstream): recorded, never retried.
    if (( _free )) && [[ "$http_code" == 429 ]]; then
      _until="$(openrouter_free_quota_record "$_lane" "$response")"
      lane_not_run "$_lane" "OpenRouter free-model quota spent until $(_ar_epoch_text "$_until") (HTTP 429: $(printf '%s' "$api_err" | _ar_quote_line first - "$LANE_ERR_RESPONSE_QUOTE_CHARS"))"
      return 1
    fi
    # No stop file for Z.ai: no fallback reads one, and a chunk's one refused request costs nothing.
    if [[ "$_plan" == zai && "$http_code" == 429 ]] && _zai_plan_refusal "$response"; then
      echo "  WARN: $_lane: Z.ai GLM Coding Plan refused (code $(printf '%s' "$response" | jq -r '.error.code' 2>/dev/null)): $(printf '%s' "$api_err" | _ar_quote_line first - "$LANE_ERR_RESPONSE_QUOTE_CHARS") — not retried" >&2
      return 1
    fi

    # Transient: throttling, provider-side 5xx, and the curl codes for a connection that died
    # mid-flight (52 empty reply, 56 recv error, 35 TLS, 16 HTTP/2 stream reset, 18 partial body, 92 HTTP/2
    # stream not closed cleanly). Everything else is a real answer or a real refusal — 401/402/404 do not
    # improve by asking again and must fail fast.
    local _transient=0
    case "$http_code" in 429|5??) _transient=1 ;; esac
    case "$status" in 52|56|35|16|18|92) _transient=1 ;; esac
    # A 2xx stream that arrived broken (cut off, a torn event, an assembly failure) is a dropped connection
    # curl did not notice: asked again within the budget.
    if [[ $_or_stream -eq 1 && -n "$api_err" ]] \
       && printf '%s' "$response" | jq -e '.error.stream_integrity == true' >/dev/null 2>&1; then
      _transient=1
    fi
    if [[ $_transient -eq 1 && $_or_try -lt $OR_ATTEMPTS ]]; then
      echo "  NOTE: $_lane [$model] transient (HTTP ${http_code:-?}, curl $status) — retry $_or_try/$(( OR_ATTEMPTS - 1 ))" >&2
      sleep $(( _or_try * 3 ))
      continue
    fi

    if [[ $status -ne 0 ]]; then
      lane_exit_warn "$_lane" "$status" 28 "$err_file"
      [[ $status -eq 28 ]] && return 124
      return "$status"
    fi
    if [[ -n "$api_err" ]]; then
      echo "  WARN: $_lane returned error: $(printf '%s' "$api_err" | _ar_quote_line first - "$LANE_ERR_RESPONSE_QUOTE_CHARS")" >&2
      return 1
    fi
    # Any non-2xx that reached here is a failure even without an OpenAI-style .error.message: a
    # gateway 502/503 HTML page after the retries, or a 4xx with an empty or foreign body, used
    # to fall through to `break` and be read as a successful provider answer.
    if [[ ! "$http_code" =~ ^2[0-9][0-9]$ ]]; then
      # Upstream bytes are untrusted. Take a bounded slice first (no pipe over a large body),
      # then keep printable ASCII only: a denylist of control bytes let C1 controls (0x80-0x9F,
      # also UTF-8-encoded as C2 80-9F), bidi overrides and U+2028/2029 through, which can still
      # drive a terminal or forge a log line. Every other byte becomes '?', so a diagnostic loses
      # accents but cannot carry an escape sequence.
      local _or_body="${response:0:$LANE_ERR_RESPONSE_QUOTE_CHARS}"
      printf '  WARN: %s HTTP %s: %s\n' "$_lane" "${http_code:-?}" "$(printf '%s' "$_or_body" | LC_ALL=C tr -c '[:print:]' '?')" >&2
      return 1
    fi
    break
  done

  openrouter_review_text "$response" "$model" "$_lane"
}

run_kimi_api() {
  # Moonshot Kimi — OpenAI-compatible chat completions via curl, 2-5s, no CLI overhead.
  # Distinct vendor (Moonshot) + distinct model family (K2) = real cross-model diversity.
  [[ -n "${MOONSHOT_API_KEY:-}" ]] || { lane_no_key kimi-api "MOONSHOT_API_KEY is not set"; return 1; }

  # The id goes into the request as it is or the lane refuses (lane_model_ok); jq builds the JSON.
  local model
  model="$(lane_model kimi-api)"
  lane_model_ok kimi-api "$model" || return 1

  # Build JSON payload via temp file (avoids ARG_MAX on large prompts)
  local payload_file="$JSON_TMPDIR/kimi_api_payload.json"
  chat_payload "$payload_file" "$model" 0.2 || { echo "  WARN: kimi-api: the request could not be built (jq failed)" >&2; return 1; }

  # R-14: pass the Authorization header via a curl config file, not argv — `-H "Bearer …"`
  # is visible to every process on the host via `ps` for the request's lifetime.
  local curl_cfg="$JSON_TMPDIR/kimi_api_curl.cfg"
  curl_auth_config "$curl_cfg" kimi-api "$MOONSHOT_API_KEY" || return 1

  local err_file="$JSON_TMPDIR/err_kimi-api.txt"
  local response
  local status=0
  # No -f (R-6): -f discards HTTP>=400 bodies, which made the {"error":...} guard below
  # dead code exactly when it matters (401/429 diagnostics).
  response=$(curl -s --max-time "$PROVIDER_TIMEOUT" \
    "${ZUVO_KIMI_BASE_URL:-https://api.moonshot.ai/v1}/chat/completions" \
    -K "$curl_cfg" \
    -d @"$payload_file" \
    2>"$err_file") || status=$?
  if [[ $status -ne 0 ]]; then
    lane_exit_warn kimi-api "$status" 28 "$err_file"
    [[ $status -eq 28 ]] && return 124
    return "$status"
  fi

  # Error-as-output guard (agy lesson 2026-07-17: an exit-0 body carrying an error
  # message was consumed as a CLEAN review). API errors come as {"error":{...}}.
  local api_err
  api_err=$(printf '%s' "$response" | jq -r '.error.message // empty' 2>/dev/null)
  if [[ -n "$api_err" ]]; then
    echo "  WARN: kimi-api returned error: $(printf '%s' "$api_err" | _ar_quote_line first - "$LANE_ERR_RESPONSE_QUOTE_CHARS")" >&2
    return 1
  fi

  # Log token usage to stderr
  echo "  Kimi API tokens: $(chat_tokens "$response")" >&2
  lane_usage_from_chat "$response"

  local text
  text=$(printf '%s' "$response" | jq -r '.choices[0].message.content // empty' 2>/dev/null)
  # R-16: same error-as-output guard as the CLI lane — an HTTP-200 body whose CONTENT is
  # an error/quota message must not pass as a clean review; empty text gets a WARN.
  # Length-gated like run_kimi: short body = full scan; long body = real review that may
  # quote "rate limit" in findings, only an error: prefix rejects it.
  local verdict
  if verdict="$(lane_error_text kimi "$text")"; then
    if [[ "$verdict" == short ]]; then
      echo "  WARN: kimi-api returned empty/error content: $(printf '%s' "$response" | _ar_quote_line first - "$LANE_ERR_RESPONSE_QUOTE_CHARS")" >&2
    else
      echo "  WARN: kimi-api returned error-prefixed content: $(printf '%s' "$text" | _ar_quote_line first - "$LANE_ERR_QUOTE_CHARS")" >&2
    fi
    return 1
  fi
  printf '%s\n' "$text"
}
