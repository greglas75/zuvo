# shellcheck shell=bash
# adversarial-dispatch.sh — running the lanes: the error-as-output guard every lane shares, the lane
# router (dispatch_provider, mock lanes for the test harness), auth-stub detection, the outcome
# bookkeeping (ok/timeout/auth/quota/empty/unverified/no-runner) and the dispatch itself — parallel
# (multi) or first-success (single).
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phase: ar_dispatch_lanes. Functions: lane_error_text, run_mock, dispatch_provider,
# _dispatch_provider_inner, is_auth_failure_output, exclude_auth_stub, lane_ok,
# record_provider_failure_outcome.
#
# Phase bodies sit at column 0, byte for byte the top-level code they were cut from:
# indenting them would change the multi-line prompt strings and heredocs several carry, and would
# make the move unprovable by diff. Each runs once, from the driver's Main, at the point it used to.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ─── Error-as-output guard (one copy for every lane that reads an exit-0 body) ───
# LANE_ERR_SCAN_CHARS — below it, a body short enough that an error/quota phrase anywhere in it means the
# body IS that notice; at or above it, a real review that may QUOTE the phrase in a finding, so only an
# `error:` prefix refuses it. Real provider error bodies are short, reviews are long. Named once (CQ12):
# it used to be the literal 1000 in four lanes. LANE_ERR_QUOTE_CHARS / LANE_ERR_RESPONSE_QUOTE_CHARS: how
# much of the refused text / raw API response the WARN line quotes.
LANE_ERR_SCAN_CHARS=1000
LANE_ERR_QUOTE_CHARS=120
LANE_ERR_RESPONSE_QUOTE_CHARS=160
# LANE_MIN_RETRY_SECONDS — the least time worth a lane's second call (a fallback model, a retry, kimi's
# API lane): every call after the first gets only what is left of the lane's PROVIDER_TIMEOUT
# (_ar_lane_budget), and under this a model does not answer a review — the call would only spend the rest.
# A lane whose whole timeout is short uses half of it instead.
LANE_MIN_RETRY_SECONDS=30
# AUTH_STUB_MAX_BYTES — the longest output that can be an auth stub rather than a review (the shared
# runner's guard is the same size). KILL_ROUNDING_SLACK_SECONDS — how far short of PROVIDER_TIMEOUT a
# hard-killed lane (137) may measure and still count as a timeout: whole-second clocks round.
AUTH_STUB_MAX_BYTES=600
KILL_ROUNDING_SLACK_SECONDS=2

# lane_error_text <set> <text> — status 0 when <text> is NOT a review (the agy lesson: a body that is a
# quota/auth/error notice must never travel on as a clean review with zero findings), with the reason on
# stdout: `short` (a body under LANE_ERR_SCAN_CHARS that is empty or matches the set) or `prefix` (a longer
# body that starts with `error:`). Status 1: a review. Each set is one lane's rule, unchanged from the
# per-lane copy it replaces — tests/adversarial/test-lane-error-text.sh pins every verdict:
#   kimi        kimi CLI and kimi-api. Short: empty, `error:` first, quota reached, rate limit, login
#               required, not authenticated. Long: an `error:` prefix. Case-insensitive.
#   openrouter  Short: empty, `error:` first, quota, rate limit, insufficient credits, not authenticated.
#               Long: an `error:` prefix. Case-insensitive.
#   qwen        Short: quota, rate limit, arrearage, invalid api key, invalidapikey, unauthorized. No long
#               rule. Case-insensitive. (An empty body never gets here: the lane refuses it first.)
#   muse        No length gate. Permission profile … unavailable, not logged in, muse login, quota,
#               rate limit, Unauthorized — case-SENSITIVE, anywhere in the body.
lane_error_text() {
  local set="$1" text="$2" lc
  if [[ "$set" == muse ]]; then
    case "$text" in
      *"Permission profile"*"unavailable"*|*"not logged in"*|*"muse login"*|*"quota"*|*"rate limit"*|*"Unauthorized"*)
        echo short; return 0 ;;
    esac
    return 1
  fi
  lc=$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]')
  if [[ ${#text} -lt $LANE_ERR_SCAN_CHARS ]]; then
    case "$set:$lc" in
      kimi:|kimi:error:*|kimi:*"quota reached"*|kimi:*"rate limit"*|kimi:*"login required"*|kimi:*"not authenticated"*)
        echo short; return 0 ;;
      openrouter:|openrouter:error:*|openrouter:*"quota"*|openrouter:*"rate limit"*|openrouter:*"insufficient credits"*|openrouter:*"not authenticated"*)
        echo short; return 0 ;;
      qwen:*"quota"*|qwen:*"rate limit"*|qwen:*"arrearage"*|qwen:*"invalid api key"*|qwen:*"invalidapikey"*|qwen:*"unauthorized"*)
        echo short; return 0 ;;
    esac
    return 1
  fi
  case "$set:$lc" in
    kimi:error:*|openrouter:error:*) echo prefix; return 0 ;;
  esac
  return 1
}

