# shellcheck shell=bash
# adversarial-report.sh — the end of a run: the review artifact (REVIEW BY: proofs, reviewed blobs),
# the no-review path and its classification, finding counts, the output (JSON document or text
# banners), the per-lane run-log rows, the SUMMARY row and the exit code (4 for truncated input).
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_report_no_review, ar_count_findings, ar_warn_clean_large_input, ar_build_output,
# ar_emit_output, ar_log_run, ar_log_summary_and_exit. Functions: write_artifact, _ar_keep_pass,
# _ar_json_add_lane.
#
# Phase bodies sit at column 0, as the top-level code they were cut from (afd4ed0d, byte for byte then):
# indenting them would change the multi-line prompt strings and heredocs several carry, and made the
# move provable by diff. Each runs once, from the driver's Main, at the point it used to.
# ar_log_summary_and_exit is the single file's last block and ends the run itself (exit 4 or 0), so it
# alone has no `return 0`.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ─── Execute ───────────────────────────────────────────────────

# META_CLEAN_LINES — the input length (lines) past which a review every lane passed clean draws the
# possible-false-negative WARN (ar_warn_clean_large_input).
META_CLEAN_LINES=150

write_artifact() {
  local artifact_path="$1"
  local final_output="$2"

  # Before the early return, so the fact is established before the evidence file is composed.
  # write_artifact is only REACHED when an artifact was requested, so the unconditional call sits
  # at the end of the run as well — the check is idempotent and prints once either way.
  _tamper_verify

  [[ -z "$artifact_path" ]] && return 0
  local tmp_out="${artifact_path}.zuvo-tmp.$$"

  mkdir -p "$(dirname "$artifact_path")"

  # Why only one provider ran — the single most misread field downstream. "1 provider" can mean
  # a deliberate --single, everyone-else-excluded, or three providers dying quietly; a gate that
  # cannot tell them apart treats a collapsed review as a passing one.
  local single_note=""
  if [[ "$PROVIDER_COUNT" -le 1 ]]; then
    if [[ "$MULTI_MODE" == "single" || "$MULTI_MODE" == "rotate" ]]; then
      single_note="by design (--${MULTI_MODE})"
    elif [[ "$ATTEMPTED_COUNT" -le 1 ]]; then
      single_note="only $ATTEMPTED_COUNT provider available after exclusions${EXCLUDE_PROVIDER:+ (--exclude: $EXCLUDE_PROVIDER)}${CACHED_FAILED:+ (auth-cached: $CACHED_FAILED)}"
    else
      single_note="$((ATTEMPTED_COUNT - PROVIDER_COUNT)) of $ATTEMPTED_COUNT providers produced no review — see provider_outcomes"
    fi
  fi

  {
    printf 'artifact_kind=adversarial-review\n'
    printf 'created_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'status=%s\n' "${FINAL_STATUS:-ok}"
    printf 'mode=%s\n' "$REVIEW_MODE"
    printf 'output_format=%s\n' "$OUTPUT_FORMAT"
    printf 'providers_used=%s\n' "$PROVIDERS_USED"
    printf 'provider_count=%s\n' "$PROVIDER_COUNT"
    printf 'providers_attempted=%s\n' "${ATTEMPTED_COUNT:-0}"
    printf 'provider_outcomes=%s\n' "${PROVIDER_OUTCOMES:-none}"
    # Canonical proof-of-work markers. pipeline-gate-lib.sh :: pg_artifact_proven counts
    # `REVIEW BY:` lines to decide whether a review actually happened. They used to be emitted
    # only by the MULTI dispatch path's body banner, so every --single / --rotate / --json run
    # produced an artifact with ZERO markers and had its genuine review refused by the gate.
    # Emitting them here makes them independent of dispatch mode AND output format (a JSON body
    # stays valid JSON), and exactly one per provider that actually returned a review.
    if [[ -n "$PROVIDERS_USED" ]]; then
      # `printf '%s\n'` — NOT '%s': `while read` never runs its body for a final unterminated
      # line, which silently emitted zero markers (caught by PROV.12-15).
      printf '%s\n' "$PROVIDERS_USED" | tr ',' '\n' | while IFS= read -r _prov; do
        _prov="$(printf '%s' "$_prov" | tr -d ' ')"
        [[ -n "$_prov" ]] && printf 'REVIEW BY: %s\n' "$(printf '%s' "$_prov" | tr '[:lower:]' '[:upper:]')"
      done
    fi
    [[ -n "$single_note" ]] && printf 'single_provider_note=%s\n' "$single_note"
    # A review that edited the tree it reviewed is a fact about this artifact's trustworthiness,
    # so it is recorded IN the artifact, next to the REVIEW BY: lines a gate reads — not only on a
    # stderr stream that nobody keeps.
    [[ -n "$TAMPER_NOTE" ]] && printf 'tree_modified_during_review=%s\n' "$TAMPER_NOTE"
    # CONTENT BINDING (B-noverify-hardening #3). The pre-commit gate used to decide whether this
    # artifact was fresh by comparing FILE MTIMES: artifact vs the newest staged path in the
    # working tree. Those are two different things. A commit stages BLOBS from the index, and a
    # path's working-tree mtime says nothing about what its index entry contains — stage an older
    # file's content, or restore a mtime, and a review of entirely different bytes passes the gate.
    # So record what was actually reviewed, by content. `build-review-patch` feeds this a
    # `git diff HEAD` snapshot (worktree vs HEAD, plus untracked), so the reviewed bytes are the
    # WORKING TREE — hash exactly those.
    #
    # Matching is on the blob-OID SET, not on path->oid pairs: a set needs no filename encoding, so
    # paths with spaces or newlines cannot break it. Residue: content reviewed at path A and staged
    # at path B passes. The bytes were still reviewed, and this is the best-effort layer — CI is
    # the server-side guarantee.
    # WHAT WAS REVIEWED, not what happens to be dirty. The first cut always enumerated the whole
    # working tree — so under `--files <subset>` any OTHER file that was dirty at review time got
    # its blob written into reviewed_blob=, and pre-commit-adversarial-gate.sh treats that list as
    # a WHITELIST. Content no reviewer ever saw could then be staged and pass the content-binding
    # gate: the exact bypass this feature exists to close, reintroduced by the recorder's scope.
    # Reproduced with a mock provider (`--files A.txt`, B.txt dirty → both blobs recorded).
    #
    # So when the caller named the files, record those. Only the stdin/whole-diff path — where the
    # input genuinely IS the working-tree diff — falls back to enumerating the tree.
    if _zar_top="$(git rev-parse --show-toplevel 2>/dev/null)"; then
      _zar_paths=()
      # Files mode records ONLY what reached the providers: COLLECTED_BLOBS, the ids collect_files_input
      # took of the bytes it put into the input — never the tree-walk below, even if that list came out
      # empty (an empty list claims nothing, a tree walk would claim files no provider was shown), and never
      # the named files hashed again now (an edit made during the review would be recorded as reviewed).
      if [[ "${INPUT_MODE:-}" == "files" ]]; then
        while IFS= read -r _zar_oid; do
          [[ -n "$_zar_oid" ]] && printf 'reviewed_blob=%s\n' "$_zar_oid"
        done <<< "$COLLECTED_BLOBS"
      else
      while IFS= read -r -d '' _zar_p; do
        [[ -n "$_zar_p" && -f "$_zar_top/$_zar_p" ]] && _zar_paths+=("$_zar_top/$_zar_p")
      done < <( { git -C "$_zar_top" -c core.quotePath=false diff HEAD --name-only -z --diff-filter=ACMR 2>/dev/null
                  git -C "$_zar_top" -c core.quotePath=false ls-files --others --exclude-standard -z 2>/dev/null; } )
      fi
      if [[ "${#_zar_paths[@]}" -gt 0 ]]; then
        # One call for all paths — N forks on a large changeset would show up as review latency.
        git hash-object -- "${_zar_paths[@]}" 2>/dev/null \
          | while IFS= read -r _zar_oid; do
              [[ -n "$_zar_oid" ]] && printf 'reviewed_blob=%s\n' "$_zar_oid"
            done
      fi
    fi
    printf 'input_chars=%s\n' "${#INPUT}"
    printf 'input_chars_original=%s\n' "${ORIG_CHARS:-${#INPUT}}"
    printf 'input_truncated=%s\n' "${INPUT_TRUNCATED:-false}"
    printf 'total_findings=%s\n' "$TOTAL_FINDINGS"
    printf 'critical=%s\n' "$CRITICAL_COUNT"
    printf 'warning=%s\n' "$WARNING_COUNT"
    printf 'info=%s\n' "$INFO_COUNT"
    # Counts cover recognized severity records; the full provider output remains below.
    printf 'count_method=severity-records\n'
    printf 'count_status=%s\n' "${COUNT_STATUS:-unavailable}"
    printf 'known_findings_supplied=%s\n' "$(printf '%s' "$KNOWN_FINDINGS" | grep -c . || true)"
    printf -- '---\n'
    printf '%s\n' "$final_output"
  } > "$tmp_out"

  if [[ "$APPEND_ARTIFACT" == true ]]; then
    # Rotation passes: keep every pass. Read, append, move into place — under a lock, because two runs
    # appending to one artifact at once (parallel passes, a chunked review's children) each read the old
    # file and the later mv erased the earlier pass's proof. Each step is checked: the group's status was
    # its last `cat`'s, so an artifact that could not be read was replaced by this pass alone. A pass that
    # cannot go in is kept beside the artifact, never written over the passes already in it. The temp file
    # makes an interrupted append unable to leave a half-written artifact a gate would read.
    # Status 1 whenever this pass did NOT land in the artifact (kept beside it, or lost): the caller then
    # fails the run as it does for an artifact that cannot be written at all — the artifact a gate reads
    # lacks this pass's REVIEW BY lines. It was 0 on every such path, the final mv unchecked included.
    local _lk=0 _landed=1
    _ar_lock "$artifact_path.lock" "$(ar_env_int ZUVO_ARTIFACT_LOCK_WAIT 30 1)" || _lk=$?
    if [[ "$_lk" -ne 0 ]]; then
      if [[ "$_lk" -eq 2 ]]; then _ar_keep_pass "$artifact_path" "$tmp_out" "cannot be locked (its directory is not writable)"
      else _ar_keep_pass "$artifact_path" "$tmp_out" "is being appended to by another run"; fi
      return 1
    fi
    if [[ -s "$artifact_path" ]] && ! { { cat "$artifact_path" \
          && printf '\n=== APPENDED PASS %s ===\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
          && cat "$tmp_out"; } > "$tmp_out.merged" && mv -f "$tmp_out.merged" "$tmp_out"; }; then
      rm -f "$tmp_out.merged"
      _ar_keep_pass "$artifact_path" "$tmp_out" "could not be read and appended to"; _landed=0
    elif ! mv -f "$tmp_out" "$artifact_path" 2>/dev/null; then
      _ar_keep_pass "$artifact_path" "$tmp_out" "could not be replaced"; _landed=0
    fi
    _ar_unlock "$artifact_path.lock"
    [[ "$_landed" -eq 1 ]]
    return
  fi
  mv -f "$tmp_out" "$artifact_path"
}

