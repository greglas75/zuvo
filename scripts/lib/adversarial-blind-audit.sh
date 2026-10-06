# shellcheck shell=bash
# adversarial-blind-audit.sh — the driver's wiring of --mode blind-audit: input refusal and prompt
# build, the isolation filter on the lane set, answer validation, and the merged report. Every DECISION
# lives in scripts/lib/blind-audit-panel.sh (bap_*), which ar_ba_setup loads; this module only wires it.
# The mode's smaller branches stay inline in the phases they belong to (host vendor mapping, MAX_CHARS,
# PROVIDER_TIMEOUT, the deadline).
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_ba_setup, ar_ba_filter_lanes, ar_ba_validate_answers, ar_ba_report.
#
# Phase bodies sit at column 0, as the top-level code they were cut from: indenting them would change the
# multi-line prompt strings and heredocs several carry. Each runs once, from the driver's Main.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ar_ba_setup — --mode blind-audit: refuse every other input, load blind-audit-panel.sh, build and size the prompt.
ar_ba_setup() {
# ─── --mode blind-audit: ONE production file + its test file, audited by a cross-vendor panel of isolated
# lanes (docs/specs/2026-09-25-blind-audit-panel-plan.md). Every decision is scripts/lib/blind-audit-panel.sh
# (looked up like model-subprocess.sh, and ONLY in this mode); this file only wires it.
BA_AGY_PREFIX='Do not invoke any tools, shell commands, or file operations. Respond with plain text only, using only the information given below.'
if [[ "$REVIEW_MODE" != blind-audit && -n "$BA_PRODUCTION$BA_TEST$BA_PROTOCOL" ]]; then
  echo "ERROR: --production/--test/--protocol belong to --mode blind-audit (this run is --mode $REVIEW_MODE)." >&2; exit 2
elif [[ "$REVIEW_MODE" == blind-audit ]]; then
  _ba_bad=""
  [[ "$INPUT_MODE" == stdin ]] || _ba_bad="--diff/--files"
  [[ -z "$ARTIFACT_PATH" && "$APPEND_ARTIFACT" != true ]] || _ba_bad="${_ba_bad:+$_ba_bad, }--artifact/--append-artifact"
  # stdin is never read here: data on it (a pipe or a file — never a tty or /dev/null) is a caller mistake.
  # The probe is bash's OWN bounded read, so it runs on every PATH: it used to be `timeout 1 head -c 1`,
  # and a PATH without `timeout` (stock macOS has none) skipped the check with only a NOTE — the one
  # invalid input this mode then let through. `-d ''` makes a NUL a byte like any other (and a newline
  # too), so status 0 = a first byte arrived; 1 = EOF, stdin empty; >128 (bash 3.2: 1) = nothing within
  # 1 s — a producer slower than that is missed, harmless: this mode never reads stdin further, the
  # check exists to refuse a caller's mistake, not to gate a real read.
  if [[ -z "$_ba_bad" && "$LIST_PROVIDERS" != true && "$DOCTOR" != true && ( -p /dev/stdin || -f /dev/stdin ) ]]; then
    if IFS= read -r -d '' -t 1 -n 1 _ba_c; then _ba_bad="stdin"; fi
  fi
  if [[ -n "$_ba_bad" ]]; then
    echo "ERROR: --mode blind-audit audits --production + --test and nothing else — refusing $_ba_bad (a blind audit is never a review proof)." >&2; exit 2
  fi
  _ba_fns="bap_find_protocol bap_build_prompt bap_bytes bap_argv_max bap_max_bytes bap_size_class bap_argv_lanes bap_validate bap_merge bap_exit_code bap_vendor_excluded bap_allowlist bap_agy_tools_open bap_timeout bap_deadline bap_run_ceiling bap_ledger_outcomes bap_uncovered_rows bap_json"
  BA_LIB=""
  for _ba_c in ${AR_SCRIPT_DIR:+"$AR_SCRIPT_DIR/lib/blind-audit-panel.sh" "$AR_SCRIPT_DIR/blind-audit-panel.sh"} ${HOME:+"$HOME/.zuvo/blind-audit-panel.sh"}; do
    [[ -f "$_ba_c" ]] || continue
    # shellcheck disable=SC2086  # one function name per word, by design
    unset -f $_ba_fns; _ba_ok=0
    # shellcheck source=/dev/null
    if . "$_ba_c"; then _ba_ok=1; for _ba_f in $_ba_fns; do declare -F "$_ba_f" >/dev/null || _ba_ok=0; done; fi
    if [[ "$_ba_ok" -eq 1 ]]; then BA_LIB="$_ba_c"; break; fi
    echo "  WARN: $_ba_c exists but does not define the panel functions — trying the next candidate" >&2
  done
  if [[ -z "$BA_LIB" ]]; then
    echo "ERROR: --mode blind-audit needs blind-audit-panel.sh — none loaded from ${AR_SCRIPT_DIR:-<the script dir, unresolved>}/lib/, next to this script or ~/.zuvo/. Reinstall: ./scripts/install.sh" >&2; exit 2
  fi
  if [[ "$LIST_PROVIDERS" != true && "$DOCTOR" != true ]]; then
    [[ -n "$BA_PRODUCTION" && -n "$BA_TEST" ]] || { echo "ERROR: --mode blind-audit needs --production <file> and --test <file>." >&2; exit 2; }
    for _ba_f in "$BA_PRODUCTION" "$BA_TEST"; do
      [[ -f "$_ba_f" && -r "$_ba_f" ]] || { echo "ERROR: --mode blind-audit: not a readable file: $_ba_f" >&2; exit 2; }
      [[ -s "$_ba_f" ]] || { echo "Blind audit: NO AUDITABLE MATERIAL — $_ba_f is empty. Nothing was sent to any lane; this is NOT an audit." >&2; exit 5; }
    done
    _ba_proto="$(bap_find_protocol "${AR_SCRIPT_DIR:-/nonexistent}" ${BA_PROTOCOL:+--protocol "$BA_PROTOCOL"})" || exit 2
    # The sentinel keeps the prompt's final newline through $( ): every lane gets exactly these bytes.
    BA_PROMPT="$(bap_build_prompt "$_ba_proto" "$BA_PRODUCTION" "$BA_TEST" && printf x)" || exit 2
    BA_PROMPT="${BA_PROMPT%x}"
    BA_PROMPT_BYTES="$(printf '%s' "$BA_PROMPT" | bap_bytes)" || exit 2
    _ba_size="$(bap_size_class "$BA_PROMPT_BYTES")" || exit 2
    if [[ "$_ba_size" == too-large ]]; then
      echo "ERROR: --mode blind-audit: the prompt is $BA_PROMPT_BYTES bytes, over the $(bap_max_bytes)-byte limit (ZUVO_BLIND_AUDIT_MAX_BYTES). Nothing is ever shortened, so nothing was sent — audit a smaller file pair." >&2; exit 6
    fi
    [[ "$_ba_size" != over-argv ]] || BA_ARGV_DROP="$(bap_argv_lanes)"
    # agy's argument is the no-tools line + a blank line + the prompt: measured as it is sent.
    BA_AGY_ARG_BYTES="$(printf '%s\n\n%s' "$BA_AGY_PREFIX" "$BA_PROMPT" | bap_bytes)" || exit 2
    if [[ "$(bap_size_class "$BA_AGY_ARG_BYTES")" != ok && " $BA_ARGV_DROP " != *" agy "* ]]; then
      BA_ARGV_DROP="${BA_ARGV_DROP:+$BA_ARGV_DROP }agy"
    fi
  fi
fi
return 0
}

