# shellcheck shell=bash
# adversarial-dispatch.sh — running the lanes: the error-as-output guard every lane shares, the lane
# router (dispatch_provider, mock lanes for the test harness), auth-stub detection, the outcome
# bookkeeping (ok/timeout/auth/quota/empty/unverified/no-runner/no-key) and the dispatch itself — parallel
# (multi) or first-success (single).
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phase: ar_dispatch_lanes.
#
# Phase bodies sit at column 0, as the top-level code they were cut from: indenting them would change the
# multi-line prompt strings and heredocs several carry. Each runs once, from the driver's Main.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ─── Error-as-output guard (one copy for every lane that reads an exit-0 body) ───
# LANE_ERR_SCAN_CHARS — below it, a body short enough that an error/quota phrase anywhere in it means the
# body IS that notice; at or above it, a real review that may QUOTE the phrase in a finding, so only an
# `error:` prefix refuses it. Real provider error bodies are short, reviews are long. Named once (CQ12):
# every lane reads this one. A WARN's quote length, by source: LANE_ERR_QUOTE_CHARS a refused answer's text,
# LANE_ERR_RESPONSE_QUOTE_CHARS a raw API response, LANE_QUOTE_MAX_BYTES a client's or a lane's stderr line.
LANE_ERR_SCAN_CHARS=1000
LANE_QUOTE_MAX_BYTES=300
# LANE_ANSWER_MAX_BYTES — the most of one lane's answer the run keeps: every answer is read into memory,
# merged and logged, and a runaway lane (a CLI echoing its input in a loop) would have no bound but the disk.
LANE_ANSWER_MAX_BYTES=2097152
LANE_ERR_QUOTE_CHARS=120
LANE_ERR_RESPONSE_QUOTE_CHARS=160
# LANE_MIN_RETRY_SECONDS — the least time left of the lane's PROVIDER_TIMEOUT worth a second call (a fallback,
# a retry, kimi's API lane; _ar_lane_budget): under it no model answers a review. Short timeouts use half.
LANE_MIN_RETRY_SECONDS=30
# AUTH_STUB_MAX_BYTES — the longest output that can be an auth stub (the shared runner's guard is the same).
# KILL_ROUNDING_SLACK_SECONDS — how far short of PROVIDER_TIMEOUT a 137 still counts as a timeout: clocks round.
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

# run_byteplus <lane> <model> — the OpenRouter client on the BytePlus Coding Plan endpoint, with the plan's key.
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
    # Its own label too, so its WARNs (which end the driver's line on a failed lane) name the lane.
    openrouter-alt|openrouter-3|openrouter-4)
                   ZUVO_OR_LANE_LABEL="$provider" ZUVO_OPENROUTER_MODEL="$(lane_model "$provider")" run_openrouter ;;
    byteplus|byteplus-alt|byteplus-3)
                   run_byteplus "$provider" "$(lane_model "$provider")" ;;
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
# Guarded by length — a REAL review that discusses login code is kept — so only a payload of at most
# AUTH_STUB_MAX_BYTES can be a stub: zms_is_auth_stub (file or string, the token list). Without the runner there is no
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
# "<lane><TAB><epoch>" younger than ZUVO_AUTH_CACHE_TTL (the health ledger's full cooldown). An entry dated in
# the future (the clock was set back) or with no time counts as expired: either would otherwise never expire.
_ar_auth_cached_lanes() {
  [[ -s "$PROVIDER_FAIL_CACHE" ]] || return 0
  awk -F'\t' -v now="$(date +%s)" -v ttl="$(ar_env_int ZUVO_AUTH_CACHE_TTL 21600)" \
    'NF >= 2 && $2 ~ /^[0-9]+$/ && $2 <= now && now - $2 < ttl { print $1 }' "$PROVIDER_FAIL_CACHE" 2>/dev/null | sort -u
}

exclude_auth_stub() {
  local kind=unverified
  if [[ -n "$ZMS_LOADED" ]]; then
    kind=auth; echo "  WARN: $1 not authenticated (auth error, no review) — $2" >&2
    _ar_auth_cached_lanes | grep -qxF -e "$1" 2>/dev/null || printf '%s\t%s\n' "$1" "$(date +%s)" >> "$PROVIDER_FAIL_CACHE"
  else echo "  WARN: $1: short output (≤${AUTH_STUB_MAX_BYTES} B) not counted, unverified — the shared runner is missing, so it cannot be checked for an auth error — $2" >&2; fi
  PROVIDER_OUTCOMES="${PROVIDER_OUTCOMES:+$PROVIDER_OUTCOMES,}$1:$kind"
}
# lane_ok <lane> — its answer counts as a review: outcome `ok` AND a result file (an excluded stub never).
lane_ok() { [[ ",$PROVIDER_OUTCOMES," == *",$1:ok,"* && -s "$JSON_TMPDIR/result_$1.txt" ]]; }

