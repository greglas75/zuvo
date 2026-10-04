# shellcheck shell=bash
# adversarial-run.sh — the run's lifecycle around the dispatch: --doctor, the preflight and timeouts,
# --dry-run, the per-run state, failure evidence kept when nothing answered, cleanup and the signal
# traps, and the whole-run deadline watchdog (plus caffeinate on macOS).
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_run_doctor, ar_preflight, ar_dry_run, ar_init_run_state, ar_install_traps,
# ar_arm_deadline. Functions: preserve_failure_evidence, cleanup.
#
# Phase bodies sit at column 0, byte for byte the top-level code they were cut from:
# indenting them would change the multi-line prompt strings and heredocs several carry, and would
# make the move unprovable by diff. Each runs once, from the driver's Main, at the point it used to.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ar_run_doctor — --doctor: probe every detected provider with a tiny prompt, then exit.
ar_run_doctor() {
# ─── Doctor mode: live auth probe of every detected provider ───
# `command -v <cli>` proves presence, NOT a working login (field lesson 2026-07-19:
# fleet bots had codex/agy/claude on PATH with expired/revoked tokens — every
# review burned full provider timeouts before discovering nothing could run).
# --doctor sends each detected provider a tiny prompt with a short timeout and
# reports WORKING / FAILED / TIMEOUT. Exit 0 if ≥1 provider works, else 1.

if [[ "$DOCTOR" == "true" ]]; then
  _doc_timeout="$(ar_env_int ZUVO_DOCTOR_TIMEOUT 60 1)"
  echo "PROVIDER DOCTOR (auth + dispatch probe, ${_doc_timeout}s timeout each)"
  REVIEW_PROMPT="Reply with exactly: PROVIDER-OK"
  PROVIDER_TIMEOUT="$_doc_timeout"
  working=0
  _doc_list="${ALL_DETECTED_PROVIDERS:-$PROVIDERS}"
  _doc_total=$(printf '%s' "$_doc_list" | wc -w | tr -d ' ')
  # Every lane is probed at once, as --multi dispatches them: one after another, a doctor over N lanes
  # took up to N x the timeout (nine minutes for nine). Each probe writes its own files; the report
  # below reads them in list order. On exit — Ctrl-C and TERM included — the probes and their clients
  # go too, and the temp dir with them.
  _doc_pids=()
  _ar_doc_stop() {
    # Keeps the exit status it was called with: a kill of a probe that has already finished fails, and
    # under errexit that failure ended the doctor with 1 after it had reported working lanes.
    local rc=$? _p _t=""
    for _p in ${_doc_pids[@]+"${_doc_pids[@]}"}; do _t="$_t $(_ar_descendants "$_p" | tr '\n' ' ') $_p"; done
    # shellcheck disable=SC2086  # a list of pids, one per word
    [[ -z "${_t// /}" ]] || kill $_t 2>/dev/null || true
    [[ -z "${JSON_TMPDIR:-}" ]] || rm -rf "$JSON_TMPDIR" || true
    return "$rc"
  }
  trap _ar_doc_stop EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  # The run_* functions need JSON_TMPDIR, normally created in the Execute section we exit before
  # reaching — our own, made once the traps that remove it are armed.
  JSON_TMPDIR=$(mktemp -d)
  for p in $_doc_list; do
    (
      p_rc=0; p_start=$(date +%s)
      dispatch_provider "$p" > "$JSON_TMPDIR/doctor_$p.out" 2> "$JSON_TMPDIR/doctor_$p.err" || p_rc=$?
      printf '%s %s\n' "$p_rc" "$(( $(date +%s) - p_start ))" > "$JSON_TMPDIR/doctor_$p.status"
    ) &
    _doc_pids+=($!)
  done
  for _doc_pid in ${_doc_pids[@]+"${_doc_pids[@]}"}; do wait "$_doc_pid" 2>/dev/null || true; done
  _doc_pids=()   # reaped: the exit trap must not signal numbers the system may since have reused
  for p in $_doc_list; do
    # R-1 (MUST-FIX), kept: a probe that failed is a REPORT line, never an abort under `set -e` — the
    # status file of a probe that died before writing it reads as a failure.
    p_rc=1; p_secs="?"
    read -r p_rc p_secs < "$JSON_TMPDIR/doctor_$p.status" 2>/dev/null || true
    p_out="$(cat "$JSON_TMPDIR/doctor_$p.out" 2>/dev/null)" || p_out=""
    # R-17: WORKING requires the actual probe echo, not just any non-empty exit-0 output —
    # an exit-0 error body (the agy failure mode) must read FAILED here.
    if [[ $p_rc -eq 0 && "$p_out" == *"PROVIDER-OK"* ]]; then
      printf '  %-14s WORKING (%ss, model: %s)\n' "$p" "$p_secs" "$(provider_model "$p")"
      working=$((working+1))
    elif [[ $p_rc -eq 0 && -n "$p_out" ]]; then
      printf '  %-14s SUSPECT (%ss, replied but without probe echo: %s)\n' "$p" "$p_secs" \
        "$(printf '%s' "$p_out" | head -c 100 | tr '\n' ' ')"
    elif [[ $p_rc -eq 124 ]]; then
      printf '  %-14s TIMEOUT after %ss\n' "$p" "$p_secs"
    else
      printf '  %-14s FAILED (exit %s): %s\n' "$p" "$p_rc" \
        "$(head -c 160 "$JSON_TMPDIR/doctor_$p.err" 2>/dev/null | tr '\n' ' ')"
    fi
  done
  echo "  ---"
  echo "  usable providers: $working / $_doc_total"
  [[ $working -ge 1 ]] && exit 0 || exit 1
fi
return 0
}