# ─── Unified dispatch ──────────────────────────────────────────


run_mock() {
  # Test-only: invoke a mock-* provider on PATH directly. The provider name IS the
  # binary name. Same two-variable guard as detect_providers — refuses to dispatch
  # mock-* unless ZUVO_ADVERSARIAL_TEST_HARNESS=1 is explicitly set, even if the
  # provider name made it into the candidate list somehow.
  if [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-}" != "1" ]]; then
    echo "[mock dispatch] refused: ZUVO_ADVERSARIAL_TEST_HARNESS not set" >&2
    return 2
  fi
  local mock_bin="$1"
  if ! command -v "$mock_bin" &>/dev/null; then
    echo "[mock dispatch] $mock_bin not found on PATH" >&2
    return 2
  fi
  printf '%s' "$REVIEW_PROMPT" | timeout $TIMEOUT_KILL_FLAG "${PROVIDER_TIMEOUT:-240}" "$mock_bin"
}

dispatch_provider() {
  local provider="$1" status=0 d_start d_elapsed
  d_start=$(date +%s)
  _dispatch_provider_inner "$provider" || status=$?
  d_elapsed=$(( $(date +%s) - d_start ))
  # `timeout` reports 124 only when SIGTERM alone ended the command. When the hard kill has to
  # escalate it exits 137 (128+SIGKILL) instead — and that is precisely the case the hard kill
  # was added for, so leaving 137 unmapped would file every TERM-ignoring provider under
  # "failed or returned empty" and lose the timeout signal the callers branch on.
  #
  # But 137 is also what an OOM killer, a container memory limit or an operator's `kill -9`
  # produces, and those die EARLY — reporting them as "every provider exceeded ${PROVIDER_TIMEOUT}s"
  # sends the reader after a slowness problem that isn't there. So only remap when the budget was
  # actually consumed; an early SIGKILL stays a plain failure and keeps its own exit code.
  #
  # The comparison carries 2s of slack because `date +%s` is whole-second and truncating: the
  # hard kill actually lands at PROVIDER_TIMEOUT + grace, so a genuine timeout-kill can measure
  # one second SHORT of the budget purely from rounding. Erring the other way would throw away
  # the timeout signal this remap exists to preserve.
  if [[ "$status" -eq 137 ]]; then
    if [[ "$d_elapsed" -ge $(( PROVIDER_TIMEOUT > KILL_ROUNDING_SLACK_SECONDS ? PROVIDER_TIMEOUT - KILL_ROUNDING_SLACK_SECONDS : PROVIDER_TIMEOUT )) ]]; then
      status=124
    else
      echo "  WARN: $provider was SIGKILLed after ${d_elapsed}s, well inside its ${PROVIDER_TIMEOUT}s budget — not a timeout (OOM kill / external kill?)" >&2
    fi
  fi
  return "$status"
}

# run_byteplus <lane> <model> — a BytePlus ModelArk Coding Plan lane: the OpenRouter client pointed at the
# plan's endpoint, with the plan's own key (never OPENROUTER_API_KEY) and the lane's label in its notes.
run_byteplus() {
  ZUVO_OR_LANE_LABEL="$1" ZUVO_OR_KEY_FILE="${ZUVO_BYTEPLUS_KEY_FILE:-$HOME/.zuvo/byteplus.key}" \
    OPENROUTER_API_KEY="" ZUVO_OPENROUTER_BASE_URL="${ZUVO_BYTEPLUS_BASE_URL:-https://ark.ap-southeast.bytepluses.com/api/coding/v3}" \
    ZUVO_OPENROUTER_MODEL="$2" run_openrouter
}

