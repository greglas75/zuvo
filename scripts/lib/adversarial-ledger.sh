# shellcheck shell=bash
# adversarial-ledger.sh — what the driver records across runs: the findings ledger (one row per
# fingerprinted finding, joined with verdicts; --record-disposition and --effectiveness), the run log
# (~/.zuvo/adversarial.log: header discipline and one row per lane), the provider-health ledger that
# benches failing lanes, and the finding counters both the log and the output use.
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_init_findings_ledger, ar_cmd_record_disposition, ar_cmd_effectiveness, ar_init_run_log,
# ar_update_provider_health.
#
# Phase bodies sit at column 0, as the top-level code they were cut from: indenting them would change the
# multi-line prompt strings and heredocs several carry. Each runs once, from the driver's Main.
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
# One row per FINDING, keyed by project + the fingerprint the review prompt mandates in both output
# formats — the JSON "id", the text "ID:" line ("derive it ONLY from what is stable across reviews"). The caller that triaged the finding appends a
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
  local p; p="$(basename "$(ar_repo_root)" 2>/dev/null)" || p=""
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
return 0
}

# Same one-time, content-keyed marker discipline as init_log_header (read its comment): never
# rewrite a file other processes append to. Best-effort — every path returns 0.
# ledger_header <file> <header> — give an append-only ledger (the run log, the findings ledger) its header
# without ever rewriting it: parallel runs append to these files, and a truncating write could erase another
# run's rows. An empty file gets the header APPENDED (under its lock, below). A file whose first line is another
# schema gets a one-time `#schema<TAB><header>` marker appended, recorded by a sentinel <file>.schema compared
# BY CONTENT (a new column heals itself), written once the marker is on disk, read with a builtin.
ledger_header() {
  local file="$1" header="$2" marker sentinel confirmed=""
  marker="#schema	$header"
  if [[ ! -s "$file" ]]; then
    # Under the file's lock, checked again, so two runs on a fresh file write one header; no lock, no header.
    _ar_lock "$file.lock" 2 || return 0
    [[ -s "$file" ]] || printf '%s\n' "$header" >> "$file" 2>/dev/null || true
    _ar_unlock "$file.lock"
    return 0
  fi
  [[ "$(head -1 "$file" 2>/dev/null)" == "$header" ]] && return 0
  sentinel="${file}.schema"
  [[ -f "$sentinel" ]] && confirmed="$(<"$sentinel")"
  [[ "$confirmed" == "$header" ]] && return 0
  if ! grep -qxF "$marker" "$file" 2>/dev/null; then
    printf '%s\n' "$marker" >> "$file" 2>/dev/null || return 0
  fi
  grep -qxF "$marker" "$file" 2>/dev/null && { printf '%s\n' "$header" > "$sentinel" 2>/dev/null || true; }
  return 0
}

