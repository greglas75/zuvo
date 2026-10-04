# shellcheck shell=bash
# adversarial-ledger.sh — what the driver records across runs: the findings ledger (one row per
# fingerprinted finding, joined with verdicts; --record-disposition and --effectiveness), the run log
# (~/.zuvo/adversarial.log: header discipline and one row per lane), the provider-health ledger that
# benches failing lanes, and the finding counters both the log and the output use.
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_init_findings_ledger, ar_cmd_record_disposition, ar_cmd_effectiveness, ar_init_run_log,
# ar_update_provider_health. Functions: log_project, ledger_project, init_findings_header,
# init_log_header, adversarial_log_row, record_provider_health, result_json_text, findings_log_rows,
# count_findings.
#
# Phase bodies sit at column 0, byte for byte the top-level code they were cut from:
# indenting them would change the multi-line prompt strings and heredocs several carry, and would
# make the move unprovable by diff. Each runs once, from the driver's Main, at the point it used to.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ─── Findings ledger: which model's findings were worth acting on ─────────────
#
# adversarial.log answers "how many findings did this model return". It cannot answer what
# decides a panel — how many were WORTH returning — because a row is one provider INVOCATION
# carrying counts. A model reporting seven speculative issues and one reporting two real bugs
# look alike there, and the louder one looks better (2026-09-30: openrouter-4 led on CRITICALs
# per review at 1.42 while its benched precision was 32%).
#
# One row per FINDING, keyed by project + the fingerprint the --json prompt mandates ("derive
# it ONLY from what is stable across reviews"). The caller that triaged the finding appends a
# verdict row for the same key; --effectiveness joins the two. Project is part of the key
# because a fingerprint is `<basename>:<line>:<keywords>` — `index.ts:10:missing-null-check`
# collides across repositories, and a verdict in one must not settle a finding in another.
# The project is the MAIN checkout's absolute path (ledger_project): a review run inside a
# linked worktree and a verdict recorded from the main checkout are the same repository, and two
# unrelated repositories that share a basename are not.
#
# APPEND-ONLY, like adversarial.log, for the same reason: parallel runs hold descriptors on it.
# A verdict judges the raises logged BEFORE it (the file is chronological): recording again with
# no raise in between supersedes it; a raise AFTER a verdict is a new, open occurrence — the same
# fingerprint months later is a new claim, and an old verdict must not settle it.
#
# Defined here, straight after argument parsing, because the two bookkeeping subcommands below
# exit here: further down, provider detection prints its banner and collect_input blocks on
# stdin — side effects a ledger query has no reason to trigger.
log_project() {
  local p; p="$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)" 2>/dev/null)" || p=""
  printf '%s' "${p:-unknown}"
}
# ledger_project — the findings ledger's project key: the main checkout's absolute path (the
# parent of the common git dir, so every linked worktree resolves to it), else the physical CWD.
ledger_project() {
  local common p=""
  # Plain --git-common-dir (relative to the CWD, or absolute) rather than --path-format=absolute,
  # which git < 2.31 lacks — there the call would fail and every worktree would key on itself.
  if common="$(git rev-parse --git-common-dir 2>/dev/null)" && [[ -n "$common" ]]; then
    p="$(cd "$common/.." 2>/dev/null && pwd -P)" || p=""
  fi
  [[ -n "$p" ]] || p="$(pwd -P 2>/dev/null)" || p=""
  # Tabs and newlines would split the row; a backslash would not survive awk -v / jq @tsv the same
  # way on both sides of the join. Neither belongs in a repository path worth keying on.
  p="${p//[[:cntrl:]\\]/_}"
  printf '%s' "${p:-unknown}"
}

# ar_init_findings_ledger — the findings ledger's path, header and schema marker.
ar_init_findings_ledger() {
FINDINGS_LOG="${ZUVO_FINDINGS_LOG_FILE:-${ZUVO_HOME:-$HOME/.zuvo}/adversarial-findings.log}"
FINDINGS_HEADER=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "date" "run_id" "mode" "provider" "model" "fingerprint" "severity" "confidence" \
  "file" "disposition" "project")