_dispatch_provider_inner() {
  local provider="$1"
  case "$provider" in
    mock-*)        run_mock "$provider" ;;
    codex-5.4)     run_codex_54 ;;
    codex-5.3)     run_codex_53 ;;
    cursor-agent)  run_cursor_agent ;;
    agy)           run_agy ;;
    openrouter)    run_openrouter ;;
    # Second OpenRouter model as its own provider id, not a flag: the run log, the artifact
    # and the exclusion logic all key on the provider NAME, so two models sharing one id
    # would be indistinguishable afterwards — which is exactly the mistake this whole
    # measurement exercise had to unpick (a provider label that was not the model).
    openrouter-alt) ZUVO_OPENROUTER_MODEL="${ZUVO_MODEL_OPENROUTER_ALT:-deepseek/deepseek-v4-flash-vision-exp}" run_openrouter ;;
    openrouter-3) ZUVO_OPENROUTER_MODEL="${ZUVO_MODEL_OPENROUTER_3:-inception/mercury-2.5-preview}" run_openrouter ;;
    openrouter-4) ZUVO_OPENROUTER_MODEL="${ZUVO_MODEL_OPENROUTER_4:-openai/gpt-oss-120b}" run_openrouter ;;
    byteplus)     run_byteplus byteplus "${ZUVO_MODEL_BYTEPLUS:-glm-5.3-flash}" ;;
    byteplus-alt) run_byteplus byteplus-alt "${ZUVO_MODEL_BYTEPLUS_ALT:-deepseek-v4-flash}" ;;
    byteplus-3)   run_byteplus byteplus-3 "${ZUVO_MODEL_BYTEPLUS_3:-dola-seed-2.0-code}" ;;
    claude)        run_claude ;;
    kimi)          run_kimi ;;        # auto when kimi CLI on PATH (OAuth, K3)
    kimi-api)      run_kimi_api ;;    # fallback when MOONSHOT_API_KEY set, no CLI
    muse)          run_muse ;;
    qwen)          run_qwen ;;
    codestral)     run_codestral ;;
    *) return 1 ;;
  esac
}

# ─── Auth-error output is NOT a review ───
# A provider CLI can exit 0 while printing only an auth error (claude: "Not logged in · Please run
# /login"; codex/kimi: login_required). Counted as a review it made "(4 total)" out of 3 reviewers,
# and in SINGLE mode the loop stopped on it (field, 2026-07-20: a nested claude without credentials).
# Guarded by length — a REAL review that discusses login code is kept — so only a payload <= 600 B
# can be a stub: zms_is_auth_stub (file or string, the token list). Without the runner there is no
# token list, so this fails CLOSED: ANY non-empty output within the guard (BYTES, a string's too —
# LC_ALL=C), or a file whose size cannot be read, qualifies. Failing open let a stub pass as a review.
is_auth_failure_output() {
  if [[ -n "$ZMS_LOADED" ]]; then zms_is_auth_stub "$1"; return; fi
  local LC_ALL=C; local bytes=${#1}
  if [[ -f "$1" ]]; then bytes=$(wc -c 2>/dev/null < "$1") || return 0; fi
  (( bytes > 0 && bytes <= AUTH_STUB_MAX_BYTES ))
}
# exclude_auth_stub <lane> <then> — records a lane is_auth_failure_output flagged; its output is never a
# review. With the runner that is a real verdict: `auth`, cached for the run, benched by the ledger.
# Without it only the length guard spoke: `unverified` — neither cached nor benched, or a broken
# install would bench a healthy lane in the PERSISTENT ledger long after it is fixed.
# _ar_auth_cached_lanes — the lanes the run's auth-failure cache still excludes, one per line: entries
# younger than ZUVO_AUTH_CACHE_TTL (default 21600 s = 6 h, the health ledger's full cooldown). An entry is
# "<lane><TAB><epoch>"; a line with no time is from before entries carried one and counts as expired —
# without a ZUVO_RUN_ID nothing ever expired those, so one failed login kept a lane out of every later
# review of the repository until the temp dir was cleared.
_ar_auth_cached_lanes() {
  [[ -s "$PROVIDER_FAIL_CACHE" ]] || return 0
  awk -F'\t' -v now="$(date +%s)" -v ttl="$(ar_env_int ZUVO_AUTH_CACHE_TTL 21600)" \
    'NF >= 2 && $2 ~ /^[0-9]+$/ && now - $2 < ttl { print $1 }' "$PROVIDER_FAIL_CACHE" 2>/dev/null | sort -u
}

exclude_auth_stub() {
  local kind=unverified
  if [[ -n "$ZMS_LOADED" ]]; then
    kind=auth; echo "  WARN: $1 not authenticated (auth error, no review) — $2" >&2
    _ar_auth_cached_lanes | grep -qxF -e "$1" 2>/dev/null || printf '%s\t%s\n' "$1" "$(date +%s)" >> "$PROVIDER_FAIL_CACHE"
  else echo "  WARN: $1: short output (≤600 B) not counted, unverified — the shared runner is missing, so it cannot be checked for an auth error — $2" >&2; fi
  PROVIDER_OUTCOMES="${PROVIDER_OUTCOMES:+$PROVIDER_OUTCOMES,}$1:$kind"
}
# lane_ok <lane> — its answer counts as a review: outcome `ok` AND a result file (an excluded stub never).
lane_ok() { [[ ",$PROVIDER_OUTCOMES," == *",$1:ok,"* && -s "$JSON_TMPDIR/result_$1.txt" ]]; }

# Preserve parallel duplicate timeouts; dedupe other failures already recorded for a lane.
record_provider_failure_outcome() {
  local lane="$1" status="$2" dispatch_mode="$3" outcome
  if [[ "$status" -ne 124 || "$dispatch_mode" != "parallel" ]]; then
    case ",$PROVIDER_OUTCOMES," in *",${lane}:"*) return 0 ;; esac
  fi
  if [[ "$status" -eq 124 ]]; then
    outcome=timeout
  elif [[ -e "$JSON_TMPDIR/norunner_${lane}" ]]; then
    outcome=no-runner
  elif [[ -e "$JSON_TMPDIR/quota_${lane}" ]]; then
    outcome=quota
  else
    outcome=empty
  fi
  PROVIDER_OUTCOMES="${PROVIDER_OUTCOMES:+$PROVIDER_OUTCOMES,}${lane}:${outcome}"
}