# result_has_text <file> — the answer holds more than whitespace: blank lines with exit 0 are no review, and
# must not put a REVIEW BY line in the artifact the push gate reads.
result_has_text() { [[ -s "$1" ]] && LC_ALL=C awk 'NF { found = 1; exit } END { exit !found }' "$1" 2>/dev/null; }

# lane_failed_verb <lane> — "was not run" for a lane with no usable key (lane_no_key's marker), else "failed".
lane_failed_verb() {
  if [[ -e "$JSON_TMPDIR/nokey_$1" ]]; then echo "was not run"; else echo "failed or returned empty"; fi
}

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
  elif [[ -e "$JSON_TMPDIR/nokey_${lane}" ]]; then
    outcome=no-key
  elif [[ -e "$JSON_TMPDIR/quota_${lane}" ]]; then
    outcome=quota
  else
    outcome=empty
  fi
  PROVIDER_OUTCOMES="${PROVIDER_OUTCOMES:+$PROVIDER_OUTCOMES,}${lane}:${outcome}"
}

# Word-count of the dispatched-provider list. Extracted (B-dispatched-count-dup) because the
# same expression sat byte-identically in the all-failed branch and the success-path status
# derivation. The two are mutually exclusive at runtime so it was never a correctness bug — it
# was inconsistent with the rest of the change that introduced it, which extracted
# adversarial_log_row, preserve_failure_evidence and suspended_seconds for exactly this reason.
dispatched_count() { printf '%s\n' "$1" | wc -w | tr -d ' '; }