# ar_preflight — timeout and jq are required; PROVIDER_TIMEOUT.
ar_preflight() {
# ─── Preflight checks ──────────────────────────────────────────

command -v timeout &>/dev/null || { echo "ERROR: GNU timeout required. Install: brew install coreutils" >&2; exit 1; }
command -v jq &>/dev/null || { echo "ERROR: jq required. Install: brew install jq" >&2; exit 1; }

# 400, not 240. Measured 2026-08-29 on a size ladder (one real diff cut to 5/12/20/28 kB, both
# Gemini lanes, 2 reps): Gemini 3.1 Pro's wall clock scales 4.6x with input size — 52s at 5 kB,
# 169s at 12 kB, 238s at 20 kB, 239s at 28 kB — while 3.7 Flash stays flat at 60-90s. At 240s the
# Pro lane was therefore dying ON THE CLOCK, not on the work: the runs that DID finish came back
# at 212s and 229s, just under the ceiling, and half the 20 kB+ cells timed out. The fleet log
# agrees — in the 15-30 kB band, which is 54% of all runs, agy failed to answer 52% of the time.
# A timeout is supposed to catch a wedged provider, not to cut off a working one mid-answer.
DEFAULT_TIMEOUT=500
# Flat, with no heavy-mode bump on top. The bump used to take those modes to 360 — below the
# base — and raising it proportionally would put the inner timeout ABOVE the outer `timeout`
# wrappers those very modes are invoked with, so the outer kill would fire first and the run
# would die with NO artifact: strictly worse than the timeout it was meant to replace.
#
# THE INVARIANT: PROVIDER_TIMEOUT + ZUVO_TIMEOUT_GRACE must stay under EVERY outer wrapper,
# with enough margin left for aggregation and writing the artifact. Raising this number alone
# silently eats that margin. Both moves kept it: 480 -> 540 with the 450 bump, and 540 -> 600
# with this one (500 + 15 + 85 margin) in skills/plan/SKILL.md and
# shared/includes/cross-provider-review.md; skills/write-tests keeps 590, which still clears
# 515 by 75s. If you change this number, change those.
#
# Why 500 (2026-09-09, was 450 since 09-06): the ceiling is what decides which models are
# usable at all, and the benchmark says the good ones sit just under it. Of 260 qwen3.8-flash
# production calls 30% died AT the ceiling while its SUCCESSFUL runs had p75 400s / p90 401s —
# a quarter finishing in the last second. Benchmarked head-room at 450s: qwen3.8-flash 336s
# average, deepseek-v4-flash 309s. 500s buys both of them a real margin instead of a coin flip;
# it is a clock problem, not a capability problem. Everything above ~420s average stays out.
PROVIDER_TIMEOUT="$(ar_env_int ZUVO_REVIEW_TIMEOUT "$DEFAULT_TIMEOUT" 1)"   # 0 would be `timeout 0`: no limit
# --mode blind-audit has its own per-lane budget (bap_timeout: default 480, at most 510 and short enough
# that timeout + kill grace + 60 stays <= 585, inside its caller's 600 s Bash call); ZUVO_REVIEW_TIMEOUT
# does not apply to it.
if [[ "$REVIEW_MODE" == blind-audit ]]; then PROVIDER_TIMEOUT="$(bap_timeout "$ZUVO_TIMEOUT_GRACE")"; fi
return 0
}