# ar_ba_filter_lanes — --mode blind-audit: keep only lanes with proven isolation; --list-providers prints them.
ar_ba_filter_lanes() {
# --mode blind-audit admits only lanes with PROVEN isolation (bap_allowlist; mock-* only in the test harness),
# agy only while its own settings keep tools closed, no argv lane over the argv limit — each drop is loud.
if [[ "$REVIEW_MODE" == blind-audit ]]; then
  ba_drop() {   # ba_drop <reason> <lane>... — take those lanes out of PROVIDERS, loudly
    local why="$1" gone; shift
    gone="$(lanes_filter keep "$PROVIDERS" "$*")"
    PROVIDERS="$(lanes_filter drop "$PROVIDERS" "$*")"
    [[ -z "$gone" ]] || { echo "  Blind audit: excluding $gone — $why" >&2; BA_DROPPED="${BA_DROPPED:+$BA_DROPPED }$gone"; }
  }
  # bap_allowlist prints NOTHING and returns 1 when ZUVO_BLIND_AUDIT_ALLOWLIST refused every lane it named
  # (its own stderr line names them). A bare `x="$(bap_allowlist)"` would then abort the whole run right
  # here under `set -e`, before the no-lane report; an empty allowlist is the graceful outcome instead —
  # every candidate is dropped below, loudly, and the run ends at the no-provider ERROR (exit 1). Any
  # other failure reads the same way: fail closed, nothing unproven runs.
  _ba_allow="$(bap_allowlist)" || _ba_allow=""
  _ba_allow=" $_ba_allow "; _ba_out=""
  set -f
  for _p in $PROVIDERS; do
    case "$_ba_allow" in *" $_p "*) ;; *) [[ "$_p" == mock-* && "${ZUVO_ADVERSARIAL_TEST_HARNESS:-}" == 1 ]] || _ba_out="$_ba_out $_p" ;; esac
  done
  # shellcheck disable=SC2086  # a lane list, one name per word
  ba_drop "isolation not proven for a blind audit (not on the allowlist)" $_ba_out
  set +f
  _ba_agy_cfg="${HOME:-/nonexistent}/.gemini/antigravity-cli/settings.json"
  if [[ " $PROVIDERS " == *" agy "* ]] && bap_agy_tools_open "$_ba_agy_cfg"; then
    ba_drop "$_ba_agy_cfg has a permissions.allow rule (or cannot be read): it would re-open the tools this mode keeps closed" agy
  fi
  # shellcheck disable=SC2086  # a lane list, one name per word
  [[ -z "$BA_ARGV_DROP" ]] || ba_drop "its argument is over the $(bap_argv_max)-byte argv limit (ZUVO_BLIND_AUDIT_ARGV_MAX; prompt $BA_PROMPT_BYTES bytes, agy's with its no-tools line $BA_AGY_ARG_BYTES); stdin lanes still run" $BA_ARGV_DROP
  if [[ "$LIST_PROVIDERS" == true ]]; then
    printf '%s\n' "$PROVIDERS" | tr ' ' '\n' | sed '/^$/d'
    exit 0
  fi