FINDINGS_SCHEMA_MARKER="#schema	$FINDINGS_HEADER"
return 0
}

# Same one-time, content-keyed marker discipline as init_log_header (read its comment): never
# rewrite a file other processes append to. Best-effort — every path returns 0.
init_findings_header() {
  mkdir -p "$(dirname "$FINDINGS_LOG")" 2>/dev/null || true
  # Never `>` an existing file: between a size check and a truncating write another run may have
  # appended rows, and the truncate would erase them. Create with noclobber (fails if the file
  # appeared meanwhile), then APPEND the header to a still-empty file — at worst two runs both
  # append it, and the reader skips header lines.
  if [[ ! -s "$FINDINGS_LOG" ]]; then
    ( set -C; : > "$FINDINGS_LOG" ) 2>/dev/null || true
    [[ -s "$FINDINGS_LOG" ]] || printf '%s\n' "$FINDINGS_HEADER" >> "$FINDINGS_LOG" 2>/dev/null || true
    return 0
  fi
  [[ "$(head -1 "$FINDINGS_LOG" 2>/dev/null)" == "$FINDINGS_HEADER" ]] && return 0
  local sentinel="${FINDINGS_LOG}.schema" confirmed=""
  [[ -f "$sentinel" ]] && confirmed="$(<"$sentinel")"
  [[ "$confirmed" == "$FINDINGS_HEADER" ]] && return 0
  if ! grep -qxF "$FINDINGS_SCHEMA_MARKER" "$FINDINGS_LOG" 2>/dev/null; then
    printf '%s\n' "$FINDINGS_SCHEMA_MARKER" >> "$FINDINGS_LOG" 2>/dev/null || return 0
  fi
  grep -qxF "$FINDINGS_SCHEMA_MARKER" "$FINDINGS_LOG" 2>/dev/null &&
    { printf '%s\n' "$FINDINGS_HEADER" > "$sentinel" 2>/dev/null || true; }
  return 0
}

# ar_cmd_record_disposition — --record-disposition: append the verdict rows and exit (1 when an id was never raised here).
ar_cmd_record_disposition() {
if [[ -n "$RECORD_ROWS" ]]; then
  _rd_proj="$(ledger_project)"
  _rd_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  _rd_out="" _rd_n=0 _rd_miss=""
  # A verdict for a fingerprint the ledger never saw from THIS project joins nothing: recording
  # it and reporting success would leave the finding "open" forever, silently excluded from the
  # precision this command exists to produce. Usual causes: a re-typed id, the wrong directory,
  # a text-mode review. Refused by name — the matched ones in the batch are still recorded.
  _rd_run="${ZUVO_RUN_ID:-manual}"; _rd_run="${_rd_run//[[:cntrl:]]/_}"
  # ENVIRON, not -v: awk -v processes backslash escapes, so the value compared would not be
  # the value written.
  _rd_known="$(RD_PROJ="$_rd_proj" awk -F'\t' '$10 == "new" && $11 == ENVIRON["RD_PROJ"] { print $6 }' \
    "$FINDINGS_LOG" 2>/dev/null | sort -u)" || _rd_known=""
  # Verdict rows leave mode/provider/model/severity EMPTY on purpose: attribution comes only
  # from the row that raised the finding. Copying a half-known model here would let a guess
  # outvote the row that actually carries it.
  while IFS=$'\t' read -r _rd_fp _rd_v; do
    if ! grep -qxF -e "$_rd_fp" <<< "$_rd_known"; then
      _rd_miss+="  $_rd_fp"$'\n'; continue
    fi
    _rd_out+="$(printf '%s\t%s\t\t\t\t%s\t\t\t\t%s\t%s' "$_rd_ts" "$_rd_run" \
      "$_rd_fp" "$_rd_v" "$_rd_proj")"$'\n'
    _rd_n=$((_rd_n + 1))
  done <<< "$RECORD_ROWS"
  if [[ -n "$_rd_out" ]]; then
    init_findings_header
    # ONE append for the whole batch, so a concurrent writer cannot interleave inside it.
    printf '%s' "$_rd_out" >> "$FINDINGS_LOG" 2>/dev/null \
      || { echo "ERROR: could not append to $FINDINGS_LOG" >&2; exit 1; }
  fi
  echo "recorded $_rd_n disposition(s) for project '$_rd_proj' in $FINDINGS_LOG"
  if [[ -n "$_rd_miss" ]]; then
    printf 'ERROR: not recorded — no --json review from this project raised these ids (copy the id\nverbatim, run from the reviewed repository; text-mode reviews are not in the ledger):\n%s' \
      "$_rd_miss" >&2
    exit 1
  fi
  exit 0
fi
return 0
}

