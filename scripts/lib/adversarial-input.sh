# shellcheck shell=bash
# adversarial-input.sh — the review input: the --files list and its guard, collection (stdin, diff,
# files), the per-mode size cap, the reviewable-material check (exit 5), auto-chunking into child runs,
# truncation as the last resort, and the tree tamper-check around the providers.
# Sourced by scripts/adversarial-review.sh only; never executed.
#
# Phases: ar_guard_file_list, ar_collect_input, ar_set_input_cap, ar_set_chunk_boundary,
# ar_check_material, ar_chunk_input, ar_truncate_input. Functions: build_file_list, collect_input,
# collect_files_input, _no_material, _tamper_capture (called from Main), _tamper_verify.
#
# Phase bodies sit at column 0, byte for byte the top-level code they were cut from:
# indenting them would change the multi-line prompt strings and heredocs several carry, and would
# make the move unprovable by diff. Each runs once, from the driver's Main, at the point it used to.
# Linted as part of the whole program: tests/hooks/test-adversarial-driver-modules.sh runs shellcheck on
# the driver with every module inlined (the repo's shellcheck gate skips files without a shebang).

# ─── Input collection ───────────────────────────────────────────

# The material and size rules, named once (CQ12). MIN_DOC_WORDS / MIN_REPORT_WORDS / MIN_PLAN_TASKS — below
# them a spec or article, an audit or test-audit report, a plan is not reviewable material (exit 5).
# CHUNK_NOTE_HEADROOM_CHARS — what each chunk leaves free under MAX_CHARS for the context note it carries.
# OMITTED_FILES_SHOWN — how many dropped files a truncated input names.
MIN_DOC_WORDS=200
MIN_REPORT_WORDS=500
MIN_PLAN_TASKS=3
CHUNK_NOTE_HEADROOM_CHARS=500
OMITTED_FILES_SHOWN=20