# ar_dry_run — --dry-run: print the prompt that would be sent and exit 0.
ar_dry_run() {
# ─── Dry run ───────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN — prompt that would be sent ===" >&2
  echo "Mode: $REVIEW_MODE | Input: ${#INPUT} chars | Format: $OUTPUT_FORMAT" >&2
  echo "Providers: $PROVIDERS" >&2
  echo "Timeout: ${PROVIDER_TIMEOUT}s" >&2
  echo "===" >&2
  printf '%s\n' "$REVIEW_PROMPT"
  exit 0
fi
return 0
}

# ar_init_run_state — the banner and the per-run state: counters, the outcome ledger, the temp dir, RUN_ID.
ar_init_run_state() {
echo "CROSS-PROVIDER REVIEW" >&2
echo "  Input: ${#INPUT} chars" >&2
echo "  Review: $REVIEW_MODE | Output: $OUTPUT_FORMAT | Dispatch: $MULTI_MODE" >&2

ALL_RESULTS=""
PROVIDERS_USED=""
PROVIDER_COUNT=0
# Per-provider outcome ledger: "claude:ok,agy:timeout,codex:auth,kimi:quota". Downstream gates read the
# artifact, not stderr — without this a one-provider artifact is indistinguishable from a
# deliberate single-provider run and a run where three providers silently died.
PROVIDER_OUTCOMES=""
# Providers actually DISPATCHED, as opposed to PROVIDERS (candidates). In --single the loop
# stops at the first success, so the remaining candidates were never asked — counting them as
# attempted is what makes a perfectly healthy single run report status=partial, and what makes
# the run log show four "failed" providers that no request was ever sent to.
DISPATCHED_LIST=""
FINAL_STATUS="ok"
TIMEOUT_COUNT=0
JSON_TMPDIR=$(mktemp -d)
# One id for the whole invocation: the run log, the saved input diff and any preserved failure
# evidence must be correlatable. Previously each site minted its own `date +%s-$$`.
RUN_ID="$(date +%s)-$$"
DEADLINE_MARKER="$JSON_TMPDIR/.deadline-hit"
WATCHDOG_PID=""
CAFFEINATE_PID=""
FAILURE_EVIDENCE_DIR=""
return 0
}