# ar_cmd_effectiveness — --effectiveness: the per-model precision report over the ledger, then exit.
ar_cmd_effectiveness() {
if [[ "$EFFECTIVENESS" == "true" ]]; then
  if [[ ! -s "$FINDINGS_LOG" ]] || ! awk -F'\t' '$10=="new"{f=1; exit} END{exit !f}' "$FINDINGS_LOG"; then
    echo "No findings recorded yet in $FINDINGS_LOG." >&2
    echo "It fills as --json reviews run; text-mode reviews carry no fingerprints and are not counted." >&2
    exit 1
  fi
  echo "Findings ledger: $FINDINGS_LOG"
  printf '%-14s %-34s %7s %6s %6s %6s %6s %6s %10s\n' \
    provider model raised CRIT fixed defer rejct open precision
  # Credit goes to EVERY lane that raised a key, once per (occurrence, lane): two reviewers
  # finding the same bug produce the same fingerprint, and both earned it. An OCCURRENCE is the
  # run of raises between two verdicts on a key — a verdict judges what came before it, a later
  # verdict with no raise in between supersedes it, and a raise after it opens a new occurrence.
  awk -F'\t' '
    /^#/ || $1 == "date" || NF < 11 { next }
    {
      fp = $6; if (fp == "" || fp == "unknown") next
      key = $11 SUBSEP fp
      if ($10 == "new") {
        if (closed[key]) { ep[key]++; closed[key] = 0 }
        occ = key SUBSEP (ep[key] + 0)
        lane = $4 "\t" ($5 == "" ? "(unknown)" : $5)
        if ((occ, lane) in seen) next
        seen[occ, lane] = 1
        n++; pk[n] = occ; pl[n] = lane
        raised[lane]++; if (toupper($7) == "CRITICAL") crit[lane]++
      } else if ($10 ~ /^(fixed|rejected|deferred)$/) {
        verdict[key SUBSEP (ep[key] + 0)] = $10  # last write wins within an occurrence
        closed[key] = 1
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        v = verdict[pk[i]]; l = pl[i]
        if (v == "fixed") fx[l]++; else if (v == "deferred") df[l]++; else if (v == "rejected") rj[l]++
      }
      for (l in raised) {
        split(l, a, "\t")
        judged = fx[l] + df[l] + rj[l]
        prec = judged ? sprintf("%.0f%%", 100 * (fx[l] + df[l]) / judged) : "n/a"
        printf "%d\t%-14s %-34s %7d %6d %6d %6d %6d %6d %10s\n", raised[l], a[1], a[2], raised[l], \
          crit[l], fx[l], df[l], rj[l], raised[l] - judged, prec
      }
    }' "$FINDINGS_LOG" | sort -t$'\t' -k1,1rn | cut -f2-
  echo
  echo "precision = (fixed + deferred) / judged; rejected = judged a false positive."
  echo "'open' findings have no verdict yet and are EXCLUDED from precision — an unjudged finding is"
  echo "not a failed one. Only --json reviews are recorded; text output carries no fingerprints."
  exit 0
fi
return 0
}

