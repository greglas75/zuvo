# shellcheck shell=bash
# adversarial-lanes-http.sh — the HTTP review lanes: codestral, the OpenAI-compatible openrouter body
# (also serving the byteplus lanes) and kimi-api. Keys travel in a umask'd curl config file, never in
# argv; a short body that is an error notice is never a review; a lane with no usable key is `no-key`
# (lane_no_key), never a failure of the lane.
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Cut from the driver (afd4ed0d, byte for byte then). Linted as part of the whole program:
# tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on the driver with every module inlined.


# chat_payload <file> <model> [<temperature>] [<stream 1|0>] — the OpenAI-style chat request for REVIEW_PROMPT, written by
# jq into <file> (a file, never argv: a large prompt would hit ARG_MAX). One builder for the three HTTP lanes.
chat_payload() {
  local extra='{}'
  [[ "${4:-0}" != 1 ]] || extra='{"stream":true,"stream_options":{"include_usage":true}}'
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
# gateway page) passes through unchanged. A stream that is NOT whole — an event that does not parse, no
# `data: [DONE]` and no finish_reason, or an assembly that fails — is {"error":{stream_integrity:true,…}}, never
# a review with a hole in it.
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

  # BYTEPLUS BILLING GUARD. ModelArk serves the same key on two base URLs: /api/coding consumes
  # the prepaid Coding Plan, /api/v3 bills the account balance. The vendor's own doc says so:
  # "Requests sent to this Base URL do not consume your Coding Plan quota and will instead incur
  # additional charges." One wrong character in a base URL would therefore turn an included
  # review into a metered one, silently and per chunk. Refuse rather than bill.
  if [[ "${ZUVO_OPENROUTER_BASE_URL:-}" == *bytepluses.com* || "${ZUVO_OPENROUTER_BASE_URL:-}" == *volces.com* ]]; then
    # Compare the PATH, with the query and fragment cut off first. `*/api/coding` on the raw URL
    # matches anything merely ENDING in those characters, so
    #   https://ark.…/api/v3?from=/api/coding
    # satisfied the allow-list and would have been billed. A guard whose whole job is to keep
    # money off the wrong endpoint cannot be defeated by a query string.
    local _bp_path="${ZUVO_OPENROUTER_BASE_URL%%\?*}"
    _bp_path="${_bp_path%%#*}"
    _bp_path="${_bp_path%/}"
    case "$_bp_path" in
      */api/coding/v3|*/api/coding) ;;
      *) echo "  WARN: $_lane base URL '${ZUVO_OPENROUTER_BASE_URL}' is not the Coding Plan path (/api/coding/v3) — refusing, it would bill the account balance instead of the plan" >&2
         return 1 ;;
    esac
  fi

  # Model id is attacker-adjacent only via env, but checked anyway: ids are vendor/name[:tag]. Rejected
  # when malformed, never repaired (lane_model_ok). The router sets ZUVO_OPENROUTER_MODEL for the other
  # OpenRouter and BytePlus lanes; lane_model openrouter reads it first.
  local model
  model="$(lane_model openrouter)"
  lane_model_ok "$_lane" "$model" || return 1

  # Temp names carry the LANE and the MODEL. `openrouter` and `openrouter-alt` are two
  # providers in the SAME parallel dispatch, so one fixed name means each overwrites the other's
  # payload and curl config mid-flight — the request goes out with the wrong model while the
  # artifact still labels it correctly. Silent mislabeling is the exact failure this change set
  # exists to remove. The lane's slug, a '.' (which neither slug holds), the model's: no two lanes share a name.
  local slug
  slug="$(printf '%s' "$_lane" | LC_ALL=C tr -c 'a-zA-Z0-9-' '_').$(printf '%s' "$model" | LC_ALL=C tr -c 'a-zA-Z0-9' '_')"
  local payload_file="$JSON_TMPDIR/openrouter_${slug}_payload.json"
  # STREAMING (ZUVO_OR_STREAM=1, set by the byteplus lanes only): the Coding Plan closes a non-streaming
  # request after a minute without a byte, while a reasoning model on a real diff thinks for minutes.
  # OpenRouter keeps the non-streaming path its keep-alive comments hold open. Tied to the lane too: an
  # exported ZUVO_OR_STREAM=1 must not flip the OpenRouter lanes onto a path they were never measured on.
  local _or_stream=0
  [[ "${ZUVO_OR_STREAM:-0}" == "1" && "$_lane" == byteplus* ]] && _or_stream=1
  chat_payload "$payload_file" "$model" 0.2 "$_or_stream" || { echo "  WARN: $_lane: the request could not be built (jq failed)" >&2; return 1; }

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