init_findings_header() {
  mkdir -p "$(dirname "$FINDINGS_LOG")" 2>/dev/null || true
  ledger_header "$FINDINGS_LOG" "$FINDINGS_HEADER"
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
  # a finding the reviewer gave no ID. Refused by name — the matched ones in the batch are still recorded.
  _rd_run="${ZUVO_RUN_ID:-manual}"; _rd_run="${_rd_run//[[:cntrl:]]/_}"
  # A raise under the bare basename of this checkout counts too (the driver keyed rows that way before the
  # absolute path) — unless another absolute project in the ledger has that basename, when the bare row
  # could be either's. The verdict row is still written under the absolute path; --effectiveness joins them.
  _rd_base="${_rd_proj%/}"; _rd_base="${_rd_base##*/}"
  # ENVIRON, not -v: awk -v processes backslash escapes, so the value compared would not be
  # the value written.
  _rd_known="$(RD_PROJ="$_rd_proj" RD_BASE="$_rd_base" awk -F'\t' '
      BEGIN { p = ENVIRON["RD_PROJ"]; b = ENVIRON["RD_BASE"] }
      NF < 11 || $1 == "date" { next }
      { k = $11; sub(/\/+$/, "", k); kb = k; sub(/^.*\//, "", kb)
        if (k ~ /^\// && k != p && kb == b) shared = 1 }
      $10 != "new" { next }
      $11 == p { own[$6] = 1 }
      b != "" && $11 == b { bare[$6] = 1 }
      END { for (i in own) print i; if (!shared) for (i in bare) print i }' \
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
    printf 'ERROR: not recorded — no review from this project raised these ids (copy the id verbatim from\nthe review'"'"'s ID: line or JSON "id", and run from the reviewed repository):\n%s' \
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
    echo "It fills as reviews run: every finding with an ID (text ID: line or JSON \"id\") is recorded." >&2
    exit 1
  fi
  echo "Findings ledger: $FINDINGS_LOG"
  printf '%-14s %-34s %7s %6s %6s %6s %6s %6s %10s\n' \
    provider model raised CRIT fixed defer rejct open precision
  # Credit goes to EVERY lane that raised a key, once per (occurrence, lane): two reviewers
  # finding the same bug produce the same fingerprint, and both earned it. An OCCURRENCE is the
  # run of raises between two verdicts on a key — a verdict judges what came before it, a later
  # verdict with no raise in between supersedes it, and a raise after it opens a new occurrence.
  # Two passes: the first finds basenames two absolute projects share — a verdict never stands for a bare
  # raise there, as --record-disposition never accepts one.
  awk -F'\t' '
    /^#/ || $1 == "date" || NF < 11 { next }
    FNR == NR {
      k = $11; sub(/\/+$/, "", k); b = k; sub(/^.*\//, "", b)
      if (k ~ /^\//) { if (!(b in first)) first[b] = k; else if (first[b] != k) shared[b] = 1 }
      next
    }
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
        # It judges the raises under the bare basename too: --record-disposition accepts those ids.
        b = $11; sub(/\/+$/, "", b); sub(/^.*\//, "", b)
        if (b != "" && b != $11 && !(b in shared)) {
          bk = b SUBSEP fp; verdict[bk SUBSEP (ep[bk] + 0)] = $10; closed[bk] = 1
        }
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
    }' "$FINDINGS_LOG" "$FINDINGS_LOG" | sort -t$'\t' -k1,1rn | cut -f2-
  echo
  echo "precision = (fixed + deferred) / judged; rejected = judged a false positive."
  echo "'open' findings have no verdict yet and are EXCLUDED from precision — an unjudged finding is"
  echo "not a failed one. A finding the reviewer gave no ID is not recorded: no verdict can join it."
  exit 0
fi
return 0
}

# INPUT_KEEP_DAYS — how long adversarial-inputs/ keeps a review's input (the diff, which can hold secrets).
INPUT_KEEP_DAYS=7
# LOCK_PID_REUSE_SLACK_S — how much younger than a lock its pid's process may look and still be its holder
# (the lock's pid is written just after its mkdir; ps's etime and the file's mtime are whole seconds).
LOCK_PID_REUSE_SLACK_S=5

# ar_init_run_log — the run log's directory, path, project key, saved-input path and header.
ar_init_run_log() {
# ─── Run-log plumbing ───────────────────────────────────────────
# Set up here rather than at the end of the script because the all-providers-failed path
# needs to log too, and it exits long before the success-path logging block.
# ZUVO_HOME (same override the rest of the zuvo helpers honour) keeps test runs out of the real
# ~/.zuvo — without it the suite writes real run rows and real failure-evidence directories.
LOG_DIR="${ZUVO_HOME:-$HOME/.zuvo}"
# adversarial-inputs/ keeps every review's input for INPUT_KEEP_DAYS — the diffs, which can hold secrets —
# so it is the owner's alone (0700), as the failure evidence beside it is. When it cannot be made, the log
# goes to the private temp dir runs share (ar_init_failure_cache), else to this run's own temp dir (not kept,
# said). Never ".", the repository under review; never a mktemp dir of its own, which nothing sweeps.
if ! mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null; then
  _ar_log_wanted="$LOG_DIR"
  LOG_DIR="${_ar_cache_dir:-}"
  if [[ -n "$LOG_DIR" ]] && mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null; then
    echo "  WARN: $_ar_log_wanted cannot hold the run log — writing it to $LOG_DIR this run" >&2
  else
    LOG_DIR="$JSON_TMPDIR/run-log"
    mkdir -p "$LOG_DIR/adversarial-inputs" 2>/dev/null \
      || LOG_DIR="/dev/null/zuvo-adversarial-log"   # under a non-directory: every write fails, quietly
    echo "  WARN: $_ar_log_wanted cannot hold the run log, nor can the private temp dir — this run's log is not kept" >&2
  fi
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
#   outcome   — ok|timeout|auth|quota|empty|unverified|no-runner|no-key|not-attempted (no-key: an API lane
#               with no usable key; no-runner: a codex/claude
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
#   effort    — column 18: the reasoning effort the lane ran at (provider_effort), empty when
#               the lane sets none. The same model at two efforts is two different reviewers — codex-5.3 runs
#               gpt-6.1-sol at `none`, the Opus reviewer runs at `high` — and nothing in the row said which.
#   tokens_in, tokens_cached, tokens_out, tokens_reasoning — columns 19-22, added 2026-10-19: what the lane's
#               calls cost, as the vendor counted it (lane_usage_add). tokens_in counts every input token, cached
#               ones included; tokens_cached is the part read from the cache; tokens_out counts every output
#               token, reasoning included; tokens_reasoning is that part. Empty = the vendor reported none (a
#               lane that never ran, a call killed before it answered). Every client returns these numbers,
#               and until now each lane printed them to a stderr that is deleted when the run ends, so the
#               cost of a lane could only be estimated from output_chars, which leaves reasoning out entirely
#               (52k of 53k output tokens on a DeepSeek review).
#   served_by, cost_usd, gen_id — columns 23-25, added 2026-10-24, OpenRouter calls only (an OpenRouter lane, or a
#               BytePlus lane's OpenRouter fallback step; empty for every other lane and on older rows). served_by:
#               the upstream host that answered (the response's `provider`, e.g. Parasail, GMICloud), several
#               comma-joined in call order when the lane made several calls; cost_usd: the summed `usage.cost` the
#               vendor billed, in USD; gen_id: the generation ids (`gen-…`), comma-joined. A pinned host order says
#               which hosts MAY serve a model; only the answer says which one did, and what it cost — OpenRouter's
#               own per-generation activity endpoint needs a management key the review key is not.
LOG_HEADER=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "date" "run_id" "mode" "model" "input_chars" "output_chars" "findings" "critical" \
  "warning" "info" "duration" "exit" "input_file" "provider" "outcome" "provider_duration" \
  "project" "effort" "tokens_in" "tokens_cached" "tokens_out" "tokens_reasoning" \
  "served_by" "cost_usd" "gen_id")
return 0
}

init_log_header() {
  # `-s`, not `-f`, inside ledger_header: a truncated (0-byte) log gets its header again.
  ledger_header "$LOG_FILE" "$LOG_HEADER"
}

# adversarial_log_row <model> <duration> <exit> <output_chars> <crit> <warn> <info> \
#                     <provider> <outcome> <provider_duration> [<findings>]
# <findings> defaults to crit + warn + info; --mode blind-audit has no severities and passes the lane's
# uncovered-row count instead (severity columns 0).
adversarial_log_row() {
  local model="$1" duration="$2" exit_code="$3" out_chars="$4" c="$5" w="$6" i="$7" \
        provider="$8" outcome="$9" p_dur="${10}"
  printf '%s\t%s\t%s\t%s\t%d\t%d\t%d\t%d\t%d\t%d\t%ds\t%d\t%s\t%s\t%s\t%ss\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$RUN_ID" "$REVIEW_MODE" "$model" \
    "${#INPUT}" "$out_chars" "${11:-$(( c + w + i ))}" "$c" "$w" "$i" \
    "$duration" "$exit_code" "$INPUT_FILE" "$provider" "$outcome" "$p_dur" \
    "${LOG_PROJECT:-unknown}" "$(provider_effort "$provider")" "$(lane_usage_cols "$provider")" \
    "$(lane_or_cols "$provider")" \
    >> "$LOG_FILE" 2>/dev/null || true
}

# ─── Token usage per lane (columns 19-22) ───────────────────────────────────
# Each lane records what its calls cost — one line per call, "<in> <cached> <out> <reasoning>", "-" for a number
# the vendor did not report — in $JSON_TMPDIR/usage_<lane>.txt; the row sums them. ADV_USAGE_LANE names the
# lane: dispatch_provider sets it in the lane's own subshell, so a stand-in (byteplus-alt through the qwen CLI,
# kimi through kimi-api) is billed to the lane the row is for.

# lane_usage_add <in> <cached> <out> <reasoning> — one call's tokens for the running lane; a no-op outside one.
lane_usage_add() {
  [[ -n "${ADV_USAGE_LANE:-}" && -n "${JSON_TMPDIR:-}" ]] || return 0
  local v line=""
  for v in "${1:-}" "${2:-}" "${3:-}" "${4:-}"; do
    [[ "$v" =~ ^[0-9]+$ ]] || v=-
    line+="$v "
  done
  # Nothing measured is no line: an all-unknown call would only turn the row's empty columns into zeros. Nor is a
  # call that reports only zeros — a refusal the model never saw (the qwen CLI records a spent Token Plan call as
  # 0 in / 0 out): no real call reads zero tokens, and those zeros read as "measured, free" in columns 19-22.
  [[ "$line" =~ [1-9] ]] || return 0
  printf '%s\n' "${line% }" >> "$JSON_TMPDIR/usage_${ADV_USAGE_LANE}.txt" 2>/dev/null || true
}

# lane_usage_line "<in> <cached> <out> <reasoning>" — lane_usage_add from one jq-built line, four fields exactly
# (word splitting of an unquoted line would shift a field if one ever came out empty).
lane_usage_line() {
  local a b c d
  [[ -n "${1:-}" ]] || return 0
  read -r a b c d _ <<< "$1"
  lane_usage_add "$a" "$b" "$c" "$d"
}

# lane_usage_from_chat <response> — the usage block of an OpenAI-shaped chat response (OpenRouter, BytePlus,
# Z.ai, Codestral, Moonshot). prompt_tokens includes the cached part; completion_tokens includes reasoning.
lane_usage_from_chat() {
  local t
  t="$(printf '%s' "$1" | jq -r '.usage // empty | select(type == "object")
        | [.prompt_tokens, (.prompt_tokens_details.cached_tokens // .prompt_cache_hit_tokens),
           .completion_tokens, .completion_tokens_details.reasoning_tokens]
        | map(if type == "number" then floor | tostring else "-" end) | join(" ")' 2>/dev/null)" || return 0
  lane_usage_line "$t"
}

# lane_usage_take <file> — every "<in> <cached> <out> <reasoning>" line a runner wrote (zms_run_* --usage-file),
# into the running lane's usage; the file is consumed.
lane_usage_take() {
  local a b c d rest
  [[ -s "$1" ]] || return 0
  while read -r a b c d rest; do lane_usage_add "$a" "$b" "$c" "$d"; done < "$1"
  rm -f -- "$1" 2>/dev/null || true
}

# lane_usage_cols <lane> — the lane's four token columns, tab-separated: each the sum of the calls that reported
# it, empty when none did.
lane_usage_cols() {
  local f="${JSON_TMPDIR:-}/usage_$1.txt"
  if [[ -z "${JSON_TMPDIR:-}" || ! -s "$f" ]]; then printf '\t\t\t'; return 0; fi
  awk '{ for (i = 1; i <= 4; i++) if ($i ~ /^[0-9]+$/) { s[i] += $i; h[i] = 1 } }
       END { printf "%s\t%s\t%s\t%s", (h[1] ? s[1] : ""), (h[2] ? s[2] : ""), (h[3] ? s[3] : ""), (h[4] ? s[4] : "") }' "$f"
}

# ─── OpenRouter host, cost and generation id per lane (columns 23-25) ─────────
# Each OpenRouter call that answered 2xx adds "<host>\t<cost>\t<gen id>" to $JSON_TMPDIR/orcall_<lane>.txt (the lane
# is ADV_USAGE_LANE, as for the tokens), any field empty when the answer lacked it; the row folds them.

# lane_or_call_add <host> <cost> <gen-id> — one OpenRouter answer for the running lane; a no-op outside one. The
# values are upstream bytes: a host or id outside [A-Za-z0-9._-] (40 / 80 chars) and a cost that is not a plain
# non-negative decimal under $1000 are dropped, never written — a tab or newline in them would shift the row's columns.
lane_or_call_add() {
  [[ -n "${ADV_USAGE_LANE:-}" && -n "${JSON_TMPDIR:-}" ]] || return 0
  local host="${1:-}" cost="${2:-}" id="${3:-}"
  [[ "$host" =~ ^[A-Za-z0-9._-]{1,40}$ ]] || host=""
  # jq writes a large or round double as 1e+21 — the sign is allowed; a cost of $1000 or more per call is no real
  # bill (1e309 would sum to `inf`) and is dropped like any other bad value.
  [[ "$cost" =~ ^[0-9]+(\.[0-9]+)?([eE][+-]?[0-9]{1,3})?$ ]] && awk -v c="$cost" 'BEGIN { exit !(c + 0 < 1000) }' || cost=""
  [[ "$id" =~ ^[A-Za-z0-9._-]{1,80}$ ]] || id=""
  [[ -n "$host$cost$id" ]] || return 0
  printf '%s\t%s\t%s\n' "$host" "$cost" "$id" >> "$JSON_TMPDIR/orcall_${ADV_USAGE_LANE}.txt" 2>/dev/null || true
}

# lane_or_cols <lane> — served_by, cost_usd, gen_id, tab-separated: the distinct hosts and the ids comma-joined in
# call order, the costs summed (8 decimals — a short call costs fractions of a cent); empty when no call
# reported the field.
lane_or_cols() {
  local f="${JSON_TMPDIR:-}/orcall_$1.txt"
  if [[ -z "${JSON_TMPDIR:-}" || ! -s "$f" ]]; then printf '\t\t'; return 0; fi
  awk -F'\t' '
    $1 != "" && !($1 in seen) { seen[$1] = 1; hosts = hosts (hosts == "" ? "" : ",") $1 }
    $2 != "" { cost += $2; hc = 1 }
    $3 != "" { ids = ids (ids == "" ? "" : ",") $3 }
    END { printf "%s\t%s\t%s", hosts, (hc ? sprintf("%.8f", cost) : ""), ids }' "$f"
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
# _ar_lock <lock-dir> <seconds> — a lock taken as a DIRECTORY (mkdir is atomic everywhere this runs;
# flock(1) is not on macOS) holding its holder's pid. Waits up to <seconds>: status 0 taken, 1 still held, 2
# at once when the lock's directory is missing or not writable. Release: _ar_unlock <lock-dir>.
#
# A lock whose holder is gone (_ar_lock_stale) is broken, but only under a second lock, <lock-dir>.break,
# with the holder read AGAIN there: nothing but a breaker removes a dead holder's lock, so a waiter can never
# break a lock another waiter has just taken. A .break left by a killed breaker is cleared after a minute.
_ar_lock() {
  local lock="$1" tries=$(( $2 * 10 )) parent
  parent="$(dirname -- "$lock")"
  [[ -d "$parent" && -w "$parent" ]] || return 2
  while ! mkdir "$lock" 2>/dev/null; do
    if _ar_lock_stale "$lock" && mkdir "$lock.break" 2>/dev/null; then
      if _ar_lock_stale "$lock" && mv "$lock" "$lock.stale.$$" 2>/dev/null; then
        rm -f "$lock.stale.$$/pid"; rmdir "$lock.stale.$$" 2>/dev/null || true
      fi
      rmdir "$lock.break" 2>/dev/null || true
      continue
    fi
    [[ -z "$(find "$lock.break" -maxdepth 0 -mmin +1 2>/dev/null)" ]] || rmdir "$lock.break" 2>/dev/null || true
    (( tries-- > 0 )) || return 1
    sleep 0.1
  done
  printf '%s\n' "$$" > "$lock/pid" 2>/dev/null || true
}

# _ar_lock_stale <lock-dir> — the holder is gone: no process has its pid (_ar_pid_alive); or the process that
# has it started AFTER the lock was taken (the pid was reused); or the lock has no pid and fails the age check
# below (a holder killed between its mkdir and its pid write, or a driver from before the pid).
_ar_lock_stale() {
  local holder p_age l_age
  holder="$(cat "$1/pid" 2>/dev/null)" || holder=""
  if [[ "$holder" =~ ^[0-9]+$ ]]; then
    _ar_pid_alive "$holder" || return 0
    p_age="$(_ar_pid_age_s "$holder")" || return 1         # alive, its age unknown: the holder
    l_age="$(_ar_mtime "$1/pid")" || return 1
    l_age=$(( $(date +%s) - l_age ))
    [[ $(( p_age + LOCK_PID_REUSE_SLACK_S )) -lt "$l_age" ]]   # started after the lock: a reused pid
  else
    [[ -d "$1" && -n "$(find "$1" -maxdepth 0 -mmin +2 2>/dev/null)" ]]
  fi
}

# _ar_pid_alive <pid> — a process has that pid, whoever owns it: ps -p shows it, or kill -0 reaches it or is
# refused it (EPERM: another user's) — neither alone sees every live process (hidepid, a sandboxed ps).
_ar_pid_alive() {
  local e
  ps -p "$1" >/dev/null 2>&1 && return 0
  e="$( (LC_ALL=C; kill -0 "$1") 2>&1 )" && return 0
  [[ "$e" == *"not permitted"* ]]
}

# _ar_pid_age_s <pid> — seconds since that process started (ps's etime, [[dd-]hh:]mm:ss); status 1 unknown.
_ar_pid_age_s() {
  local t d=0 a b c
  t="$(ps -o etime= -p "$1" 2>/dev/null | tr -d ' ')" && [[ "$t" =~ ^([0-9]+-)?[0-9:]+$ ]] || return 1
  if [[ "$t" == *-* ]]; then d="${t%%-*}"; t="${t#*-}"; fi
  IFS=: read -r a b c <<< "$t"
  if [[ -n "$c" ]]; then echo $(( 10#$d * 86400 + 10#$a * 3600 + 10#$b * 60 + 10#$c ))
  else echo $(( 10#$d * 86400 + 10#$a * 60 + 10#${b:-0} )); fi
}

# _ar_mtime <path> — its modification time, epoch seconds. GNU stat first: on Linux `stat -f` is a filesystem
# report that succeeds, so the BSD form must never be tried first.
_ar_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# _ar_unlock <lock-dir> — releases a lock this run holds; one that is not ours (ours was broken) stays.
_ar_unlock() {
  local holder
  holder="$(cat "$1/pid" 2>/dev/null)" || holder=""
  [[ -z "$holder" || "$holder" == "$$" ]] || return 0
  rm -f "$1/pid" 2>/dev/null; rmdir "$1" 2>/dev/null || true
}

record_provider_health() {
  [[ "${ZUVO_PROVIDER_BENCH:-1}" == "1" && -n "$PROVIDER_HEALTH_FILE" ]] || return 0
  [[ -n "${PROVIDER_OUTCOMES:-}" ]] || return 0
  # Read, recompute, mv over — under a lock, or parallel reviews erase each other's updates. A run that cannot
  # take it records nothing (one lost update, said) rather than clobbering a concurrent one.
  local _lk=0
  _ar_lock "${PROVIDER_HEALTH_FILE}.lock" "$(ar_env_int ZUVO_PROVIDER_HEALTH_LOCK_WAIT 10)" || _lk=$?
  if [[ "$_lk" -eq 2 ]]; then
    echo "  WARN: provider-health ledger cannot be written (${PROVIDER_HEALTH_FILE%/*} is missing or not writable) — this run's lane outcomes are not recorded" >&2
    return 0
  elif [[ "$_lk" -ne 0 ]]; then
    echo "  WARN: provider-health ledger busy (${PROVIDER_HEALTH_FILE}.lock is held by another run) — this run's lane outcomes are not recorded" >&2
    return 0
  fi
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
  # no-runner (model-subprocess.sh did not load) and no-key (no usable API key): a broken install or a missing
  # key is not a broken lane, and counted here would bench a healthy lane long after it is fixed.
  # And `input`: the lane refused THIS input (a prompt over its context window) — the input's fault, not the lane's.
  models=""
  for _rp in $(printf '%s' "$PROVIDER_OUTCOMES" | tr ',' ' '); do
    _rn="${_rp%%:*}"; [[ -n "$_rn" ]] || continue
    models="${models}${_rn}	$(ledger_model "$_rn")
"
  done
  # SIXTH column (only when set): the strike group of the last write (ZUVO_ADV_STRIKE_GROUP — minted by the
  # chunk launcher for the parts of one review, and honoured only in such a part: ZUVO_ADV_CHUNK set). Parallel parts of one review are one sample, not three. Read through ENVIRON (awk -v would turn a literal \n into a row break) and
  # stripped of tabs, newlines and carriage returns.
  local _sgrp=""; [[ -n "${ZUVO_ADV_CHUNK:-}" ]] && _sgrp="${ZUVO_ADV_STRIKE_GROUP:-}"
  printf '%s' "$models" | ZUVO_ADV_STRIKE_GROUP="$_sgrp" awk -F'\t' \
      -v outcomes="$PROVIDER_OUTCOMES" -v now="$now" -v hf="$PROVIDER_HEALTH_FILE" '
    BEGIN{
      grp=ENVIRON["ZUVO_ADV_STRIKE_GROUP"]; gsub(/[\t\n\r]/, "", grp)
      n=split(outcomes, pp, ",")
      for(i=1;i<=n;i++){ split(pp[i], kv, ":")
        if(kv[1]!="" && kv[2]!="" && kv[2]!="not-attempted" && kv[2]!="unverified" && kv[2]!="no-runner" && kv[2]!="no-key" && kv[2]!="input") seen[kv[1]]=kv[2] }
      while((getline l < hf) > 0){ k=split(l, f, "\t"); if(k<4) continue
        key=f[1] SUBSEP f[2]; cnt[key]=f[3]+0; ts[key]=f[4]
        last[key]=(k>=5 ? f[5] : ""); sg[key]=(k>=6 ? f[6] : "") }
      close(hf)
    }
    NF>=2 { model[$1]=$2 }
    END{
      for(p in seen){
        if(!(p in model)) continue
        key = p SUBSEP model[p]
        # A failure of a group that already decided this lane (it struck, or another part answered) within
        # the hour changes nothing — not the count, the class or the time: whichever order the parts end in,
        # a review with any answering part leaves 0, one with none leaves exactly one strike.
        if(seen[p]!="ok" && grp != "" && sg[key] == grp && now >= ts[key] && now - ts[key] <= 3600) continue
        # probe-ok: the cooldown canary answered — the lane runs again, the count stands until a real answer.
        if(seen[p]=="probe-ok"){ cnt[key]=((key in cnt) ? cnt[key] : 0); last[key]="probe-ok" }
        else if(seen[p]=="ok"){ cnt[key]=0; last[key]="ok" }
        else             { cnt[key]=((key in cnt) ? cnt[key] : 0) + 1; last[key]=seen[p] }
        sg[key]=grp
        ts[key]=now
      }
      for(key in cnt){ split(key, kk, SUBSEP)
        print kk[1] "\t" kk[2] "\t" cnt[key] "\t" ts[key] "\t" ((key in last) ? last[key] : "") ((sg[key] != "") ? "\t" sg[key] : "") }
    }' > "$tmp" 2>/dev/null && mv -f "$tmp" "$PROVIDER_HEALTH_FILE" || rm -f "$tmp"
  _ar_unlock "${PROVIDER_HEALTH_FILE}.lock"
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
# result_json_text <result_file> — the JSON a lane returned: what its json-tagged fences hold, when they hold
# anything (prose around them dropped); else what its bare fences hold, when the answer is nothing BUT fenced
# blocks (a code sample fenced inside a prose review is not the review); else the whole file. A fence is a line
# of three or more backticks or tildes, indented or not, its "json" tag in any case and spaced or not; it
# closes on a line of the same character, at least as long (CommonMark). An EMPTY json fence hides nothing.
# Shared by the counter, the findings ledger and the --json document, so none of them can disagree.
result_json_text() {
  awk '
    function fence(s) { sub(/^[[:space:]]+/, "", s); match(s, /^(`+|~+)/); return substr(s, 1, RLENGTH) }
    { raw = raw $0 ORS }
    !inside && /^[[:space:]]*(```+|~~~+)[[:space:]]*([Jj][Ss][Oo][Nn])?[[:space:]]*$/ {
      inside = 1; open = fence($0); tagged = ($0 ~ /[Jj][Ss][Oo][Nn]/); next }
    inside && /^[[:space:]]*(```+|~~~+)[[:space:]]*$/ {
      f = fence($0)
      if (substr(f, 1, 1) == substr(open, 1, 1) && length(f) >= length(open)) { inside = 0; next }
    }
    inside && tagged { json = json $0 ORS; next }
    inside           { bare = bare $0 ORS; next }
    /[^[:space:]]/   { prose = 1 }
    END {
      if (json ~ /[^[:space:]]/)               printf "%s", json
      else if (bare ~ /[^[:space:]]/ && !prose) printf "%s", bare
      else                                      printf "%s", raw
    }
  ' "$1"
}

# findings_log_rows <provider> <model> <result_file> — one findings-ledger row per fingerprinted
# finding (the ledger is described where FINDINGS_LOG is defined). BEST-EFFORT BY CONSTRUCTION:
# every path returns 0, because a telemetry gap must never turn a review that ran into a failed
# run. Text output is read through findings_text_rows (its ID: lines); ids are never invented from
# prose, which would join to nothing. A mock-* lane never writes the real ~/.zuvo ledger, however it was reached —
# test fixtures there skew every precision figure, as 1,178 mock runs in a week already skew
# adversarial.log. Ids --record-disposition could never accept (control characters, flag-shaped)
# are not recorded: an unrecordable finding would sit "open" forever.
findings_log_rows() {
  local provider="$1" model="$2" rf="$3" rows
  # (--mode blind-audit never reaches the counting loop that calls this: it returns its merged
  # block earlier, so no mode check is needed here — test-findings-ledger.sh FL.16 pins that.)
  if [[ "$provider" == mock-* && "$FINDINGS_LOG" == "${HOME:-}/.zuvo/adversarial-findings.log" ]]; then
    return 0
  fi
  # jq needs no check here: the driver refuses to start without it ("ERROR: jq required").
  [[ -s "$rf" ]] || return 0
  # Resolved once per run, not per lane: two git calls per provider buy nothing.
  [[ -n "${LEDGER_PROJECT:-}" ]] || LEDGER_PROJECT="$(ledger_project)"
  rows=""
  # -s over the whole text: a chunked review concatenates one JSON object per chunk.
  # group_by(.id): the same finding repeated across chunks is one finding, at its HIGHEST
  # severity — keeping whichever copy sorted first would under-report a CRITICAL.
  [[ "$OUTPUT_FORMAT" != "json" ]] || rows=$(result_json_text "$rf" | jq -rs --arg d "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
      --arg r "$RUN_ID" --arg mo "$REVIEW_MODE" --arg p "$provider" --arg m "$model" \
      --arg pj "$LEDGER_PROJECT" '
    def rank: {"CRITICAL": 3, "WARNING": 2, "INFO": 1}[(.severity // "") | tostring | ascii_upcase] // 0;
    [ .[] | objects | select((.findings | type) == "array") | .findings[] | objects
      | select((.id | type) == "string" and (.id | test("^[^-\\\\[:cntrl:]<>][^\\\\[:cntrl:]<>]*$"))) ]
    | group_by(.id)[] | max_by(rank)
    | [ $d, $r, $mo, $p, $m, .id,
        ((.severity // "?") | tostring | ascii_upcase), ((.confidence // "?") | tostring),
        ((.file // "?") | tostring), "new", $pj ]
    | @tsv' 2>/dev/null) || rows=""
  # Text output — and a lane that answered the text format to a --json prompt — carries ID lines.
  [[ -n "$rows" ]] || rows=$(findings_text_rows "$provider" "$model" "$rf") || return 0
  [[ -n "$rows" ]] || return 0
  init_findings_header
  # For print_verdict_hint: the IDs this run put in the ledger (field 6), across lanes — only once they are
  # in it, or the hint would offer IDs that --record-disposition then refuses.
  if printf '%s\n' "$rows" >> "$FINDINGS_LOG" 2>/dev/null; then
    LEDGER_RUN_IDS+="$(printf '%s\n' "$rows" | cut -f6)"$'\n'
  else
    echo "WARN: findings ledger not written ($FINDINGS_LOG) — $provider's findings cannot be given a verdict" >&2
  fi
  return 0
}

# findings_text_rows <provider> <model> <result_file> — the ledger rows of a TEXT review: one per finding block
# (opened by its SEVERITY field) that carries a recordable ID, grouped by ID at the highest severity, as the JSON
# path does. Keys are found on the line stripped the way count_findings' fallback strips it (Markdown emphasis,
# list markers); values come from the RAW line, trimmed of emphasis and backticks at their ends only, so an
# underscore in a path or an ID survives. An ID holding a control character is dropped, as the JSON path drops it.
findings_text_rows() {
  # ENVIRON, not -v: awk -v processes backslash escapes, so the value written would not be the value passed.
  FT_D="$(date -u +%Y-%m-%dT%H:%M:%SZ)" FT_R="$RUN_ID" FT_MO="$REVIEW_MODE" FT_P="$1" FT_M="$2" \
  FT_PJ="${LEDGER_PROJECT:-}" awk '
    BEGIN { d = ENVIRON["FT_D"]; r = safe(ENVIRON["FT_R"]); mo = safe(ENVIRON["FT_MO"]); p = safe(ENVIRON["FT_P"])
            m = safe(ENVIRON["FT_M"]); pj = safe(ENVIRON["FT_PJ"]) }
    function safe(s) { gsub(/[[:cntrl:]]/, "_", s); return s }
    # The colon may sit inside or outside the emphasis, or after a space: KEY:, **KEY:**, **KEY**:, KEY :.
    function value(raw, key) {
      if (!match(toupper(raw), key "[*_`]*[[:space:]]*:")) return ""
      raw = substr(raw, RSTART + RLENGTH)
      sub(/^[[:space:]*`]+/, "", raw); sub(/[[:space:]*`]+$/, "", raw); return raw
    }
    # An ID is one token: a fingerprint holds no space, so words after it and closing punctuation are not part of it.
    function token(s) { sub(/[[:space:]].*$/, "", s); sub(/[`*.,;:)]+$/, "", s); return s }
    function word(s) { split(s, w, /[^A-Za-z]+/); return w[1] }
    function rank(s) { return s == "CRITICAL" ? 3 : s == "WARNING" ? 2 : s == "INFO" ? 1 : 0 }
    function flush() {
      # <…> is the template of the prompt (a lane that copied it back): a fingerprint never holds it.
      if (open && !badid && id != "" && id !~ /^-/ && id !~ /[\\[:cntrl:]<>]/) {
        if (!(id in best)) order[++n] = id
        # >=, as jq max_by in the JSON path: of two copies at the same severity the later one is kept.
        if (!(id in best) || rank(sev) >= rank(best[id])) { best[id] = sev; conf[id] = cf; file[id] = fl }
      }
      open = 0; badid = 0; id = ""; sev = "?"; cf = "?"; fl = "?"
    }
    {
      key = $0; gsub(/[*_`]/, "", key); sub(/^[[:space:]]+/, "", key)
      while (sub(/^(#+|[-+]|[0-9]+[.)])[[:space:]]+/, "", key)) {}
      key = toupper(key)
      if (key ~ /^SEVERITY[[:space:]]*:/) {
        flush(); open = 1
        sev = toupper(word(value($0, "SEVERITY"))); if (!rank(sev)) sev = "?"
        c = tolower(word(value($0, "CONFIDENCE"))); if (c != "") cf = c
        next
      }
      if (!open) next
      # The first value of each field in a block wins: a later finding that skipped its SEVERITY line must
      # not overwrite this one (its fields are lost instead, and its ID, unrecorded, is refused by name).
      if (key ~ /^CONFIDENCE[[:space:]]*:/) { c = tolower(word(value($0, "CONFIDENCE"))); if (c != "" && cf == "?") cf = c; next }
      if (key ~ /^FILE[[:space:]]*:/)       { f = value($0, "FILE"); gsub(/[[:cntrl:]]/, " ", f); if (f != "" && fl == "?") fl = f; next }
      # A control character is judged on the whole value, before token() would cut at it.
      if (key ~ /^ID[[:space:]]*:/)         { v = value($0, "ID"); if (id == "" && !badid) { if (v ~ /[[:cntrl:]]/) badid = 1; else id = token(v) }; next }
    }
    END {
      flush()
      for (k = 1; k <= n; k++) { i = order[k]
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\tnew\t%s\n", d, r, mo, p, m, i, best[i], conf[i], file[i], pj
      }
    }' "$3" 2>/dev/null
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

# ─── Pass cap ───────────────────────────────────────────────────
# PASS_CAP — the most passes ONE change gets (adversarial-loop.md Step 5), with no override: later passes
# mostly re-derive the false positives of the earlier ones.
PASS_CAP=3
# PASS_WINDOW_S — an earlier pass counts when it ran in this repository (any worktree of it), on this branch,
# within this window, over files that share at least half of the SMALLER of the two file sets with the files under
# review now — a fix delta, the full scope again, a wider or a re-based review of the same change all count.
# Seven days: on 2026-10-15/16 one PR took 28 passes in 44 h because farm waits spread them past the old 3 h window
# and every pass used another --diff base, so no file set contained all of the next one (tgm-survey-platform,
# feature/import-parser-primitives, ~185M tokens). A shared default branch keeps the short window
# (PASS_WINDOW_SHARED_S): unrelated changes land there one after another and touch the same files.
# When the agent session is known (_ar_pass_session), only that session's passes count: the cap stops ONE agent
# looping, it must not stop the next session from reviewing a fix. Owner 2026-10-20: a 6-line fix to a merged
# change went unreviewed because three passes of an earlier review in another round had spent the branch's week.
PASS_WINDOW_S=604800
PASS_WINDOW_SHARED_S=10800
# PASS_CAP_EXIT — the exit status of a refused pass: nothing was reviewed, so it is not 0 and not a finding.
PASS_CAP_EXIT=7

# _ar_pass_files — the files under review, one per line, sorted and unique: `diff --git` headers for a patch,
# `=== FILE: <name> ===` sections for --files input. Empty when the input names no file (a plan, free text).
_ar_pass_files() {
  # From the ---/+++ lines, not `diff --git a/X b/Y`: a path holding " b/" makes that header ambiguous. A git-quoted
  # path ("b/x y") is unquoted; /dev/null (an added or deleted file's other side) is no path.
  # A section with no ---/+++ lines (a mode change, a pure rename, a binary) falls back to its header.
  printf '%s\n' "$INPUT" | awk '
    /^diff --git a\/.* b\// { if (hdr != "" && !seen) print hdr
                               hdr = $0; sub(/^diff --git a\/.* b\//, "", hdr); seen = 0; next }
    /^(\+\+\+|---) "?[ab]\// { p = substr($0, 5); sub(/^"/, "", p); sub(/"$/, "", p); print substr(p, 3); seen = 1; next }
    /^=== FILE: .* ===$/   { sub(/^=== FILE: /, ""); sub(/ ===$/, ""); print }
    END { if (hdr != "" && !seen) print hdr }' | LC_ALL=C sort -u
}

# _ar_pass_session — the agent session this pass runs in: ZUVO_ADV_SESSION (a caller's own name for it), else
# Claude Code's CLAUDE_CODE_SESSION_ID, else Codex's thread or session id. Empty for cron, CI, a bare shell, and an
# agent CLI that exports none: those are counted by _ar_pass_agent instead. Tabs and newlines would break the
# ledger's columns, so they are dropped.
_ar_pass_session() {
  printf '%s' "${ZUVO_ADV_SESSION:-${CLAUDE_CODE_SESSION_ID:-${CODEX_THREAD_ID:-${CODEX_SESSION_ID:-}}}}" | tr -d '\t\n\r'
}

# _ar_pass_agent — the agent process this pass runs under: the nearest ancestor whose argv[0] names an agent CLI
# (claude, codex, cursor-agent, kimi, agy, gemini, qwen, opencode), as <name>:<pid>@<start>; the start keeps a
# reused pid from inheriting a dead process's passes. Empty when no ancestor is one (cron, CI, a bare shell).
# Why: a run with no session id used to count EVERY session's passes on the branch, so an independent reviewer that
# exports no id inherited the author's spent cap (tgm-flux RD-7585). Counting only id-less rows instead would let an
# agent reset its own cap by unsetting its session variable; its process is what unsetting the variable does not
# shed — every pass records it, so an id-less run counts the passes of its own agent process whatever their session.
# A session id, when present, is trusted as the reviewer's identity on its own: one Codex app process hosts many
# threads, each its own reviewer, so matching on the process there would cap a reviewer thread with its author's
# passes — the defect this fixes. Inventing a new ZUVO_ADV_SESSION value therefore still starts a new count, as before.
# The residue, accepted: a pass detached from its agent (setsid + the parent exiting first) finds no ancestor and is
# counted with cron's passes — that takes a deliberate escape, not an unset variable.
# One ps for the whole table: walking it with a ps per ancestor would cost a fork per level on every pass.
_ar_pass_agent() {
  local hit pid name start stat
  hit="$(ps -A -o pid= -o ppid= -o args= 2>/dev/null | awk -v me="$$" '
    { n = split($3, seg, "/"); pp[$1] = $2; nm[$1] = tolower(seg[n]) }
    END { p = me
          for (d = 0; d < 64 && p != "" && p > 1; d++) {
            if (nm[p] ~ /^(claude|codex|cursor-agent|kimi|agy|gemini|qwen|opencode)([-_.][^ ]*)?$/) { print p, nm[p]; exit }
            p = pp[p] } }')" || hit=""
  [[ -n "$hit" ]] || return 0
  pid="${hit%% *}"; name="${hit#* }"
  # Linux: the start in clock ticks since boot (/proc/<pid>/stat field 22, counted after the ")" that ends the
  # command name, which may itself hold spaces). It never changes; `ps -o lstart` is derived from the wall clock
  # and moves with an NTP step or a resume, which would make one agent read as two. lstart elsewhere (macOS).
  start=""
  if [[ -r "/proc/$pid/stat" ]] && stat="$(cat "/proc/$pid/stat" 2>/dev/null)" && [[ "$stat" == *") "* ]]; then
    start="$(printf '%s' "${stat##*) }" | awk '{ print $20 }')" || start=""
  fi
  [[ -n "$start" ]] || start="$(ps -o lstart= -p "$pid" 2>/dev/null | tr -s ' ' | tr ' ' '_')" || start=""
  printf '%s:%s@%s' "$name" "$pid" "${start#_}" | tr -d '\t\n\r'
}

# _ar_pass_counted_mode — the modes that count against PASS_CAP (and so always leave a proof).
_ar_pass_counted_mode() { [[ "$REVIEW_MODE" =~ ^(code|test|security|migrate)$ ]]; }

# _ar_default_proof — the proof path of a counted pass run without --artifact: <ZUVO_OUTPUT_DIR or <repo>/zuvo>/proofs/
# auto-<branch>-<pass id>.txt (shared/includes/report-output-location.md). A pass that counts against PASS_CAP must
# leave a proof the pre-push gate can cite: three artifact-less passes used to spend the cap and leave nothing, so the
# agent could neither review again (exit 7) nor reference a proof (tgm-flux RD-7585).
_ar_default_proof() {
  local dir slug
  dir="${ZUVO_OUTPUT_DIR:-$(ar_repo_root)/zuvo}/proofs"
  slug="$(printf '%s' "$1" | LC_ALL=C tr -c 'A-Za-z0-9._-' '-' | cut -c1-60)"
  printf '%s/auto-%s-%s.txt' "$dir" "${slug:-branch}" "$2"
}

# _ar_proof_shown <path> — <path> relative to the checkout's top when it is inside it (what an `adversarial:` header
# cites), else as given.
_ar_proof_shown() {
  local top; top="$(ar_repo_root)"
  case "$1" in "$top"/*) printf '%s' "${1#"$top"/}" ;; *) printf '%s' "$1" ;; esac
}

# _ar_detached_key — the pass-cap key of a detached HEAD, which has no branch name to count under. Bare "detached"
# made every detached review of a repository ONE change: a review host that checks each PR out detached refused the
# fourth unrelated PR touching the same files (exit 7). The key, first that applies:
#   detached@<ZUVO_ADV_PASS_KEY> — the caller names the change (a PR number); a key outside [A-Za-z0-9._/-]{1,80}
#     is keyed by its checksum (k-<cksum>-<length>), so two keys never collapse into one by losing characters;
#   detached@<sha12> — the change's FIRST commit past the merge-base with the remote's default branch, which fix
#     commits appended on top keep, and an unrelated change (other commits) never shares;
#   detached@<sha12> of HEAD — no default branch to measure from, or HEAD is on it (uncommitted work on the base).
# Every detached key keeps the SHARED window (3 h), not a feature branch's 7 days: a review host re-reviews each
# push of a PR detached, and a stacked change (B on unmerged A) shares A's first commit — name it with the key.
_ar_pass_key_ok() { [[ ${#1} -le 80 && "$1" =~ ^[A-Za-z0-9._/-]+$ ]]; }
_ar_detached_key() {
  local key="${ZUVO_ADV_PASS_KEY:-}" top def mb first
  if [[ -n "$key" ]] && ! LC_ALL=C _ar_pass_key_ok "$key"; then
    key="k-$(printf '%s' "$key" | cksum | awk '{ print $1 "-" $2 }')"
  fi
  if [[ -n "$key" ]]; then printf 'detached@%s\n' "$key"; return 0; fi
  top="$(ar_repo_root)"
  def="$(git -C "$top" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)" || def=""
  if [[ -z "$def" ]]; then
    for def in refs/remotes/origin/main refs/remotes/origin/master refs/remotes/origin/develop ""; do
      [[ -z "$def" ]] || git -C "$top" rev-parse -q --verify "$def^{commit}" >/dev/null 2>&1 && break
    done
  fi
  first=""
  if [[ -n "$def" ]] && mb="$(git -C "$top" merge-base HEAD "$def" 2>/dev/null)" && [[ -n "$mb" ]]; then
    first="$(git -C "$top" rev-list --reverse --first-parent "$mb..HEAD" 2>/dev/null | head -n 1)"
  fi
  [[ -n "$first" ]] || first="$(git -C "$top" rev-parse -q --verify HEAD 2>/dev/null)" || first=""
  if [[ -n "$first" ]]; then printf 'detached@%s\n' "${first:0:12}"; else printf 'detached\n'; fi
}

# ar_check_pass_cap — refuse a fourth pass over the same change (exit PASS_CAP_EXIT) and set up the record
# _ar_record_pass writes once this pass has reviewed something. Runs before the input is chunked, so a chunked
# pass counts ONCE: the parent checks, and every part records under the parent's ZUVO_ADV_PASS_ID.
ar_check_pass_cap() {
PASS_RECORD=""
# Set here and nowhere else: a value inherited from the caller's environment would let an unwritable --artifact
# the caller DID ask for pass as a mere warning.
AR_AUTO_PROOF=0
[[ "$DRY_RUN" != true && "$DOCTOR" != true && "$LIST_PROVIDERS" != true ]] || return 0
_ar_pass_counted_mode || return 0
# A test-harness run (mock providers, fake lane binaries) re-reviews the same fixture files on purpose, so it
# neither counts nor is capped — unless the suite is testing the cap itself (ZUVO_ADV_PASS_CAP_TEST=1).
# ZUVO_ADVERSARIAL_TEST_HARNESS is the suites' switch; a real review never sets it.
if [[ "${ZUVO_ADVERSARIAL_TEST_HARNESS:-}" == 1 && "${ZUVO_ADV_PASS_CAP_TEST:-0}" != 1 ]]; then
  return 0
fi
local files root branch ledger now n window session agent counted proof proofs=""
files="$(_ar_pass_files)"
[[ -n "$files" ]] || return 0
session="$(_ar_pass_session)"
# Recorded on every row, with or without a session id: the passes an agent ran under its id are exactly the ones
# its id-less re-run must still count.
agent="$(_ar_pass_agent)"
# The repository, not the worktree: a second worktree of the same branch is the same change.
root="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || root=""
[[ -n "$root" ]] || root="$(ar_repo_root)"
# The branch of THIS worktree: $root is the shared git dir, whose HEAD is the main worktree's.
branch="$(git -C "$(ar_repo_root)" symbolic-ref -q --short HEAD 2>/dev/null)" || branch=""
[[ -n "$branch" ]] || branch="$(_ar_detached_key)"
# Shared: the usual default names, the remote's own default branch (whatever it is called), and a detached HEAD.
local shared_branch
shared_branch="$(git -C "$(ar_repo_root)" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)" || shared_branch=""
shared_branch="${shared_branch#origin/}"
case "$branch" in
  main|master|develop|trunk|detached|detached@*) window=$PASS_WINDOW_SHARED_S ;;
  *) if [[ -n "$shared_branch" && "$branch" == "$shared_branch" ]]; then window=$PASS_WINDOW_SHARED_S; else window=$PASS_WINDOW_S; fi ;;
esac
ledger="${ZUVO_HOME:-$HOME/.zuvo}/adversarial-passes.tsv"
now="$(date +%s)"
if [[ -z "${ZUVO_ADV_CHUNK:-}" ]]; then
  export ZUVO_ADV_PASS_ID="${ZUVO_ADV_PASS_ID:-$now-$$}"
  # One row per process that reviewed something; a pass is every row sharing a pass id, its files their union.
  n=0
  if [[ -s "$ledger" ]]; then
    # Through the environment, not -v: BSD awk (macOS) refuses a -v value holding a newline, and a refusal
    # here would read as "no earlier passes" — the cap silently off.
    # Column 6 is the session, 7 the pass's proof, 8 its agent process (_ar_pass_agent); each is empty in rows
    # written before it existed. Whose passes count:
    #   a session id      — that session's rows, nothing else;
    #   no id, an agent   — the rows of that agent process, whatever their session (unsetting the session
    #                       variable does not reset the cap), and rows with no identity at all;
    #   no id, no agent   — rows with no identity at all (cron, CI, a bare shell, rows older than column 6).
    # Line 1 of the result is the count; each later line is "<time>\t<proof>" of a counted pass that has one.
    counted="$(ZUVO_ADV_PASS_FILES="$files" ZUVO_ADV_PASS_ROOT="$root" ZUVO_ADV_PASS_BRANCH="$branch" \
      ZUVO_ADV_PASS_SESSION="$session" ZUVO_ADV_PASS_AGENT="$agent" awk -F'\t' -v since=$(( now - window )) '
      BEGIN { nc = split(ENVIRON["ZUVO_ADV_PASS_FILES"], want, "\n")
              root = ENVIRON["ZUVO_ADV_PASS_ROOT"]; branch = ENVIRON["ZUVO_ADV_PASS_BRANCH"]
              sess = ENVIRON["ZUVO_ADV_PASS_SESSION"]; agent = ENVIRON["ZUVO_ADV_PASS_AGENT"] }
      function mine() {
        if (sess != "") return $6 == sess
        return (agent != "" && $8 == agent) || ($6 == "" && $8 == "")
      }
      $1 >= since && $3 == root && $4 == branch && $2 != ENVIRON["ZUVO_ADV_PASS_ID"] && mine() {
        m = split($5, f, "\037")
        for (i = 1; i <= m; i++) if (f[i] != "" && !((($2) SUBSEP f[i]) in seen)) { seen[$2 SUBSEP f[i]] = 1; size[$2]++ }
        pass[$2] = 1; if (!($2 in at)) at[$2] = $1
        if ($7 != "" && !($2 in proof)) proof[$2] = $7 }
      END { c = 0
        for (p in pass) { hit = 0; for (i = 1; i <= nc; i++) if ((p SUBSEP want[i]) in seen) hit++
                          small = (size[p] < nc) ? size[p] : nc
                          if (small > 0 && 2 * hit >= small) { c++; if (p in proof) out = out at[p] "\t" proof[p] "\n" } }
        printf "%s\n%s", c, out }' "$ledger" 2>/dev/null)" || counted=0
    n="${counted%%$'\n'*}"
    [[ "$counted" != *$'\n'* ]] || proofs="${counted#*$'\n'}"
  fi
  if [[ "${n:-0}" -ge "$PASS_CAP" ]]; then
    echo "PASS CAP: ${n} adversarial passes already reviewed these files on ${branch} $( if [[ -n "$session" ]]; then echo "in this session"; elif [[ -n "$agent" ]]; then echo "in this agent process (${agent%%:*}, no session id)"; else echo "in the last $(( window / 3600 ))h"; fi) — the cap is ${PASS_CAP}, with no override." >&2
    echo "  Nothing was reviewed. Do not run another pass: record what is still open as known concerns" >&2
    echo "  (shared/includes/adversarial-loop.md, Step 5). A verified CRITICAL left open still means 'not complete'." >&2
    # The passes that spent the cap left proofs: name them, so the review artifact can cite them (`adversarial:`).
    if [[ -n "$proofs" ]]; then
      echo "  Proofs of those passes — cite them as \`adversarial:\` in memory/reviews/<base7>..<head7>-<slug>.md:" >&2
      printf '%s' "$proofs" | LC_ALL=C sort -n | cut -f2- | while IFS= read -r proof; do
        [[ -n "$proof" ]] || continue
        if [[ -f "$proof" ]]; then echo "    $(_ar_proof_shown "$proof")" >&2
        else echo "    $(_ar_proof_shown "$proof")  (missing — moved or deleted since)" >&2; fi
      done
    fi
    exit "$PASS_CAP_EXIT"
  fi
  # Every pass says its number: an agent that never loaded adversarial-loop.md learns the cap from the driver.
  export ZUVO_ADV_PASS_NUMBER="$(( n + 1 ))/${PASS_CAP}"
  if [[ "$n" -lt $(( PASS_CAP - 1 )) ]]; then
    echo "  NOTE: adversarial pass $(( n + 1 )) of ${PASS_CAP} for these files on ${branch} (the driver refuses a $(( PASS_CAP + 1 ))th)." >&2
  else
    echo "  NOTE: this is adversarial pass ${PASS_CAP} of ${PASS_CAP} for these files — the last one." >&2
  fi
  # A counted pass always leaves a proof. Without --artifact it gets a default one — set before the input is
  # chunked, so every part reviews into it and the parts merge there.
  if [[ -z "$ARTIFACT_PATH" ]]; then
    ARTIFACT_PATH="$(_ar_default_proof "$branch" "$ZUVO_ADV_PASS_ID")"
    AR_AUTO_PROOF=1
    echo "  PROOF: no --artifact given — this pass's proof goes to $(_ar_proof_shown "$ARTIFACT_PATH") (cite it as \`adversarial:\` in the review artifact)" >&2
  fi
  case "$ARTIFACT_PATH" in /*) proof="$ARTIFACT_PATH" ;; *) proof="$(pwd -P)/$ARTIFACT_PATH" ;; esac
  # For the parts' ledger rows: a part records the parent's proof, not its own temporary one.
  export ZUVO_ADV_PASS_PROOF="$proof"
else
  proof="${ZUVO_ADV_PASS_PROOF:-}"
fi
PASS_RECORD="$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s' "${ZUVO_ADV_PASS_ID:-$now-$$}" "$root" "$branch" \
  "$(printf '%s' "$files" | tr '\n' '\037')" "$session" "$(printf '%s' "$proof" | tr -d '\t\n\r')" "$agent")"
}

# _ar_record_pass — append this process's row to the pass ledger once it has reviewed something. Best effort: a
# ledger that cannot be written loses one count, never the review.
_ar_record_pass() {
  [[ -n "${PASS_RECORD:-}" ]] || return 0
  local led="${ZUVO_HOME:-$HOME/.zuvo}/adversarial-passes.tsv" now
  now="$(date +%s)"
  printf '%s\t%s\n' "$now" "$PASS_RECORD" >> "$led" 2>/dev/null || true
  # Rows older than the window can never count again: past 1 MB, keep only the window.
  if [[ "$(wc -c < "$led" 2>/dev/null || echo 0)" -gt 1048576 ]]; then
    awk -F'\t' -v since=$(( now - PASS_WINDOW_S )) '$1 >= since' "$led" > "$led.$$" 2>/dev/null \
      && mv -f "$led.$$" "$led" 2>/dev/null || true
  fi
}