# ar_init_run_log — the run log's directory, path, project key, saved-input path and header.
ar_init_run_log() {
# ─── Run-log plumbing ───────────────────────────────────────────
# Set up here rather than at the end of the script because the all-providers-failed path
# needs to log too, and it exits long before the success-path logging block.
# ZUVO_HOME (same override the rest of the zuvo helpers honour) keeps test runs out of the real
# ~/.zuvo — without it the suite writes real run rows and real failure-evidence directories.
LOG_DIR="${ZUVO_HOME:-$HOME/.zuvo}"
# adversarial-inputs/ keeps every review's input for 7 days — the diffs, which can hold secrets — so it
# is the owner's alone (0700, tightened when it already existed), as the failure evidence beside it is.
# When it cannot be made, the log goes to this run's private temp dir (ar_init_failure_cache), else a
# fresh mktemp dir — never ".": that was the repository under review, so the run wrote its log into the
# reviewed tree and the tamper-check then reported the reviewers for changing it.
if ! mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null; then
  _ar_log_wanted="$LOG_DIR"
  LOG_DIR="${_ar_cache_dir:-}"
  if [[ -z "$LOG_DIR" ]] || ! mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null; then
    LOG_DIR="$(mktemp -d 2>/dev/null)" && mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null \
      || LOG_DIR="/dev/null/zuvo-adversarial-log"   # under a non-directory: every write fails, quietly
  fi
  echo "  WARN: $_ar_log_wanted cannot hold the run log — writing it to $LOG_DIR this run" >&2
  unset _ar_log_wanted
fi
chmod 700 "$LOG_DIR/adversarial-inputs" 2>/dev/null || true
# ZUVO_ADVERSARIAL_LOG_FILE overrides the default path (tests + ops).
LOG_FILE="${ZUVO_ADVERSARIAL_LOG_FILE:-$LOG_DIR/adversarial.log}"
# Resolved ONCE: the row writer runs per provider, and a git call per row would add a
# subprocess to every line of the busiest log on the machine. Basename of the repo root, which
# is the same key runs.log uses in its project column, so the two can be joined.
LOG_PROJECT="$(log_project)"
INPUT_FILE="$LOG_DIR/adversarial-inputs/${RUN_ID}.diff"
# Columns 1-13 are unchanged so existing readers keep working. The three new ones exist
# because the old row could not answer the questions an incident actually asks:
#   provider  — column 4 was labelled "provider" in the header but held the MODEL, and the
#               provider name appeared nowhere. Header said 14 fields, rows had 13.
#   outcome   — ok|timeout|auth|quota|empty|unverified|no-runner|not-attempted (no-runner: a codex/claude
#               lane that could not run because the shared runner did not load). In --single every candidate after the
#               first success was logged with exit=1 and zero bytes, indistinguishable from a
#               provider that was asked and failed. That artefact is what made a healthy day
#               read as a 68%-failure day.
#   provider_duration — column 11 is the WHOLE invocation's wall time, repeated on every row.
#   project   — column 17, added 2026-09-22. The PostToolUse hook that asks "did this skill run
#               its adversarial pass?" had no per-project signal here, so it fell back to
#               grepping the word "adversarial" out of the free-text note column of runs.log.
#               Measured over 1,115 qualifying skill runs since 2026-08-01: that note carries
#               the word in 6% of them, while THIS ledger holds a real invocation for 94%. The
#               hook was therefore nagging almost every run to re-run a review it had already
#               run. A project column lets it read the ledger instead of the prose.
LOG_HEADER=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "date" "run_id" "mode" "model" "input_chars" "output_chars" "findings" "critical" \
  "warning" "info" "duration" "exit" "input_file" "provider" "outcome" "provider_duration" \
  "project")
LOG_SCHEMA_MARKER="#schema	$LOG_HEADER"
return 0
}