# Keep every provider's stderr when the run produced NO review at all. Today cleanup deletes
# the tmpdir and takes all of it with it, which is why 41 of the last 229 all-fail events —
# the ones rejected in under 30s, so auth or quota or rate limit — cannot be told apart now.
preserve_failure_evidence() {
  # PRUNE FIRST — before every early return below. The 7-day prune at the end of this function
  # has been here all along and almost never ran: it sits behind `PROVIDER_COUNT > 0 && return`,
  # so a run in which ANY provider answered leaves without pruning. On a healthy fleet that is
  # nearly every run, which is why the directory held 336 entries reaching back 8 days while a
  # correct-looking 7-day prune sat in the source. A retention that only fires on total failure
  # is retention that fires when the fleet is broken and never when it works.
  #
  # Cheap and fail-open: one find over a few hundred entries. `2>/dev/null` swallows the MESSAGE,
  # `|| true` swallows the STATUS — and only the second one matters under `set -euo pipefail`.
  # Without it this was the single unguarded command in a function where every other fallible
  # line already carries `|| true`, and `find` is the final command after `&&`, so its failure is
  # NOT exempt. The caller at the "all providers failed" path runs with `-e` still active (the
  # only `set +e` lives inside `cleanup`), so a prune that lost a race with a concurrent run —
  # two reviews share ~/.zuvo/adversarial-failures — killed the script before it wrote the
  # diagnostic this whole path exists to produce. Reproduced: a failing find exits 1 and the
  # next line never runs.
  local _ev_root="${ZUVO_HOME:-$HOME/.zuvo}/adversarial-failures"
  [[ -d "$_ev_root" ]] && find "$_ev_root" -mindepth 1 -maxdepth 1 -type d \
    -mtime "+$(ar_env_int ZUVO_FAILURE_EVIDENCE_DAYS 7)" -exec rm -rf {} + 2>/dev/null || true
  [[ -n "$FAILURE_EVIDENCE_DIR" ]] && return 0   # already saved (fail path calls it early)
  [[ "${PROVIDER_COUNT:-0}" -gt 0 ]] && return 0
  [[ -d "$JSON_TMPDIR" ]] || return 0
  # Glob test, not `ls a* b*` — BSD ls exits non-zero when EITHER pattern misses, so with a
  # provider that produced err_ but no provider_ stderr (or vice versa) the guard would bail
  # and throw away the evidence it is here to keep.
  local f found=0
  for f in "$JSON_TMPDIR"/err_*.txt "$JSON_TMPDIR"/provider_*.stderr; do
    [[ -e "$f" ]] && { found=1; break; }
  done
  [[ "$found" -eq 1 ]] || return 0
  local evidence_root="${ZUVO_HOME:-$HOME/.zuvo}/adversarial-failures"
  local dest="$evidence_root/$RUN_ID"
  # 0700, both levels. This copies THIRD-PARTY CLI stderr verbatim and keeps it for a week; an
  # auth failure can print a token or a config dump, and until now that content died with the
  # tmpdir. Persisting it at the ambient umask would be a new, durable exposure.
  # `mkdir -m` sets the mode only on directories it CREATES — an evidence root left over from a
  # pre-0700 run would keep its looser mode forever, so tighten explicitly as well.
  # shellcheck disable=SC2174  # the chmod on the next line is exactly the -p fix SC2174 asks for
  mkdir -m 700 -p "$evidence_root" 2>/dev/null || return 0
  chmod 700 "$evidence_root" 2>/dev/null || true
  # shellcheck disable=SC2174
  mkdir -m 700 -p "$dest" 2>/dev/null || return 0
  chmod 700 "$dest" 2>/dev/null || true
  # `|| true` on both: only one of the two patterns matches in most runs, and an unmatched
  # glob reaches cp as a literal path. Under `set -e` that failure aborted the whole failure
  # path — the run died before it could report WHY it failed.
  cp "$JSON_TMPDIR"/err_*.txt "$dest/" 2>/dev/null || true
  cp "$JSON_TMPDIR"/provider_*.stderr "$dest/" 2>/dev/null || true
  {
    printf 'run_id=%s\n' "$RUN_ID"
    printf 'mode=%s\n' "$REVIEW_MODE"
    printf 'dispatch=%s\n' "${MULTI_MODE:-auto}"
    printf 'providers=%s\n' "$PROVIDERS"
    printf 'dispatched=%s\n' "${DISPATCHED_LIST:-}"
    # `none` used to mean two different things and the difference is the whole value of this
    # file. This function runs from the EXIT trap, so a run killed mid-flight — an outer
    # `timeout`, a reaped process group, Ctrl-C — lands here with PROVIDER_OUTCOMES still empty
    # and recorded `none`, identical to "every provider was tried and gave nothing".
    #
    # Measured 2026-09-23 over the saved evidence: 93 of 259 directories said `none`, and at
    # least one of them holds a provider stderr reporting 11088 input / 3175 output tokens —
    # real, paid work, discarded, filed as "nobody answered". Diagnosing a lane from that
    # ledger means diagnosing it from runs where the lane was never given a verdict.
    #
    # DISPATCHED_LIST is appended as each provider STARTS, in both the single and multi paths,
    # and is a plain global, so it survives into the trap. Non-empty outcomes + empty dispatch
    # list cannot happen; empty outcomes + non-empty dispatch list is exactly the kill case.
    if [[ -n "$PROVIDER_OUTCOMES" ]]; then
      printf 'provider_outcomes=%s\n' "$PROVIDER_OUTCOMES"
    elif [[ -n "${DISPATCHED_LIST:-}" ]]; then
      printf 'provider_outcomes=interrupted\n'
    else
      printf 'provider_outcomes=none\n'
    fi
    printf 'provider_timeout=%s\n' "$PROVIDER_TIMEOUT"
  } > "$dest/meta.txt" 2>/dev/null
  FAILURE_EVIDENCE_DIR="$dest"
}