# ar_dispatch_lanes — run the lanes — all at once (multi) or in turn until one answers (single) — and record each outcome.
ar_dispatch_lanes() {
if [[ "$MULTI_MODE" == "multi" ]]; then
  # ── PARALLEL: launch providers directly (no run_provider wrapper) ──
  PIDS=()
  PNAMES=()

  for p in $PROVIDERS; do
    outfile="$JSON_TMPDIR/result_${p}.txt"
    statusfile="$JSON_TMPDIR/status_${p}.txt"
    errfile="$JSON_TMPDIR/provider_${p}.stderr"
    echo "  Launching: $p..." >&2
    # F6 (Plan B Task 10 review): the codex audit effort, on the DRIVER's own stderr, printed HERE
    # (not inside run_codex/dispatch_provider, whose stderr is redirected per-lane to $errfile and
    # never re-printed on success). The isolated CODEX_HOME's config.toml — where the effort is
    # actually set — is removed by that lane's own runner subshell moments after it finishes, long
    # before a live smoke run could read it; this line is the durable, cheap proof instead. Blind-audit
    # only, so --mode code's byte-identical golden output is untouched.
    if [[ "$REVIEW_MODE" == blind-audit ]]; then
      case "$p" in
        codex-*)
          echo "  ${p}: blind-audit effort=$(blind_audit_codex_effort) access=none" >&2 ;;
      esac
    fi

    (
      status=0
      p_start=$(date +%s)
      dispatch_provider "$p" > "$outfile" 2> "$errfile" || status=$?
      printf '%s\n' "$status" > "$statusfile"
      # Per-provider wall time. The run log used to record the WHOLE invocation's duration on
      # every provider row, so a single slow provider made all five look slow and no row ever
      # answered "which one ate the budget".
      printf '%s\n' "$(( $(date +%s) - p_start ))" > "$JSON_TMPDIR/dur_${p}.txt"
      exit 0
    ) &
    PIDS+=($!)
    PNAMES+=("$p")
    DISPATCHED_LIST="${DISPATCHED_LIST:+$DISPATCHED_LIST }$p"
  done

  # Wait for all providers — each has its own timeout inside the provider function
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Collect results. D1 (Task 3): no retry — the first timeout is final. The old 60%-truncated retry cost a
  # second full PROVIDER_TIMEOUT window (~6 min waits in the retros) and reviewed less; callers wanting a
  # second opinion re-invoke, with --rotate / --exclude-last <provider>.
  for i in "${!PNAMES[@]}"; do
    local_name="${PNAMES[$i]}"
    result_file="$JSON_TMPDIR/result_${local_name}.txt"
    status_file="$JSON_TMPDIR/status_${local_name}.txt"
    provider_status=1
    [[ -f "$status_file" ]] && provider_status=$(cat "$status_file")

    # Exclude a lane that only printed an auth error: no review, and counting it inflates "(N total)". A
    # MISSING file is no output (`empty`), not a stub. The FLAG excludes, never the unlink (best effort).
    lane_excluded=0
    if [[ -f "$result_file" ]] && is_auth_failure_output "$result_file"; then
      exclude_auth_stub "$local_name" "excluded from tally"
      lane_excluded=1; provider_status=1
      rm -f -- "$result_file" 2>/dev/null || true
    fi

    if [[ $lane_excluded -eq 0 && "$provider_status" == 0 && -s "$result_file" ]]; then
      PROVIDER_COUNT=$((PROVIDER_COUNT + 1))
      PROVIDERS_USED="${PROVIDERS_USED:+$PROVIDERS_USED, }$local_name"
      upper_name=$(echo "$local_name" | tr '[:lower:]' '[:upper:]')
      RESULT=$(cat "$result_file")
      ALL_RESULTS="${ALL_RESULTS}