# _ar_keep_pass <artifact> <pass-file> <why> — a pass that cannot go into <artifact> is kept beside it as
# <artifact>.pass-<time>-<pid>, said in a WARN; never written over the passes already in <artifact>.
_ar_keep_pass() {
  local kept
  kept="$1.pass-$(date -u +%Y%m%dT%H%M%SZ)-$$"
  if mv -f "$2" "$kept" 2>/dev/null; then
    echo "  WARN: $1 $3 — this pass is kept as $kept (append it by hand)" >&2
  else
    rm -f "$2"
    echo "  WARN: $1 $3, and this pass could not be kept beside it — it is not recorded" >&2
  fi
}

# ar_report_no_review — no lane answered: classify it (suspended/timeout/error), keep the evidence, log, exit 125/124/2.
ar_report_no_review() {
if [[ -z "$ALL_RESULTS" ]]; then
  TOTAL_FINDINGS=0
  CRITICAL_COUNT=0
  WARNING_COUNT=0
  INFO_COUNT=0
  # Log failed run (per-provider format)
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  DISPATCHED_COUNT=$(dispatched_count "$DISPATCHED_LIST")
  SUSPENDED_S=$(suspended_seconds "$DURATION" "$SUSPEND_BUDGET")

  # ── Classify the failure. "Every provider returned nothing" has at least three causes and
  # they call for different actions, but until now they all collapsed into one exit code and
  # one message ("All providers failed"), which downstream skills relay as BLOCKED_INFRA:
  #   suspended — the HOST was asleep mid-run. Nothing was wrong with any provider and a
  #               retry is free. 41 of the last 229 all-fail events look like this.
  #   timeout   — providers were reachable and too slow. Retrying costs the same again.
  #   error     — providers were reached and refused/failed. Read the preserved stderr.
  # Suspension wins the tie: a provider cannot be blamed for a laptop with a closed lid.
  if [[ "$SUSPENDED_S" -ge "$SUSPEND_THRESHOLD" ]]; then
    FINAL_STATUS="suspended"; FAIL_EXIT=125; FAIL_OUTCOME="suspended"
  elif [[ "$TIMEOUT_COUNT" -gt 0 ]]; then
    FINAL_STATUS="timeout";   FAIL_EXIT=124; FAIL_OUTCOME="all-timeout"
  else
    FINAL_STATUS="error";     FAIL_EXIT=2;   FAIL_OUTCOME="all-failed"
  fi

  # Keep the providers' stderr before cleanup deletes the tmpdir, so the message below can
  # point at it and the "<30s rejection" class stops being undiagnosable.
  preserve_failure_evidence

  mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null || true
  ( umask 077; printf '%s' "$INPUT" > "$INPUT_FILE" ) 2>/dev/null || true   # owner-only: it is the reviewed diff
  adversarial_log_row "none" "$DURATION" "$FAIL_EXIT" 0 0 0 0 "none" "$FAIL_OUTCOME" "$DURATION"

  case "$FINAL_STATUS" in
    suspended)
      _fail_note="host suspended for ~${SUSPENDED_S}s mid-run (sleep/lid-close) — providers were never given a chance; this run is safe to repeat"
      _fail_text="Adversarial review: skipped (host suspended ${SUSPENDED_S}s — retry)" ;;
    timeout)
      _fail_note="every provider exceeded ${PROVIDER_TIMEOUT}s"
      _fail_text="Adversarial review: skipped (timeout)" ;;
    *)
      # "reached" is false when no lane could start (_ar_no_lane_note says why); none of them ran.
      _nl_note="$(_ar_no_lane_note)"
      if [[ -n "$_nl_note" ]]; then
        _fail_note="${_nl_note}$(_ar_evidence_note)"
      else
        _fail_note="every provider was reached and returned no review$(_ar_evidence_note)"
      fi
      _fail_text="Adversarial review: skipped (provider error)" ;;
  esac

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    FINAL_OUTPUT=$(jq -n \
      --arg status "$FINAL_STATUS" \
      --arg mode "$REVIEW_MODE" \
      --arg providers "$PROVIDERS" \
      --arg outcomes "${PROVIDER_OUTCOMES:-none}" \
      --arg note "$_fail_note" \
      --arg evidence "${FAILURE_EVIDENCE_DIR:-}" \
      --argjson attempted "$ATTEMPTED_COUNT" \
      --argjson dispatched "$DISPATCHED_COUNT" \
      --argjson count "$TIMEOUT_COUNT" \
      --argjson suspended "$SUSPENDED_S" \
      --argjson retryable "$([[ "$FINAL_STATUS" == "suspended" ]] && echo true || echo false)" \
      --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      '{status: $status, mode: $mode, providers_attempted: $providers, providers_attempted_list: ($providers | split(" ")), attempted_count: $attempted, dispatched_count: $dispatched, timeout_count: $count, provider_count: 0, provider_outcomes: $outcomes, suspended_seconds: $suspended, retryable: $retryable, note: $note, evidence_dir: $evidence, findings: [], date: $date}')
  else
    FINAL_OUTPUT="$_fail_text"
  fi

  echo "ERROR: no review produced — $_fail_note. Tried: $PROVIDERS (outcomes: ${PROVIDER_OUTCOMES:-none})" >&2

  if [[ -n "$ARTIFACT_PATH" ]]; then
    write_artifact "$ARTIFACT_PATH" "$FINAL_OUTPUT" \
      || { echo "ERROR: Failed to write adversarial artifact to $ARTIFACT_PATH" >&2; exit "$FAIL_EXIT"; }
  fi
  printf '%s\n' "$FINAL_OUTPUT"
  exit "$FAIL_EXIT"