fi
return 0
}

# ar_ba_validate_answers — --mode blind-audit: an answer without a valid strict block becomes `invalid`.
ar_ba_validate_answers() {
# --mode blind-audit: an answer counts only as a valid strict block (bap_validate). One that is not is
# outcome `invalid` — never a review, never `ok` in the ledger — and its reply joins the failure evidence
# (err_*.txt is what preserve_failure_evidence keeps); PROVIDER_COUNT counts the VALID answers only.
if [[ "$REVIEW_MODE" == blind-audit ]]; then
  BA_VALID=""
  for p in $PROVIDERS; do
    lane_ok "$p" || continue
    if bap_validate "$JSON_TMPDIR/result_$p.txt" > /dev/null; then BA_VALID="${BA_VALID:+$BA_VALID }$p"; continue; fi
    echo "  WARN: $p answered without a valid strict block — counted as invalid" >&2
    _o=",$PROVIDER_OUTCOMES,"; _n=",$p:invalid,"; _o="${_o/",$p:ok,"/$_n}"; _o="${_o#,}"; PROVIDER_OUTCOMES="${_o%,}"
    cp -- "$JSON_TMPDIR/result_$p.txt" "$JSON_TMPDIR/err_$p.invalid-reply.txt" 2>/dev/null || true
  done
  PROVIDER_COUNT=$(echo "$BA_VALID" | wc -w | tr -d ' ')
fi
return 0
}