###############################################################
###   PROVIDER: ${upper_name}
###############################################################

$RESULT
"
      echo "  Done: $local_name" >&2
      PROVIDER_OUTCOMES="${PROVIDER_OUTCOMES:+$PROVIDER_OUTCOMES,}${local_name}:ok"
    else
      if [[ "$provider_status" -eq 124 ]]; then
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        echo "  WARN: $local_name timed out." >&2
      else
        echo "  WARN: $local_name failed or returned empty." >&2
      fi
      record_provider_failure_outcome "$local_name" "$provider_status" parallel
    fi
  done

else
  # ── SINGLE: stop at first successful provider ──
  for p in $PROVIDERS; do
    echo "  Running: $p..." >&2

    status=0
    p_start=$(date +%s)
    DISPATCHED_LIST="${DISPATCHED_LIST:+$DISPATCHED_LIST }$p"
    RESULT=$(dispatch_provider "$p" 2>"$JSON_TMPDIR/provider_${p}.stderr") || status=$?
    printf '%s\n' "$(( $(date +%s) - p_start ))" > "$JSON_TMPDIR/dur_${p}.txt" 2>/dev/null || true

    # An auth stub must NOT satisfy "first successful provider" — otherwise the
    # loop breaks on it and no other provider is ever tried, turning the whole
    # review into a single "Not logged in" line.
    if [[ $status -eq 0 ]] && is_auth_failure_output "$RESULT"; then
      exclude_auth_stub "$p" "trying next provider."
      RESULT=""; status=1
    fi

    if [[ $status -ne 0 || -z "$RESULT" ]]; then
      # Record the NON-success outcomes too. Recording only auth/ok left a timed-out single
      # provider reporting `provider_outcomes=none` — the exact ambiguity this field exists to
      # remove. Skip when the auth branch above already classified it.
      record_provider_failure_outcome "$p" "$status" sequential
    fi
    if [[ $status -eq 0 && -n "$RESULT" ]]; then
      PROVIDER_COUNT=$((PROVIDER_COUNT + 1))
      PROVIDERS_USED="$p"
      PROVIDER_OUTCOMES="${PROVIDER_OUTCOMES:+$PROVIDER_OUTCOMES,}${p}:ok"
      [[ -d "$JSON_TMPDIR" ]] && echo "$RESULT" > "$JSON_TMPDIR/result_${p}.txt"
      ALL_RESULTS="$RESULT"
      break
    else
      if [[ $status -eq 124 ]]; then
        TIMEOUT_COUNT=$((TIMEOUT_COUNT + 1))
        echo "  WARN: $p timed out." >&2
      else
        echo "  WARN: $p failed or returned empty." >&2
      fi
    fi
  done
fi
return 0
}