fi
return 0
}

# ar_count_findings — count every answering lane's findings and write its findings-ledger rows.
ar_count_findings() {
# ─── Count findings (before output, while temp files still exist) ──

TOTAL_FINDINGS=0
CRITICAL_COUNT=0
WARNING_COUNT=0
INFO_COUNT=0
COUNT_STATUS=complete
for p in $PROVIDERS; do
  result_file="$JSON_TMPDIR/result_${p}.txt"
  if lane_ok "$p"; then
    read -r c w i count_status < <(count_findings "$result_file")
    if [[ "$count_status" != "complete" ]]; then
      COUNT_STATUS=partial
      echo "WARN: $p finding counts are incomplete; inspect the full review before treating it as clean." >&2
    fi
    printf '%s %s %s\n' "$c" "$w" "$i" > "$JSON_TMPDIR/counts_${p}.txt"
    CRITICAL_COUNT=$((CRITICAL_COUNT + c))
    WARNING_COUNT=$((WARNING_COUNT + w))
    INFO_COUNT=$((INFO_COUNT + i))
    # Here, not in the output block: this loop is the last point the per-provider result files
    # are guaranteed to exist, and already the point where findings are attributed to a lane.
    # `|| true`: provider_model runs under `set -e`, and the ledger must never fail a review.
    findings_log_rows "$p" "$(provider_model "$p" 2>/dev/null || true)" "$result_file" || true
  fi
done
TOTAL_FINDINGS=$((CRITICAL_COUNT + WARNING_COUNT + INFO_COUNT))
return 0
}