# ar_ba_report — --mode blind-audit: the merged block (or --json) on stdout, one log row per lane, exit 0/3/2/124/125.
ar_ba_report() {
# ─── --mode blind-audit: stdout is the ONE merged block (--json: bap_json's document); exit 0/3/2 by valid
# count — 124/125 when nothing answered at all, as in the other modes. One adversarial.log row per lane,
# findings = the uncovered rows it contributed. No finding counting, SUMMARY row or review artifact.
if [[ "$REVIEW_MODE" == blind-audit ]]; then
  ba_outcome() { printf '%s\n' "$PROVIDER_OUTCOMES" | tr ',' '\n' | awk -F: -v p="$1" '$1 == p { print $2; exit }'; }
  _ba_args=(); _ba_answered=(); _ba_merged="$JSON_TMPDIR/blind-audit.block"; _ba_mf=""
  for p in $PROVIDERS; do
    _o="$(ba_outcome "$p")"
    if lane_ok "$p"; then _ba_args+=("$p=$JSON_TMPDIR/result_$p.txt"); else _ba_args+=(--failed "$p:${_o:-empty}"); fi
    [[ "$_o" != ok && "$_o" != invalid ]] || _ba_answered+=("$p=$JSON_TMPDIR/result_$p.txt")
  done
  _ba_exit="$(bap_exit_code "$PROVIDER_COUNT")"; _ba_status=none
  case "$_ba_exit" in 0) _ba_status=strict ;; 3) _ba_status=degraded ;; esac
  if [[ "$PROVIDER_COUNT" -eq 0 && -z "$ALL_RESULTS" ]]; then
    if [[ "$(suspended_seconds "$(( $(date +%s) - START_TIME ))" "$SUSPEND_BUDGET")" -ge "$SUSPEND_THRESHOLD" ]]; then _ba_exit=125; _ba_status=suspended
    elif [[ "$TIMEOUT_COUNT" -gt 0 ]]; then _ba_exit=124; _ba_status=timeout; fi
  fi
  : > "$_ba_merged"
  # bap_merge/bap_json's own exit 2 is a USAGE error (malformed args) — unreachable today from this call
  # site (PROVIDER_COUNT>0 already verified, and every arg here is internally well-formed), but if it
  # ever fired, the per-lane log loop below is the one thing this run most needs a trail for. So an
  # internal failure here is deferred to AFTER the log loop, not `exit`ed on the spot.
  _ba_merge_rc=0; _ba_json_rc=0
  if [[ "$PROVIDER_COUNT" -gt 0 ]]; then
    bap_merge "${_ba_args[@]}" > "$_ba_merged" || _ba_merge_rc=$?
    [[ "$_ba_merge_rc" -ne 0 ]] || _ba_mf="$_ba_merged"
  else
    preserve_failure_evidence
    echo "ERROR: blind audit: no valid answer from any lane (outcomes: ${PROVIDER_OUTCOMES:-none})$(_ar_evidence_note "replies and stderr")" >&2
  fi
  if [[ "$_ba_merge_rc" -eq 0 ]]; then
    if [[ "$OUTPUT_FORMAT" == json ]]; then
      bap_json "$_ba_status" "$BA_VALID" "${PROVIDER_OUTCOMES:-none}" "$BA_PROMPT_BYTES" "$BA_ARGV_DROP" "$_ba_mf" \
        ${_ba_answered[@]+"${_ba_answered[@]}"} || _ba_json_rc=$?
    else
      cat "$_ba_merged"
    fi
  fi
  ( umask 077; printf '%s' "$INPUT" > "$INPUT_FILE" ) 2>/dev/null || true   # owner-only: it is the reviewed diff
  _ba_dur=$(( $(date +%s) - START_TIME ))
  for p in $PROVIDERS; do
    _n=0; _b=0; _x=1; _o="$(ba_outcome "$p")"; _d="$(cat "$JSON_TMPDIR/dur_$p.txt" 2>/dev/null || true)"
    if lane_ok "$p"; then _x=0; _n="$(bap_uncovered_rows "$_ba_merged" "$p")" || _n=0; fi
    [[ ! -s "$JSON_TMPDIR/result_$p.txt" ]] || _b="$(wc -c < "$JSON_TMPDIR/result_$p.txt" | tr -d ' ')"
    adversarial_log_row "$(provider_model "$p")" "$_ba_dur" "$_x" "$_b" 0 0 0 "$p" "${_o:-not-attempted}" "${_d:-0}" "$_n"
  done
  # A merge/json failure is never silent, and it never hides what the PANEL did: the ERROR names the
  # failing step and its rc, and the panel's own outcome (status, valid count, the exit it would have
  # had). The exit is still 2 — 0 and 3 promise the merged block on stdout, and there is none — so a
  # degraded or strict panel is reported here, in words, not by an exit code that would lie about stdout.
  if [[ "$_ba_merge_rc" -ne 0 || "$_ba_json_rc" -ne 0 ]]; then
    if [[ "$_ba_merge_rc" -ne 0 ]]; then _ba_step="bap_merge (rc=$_ba_merge_rc)"; else _ba_step="bap_json (rc=$_ba_json_rc)"; fi
    echo "ERROR: blind audit: $_ba_step failed — nothing on stdout, exit 2; the panel itself was $_ba_status with $PROVIDER_COUNT valid answer(s) (exit $_ba_exit withheld) — per-lane rows are in the adversarial log" >&2
    exit 2
  fi
  exit "$_ba_exit"
fi
return 0
}