init_log_header() {
  # `-s`, not `-f`: a truncated (0-byte) log still exists, and treating it as "already has a
  # header" leaves every subsequent row undescribed.
  if [[ ! -s "$LOG_FILE" ]]; then
    printf '%s\n' "$LOG_HEADER" > "$LOG_FILE" 2>/dev/null || true
    return 0
  fi
  [[ "$(head -1 "$LOG_FILE" 2>/dev/null)" == "$LOG_HEADER" ]] && return 0
  # Existing file: never rewrite it in place. Parallel runs append to this log and an atomic
  # replace would silently drop rows written through a file descriptor pointing at the old
  # inode. Append a one-time schema marker instead — appends are safe, rewrites are not.
  #
  # The sentinel is what makes "one-time" cheap. Grepping the log itself would re-read the whole
  # file on EVERY invocation (already 3.7 MB here, append-only, so it only grows) to answer a
  # question that never changes after the first run.
  # The sentinel holds the schema it confirmed, and is compared BY CONTENT. It used to be a
  # zero-byte file named `.schema16` — the column count of the day, hardcoded. Adding column 17
  # (`project`) therefore did nothing: the sentinel from the 16-column era still existed, this
  # function returned here, and the marker was never appended. The live log kept a 16-column
  # `#schema` line over 1,785 seventeen-field rows, so anything reading the schema to pick a
  # field read `provider` where `outcome` is — the exact off-by-one that made a later
  # aggregation of this file report every lane as 100% failed.
  #
  # Keying it on the header STRING instead of a number in the filename makes the next column
  # addition self-healing: a changed schema no longer matches, the marker is appended once, and
  # the sentinel is rewritten. `$(<file)` is a bash builtin read — no subprocess on this path.
  local sentinel="${LOG_FILE}.schema"
  local confirmed=""
  [[ -f "$sentinel" ]] && confirmed="$(<"$sentinel")"
  [[ "$confirmed" == "$LOG_HEADER" ]] && return 0
  if ! grep -qxF "$LOG_SCHEMA_MARKER" "$LOG_FILE" 2>/dev/null; then
    printf '%s\n' "$LOG_SCHEMA_MARKER" >> "$LOG_FILE" 2>/dev/null || return 0
  fi
  # Write the sentinel only once the marker is CONFIRMED on disk. Writing it unconditionally
  # would make a failed append permanent: the next run sees a matching sentinel, skips the
  # check, and the log never gets its schema line.
  grep -qxF "$LOG_SCHEMA_MARKER" "$LOG_FILE" 2>/dev/null &&
    { printf '%s\n' "$LOG_HEADER" > "$sentinel" 2>/dev/null || true; }
  return 0
}