# ar_warn_clean_large_input — --json: warn when every lane came back clean on a large input.
ar_warn_clean_large_input() {
# ─── Meta-review: warn on clean pass for large diffs ───────────

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  # Check if ALL results are clean (no findings) on a large input
  input_lines=$(printf '%s' "$INPUT" | awk 'END { print NR }')   # wc -l missed a last line with no newline
  all_clean=true
  for p in $PROVIDERS; do
    result_file="$JSON_TMPDIR/result_${p}.txt"
    if lane_ok "$p"; then
      # Check for clean markers — inverted logic avoids false positives from "No CRITICAL issues"
      if grep -qiE 'NO ISSUES FOUND|"findings":\s*\[\]' "$result_file" 2>/dev/null; then
        : # this provider found nothing
      else
        all_clean=false
      fi
    fi
  done
  # META_CLEAN_LINES: an input this long that EVERY lane passed clean is more likely a miss than a clean change.
  if [[ "$all_clean" == "true" && "$input_lines" -gt $META_CLEAN_LINES ]]; then
    echo "  ⚠ META: Clean pass on ${input_lines}-line diff — possible false negative. Consider zuvo:review for multi-provider check." >&2
  fi
fi
return 0
}

# _ar_evidence_note [<what>] — where the failure evidence is, as the tail of the failure line: " — <what> kept in
# <dir>" (default "stderr"), or, when nothing of it reached the dir (copies refused — a full disk, a quota — or only
# empty stderr), what the dir does hold. Nothing without one. One helper for every failure line that names the dir.
_ar_evidence_note() {
  local what="${1:-stderr}"
  [[ -n "${FAILURE_EVIDENCE_DIR:-}" ]] || return 0
  if [[ "${FAILURE_EVIDENCE_STDERR:-0}" -eq 1 ]]; then printf ' — %s kept in %s' "$what" "$FAILURE_EVIDENCE_DIR"
  else printf " — the run's record kept in %s (no %s to keep: none copied, or all empty)" "$FAILURE_EVIDENCE_DIR" "$what"; fi
}