build_file_list() {
  # Parse once so input collection and missing-file validation use the same paths.
  # Looking for generated headers in INPUT also scans user-controlled file contents.
  local file_list="" raw_files="$FILES" candidate="" best="" token=""
  local i j best_end n
  local -a words=()
  if [[ "$raw_files" == *$'\n'* ]]; then
    # Newline-separated — safe, preserves spaces in paths.
    file_list="$raw_files"
  else
    # The split is literal: shell glob expansion could select unrelated files.
    [[ "$raw_files" =~ [^[:space:]] ]] || return 0
    read -r -a words <<< "$raw_files"
    n=${#words[@]}
    i=0
    while (( i < n )); do
      # Prefer the longest existing path from this token. A shorter real file
      # may share its first words; -e also preserves unreadable paths so the
      # guard can give their real reason instead of splitting them apart.
      candidate=""; best=""; best_end=-1
      for (( j=i; j<n; j++ )); do
        token="${words[$j]}"
        candidate="${candidate:+$candidate }$token"
        # A longer string cannot name a filesystem path on supported hosts.
        (( ${#candidate} <= 4096 )) || break
        # -e alone: anything readable also exists, so a `-r && ! -d` alternative could never add a
        # match. A directory is accepted here and reported as "directory" (and skipped) downstream.
        if [[ -e "$candidate" ]]; then
          best="$candidate"; best_end=$j
        fi
      done
      if (( best_end >= i )); then
        file_list="${file_list}${best}"$'\n'
        i=$((best_end + 1))
        continue
      fi

      # Missing paths cannot be unambiguously reconstructed from spaces.
      # Keep each token distinct; callers with missing paths containing spaces
      # can use --file or a newline-separated list.
      file_list="${file_list}${words[$i]}"$'\n'
      i=$((i + 1))
    done
  fi
  printf '%s' "$file_list"
}

# ar_guard_file_list — --files: parse the list once (FILE_LIST); nothing reviewable exits 2, a partial list WARNs.
ar_guard_file_list() {
FILE_LIST=""
[[ "$INPUT_MODE" != files ]] || FILE_LIST=$(build_file_list)

# Reject a --files request when none of its paths is reviewable. Count the
# requested paths, not the generated headers/stubs in INPUT: file contents may
# contain lines identical to those markers.
if [[ "$INPUT_MODE" == "files" ]]; then
  _files_listed=0
  _files_missing=0
  _files_other=0
  _missing_paths=""
  _unusable_reasons=""
  while IFS= read -r _file || [[ -n "$_file" ]]; do
    [[ -n "$_file" ]] || continue
    _files_listed=$((_files_listed + 1))
    _reason=""
    if [[ -d "$_file" ]]; then
      _reason="directory"
      _files_other=$((_files_other + 1))
    elif [[ ! -r "$_file" ]]; then
      if [[ -e "$_file" ]]; then
        _reason="unreadable"
        _files_other=$((_files_other + 1))
      else
        _reason="missing"
      fi
    fi
    if [[ -n "$_reason" ]]; then
      _files_missing=$((_files_missing + 1))
      _missing_paths="${_missing_paths}${_file}"$'\n'
      _unusable_reasons="${_unusable_reasons}${_file}: ${_reason}"$'\n'
    fi
  done <<< "$FILE_LIST"
  if (( _files_listed > 0 && _files_missing == _files_listed )); then
    if (( _files_other == 0 )); then
      echo "ERROR: none of the ${_files_listed} --files path(s) exist — nothing to review. Check that the list expanded (zsh does not word-split \$VAR) and that the paths resolve from $(pwd)." >&2
    else
      echo "ERROR: none of the ${_files_listed} --files path(s) are reviewable:" >&2
    fi
    printf '%s' "$_unusable_reasons" | sed '/^$/d; s/^/  /' >&2
    exit 2
  elif (( _files_missing > 0 )); then
    if (( _files_other == 0 )); then
      echo "WARN: ${_files_missing} of ${_files_listed} --files path(s) do not exist and are NOT reviewed:" >&2
    else
      echo "WARN: ${_files_missing} of ${_files_listed} --files path(s) are not reviewable and are NOT reviewed:" >&2
    fi
    if (( _files_other == 0 )); then
      printf '%s' "$_missing_paths" | sed '/^$/d; s/^/  /' >&2
    else
      printf '%s' "$_unusable_reasons" | sed '/^$/d; s/^/  /' >&2
    fi
  fi
fi
return 0
}

# collect_input — stdin or the diff, on stdout. Status 3 when stdin did not end in time (said on stderr);
# anything else goes on to the caller's empty-input check, as before.
collect_input() {
  case "$INPUT_MODE" in
    stdin)
      # A terminal is not input. Otherwise wait up to ZUVO_STDIN_WAIT seconds (10) for the FIRST byte, so a
      # caller that pipes nothing cannot block the run forever — then read to the end, bounded by
      # ZUVO_STDIN_TIMEOUT (300) and refused, not cut, when it runs out. This was `timeout 10 cat || true`:
      # a cap on the WHOLE read, so a producer still writing after 10 s (a big git diff, a slow pipeline)
      # was cut off mid-diff, the 124 swallowed, and half a change reviewed as all of it.
      [[ -t 0 ]] && return 0
      local _first="" _cap _rc=0
      IFS= read -r -d '' -n 1 -t "$(ar_env_int ZUVO_STDIN_WAIT 10 1)" _first || [[ -n "$_first" ]] || return 0
      printf '%s' "$_first"
      _cap="$(ar_env_int ZUVO_STDIN_TIMEOUT 300 1)"
      if command -v timeout >/dev/null 2>&1; then
        timeout "$_cap" cat || _rc=$?
      else
        cat || _rc=$?
      fi
      if [[ "$_rc" -ne 0 ]]; then
        if [[ "$_rc" -eq 124 ]]; then
          echo "ERROR: stdin did not end within ${_cap}s (ZUVO_STDIN_TIMEOUT) — refusing to review part of an input." >&2
        else
          echo "ERROR: reading stdin failed (exit $_rc) — refusing to review part of an input." >&2
        fi
        return 3
      fi
      ;;
    diff)
      git diff "$DIFF_REF"..HEAD 2>/dev/null || git diff "$DIFF_REF"
      ;;
  esac
}

# collect_files_input — --files mode. Runs in THIS shell, not in `$(…)`, because it has two outputs: INPUT,
# and COLLECTED_BLOBS — the git blob id of each file's bytes AS THEY WENT INTO INPUT, one per line, which is
# what write_artifact records as reviewed. Not FILE_LIST (what was ASKED for: a path can pass the guard above
# and still fail to read here), and not the file hashed again when the review ends: the checkout stays live
# for the minutes a review takes, and an edit made meanwhile would be recorded as reviewed bytes no provider
# saw. The id is taken only when an artifact was asked for (one git process per file).
COLLECTED_BLOBS=""
collect_files_input() {
  local f abs_path body oid
  INPUT=""; COLLECTED_BLOBS=""
  while IFS= read -r f || [[ -n "$f" ]]; do
    [[ -z "$f" ]] && continue
    # The earlier guard reports unusable paths; no stub is review material.
    [[ ! -d "$f" && -r "$f" ]] || continue
    # Resolve to absolute path from CWD (not from temp/cache dirs)
    if [[ -f "$f" ]]; then
      abs_path=$(cd "$(dirname "$f")" 2>/dev/null && pwd)/$(basename "$f")
    else
      abs_path="$f"
    fi
    # Read BEFORE the header goes out. A file that passed the guard can still fail now (removed or made
    # unreadable since, an I/O error); its header used to go out anyway, followed by a "(file not found)"
    # stub that reached the providers as review material. The trailing `x` carries the file's own
    # trailing newlines through the command substitution.
    if ! body="$(cat -- "$abs_path" 2>/dev/null && printf x)"; then
      echo "WARN: $f could not be read when the review input was collected — NOT reviewed" >&2
      continue
    fi
    # Show basename in header to prevent providers from reading stale cached paths
    body="${body%x}"
    INPUT+="=== FILE: $(basename "$abs_path") ==="$'\n'"$body"$'\n'
    if [[ -n "$ARTIFACT_PATH" ]]; then
      # These exact bytes, under the path's own attributes (--path: the clean filters `git add` applies, so
      # the id matches what the pre-commit gate sees staged). A file whose bytes a shell variable cannot hold
      # (a NUL) gets an id that matches no blob of it — the gate then refuses it, which is the safe side.
      if oid="$(printf '%s' "$body" | git hash-object --stdin --path="$abs_path" 2>/dev/null)" && [[ -n "$oid" ]]; then
        COLLECTED_BLOBS+="$oid"$'\n'
      else
        echo "WARN: $f — its blob id could not be taken; the artifact will not record it as reviewed" >&2
      fi
    fi
  done <<< "$FILE_LIST"
  # Byte for byte what `INPUT=$(collect_input)` gave: a command substitution drops every trailing newline.
  while [[ "$INPUT" == *$'\n' ]]; do INPUT="${INPUT%$'\n'}"; done
}

# ar_collect_input — INPUT from stdin, the diff, the files or the blind-audit prompt; an empty one exits 2.
ar_collect_input() {
# Doctor mode needs no review input (it sends its own probe prompt) — skipping
# collect_input also avoids the 10s stdin wait on a bare `adversarial-review --doctor`.
  if [[ "$DOCTOR" == "true" || "$LIST_PROVIDERS" == "true" ]]; then
    INPUT="(no review input needed)"
elif [[ "$REVIEW_MODE" == blind-audit ]]; then
  INPUT="$BA_PROMPT"   # built above from --production/--test; stdin is never read in this mode
elif [[ "$INPUT_MODE" == files ]]; then
  collect_files_input
else
  # Status 3: stdin did not end (or broke off) — collect_input said so; nothing partial is reviewed.
  _ci_rc=0; INPUT=$(collect_input) || _ci_rc=$?
  [[ "$_ci_rc" -ne 3 ]] || exit 2
fi

# Whitespace-only counts as no input: a piped diff that matched nothing is often a bare newline.
if [[ -z "$INPUT" || ! "$INPUT" =~ [^[:space:]] ]]; then
  echo "ERROR: No input provided. Pipe a diff or use --diff/--files." >&2
  exit 2
fi
return 0
}

# ar_set_input_cap — MAX_CHARS — the per-mode input cap and its ZUVO_ADV_MAX_CHARS override.
ar_set_input_cap() {
# Chunk/truncate boundary for oversized input (SIGPIPE-safe, line boundary).
#
# THE OLD REASON WAS "to avoid token limits" AND IT IS NO LONGER TRUE. 30,000 chars is ~8k
# tokens; every lane in the current set holds far more (gpt-oss-120b 131k, qwen and deepseek
# 1M, glm-5.3-flash 1.3M, Gemini 1M+). Anyone reading that comment now concludes the cap is
# obsolete. What actually keeps it is different, and measured over 66,622 successful provider
# calls in ~/.zuvo/adversarial.log:
#
#   input size     runs    findings/run   CRITICAL/run   findings per 10k chars
#   0-5k          12,738       1.34           0.27            10.65
#   5-15k         14,676       4.50           0.99             4.60
#   15-25k        18,828       4.59           0.65             2.24
#   25-30k        17,112       4.56           0.62             1.66
#   >30k           3,268       4.40           0.77             1.30
#
# A reviewer returns roughly a FIXED-SIZE answer — ~4.5 findings — however much you give it.
# Doubling the input does not double the findings, it dilutes them. So splitting is not a way
# around a context limit; it is a way to buy more ANSWERS: five chunks yield ~22 findings where
# one big call yields ~4.5. (Observational, not causal: large ranges may carry less novel logic
# per kilobyte, and this column counts findings, not judged-real ones.)
#
# Two hard constraints back it up. The panel is bounded by its SMALLEST-context member, not its
# largest. And PROVIDER_TIMEOUT is 500s while qwen already averaged 336s at ~30k input — ten
# times the payload would cross the ceiling, which is exactly how the openrouter lane collected
# four 500s timeouts and got benched.
#
# ZUVO_ADV_MAX_CHARS overrides it, which is what makes "is 30,000 the right number?" an
# experiment rather than an opinion.
MAX_CHARS=30000
[[ "$REVIEW_MODE" =~ ^(spec|plan|audit|migrate|article)$ ]] && MAX_CHARS=50000
MAX_CHARS="$(ar_env_int ZUVO_ADV_MAX_CHARS "$MAX_CHARS" 2000)"   # under 2000 a chunk is all note
# --mode blind-audit sends both files WHOLE (its byte gates decided above): no cap, chunking or truncation.
if [[ "$REVIEW_MODE" == blind-audit ]]; then MAX_CHARS=$AR_NUM_CAP; fi
return 0
}

# ar_set_chunk_boundary — where oversized input is split: file headers for diffs, h2+ headings for documents.
ar_set_chunk_boundary() {
# ─── Auto-chunk oversized input at FILE boundaries (2026-08-01) ───────────────
# 32% of all runs on record hit MAX_CHARS (2,214 of 6,920 in ~/.zuvo/adversarial.log;
# 45% in June) and until the truncation WARN landed the overflow was cut SILENTLY —
# one 543KB range dropped the file holding five CRITICALs from three providers.
# Chunking was caller folklore rediscovered per run; now the script owns it: split
# the input at file boundaries, re-invoke ITSELF once per chunk (ZUVO_ADV_CHUNK is
# the recursion guard — a child never chunks again), merge outputs and exit codes.
# Truncation remains only for: input with fewer than 2 boundaries to cut at, a
# single section bigger than the cap (the child's truncate path, loud WARN), or an
# explicit --no-chunk / ZUVO_ADV_NO_CHUNK=1.
#
# 2026-08-03 — document modes were chunk-EXEMPT until now, on the reasoning that a
# spec/plan is "one artifact, no file boundaries to cut at". That reasoning was
# wrong, and it was expensive: a plan has `### Task 7:` per task and a spec has
# `## `, which are boundaries every bit as real as `diff --git`. Measured over
# ~/.zuvo/adversarial.log (47,912 rows): 264 of 1,601 plan/spec/audit/migrate runs
# hit the 50K cap and were SILENTLY CUT — ~16% of every plan review ever run judged
# roughly 60% of the plan it was asked to review, and the reviewer had no way to
# know which 40% it never saw. Chunking these needs no new machinery; it only ever
# needed the right boundary regex.
#
# Boundary by input shape, not by mode name:
#   docs  -> `^##+ ` (h2+). Deliberately NOT `^#+ `: a plan is full of fenced bash
#            whose `# comment` lines would otherwise split it into confetti. The
#            h1 title is also skipped — there is exactly one and it is not a
#            section boundary.
#   diffs -> the file headers, unchanged.
_ck_boundary_re='^(diff --git |=== FILE: )'
_ck_fence=0
if [[ "$REVIEW_MODE" =~ ^(spec|plan|audit|migrate|article)$ ]]; then
  _ck_boundary_re='^##+ '
  _ck_fence=1   # ignore headings inside ``` / ~~~ blocks (see the awk below)
fi
_chunk_headers=0
return 0
}

# The material/minimum check runs HERE, before the chunk splitter below, so the PARENT validates
# the payload it was actually given. It used to sit ~200 lines further down, after chunking — so a
# payload with nothing to judge was first cut into parts, and each part was then measured instead
# of the whole. Found by the second adversarial pass on this branch.

# ─── Nothing to judge? Say so — do NOT exit 0 ─────────────────────────────────
#
# Every branch below used to `exit 0`, and a caller cannot tell that apart from a completed clean
# review: it records coverage, ticks "adversarial review ran", and writes an artifact whose proof
# no provider ever produced. Three live instances were found in one pass (2026-09-18):
#   * a pass-2/3 payload from skills/review/SKILL.md:774,779 — `echo "PRIOR FINDINGS: …"` plus a
#     `git diff` that came back EMPTY. Non-whitespace, so the guard above lets it through; the
#     providers get a sentence of metadata and answer "0 findings", and `REVIEW BY:` lands in the
#     proof the push gate reads;
#   * the tail chunk of a split plan (skills/plan/SKILL.md:454-461) — below the 3-task minimum
#     purely because it is the LAST PART of a long document;
#   * the short re-audit report from shared/includes/test-quality-gate.md:45, while test-audit
#     ticks "adversarial review ran".
# So: exit 5, a code that means "not reviewed", and never silently succeed.
#
# A CHUNK CHILD IS EXEMPT. The parent validated the whole payload before splitting it, so a part
# is not a short document — applying the per-mode minimum to parts is precisely how the tail of a
# long plan went unreviewed while the Review Trail recorded it as covered.

_no_material() {   # $1 = reason
  echo "Adversarial review: NO REVIEWABLE MATERIAL — $1." >&2
  echo "  Nothing was sent to any provider. This is NOT a completed review: do not record coverage," >&2
  echo "  do not tick an adversarial gate, and do not treat an absent finding as a clean result." >&2
  exit 5
}

# ar_check_material — nothing to judge exits 5 before anything is sent (a chunk child skips only the length minimums).
ar_check_material() {
# `--doctor` and `--list-providers` never review anything by design — they set INPUT to a
# placeholder far above. Running the material check on them made both exit 5, i.e. the change
# broke the two commands used to diagnose the reviewer. Caught by the test below, not by reading.
# Is this process a CHILD CHUNK the parent dispatched? Only a `k/n` with n>=2 counts: a genuine
# split has at least two parts, so the trivial forgery `ZUVO_ADV_CHUNK=1/1` buys nothing.
#
# The exemption is deliberately NARROW — it covers ONLY the per-mode length minimums, never the
# code-material check below. The first cut exempted both, which made this env var a bypass any
# caller could type for the correctness gate itself: `ZUVO_ADV_CHUNK=1/1 adversarial-review
# --mode code` on an empty payload would have sailed through the very check this commit adds.
# An escape an agent can type is not an escape, it is the hole (see the repo's own
# no-agent-typable-bypass rule). Length minimums are a COST heuristic — forging one wastes
# provider budget on a short document and cannot manufacture false coverage — so they stay
# exempt for parts of a split document, which is what the exemption was for.
_is_chunk_child=false
if [[ "${ZUVO_ADV_CHUNK:-}" =~ ^[0-9]+/([0-9]+)$ && "${BASH_REMATCH[1]}" -ge 2 ]]; then
  _is_chunk_child=true
fi

if [[ "$DOCTOR" != "true" && "$LIST_PROVIDERS" != "true" && "$REVIEW_MODE" != blind-audit ]]; then
  if [[ "$REVIEW_MODE" =~ ^(spec|article)$ ]]; then
    word_count=$(printf '%s' "$INPUT" | wc -w | tr -d ' ')
    [[ "$_is_chunk_child" == "false" && "$word_count" -lt $MIN_DOC_WORDS ]] && _no_material "$REVIEW_MODE too short (${word_count} words, minimum $MIN_DOC_WORDS)"
  elif [[ "$REVIEW_MODE" == "plan" ]]; then
    task_count=$(printf '%s' "$INPUT" | grep -c '^### Task' || true)
    [[ "$_is_chunk_child" == "false" && "$task_count" -lt $MIN_PLAN_TASKS ]] && _no_material "plan too short (${task_count} tasks, minimum $MIN_PLAN_TASKS)"
  elif [[ "$REVIEW_MODE" =~ ^(audit|tests)$ ]]; then
    word_count=$(printf '%s' "$INPUT" | wc -w | tr -d ' ')
    [[ "$_is_chunk_child" == "false" && "$word_count" -lt $MIN_REPORT_WORDS ]] && _no_material "report too short (${word_count} words, minimum $MIN_REPORT_WORDS)"
  else
    # Code-ish modes. Material = a diff header, a hunk header, or a `=== FILE:` section from
    # --files — the three shapes every caller in this repo actually produces. Applies to chunk
    # children too: a chunk of a diff still contains hunks, so nothing legitimate is rejected.
    #
    # `<<<` and NOT `printf … | grep -q`. Under `set -o pipefail` that pipeline returns 141 on a
    # large input, because grep -q exits at the first match and printf dies of SIGPIPE — so `!`
    # fired and a REAL diff was declared empty. Reproduced on a 200k-line diff: the guard against
    # reviewing nothing would have blocked exactly the biggest reviews. Found by the adversarial
    # pass on this very commit.
    #
    # `[+-]` is NOT a marker here. It matched a markdown bullet (`- item`), so ordinary prose
    # counted as code and the guard passed payloads with no code at all — the false negative that
    # mirrors the false positive above.
    if ! grep -qE '^(diff --git |@@ |=== FILE: )' <<< "$INPUT"; then
      _no_material "no diff hunks and no '=== FILE:' sections — pipe a diff or use --files (payload was ${#INPUT} chars)"
    fi
  fi
fi
return 0
}

# _ck_count_units [<file>] — the chunk boundaries in <file> (stdin without one): file headers, or in a
# document mode headings outside code fences — counted by the same rule the split itself uses. One copy:
# the dry-run plan once counted with a hardcoded diff regex and reported "files: 0" for every document.
_ck_count_units() {
  awk -v re="$_ck_boundary_re" -v fence="$_ck_fence" '
    fence && /^[[:space:]]*(```|~~~)/ { infence = !infence; next }
    !(fence && infence) && $0 ~ re    { n++ }
    END { print n + 0 }' "$@"
}

# ar_chunk_input — input over the cap with 2+ boundaries: review it chunk by chunk in child runs, then exit with the merged result.
ar_chunk_input() {
if [[ ${#INPUT} -gt $MAX_CHARS && "$REVIEW_MODE" != "tests" ]]; then
  _chunk_headers=$(printf '%s\n' "$INPUT" | _ck_count_units)
fi
if [[ ${#INPUT} -gt $MAX_CHARS && -z "${ZUVO_ADV_CHUNK:-}" && "$NO_CHUNK" != "true" \
      && "${ZUVO_ADV_NO_CHUNK:-0}" != "1" && "${_chunk_headers:-0}" -ge 2 ]]; then
  _ck_dir=$(mktemp -d "${TMPDIR:-/tmp}/zuvo-adv-chunks.XXXXXX")
  # Each chunk's review is a child run of this driver, started in the background and waited for, so an INT
  # or TERM reaches these traps at once: the running child is stopped (its own traps stop its lanes) before
  # the chunk dir it reads from is removed. With only the EXIT trap, a TERM removed the dir and left the
  # child review running, orphaned.
  _ck_pid=""
  _ck_stop() {
    [[ -n "$_ck_pid" ]] || return 0
    kill -TERM "$_ck_pid" 2>/dev/null || true
    wait "$_ck_pid" 2>/dev/null || true
  }
  trap 'rm -rf "$_ck_dir"' EXIT
  trap '_ck_stop; exit 130' INT
  trap '_ck_stop; exit 143' TERM

  # Pass 1: split into sections (sec-0000 = any preamble before the first header).
  # Fence tracking is enabled ONLY for document modes. A diff of a markdown file
  # legitimately contains ``` lines; letting those toggle in-fence state there
  # would suppress a real `diff --git` boundary and silently merge two files into
  # one chunk — so the toggle is gated on $_ck_fence, not applied universally.
  printf '%s\n' "$INPUT" | awk -v dir="$_ck_dir" -v re="$_ck_boundary_re" -v fence="$_ck_fence" '
    BEGIN { n = 0; infence = 0; fn = sprintf("%s/sec-%04d", dir, n) }
    fence && /^[[:space:]]*(```|~~~)/ { infence = !infence; print >> fn; next }
    !(fence && infence) && $0 ~ re { close(fn); n++; fn = sprintf("%s/sec-%04d", dir, n) }
    { print >> fn }
  '
  # Pass 2: pack sections greedily into chunks of at most MAX_CHARS-CHUNK_NOTE_HEADROOM_CHARS (headroom
  # for the per-chunk context note). A single section over the cap becomes its own
  # chunk — the child truncates it with the existing loud WARN; half of one file
  # still beats none, and every OTHER file keeps a full-fidelity review.
  _ck_budget=$((MAX_CHARS - CHUNK_NOTE_HEADROOM_CHARS))
  _ck_n=0; _ck_size=0; _ck_file=""
  for _sec in "$_ck_dir"/sec-*; do
    [[ -s "$_sec" ]] || continue
    _sec_size=$(wc -c < "$_sec" | tr -d ' ')
    if [[ -z "$_ck_file" || $((_ck_size + _sec_size)) -gt $_ck_budget && $_ck_size -gt 0 ]]; then
      _ck_n=$((_ck_n + 1)); _ck_file=$(printf '%s/chunk-%03d' "$_ck_dir" "$_ck_n"); _ck_size=0
    fi
    cat "$_sec" >> "$_ck_file"
    _ck_size=$((_ck_size + _sec_size))
  done

  _ck_bnd_label="file boundaries"
  [[ "$_ck_fence" -eq 1 ]] && _ck_bnd_label="section headings (h2+, outside code fences)"
  echo "CHUNKED INPUT: ${#INPUT} chars > ${MAX_CHARS} cap -> ${_ck_n} chunks at ${_ck_bnd_label} (no truncation)" >&2

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "=== DRY RUN — chunk plan ===" >&2
    for _ck in "$_ck_dir"/chunk-*; do
      # Count with the SAME boundary the split used — hardcoding the diff regex
      # here reported "files: 0" for every document chunk, which reads as "this
      # chunk is empty" in the one output a caller uses to sanity-check the plan.
      _ck_units=$(_ck_count_units "$_ck")
      echo "  $(basename "$_ck"): $(wc -c < "$_ck" | tr -d ' ') chars, $([[ "$_ck_fence" -eq 1 ]] && echo sections || echo files): ${_ck_units}" >&2
    done
    exit 0
  fi

  # Rebuild the child invocation from parsed state (never forward raw "$@" — the
  # input flags must not leak; each child reads its chunk on stdin).
  _ck_base_args=()
  case "$MULTI_MODE" in
    multi)  _ck_base_args+=(--multi) ;;
    single) _ck_base_args+=(--single) ;;
    rotate) _ck_base_args+=(--rotate) ;;
  esac
  [[ -n "$PROVIDER" ]]         && _ck_base_args+=(--provider "$PROVIDER")
  # One flag PER excluded provider — EXCLUDE_PROVIDER is a set. Passing it as a single
  # arg would hand the child a provider literally named "codex gemini", matching nothing.
  # `set -f` is NOT cosmetic here: an unquoted split does pathname expansion as well as
  # word-splitting, and --exclude takes arbitrary CLI text. With files named `codexAAA`/
  # `codexZZZ` in CWD, `--exclude 'codex*'` expanded to those filenames and `codex-5.3`
  # survived the filter — the named provider was NOT excluded, silently defeating the
  # host self-review guard this mechanism exists to enforce (verified 2026-08-11).
  # Arrays would be the other fix, but macOS ships bash 3.2 where `"${arr[@]}"` on an
  # empty array aborts under this script's `set -u`.
  set -f; for _xp in $EXCLUDE_PROVIDER; do _ck_base_args+=(--exclude "$_xp"); done; set +f
  [[ -n "$EXCLUDE_LAST" ]]     && _ck_base_args+=(--exclude-last "$EXCLUDE_LAST")
  [[ -n "$REVIEW_MODE" ]]      && _ck_base_args+=(--mode "$REVIEW_MODE")
  [[ "$OUTPUT_FORMAT" == "json" ]] && _ck_base_args+=(--json)
  if [[ -n "$KNOWN_FINDINGS" ]]; then
    while IFS= read -r _kf; do
      [[ -n "$_kf" ]] && _ck_base_args+=(--known-finding "$_kf")
    done <<< "$KNOWN_FINDINGS"
  fi

  _ck_rc=0; _ck_ok=0; _ck_fail=0; _ck_nomat=0; _ck_i=0
  for _ck in "$_ck_dir"/chunk-*; do
    _ck_i=$((_ck_i + 1))
    _ck_args=("${_ck_base_args[@]}")
    # The note must match what was actually split. Telling a plan reviewer that
    # "sibling FILES are reviewed in other chunks" invites it to report the
    # document as truncated or to flag cross-references it cannot see; say
    # plainly that this is one document cut into parts.
    if [[ "$_ck_fence" -eq 1 ]]; then
      _ck_note="[part ${_ck_i}/${_ck_n} of ONE document split at section headings — the other sections are reviewed in sibling parts; do NOT report the document as incomplete/truncated, and do NOT report a section or cross-reference you cannot see here as missing]"
    else
      _ck_note="[chunk ${_ck_i}/${_ck_n} of a larger range — sibling files are reviewed in other chunks; do NOT report them as missing]"
    fi
    _ck_args+=(--context "${CONTEXT_HINT:+$CONTEXT_HINT }${_ck_note}")
    if [[ -n "$ARTIFACT_PATH" ]]; then
      _ck_args+=(--artifact "$ARTIFACT_PATH")
      # chunk 1 respects the caller's append choice; later chunks always append
      # so one artifact accumulates every chunk's REVIEW BY evidence.
      if [[ "$_ck_i" -gt 1 || "$APPEND_ARTIFACT" == "true" ]]; then
        _ck_args+=(--append-artifact)
      fi
    fi
    _ck_child_rc=0
    ZUVO_ADV_CHUNK="${_ck_i}/${_ck_n}" "$0" "${_ck_args[@]}" \
      < "$_ck" > "$_ck_dir/out-${_ck_i}" 2> "$_ck_dir/err-${_ck_i}" &
    _ck_pid=$!
    wait "$_ck_pid" || _ck_child_rc=$?
    _ck_pid=""
    sed "s|^|  [chunk ${_ck_i}/${_ck_n}] |" "$_ck_dir/err-${_ck_i}" >&2 || true
    if [[ "$_ck_child_rc" -eq 130 || "$_ck_child_rc" -eq 143 ]]; then
      echo "CHUNKED: interrupted at chunk ${_ck_i}/${_ck_n}" >&2
      exit "$_ck_child_rc"
    fi
    # rc 5 (no material) is neither ok nor a failure: it means that part was never judged. It is
    # counted on its own so the CHUNKED line cannot imply coverage, and it does NOT become the
    # aggregate — one empty tail part must not mask the real verdict of the parts that WERE
    # reviewed, and must not report them as unreviewed either.
    if [[ "$_ck_child_rc" -eq 5 ]]; then
      _ck_nomat=$((_ck_nomat + 1))
    elif [[ "$_ck_child_rc" -eq 0 ]]; then
      _ck_ok=$((_ck_ok + 1))
    else
      _ck_fail=$((_ck_fail + 1))
      [[ "$_ck_child_rc" -gt "$_ck_rc" ]] && _ck_rc=$_ck_child_rc
    fi
    if [[ "$OUTPUT_FORMAT" != "json" ]]; then
      printf '=== ADVERSARIAL CHUNK %d/%d ===\n' "$_ck_i" "$_ck_n"
      cat "$_ck_dir/out-${_ck_i}"
      printf '\n'
    fi
  done

  if [[ "$OUTPUT_FORMAT" == "json" ]]; then
    # One wrapper object; callers detect .chunked to iterate .results[].
    if command -v jq >/dev/null 2>&1; then
      # A no-material chunk writes no out-file, so `results` would silently be SHORTER than
      # `chunks` and a machine consumer comparing lengths could only infer that something was
      # missing — never which part. Emit an explicit placeholder for those indices instead.
      for _ck_j in $(seq 1 "$_ck_n"); do
        [[ -s "$_ck_dir/out-${_ck_j}" ]] || printf '{"chunk": %d, "status": "no_material", "reviewed": false}\n' "$_ck_j" > "$_ck_dir/out-${_ck_j}"
      done
      jq -s --argjson n "$_ck_n" '{chunked: true, chunks: $n, results: .}' \
        "$_ck_dir"/out-* 2>/dev/null || cat "$_ck_dir"/out-*
    else
      cat "$_ck_dir"/out-*
    fi
  fi
  # All parts empty => the whole run judged nothing, so the run itself is exit 5.
  if [[ "$_ck_nomat" -gt 0 && "$_ck_ok" -eq 0 && "$_ck_fail" -eq 0 ]]; then
    echo "CHUNKED: ${_ck_n} chunks — NONE carried reviewable material. Nothing was reviewed." >&2
    exit 5
  fi
  # MIXED: some parts reviewed, at least one never judged. The first cut exited 0 here so that one
  # empty tail could not mask the verdict of the parts that WERE reviewed — but a caller reads 0 as
  # "the whole range was reviewed", which is the same false coverage this commit exists to remove,
  # just at the aggregate level. Exit 4 already means exactly this ("review completed, part of the
  # input reached no provider") and every caller's table tells it not to report the review complete.
  if [[ "$_ck_nomat" -gt 0 && "$_ck_rc" -eq 0 ]]; then
    echo "CHUNKED: ${_ck_n} chunks — ${_ck_ok} reviewed, ${_ck_nomat} carried NO material (never judged). Partial coverage: exit 4." >&2
    exit 4
  fi
  echo "CHUNKED: ${_ck_n} chunks — ${_ck_ok} ok, ${_ck_fail} failed${_ck_nomat:+, ${_ck_nomat} with no material (NOT reviewed)}. Aggregate exit: ${_ck_rc}." >&2
  exit "$_ck_rc"
fi
return 0
}

# ar_truncate_input — input still over the cap: cut it back to a whole-file boundary and name what was left out.
ar_truncate_input() {
ORIG_CHARS=${#INPUT}
INPUT_TRUNCATED=false
if [[ ${#INPUT} -gt $MAX_CHARS ]]; then
  INPUT_TRUNCATED=true
  FULL_INPUT="$INPUT"
  # Pure-bash substring: CHARACTER-indexed, consistent with the ${#INPUT}/${FULL_INPUT:offset}
  # arithmetic below (head -c cuts BYTES — a multibyte char at the boundary skewed the omitted-
  # content offset and could split a UTF-8 sequence).
  INPUT="${INPUT:0:$MAX_CHARS}"
  # Trim to last complete line
  INPUT="${INPUT%$'\n'*}"
  # …then back to the last complete FILE boundary. A cut mid-file hands the reviewer a partial
  # implementation that reads as broken code — it reports the missing half as the defect, and the
  # real findings never get budget. Only applied when at least one whole file survives the trim:
  # for a single file larger than the cap there is no boundary to fall back to, and half of one
  # file still beats none. `|| true` for the same pipefail reason as the manifest below.
  _last_hdr=$(printf '%s\n' "$INPUT" | grep -n -E '^(diff --git |=== FILE: )' | tail -1 | cut -d: -f1) || _last_hdr=""
  _hdr_count=$(printf '%s\n' "$INPUT" | { grep -c -E '^(diff --git |=== FILE: )' || true; })
  if [[ -n "$_last_hdr" && "${_hdr_count:-0}" -gt 1 ]]; then
    INPUT=$(printf '%s\n' "$INPUT" | sed -n "1,$((_last_hdr - 1))p")
    echo "  Input trimmed back to a whole-file boundary (dropped the partial trailing file)." >&2
  fi
  # Manifest of files whose content fell past the cutoff, so the reviewer never reports
  # omitted sections as "missing" and the caller can re-run --files on just the omitted set.
  # `|| true` is LOAD-BEARING: with `set -euo pipefail` (the driver's first line of code) a grep that matches nothing
  # exits 1, pipefail propagates it, and the command substitution kills the script HERE —
  # before a single provider is dispatched, with no output. That is the exact shape of a
  # remainder with no file header: one file's diff cut mid-content, i.e. every single-file /
  # single-test input just over MAX_CHARS silently produced NO review at all. The manifest is
  # a diagnostic; failing to build it must never abort the review.
  # awk, not `head -20`, for the same reason: head exits after its lines, and once the omitted names
  # outgrow one pipe write (~75 long paths) sed's next write takes SIGPIPE, the pipeline returns 141 and
  # `set -e` ended the run right here. awk reads to the end and prints the first OMITTED_FILES_SHOWN.
  OMITTED_FILES=$(printf '%s' "${FULL_INPUT:${#INPUT}}" | { grep -E '^(diff --git |=== FILE: )' || true; } | sed -E 's#^diff --git a/(.*) b/.*#\1#; s/^=== FILE: (.*) ===$/\1/' | awk -v n="$OMITTED_FILES_SHOWN" 'NR <= n' | tr '\n' ' ')
  unset FULL_INPUT
  INPUT="${INPUT}

... [TRUNCATED — input was ${ORIG_CHARS} chars; only this first portion was sent.${OMITTED_FILES:+ Files NOT included: ${OMITTED_FILES}.} Do NOT report content beyond this point as missing or absent — review only what is present above.]"
  echo "  WARN: input truncated ${ORIG_CHARS} -> ${MAX_CHARS} chars${OMITTED_FILES:+ (omitted: ${OMITTED_FILES})}" >&2
fi
return 0
}

# ─── Tree tamper-check around the providers ───────────────────────────────────
#
# The reviewer lanes run with FULL WRITE ACCESS to the tree being reviewed: the codex lane pins
# `sandbox_mode = "danger-full-access"` + `approval_policy = "never"` (see the isolated CODEX_HOME
# below), and the claude lane passes `--dangerously-skip-permissions`. That is deliberate and
# measured — a sandboxed/prompting lane blocks forever headless and produced "none returned usable
# review output" (field report 2026-07-12) — so the permission is NOT the thing to remove.
#
# KNOWN LIMIT, stated so nobody reads more into it than it delivers: this is a SNAPSHOT
# COMPARISON, so a provider that edits a file and restores it before the run ends leaves no trace.
# Catching that would need filesystem watching for the whole run. The check answers "did the tree
# change under the reviewers", not "did a reviewer ever touch it".
#
# What was missing is the ability to NOTICE. A review is supposed to read code and return text; if
# a provider edits the tree instead, nothing downstream can tell, because the run's only artifacts
# are the findings. The check below is cheap, read-only, and exists so that "the reviewer changed
# my code" is a reported fact rather than a suspicion. It never blocks the review: detection is the
# whole value, and failing a review over a tamper-check bug would be a worse trade.
_TAMPER_BEFORE=""
_TAMPER_HEAD=""
_TAMPER_CAPTURED=0
_tamper_capture() {
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  _TAMPER_CAPTURED=1
  _TAMPER_HEAD=$(git rev-parse --verify -q HEAD 2>/dev/null || true)
  # --porcelain covers staged, unstaged and untracked in one stable, parseable form.
  _TAMPER_BEFORE=$(git status --porcelain 2>/dev/null || true)
}
# Prints nothing when the tree is untouched. Safe to call more than once.
_TAMPER_DONE=0
_tamper_verify() {
  [[ "$_TAMPER_DONE" -eq 1 ]] && return 0
  _TAMPER_DONE=1
  [[ "$_TAMPER_CAPTURED" -eq 1 ]] || return 0      # nothing was captured => nothing to compare
  git rev-parse --git-dir >/dev/null 2>&1 || return 0
  # An UNBORN HEAD (a repo with no commits — build-review-patch supports that case) leaves
  # _TAMPER_HEAD empty. Returning here on that alone disabled the WORKING-TREE comparison too,
  # even though `git status --porcelain` works perfectly without any commits: the half that
  # actually catches a reviewer editing files was switched off by the half that cannot run.
  local now_head now_status
  now_head=$(git rev-parse --verify -q HEAD 2>/dev/null || true)
  now_status=$(git status --porcelain 2>/dev/null || true)
  # Any move counts, including the first commit of an UNBORN branch (empty -> a sha): since HEAD is read
  # with --verify, an unborn HEAD is empty rather than the literal word "HEAD", and requiring a
  # non-empty baseline would have let "edit, then commit" during the review go unseen there.
  if [[ "$now_head" != "$_TAMPER_HEAD" ]]; then
    local _th_from="(unborn)" _th_to="(unborn)"
    [[ -n "$_TAMPER_HEAD" ]] && _th_from="${_TAMPER_HEAD:0:7}"
    [[ -n "$now_head" ]] && _th_to="${now_head:0:7}"
    TAMPER_NOTE="HEAD moved during the review: $_th_from -> $_th_to"
  elif [[ "$now_status" != "$_TAMPER_BEFORE" ]]; then
    local n
    n=$(diff <(printf '%s\n' "$_TAMPER_BEFORE") <(printf '%s\n' "$now_status") 2>/dev/null | grep -c '^[<>]' || true)
    TAMPER_NOTE="working tree changed during the review (${n} path(s) differ from the pre-review snapshot)"
  else
    return 0
  fi
  echo "WARNING: $TAMPER_NOTE" >&2
  echo "  A review must not modify the tree it reviews. The reviewer lanes run with full write" >&2
  echo "  access, so this is possible; inspect \`git status\` before trusting this run's findings." >&2
  return 0
}