# _ar_quote_line first|last-warn <file|-> [<max bytes>] — one line of a client's or a lane's output, safe to
# print (every WARN that quotes a client goes through here): ANSI sequences and C0/C1 controls stripped, tabs
# as spaces, at most <max bytes> (default LANE_QUOTE_MAX_BYTES; never a split UTF-8 char) + "…". `first`: the
# first non-empty line; `last-warn`: the text of the last "WARN:" line.
_ar_quote_line() {
  LC_ALL=C awk -v pick="$1" -v max="${3:-$LANE_QUOTE_MAX_BYTES}" '
    { gsub(/\t/, " "); gsub(/\033\[[0-9;?]*[A-Za-z]/, ""); gsub(/\302[\200-\237]|[[:cntrl:]]/, "") }
    pick == "first" && /[^ ]/        { line = $0; exit }
    pick == "last-warn" && /^ *WARN: / { line = $0; sub(/^ *WARN: /, "", line) }
    END {
      if (line == "") exit
      if (length(line) > max) { line = substr(line, 1, max); sub(/[\300-\377][\200-\277]*$/, "", line); line = line "…" }
      print line
    }' "$2" 2>/dev/null || true
}

# _ar_cap_answer <lane> — cuts the lane's answer file at LANE_ANSWER_MAX_BYTES, said in a WARN; status 0 always
# (callers run under errexit). An answer it cannot cut is never left whole: when copy-and-move fails (a full
# disk, an unwritable dir) it is cut in place with dd, and failing that dropped, so the lane reads as empty.
_ar_cap_answer() {
  local f="$JSON_TMPDIR/result_$1.txt" size
  size="$(wc -c < "$f" 2>/dev/null | tr -d ' ')" || return 0
  [[ "${size:-0}" -gt "$LANE_ANSWER_MAX_BYTES" ]] || return 0
  if head -c "$LANE_ANSWER_MAX_BYTES" "$f" > "$f.cap" 2>/dev/null && mv -f "$f.cap" "$f" 2>/dev/null; then
    echo "  WARN: $1's answer was $size bytes — the review keeps its first $LANE_ANSWER_MAX_BYTES" >&2
    return 0
  fi
  rm -f "$f.cap" 2>/dev/null || true
  # Exactly the cap afterwards, not "no larger": a file the cut emptied is no larger either.
  if dd if=/dev/null of="$f" bs=1 seek="$LANE_ANSWER_MAX_BYTES" count=0 2>/dev/null \
     && [[ "$(wc -c < "$f" 2>/dev/null | tr -d ' ')" -eq "$LANE_ANSWER_MAX_BYTES" ]]; then
    echo "  WARN: $1's answer was $size bytes — the review keeps its first $LANE_ANSWER_MAX_BYTES (cut in place)" >&2
    return 0
  fi
  if : > "$f" 2>/dev/null || rm -f "$f" 2>/dev/null; then
    echo "  WARN: $1's answer was $size bytes and could not be cut to $LANE_ANSWER_MAX_BYTES — dropped, the lane counts as empty" >&2
  else
    echo "  WARN: $1's answer was $size bytes and could neither be cut nor dropped — it is read whole" >&2
  fi
  return 0
}

# lane_reason <lane> — what a failed lane said last about why (its last WARN), for the driver's own line on
# it: a lane's stderr goes to provider_<lane>.stderr, a file kept only when EVERY lane failed.
lane_reason() {
  [[ -s "$JSON_TMPDIR/provider_$1.stderr" ]] || return 0
  _ar_quote_line last-warn "$JSON_TMPDIR/provider_$1.stderr"
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
    [[ "$p" != claude ]] || claude_lane_note
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
  # All reaped: cleanup must not signal these numbers later, when the system may have given them to others.
  PIDS=()

  # Collect results. D1 (Task 3): no retry — the first timeout is final. The old 60%-truncated retry cost a
  # second full PROVIDER_TIMEOUT window (~6 min waits in the retros) and reviewed less; callers wanting a
  # second opinion re-invoke, with --rotate / --exclude-last <provider>.
  for i in "${!PNAMES[@]}"; do
    local_name="${PNAMES[$i]}"
    result_file="$JSON_TMPDIR/result_${local_name}.txt"
    status_file="$JSON_TMPDIR/status_${local_name}.txt"
    provider_status=1
    [[ -f "$status_file" ]] && provider_status=$(cat "$status_file")
    _ar_cap_answer "$local_name"

    # Exclude a lane that only printed an auth error: no review, and counting it inflates "(N total)". A
    # MISSING file is no output (`empty`), not a stub. The FLAG excludes, never the unlink (best effort).
    lane_excluded=0
    if [[ -f "$result_file" ]] && is_auth_failure_output "$result_file"; then
      exclude_auth_stub "$local_name" "excluded from tally"
      lane_excluded=1; provider_status=1
      rm -f -- "$result_file" 2>/dev/null || true
    fi

    if [[ $lane_excluded -eq 0 && "$provider_status" == 0 ]] && result_has_text "$result_file"; then
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
        reason="$(lane_reason "$local_name")"
        if [[ -n "$reason" ]]; then reason=": $reason"; else reason="."; fi
        echo "  WARN: $local_name $(lane_failed_verb "$local_name")$reason" >&2
      fi
      record_provider_failure_outcome "$local_name" "$provider_status" parallel
    fi
  done

else
  # ── SINGLE: stop at first successful provider ──
  # One walk budget (LANE_WALK_BUDGET): a later lane gets what is left, never less than _ar_lane_budget's floor.
  _walk_t0=$SECONDS; _walk_n=0
  for p in $PROVIDERS; do
    _walk_timeout="$PROVIDER_TIMEOUT"
    if [[ "$_walk_n" -gt 0 && -n "${LANE_WALK_BUDGET:-}" ]]; then
      _walk_left=$(( LANE_WALK_BUDGET - (SECONDS - _walk_t0) - ZUVO_TIMEOUT_GRACE ))
      _walk_floor=$LANE_MIN_RETRY_SECONDS   # _ar_lane_budget's floor: under half the timeout when that is less
      [[ "$_walk_floor" -le $(( PROVIDER_TIMEOUT / 2 )) ]] || _walk_floor=$(( PROVIDER_TIMEOUT / 2 ))
      if [[ "$_walk_left" -lt "$_walk_floor" || "$_walk_left" -le 0 ]]; then
        echo "  NOTE: not starting $p — ${_walk_left}s left of the run's ${LANE_WALK_BUDGET}s" >&2
        break
      fi
      [[ "$_walk_left" -ge "$_walk_timeout" ]] || _walk_timeout="$_walk_left"
    fi
    _walk_n=$((_walk_n + 1))
    echo "  Running: $p..." >&2
    [[ "$p" != claude ]] || claude_lane_note

    status=0
    p_start=$(date +%s)
    DISPATCHED_LIST="${DISPATCHED_LIST:+$DISPATCHED_LIST }$p"
    # In the background and waited for, not inside $( ): bash holds a trap until a command substitution
    # returns, while `wait` is interrupted at once — and cleanup finds the lane in PIDS.
    PROVIDER_TIMEOUT="$_walk_timeout" dispatch_provider "$p" > "$JSON_TMPDIR/result_${p}.txt" 2>"$JSON_TMPDIR/provider_${p}.stderr" &
    PIDS=($!)
    wait "${PIDS[0]}" || status=$?
    PIDS=()
    _ar_cap_answer "$p"
    RESULT="$(cat "$JSON_TMPDIR/result_${p}.txt" 2>/dev/null)" || RESULT=""
    printf '%s\n' "$(( $(date +%s) - p_start ))" > "$JSON_TMPDIR/dur_${p}.txt" 2>/dev/null || true

    # An auth stub must NOT satisfy "first successful provider" — otherwise the
    # loop breaks on it and no other provider is ever tried, turning the whole
    # review into a single "Not logged in" line.
    if [[ $status -eq 0 ]] && is_auth_failure_output "$RESULT"; then
      exclude_auth_stub "$p" "trying next provider."
      RESULT=""; status=1
    fi

    [[ $status -ne 0 ]] || result_has_text "$JSON_TMPDIR/result_${p}.txt" || RESULT=""
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
        reason="$(lane_reason "$p")"
        if [[ -n "$reason" ]]; then reason=": $reason"; else reason="."; fi
        echo "  WARN: $p $(lane_failed_verb "$p")$reason" >&2
      fi
    fi
  done
fi
return 0
}