# _ar_no_lane_note — when NO lane could start, the line that says why, every cause named: no-runner (the shared
# runner did not load: the install is the fault) and no-key (the lane has no usable API key: the configuration
# is). Nothing when any lane was reached. A run mixing the two named only the keys, and the reader fixed them to
# find the runner still missing.
_ar_no_lane_note() {
  local o nr=0 nk="" why=""
  [[ -n "$PROVIDER_OUTCOMES" ]] || return 0
  for o in $(printf '%s' "$PROVIDER_OUTCOMES" | tr ',' ' '); do
    case "$o" in
      *:no-runner) nr=1 ;;
      *:no-key)    nk="${nk:+$nk, }${o%:no-key}" ;;
      *)           return 0 ;;
    esac
  done
  [[ "$nr" -eq 0 ]] || why="the shared runner model-subprocess.sh was not loaded (reinstall: ./scripts/install.sh)"
  [[ -z "$nk" ]] || why="${why:+$why; }no usable API key for: $nk"
  printf 'no lane could run — %s\n' "$why"
}

# _ar_json_add_lane <lane> <result file> — adds the lane's model to json_models and its answer to
# $json_results_file; status 1, with NEITHER added, when a step fails. Every step is checked: under errexit
# a failed jq in the models line ended the run after the review had finished — no document at all — and a
# failed jq in the results step left .next empty, which the unconditional mv put in place: "results": null
# with status ok, every lane's answer gone and nothing said.
_ar_json_add_lane() {
  local p="$1" result_file="$2" models cleaned
  models=$(printf '%s' "$json_models" | jq --arg k "$p" --arg v "$(provider_model "$p")" '. + {($k): $v}') || return 1
  # The JSON the answer carries, read exactly as the counts read it (result_json_text: its json-fenced blocks,
  # else its bare-fenced ones, else all of it). A sed of its own here took other fence shapes than the counts:
  # an answer counted as findings was stored as a string, its findings in no document a caller parses.
  cleaned=$(result_json_text "$result_file") || return 1
  printf '%s' "$cleaned" > "$JSON_TMPDIR/json-answer.txt" || return 1
  # Parse it as JSON: one JSON text is stored as itself, several — a lane that printed two objects — as their
  # array (--argjson used to abort the run). An answer that is not JSON is stored as a string, exactly as the
  # lane wrote it — fences, blank lines and all (it used to be stored with them stripped). That includes an
  # answer that is only fences: `jq .` accepts empty input, and the lane's entry became [].
  if [[ -n "${cleaned//[[:space:]]/}" ]] && jq . "$JSON_TMPDIR/json-answer.txt" &>/dev/null; then
    jq --slurpfile v "$JSON_TMPDIR/json-answer.txt" --arg k "$p" \
      '. + {($k): (if ($v | length) == 1 then $v[0] else $v end)}' "$json_results_file" > "$json_results_file.next" || return 1
  else
    jq --rawfile v "$result_file" --arg k "$p" '. + {($k): $v}' "$json_results_file" > "$json_results_file.next" || return 1
  fi
  mv -f "$json_results_file.next" "$json_results_file" || return 1
  json_models="$models"
}

