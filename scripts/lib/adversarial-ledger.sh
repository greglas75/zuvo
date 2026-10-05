# shellcheck shell=bash
# adversarial-ledger.sh — what the driver records across runs: the findings ledger (one row per
# fingerprinted finding, joined with verdicts; --record-disposition and --effectiveness), the run log
# (~/.zuvo/adversarial.log: header discipline and one row per lane), the provider-health ledger that
# benches failing lanes, and the finding counters both the log and the output use.
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_init_findings_ledger, ar_cmd_record_disposition, ar_cmd_effectiveness, ar_init_run_log,
# ar_update_provider_health. Functions: log_project, ledger_project, ledger_header, init_findings_header,
# init_log_header, adversarial_log_row, record_provider_health, _ar_lock, _ar_lock_stale, _ar_pid_alive,
# _ar_pid_age_s, _ar_mtime, _ar_unlock, result_json_text, findings_log_rows, count_findings.
#
# Phase bodies sit at column 0, as the top-level code they were cut from (afd4ed0d, byte for byte then):
# indenting them would change the multi-line prompt strings and heredocs several carry, and made the
# move provable by diff. Each runs once, from the driver's Main, at the point it used to.
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
# without ever rewriting it. Parallel runs append to these files, and a truncating write between a size
# check and the write would erase what another run just appended — so an empty file is created with
# noclobber and the header APPENDED (at worst two runs both append it; readers skip header lines). A file
# whose first line is another schema gets a one-time `#schema<TAB><header>` marker appended instead, and
# a sentinel <file>.schema — compared BY CONTENT, so the next column addition heals itself, where the old
# `.schema16` sentinel kept a 16-column marker over seventeen-field rows — records that it is there. The
# sentinel is written only once the marker is confirmed on disk, and read with a builtin: no re-read of a
# multi-megabyte log on every run. One routine: the findings ledger's copy had the race fixed, the run
# log's did not.
ledger_header() {
  local file="$1" header="$2" marker sentinel confirmed=""
  marker="#schema	$header"
  if [[ ! -s "$file" ]]; then
    # Under the file's lock, checked again: two runs on a fresh file each saw it empty and each appended the
    # header — the second one after the first one's rows. A lock that cannot be had writes no header.
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
# so it is the owner's alone (0700, tightened when it already existed), as the failure evidence beside it is.
# When it cannot be made, the log goes to the private temp dir runs share (ar_init_failure_cache), swept
# like the home one; failing that, to this run's own temp dir, removed when the run ends — so it is not
# kept, and the WARN says so. Never ".": that was the repository under review, so the run wrote its log
# into the reviewed tree and the tamper-check then reported the reviewers for changing it. Never a mktemp
# dir of its own either: nothing removed or swept those, and a host whose home stayed unwritable piled up
# every reviewed diff in $TMPDIR.
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
return 0
}

init_log_header() {
  # `-s`, not `-f`, inside ledger_header: a truncated (0-byte) log still exists, and treating it as
  # "already has a header" would leave every later row undescribed.
  ledger_header "$LOG_FILE" "$LOG_HEADER"
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
# _ar_lock <lock-dir> <seconds> — a lock taken as a DIRECTORY (mkdir is atomic everywhere this runs;
# flock(1) is not on macOS) that holds its holder's pid. Waits up to <seconds>. Status 0 taken, 1 still held.
# Release: _ar_unlock <lock-dir>. Status 2 at once when the lock's directory is missing or not writable:
# mkdir would fail there for every poll, and the caller waited out the whole wait to blame another run.
#
# A lock whose holder is gone (_ar_lock_stale) was left by a run that died inside its critical section, and
# is broken — but only under a second lock, <lock-dir>.break, with the holder read AGAIN there. Breakers take
# turns, and nothing but a breaker removes a lock whose holder is dead, so what was read under .break cannot
# change before the rename: a waiter can never break a lock another waiter has just taken. (It was rmdir after
# an age check, and two waiters could both judge one lock stale and both proceed.) A .break left by a breaker
# killed mid-break — a break takes milliseconds — is cleared after a minute.
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

# _ar_lock_stale <lock-dir> — the holder is gone: no process has its pid; or the process that has it started
# AFTER the lock was taken, so it is not the holder (the pid was reused); or the lock has no pid and is older
# than 2 minutes (a holder killed between its mkdir and its pid write, or a driver from before the pid).
# `kill -0` alone was the test: it fails with EPERM for a live process of another user, which was then
# broken as dead, and it succeeds for a reused pid, whose lock was then never broken.
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

# _ar_pid_alive <pid> — a process has that pid, whoever owns it (ps -p; kill -0 only without ps).
_ar_pid_alive() {
  if command -v ps >/dev/null 2>&1; then ps -p "$1" >/dev/null 2>&1; return; fi
  kill -0 "$1" 2>/dev/null
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
  # Read, recompute, mv over: parallel reviews do exactly that at the same moment, and without a lock
  # the last writer erased the other's increments and resets. A run that cannot take the lock records
  # nothing (one lost update, said) rather than clobbering a concurrent one.
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
  # no-runner (the lane could not start: model-subprocess.sh did not load). A broken install is not a
  # broken lane: counted here, it would bench a healthy lane long after the install is fixed.
  models=""
  for _rp in $(printf '%s' "$PROVIDER_OUTCOMES" | tr ',' ' '); do
    _rn="${_rp%%:*}"; [[ -n "$_rn" ]] || continue
    models="${models}${_rn}	$(ledger_model "$_rn")
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