# adversarial_log_row <model> <duration> <exit> <output_chars> <crit> <warn> <info> \
#                     <provider> <outcome> <provider_duration> [<findings>]
# <findings> defaults to crit + warn + info; --mode blind-audit has no severities and passes the lane's
# uncovered-row count instead (severity columns 0).
adversarial_log_row() {
  local model="$1" duration="$2" exit_code="$3" out_chars="$4" c="$5" w="$6" i="$7" \
        provider="$8" outcome="$9" p_dur="${10}"
  printf '%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%ds\t%d\t%s\t%s\t%s\t%ss\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$REVIEW_MODE" "$model" \
    "${#INPUT}" "$out_chars" "${11:-$(( c + w + i ))}" "$c" "$w" "$i" \
    "$duration" "$exit_code" "$INPUT_FILE" "$provider" "$outcome" "$p_dur" \
    "${LOG_PROJECT:-unknown}" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Provider health ledger (persistent, across runs) ───────────────────────
# WHY: the run-scoped auth cache above only catches providers that report an AUTH error.
# A dead subscription that answers with its refusal IN THE BODY exits 0 and lands as "empty",
# so nothing ever benched it. Measured 2026-09-09: cursor-agent returned "You're out of usage"
# for 281 consecutive runs and codex-5.4 "gpt-5.4 is not supported ... ChatGPT account" for
# 206, and BOTH kept being sampled the whole time — every draw they won was a slot that ran
# nothing. A cap of 5 over 8 providers with 2 corpses means a review advertising five
# reviewers was routinely getting three.
#
# The substitution is implicit and that is the point: a benched provider is removed BEFORE the
# fan-out sample, so its slot is drawn by somebody else. Substituting after a failure instead
# would mean waiting out the dead provider's full timeout first and only then starting a
# replacement — paying the latency twice per run, forever.
record_provider_health() {
  [[ "${ZUVO_PROVIDER_BENCH:-1}" == "1" ]] || return 0
  [[ -n "${PROVIDER_OUTCOMES:-}" ]] || return 0
  local now tmp models _rp _rn; now=$(date +%s); tmp="${PROVIDER_HEALTH_FILE}.$$"
  # Wiersz: <lane> <model> <kolejne_porazki> <epoka> <ostatni_wynik>. CZTERY pierwsze kolumny, bo
  # klucz zlozony ze sklejonych nazw byl minem — identyfikatory modeli zawieraja i "/" i "@"
  # (gemini-3.7-flash@high). Wiersze 3-kolumnowe ze starego formatu sa POMIJANE: nie wiadomo,
  # ktorego modelu dotyczyly.
  #
  # PIATA kolumna to RODZAJ ostatniej porazki, i istnieje wylacznie po to, zeby bramka wyzej
  # mogla odroznic lane, ktory nie miesci sie w suficie czasowym (blad strukturalny, pelny
  # cooldown), od takiego, ktory zlapal 15-minutowa awarie CLI (krotki cooldown). Bez niej obie
  # sytuacje wygladaja identycznie: "kolejna porazka". Dopisywana na koncu, wiec czytelnicy
  # czterokolumnowego formatu dzialaja dalej.
  #
  # Skipped — neither a success nor a failure of the lane: not-attempted (the --single loop never
  # reached it), unverified (without the runner a short answer cannot be judged a login stub) and
  # no-runner (the lane could not start: model-subprocess.sh did not load). A broken install is not a
  # broken lane: counted here, it would bench a healthy lane long after the install is fixed.
  models=""
  for _rp in $(printf '%s' "$PROVIDER_OUTCOMES" | tr ',' ' '); do
    _rn="${_rp%%:*}"; [[ -n "$_rn" ]] || continue
    models="${models}${_rn}	$(provider_model "$_rn")
"
  done
  printf '%s' "$models" | awk -F'\t' -v outcomes="$PROVIDER_OUTCOMES" -v now="$now" \
      -v hf="$PROVIDER_HEALTH_FILE" '
    BEGIN{
      n=split(outcomes, pp, ",")
      for(i=1;i<=n;i++){ split(pp[i], kv, ":")
        if(kv[1]!="" && kv[2]!="" && kv[2]!="not-attempted" && kv[2]!="unverified" && kv[2]!="no-runner") seen[kv[1]]=kv[2] }
      while((getline l < hf) > 0){ k=split(l, f, "\t"); if(k<4) continue
        key=f[1] SUBSEP f[2]; cnt[key]=f[3]+0; ts[key]=f[4]
        last[key]=(k>=5 ? f[5] : "") }
      close(hf)
    }
    NF>=2 { model[$1]=$2 }
    END{
      for(p in seen){
        if(!(p in model)) continue
        key = p SUBSEP model[p]
        if(seen[p]=="ok"){ cnt[key]=0; last[key]="ok" }
        else             { cnt[key]=((key in cnt) ? cnt[key] : 0) + 1; last[key]=seen[p] }
        ts[key]=now
      }
      for(key in cnt){ split(key, kk, SUBSEP)
        print kk[1] "\t" kk[2] "\t" cnt[key] "\t" ts[key] "\t" ((key in last) ? last[key] : "") }
    }' > "$tmp" 2>/dev/null && mv -f "$tmp" "$PROVIDER_HEALTH_FILE" || rm -f "$tmp"
}

# ar_update_provider_health — feed this run's outcomes to the provider-health ledger (blind audit: account outcomes only).
ar_update_provider_health() {
# --mode blind-audit: the ledger learns only what describes a lane's ACCOUNT (bap_ledger_outcomes: ok,
# auth, quota); a timeout, an empty or an invalid answer here describes THIS input, not the lane.
if [[ "$REVIEW_MODE" == blind-audit ]]; then
  _ba_all="$PROVIDER_OUTCOMES"; PROVIDER_OUTCOMES="$(bap_ledger_outcomes "$_ba_all")"
  record_provider_health; PROVIDER_OUTCOMES="$_ba_all"
else
  record_provider_health
fi
return 0
}

# Count finding records, never severity words in descriptions or clean summaries.
# JSON is authoritative when present; text accepts the prompted SEVERITY field and
# the legacy "CRITICAL: description" form, with Markdown list/emphasis decoration.
# result_json_text <result_file> — the JSON a lane returned: the ```json fences when it used any
# (prose around them dropped), else the whole file. Shared by the counter and the findings
# ledger so the two can never disagree about what a lane's JSON was.
result_json_text() {
  awk '
    /^[[:space:]]*```[Jj][Ss][Oo][Nn][[:space:]]*$/ { fenced=1; inside=1; next }
    inside && /^[[:space:]]*```[[:space:]]*$/ { inside=0; next }
    { raw=raw $0 ORS; if (inside) json=json $0 ORS }
    END { printf "%s", fenced ? json : raw }
  ' "$1"
}

# findings_log_rows <provider> <model> <result_file> — one findings-ledger row per fingerprinted
# finding (the ledger is described where FINDINGS_LOG is defined). BEST-EFFORT BY CONSTRUCTION:
# every path returns 0, because a telemetry gap must never turn a review that ran into a failed
# run. JSON only: text output carries no fingerprint, and ids invented from prose headings would
# join to nothing. A mock-* lane never writes the real ~/.zuvo ledger, however it was reached —
# test fixtures there skew every precision figure, as 1,178 mock runs in a week already skew
# adversarial.log. Ids --record-disposition could never accept (control characters, flag-shaped)
# are not recorded: an unrecordable finding would sit "open" forever.
findings_log_rows() {
  local provider="$1" model="$2" rf="$3" rows
  # (--mode blind-audit never reaches the counting loop that calls this: it returns its merged
  # block earlier, so no mode check is needed here — test-findings-ledger.sh FL.16 pins that.)
  [[ "$OUTPUT_FORMAT" == "json" ]] || return 0
  if [[ "$provider" == mock-* && "$FINDINGS_LOG" == "${HOME:-}/.zuvo/adversarial-findings.log" ]]; then
    return 0
  fi
  # jq needs no check here: the driver refuses to start without it ("ERROR: jq required").
  [[ -s "$rf" ]] || return 0
  # Resolved once per run, not per lane: two git calls per provider buy nothing.
  [[ -n "${LEDGER_PROJECT:-}" ]] || LEDGER_PROJECT="$(ledger_project)"
  # -s over the whole text: a chunked review concatenates one JSON object per chunk.
  # group_by(.id): the same finding repeated across chunks is one finding, at its HIGHEST
  # severity — keeping whichever copy sorted first would under-report a CRITICAL.
  rows=$(result_json_text "$rf" | jq -rs --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg r "$RUN_ID" --arg mo "$REVIEW_MODE" --arg p "$provider" --arg m "$model" \
      --arg pj "$LEDGER_PROJECT" '
    def rank: {"CRITICAL": 3, "WARNING": 2, "INFO": 1}[(.severity // "") | tostring | ascii_upcase] // 0;
    [ .[] | objects | select((.findings | type) == "array") | .findings[] | objects
      | select((.id | type) == "string" and (.id | test("^[^-\\\\[:cntrl:]][^\\\\[:cntrl:]]*$"))) ]
    | group_by(.id)[] | max_by(rank)
    | [ $d, $r, $mo, $p, $m, .id,
        ((.severity // "?") | tostring | ascii_upcase), ((.confidence // "?") | tostring),
        ((.file // "?") | tostring), "new", $pj ]
    | @tsv' 2>/dev/null) || return 0
  [[ -n "$rows" ]] || return 0
  init_findings_header
  printf '%s\n' "$rows" >> "$FINDINGS_LOG" 2>/dev/null || true
  return 0
}

count_findings() {
  local result_file="$1" counts
  if counts=$(result_json_text "$result_file" | jq -ers '
    [ .[] | select(type == "object" and (.findings | type) == "array") ] as $reviews |
    if ($reviews | length) >= 1 then
      [ $reviews[].findings[] ] as $f |
      [$f[] | objects | .severity | strings | ascii_upcase |
       select(. == "CRITICAL" or . == "WARNING" or . == "INFO")] as $s |
      [([ $s[] | select(. == "CRITICAL") ] | length),
       ([ $s[] | select(. == "WARNING") ] | length),
       ([ $s[] | select(. == "INFO") ] | length),
       (if ($s | length) == ($f | length) then "complete" else "partial" end)] | @tsv
    else empty end' 2>/dev/null); then
    printf '%s\n' "$counts"
  else
    awk '
      {
        line=toupper($0)
        gsub(/[*_`]/, "", line)
        sub(/^[[:space:]]*/, "", line)
        while (sub(/^(#+|[-+]|[0-9]+[.)])[[:space:]]+/, "", line)) {}
        severity_words=0
        if (line ~ /CRITICAL/) severity_words++
        if (line ~ /WARNING/) severity_words++
        if (line ~ /INFO/) severity_words++
        if (line ~ /^SEVERITY:[[:space:]]*CRITICAL[[:space:]]*\|[[:space:]]*WARNING[[:space:]]*\|[[:space:]]*INFO[[:space:]]*$/) {
          next
        } else if (line ~ /^SEVERITY:[[:space:]]*(CRITICAL|WARNING|INFO)([[:space:]]|$)/ && severity_words == 1) {
          sub(/^SEVERITY:[[:space:]]*/, "", line)
          sub(/[[:space:]].*/, "", line)
          count[line]++
        } else if (line ~ /^(SEVERITY|CRITICAL|WARNING|INFO):[[:space:]]*(NONE|0|NO ISSUES)[.!]?[[:space:]]*$/) {
          clean=1
        } else if (line ~ /^(CRITICAL|WARNING|INFO):[[:space:]]+[^[:space:]]/) {
          sub(/:.*/, "", line)
          legacy[line]++
          uncertain=1
        } else if (line ~ /^SEVERITY([[:space:]:-]|$)/ || line ~ /^(CRITICAL|WARNING|INFO)[[:space:]]*[-:]/) {
          uncertain=1
        }
        if (line ~ /^NO ISSUES FOUND[.!]?[[:space:]]*$/) clean=1
      }
      END {
        c=count["CRITICAL"]+0; w=count["WARNING"]+0; i=count["INFO"]+0
        # Explicit fields win over legacy titles/body prose, avoiding double counts.
        # Legacy-only text is ambiguous: retain its counts but require inspection.
        if (c+w+i == 0 && legacy["CRITICAL"]+legacy["WARNING"]+legacy["INFO"] > 0) {
          c=legacy["CRITICAL"]+0; w=legacy["WARNING"]+0; i=legacy["INFO"]+0; uncertain=1
        }
        status=(uncertain || (c+w+i == 0 && !clean)) ? "partial" : "complete"
        print c,w,i,status
      }
    ' "$result_file"
  fi
}