# ar_build_output — FINAL_OUTPUT and FINAL_STATUS: the JSON document or the text banners.
ar_build_output() {
# ─── Output ─────────────────────────────────────────────────────

FINAL_OUTPUT=""

# D2 / Task 6: compute DERIVED_STATUS once, regardless of output format. Used by
# both the JSON status field and the SUMMARY log row. Without this hoist the
# SUMMARY for text-output runs would always log "ok" even when partial.
# Measured against providers actually DISPATCHED, not candidates. --single stops at the first
# success by design, so comparing against the candidate list reported every healthy single run
# as "partial" (302 of 536 runs on 2026-07-30 alone) and taught readers to ignore the field.
DISPATCHED_COUNT=$(dispatched_count "$DISPATCHED_LIST")
[[ "$DISPATCHED_COUNT" -gt 0 ]] || DISPATCHED_COUNT="$ATTEMPTED_COUNT"
if [[ "$PROVIDER_COUNT" -eq "$DISPATCHED_COUNT" ]]; then
  DERIVED_STATUS="ok"
else
  DERIVED_STATUS="partial"
fi
FINAL_STATUS="$DERIVED_STATUS"

if [[ "$OUTPUT_FORMAT" == "json" ]]; then
  # JSON output: build with jq for safety (no injection from provider output)
  # Every answer, and the results object growing from them, reaches jq as a FILE (--slurpfile /
  # --rawfile), never as an argv string: Linux caps one argv string at 128 KiB (MAX_ARG_STRLEN), and a
  # 200 KB answer made jq fail with E2BIG after the review had finished — no document, no artifact.
  json_results_file="$JSON_TMPDIR/json-results.json"
  printf '{}' > "$json_results_file"
  # The model each answering lane ran, as the log row records it: a caller that pinned a model can
  # check it was honoured instead of trusting its own configuration.
  json_models="{}"
  json_dropped=""
  for p in $PROVIDERS; do
    result_file="$JSON_TMPDIR/result_${p}.txt"
    if lane_ok "$p" && ! _ar_json_add_lane "$p" "$result_file"; then
      rm -f "$json_results_file.next"
      json_dropped="${json_dropped:+$json_dropped }$p"
    fi
  done
  if [[ -n "$json_dropped" ]]; then
    echo "  WARN: the JSON document leaves out the answer of: $json_dropped (jq could not add it) — status is partial" >&2
    DERIVED_STATUS="partial"; FINAL_STATUS="partial"
    # A lane whose answer is not in the document is not credited for it either: its counts come off the
    # totals, and it leaves providers_used — the list write_artifact turns into the REVIEW BY lines a gate
    # reads. A gate used to see a REVIEW BY and finding counts for an answer the artifact's body lacked.
    for p in $json_dropped; do
      if [[ -r "$JSON_TMPDIR/counts_${p}.txt" ]] && read -r c w i < "$JSON_TMPDIR/counts_${p}.txt"; then
        CRITICAL_COUNT=$((CRITICAL_COUNT - c)); WARNING_COUNT=$((WARNING_COUNT - w)); INFO_COUNT=$((INFO_COUNT - i))
      fi
      PROVIDERS_USED="$(printf '%s\n' "$PROVIDERS_USED" | tr ',' '\n' | sed 's/^ *//; s/ *$//' \
        | awk -v p="$p" '$0 != "" && $0 != p' | paste -sd, - | sed 's/,/, /g')"
      PROVIDER_COUNT=$((PROVIDER_COUNT - 1))
    done
    TOTAL_FINDINGS=$((CRITICAL_COUNT + WARNING_COUNT + INFO_COUNT))
  fi

  # DERIVED_STATUS computed above (output-format-agnostic).
  # R-1 fix: emit BOTH providers_used (comma-string, back-compat) AND providers_used_list
  # (JSON array, typed access for jq '[0]' indexing per D4 cross-call rotation pattern).
  # Old consumers using `jq -r '.providers_used'` continue to see the string;
  # new consumers use `.providers_used_list[0]` for correct typed extraction.
  FINAL_OUTPUT=$(jq -n \
    --arg status "$DERIVED_STATUS" \
    --arg mode "$REVIEW_MODE" \
    --arg providers "$PROVIDERS_USED" \
    --argjson count "$PROVIDER_COUNT" \
    --argjson attempted "$ATTEMPTED_COUNT" \
    --argjson dispatched "$DISPATCHED_COUNT" \
    --argjson timeouts "$TIMEOUT_COUNT" \
    --argjson suspended "$(suspended_seconds "$(( $(date +%s) - START_TIME ))" "$SUSPEND_BUDGET")" \
    --arg outcomes "${PROVIDER_OUTCOMES:-none}" \
    --argjson input_size "${#INPUT}" \
    --argjson input_original "${ORIG_CHARS:-${#INPUT}}" \
    --argjson truncated "${INPUT_TRUNCATED:-false}" \
    --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --slurpfile results "$json_results_file" \
    --argjson models "$json_models" \
    --arg review_access "$(review_access_name)" \
    '{status: $status, mode: $mode, providers_used: $providers, providers_used_list: ($providers | split(", ")), provider_count: $count, attempted_count: $attempted, dispatched_count: $dispatched, timeout_count: $timeouts, provider_outcomes: $outcomes, suspended_seconds: $suspended, input_size: $input_size, input_chars_original: $input_original, input_truncated: $truncated, date: $date, models: $models, review_access: $review_access, results: $results[0]}')
else
  # Text output with banners
  FINAL_OUTPUT=$(cat <<HEADER
===============================================================
CROSS-PROVIDER ADVERSARIAL REVIEW
===============================================================
Providers: $PROVIDERS_USED ($PROVIDER_COUNT total)
Mode: $REVIEW_MODE
Input size: ${#INPUT} chars
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
===============================================================
$ALL_RESULTS
===============================================================
END OF CROSS-PROVIDER REVIEW
===============================================================
HEADER
)
fi
return 0
}

# ar_emit_output — write the artifact, report a tree changed under the reviewers, print the output.
ar_emit_output() {
if [[ -n "$ARTIFACT_PATH" ]]; then
  write_artifact "$ARTIFACT_PATH" "$FINAL_OUTPUT" \
    || { echo "ERROR: Failed to write adversarial artifact to $ARTIFACT_PATH" >&2; exit 2; }
fi

# Most runs pass no --artifact, and those are exactly the ad-hoc ones a person watches in a
# terminal — so the tamper verdict cannot live only inside the artifact path.
_tamper_verify

printf '%s\n' "$FINAL_OUTPUT"

# Disable strict mode for best-effort logging below. Partial-status runs (some
# providers timed out) can have grep -c returning 1 on missing markers, and we
# do not want that to flip the script's exit code away from 0.
set +e
return 0
}

# ar_log_run — one run-log row per candidate lane.
ar_log_run() {
# ─── Run log (per-provider) ────────────────────────────────────

END_TIME=$(date +%s)
TOTAL_DURATION=$((END_TIME - START_TIME))
SUSPENDED_S=$(suspended_seconds "$TOTAL_DURATION" "$SUSPEND_BUDGET")

# Save input for later investigation (cleanup files older than INPUT_KEEP_DAYS)
( umask 077; printf '%s' "$INPUT" > "$INPUT_FILE" ) 2>/dev/null || true   # owner-only: it is the reviewed diff
find "$LOG_DIR/adversarial-inputs" -name "*.diff" -mtime "+$INPUT_KEEP_DAYS" -delete 2>/dev/null || true

# Log one line per candidate provider. `outcome` carries what the row really means; a
# provider the --single loop never reached is `not-attempted`, not a failure.
for p in $PROVIDERS; do
  result_file="$JSON_TMPDIR/result_${p}.txt"
  p_output=0
  p_c=0; p_w=0; p_i=0
  p_exit=1
  if lane_ok "$p"; then
    p_output=$(wc -c < "$result_file" | tr -d ' ')
    read -r p_c p_w p_i < "$JSON_TMPDIR/counts_${p}.txt"
    p_exit=0
  fi

  # Outcome from the ledger the dispatch loops already maintain; no entry means the loop
  # never got to this provider.
  p_outcome="not-attempted"
  case ",$PROVIDER_OUTCOMES," in
    *",${p}:"*) p_outcome=$(printf '%s' "$PROVIDER_OUTCOMES" | tr ',' '\n' \
                   | grep "^${p}:" | head -1 | cut -d: -f2) ;;
  esac
  [[ -n "$p_outcome" ]] || p_outcome="unknown"

  p_dur=0
  [[ -f "$JSON_TMPDIR/dur_${p}.txt" ]] && p_dur=$(cat "$JSON_TMPDIR/dur_${p}.txt" 2>/dev/null)
  [[ -n "$p_dur" ]] || p_dur=0

  adversarial_log_row "$(provider_model "$p")" "$TOTAL_DURATION" "$p_exit" \
    "$p_output" "$p_c" "$p_w" "$p_i" "$p" "$p_outcome" "$p_dur"
done
return 0
}