PIDS=()   # not `declare -a`: global wherever this module is sourced from (in a function, declare makes a local)
CLEANED_UP=0
# DEADLINE_SLACK_SECONDS — what the whole-run deadline adds to the lanes' own budget (setup, the report,
# the last lane's kill grace): generous on purpose, it must never fire on a merely slow provider.
DEADLINE_SLACK_SECONDS=120
# _ar_descendants <pid> — every live descendant of <pid>, deepest first (pgrep -P, one level at a time).
# Without pgrep it prints nothing, and cleanup does what it always did.
_ar_descendants() {
  local c
  for c in $(pgrep -P "$1" 2>/dev/null); do _ar_descendants "$c"; printf '%s\n' "$c"; done
}

cleanup() {
  # Preserve the script's exit code — any non-zero return from kill/wait/rm here
  # would otherwise override an explicit `exit 124` (timeout) or `exit 0`. Locally
  # disable set -e so a stale PID kill (which returns 1) does not short-circuit
  # the return statement that propagates the original rc.
  local rc=$?
  # R-5 fix: guard against double-run. INT/TERM trap fires `cleanup` then `exit N`,
  # which triggers EXIT trap → `cleanup` again. Without this guard, kill/rm run
  # twice on already-dead PIDs / already-gone tmpdir — usually benign but creates
  # noisy debugging trails.
  [[ "$CLEANED_UP" -eq 1 ]] && return $rc
  CLEANED_UP=1
  set +e
  # Kill the watchdog AND its `sleep` child — killing the subshell alone reparents the sleep,
  # which then idles until the full deadline.
  if [[ -n "$WATCHDOG_PID" ]]; then
    pkill -P "$WATCHDOG_PID" 2>/dev/null
    kill "$WATCHDOG_PID" 2>/dev/null
  fi
  [[ -n "$CAFFEINATE_PID" ]] && kill "$CAFFEINATE_PID" 2>/dev/null
  # The lanes' CLIENTS, not only their dispatch subshells. A client runs under `timeout` (its own
  # process group) or the shared runner, a level or two below the subshell in PIDS, and killing the
  # subshell alone left it running — and spending — until its own timeout, minutes after Ctrl-C or an
  # orchestrator's TERM. TERM goes to every descendant first, deepest first; `timeout` forwards it to
  # its group. (--single runs its lane inside $( ), where bash holds the trap until the lane returns.)
  if [[ ${#PIDS[@]} -gt 0 ]]; then
    local _p _tree=""
    for _p in "${PIDS[@]}"; do _tree="$_tree $(_ar_descendants "$_p" | tr '\n' ' ')"; done
    # shellcheck disable=SC2086  # a list of pids, one per word
    [[ -n "${_tree// /}" ]] && kill $_tree 2>/dev/null
  fi
  [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null
  wait 2>/dev/null
  preserve_failure_evidence
  rm -rf "$JSON_TMPDIR" 2>/dev/null
  return $rc
}

# ar_install_traps — cleanup on EXIT; INT exits 130, TERM 143 (124 when the deadline fired).
ar_install_traps() {
# Right after ar_init_run_state, which creates JSON_TMPDIR and sets everything cleanup reads (PIDS,
# WATCHDOG_PID, CAFFEINATE_PID, RUN_ID, FAILURE_EVIDENCE_DIR, PROVIDER_COUNT). It used to come after
# the run-log setup, so a TERM or an exit in between left the run's temp dir behind.
trap cleanup EXIT
# R-3 fix: distinct exit codes for signals vs timeout. INT=130 (standard 128+SIGINT),
# TERM=143 (standard 128+SIGTERM). Previously both mapped to 124, conflating user-cancel
# / orchestrator-kill with "all providers timed out". Callers branching on exit 124
# now reliably mean "timeout" only.
# The deadline watchdog below also delivers TERM, so the marker is read BEFORE cleanup
# removes the tmpdir — a self-inflicted deadline is a timeout (124), not an outside kill.
trap 'cleanup; exit 130' INT
_dl=0   # set by the TERM trap below; declared here so it is a known global
trap '_dl=0; [[ -f "$DEADLINE_MARKER" ]] && _dl=1; cleanup; [[ "$_dl" -eq 1 ]] && exit 124; exit 143' TERM
return 0
}

# ar_arm_deadline — RUN_DEADLINE and its watchdog; caffeinate on macOS.
ar_arm_deadline() {
# ─── Whole-run deadline ─────────────────────────────────────────
# Second line of defence behind `timeout -k`. If a provider wedges somewhere the per-provider
# kill cannot reach, nothing else bounds this script: the field log holds invocations of 1076s,
# 5998s and 34273s against a 240s budget. This turns "hangs until someone notices" into
# "exits 124 late". Generous on purpose — it must never fire on a merely slow provider.
if [[ "$REVIEW_MODE" == blind-audit ]]; then
  # timeout + grace + 60, never past 585 s: its callers wait in a 600 s Bash call (480 + 15 + 60 = 555).
  RUN_DEADLINE="$(bap_deadline "$PROVIDER_TIMEOUT" "$ZUVO_TIMEOUT_GRACE")"
  # ZUVO_RUN_DEADLINE is ignored here, same as ZUVO_REVIEW_TIMEOUT/ZUVO_REVIEW_MAX_PROVIDERS/
  # ZUVO_REVIEW_PROVIDER above: a larger value breaks the 585 s invariant this mode's callers rely
  # on (they wait in a 600 s Bash call); a smaller one SIGTERMs the panel before a lane can answer.
  if [[ -n "${ZUVO_RUN_DEADLINE:-}" ]]; then
    # Sanitized before it reaches stderr, same idiom as the model-id sanitizers above (tr -cd) plus
    # a length cap — this value is unvalidated env input, never echoed raw. LC_ALL=C keeps BSD tr
    # from aborting on an invalid byte sequence in a UTF-8 locale (it exits non-zero on "Illegal
    # byte sequence", which — under this script's `set -euo pipefail` — a bare failing command
    # substitution turns into a whole-run abort); `|| _rd_shown=""` is the same belt for any other
    # unexpected failure in the pipeline, so this can never take the run down with it.
    _rd_shown="$(printf '%s' "$ZUVO_RUN_DEADLINE" | LC_ALL=C tr -cd 'a-zA-Z0-9._-' | cut -c1-20)" || _rd_shown=""
    [[ -n "$_rd_shown" ]] || _rd_shown="(unprintable)"   # e.g. all-whitespace or non-ASCII input
    echo "  NOTE: ZUVO_RUN_DEADLINE='$_rd_shown' is ignored in --mode blind-audit (deadline is derived from the per-lane timeout)" >&2
    unset _rd_shown
  fi
elif [[ "$MULTI_MODE" == "multi" ]]; then
  RUN_DEADLINE=$(( PROVIDER_TIMEOUT + ZUVO_TIMEOUT_GRACE + DEADLINE_SLACK_SECONDS ))
else
  # single/rotate walk the candidate list sequentially in the worst case.
  RUN_DEADLINE=$(( (PROVIDER_TIMEOUT + ZUVO_TIMEOUT_GRACE) * ATTEMPTED_COUNT + DEADLINE_SLACK_SECONDS ))
fi
# ONE gate, ONE sanitizer: blind-audit's value (from bap_deadline) skips the env override but still
# passes through the same ar_decimal normaliser as every other mode — no separate sanitizer path.
# The COMPUTED deadline is normalised first and is ar_decimal's default for the override: an invalid
# ZUVO_RUN_DEADLINE (negative → WARN, or no digit at all) falls back to it. The default used to be "",
# so a negative override (" -3600", "-5") silently armed NO watchdog at all — the unbounded run this
# backstop exists to prevent. An explicit 0 is unchanged (valid digits; the gate below arms nothing).
# Without an override the normalised default IS the deadline — never normalised a second time.
_rd_default="$(ar_decimal "$RUN_DEADLINE" "" "$AR_NUM_CAP")"
if [[ "$REVIEW_MODE" == blind-audit || -z "${ZUVO_RUN_DEADLINE:-}" ]]; then RUN_DEADLINE="$_rd_default"
else RUN_DEADLINE="$(ar_decimal "$ZUVO_RUN_DEADLINE" "$_rd_default" "$AR_NUM_CAP")"; fi
unset _rd_default
# bap_deadline's contract is to always print positive digits, never more than the library's own
# ceiling (the mode's skill callers wait in a bounded Bash call) — this is unreachable by
# construction today. But a mode with NO watchdog at all (empty, zero, or somehow negative) would
# silently break that ceiling promise if it ever happened, so fall back to the library's PUBLIC
# accessor — never its private $_BAP_RUN_CEILING var directly, and never a hardcoded 585 — through
# the same ar_decimal normaliser as every other value here.
if [[ "$REVIEW_MODE" == blind-audit ]] && { [[ -z "$RUN_DEADLINE" ]] || [[ "$RUN_DEADLINE" -le 0 ]]; }; then
  echo "  WARN: blind-audit whole-run deadline could not be derived; using the ceiling $(bap_run_ceiling)s" >&2
  RUN_DEADLINE="$(ar_decimal "$(bap_run_ceiling)" "" "$AR_NUM_CAP")"
fi
[[ "$REVIEW_MODE" != blind-audit ]] || echo "  Blind audit: ${PROVIDER_TIMEOUT}s per lane, whole-run deadline ${RUN_DEADLINE:-none}${RUN_DEADLINE:+s}" >&2
# The whole-run ceiling is also what the no-monotonic-clock suspend heuristic must measure
# against — see suspended_seconds(). Anything smaller misreads sequential dispatch as a sleep.
SUSPEND_BUDGET="${RUN_DEADLINE:-$PROVIDER_TIMEOUT}"
[[ -n "$SUSPEND_BUDGET" && "$SUSPEND_BUDGET" -gt 0 ]] || SUSPEND_BUDGET="$PROVIDER_TIMEOUT"
if [[ -n "$RUN_DEADLINE" && "$RUN_DEADLINE" -gt 0 ]]; then
  # The redirects are load-bearing, not tidiness: skills invoke this script as `out=$(...)`, and
  # a command substitution does not return until EVERY process holding the pipe closes it. A
  # watchdog that inherited stdout would keep the caller blocked for the whole deadline even
  # after the review finished — the exact hang this watchdog exists to prevent.
  ( sleep "$RUN_DEADLINE"; : > "$DEADLINE_MARKER" 2>/dev/null; kill -TERM $$ 2>/dev/null ) \
    </dev/null >/dev/null 2>&1 &
  WATCHDOG_PID=$!
fi

# Hold off IDLE and disk sleep for the duration (macOS). This does NOT stop a clamshell
# (lid-close) sleep on battery — no userspace process can — which is why the suspend
# DETECTION above exists instead of being replaced by this.
if [[ "${ZUVO_NO_CAFFEINATE:-}" != "1" ]] && command -v caffeinate >/dev/null 2>&1; then
  caffeinate -sim -w $$ >/dev/null 2>&1 &
  CAFFEINATE_PID=$!
fi
return 0
}