# ar_log_summary_and_exit — the SUMMARY row; exit 4 when the input was truncated, else 0.
ar_log_summary_and_exit() {
# ─── Task 6: SUMMARY row (per-invocation roll-up) ───────────────────────────
# One TSV line per invocation summarizing the run. Greppable by leading SUMMARY
# token to distinguish from per-provider rows. Fields: SUMMARY \t ts \t mode \t
# status \t attempted_count \t timeout_count \t duration_s \t providers_used \t suspended_s
# suspended_s (col 9) is how many of duration_s the HOST spent asleep — without it a run that
# straddles a lid-close is a mystery slow run forever after.
SUMMARY_STATUS="${FINAL_STATUS:-${DERIVED_STATUS:-ok}}"
SUMMARY_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'SUMMARY\t%s\t%s\t%s\t%d\t%d\t%d\t%s\t%d\n' \
  "$SUMMARY_TS" "$REVIEW_MODE" "$SUMMARY_STATUS" \
  "${ATTEMPTED_COUNT:-0}" "${TIMEOUT_COUNT:-0}" "$TOTAL_DURATION" \
  "${PROVIDERS_USED:-${PROVIDERS:-none}}" "${SUSPENDED_S:-0}" \
  >> "$LOG_FILE" 2>/dev/null || true

# Explicit success exit. Set -e + the logging loop's last assignment can otherwise
# leak a non-zero status into the script's implicit exit code on some bash versions.
#
# …unless the input was TRUNCATED (B-ADV-TRUNC). The metadata has said `input_truncated=true` for a
# while and stderr has carried a WARN, but every call-site in adversarial-loop.md gates on the EXIT
# CODE, so a partially-reviewed patch reported as fully reviewed — the same shape of failure the
# gates exist to prevent, with the gate itself supplying the green. Observed 2026-07-31: a 50583-
# char patch silently dropped its single largest file and exited 0 with a normal verdict.
#
# Chunking (added since) removes most of this: it only truncates now when there is nothing to split
# on — `--mode tests`, fewer than two boundaries in the input (one huge file), or chunking
# explicitly disabled. Those cases are rarer, not safer, so they get their own code rather than
# sharing success's.
if [[ "${INPUT_TRUNCATED:-false}" == "true" ]]; then
  echo "  EXIT 4: input was truncated — this review does NOT cover the whole change." >&2
  echo "         Re-run over the omitted files, or split the input. Do not report it complete." >&2
  exit 4
fi
exit 0
}
