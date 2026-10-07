#!/usr/bin/env bash
# test-test-audit-subprocess-dispatch.sh — the test-audit batch auditor prompt
# lives in one shared include any client can be handed, and SKILL.md points at
# it instead of embedding the ~13.5 KB template inline.
#
# Test level: MEDIUM — the shipped SKILL.md call blocks and scripts/zuvo-home/test-audit-batch run as
# real subprocesses (bash and zsh) in a scratch git repo under a stub HOME; model-run is a stub, except
# one case that runs the real model-run with no client available. No model is ever called.
#
# Part 1 (this file, Task 7 — "move the prompt into a shared include"):
#   - shared/includes/test-audit-batch-prompt.md exists and carries BOTH
#     GENERATED regions (kind=q-prompt, kind=ap-list) verbatim from the move,
#     and each region is checked for actual (non-empty) content, not just its
#     BEGIN/END markers — a truncated move must not pass;
#   - the include's output contract: "the agent returns ONLY the report; the
#     orchestrator saves it" (never "the agent writes the file itself"); a
#     `Verification context: [VERIFICATION CONTEXT]` FIELD the orchestrator
#     fills — the agent never decides for itself whether it has a shell —
#     with the two values the field can carry (`not run (read-only
#     reviewer)`, `N/A (no run artifact)`) present; the `[BATCH FILE LIST]`
#     placeholder; and the removal of the old "Write complete output to"
#     wording and of any `.test-audit-batch` path mention (the include must
#     never tell the agent to write anywhere itself);
#   - skills/test-audit/SKILL.md references the include from its Mandatory
#     File Loading block, and no longer embeds the prompt body (the
#     RED FLAG PRE-SCAN heading, unique to the prompt, must appear ONLY in
#     the include; no `GATES:BEGIN` marker survives in SKILL.md);
#   - SKILL.md's own Phase 1 text agrees with the include's contract: it
#     states the fenced-body-only handoff rule, that the orchestrator
#     substitutes BOTH placeholders (`[BATCH FILE LIST]` and
#     `[VERIFICATION CONTEXT]`), and the CONCRETE save gate taken from the
#     include's own FULL/SHORT output format heading (`### [filename]`, one
#     per file in the batch, path exactly as listed) — tied to "orchestrator
#     saves" and the exact batch path in the SAME paragraph, not merely
#     somewhere in the section;
#   - Phase 2 (unchanged by this task) still reads from the same directory
#     AND the same `batch-*.md` glob pattern Phase 1 writes to — asserted
#     both as a literal string AND by extracting and comparing the directory
#     portion of each path, so the two cannot silently diverge together.
#
# Section-scoped assertions use extract_block()/fenced_body(), which
# distinguish "the end sentinel was found" from "the scan ran off the end of
# the file" via awk's OWN exit code (never in-band sentinel text mixed into
# the block's own content, and never a folded-together `2>/dev/null` — a
# genuine read/awk error is a DIFFERENT failure reason, with its stderr
# quoted in the message). Heading/fence sentinels are matched as LITERAL
# strings (awk index()/exact compare, never `~` against an ERE) so a heading
# containing "." or another regex metacharacter can never be misread as
# "match any character"; trailing whitespace on a heading line is trimmed
# before the compare, so an invisible trailing space cannot break the
# anchor. fenced_body() further requires the closing fence to carry the
# SAME backtick run length as the opener (accepting an info string like
# ```text on the opener), so a nested fence with FEWER backticks inside the
# body can never end the range early.
#
# require_text_in / require_absent_in check the underlying grep exit code,
# not just "did stdout contain the string": grep rc=0 (found), rc=1 (not
# found) and rc>1 (a grep ERROR — unreadable content, not "absence") are
# handled distinctly. rc>1 is always a FAIL, including inside
# require_absent_in, where treating an error as "confirmed absent" would be
# the dangerous direction — a broken check silently passing.
#
# No `set -e` anywhere in this file (only `-u`/`-o pipefail`) — confirmed
# below, and every `rc=$?`-style capture still uses the `rc=0; cmd || rc=$?`
# form regardless, so the pattern stays correct even if a future edit adds
# `-e` (a bare `rc=$?` right after a command that can legitimately return
# nonzero would abort the script under `-e` before the branch that is
# supposed to HANDLE that nonzero code ever runs).
#
# Part 2 (Task 8 — "Phase 1 dispatches through model-run on Claude/Codex
# hosts, with a labelled in-family fallback"), scoped to Phase 1's own
# subsections (1a model-run route, 1b fallback, 1c other hosts):
#   - the shell of 1a lives in scripts/zuvo-home/test-audit-batch (installed as
#     ~/.zuvo/test-audit-batch); 1a keeps the two CALLS and their contract. The
#     script carries the exact per-batch model-run command; its --reject ERE is
#     the PLAN's own text and its --require ERE is the plan's with the tier
#     alternation widened to `([ABCD]|INCOMPLETE)` (not a re-typed copy), and
#     the stub model-run records the arguments it is really handed;
#   - 1a's two shipped bash blocks (the setup call, the group call) and 1d's
#     save call are EXECUTED (the "execution harness") in a scratch git repo,
#     HOME pointing at a stub ~/.zuvo (zuvo-base, the script under test, and a
#     model-run stub driven by per-batch mode files that leaves start/end
#     marker files). one_run() runs setup and every group call as children of
#     ONE parent script, as the harness does, so the run lock's owner (each
#     call's $PPID, passed as --owner) is shared. It proves: ZUVO_BASE
#     validation; the run lock (live owner STOPs,
#     stale owner reclaimed, a group without the lock STOPs); prompts built and
#     validated; at most P jobs per call, overlapping (marker ordering, not
#     clocks), group 2 only after group 1 ended; P decimal/validated/capped;
#     stale files never read as success; the DONE gate (non-empty TAB listing,
#     heading AND verdict per listed path, sections end only at a listed
#     path); quarantine; the K5 status line; rc 2 STOPs; a job alive at BOUND
#     killed with its process group as timeout-orphan. A missing block FAILS
#     by name (D1), and a floor on the number of executed checks is asserted;
#   - the exit-code table, "never re-run", the labelled fallback (1b) and
#     the INCOMPLETE header; no sonnet in any spelling on the main path;
#   - 1c (Cursor, Antigravity, Kimi) keeps the in-harness dispatch (X7), and
#     Phase 1 never says "Claude Code" (the Kimi/Antigravity builds rewrite it);
#   - the `Batch auditor:` line in Phase 1 AND in Phase 2's report template;
#   - the prompt's OUTPUT LINE FORMAT rule, and line-by-line anti-echo;
#   - Phase 3b is byte-identical to the pre-plan commit e6c2bedd (X8).
# The literal matcher and fence-aware extraction carry their own self-checks.
#
# bash 3.2-compatible (macOS default /bin/bash) AND bash 5 (Homebrew):
# verified under both. No mapfile, no associative arrays, no python3
# dependency (same_paragraph() is pure awk, paragraph mode).
set -uo pipefail
case "$-" in *e*) printf 'FAIL: this script must not run under set -e (rc=$? capture pattern assumes it does not)\n'; exit 1 ;; esac

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" && [ -n "$ROOT" ] && [ -d "$ROOT/skills" ] && [ -d "$ROOT/shared/includes" ] \
  || { printf 'FAIL: cannot locate the repository root from %s\n' "$0"; exit 1; }
# TA_SKILL / TA_PROMPT / TA_SCRIPT: point the whole suite at another copy (RED
# runs against an older revision, planted mutants). ALL THREE or none (D8): a
# partial override would test one tree's SKILL.md against another tree's include
# or script. Each must be a readable regular file, and what is under test is
# printed first.
if [ -n "${TA_SKILL:-}" ] || [ -n "${TA_PROMPT:-}" ] || [ -n "${TA_SCRIPT:-}" ]; then
  [ -n "${TA_SKILL:-}" ] && [ -n "${TA_PROMPT:-}" ] && [ -n "${TA_SCRIPT:-}" ] \
    || { printf 'FAIL: TA_SKILL, TA_PROMPT and TA_SCRIPT must be set together (got TA_SKILL=%s TA_PROMPT=%s TA_SCRIPT=%s)\n' "${TA_SKILL:-}" "${TA_PROMPT:-}" "${TA_SCRIPT:-}"; exit 1; }
  for f in "$TA_SKILL" "$TA_PROMPT" "$TA_SCRIPT"; do
    { [ -f "$f" ] && [ -r "$f" ]; } || { printf 'FAIL: override is not a readable regular file: %s\n' "$f"; exit 1; }
  done
fi
SKILL="${TA_SKILL:-$ROOT/skills/test-audit/SKILL.md}"
PROMPT="${TA_PROMPT:-$ROOT/shared/includes/test-audit-batch-prompt.md}"
SCRIPT="${TA_SCRIPT:-$ROOT/scripts/zuvo-home/test-audit-batch}"
printf 'under test: SKILL=%s PROMPT=%s SCRIPT=%s\n' "$SKILL" "$PROMPT" "$SCRIPT"

fail=0
npass=0
pass() { npass=$((npass+1)); printf 'PASS: %s\n' "$1"; }
bad()  { fail=$((fail+1)); printf 'FAIL: %s\n' "$1"; }

# extract_block()/fenced_body() are always invoked as `x=$(extract_block ...)`
# to capture the block on stdout — and a command substitution always forks a
# subshell, so a plain variable assignment made INSIDE the function (e.g.
# EXTRACT_BLOCK_REASON="...") never reaches the caller; it dies with the
# subshell. A file on disk does not have that problem — subshells share the
# filesystem, only shell variables are subshell-local — so the failure
# reason is written to this scratch file instead, and read back with
# eb_reason() after the `if x=$(...); then ... else ...; fi` has already
# resolved which branch to take.
EB_REASON_FILE="$(mktemp 2>/dev/null)" || { printf 'FAIL: could not create scratch reason file\n'; exit 1; }
trap 'rm -f "$EB_REASON_FILE"' EXIT   # re-armed with ta_cleanup chained in, part 2
eb_reason() { cat "$EB_REASON_FILE" 2>/dev/null; }

# require_text_in / require_absent_in — grep exit codes: 0=found, 1=not
# found, >1=error (unreadable/binary/etc.). An error is ALWAYS a FAIL; it
# must never be read as "confirmed absent" (F21/E).
require_text_in() {
  file="$1"; needle="$2"; label="$3"
  if [ ! -r "$file" ]; then
    bad "$label (file unreadable: $file)"
    return
  fi
  rc=0
  grep -qF -- "$needle" "$file" || rc=$?
  if [ "$rc" -eq 0 ]; then
    pass "$label"
  elif [ "$rc" -eq 1 ]; then
    bad "$label"
  else
    bad "$label (grep error, rc=$rc)"
  fi
}

require_absent_in() {
  file="$1"; needle="$2"; label="$3"
  if [ ! -r "$file" ]; then
    bad "$label (file unreadable: $file)"
    return
  fi
  rc=0
  grep -qF -- "$needle" "$file" || rc=$?
  if [ "$rc" -eq 0 ]; then
    bad "$label"
  elif [ "$rc" -eq 1 ]; then
    pass "$label"
  else
    bad "$label (grep error, rc=$rc — cannot confirm absence)"
  fi
}

# extract_block <file> <start_mode> <start_lit> <end_mode> <end_lit>
# mode is "exact" (the line, with trailing whitespace trimmed, equals
# <lit> exactly — F29) or "prefix" (the line starts with the LITERAL
# string <lit>, via awk's index(), e.g. index($0,"## Phase 2:")==1 — F5:
# never an ERE, so "." in a heading can never mean "any character").
# Prints [start,end) on stdout — the start line THROUGH the line before the
# end line, EXCLUDING the end line itself (T1: verified the prior version
# included it, which meant e.g. Phase 1 extraction with end='## Phase 2:'
# also carried the Phase 2 HEADING line itself into "phase1_block" content;
# harmless today only because nothing that heading line says happens to
# satisfy a Phase-1-scoped check, which is exactly the kind of boundary
# leakage a future edit could silently exploit). Returns 0 on success. On
# failure, prints nothing, writes the reason to $EB_REASON_FILE (read it
# back with eb_reason()), and returns 1 — the reason distinguishes "end
# pattern never matched, ran off EOF" (awk's own
# exit 3) from any OTHER read/awk error (awk's own nonzero exit, with its
# captured stderr quoted verbatim — never folded away via 2>/dev/null)
# (F14/F25/F38, E).
# FENCE_AWK — the ONE fence grammar every extractor in this file uses (T1):
# extract_block, fenced_body and bash_block/bash_block_count all embed it.
# CommonMark: an opener is 0-3 spaces (matched as " ? ? ?" — no {m,n}
# interval, which old BWK awks lack) then a run of 3+ backticks or 3+ tildes;
# a backtick opener may not carry a backtick in its info string; it closes
# only on the SAME character, a run at least as long, then only whitespace. A
# trailing CR is ignored everywhere. trimmed() strips both sides and the CR.
FENCE_AWK='
function trimmed(s) { sub(/\r$/, "", s); sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
function fence_step(line,    l, s) {
  l = line; sub(/\r$/, "", l)
  if (!infc) {
    if (match(l, /^ ? ? ?(````*|~~~~*)/)) {
      s = substr(l, RSTART, RLENGTH); sub(/^ +/, "", s)
      if (substr(s, 1, 1) == "`" && index(substr(l, RSTART + RLENGTH), "`")) return 0
      fch = substr(s, 1, 1); flen = length(s); finfo = trimmed(substr(l, RSTART + RLENGTH)); infc = 1; return 1
    }
    return 0
  }
  if (match(l, /^ ? ? ?(````*|~~~~*)[ \t]*$/)) {
    s = substr(l, RSTART, RLENGTH); sub(/^ +/, "", s); sub(/[ \t]+$/, "", s)
    if (substr(s, 1, 1) == fch && length(s) >= flen) { infc = 0; return 2 }
  }
  return 0
}
'

# Optional 6th arg "anywhere": sentinels may match inside fenced code (only
# the CORE FILES LOADED block, which IS a fence, needs it). Default: every
# sentinel — start and end, any kind — is suppressed inside a fence and on a
# fence line itself (D9), and a fence still open at EOF is a failure (exit 4).
# The fence tracker is CommonMark's: an opener is 0-3 spaces then a run of 3+
# backticks or 3+ tildes (a backtick opener may not carry a backtick in its
# info string); it closes only on the SAME character, a run at least as long,
# and nothing but whitespace after it. The leading spaces are matched as
# " ? ? ?" — no {m,n} interval, which old BWK awks lack.
extract_block() {
  eb_file="$1"; eb_smode="$2"; eb_slit="$3"; eb_emode="$4"; eb_elit="$5"; eb_where="${6:-outside}"
  if [ ! -r "$eb_file" ]; then
    printf '%s' "file unreadable: $eb_file" > "$EB_REASON_FILE"
    return 1
  fi
  eb_err="$(mktemp 2>/dev/null)" || { printf '%s' "mktemp failed" > "$EB_REASON_FILE"; return 1; }
  eb_rc=0
  eb_out="$(awk -v smode="$eb_smode" -v slit="$eb_slit" -v emode="$eb_emode" -v elit="$eb_elit" -v where="$eb_where" "$FENCE_AWK"'
    # matches(): outside mode, no sentinel ever matches inside a fence or on a
    # fence line. "anywhere" mode (the CORE block and the GATES regions, which
    # live INSIDE fences) matches inside fences too, but a fence-shaped
    # sentinel ("```"/"~~~") there matches only a CLOSING fence line.
    function matches(mode, lit, line, st) {
      if (where == "anywhere") {
        if (substr(lit, 1, 3) == "```" || substr(lit, 1, 3) == "~~~") return (st == 2 && trimmed(line) == lit)
      } else if (was || st != 0) return 0
      if (mode == "exact")  { return (trimmed(line) == lit) }
      if (mode == "prefix") { return (index(line, lit) == 1) }
      return 0
    }
    { was = infc; st = fence_step($0) }
    !inside {
      if (matches(smode, slit, $0, st)) { inside = 1; buf[++n] = $0 }
      next
    }
    inside && !found {
      if (matches(emode, elit, $0, st)) { found = 1; next }
      buf[++n] = $0
      next
    }
    END {
      if (!found && infc) { exit 4 }   # the search ran into a fence that never closes
      if (!found) { exit 3 }
      for (i = 1; i <= n; i++) print buf[i]
      exit 0
    }
  ' "$eb_file" 2>"$eb_err")" || eb_rc=$?
  eb_stderr="$(cat "$eb_err" 2>/dev/null)"
  rm -f "$eb_err"
  if [ "$eb_rc" -eq 0 ]; then
    printf '%s\n' "$eb_out"
    return 0
  fi
  if [ "$eb_rc" -eq 3 ]; then
    printf '%s' "end pattern ($eb_emode: $eb_elit) never matched in $eb_file — ran to EOF" > "$EB_REASON_FILE"
  elif [ "$eb_rc" -eq 4 ]; then
    printf '%s' "the end sentinel was not found before a fenced code block that never closes in $eb_file" > "$EB_REASON_FILE"
  else
    printf '%s' "awk failed (rc=$eb_rc) reading $eb_file${eb_stderr:+ -- $eb_stderr}" > "$EB_REASON_FILE"
  fi
  return 1
}

# fenced_body <file> — prints the content of the FIRST fenced code block
# that opens on the first non-blank line after a line starting with the
# literal "### Agent Prompt" (D). CommonMark fence rules (T2):
#   - the opening (and closing) fence may carry up to 3 leading spaces;
#   - an info string on the opening fence line (e.g. ```text) is accepted
#     and ignored;
#   - the CLOSING fence is a line of ONLY backticks (after trimming a
#     trailing CR and trailing whitespace) whose COUNT IS >= the opener's
#     count — not exact equality, so e.g. a 3-backtick opener closed by a
#     4-backtick line is valid CommonMark and must be recognized, while a
#     nested fence using FEWER backticks than the opener can never end the
#     range early. Distinct failure reasons (heading missing / next line
#     not a fence-opener / closing fence never found) via awk's own exit
#     code, same convention as extract_block. The closing fence line itself
#     is excluded from the printed body (same T1 fix as extract_block).
fenced_body() {
  fb_file="$1"
  if [ ! -r "$fb_file" ]; then
    printf '%s' "file unreadable: $fb_file" > "$EB_REASON_FILE"
    return 1
  fi
  fb_err="$(mktemp 2>/dev/null)" || { printf '%s' "mktemp failed" > "$EB_REASON_FILE"; return 1; }
  fb_rc=0
  fb_out="$(awk "$FENCE_AWK"'
    { was = infc; st = fence_step($0) }
    !heading {
      if (!was && st == 0 && index($0, "### Agent Prompt") == 1) { heading = 1 }
      next
    }
    heading && !open {
      if (st == 1) { open = 1; next }
      if (trimmed($0) == "") { next }
      no_open = 1
      exit 22
    }
    open && !closed {
      if (st == 2) { closed = 1; next }
      buf[++n] = $0
      next
    }
    END {
      if (!heading) { exit 21 }
      if (no_open)  { exit 22 }
      if (!open)    { exit 22 }
      if (!closed)  { exit 23 }
      for (i = 1; i <= n; i++) print buf[i]
      exit 0
    }
  ' "$fb_file" 2>"$fb_err")" || fb_rc=$?
  fb_stderr="$(cat "$fb_err" 2>/dev/null)"
  rm -f "$fb_err"
  if [ "$fb_rc" -eq 0 ]; then
    printf '%s\n' "$fb_out"
    return 0
  fi
  case "$fb_rc" in
    21) fb_reason="'### Agent Prompt' heading not found in $fb_file" ;;
    22) fb_reason="heading found, but the next non-blank line is not a fence opener in $fb_file" ;;
    23) fb_reason="opening fence found, but no closing fence (same character, run at least as long) before EOF in $fb_file" ;;
    *)  fb_reason="awk failed (rc=$fb_rc) reading $fb_file${fb_stderr:+ -- $fb_stderr}" ;;
  esac
  printf '%s' "$fb_reason" > "$EB_REASON_FILE"
  return 1
}

# same_paragraph <text> <needle_a> <needle_b> — prints YES/NO on success and
# returns 0. A line's trailing CR is stripped FIRST (T3: a CRLF-sourced
# blank line that is only "\r" must still normalize to truly empty, or it
# would wrongly fail to separate paragraphs); a line holding only
# spaces/tabs is then normalized to a truly empty line, because awk's own
# paragraph mode (RS="") treats ONLY a truly empty line as a separator, not
# a whitespace-only one (G). Pure awk — no python3. On any failure in the
# two-stage pipeline (pipefail is set globally), returns 1 with the reason
# in $EB_REASON_FILE — the caller must NOT read empty/partial output as
# "NO" (a quiet false negative), which is exactly what happened before this
# fix: the caller ignored the pipeline's own exit status entirely (T3).
same_paragraph() {
  sp_text="$1"; sp_a="$2"; sp_b="$3"
  sp_err="$(mktemp 2>/dev/null)" || { printf '%s' "mktemp failed" > "$EB_REASON_FILE"; return 1; }
  sp_rc=0
  sp_out="$(printf '%s\n' "$sp_text" \
    | awk '{ sub(/\r$/, ""); if ($0 ~ /^[ \t]*$/) print ""; else print }' \
    | awk -v RS='' -v a="$sp_a" -v b="$sp_b" '
        index($0, a) > 0 && index($0, b) > 0 { found = 1 }
        END { print (found ? "YES" : "NO") }
      ' 2>"$sp_err")" || sp_rc=$?
  sp_stderr="$(cat "$sp_err" 2>/dev/null)"
  rm -f "$sp_err"
  if [ "$sp_rc" -ne 0 ]; then
    printf '%s' "same_paragraph pipeline failed (rc=$sp_rc)${sp_stderr:+ -- $sp_stderr}" > "$EB_REASON_FILE"
    return 1
  fi
  printf '%s\n' "$sp_out"
  return 0
}

echo "== test-audit-batch-prompt.md exists and carries both GENERATED regions with real content =="

if [ -f "$PROMPT" ]; then
  pass "shared/includes/test-audit-batch-prompt.md exists"
else
  bad "shared/includes/test-audit-batch-prompt.md exists"
fi

require_text_in "$PROMPT" '<!-- GATES:BEGIN kind=q-prompt -->' \
  "include carries the q-prompt GENERATED region (begin marker)"
require_text_in "$PROMPT" '<!-- GATES:END kind=q-prompt -->' \
  "include carries the q-prompt GENERATED region (end marker)"
require_text_in "$PROMPT" '<!-- GATES:BEGIN kind=ap-list -->' \
  "include carries the ap-list GENERATED region (begin marker)"
require_text_in "$PROMPT" '<!-- GATES:END kind=ap-list -->' \
  "include carries the ap-list GENERATED region (end marker)"

# Markers alone pass on a truncated move (empty region body). Check the
# region actually contains its first and last known ids — a real move, not
# an empty shell (F17/F26/F35).
if qregion=$(extract_block "$PROMPT" exact '<!-- GATES:BEGIN kind=q-prompt -->' exact '<!-- GATES:END kind=q-prompt -->' anywhere); then
  case "$qregion" in
    *"Q1:"*"Q25:"*)
      pass "q-prompt region is non-empty: carries both Q1: and Q25:" ;;
    *)
      bad "q-prompt region is non-empty: carries both Q1: and Q25:" ;;
  esac
else
  bad "q-prompt region is non-empty: carries both Q1: and Q25: ($(eb_reason))"
fi

if apregion=$(extract_block "$PROMPT" exact '<!-- GATES:BEGIN kind=ap-list -->' exact '<!-- GATES:END kind=ap-list -->' anywhere); then
  case "$apregion" in
    *"AP1:"*"AP32:"*)
      pass "ap-list region is non-empty: carries both AP1: and AP32:" ;;
    *)
      bad "ap-list region is non-empty: carries both AP1: and AP32:" ;;
  esac
else
  bad "ap-list region is non-empty: carries both AP1: and AP32: ($(eb_reason))"
fi

echo "== include's output contract: return ONLY the report, an orchestrator-filled verification field, never write a file =="

require_text_in "$PROMPT" 'Return ONLY the report as your final message' \
  "include says the agent returns ONLY the report as its final message"
require_text_in "$PROMPT" '[BATCH FILE LIST]' \
  "include carries the [BATCH FILE LIST] placeholder"
require_absent_in "$PROMPT" 'Write complete output to' \
  "include no longer tells the agent to write complete output to a file"
require_absent_in "$PROMPT" '.test-audit-batch' \
  "include never mentions the .test-audit-batch path (the agent must not write there either)"

# The Verification-context FIELD (and both values it can carry) must sit
# INSIDE the fenced agent prompt, not merely anywhere in the include file
# (F19), and must be a field the ORCHESTRATOR fills, not the agent's own
# self-diagnosis (B) — so the include must carry the literal placeholder
# token, not a sentence telling the agent to decide for itself. The
# producer contract (return-only, the file-list placeholder, and the P4
# per-file save-gate heading rule) is asserted here too, scoped to the
# fenced body specifically, not merely "somewhere in the file" (T4) — and
# the P1 default-to-read-only fallback rule is asserted the same way (T6).
if fenced=$(fenced_body "$PROMPT"); then
  case "$fenced" in
    *"Verification context: [VERIFICATION CONTEXT]"*)
      pass "include carries the orchestrator-filled [VERIFICATION CONTEXT] field, inside the fenced agent prompt" ;;
    *)
      bad "include carries the orchestrator-filled [VERIFICATION CONTEXT] field, inside the fenced agent prompt" ;;
  esac
  case "$fenced" in
    *"not run (read-only reviewer)"*)
      pass "include carries the 'not run (read-only reviewer)' value, inside the fenced agent prompt" ;;
    *)
      bad "include carries the 'not run (read-only reviewer)' value, inside the fenced agent prompt" ;;
  esac
  case "$fenced" in
    *"N/A (no run artifact)"*)
      pass "include carries the 'N/A (no run artifact)' value, inside the fenced agent prompt" ;;
    *)
      bad "include carries the 'N/A (no run artifact)' value, inside the fenced agent prompt" ;;
  esac
  # T6: any value other than exactly "shell available" — including an
  # empty or unsubstituted placeholder — must default to the read-only
  # branch (P1). Pinned via the literal "EXACTLY" + "ANY OTHER value" +
  # "unsubstituted" wording, not merely "the two branches exist somewhere".
  case "$fenced" in
    *"EXACTLY \"shell available\""*"ANY OTHER value"*"unsubstituted"*)
      pass "include's fenced body states the read-only-by-default fallback rule (any non-'shell available' value, including empty/unsubstituted)" ;;
    *)
      bad "include's fenced body states the read-only-by-default fallback rule (any non-'shell available' value, including empty/unsubstituted)" ;;
  esac
  # T4: the producer contract (return-only, file-list placeholder) proven
  # to live INSIDE the fence, not merely somewhere in the include file —
  # the earlier whole-file require_text_in checks above prove existence;
  # these prove placement.
  case "$fenced" in
    *"Return ONLY the report as your final message"*)
      pass "include's fenced body carries 'Return ONLY the report as your final message'" ;;
    *)
      bad "include's fenced body carries 'Return ONLY the report as your final message'" ;;
  esac
  case "$fenced" in
    *"[BATCH FILE LIST]"*)
      pass "include's fenced body carries the [BATCH FILE LIST] placeholder" ;;
    *)
      bad "include's fenced body carries the [BATCH FILE LIST] placeholder" ;;
  esac
  # P4: every listed file gets its own "### " + path-as-listed section, or
  # the whole batch counts as not returned.
  case "$fenced" in
    *"MUST get its own section"*"### "*"not returned"*)
      pass "include's fenced body states the P4 per-file save-gate heading rule (### + path as listed; missing = whole batch not returned)" ;;
    *)
      bad "include's fenced body states the P4 per-file save-gate heading rule (### + path as listed; missing = whole batch not returned)" ;;
  esac
else
  bad "include carries the orchestrator-filled [VERIFICATION CONTEXT] field, inside the fenced agent prompt ($(eb_reason))"
  bad "include carries the 'not run (read-only reviewer)' value, inside the fenced agent prompt (fenced body not found)"
  bad "include carries the 'N/A (no run artifact)' value, inside the fenced agent prompt (fenced body not found)"
  bad "include's fenced body states the read-only-by-default fallback rule (any non-'shell available' value, including empty/unsubstituted) (fenced body not found)"
  bad "include's fenced body carries 'Return ONLY the report as your final message' (fenced body not found)"
  bad "include's fenced body carries the [BATCH FILE LIST] placeholder (fenced body not found)"
  bad "include's fenced body states the P4 per-file save-gate heading rule (### + path as listed; missing = whole batch not returned) (fenced body not found)"
fi

echo "== SKILL.md references the include and no longer embeds the prompt body =="

require_text_in "$SKILL" '../../shared/includes/test-audit-batch-prompt.md' \
  "SKILL.md references ../../shared/includes/test-audit-batch-prompt.md"

# The reference must sit inside the Mandatory File Loading block's numbered
# "CORE FILES LOADED:" list, not merely appear somewhere in the file — a bare
# mention elsewhere would not guarantee the file is actually loaded before
# use. Literal-anchored heading sentinels (not a bare substring match, not
# an ERE) so an unrelated later mention of the same phrase cannot satisfy
# this; the closing fence is required to actually be found, not assumed at
# EOF (F14/F25).
if loading_block=$(extract_block "$SKILL" exact 'CORE FILES LOADED:' exact '```' anywhere); then
  case "$loading_block" in
    *"test-audit-batch-prompt.md"*)
      pass "test-audit-batch-prompt.md is listed under Mandatory File Loading (CORE FILES LOADED block)" ;;
    *)
      bad "test-audit-batch-prompt.md is listed under Mandatory File Loading (CORE FILES LOADED block)" ;;
  esac
else
  bad "test-audit-batch-prompt.md is listed under Mandatory File Loading ($(eb_reason))"
fi

require_absent_in "$SKILL" 'RED FLAG PRE-SCAN' \
  "SKILL.md no longer embeds the prompt body (RED FLAG PRE-SCAN appears only in the include)"
require_absent_in "$SKILL" 'Write complete output to' \
  "SKILL.md no longer embeds the prompt's old output-writing instruction"
require_absent_in "$SKILL" 'GATES:BEGIN' \
  "SKILL.md carries no GATES:BEGIN marker any more (the regions moved with the prompt)"

# The heading is unique to the prompt template; confirm it survived the move
# and lives in exactly the include, not nowhere and not in both places.
require_text_in "$PROMPT" 'RED FLAG PRE-SCAN' \
  "the include itself still carries RED FLAG PRE-SCAN (the move did not drop it)"

echo "== SKILL.md Phase 1 agrees with the include's contract =="

# Scoped to Phase 1 so a mention elsewhere (e.g. Phase 2's aggregation step)
# cannot satisfy this. Literal-anchored start sentinel, trailing whitespace
# trimmed (F29); prefix-anchored end sentinel, literal not ERE (F5); the
# block extraction is a hard FAIL if the Phase 2 heading is never found,
# never a silent run to EOF (F14/F38).
if phase1_block=$(extract_block "$SKILL" exact '## Phase 1: Batch Evaluation' prefix '## Phase 2:'); then
  pass "SKILL.md Phase 1 section located (end sentinel '## Phase 2:' found)"

  case "$phase1_block" in
    *"FENCED BODY ONLY"*)
      pass "SKILL.md Phase 1 states the fenced-body-only handoff rule" ;;
    *)
      bad "SKILL.md Phase 1 states the fenced-body-only handoff rule" ;;
  esac

  case "$phase1_block" in
    *"[BATCH FILE LIST]"*)
      pass "SKILL.md Phase 1 carries the [BATCH FILE LIST] placeholder" ;;
    *)
      bad "SKILL.md Phase 1 carries the [BATCH FILE LIST] placeholder" ;;
  esac

  case "$phase1_block" in
    *"[VERIFICATION CONTEXT]"*)
      pass "SKILL.md Phase 1 carries the [VERIFICATION CONTEXT] placeholder" ;;
    *)
      bad "SKILL.md Phase 1 carries the [VERIFICATION CONTEXT] placeholder" ;;
  esac

  case "$phase1_block" in
    *"orchestrator substitutes BOTH placeholders"*)
      pass "SKILL.md Phase 1 says the orchestrator substitutes BOTH placeholders" ;;
    *)
      bad "SKILL.md Phase 1 says the orchestrator substitutes BOTH placeholders" ;;
  esac

  case "$phase1_block" in
    *"### [filename]"*)
      pass "SKILL.md Phase 1 states the concrete save gate (### [filename] heading, path as listed, one per file)" ;;
    *)
      bad "SKILL.md Phase 1 states the concrete save gate (### [filename] heading, path as listed, one per file)" ;;
  esac

  # The dispatch block's own comment must not contradict the fact that this
  # path substitutes [VERIFICATION CONTEXT] with `shell available`: the OLD
  # "Read + CodeSift only, no Edit/Write" wording claimed no shell at all,
  # a few lines above a paragraph that says the opposite. Assert the
  # reworded comment (no Edit/Write, but read-only verification commands
  # ARE allowed) and the absence of the old contradictory phrase.
  case "$phase1_block" in
    *"may run read-only verification commands"*)
      pass "SKILL.md Phase 1 dispatch comment allows read-only verification commands (agrees with 'shell available')" ;;
    *)
      bad "SKILL.md Phase 1 dispatch comment allows read-only verification commands (agrees with 'shell available')" ;;
  esac
  case "$phase1_block" in
    *"Read + CodeSift only"*)
      bad "SKILL.md Phase 1 dispatch comment no longer says 'Read + CodeSift only' (contradicted 'shell available')" ;;
    *)
      pass "SKILL.md Phase 1 dispatch comment no longer says 'Read + CodeSift only' (contradicted 'shell available')" ;;
  esac

  # "orchestrator saves" and the exact batch path must be tied to the SAME
  # sentence/paragraph, not merely anywhere in the Phase 1 block — two
  # independent, unrelated mentions would satisfy a whole-block substring
  # check without the skill actually saying where the report is saved
  # (F22/F34). Pure awk, no python3 (G). same_paragraph's own exit status is
  # checked (T3): a pipeline failure is its OWN distinct FAIL, never quietly
  # read as "not in the same paragraph".
  sp_rc2=0
  same_para=$(same_paragraph "$phase1_block" "orchestrator saves" "zuvo/audits/.test-audit-batch/batch-{N}.md") || sp_rc2=$?
  if [ "$sp_rc2" -ne 0 ]; then
    bad "SKILL.md Phase 1: 'orchestrator saves' and the batch path are in the same paragraph (same_paragraph itself failed: $(eb_reason))"
  elif [ "$same_para" = "YES" ]; then
    pass "SKILL.md Phase 1: 'orchestrator saves' and the batch path are in the same paragraph"
  else
    bad "SKILL.md Phase 1: 'orchestrator saves' and the batch path are in the same paragraph"
  fi
  phase1_ok=1
else
  bad "SKILL.md Phase 1 section located (end sentinel '## Phase 2:' found) — $(eb_reason)"
  bad "SKILL.md Phase 1 states the fenced-body-only handoff rule (Phase 1 block not found)"
  bad "SKILL.md Phase 1 carries the [BATCH FILE LIST] placeholder (Phase 1 block not found)"
  bad "SKILL.md Phase 1 carries the [VERIFICATION CONTEXT] placeholder (Phase 1 block not found)"
  bad "SKILL.md Phase 1 says the orchestrator substitutes BOTH placeholders (Phase 1 block not found)"
  bad "SKILL.md Phase 1 states the concrete save gate (### [filename] heading, path as listed, one per file) (Phase 1 block not found)"
  bad "SKILL.md Phase 1 dispatch comment allows read-only verification commands (agrees with 'shell available') (Phase 1 block not found)"
  bad "SKILL.md Phase 1 dispatch comment no longer says 'Read + CodeSift only' (contradicted 'shell available') (Phase 1 block not found)"
  bad "SKILL.md Phase 1: 'orchestrator saves' and the batch path are in the same paragraph (Phase 1 block not found)"
  phase1_ok=0
fi

echo "== Phase 2 reads from the same directory and glob pattern Phase 1 writes to =="

if phase2_block=$(extract_block "$SKILL" exact '## Phase 2: Aggregate Results' prefix '## Phase 3:'); then
  case "$phase2_block" in
    *"zuvo/audits/.test-audit-batch/batch-*.md"*)
      pass "SKILL.md Phase 2 reads zuvo/audits/.test-audit-batch/batch-*.md (directory AND glob pattern, not only the prefix)" ;;
    *)
      bad "SKILL.md Phase 2 reads zuvo/audits/.test-audit-batch/batch-*.md (directory AND glob pattern, not only the prefix)" ;;
  esac
  phase2_ok=1
else
  bad "SKILL.md Phase 2 reads zuvo/audits/.test-audit-batch/batch-*.md ($(eb_reason))"
  phase2_ok=0
fi

echo "== Phase 1's save directory equals Phase 2's read glob directory =="

# T5: extract the directory portion of each path (the part before
# "batch-") and compare them directly, rather than relying on each being
# independently pinned to the same hardcoded literal — a design that could
# not tell "both changed to the same new directory" (still consistent)
# apart from "one changed, one did not" (a real drift) without this
# comparison.
extract_batch_dir() {
  printf '%s' "$1" | awk '
    match($0, /[A-Za-z0-9_.\/-]*\/batch-/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/batch-$/, "", s)
      print s
      exit
    }
  '
}
if [ "${phase1_ok:-0}" -eq 1 ] && [ "${phase2_ok:-0}" -eq 1 ]; then
  p1dir=$(extract_batch_dir "$phase1_block")
  p2dir=$(extract_batch_dir "$phase2_block")
  if [ -n "$p1dir" ] && [ -n "$p2dir" ] && [ "$p1dir" = "$p2dir" ]; then
    pass "Phase 1's save directory ($p1dir) equals Phase 2's read glob directory"
  else
    bad "Phase 1's save directory ('${p1dir:-empty}') equals Phase 2's read glob directory ('${p2dir:-empty}')"
  fi
else
  bad "Phase 1's save directory equals Phase 2's read glob directory (Phase 1 and/or Phase 2 block not found, cannot compare)"
fi

# ════════════════════════════════════════════════════════════════════════════
# Part 2 (Task 8): Phase 1 dispatches through model-run on Claude/Codex hosts
# ════════════════════════════════════════════════════════════════════════════

# lit_in <haystack> <needle> — LITERAL containment over the WHOLE text (D2):
# both strings reach awk through ENVIRON (no heredoc, no -v escape processing,
# no trailing-newline artefact), and index() is taken on the full haystack, so
# a needle spanning lines matches and `[ABCD]`, `*`, `?`, `|`, `\` are just
# characters.
lit_in() {
  HAY="$1" NEEDLE="$2" awk 'BEGIN { exit !(index(ENVIRON["HAY"], ENVIRON["NEEDLE"]) > 0) }'
}
block_has()   { if lit_in "$1" "$2"; then pass "$3"; else bad "$3"; fi; }
block_lacks() { if lit_in "$1" "$2"; then bad "$3"; else pass "$3"; fi; }
must() {  # must <label> <cmd...> — PASS when the command succeeds
  lbl="$1"; shift
  if "$@"; then pass "$lbl"; else bad "$lbl"; fi
}
mustnot() {
  lbl="$1"; shift
  if "$@"; then bad "$lbl"; else pass "$lbl"; fi
}

echo "== part 2: the literal matcher is literal (T1/D2 self-checks) =="
mustnot "lit_in: '[ABCD]' does not match a text lacking that literal" lit_in 'Tier: A (x)' 'Tier: [ABCD]'
mustnot "lit_in: 'a*b' does not match 'axxb'" lit_in 'axxb' 'a*b'
must    "lit_in: the exact regex text is found" lit_in "x '^Tier: [ABCD]( |\$)' y" "'^Tier: [ABCD]( |\$)'"
must    "lit_in: a literal \$HOME in the haystack stays literal" lit_in 'run $HOME/.zuvo/x' '$HOME/.zuvo'
must    "lit_in: a haystack line reading EOF does not end the haystack" lit_in "$(printf 'a\nEOF\nlast-line')" 'last-line'
must    "lit_in: a needle spanning two lines matches" lit_in "$(printf 'one\ntwo\nthree')" "$(printf 'one\ntwo')"
mustnot "lit_in: no trailing-newline artefact (a needle ending in a newline the haystack lacks)" lit_in 'abc' "$(printf 'abc\n_')"
must    "lit_in: backslashes are literal" lit_in 'a \[x\] b' '\[x\]'

echo "== part 2: fence-aware section extraction (T6/D9 self-checks) =="
FX="$(mktemp 2>/dev/null)" || { bad "mktemp for the fence fixtures"; FX=""; }
fx_case() {  # fx_case <label> <expect: ok:<needle-present>:<needle-absent> | fail> <lines...>
  lbl="$1"; want="$2"; shift 2
  printf '%s\n' "$@" > "$FX"
  if out=$(extract_block "$FX" prefix '### 1a.' prefix '### 1b.'); then
    case "$want" in
      fail) bad "$lbl (extracted, expected a failure)" ;;
      ok:*) w1="${want#ok:}"; yes="${w1%%:*}"; no="${w1#*:}"
            if lit_in "$out" "$yes" && ! lit_in "$out" "$no"; then pass "$lbl"; else bad "$lbl (got: $out)"; fi ;;
    esac
  else
    case "$want" in fail) pass "$lbl ($(eb_reason))" ;; *) bad "$lbl ($(eb_reason))" ;; esac
  fi
}
if [ -n "$FX" ]; then
  fx_case "a heading inside a backtick fence does not end the section" ok:after-fence:in-1b \
    '### 1a. X' '```bash' '### 1b. inside' '```' 'after-fence' '### 1b. real' 'in-1b'
  fx_case "a heading inside a tilde fence does not end the section" ok:after-fence:in-1b \
    '### 1a. X' '~~~' '### 1b. inside' '~~~' 'after-fence' '### 1b. real' 'in-1b'
  fx_case "a tilde line does not close a backtick fence" ok:still-in:in-1b \
    '### 1a. X' '```' '~~~' '### 1b. inside' 'still-in' '```' '### 1b. real' 'in-1b'
  fx_case "a shorter run does not close a longer fence; a longer run does" ok:still-in:in-1b \
    '### 1a. X' '````' '```' '### 1b. inside' 'still-in' '`````' '### 1b. real' 'in-1b'
  fx_case "four spaces of indent is not a fence (the heading after it ends the section)" ok:four:in-1b \
    '### 1a. X' '    ```' 'four' '### 1b. real' 'in-1b'
  fx_case "a start sentinel inside a fence is ignored" ok:real-1a:fake \
    '```' '### 1a. fake' '```' '### 1a. X' 'real-1a' '### 1b. real'
  fx_case "an unclosed fence BEFORE the end sentinel fails the extraction" fail \
    '### 1a. X' 'body' '```' '### 1b. inside' 'never closed'
  fx_case "an unclosed fence AFTER the block does not fail it" ok:body:never \
    '### 1a. X' 'body' '### 1b. real' '```' 'never closed'
  fx_case "a CRLF-terminated fence line is still a fence" ok:after-fence:in-1b \
    '### 1a. X' "$(printf '```\r')" '### 1b. inside' "$(printf '```\r')" 'after-fence' '### 1b. real' 'in-1b'
  printf '%s\n' 'CORE FILES LOADED:' '```' 'inside' '```' 'after' > "$FX"
  if out=$(extract_block "$FX" exact 'CORE FILES LOADED:' exact '```' anywhere) && lit_in "$out" inside; then
    pass "anywhere mode: a fence sentinel ends the block only at a CLOSING fence, never at an opener (f3-48)"
  else
    bad "anywhere mode: a fence sentinel ends the block only at a CLOSING fence, never at an opener (f3-48) (got: ${out:-$(eb_reason)})"
  fi
  printf '%s\n' '  ### 1a. X' 'body' '### 1b. y' > "$FX"
  if out=$(extract_block "$FX" exact '### 1a. X' prefix '### 1b.'); then pass "exact sentinels compare trimmed on BOTH sides (T1)"; else bad "exact sentinels compare trimmed on BOTH sides (T1) ($(eb_reason))"; fi
  rm -f "$FX"
fi

# The exact strings the plan pins — read FROM the plan (T5/D6): both EREs from
# the SAME "Anti-echo for test-audit" bullet, which must occur exactly once.
# An ERE is the shell single-quoted word after the flag; the `'\''` idiom (a
# quote inside) is decoded, backslashes are kept as written.
PLAN="$ROOT/docs/specs/2026-09-25-cross-vendor-reviewer-routing-plan.md"
plan_bullet=""
nb=$(awk 'index($0, "**Anti-echo for test-audit:**") { n++ } END { print n + 0 }' "$PLAN" 2>/dev/null)
if [ "${nb:-0}" -eq 1 ]; then
  plan_bullet=$(awk 'index($0, "**Anti-echo for test-audit:**")' "$PLAN")
  pass "the plan's Anti-echo bullet occurs exactly once"
else
  bad "the plan's Anti-echo bullet occurs exactly once (found ${nb:-?} in $PLAN)"
fi
sq_word_after() {  # sq_word_after <text> <flag> — decode `<flag> '<...>'`
  TXT="$1" FLAG="$2" awk 'BEGIN {
    t = ENVIRON["TXT"]; f = ENVIRON["FLAG"] " \047"; i = index(t, f)
    if (!i) exit 1
    s = substr(t, i + length(f)); out = ""
    while (1) {
      j = index(s, "\047"); if (!j) exit 1
      out = out substr(s, 1, j - 1); s = substr(s, j + 1)
      if (substr(s, 1, 3) == "\\\047\047") { out = out "\047"; s = substr(s, 4); continue }
      break
    }
    if (out == "") exit 1
    printf "%s", out
  }'
}
must "sq_word_after decodes a quoted word containing an escaped quote and a backslash" \
  [ "$(sq_word_after "x --require 'a'\\''b\\[c' y" --require)" = "a'b\\[c" ]
req_ere=$(sq_word_after "$plan_bullet" --require) || req_ere=""
rej_ere=$(sq_word_after "$plan_bullet" --reject) || rej_ere=""
if [ -n "$req_ere" ] && [ -n "$rej_ere" ]; then
  pass "the plan's Anti-echo bullet yields both --require and --reject EREs"
else
  bad "the plan's Anti-echo bullet yields both --require and --reject EREs"
  req_ere='<unreadable>'; rej_ere='<unreadable>'
fi
MR_CMD='model-run" --route --mode audit --access read'

# The script's own constants, read by SOURCING it (it defines and runs nothing when sourced) — never
# by parsing its text. One `name=value` line each; TAB_REQUIRE / TAB_REJECT are what model-run is handed.
script_const() {
  "${BASH:-bash}" -c '. "$1" || exit 9; n="$2"; [ -n "${!n+x}" ] || exit 8; printf "%s" "${!n}"' _ "$SCRIPT" "$1" 2>/dev/null
}
S_REQ=$(script_const TAB_REQUIRE) || S_REQ='<unreadable>'
S_REJ=$(script_const TAB_REJECT) || S_REJ='<unreadable>'
S_BOUND=$(script_const TAB_BOUND) || S_BOUND=0
S_GRACE=$(script_const TAB_GRACE) || S_GRACE=0
S_TMO=$(script_const TAB_CLIENT_TIMEOUT) || S_TMO=0
script_text="$(cat "$SCRIPT" 2>/dev/null)"

echo "== part 2: the batch script — model-run's command and the patterns it is handed =="

if [ -f "$SCRIPT" ] && [ -x "$SCRIPT" ]; then pass "scripts/zuvo-home/test-audit-batch exists and is executable"; else bad "scripts/zuvo-home/test-audit-batch exists and is executable ($SCRIPT)"; fi
if [ "$(sed -n 1p "$SCRIPT" 2>/dev/null)" = '#!/usr/bin/env bash' ]; then pass "the script runs under its own bash (shebang), whatever shell calls it"; else bad "the script's first line is '#!/usr/bin/env bash'"; fi
# The plan pins both EREs. --reject is the plan's verbatim. --require is the plan's with the tier
# alternation widened: a file with nothing applicable has no letter and writes `Tier: INCOMPLETE`.
want_req=$(REQ="$req_ere" awk 'BEGIN { s = ENVIRON["REQ"]; i = index(s, "[ABCD]"); if (!i) exit 1
  printf "%s", substr(s, 1, i - 1) "([ABCD]|INCOMPLETE)" substr(s, i + 6) }') || want_req='<plan ERE has no [ABCD]>'
if [ "$S_REQ" = "$want_req" ]; then pass "the script's --require is the plan's ERE with the tier widened to ([ABCD]|INCOMPLETE)"; else bad "the script's --require is the plan's ERE with the tier widened to ([ABCD]|INCOMPLETE) (got: $S_REQ; want: $want_req)"; fi
if [ "$S_REJ" = "$rej_ere" ]; then pass "the script's --reject is the plan's ERE verbatim"; else bad "the script's --reject is the plan's ERE verbatim (got: $S_REJ)"; fi
block_has "$script_text" "$MR_CMD" "the script carries 'model-run --route --mode audit --access read'"
block_has "$script_text" '--require "$TAB_REQUIRE"' "the script hands model-run its --require pattern"
block_has "$script_text" '--reject "$TAB_REJECT"' "the script hands model-run its --reject pattern"
block_has "$script_text" '--out "$b.md"' "the script writes the answer with --out on batch-N.md"
block_has "$script_text" '--append-file "$b.list"' "the script appends the per-batch listing with --append-file"
block_has "$script_text" '--prompt-file "$b.prompt"' "the script hands model-run the per-batch substituted prompt file"
block_has "$script_text" '--read-root "$TAB_ROOT"' "the script passes --read-root as the repository root"
block_has "$script_text" '${ZUVO_TEST_AUDIT_PARALLEL:-2}' "the script expands \${ZUVO_TEST_AUDIT_PARALLEL:-2} (Q11)"
if [ "$S_TMO" = 480 ]; then pass "the script gives each batch the 480 s client budget"; else bad "the script gives each batch the 480 s client budget (TAB_CLIENT_TIMEOUT=$S_TMO)"; fi
n_mr=$(printf '%s\n' "$script_text" | awk 'index($0, "/model-run\" --") { c++ } END { print c + 0 }')
if [ "$n_mr" -eq 1 ]; then pass "the script carries exactly one model-run invocation"; else bad "the script carries exactly one model-run invocation (found $n_mr)"; fi
# The group call's wait and grace: inside the harness's 600 s, and the grace covers what model-run
# itself needs after a TERM (its runner's clamped grace plus its cleanup slack, read from model-run).
mr_const() { awk -v k="$1" '/^readonly / { for (i = 2; i <= NF; i++) if (index($i, k "=") == 1) { print substr($i, length(k) + 2); exit } }' "$ROOT/scripts/zuvo-home/model-run"; }
MR_GRACE_MAX=$(mr_const GRACE_MAX); MR_SLACK=$(mr_const RUNNER_CLEANUP_SLACK)
case "$MR_GRACE_MAX:$MR_SLACK" in
  *[!0-9:]*|:*|*:) bad "model-run's stop() ceiling is readable (GRACE_MAX=$MR_GRACE_MAX RUNNER_CLEANUP_SLACK=$MR_SLACK)"; MR_STOP=9999 ;;
  *) MR_STOP=$((MR_GRACE_MAX + MR_SLACK)); pass "model-run's stop() ceiling is readable: $MR_GRACE_MAX + $MR_SLACK = $MR_STOP s" ;;
esac
if [ "$S_GRACE" -gt "$MR_STOP" ]; then pass "the group call's GRACE ($S_GRACE s) outlasts model-run's own stop() ceiling ($MR_STOP s) (R2-4)"; else bad "the group call's GRACE ($S_GRACE s) outlasts model-run's own stop() ceiling ($MR_STOP s) (R2-4)"; fi
if [ "$S_BOUND" -gt "$S_TMO" ] && [ $((S_BOUND + S_GRACE + 10)) -lt 600 ]; then pass "BOUND ($S_BOUND) + GRACE ($S_GRACE) leaves at least 10 s of the harness's 600 s call ceiling, and BOUND is past the client budget"; else bad "BOUND ($S_BOUND) + GRACE ($S_GRACE) + 10 s margin < 600 s, and BOUND > the $S_TMO s client budget"; fi

echo "== part 2: 1a — Claude and Codex hosts dispatch batches through model-run =="

p1a=""
if p1a=$(extract_block "$SKILL" prefix '### 1a. Claude and Codex hosts' prefix '### 1b.'); then
  pass "Phase 1a section located (heading names Claude and Codex hosts; ends at ### 1b.)"
else
  bad "Phase 1a section located — $(eb_reason)"
  p1a=""
fi
block_has "$p1a" '~/.zuvo/test-audit-batch setup --owner "$PPID" --nbatch "$NBATCH" --token "$RUN_TOKEN"' "1a carries the setup call, the harness pid passed as --owner"
block_has "$p1a" '~/.zuvo/test-audit-batch group --owner "$PPID" --nbatch "$NBATCH" --first "$FIRST" --token "$RUN_TOKEN"' "1a carries the group call, the harness pid passed as --owner"
block_has "$p1a" '~/.zuvo/test-audit-batch release --owner "$PPID" --token' "1a names the release call for a run that STOPs"
block_has "$p1a" 'model-run --route --mode audit --access read' "1a says what each batch is run as"
block_has "$p1a" '--timeout 480' "1a gives each batch the 480 s client budget"
block_has "$p1a" 'batches of 5' "1a uses batches of 5 on this route"
block_has "$p1a" '${ZUVO_TEST_AUDIT_PARALLEL:-2}' "1a names \${ZUVO_TEST_AUDIT_PARALLEL:-2} as the group size (Q11)"
block_has "$p1a" 'batch holding one group of more than 5 files exceeds 5' "1a: a Phase 0.3 group is never split, so a batch may exceed 5 (Q8)"
block_has "$p1a" 'Tier: INCOMPLETE' "1a: the gate and --require take 'Tier: INCOMPLETE' for a file with nothing applicable (R2-2)"
sp3=$(same_paragraph "$p1a" "ONE Bash call" "timeout: 600000") || sp3=ERR
sp3b=$(same_paragraph "$p1a" "per GROUP" "Never put a second group into the same call") || sp3b=ERR
sp3c=$(same_paragraph "$p1a" "per GROUP" "BOUND=$S_BOUND") || sp3c=ERR
sp3d=$(same_paragraph "$p1a" "per GROUP" "GRACE=$S_GRACE") || sp3d=ERR
sp3e=$(same_paragraph "$p1a" "per GROUP" "is $((S_BOUND + S_GRACE)) s, $((600 - S_BOUND - S_GRACE)) s inside the ceiling") || sp3e=ERR
if [ "$sp3" = YES ] && [ "$sp3b" = YES ] && [ "$sp3c" = YES ] && [ "$sp3d" = YES ] && [ "$sp3e" = YES ]; then
  pass "1a: ONE Bash call per GROUP with 'timeout: 600000', never a second group in the same call, the script's own BOUND=$S_BOUND and GRACE=$S_GRACE and their sum (one paragraph)"
else
  bad "1a: ONE Bash call per GROUP / timeout: 600000 / never a second group / BOUND=$S_BOUND / GRACE=$S_GRACE / their sum in one paragraph ($sp3/$sp3b/$sp3c/$sp3d/$sp3e)"
fi
block_has "$p1a" "the $MR_STOP s \`model-run\` may take" "1a: GRACE is explained by model-run's own $MR_STOP s stop ceiling (R2-4)"
block_has "$p1a" 'read-only reviewer, no shell' "1a substitutes [VERIFICATION CONTEXT] with 'read-only reviewer, no shell'"
block_has "$p1a" 'two TAB-separated fields' "1a: batch-N.files is two TAB-separated fields (S7)"
block_has "$p1a" '### ` followed by field 1 exactly' "1a: the report heading is '### ' + field 1 (S7)"

# T7/D7: no Sonnet on the main path — on `model:` KEY lines (a YAML/dispatch
# key at line start, optionally indented or after "- "), with a boundary after
# the name; prose mentioning Sonnet is not a model setting.
SONNET_RE="^[[:space:]]*(-[[:space:]]+)?model[[:space:]]*:[[:space:]]*['\"]?(claude-)?sonnet([^A-Za-z0-9]|\$)"
sonnet_on() { printf '%s\n' "$1" | grep -Eiq -e "$SONNET_RE"; }
if [ -n "$p1a" ]; then
  mustnot "1a (main path) sets no sonnet model on any model: key line" sonnet_on "$p1a"
fi
for v in 'model: sonnet' "  model: 'sonnet'" '  model: "claude-sonnet-4-5"' 'MODEL: "Sonnet"' '- model: sonnet' 'model : sonnet'; do
  must "the sonnet detector catches the key line: $v" sonnet_on "$v"
done
for v in 'The model: sonnetish-thing' 'We used to say model: sonnet in prose' 'model: sonnets'; do
  mustnot "the sonnet detector ignores: $v" sonnet_on "$v"
done

echo "== part 2: 1a exit-code table, DONE gate, quarantine (Q2) =="

row() { printf '%s\n' "$p1a" | awk -v c="| \`$1\`" 'index($0, c) == 1 { print; exit }'; }
for code in 1 3 4 124 timeout-orphan prompt-invalid listing-invalid no-rc; do
  r=$(row "$code")
  case "$r" in
    *"fallback (1b)"*) pass "exit table: rc $code -> fallback (1b)" ;;
    *) bad "exit table: rc $code -> fallback (1b) (row: ${r:-<none>})" ;;
  esac
done
r=$(row 2)
case "$r" in
  *STOP*"exits 2"*"run ends"*) pass "exit table: rc 2 (usage) STOPs: the call exits 2 and the run ends (Q9/S2)" ;;
  *) bad "exit table: rc 2 (usage) STOPs: the call exits 2 and the run ends (row: ${r:-<none>})" ;;
esac
case "$r" in *"fallback (1b)"*) bad "exit table: rc 2 does not take the fallback" ;; *) pass "exit table: rc 2 does not take the fallback" ;; esac
r=$(printf '%s\n' "$p1a" | awk 'index($0, "| `0`, gate passes") == 1 { print; exit }')
case "$r" in *"| DONE |"*) pass "exit table: rc 0 + gate passes -> DONE" ;; *) bad "exit table: rc 0 + gate passes -> DONE (row: ${r:-<none>})" ;; esac
r=$(printf '%s\n' "$p1a" | awk 'index($0, "| `0`, gate fails") == 1 { print; exit }')
case "$r" in *quarantine*"fallback (1b)"*) pass "exit table: rc 0 + gate fails -> quarantine + fallback" ;; *) bad "exit table: rc 0 + gate fails -> quarantine + fallback (row: ${r:-<none>})" ;; esac
sp5=$(same_paragraph "$p1a" "DONE only when" "batch-N.md.incomplete") || sp5=ERR
sp6=$(same_paragraph "$p1a" "DONE only when" "lists at least") || sp6=ERR
sp6b=$(same_paragraph "$p1a" "DONE only when" "another LISTED path") || sp6b=ERR
if [ "$sp5" = YES ] && [ "$sp6" = YES ] && [ "$sp6b" = YES ]; then
  pass "DONE gate paragraph: a non-empty listing, heading + verdict per listed path, sections end at another listed path, quarantine"
else
  bad "DONE gate paragraph: non-empty listing / listed-path sections / quarantine ($sp5/$sp6/$sp6b)"
fi
block_has "$p1a" 'Do not re-run `model-run` for a failed batch' "1a: a failed batch is never re-run through model-run"
sp9=$(same_paragraph "$p1a" "DONE only when" "for EVERY listed path") || sp9=ERR
[ "$sp9" = YES ] && pass "DONE gate paragraph says 'for EVERY listed path' (item 8)" || bad "DONE gate paragraph says 'for EVERY listed path' (item 8) ($sp9)"
sp10=$(same_paragraph "$p1a" "field 1 an absolute path" "an absolute path or \`ORPHAN\`") || sp10=ERR
[ "$sp10" = YES ] && pass "1a prose: field 1 an absolute path, field 2 an absolute path or ORPHAN, else listing-invalid (item 2)" || bad "1a prose: field 1 absolute, field 2 absolute or ORPHAN (item 2) ($sp10)"
sp11=$(same_paragraph "$p1a" "in the harness's own shell" "emulation") || sp11=ERR
sp11b=$(same_paragraph "$p1a" "in the harness's own shell" 'Never wrap a call in `bash -c`') || sp11b=ERR
[ "$sp11" = YES ] && [ "$sp11b" = YES ] && pass "1a says the calls run as written in the harness's own shell (bash or zsh, no emulation needed), never wrapped in bash -c (item 1)" || bad "1a says the calls run in the harness's own shell, no emulation, never wrapped in bash -c (item 1) ($sp11/$sp11b)"
sp12=$(same_paragraph "$p1a" "DONE only when" "one pair of wrapping backticks removed") || sp12=ERR
sp12b=$(same_paragraph "$p1a" "DONE only when" "is not listed does") || sp12b=ERR
[ "$sp12" = YES ] && [ "$sp12b" = YES ] && pass "DONE gate paragraph: headings normalised on both sides; an unlisted path heading ends the section (ADV-134/ADV-126)" || bad "DONE gate paragraph: heading normalisation / unlisted path heading ends the section ($sp12/$sp12b)"
for ex in '- exit `0` — the lock is held and the prompts are written' '- exit `3` — `STOP:` on stderr with the reason' \
          '- exit `2` — a batch ended with model-run' '- exit `3` — `STOP:` on stderr before anything ran'; do
  block_has "$p1a" "$ex" "1a call contract states: ${ex}"
done
block_has "$p1a" 'the line starting `model-run: status=`' "1a: the status is the 'model-run: status=' line (K5)"
sp8=$(same_paragraph "$p1a" "A live owner" "the setup takes the reclaim mutex") || sp8=ERR
lit_in "$p1a" "takes the run lock" || sp8=NO
[ "$sp8" = YES ] && pass "1a documents the run lock and its STOP (S3)" || bad "1a documents the run lock and its STOP (S3) ($sp8)"

echo "== part 2: EXECUTING the shipped calls (Q1) — the real script, stub model-run, temp repo =="

# The ```bash blocks of 1a, cut with the SAME fence grammar as every other
# extractor (FENCE_AWK): #1 the setup call, #2 the group call; and 1d's one
# block, the save call. D1: a missing block FAILS by name. Each block's last
# line calls ~/.zuvo/test-audit-batch — the script under test, copied into the
# harness's stub HOME. awk reads to the end rather than exiting at the closing fence: an early exit
# lets printf take SIGPIPE on its remaining output, and under pipefail the block then "fails" at
# random — 40-65% of extractions under parallel load (measured 2026-10-06).
bash_block() {  # bash_block <text> <n> — the body of the n-th ```bash block
  printf '%s\n' "$1" | awk -v want="$2" "$FENCE_AWK"'
    f { next }
    { was = infc; st = fence_step($0) }
    st == 1 && trimmed($0) == "```bash" { k++; if (k == want) { o = 1 }; next }
    o && st == 2 { f = 1; next }
    o { print }
    END { exit !f }'
}
bash_block_count() {  # the number of ```bash blocks; exit 1 when one never closes (f4-68)
  printf '%s\n' "$1" | awk "$FENCE_AWK"'
    { st = fence_step($0) }
    st == 1 && trimmed($0) == "```bash" { k++ }
    END { print k + 0; exit (infc != 0) }'
}
SETUP_SH=""; GROUP_SH=""
if SETUP_SH=$(bash_block "$p1a" 1) && [ -n "$SETUP_SH" ]; then pass "1a setup bash block extracted"; else bad "1a setup bash block extracted (D1: the execution harness cannot run)"; SETUP_SH=""; fi
if GROUP_SH=$(bash_block "$p1a" 2) && [ -n "$GROUP_SH" ]; then pass "1a group bash block extracted"; else bad "1a group bash block extracted (D1: the execution harness cannot run)"; GROUP_SH=""; fi
bc_rc=0; bc_n=$(bash_block_count "$p1a") || bc_rc=$?
if [ "$bc_rc" -eq 0 ] && [ "$bc_n" = 2 ]; then pass "1a holds exactly two bash blocks, both closed"; else bad "1a holds exactly two bash blocks, both closed (found ${bc_n:-?}, unclosed=$bc_rc)"; fi
bbc_fx="$(printf '%s\n' '```bash' 'a' '```' '```bash' 'b')"
if bash_block_count "$bbc_fx" >/dev/null; then bad "bash_block_count fails on a second, UNTERMINATED bash block (f4-68)"; else pass "bash_block_count fails on a second, UNTERMINATED bash block (f4-68)"; fi
block_lacks "$script_text" '${line%% (production: *}' "the script never parses ' (production: ' back out of a listing line (S7)"
block_has "$script_text" "awk -F '\\t'" "the script reads batch-N.files as TAB-separated fields (S7)"
p1d_body=""; SAVE_SH=""
if p1d_body=$(extract_block "$SKILL" prefix '### 1d.' exact '---'); then
  if SAVE_SH=$(bash_block "$p1d_body" 1) && [ -n "$SAVE_SH" ]; then pass "1d save bash block extracted"; else bad "1d save bash block extracted (D1: the save gate cannot run)"; SAVE_SH=""; fi
else
  bad "Phase 1d section located — $(eb_reason)"
fi
block_has "$SAVE_SH" '~/.zuvo/test-audit-batch save --batch "$N"' "1d carries the save call"
for blk in "$SETUP_SH" "$GROUP_SH" "$SAVE_SH"; do
  n_calls=$(printf '%s\n' "$blk" | awk '/^[ \t]*#/ { next } index($0, "~/.zuvo/test-audit-batch ") == 1 { c++ } /[^ \t]/ && !/^[A-Z_]+=/ { o++ } END { print c + 0 ":" o + 0 }')
  if [ "$n_calls" = "1:1" ]; then pass "a call block is variable lines and ONE ~/.zuvo/test-audit-batch command, nothing else"; else bad "a call block is variable lines and ONE ~/.zuvo/test-audit-batch command, nothing else (calls:other-commands = $n_calls)"; fi
done

# The harness runs the two blocks as written under EACH shell the orchestrator may have: bash, and
# zsh (the Claude Bash tool on macOS is /bin/zsh). run_harness <shell> runs every case; its labels
# carry the shell. Leftover processes (the live-owner sleeps, stub process groups) are killed by
# ta_cleanup, chained into the file's EXIT trap and also called at the end of each leg.
harness_checks=0 TAGX="" SHX="" X="" ta_live_pids=""
hpass() { harness_checks=$((harness_checks + 1)); pass "$TAGX$1"; }
hbad()  { harness_checks=$((harness_checks + 1)); bad "$TAGX$1"; }
hres()  { if [ "$2" -eq 0 ]; then hpass "$1"; else hbad "$1"; fi; }   # hres <label> <status> — no eval (T6)
ta_cleanup() {
  for p in $ta_live_pids; do kill "$p" 2>/dev/null; done; ta_live_pids=""
  if [ -n "${X:-}" ] && [ -d "$X/log" ]; then
    for f in "$X"/log/pgid-*; do [ -f "$f" ] && perl -e 'kill("KILL", -$ARGV[0])' "$(cat "$f")" 2>/dev/null; done
  fi
  return 0
}
trap 'rm -f "$EB_REASON_FILE"; ta_cleanup' EXIT

run_harness() {
  SHX="$1"; TAGX="[$1] "; harness_checks=0
  X="$(mktemp -d 2>/dev/null)" || { bad "${TAGX}mktemp -d for the execution harness"; X=""; return; }
  mkdir -p "$X/home/.zuvo" "$X/repo" "$X/log" "$X/inc/shared/includes" "$X/inc/scripts"
  git -C "$X/repo" init -q 2>/dev/null
  cp "$PROMPT" "$X/inc/shared/includes/test-audit-batch-prompt.md"
  : > "$X/inc/scripts/reviewer-model-route.sh"
  # zuvo-base fixture: the real ~/.zuvo/zuvo-base is an EXECUTABLE (a sh/python
  # polyglot) that prints the install root on stdout, and exits 3 with no
  # output when nothing resolves (T11). This fixture is an executable script
  # with the same contract; ZB_FAIL=1 selects the exit-3 branch.
  printf '#!/bin/sh\n[ -z "${ZB_FAIL:-}" ] || exit 3\necho "%s"\n' "$X/inc" > "$X/home/.zuvo/zuvo-base"
  # The stub: markers per batch in $STUB_LOG (started-N, ended-N, pre-N = the
  # end markers present when it started, pgid-N), the mode for batch N from the
  # file $STUB_LOG/mode-N (no eval), headings from TAB field 1 of the batch's
  # own batch-N.files (T2), the assembled prompt the way model-run builds it.
  # It never reads stdin.
  cat > "$X/home/.zuvo/model-run" <<'STUB'
#!/usr/bin/env bash
# A FAITHFUL stand-in (item 6): it accepts exactly model-run's flags and refuses any other with
# exit 2 (usage), and it writes --out only on exit 0 (a temp file renamed at the very end).
out="" pf="" af="" route=0 orig=("$@")
while [ $# -gt 0 ]; do
  case "$1" in
    --route) route=1; shift ;;
    --model|--mode|--access|--read-root|--require|--reject|--timeout) [ $# -ge 2 ] || { echo "model-run: $1 needs a value" >&2; exit 2; }; shift 2 ;;
    --out) out="$2"; shift 2 ;; --prompt-file) pf="$2"; shift 2 ;; --append-file) af="$2"; shift 2 ;;
    *) echo "model-run: unknown argument: $1 (see --help)" >&2; exit 2 ;;
  esac
done
[ "$route" = 1 ] && [ -n "$out" ] && [ -f "$pf" ] && [ -f "$af" ] || { echo "model-run: --route, --out and readable prompt files are required" >&2; exit 2; }
n="${out##*batch-}"; n="${n%.md}"
case "$n" in ''|*[!0-9]*) echo "stub: cannot read the batch number from --out=$out" >&2; exit 97 ;; esac
L="$STUB_LOG"; files="${out%.md}.files"; tmp="$out.stub.$$"
: > "$L/started-$n"
printf '%s\n' "${orig[@]}" > "$L/args-$n"   # one argument per line, as this stub was really handed them
( cd "$L" && ls ) | awk '/^ended-/' > "$L/pre-$n"
ps -o pgid= -p $$ | tr -d ' ' > "$L/pgid-$n"
cat -- "$pf" "$af" > "$L/assembled-$n" 2>/dev/null
answer() {  # answer <mode> — the report for every listed file, into $tmp
  k=0; : > "$tmp"
  while IFS="$(printf '\t')" read -r t _; do
    k=$((k + 1))
    case "$1" in
      backtick) printf '### `%s`\nProduction file: x\n' "$t" >> "$tmp" ;;
      *) printf '### %s  \nProduction file: x\n' "$t" >> "$tmp" ;;
    esac
    case "$1" in
      noverdict) : ;;
      incomplete) printf 'Tier: INCOMPLETE\n' >> "$tmp" ;;
      otherpath) printf '### /abs/not-listed.test.ts\nTier: B\n' >> "$tmp" ;;
      short) printf 'Red flags: AP13 -> AUTO TIER-D\n' >> "$tmp" ;;
      unicode) printf 'Red flags: AP13 \342\206\222 AUTO TIER-D\n' >> "$tmp" ;;
      subhead) printf '### Notes\nTier: B\n' >> "$tmp" ;;
      firstonly) [ "$k" -gt 1 ] || printf 'Tier: B\n' >> "$tmp" ;;
      *) printf 'Tier: B\n' >> "$tmp" ;;
    esac
  done < "$files"
}
ok_exit() { mv -f "$tmp" "$out"; echo "model-run: status=ok client=codex model=gpt-6-sol effort=high route=cross-vendor" >&2; : > "$L/ended-$n"; exit 0; }
mode=ok; [ -f "$L/mode-$n" ] && mode="$(cat "$L/mode-$n")"
case "$mode" in
  peer:*)  # overlap proof: wait (bounded, generous) until the peer batch has STARTED
    p="${mode#peer:}"; i=0
    while [ ! -e "$L/started-$p" ] && [ "$i" -lt 300 ]; do sleep 0.1; i=$((i + 1)); done
    [ -e "$L/started-$p" ] && echo seen > "$L/overlap-$n" || echo alone > "$L/overlap-$n"
    mode=ok ;;
  hang) sleep 30 ;;
  hang-term)  # ignores TERM (so does its sleep): only the KILL after GRACE stops it
    trap '' TERM; sleep 30 ;;
  late0)  # finishing exactly as the bound hits: on TERM it completes (0.5 s) and exits 0
    answer ok; trap 'sleep 0.5; ok_exit' TERM
    sleep 30 & wait $! ;;
  late124)  # its OWN client budget runs out as the bound hits: on TERM it finishes (0.5 s) with 124
    trap 'sleep 0.5; echo "model-run: status=timeout client=codex model=gpt-6-sol effort=high route=cross-vendor" >&2; : > "$L/ended-$n"; exit 124' TERM
    sleep 30 & wait $! ;;
  die)  # the job dies before its subshell can record an exit: kill that subshell (this stub's
        # parent), after checking it IS a shell — never anything else
    : > "$L/ended-$n"
    case "$(ps -o comm= -p "$PPID" 2>/dev/null)" in *bash|*zsh|*sh) kill -KILL "$PPID" ;; esac
    exit 137 ;;
  fail3) echo "model-run: note: no line of the answer matches --require" >&2
         echo "model-run: status=invalid client=codex model=gpt-6-sol effort=high route=cross-vendor" >&2
         : > "$L/ended-$n"; exit 3 ;;
  usage) echo "model-run: --mode must be audit (see --help)" >&2; : > "$L/ended-$n"; exit 2 ;;
  wrote3)  # a complete report at --out, and yet a non-zero exit: the exit decides, never the file
    answer ok; mv -f "$tmp" "$out"
    echo "model-run: status=error client=codex model=gpt-6-sol effort=high route=cross-vendor" >&2
    : > "$L/ended-$n"; exit 4 ;;
esac
answer "$mode"
echo "model-run: note: something informative" >&2
if [ "$mode" = trailing ]; then mv -f "$tmp" "$out"; echo "model-run: status=ok client=codex model=gpt-6-sol effort=high route=cross-vendor" >&2; echo "bash: warning: some stray line" >&2; : > "$L/ended-$n"; exit 0; fi
ok_exit
STUB
  # The script under test, installed where the shipped calls look for it: ~/.zuvo/test-audit-batch,
  # beside the model-run stub and the zuvo-base fixture it runs.
  cp "$SCRIPT" "$X/home/.zuvo/test-audit-batch"
  chmod +x "$X/home/.zuvo/zuvo-base" "$X/home/.zuvo/model-run" "$X/home/.zuvo/test-audit-batch"
  B="$X/repo/zuvo/audits/.test-audit-batch"

  # subst_block <script> <NBATCH> <FIRST> <BOUND> <GRACE> [RUN_TOKEN] — the
  # block's text with those lines set (indented or not), on stdout. BOUND and
  # GRACE are not lines of the shipped call (the script's own defaults apply):
  # a value other than `-` is appended to the group command as --bound/--grace,
  # the script's test-and-tuning flags.
  subst_block() {
    printf '%s\n' "$1" | awk -v nb="$2" -v fi="$3" -v bd="$4" -v gr="$5" -v tk="${6-__keep__}" '
      match($0, /^[ \t]*NBATCH=/)    { print substr($0, 1, RLENGTH) nb; next }
      match($0, /^[ \t]*FIRST=/)     { print substr($0, 1, RLENGTH) fi; next }
      tk != "__keep__" && match($0, /^[ \t]*RUN_TOKEN=/) { print substr($0, 1, RLENGTH) tk; next }
      index($0, "/test-audit-batch group ") { if (bd != "-") $0 = $0 " --bound \"" bd "\""; if (gr != "-") $0 = $0 " --grace \"" gr "\"" }
      { print }'
  }
  # run_block <script> <NBATCH> <FIRST> <BOUND> <GRACE> [VAR=value ...] — the
  # block run by `env` in the scratch repo, as a child of THIS test (so its
  # $PPID is this test's process); stdout -> $X/log/out, stderr -> $X/log/err.
  run_block() {
    rb_s="$1" rb_nb="$2" rb_fi="$3" rb_bd="$4" rb_gr="$5"; shift 5
    subst_block "$rb_s" "$rb_nb" "$rb_fi" "$rb_bd" "$rb_gr" > "$X/log/block.sh"
    ( cd "$X/repo" && env -u ZUVO_TEST_AUDIT_PARALLEL HOME="$X/home" STUB_LOG="$X/log" "$@" "$SHX" "$X/log/block.sh" ) > "$X/log/out" 2> "$X/log/err"
  }
  write_files() {  # write_files <n>... — a 2-record TAB listing per batch, one printf per record
    for n in "$@"; do
      : > "$B/batch-$n.files"
      printf '%s\t%s\n' "/abs/t$n-a.test.ts" "/abs/p$n-a.ts" >> "$B/batch-$n.files"
      printf '%s\t%s\n' "/abs/t$n-b.test.ts" ORPHAN >> "$B/batch-$n.files"
    done
  }
  reset_log() { rm -f "$X/log"/started-* "$X/log"/ended-* "$X/log"/mode-* "$X/log"/overlap-* "$X/log"/assembled-* "$X/log"/pre-* "$X/log"/pgid-* "$X/log"/args-*; }
  mode() { printf '%s' "$2" > "$X/log/mode-$1"; }
  started() { ( cd "$X/log" && ls started-* 2>/dev/null ) | sed 's/started-//' | sort -n | tr '\n' ' '; }
  err_has() { lit_in "$(cat "$X/log/err")" "$1"; }
  gout() { cat "$X/log/group-$1.out" 2>/dev/null; }
  gbatches() { gout "$1" | awk '/^batch-[0-9]+ (DONE|FAILED)/ { sub(/^batch-/, "", $1); printf "%s ", $1 }'; }

  # one_run <NBATCH> <group-FIRSTs...> — setup, the listings, then each group
  # call, ALL children of one parent script (run.sh): the harness's one
  # process, so they share the lock owner $PPID. run.sh reads the setup's
  # RUN_TOKEN= line and writes it — and each FIRST — into the group script with
  # the same indent-safe substitution (T11). Knobs, set as a call prefix:
  # OR_PAR, OR_BOUND, OR_GRACE, PRE_GROUP (shell run before the groups),
  # REENTER=1 (run the setup a second time with the run's token).
  one_run() {
    or_nb="$1"; shift
    rm -f "$B/.lock"; rm -rf "$B/.lock.reclaim"   # the previous case's run ended: Phase 3 released its lock
    subst_block "$SETUP_SH" "$or_nb" 1 560 15 > "$X/log/setup.sh"
    subst_block "$GROUP_SH" "$or_nb" 1 "${OR_BOUND:--}" "${OR_GRACE:--}" > "$X/log/group.sh"
    printf '%s\n' "$SETUP_SH" > "$X/log/setup.raw"
    or_par=""; [ -z "${OR_PAR+x}" ] || or_par="ZUVO_TEST_AUDIT_PARALLEL=$OR_PAR"
    {
      echo 'set -u'
      echo 'subst() { awk -v k="$1" -v v="$2" '"'"'match($0, "^[ \t]*" k "=") { print substr($0, 1, RLENGTH) v; next } { print }'"'"' "$3"; }'
      echo '"$SHX" "$SETUP" > "$LOG/setup.out" 2> "$LOG/setup.err"; echo "$?" > "$LOG/setup.rc"'
      echo '[ "$(cat "$LOG/setup.rc")" = 0 ] || exit 0'
      echo 'tok="$(awk -F= '"'"'/^RUN_TOKEN=/ { print $2 }'"'"' "$LOG/setup.out")"'
      echo 'gtok="${GTOK:-$tok}"'
      echo 'if [ -n "${REENTER:-}" ]; then subst RUN_TOKEN "$tok" "$SETUP" > "$LOG/setup2.sh"; "$SHX" "$LOG/setup2.sh" > "$LOG/setup2.out" 2> "$LOG/setup2.err"; echo "$?" > "$LOG/setup2.rc"; fi'
      echo 'if [ -n "${NEWRUN:-}" ]; then "$SHX" "$SETUP" > "$LOG/setup3.out" 2> "$LOG/setup3.err"; echo "$?" > "$LOG/setup3.rc"; fi'
      echo 'for n in $(seq 1 '"$or_nb"'); do : > "$BDIR/batch-$n.files"; printf "%s\t%s\n" "/abs/t$n-a.test.ts" "/abs/p$n-a.ts" >> "$BDIR/batch-$n.files"; printf "%s\t%s\n" "/abs/t$n-b.test.ts" ORPHAN >> "$BDIR/batch-$n.files"; done'
      echo '[ -z "${PRE_GROUP:-}" ] || sh -c "$PRE_GROUP"'
      k=0
      for f in "$@"; do
        k=$((k + 1))
        echo "subst RUN_TOKEN \"\$gtok\" \"\$GROUP\" > \"\$LOG/g.tmp\"; subst FIRST $f \"\$LOG/g.tmp\" > \"\$LOG/group-$k.sh\""
        echo "\"\$SHX\" \"\$LOG/group-$k.sh\" > \"\$LOG/group-$k.out\" 2> \"\$LOG/group-$k.err\"; echo \"\$?\" > \"\$LOG/group-$k.rc\""
      done
      # REENTER_AFTER: shell run AFTER the groups, then the setup once more with the run's token (a
      # same-run re-run, e.g. to rebuild a prompt), into setup4.*.
      echo 'if [ -n "${REENTER_AFTER:-}" ]; then sh -c "$REENTER_AFTER"; subst RUN_TOKEN "$tok" "$SETUP" > "$LOG/setup4.sh"; "$SHX" "$LOG/setup4.sh" > "$LOG/setup4.out" 2> "$LOG/setup4.err"; echo "$?" > "$LOG/setup4.rc"; fi'
    } > "$X/log/run.sh"
    ( cd "$X/repo" && env -u ZUVO_TEST_AUDIT_PARALLEL HOME="$X/home" STUB_LOG="$X/log" LOG="$X/log" BDIR="$B" \
        SETUP="$X/log/setup.sh" GROUP="$X/log/group.sh" PRE_GROUP="${PRE_GROUP:-}" REENTER="${REENTER:-}" NEWRUN="${NEWRUN:-}" GTOK="${GTOK:-}" \
        REENTER_AFTER="${REENTER_AFTER:-}" SHX="$SHX" ${or_par:+"$or_par"} bash "$X/log/run.sh" )
  }

  # --- setup: ZUVO_BASE is validated (S6), against the real zuvo-base contract (T11)
  mv "$X/inc/scripts/reviewer-model-route.sh" "$X/inc/scripts/route.off"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: ZUVO_BASE=" && [ ! -e "$B/.lock" ] && [ ! -L "$B/.lock" ]; }
  hres "setup STOPs (exit 3, named reason) when ZUVO_BASE holds no scripts/reviewer-model-route.sh (S6)" $?
  mv "$X/inc/scripts/route.off" "$X/inc/scripts/reviewer-model-route.sh"
  run_block "$SETUP_SH" 3 1 560 15 ZB_FAIL=1; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: ZUVO_BASE=''"; }
  hres "setup STOPs when zuvo-base exits 3 with no output (the helper's own contract)" $?

  # --- setup: stale files cleared (K3), prompts built and valid (K6), lock taken (S3/P1)
  mkdir -p "$B"; printf 'Tier: A\n' > "$B/batch-9.md"; printf '0\n' > "$B/batch-1.rc"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  hres "setup block exits 0" "$rc"
  if { [ ! -e "$B/batch-9.md" ] && [ ! -e "$B/batch-1.rc" ]; }; then st_=0; else st_=1; fi
  hres "setup clears an earlier run's batch files (K3)" "$st_"
  lk="$(readlink "$B/.lock" 2>/dev/null)"; tk="$(awk -F= '/^RUN_TOKEN=/ { print $2 }' "$X/log/out")"
  { [ -L "$B/.lock" ] && printf '%s\n' "$lk" | awk -v t="$tk" 'NF == 3 && $1 ~ /^[0-9]+$/ && $2 ~ /^[0-9]+$/ && $3 == t && t != "" { f = 1 } END { exit !f }'; }
  hres "setup takes the lock as ONE atomic link '<pid> <epoch> <token>' and prints RUN_TOKEN=<that token> (P1)" $?
  ok=1
  for n in 1 2 3; do
    awk '$0 == "Verification context: read-only reviewer, no shell" { v = 1 }
         $0 == "[BATCH FILE LIST]" || index($0, "Verification context: [VERIFICATION CONTEXT]") == 1 { b = 1 }
         index($0, "OUTPUT LINE FORMAT") == 1 { o = 1 }
         { last = $0 }
         END { exit !(v && !b && o && last == "Files to audit:") }' "$B/batch-$n.prompt" 2>/dev/null || ok=0
  done
  hres "setup writes batch-1..3.prompt: read-only value, no placeholder, OUTPUT LINE FORMAT, ends at 'Files to audit:'" $((1 - ok))
  if [ ! -e "$B/batch-4.prompt" ]; then st_=0; else st_=1; fi; hres "setup writes exactly NBATCH prompts" "$st_"

  # --- lock (T5): a live foreign owner the test controls; lock taken BEFORE any file is cleared
  sleep 300 & live=$!; ta_live_pids="$ta_live_pids $live"
  rm -f "$B/.lock"; ln -s "$live $(date +%s) foreign-tok" "$B/.lock"; printf 'Tier: A\n' > "$B/batch-9.md"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: another test-audit run (pid $live)" && [ -e "$B/batch-9.md" ] && [ "$(readlink "$B/.lock" | awk '{ print $1 " " $3 }')" = "$live foreign-tok" ]; }
  hres "setup STOPs (exit 3) on a LIVE foreign owner, before clearing anything (batch-9.md survives), lock untouched" $?
  write_files 1 2 3; reset_log
  run_block "$GROUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: this run does not hold" && [ -z "$(started)" ]; }
  hres "a group call STOPs (exit 3) when this run does not hold the lock, and runs nothing" $?
  # PID reuse (T5): the same live pid, but the lock is OLDER than that process — it is not its owner
  rm -f "$B/.lock"; ln -s "$live $(( $(date +%s) - 1000 )) old-tok" "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 0 ] && err_has "reclaimed the lock of a run that is gone" && [ -L "$B/.lock.stale.$(awk -F= '/^RUN_TOKEN=/ { print $2 }' "$X/log/out")" ]; }
  hres "a lock older than the live process holding its pid is stale (pid reuse) and is reclaimed by an atomic rename (P1)" $?
  # …and the tolerance is the 2 s of ps/clock granularity, not minutes: a lock only 60 s older than the
  # live process is already stale.
  sleep 300 & live3=$!; ta_live_pids="$ta_live_pids $live3"
  rm -f "$B/.lock" "$B"/.lock.stale.*; ln -s "$live3 $(( $(date +%s) - 60 )) near-tok" "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 0 ] && err_has "reclaimed the lock of a run that is gone" && [ -L "$B/.lock.stale.$(awk -F= '/^RUN_TOKEN=/ { print $2 }' "$X/log/out")" ]; }
  hres "a lock 60 s older than the live process holding its pid is stale too (the tolerance is 2 s), reclaimed by the atomic rename" $?
  rm -f "$B"/.lock.stale.*
  kill "$live3" 2>/dev/null; wait "$live3" 2>/dev/null
  kill "$live" 2>/dev/null; wait "$live" 2>/dev/null
  rm -f "$B/.lock"; ln -s "$live 1 dead-tok" "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 0 ] && err_has "reclaimed the lock of a run that is gone"; }
  hres "a lock whose owner is gone is reclaimed (setup exits 0, says so)" $?
  # EPERM (f2-30): pid 1 is alive but another user's — kill -0 fails on it with EPERM; ps sees it.
  rm -f "$B/.lock"; ln -s "1 $(date +%s) root-tok" "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: another test-audit run (pid 1)"; }
  hres "an owner alive under ANOTHER uid (pid 1: kill -0 says EPERM) is alive, never reclaimed (P1)" $?
  # Reclaim re-check (P1): between reading the stale record and taking the reclaim mutex, another
  # run reclaims and takes a LIVE lock. A mkdir shim performs that swap exactly then; the setup
  # must re-read, see a different record, leave it alone, and STOP on the live owner.
  sleep 300 & live2=$!; ta_live_pids="$ta_live_pids $live2"
  mkdir -p "$X/shim"
  printf '#!/bin/sh
for a in "$@"; do case "$a" in *.lock.reclaim) [ -z "${SWAP_TO:-}" ] || { rm -f "${a%%.reclaim}"; ln -s "$SWAP_TO" "${a%%.reclaim}"; SWAP_TO=""; } ;; esac; done
exec /bin/mkdir "$@"
' > "$X/shim/mkdir"
  chmod +x "$X/shim/mkdir"
  rm -f "$B/.lock"; ln -s "999999 1 gone-tok" "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15 PATH="$X/shim:$PATH" SWAP_TO="$live2 $(date +%s) other-live-tok"; rc=$?
  if { [ "$rc" = 3 ] && [ "$(readlink "$B/.lock" | awk '{ print $1 " " $3 }')" = "$live2 other-live-tok" ]; }; then st_=0; else st_=1; fi
  hres "a stale lock replaced by a LIVE one mid-reclaim is re-read and left alone (the setup STOPs) (P1)" "$st_"
  kill "$live2" 2>/dev/null; wait "$live2" 2>/dev/null
  # A reclaim mutex left by a run that died inside the reclaim: older than 120 s it self-heals
  # (removed once, the setup proceeds); a FRESH one is respected (the setup STOPs as contended).
  rm -f "$B/.lock"; rm -rf "$B/.lock.reclaim"; ln -s "999999 1 gone-tok" "$B/.lock"
  mkdir "$B/.lock.reclaim"; touch -t "$(date -r $(( $(date +%s) - 600 )) +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$(( $(date +%s) - 600 ))" +%Y%m%d%H%M.%S)" "$B/.lock.reclaim"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 0 ] && err_has "removed a reclaim mutex older than 120 s" && err_has "reclaimed the lock of a run that is gone" && [ ! -d "$B/.lock.reclaim" ]; }
  hres "a reclaim mutex aged 600 s is removed once and the setup proceeds (self-healing)" $?
  rm -f "$B/.lock"; rm -rf "$B/.lock.reclaim"; ln -s "999999 1 gone-tok" "$B/.lock"
  mkdir "$B/.lock.reclaim"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: could not take" && [ -d "$B/.lock.reclaim" ] && ! err_has "removed a reclaim mutex"; }
  hres "a FRESH reclaim mutex (another run is reclaiming now) is left alone: the setup STOPs as contended" $?
  rm -rf "$B/.lock.reclaim"; rm -f "$B/.lock"
  # two setups of two different runs at once: exactly one wins (P1). Each runs under its
  # own parent, which stays alive past the race (the owner a loser checks is live).
  rm -f "$B/.lock" "$B"/.lock.stale.*
  subst_block "$SETUP_SH" 3 1 560 15 > "$X/log/race.sh"
  for r in a b; do
    ( cd "$X/repo" && env HOME="$X/home" bash -c '"$3" "$1" > "$2.out" 2> "$2.err"; echo "$?" > "$2.rc"; sleep 4' _ "$X/log/race.sh" "$X/log/race-$r" "$SHX" ) &
  done
  wait
  wins=$(cat "$X/log/race-a.rc" "$X/log/race-b.rc" 2>/dev/null | awk '$1 == 0 { w++ } $1 == 3 { l++ } END { print w + 0 "/" l + 0 }')
  if [ "$wins" = "1/1" ]; then st_=0; else st_=1; fi; hres "two concurrent setups of different runs: exactly one takes the lock, the other STOPs (P1) — got wins/stops=$wins" "$st_"
  rm -f "$B/.lock" "$B"/.lock.stale.*
  # same harness process, a NEW run (another token) while the lock is held: STOP, never a silent re-take (f2-18)
  reset_log
  REENTER=1 NEWRUN=1 one_run 2 1
  { [ "$(cat "$X/log/setup2.rc")" = 0 ] && [ "$(cat "$X/log/group-1.rc")" = 0 ] && lit_in "$(gout 1)" "batch-1 DONE"; }
  hres "a setup re-run inside the SAME run (same process, same RUN_TOKEN) keeps the lock, and the group still runs" $?
  { [ "$(cat "$X/log/setup3.rc")" = 3 ] && lit_in "$(cat "$X/log/setup3.err")" "STOP: an earlier test-audit run of THIS session"; }
  hres "a NEW run from the same harness process (no token) while the lock is held STOPs — never a silent re-take (f2-18)" $?
  reset_log
  GTOK=not-this-run one_run 2 1
  { [ "$(cat "$X/log/group-1.rc")" = 3 ] && lit_in "$(cat "$X/log/group-1.err")" "STOP: this run does not hold" && [ -z "$(started)" ]; }
  hres "a group call with this process but ANOTHER run token STOPs and runs nothing (P1)" $?

  # --- one run, group 1 of 5 at default P: batches 1+2 overlap (ordering, D3), the call waits for both
  reset_log; mode 1 peer:2; mode 2 peer:1
  one_run 5 1
  if [ "$(started)" = "1 2 " ]; then st_=0; else st_=1; fi; hres "group FIRST=1, P unset: model-run runs for batches 1 and 2 only (K1)" "$st_"
  if { [ "$(cat "$X/log/overlap-1" 2>/dev/null)" = seen ] && [ "$(cat "$X/log/overlap-2" 2>/dev/null)" = seen ]; }; then st_=0; else st_=1; fi
  hres "batches 1 and 2 ran side by side: each saw the other START before it finished (D3)" "$st_"
  { [ -e "$X/log/ended-1" ] && [ -e "$X/log/ended-2" ] && lit_in "$(gout 1)" "batch-1 DONE rc=0" && lit_in "$(gout 1)" "batch-2 DONE rc=0"; }
  hres "the call returned only after both jobs ended, and both are DONE (wait before the gate)" $?
  for n in 1 2; do
    { [ "$(cat "$B/batch-$n.rc" 2>/dev/null)" = 0 ] && awk '/^model-run: status=ok / { f = 1 } END { exit !f }' "$B/batch-$n.status"; }
    hres "batch-$n.rc (0) and a canonical 'model-run: status=ok ' line in batch-$n.status (T6)" $?
    cat "$B/batch-$n.prompt" "$B/batch-$n.list" 2>/dev/null | cmp -s - "$X/log/assembled-$n"
    hres "batch-$n: the reviewer got exactly batch-N.prompt then the rendered listing (S7)" $?
    printf '%s (production: %s)\n%s (production: %s)\n' "/abs/t$n-a.test.ts" "/abs/p$n-a.ts" "/abs/t$n-b.test.ts" ORPHAN | cmp -s - "$B/batch-$n.list"
    hres "batch-$n.list renders every record of the TAB listing (T2)" $?
  done
  lit_in "$(gout 1)" "batch-1 DONE rc=0 model-run: status=ok client=codex"
  hres "gate: the verdict carries the 'model-run: status=' line, not the note before it (K5)" $?
  if [ ! -e "$B/batch-3.rc" ]; then st_=0; else st_=1; fi; hres "group 1 leaves batch 3 to the next call" "$st_"
  # What model-run was REALLY handed, one argument per line (the stub's record) — the whole command,
  # in order, with the script's own patterns, the repository root and the per-batch files.
  rr="$(cd "$X/repo" && pwd -P)"
  printf '%s\n' --route --mode audit --access read --read-root "$rr" \
      --prompt-file zuvo/audits/.test-audit-batch/batch-1.prompt --append-file zuvo/audits/.test-audit-batch/batch-1.list \
      --require "$S_REQ" --reject "$S_REJ" --timeout "$S_TMO" --out zuvo/audits/.test-audit-batch/batch-1.md \
    | cmp -s - "$X/log/args-1"
  hres "model-run is handed exactly: --route --mode audit --access read --read-root <repo>, the batch's prompt and listing, the script's --require/--reject, --timeout $S_TMO, --out batch-1.md" $?

  # --- group separation across calls: group 2 starts only after group 1's jobs ENDED (D3)
  reset_log
  one_run 4 1 3
  { [ "$(started)" = "1 2 3 4 " ] && grep -qx ended-1 "$X/log/pre-3" && grep -qx ended-2 "$X/log/pre-3" \
      && grep -qx ended-1 "$X/log/pre-4" && grep -qx ended-2 "$X/log/pre-4" && lit_in "$(gout 2)" "batch-3 DONE" && lit_in "$(gout 2)" "batch-4 DONE"; }
  hres "two groups in one run: group 2 (batches 3,4) starts only after every group-1 job ended" $?
  # Each call says where the next one starts, so the orchestrator copies it rather than recomputing P.
  if [ "$(gout 1 | tail -n 1)" = "NEXT_FIRST=3" ] && [ "$(gout 2 | tail -n 1)" = "NEXT_FIRST=none" ]; then st_=0; else st_=1; fi
  hres "each group call's last line names the next FIRST (NEXT_FIRST=3), the last group NEXT_FIRST=none (BEHAV-2)" "$st_"

  # --- the last group clamps to NBATCH; P is decimal, leading zeros stripped, validated and capped (K1/S9/P6);
  #     every case runs TWO groups and asserts both boundaries (T3)
  reset_log; one_run 5 5
  { [ "$(started)" = "5 " ] && [ ! -e "$B/batch-6.rc" ] && ! lit_in "$(gout 1)" "batch-6"; }
  hres "group FIRST=5 of NBATCH=5 runs batch 5 only, and never touches a batch past NBATCH" $?
  for pv in 9:4 abc:2 0:2 00:2 000:2 -3:2 03:3 05:4 08:4 09:4 0003:3 0005:4 0000000003:3 3:3 1:1 99999999999999999999:4 18446744073709551617:4 '':2; do
    p="${pv#*:}"; reset_log
    OR_PAR="${pv%%:*}" one_run 9 1 $((1 + p))
    w1=""; w2=""; i=1; while [ "$i" -le "$p" ]; do w1="$w1$i "; w2="$w2$((i + p)) "; i=$((i + 1)); done
    g1="$(gbatches 1)"; g2="$(gbatches 2)"
    # the status is captured BEFORE the label is built: a $(...) inside hres's arguments would reset $?
    if [ "$g1" = "$w1" ] && [ "$g2" = "$w2" ]; then st_=0; else st_=1; fi
    hres "ZUVO_TEST_AUDIT_PARALLEL='${pv%%:*}' -> P=$p: group 1 = [${w1% }], group 2 = [${w2% }] (got [${g1% }] / [${g2% }])" "$st_"
  done

  # --- stale success never survives; each failure kind is FAILED + quarantined (K2/K4/K5/S8/P4)
  reset_log; mode 1 fail3; mode 2 noverdict; mode 3 trailing; mode 4 subhead
  PRE_GROUP="printf '0\n' > '$B/batch-1.rc'; printf '### /abs/t1-a.test.ts\nTier: A\n### /abs/t1-b.test.ts\nTier: A\n' > '$B/batch-1.md'" \
    OR_PAR=4 one_run 4 1
  { lit_in "$(gout 1)" "batch-1 FAILED rc=3 model-run: status=invalid" && [ ! -e "$B/batch-1.md" ]; }
  hres "a batch that fails now is FAILED even with a stale batch-1.rc/.md of 0/valid before it (K2)" $?
  { lit_in "$(gout 1)" "batch-2 FAILED rc=0" && [ -f "$B/batch-2.md.incomplete" ] && [ ! -e "$B/batch-2.md" ]; }
  hres "rc 0 but a section without a verdict line: FAILED, quarantined as batch-2.md.incomplete (K4)" $?
  lit_in "$(gout 1)" "batch-3 DONE rc=0 model-run: status=ok client=codex"
  hres "the status is read from the 'model-run: status=' line even with a stray line after it (K5)" $?
  lit_in "$(gout 1)" "batch-4 DONE rc=0"; hres "a reviewer's own ### heading inside a file's section does not end it (S8)" $?
  reset_log; mode 1 short; mode 2 unicode; mode 3 die; mode 4 firstonly
  OR_PAR=4 one_run 4 1
  lit_in "$(gout 1)" "batch-1 DONE rc=0"; hres "an all-AUTO-TIER-D batch (Red flags ... -> AUTO TIER-D, no Tier line) is DONE" $?
  lit_in "$(gout 1)" "batch-2 FAILED rc=0"; hres "a Unicode-arrow red-flag line is not a verdict line (FAILED)" $?
  lit_in "$(gout 1)" "batch-3 FAILED rc=no-rc"; hres "a job whose process group dies before writing batch-N.rc is FAILED rc=no-rc (K2)" $?
  lit_in "$(gout 1)" "batch-4 FAILED rc=0"; hres "a verdict under path A never counts for path B (P4)" $?
  # R2-2 / ADV-134 / ADV-126: the machine encoding of "no tier", the heading normalisation, and an
  # unlisted path heading between a listed file and a verdict.
  reset_log; mode 1 incomplete; mode 2 backtick; mode 3 otherpath
  OR_PAR=3 one_run 3 1
  lit_in "$(gout 1)" "batch-1 DONE rc=0"; hres "a file with nothing applicable writes 'Tier: INCOMPLETE': a verdict line, the batch is DONE (R2-2)" $?
  lit_in "$(gout 1)" "batch-2 DONE rc=0"; hres "a heading in backticks ('### \`<path>\`') still names its listed file: DONE (ADV-134)" $?
  { lit_in "$(gout 1)" "batch-3 FAILED rc=0" && [ -f "$B/batch-3.md.incomplete" ] && [ ! -e "$B/batch-3.md" ]; }
  hres "a Tier under an UNLISTED '### <other path>' does not count for the listed file above it: FAILED (ADV-126)" $?

  # --- 1d (R2-1): the save gate for an in-harness report is the DONE gate's per-file check, run by
  #     the shipped save call. run_save <N> writes nothing itself: the case plants .files/.returned.
  run_save() {
    printf '%s\n' "$SAVE_SH" | awk -v n="$1" 'match($0, /^[ \t]*N=/) { print substr($0, 1, RLENGTH) n; next } { print }' > "$X/log/save.sh"
    ( cd "$X/repo" && env HOME="$X/home" "$SHX" "$X/log/save.sh" ) > "$X/log/save.out" 2> "$X/log/save.err"
  }
  sv_ok() { [ "$1" = 0 ] && lit_in "$(cat "$X/log/save.out")" "batch-7 SAVED" && [ -f "$B/batch-7.md" ] && [ ! -e "$B/batch-7.returned" ] && [ ! -e "$B/batch-7.md.incomplete" ]; }
  sv_no() { [ "$1" = 1 ] && lit_in "$(cat "$X/log/save.out")" "batch-7 NOT-SAVED" && [ ! -e "$B/batch-7.md" ]; }
  sv_reset() { rm -f "$B"/batch-7.*; printf '%s\t%s\n' "$1" "/abs/p7-a.ts" > "$B/batch-7.files"; printf '%s\t%s\n' "$2" ORPHAN >> "$B/batch-7.files"; }
  sv_reset /abs/t7-a.test.ts /abs/t7-b.test.ts
  printf '### /abs/t7-a.test.ts\nTier: A\n### /abs/t7-b.test.ts\nRed flags: AP13 -> AUTO TIER-D\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; sv_ok "$rc"
  hres "save: a returned report with a section and a verdict per listed file is saved as batch-7.md (R2-1)" $?
  sv_reset /abs/t7-a.test.ts /abs/t7-b.test.ts
  printf '### /abs/t7-a.test.ts\nTier: A\n### /abs/t7-b.test.ts\nProduction file: x\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; { sv_no "$rc" && [ -f "$B/batch-7.md.incomplete" ]; }
  hres "save: every heading present but one section WITHOUT a verdict line is NOT saved, and is quarantined (R2-1)" $?
  sv_reset /abs/t7-a.test.ts /abs/t7-b.test.ts
  printf '### /abs/t7-a.test.ts\nTier: A\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; { sv_no "$rc" && [ -f "$B/batch-7.md.incomplete" ]; }
  hres "save: a report missing a listed file's section is NOT saved, and is quarantined" $?
  sv_reset /abs/t7-a.test.ts /abs/t7-b.test.ts
  printf '### /abs/t7-a.test.ts\n**Tier: A**\n### /abs/t7-b.test.ts\n  Tier: B\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; { sv_no "$rc" && [ -f "$B/batch-7.md.incomplete" ]; }
  hres "save: a decorated or indented Tier line is not a verdict line here either (the same check as 1a), and is quarantined" $?
  sv_reset src/t7-a.test.ts ./src/t7-b.test.ts
  printf '### ./src/t7-a.test.ts\nTier: INCOMPLETE\n### `src/t7-b.test.ts`\nTier: C\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; sv_ok "$rc"
  hres "save: relative paths as listed to an in-harness agent; './' and backticks normalised on both sides; Tier: INCOMPLETE counts (ADV-134/R2-2)" $?
  # Both normalisations on ONE heading: a backtick-quoted path that also starts with './'.
  sv_reset src/t7-a.test.ts src/t7-b.test.ts
  printf '### `./src/t7-a.test.ts`\nTier: A\n### src/t7-b.test.ts\nTier: B\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; sv_ok "$rc"
  hres "save: a heading that is backtick-quoted AND starts with './' matches the listed path" $?
  rm -f "$B"/batch-7.*; printf '### /abs/t7-a.test.ts\nTier: A\n' > "$B/batch-7.returned"
  run_save 7; rc=$?; { sv_no "$rc" && lit_in "$(cat "$X/log/save.out")" "batch-7.files is missing"; }
  hres "save: no batch-7.files listing - NOT saved, by name" $?
  rm -f "$B"/batch-7.*

  # --- release: only the run that holds the lock removes it
  rm -f "$B/.lock"; ln -s "4242 $(date +%s) rel-tok" "$B/.lock"
  ( cd "$X/repo" && env HOME="$X/home" "$X/home/.zuvo/test-audit-batch" release --owner 4242 --token other-tok ) > /dev/null 2> "$X/log/err"; rc=$?
  { [ "$rc" = 3 ] && [ -L "$B/.lock" ] && err_has "is not this run's"; }
  hres "release with another run's token STOPs (exit 3) and leaves the lock alone" $?
  ( cd "$X/repo" && env HOME="$X/home" "$X/home/.zuvo/test-audit-batch" release --owner 4242 --token rel-tok ) > /dev/null 2> "$X/log/err"; rc=$?
  if [ "$rc" = 0 ] && [ ! -L "$B/.lock" ] && [ ! -e "$B/.lock" ]; then st_=0; else st_=1; fi
  hres "release with the run's own owner and token removes the lock (exit 0)" "$st_"
  ( cd "$X/repo" && env HOME="$X/home" "$X/home/.zuvo/test-audit-batch" group --nbatch 1 --first 1 --token t ) > /dev/null 2> "$X/log/err"; rc=$?
  { [ "$rc" = 2 ] && err_has "--owner must be the harness pid"; }
  hres "a call without --owner is a usage error (exit 2): the script never guesses the lock's owner from its own parent" $?

  # --- S1/P5: an empty listing, a blank-only listing, and a line with a third TAB field never run
  reset_log
  PRE_GROUP="printf '' > '$B/batch-1.files'; printf '\n \n' > '$B/batch-2.files'; printf '/abs/x\t/abs/y\t/abs/z\n' > '$B/batch-3.files'" one_run 3 1 3
  { lit_in "$(gout 1)" "batch-1 FAILED rc=listing-invalid" && lit_in "$(gout 1)" "batch-2 FAILED rc=listing-invalid" \
      && lit_in "$(gout 2)" "batch-3 FAILED rc=listing-invalid" && [ -z "$(started)" ] \
      && lit_in "$(cat "$X/log/group-2.err")" "listing-invalid: batch-3"; }
  hres "empty, blank-only and 3-field listings are FAILED rc=listing-invalid with a named error, and never run (S1/P5)" $?

  # --- item 2: a relative field 1, and a field 2 that is neither absolute nor ORPHAN, are listing-invalid
  reset_log
  PRE_GROUP="printf 'rel/t1.test.ts\t/abs/p1.ts\n' > '$B/batch-1.files'; printf '/abs/t2.test.ts\tsrc/p2.ts\n' > '$B/batch-2.files'" one_run 2 1
  { lit_in "$(gout 1)" "batch-1 FAILED rc=listing-invalid" && lit_in "$(gout 1)" "batch-2 FAILED rc=listing-invalid" && [ -z "$(started)" ]; }
  hres "a RELATIVE test path and a relative production path are listing-invalid, never run (item 2)" $?

  # --- item 9: a stale rc of 0 before the job, and the job dies before recording one: no-rc, never 0
  reset_log; mode 1 die
  PRE_GROUP="printf '0\n' > '$B/batch-1.rc'" one_run 2 1
  lit_in "$(gout 1)" "batch-1 FAILED rc=no-rc"; hres "a stale batch-1.rc of 0 + a job that dies before writing one: FAILED rc=no-rc (item 9)" $?

  # --- item 5: NBATCH/FIRST/BOUND/GRACE are validated; a FIRST past NBATCH never counts down
  for bad_ in "0 1 560 15" "3 4 560 15" "3 1 0 15" "3 1 560 x" "3 01 560 15"; do
    set -- $bad_; reset_log
    run_block "$GROUP_SH" "$1" "$2" "$3" "$4"; rc=$?
    { [ "$rc" = 3 ] && { err_has "must be positive whole numbers" || err_has "is past NBATCH"; } && [ -z "$(started)" ]; }
    hres "group call with NBATCH=$1 FIRST=$2 BOUND=$3 GRACE=$4 STOPs on the VALIDATION (not the lock) and runs nothing (item 5)" $?
  done
  run_block "$SETUP_SH" 0 1 560 15; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: NBATCH='0'"; }
  hres "setup with NBATCH=0 STOPs (item 5)" $?

  # --- item 3/N8: a .lock that is a directory or a regular file (not our link) STOPs by name
  rm -f "$B/.lock"; mkdir "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  if { [ "$rc" = 3 ] && err_has "is not a lock link"; }; then st_=0; else st_=1; fi
  rmdir "$B/.lock"; : > "$B/.lock"
  run_block "$SETUP_SH" 3 1 560 15; rc=$?
  { [ "$st_" = 0 ] && [ "$rc" = 3 ] && err_has "is not a lock link"; }
  hres "a .lock that is a directory, or a regular file, STOPs setup by name (N8)" $?
  rm -f "$B/.lock"

  # --- item 10: this session's own leftover lock (same harness process, another token) says how to clear it
  reset_log
  NEWRUN=1 one_run 1 1
  { [ "$(cat "$X/log/setup3.rc")" = 3 ] && lit_in "$(cat "$X/log/setup3.err")" "an earlier test-audit run of THIS session" && lit_in "$(cat "$X/log/setup3.err")" "clear it: rm -f zuvo/audits/.test-audit-batch/.lock"; }
  hres "a leftover lock of THIS session's earlier run STOPs with the command that clears it (item 10)" $?

  # --- item 6: the block's exact model-run command, against the REAL scripts/zuvo-home/model-run:
  #     its flags parse (exit is not 2). Nothing can run: the codex/claude CLIs point at /nonexistent.
  reset_log; rm -f "$B/.lock"
  one_run 1 1 >/dev/null 2>&1
  # A second install dir: the script under test beside a launcher that execs the REAL model-run from
  # its own path in the repo (so it finds its runner and router there, not in this stub HOME).
  mkdir -p "$X/real"
  cp "$SCRIPT" "$X/real/test-audit-batch"
  printf '#!/bin/sh\nexec "%s" "$@"\n' "$ROOT/scripts/zuvo-home/model-run" > "$X/real/model-run"
  chmod +x "$X/real/test-audit-batch" "$X/real/model-run"
  subst_block "$GROUP_SH" 1 1 560 15 real-tok | awk -v tb="$X/real/test-audit-batch " '{ i = index($0, "~/.zuvo/test-audit-batch "); if (i) $0 = substr($0, 1, i - 1) tb substr($0, i + 25); print }' > "$X/log/real.sh"
  # the parent that runs the block owns the lock (as the harness process does): it writes it itself
  printf '%s\n' 'rm -f "$1/.lock"; ln -s "$$ $(date +%s) real-tok" "$1/.lock"; "$2" "$3"' > "$X/log/real-parent.sh"
  # The shell by its absolute path: PATH is narrowed below, and zsh is not in /usr/bin:/bin everywhere
  # (a user-local zsh never ran here, and the stale batch-1.rc of the run above was read as its result).
  # The previous run's rc/status go first, so a block that never ran cannot be scored on them.
  shx_abs="$(command -v "$SHX")"; rm -f "$B/batch-1.rc" "$B/batch-1.status"
  ( cd "$X/repo" && env HOME="$X/home" ZUVO_CODEX_BIN=/nonexistent ZUVO_CLAUDE_BIN=/nonexistent CLAUDECODE=1 PATH=/usr/bin:/bin \
      bash "$X/log/real-parent.sh" "$B" "$shx_abs" "$X/log/real.sh" ) > "$X/log/real.out" 2> "$X/log/real.err"
  rrc="$(cat "$B/batch-1.rc" 2>/dev/null)"
  { [ -n "$rrc" ] && [ "$rrc" != 2 ] && [ "$rrc" != 127 ] && awk '/^model-run: status=unavailable / { f = 1 } END { exit !f }' "$B/batch-1.status"; }
  hres "the block's command, run against the REAL model-run, parses (rc=$rrc, not 2) and reports status=unavailable (item 6)" $?

  # --- S2: a usage error STOPs in the executable flow
  reset_log; mode 1 usage
  one_run 2 1
  { [ "$(cat "$X/log/group-1.rc")" = 2 ] && lit_in "$(gout 1)" "STOP: batch-1: model-run usage error" && lit_in "$(gout 1)" "model-run: --mode must be audit"; }
  hres "rc 2 prints 'STOP:' with batch-N.status and the call exits 2 (S2)" $?

  # --- S4/P2/P3: a job alive at BOUND is killed with its process group and marked in batch-N.orphan;
  #     a late job whose rc is already one of model-run's exits keeps it
  reset_log; mode 1 hang; mode 2 late0; mode 3 hang-term
  OR_BOUND=4 OR_GRACE=2 OR_PAR=3 one_run 3 1
  { lit_in "$(gout 1)" "batch-1 FAILED rc=timeout-orphan" && [ "$(cat "$B/batch-1.orphan" 2>/dev/null)" = timeout-orphan ]; }
  hres "a job still running at BOUND: batch-1.orphan = timeout-orphan, FAILED rc=timeout-orphan (S4/P2)" $?
  { lit_in "$(gout 1)" "batch-2 DONE rc=0" && [ ! -e "$B/batch-2.orphan" ]; }
  hres "a job that had already recorded rc 0 when the bound hit keeps it: DONE, no orphan mark (P3)" $?
  { lit_in "$(gout 1)" "batch-3 FAILED rc=timeout-orphan" && [ "$(cat "$B/batch-3.orphan" 2>/dev/null)" = timeout-orphan ]; }
  hres "a job that IGNORES TERM is still stopped by the KILL after GRACE, and marked timeout-orphan (item 3)" $?
  gone=1
  for n in 1 2 3; do
    pg="$(cat "$X/log/pgid-$n" 2>/dev/null)"; [ -n "$pg" ] || { gone=0; continue; }
    i=0
    while ps -A -o pgid= | awk -v g="$pg" '$1 == g { f = 1 } END { exit !f }' && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
    ! ps -A -o pgid= | awk -v g="$pg" '$1 == g { f = 1 } END { exit !f }' || gone=0
  done
  hres "no process of any killed job's process group is left, TERM-ignoring one included (polled by pgid, bounded) (T4)" $((1 - gone))
  # A complete report left at --out by a run that exited non-zero is never DONE: FAILED, quarantined.
  reset_log; mode 1 wrote3
  one_run 1 1
  { lit_in "$(gout 1)" "batch-1 FAILED rc=4" && [ ! -e "$B/batch-1.md" ] && [ -f "$B/batch-1.md.incomplete" ]; }
  hres "a batch whose model-run exited 4 is FAILED even with a complete report at --out, which is quarantined as .md.incomplete" $?
  # A late job that recorded model-run's OWN timeout (124) keeps it: FAILED rc=124, never timeout-orphan.
  reset_log; mode 1 late124
  OR_BOUND=2 OR_GRACE=2 OR_PAR=1 one_run 1 1
  { lit_in "$(gout 1)" "batch-1 FAILED rc=124" && [ ! -e "$B/batch-1.orphan" ]; }
  hres "a job that recorded rc 124 (model-run's own timeout) when the bound hit keeps it: FAILED rc=124, no orphan mark (P3)" $?

  # --- K6/S5/D15/T9: an invalid prompt never reaches model-run, and setup says why on stderr
  awk '/^OUTPUT LINE FORMAT/ { skip = 1 } skip && /^[ \t]*$/ { skip = 0 } !skip' "$PROMPT" > "$X/inc/shared/includes/test-audit-batch-prompt.md"
  reset_log; one_run 2 1
  { [ -f "$B/batch-1.prompt.invalid" ] && [ ! -e "$B/batch-1.prompt" ] && lit_in "$(cat "$X/log/setup.err")" "prompt-invalid: batch-1" \
      && [ -z "$(started)" ] && lit_in "$(gout 1)" "batch-1 FAILED rc=prompt-invalid" \
      && ! grep -q 'the two ASCII characters' "$X/inc/shared/includes/test-audit-batch-prompt.md"; }
  hres "without the WHOLE OUTPUT LINE FORMAT block: .prompt.invalid, 'prompt-invalid: batch-1' on stderr, model-run never runs (K6/T9)" $?
  # BEHAV-8: the invalid prompt cannot be set aside (mv refused): the invalid batch-1.prompt would stay
  # and a group call would run it. The setup must STOP by name instead.
  mkdir -p "$X/mvshim"
  printf '#!/bin/sh\nfor last in "$@"; do :; done\ncase "$last" in *.prompt.invalid) echo "mv-shim: refused $last" >&2; exit 1 ;; esac\nexec /bin/mv "$@"\n' > "$X/mvshim/mv"
  chmod +x "$X/mvshim/mv"
  rm -f "$B/.lock"; reset_log
  run_block "$SETUP_SH" 2 1 560 15 PATH="$X/mvshim:$PATH"; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: batch-1.prompt is invalid and could not be set aside"; }
  hres "an invalid prompt that cannot be moved aside STOPs the setup by name, never left for a group to run (BEHAV-8)" $?
  rm -f "$B/.lock"
  cp "$PROMPT" "$X/inc/shared/includes/test-audit-batch-prompt.md"

  # BEHAV-4: a `ps` that cannot see any process (a sandbox, hidepid) makes the owner's liveness
  # UNKNOWN. A lock whose owner might be alive is never reclaimed: the setup STOPs by name.
  mkdir -p "$X/psshim"
  printf '#!/bin/sh\nexit 1\n' > "$X/psshim/ps"; chmod +x "$X/psshim/ps"
  rm -f "$B/.lock"; ln -s "999999 1 unknown-tok" "$B/.lock"; reset_log
  run_block "$SETUP_SH" 2 1 560 15 PATH="$X/psshim:$PATH"; rc=$?
  { [ "$rc" = 3 ] && err_has "STOP: cannot tell whether the owner of" && [ "$(readlink "$B/.lock")" = "999999 1 unknown-tok" ] && ! err_has "reclaimed"; }
  hres "a ps that sees nothing: the lock's owner is undecidable, the setup STOPs and leaves the lock alone (BEHAV-4)" $?
  rm -f "$B/.lock"

  # BEHAV-3: a setup re-run inside the SAME run (its token, same process) after a group finished keeps
  # that group's DONE results; it rebuilds the prompts and drops results of batches past NBATCH.
  reset_log
  REENTER_AFTER="printf 'Tier: A\n' > '$B/batch-9.md'" one_run 2 1
  { [ "$(cat "$X/log/setup4.rc" 2>/dev/null)" = 0 ] && lit_in "$(gout 1)" "batch-1 DONE" && [ -f "$B/batch-1.md" ] \
      && [ "$(cat "$B/batch-1.rc" 2>/dev/null)" = 0 ] && [ -f "$B/batch-2.md" ] && [ -s "$B/batch-1.prompt" ] && [ ! -e "$B/batch-9.md" ]; }
  hres "a same-run setup re-run keeps the finished batch-1/2 results, rebuilds prompts, drops batch-9 past NBATCH (BEHAV-3)" $?

  # D1: a floor on the execution checks THIS leg performed (hres only runs here) = the actual count.
  if [ "$harness_checks" -ge "$HARNESS_FLOOR" ]; then pass "${TAGX}the execution harness ran all of its checks ($harness_checks)"; else bad "${TAGX}the execution harness ran all of its checks (only $harness_checks of $HARNESS_FLOOR)"; fi
  ta_cleanup
  # D10: no EXIT trap was replaced — clean the scratch tree here, and only a mktemp path.
  case "$X" in
    /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*)
      if [ -n "${TA_KEEP:-}" ]; then echo "kept: $X"; else rm -rf "$X"; fi ;;
    *) bad "refusing to remove an unexpected scratch path: $X" ;;
  esac
}

HARNESS_FLOOR=96
if [ -n "$SETUP_SH" ] && [ -n "$GROUP_SH" ]; then
  for sh_ in bash zsh; do
    if command -v "$sh_" >/dev/null 2>&1; then run_harness "$sh_"
    else echo "SKIP: $sh_ is not installed - the [$sh_] leg of the execution harness did not run"; fi
  done
  TAGX=""
else
  bad "the execution harness ran (D1: no setup/group block — nothing was executed)"
fi
echo "== part 2: 1b — the labelled in-family fallback =="

p1b=""
if p1b=$(extract_block "$SKILL" prefix '### 1b.' prefix '### 1c.'); then
  pass "Phase 1b (fallback) section located (ends at ### 1c.)"
else
  bad "Phase 1b (fallback) section located — $(eb_reason)"; p1b=""
fi
sp4=$(same_paragraph "$p1b" "reviewer-model-route.sh --fallback" "status=in-family-fallback (degraded)") || sp4=ERR
sp4b=$(same_paragraph "$p1b" "reviewer-model-route.sh --fallback" "never reported as cross-vendor or as \`status=ok\`") || sp4b=ERR
if [ "$sp4" = YES ] && [ "$sp4b" = YES ]; then
  pass "1b: --fallback picks the model, the batch is labelled in-family-fallback (degraded), never cross-vendor/status=ok (one paragraph)"
else
  bad "1b: --fallback picks the model, labelled in-family-fallback (degraded), never cross-vendor/status=ok ($sp4/$sp4b)"
fi
block_has "$p1b" 'status=in-family-fallback (degraded, writer unknown)` for `unknown-writer-model`' "1b: unknown-writer-model -> '(degraded, writer unknown)'"
block_has "$p1b" 'status=in-family-fallback (degraded, same model)` for `same-model-fallback`' "1b: same-model-fallback -> '(degraded, same model)'"
block_has "$p1b" '`<client>` is the harness that ran the in-harness agent' "1b defines <client> in its header line (Q10)"
block_has "$p1b" 'shell available' "1b (in-harness Agent) substitutes [VERIFICATION CONTEXT] with 'shell available'"
m1b=$(printf '%s\n' "$p1b" | awk '/^[ \t]*model:/ { print; n++ } END { exit n != 1 }') \
  && [ "$m1b" = '  model: <reviewer_model from reviewer-model-route.sh --fallback>' ] \
  && pass "1b's only model: line is the router-derived '<reviewer_model from reviewer-model-route.sh --fallback>' (Q3)" \
  || bad "1b's only model: line is the router-derived one — got: ${m1b:-<none or several>}"
mustnot "1b (fallback) sets no sonnet model on any model: key line" sonnet_on "$p1b"
sp7=$(same_paragraph "$p1b" "A fallback that fails too" "\`status=INCOMPLETE\` header line") || sp7=ERR
[ "$sp7" = YES ] && pass "1b: a failed fallback leaves the batch INCOMPLETE with a status=INCOMPLETE header line" \
                 || bad "1b: a failed fallback leaves the batch INCOMPLETE with a status=INCOMPLETE header line ($sp7)"

echo "== part 2: 1c — Cursor, Antigravity and Kimi keep the in-harness Agent dispatch (X7) =="

p1c=""
if p1c=$(extract_block "$SKILL" prefix '### 1c. Cursor, Antigravity and Kimi hosts' prefix '### 1d.'); then
  pass "Phase 1c section located (heading names Cursor, Antigravity and Kimi hosts; ends at ### 1d.)"
else
  bad "Phase 1c section located — $(eb_reason)"; p1c=""
fi
block_has "$p1c" 'Agent: Test Quality Auditor (per batch)' "1c keeps the in-harness 'Agent: Test Quality Auditor (per batch)' dispatch"
block_has "$p1c" 'batches of 8-10' "1c keeps batches of 8-10"
block_has "$p1c" 'shell available' "1c keeps substituting [VERIFICATION CONTEXT] with 'shell available'"
[ -n "$p1c" ] && block_lacks "$p1c" 'model-run' "1c never routes through model-run (the subprocess route is Claude/Codex only)"
# The Kimi and Antigravity builds rewrite "Claude Code" to their own host name in
# skill bodies; Phase 1 must not say it (found fix round 1).
[ -n "${phase1_block:-}" ] && block_lacks "$phase1_block" 'Claude Code' "Phase 1 never says 'Claude Code' (the Kimi/Antigravity builds rewrite it to their own host)"

echo "== part 2: header line (Phase 1 + Phase 2 template), model-run count, Execution Notes =="

block_has "${phase1_block:-}" 'Batch auditor: <client>/<model> route=<lane> status=<status> batch=<N>' "Phase 1 specifies the 'Batch auditor:' header line"
# T8/D14/D18: join backslash continuations (a line ending in an ODD run of
# backslashes; `\\` is an escaped backslash, not a continuation; a trailing
# continuation at EOF is flushed), then count every spelling of the command.
join_cont() {
  awk '{ sub(/\r$/, ""); l = $0; c = 0
         if (match(l, /\\+$/)) { c = RLENGTH % 2 }
         if (c) { buf = buf substr(l, 1, length(l) - 1); next }
         print buf l; buf = "" }
       END { if (buf != "") print buf }'
}
MR_ANY='((~|\$HOME|"\$HOME"|'"'"'\$HOME'"'"'|\$\{HOME\}|"\$\{HOME\}"|'"'"'\$\{HOME\}'"'"')/\.zuvo/|(^|[[:space:];&|({!]))model-run[[:space:]]+--'
count_inv() { printf '%s\n' "$1" | join_cont | { grep -Ec -e "$MR_ANY" || true; }; }
must "join_cont: a trailing continuation at EOF is flushed" [ "$(printf 'a \\\nb \\\n' | join_cont)" = "a b " ]
must "join_cont: an escaped \\\\ at end of line is not a continuation" [ "$(printf 'a \\\\\nb\n' | join_cont | awk 'END { print NR }')" = 2 ]
for v in '$HOME/.zuvo/model-run --x' '"${HOME}"/.zuvo/model-run --x' "'\$HOME'/.zuvo/model-run --x" '  model-run --route' "$(printf '~/.zuvo/model-run \\\n  --route')" "$(printf '~/.zuvo/model-run \\\r\n  --route')" '{ model-run --x; }'; do
  must "the invocation counter sees: $v" [ "$(count_inv "$v")" -eq 1 ]
done
must "the invocation counter ignores prose: \`model-run --out\` in backticks" [ "$(count_inv 'written by `model-run --out`')" -eq 0 ]
must "the invocation counter ignores a path mention without options" [ "$(count_inv 'through `~/.zuvo/model-run` (1a)')" -eq 0 ]
# The invocation lives in the script, once, and is the full pinned command through --out; SKILL.md
# Phase 1 runs model-run only through the script, so it carries NO invocation of its own in any
# spelling (a second, hand-typed one would drift from the script's).
inv_n=$(count_inv "${phase1_block:-}")
full_n=$(printf '%s\n' "$script_text" | join_cont | awk -v a="$MR_CMD" 'index($0, a) && index($0, "--require \"$TAB_REQUIRE\"") && index($0, "--out \"$b.md\"") { c++ } END { print c + 0 }')
if [ "${inv_n:-1}" -eq 0 ] && [ "$full_n" -eq 1 ]; then
  pass "Phase 1 carries no model-run invocation of its own, and the script's one is the full pinned command through --out (T8/D18)"
else
  bad "Phase 1 carries no model-run invocation of its own (found ${inv_n:-?}), and the script's one is the full command (found $full_n)"
fi
# D12: the Batch auditor line anywhere in the report template's HEADER block
# (the ```markdown fence of Phase 2, before its first "## " line).
p2hdr=$(printf '%s\n' "${phase2_block:-}" | awk '$0 == "```markdown" { o = 1; next } o && (index($0, "## ") == 1 || $0 == "```") { exit } o')
n_ba=$(printf '%s\n' "$p2hdr" | awk 'index($0, "Batch auditor: [") == 1 && index($0, "<client>/<model> route=<lane> status=<status> batch=<N>]") { c++ } END { print c + 0 }')
if [ -n "$p2hdr" ] && [ "$n_ba" -eq 1 ]; then
  pass "Phase 2's report template header carries exactly one Batch auditor: line (Q4/D12)"
else
  bad "Phase 2's report template header carries exactly one Batch auditor: line (found ${n_ba:-0}; header block ${p2hdr:+found}${p2hdr:-missing})"
fi

p2_step5=$(printf '%s\n' "${phase2_block:-}" | awk 'index($0, "5. Count INCOMPLETE files separately") == 1')
block_has "$p2_step5" 'every file whose tier line is `Tier: INCOMPLETE`' "Phase 2 step 5 counts a 'Tier: INCOMPLETE' file as INCOMPLETE (R2-2)"

notes=$(awk 'on && index($0, "## ") == 1 { exit } index($0, "## Execution Notes") == 1 { on = 1 } on { print }' "$SKILL")
if [ -z "$notes" ]; then
  bad "Execution Notes section located"
else
  pass "Execution Notes section located"
  notes_plain=$(printf '%s' "$notes" | tr -d '*_`')
  block_lacks "$notes_plain" 'Use Sonnet for batch agents' "Execution Notes no longer say 'Use Sonnet for batch agents' (bold, italic, code or plain) (D7)"
  block_has "$notes" 'model-run' "Execution Notes name the model-run route for batch auditors"
  # The ceiling is 5 group calls of BOUND + GRACE each — computed from the script's own constants, so
  # the note cannot go stale when either moves (R2-3).
  ceil_s=$((5 * (S_BOUND + S_GRACE))); ceil_min=$(( (ceil_s + 30) / 60 ))
  block_has "$notes" "5 groups × ($S_BOUND + $S_GRACE) s = $ceil_s s ≈ $ceil_min min" "Execution Notes give the model-run route's worst case from the script's BOUND and GRACE: 5 × ($S_BOUND + $S_GRACE) s = $ceil_s s ≈ $ceil_min min (Q7/R2-3)"
  block_lacks "$notes" '× 480 s' "Execution Notes no longer count one 480 s client budget per group (R2-3)"
fi

echo "== part 2: the prompt pins the machine-checked line format (live finding 2026-09-29) =="

fenced2=""
if fenced2=$(fenced_body "$PROMPT"); then pass "the include's fenced body located"; else bad "the include's fenced body located ($(eb_reason))"; fenced2=""; fi
block_has "$fenced2" 'OUTPUT LINE FORMAT' "prompt's fenced body carries the OUTPUT LINE FORMAT rule"
block_has "$fenced2" 'starts at column 0, in plain text' "prompt: every Tier/Red flags line starts at column 0, in plain text"
block_has "$fenced2" 'no markdown emphasis' "prompt: no markdown emphasis on those lines"
block_has "$fenced2" 'no bullet' "prompt: no bullet on those lines"
block_has "$fenced2" 'exactly `Tier: <A|B|C|D>`' "prompt: the tier line is exactly 'Tier: <A|B|C|D>'"
block_has "$fenced2" 'the two ASCII characters `->`' "prompt: the AUTO TIER-D arrow is ASCII '->'"
block_has "$fenced2" 'never a Unicode' "prompt: never a Unicode arrow"
block_has "$fenced2" 'is a PLACEHOLDER' "prompt: the FULL-format 'Tier: [A/B/C/D]' line is named a placeholder (P7)"
block_has "$fenced2" 'No non-ASCII punctuation anywhere in a `Tier:` or `Red flags:` line' "prompt: no non-ASCII punctuation in Tier/Red flags lines (P7)"
block_has "$fenced2" 'its tier line is exactly `Tier: INCOMPLETE`' "prompt: a file with Applicable == 0 writes exactly 'Tier: INCOMPLETE' (R2-2)"
block_lacks "$fenced2" 'tier=none' "prompt: 'no tier' has a machine encoding, never the unencodable 'tier=none' (R2-2)"
block_has "$fenced2" 'one pair of wrapping backticks and a leading `./`' "prompt: says how a heading is normalised before it is compared (ADV-134)"
block_has "$fenced2" 'heading that is a path NOT in the list ends the section above it' "prompt: an unlisted path heading ends the section above it (ADV-126)"
# T8: every rule above in ONE paragraph (the OUTPUT LINE FORMAT block), not scattered.
para_all=$(printf '%s\n' "$fenced2" | awk '{ sub(/\r$/, ""); if ($0 ~ /^[ \t]*$/) print ""; else print }' | NEEDLES="OUTPUT LINE FORMAT@@starts at column 0, in plain text@@no markdown emphasis@@no bullet@@exactly \`Tier: <A|B|C|D>\`@@is a PLACEHOLDER@@the two ASCII characters \`->\`@@never a Unicode@@No non-ASCII punctuation" awk -v RS='' '
  BEGIN { n = split(ENVIRON["NEEDLES"], N, "@@") }
  { ok = 1; for (i = 1; i <= n; i++) if (!index($0, N[i])) ok = 0; if (ok) f = 1 }
  END { print (f ? "YES" : "NO") }')
[ "$para_all" = YES ] && pass "prompt: every OUTPUT LINE FORMAT rule sits in ONE paragraph (T8)" || bad "prompt: every OUTPUT LINE FORMAT rule sits in ONE paragraph (T8)"
# T4/D13 anti-echo, line by line, with explicit counts: at least one prompt line
# matches --require (the template line), and EVERY such line also matches
# --reject. grep's "no match" (1) is captured, never fatal; >1 is an error.
g_rc=0; n_req=$(printf '%s\n' "$fenced2" | grep -Ec -e "$S_REQ") || g_rc=$?
b_rc=0; n_both=$(printf '%s\n' "$fenced2" | grep -E -e "$S_REQ" | grep -Ec -e "$S_REJ") || b_rc=$?
if [ "$g_rc" -gt 1 ] || [ "$b_rc" -gt 1 ]; then
  bad "anti-echo: grep error (require rc=$g_rc, reject rc=$b_rc)"
elif [ "${n_req:-0}" -ge 1 ] && [ "${n_both:-0}" -eq "${n_req:-0}" ]; then
  pass "anti-echo: all $n_req --require-matching prompt line(s) also match --reject"
else
  bad "anti-echo: ${n_req:-0} prompt line(s) match --require, only ${n_both:-0} of them match --reject (need >= 1 and all)"
fi

echo "== part 2: Phase 3b is byte-identical to the pre-plan commit (X8) =="

P3B_LINE='~/.zuvo/adversarial-review --mode tests --files "zuvo/audits/test-quality-audit-[date].md"'
X8_BASE=e6c2bedda3e576c2b7fbe6715df8d74ab3cbbf3a   # the commit before Plan C Task 8 touched skills/test-audit/SKILL.md
p3b_of() {  # every line (continuations joined) whose first non-blank text is the call — printed RAW, byte for byte (T7)
  join_cont | awk '{ t = $0; sub(/^[ \t]+/, "", t) } index(t, "~/.zuvo/adversarial-review --mode tests") == 1 { print }'
}
p3b_now=$(p3b_of < "$SKILL")
n_now=$(printf '%s' "$p3b_now" | awk 'END { print NR }')
if [ "$n_now" -eq 1 ] && [ "$p3b_now" = "$P3B_LINE" ]; then
  pass "Phase 3b: exactly one adversarial-review --mode tests line, and it is the pinned literal"
else
  bad "Phase 3b: exactly one adversarial-review --mode tests line, the pinned literal — $n_now found: ${p3b_now:-<none>}"
fi
if ! git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  bad "Phase 3b vs $X8_BASE: no git repository at $ROOT — cannot prove X8 (not skipped)"
elif ! git -C "$ROOT" cat-file -e "$X8_BASE:skills/test-audit/SKILL.md" 2>/dev/null; then
  bad "Phase 3b vs $X8_BASE: that object is not in this clone (shallow?) — cannot prove X8 (not skipped)"
else
  gs_rc=0; base_skill=$(git -C "$ROOT" show "$X8_BASE:skills/test-audit/SKILL.md" 2>&1) || gs_rc=$?
  if [ "$gs_rc" -ne 0 ]; then
    bad "Phase 3b vs $X8_BASE: git show failed (rc=$gs_rc): $base_skill"
  else
    p3b_base=$(printf '%s\n' "$base_skill" | p3b_of)
    n_base=$(printf '%s' "$p3b_base" | awk 'END { print NR }')
    if [ "$n_base" -eq 1 ] && [ "$p3b_now" = "$p3b_base" ]; then
      pass "Phase 3b adversarial-review line is byte-identical to $X8_BASE's, which has exactly one (X8)"
    else
      bad "Phase 3b adversarial-review line is byte-identical to $X8_BASE's (X8) — base has $n_base: ${p3b_base:-<none>}"
    fi
  fi
fi

# ── The setup call's exit-3 list in SKILL.md names EVERY reason the setup can STOP for: each tab_stop of
# tab_take_lock and cmd_setup is paired with the phrase the list uses for it, and a tab_stop with no pair
# (a new reason nobody documented) turns this red by the count.
echo "== the setup call's documented exit-3 reasons =="
# setup_stops_of <script> — the tab_stop lines of tab_take_lock and cmd_setup. A function ends at a `}` at
# column 0, alone or followed by a `;` and/or a comment (a column-0 `} &` or `} >file` closing a nested
# group does not end it); status 1 unless both functions are found and closed.
setup_stops_of() {
  awk '/^(tab_take_lock|cmd_setup)\(\) *\{/ { f = 1; n++; next }
    f && /^}[[:space:]]*(;[[:space:]]*)?(#.*)?$/ { f = 0; closed++; next }
    f && /tab_stop "/
    END { exit !(n == 2 && closed == 2) }' "$1"
}
setup_stops="$(setup_stops_of "$SCRIPT")" || bad "tab_take_lock() and cmd_setup() were not both found, each closed by a column-0 \`}\`"
# The extractor itself, on a copy with a nested group closed by a column-0 `} &` before one more reason:
# that reason is still counted (an early stop there would let an undocumented reason pass by the count).
stops_copy="$(mktemp "${TMPDIR:-/tmp}/tab-stops.XXXXXX")" || stops_copy=""
if [ -n "$stops_copy" ]; then
  awk '{ print } /^tab_take_lock\(\) *\{/ { print "{ sleep 0"; print "} &"; print "  tab_stop \"a planted reason\"" }' "$SCRIPT" > "$stops_copy"
  n_real="$(printf '%s\n' "$setup_stops" | awk 'NF { n++ } END { print n + 0 }')"
  n_copy="$(setup_stops_of "$stops_copy" | awk 'NF { n++ } END { print n + 0 }')"
  if [ "$n_copy" -eq $((n_real + 1)) ]; then pass "the STOP-reason extractor reads past a nested group's column-0 \`} &\` ($n_copy = $n_real + 1)"
  else bad "the STOP-reason extractor stopped at a nested group's column-0 \`} &\` ($n_copy, want $((n_real + 1)))"; fi
  # …and a function closed by a column-0 `} # comment` still ends there (the reason after it is not its own).
  awk '/^tab_take_lock\(\) *\{/ { t = 1 }
    t && /^}[[:space:]]*$/ { print "} # end of tab_take_lock"; print "outside() {"; print "  tab_stop \"not a setup reason\""; print "}"; t = 0; next }
    { print }' "$SCRIPT" > "$stops_copy"
  n_cmt="$(setup_stops_of "$stops_copy" | awk 'NF { n++ } END { print n + 0 }')"
  if [ "$n_cmt" -eq "$n_real" ]; then pass "the STOP-reason extractor ends a function at a column-0 \`} # comment\` ($n_cmt = $n_real)"
  else bad "the STOP-reason extractor ran past a column-0 \`} # comment\` ($n_cmt, want $n_real)"; fi
  rm -f "$stops_copy"
fi
exit3_doc="$(awk '/^- exit `3` — `STOP:` on stderr with the reason/ { f = 1 } f { print } f && /^- exit `1`/ { exit }' "$SKILL" | tr '\n' ' ' | tr -s ' ')"
[ -n "$exit3_doc" ] || bad "SKILL.md: the setup call's exit-3 bullet was not found"
n_pairs=0
while IFS='|' read -r stop_msg doc_phrase; do
  [ -n "$stop_msg" ] || continue
  n_pairs=$((n_pairs + 1))
  if ! printf '%s\n' "$setup_stops" | grep -qF -- "$stop_msg"; then bad "setup STOP reason [$stop_msg] is no longer in tab_take_lock/cmd_setup — update this pairing"
  elif case "$exit3_doc" in *"$doc_phrase"*) true ;; *) false ;; esac; then pass "setup STOP [$stop_msg] is named in SKILL.md's exit-3 list ($doc_phrase)"
  else bad "setup STOP [$stop_msg] is not named in SKILL.md's exit-3 list (want: $doc_phrase)"; fi
done <<'PAIRS'
ps shows no process here|an undecidable owner
an earlier test-audit run of THIS session|a lock an earlier run of this session left
another test-audit run (pid|a live foreign lock
(contended)|a contended lock
is not an install root|not an install root
is not a positive whole number|a bad `NBATCH`
is not a lock link|a `.lock` that is not a lock link (an older layout)
could not be set aside|a prompt that could not be set aside
PAIRS
n_stops="$(printf '%s\n' "$setup_stops" | awk 'NF { n++ } END { print n + 0 }')"
if [ "$n_stops" -eq "$n_pairs" ]; then pass "every one of the setup's $n_stops STOP reasons is paired with the exit-3 list"
else bad "the setup has $n_stops STOP reasons but $n_pairs are paired with the exit-3 list — document the new one"; fi

# ── One verdict pattern: TAB_VERDICT_RE is both model-run's --require (TAB_REQUIRE) and what the DONE
# gate (tab_gate) looks for per file. Proven on a COPY of the script whose TAB_VERDICT_RE line is changed:
# both consumers must follow it — a second hand-written copy of the pattern would not.
echo "== one verdict pattern for --require and the DONE gate =="
vcopy="$(mktemp "${TMPDIR:-/tmp}/tab-verdict.XXXXXX")" && vfiles="$(mktemp "${TMPDIR:-/tmp}/tab-vfiles.XXXXXX")" \
  && vrep="$(mktemp "${TMPDIR:-/tmp}/tab-vrep.XXXXXX")" || { bad "mktemp for the verdict-pattern case"; vcopy=""; }
if [ -n "$vcopy" ]; then
  # Any assignment counts — indented, or behind export / readonly / declare / local — so a second one in
  # another spelling cannot hide from the once-check, and the copy below rewrites exactly the one counted.
  vdef_re='^[[:space:]]*((export|readonly|declare|local|typeset)([[:space:]]+-[[:alpha:]]+)*[[:space:]]+)?TAB_VERDICT_RE='
  n_vdef() { awk -v re="$vdef_re" '$0 ~ re { n++ } END { print n + 0 }' "$1"; }
  n_def="$(n_vdef "$SCRIPT")"
  if [ "$n_def" -eq 1 ]; then pass "TAB_VERDICT_RE is defined once"; else bad "TAB_VERDICT_RE is defined $n_def times (want 1)"; fi
  printf '%s\n' "TAB_VERDICT_RE='^a'" "  export TAB_VERDICT_RE='^b'" "readonly TAB_VERDICT_RE" "# TAB_VERDICT_RE='^c'" > "$vcopy"
  if [ "$(n_vdef "$vcopy")" -eq 2 ]; then pass "the once-check counts an indented, exported second assignment too"
  else bad "the once-check misses an indented or exported TAB_VERDICT_RE assignment (counted $(n_vdef "$vcopy"), want 2)"; fi
  awk -v re="$vdef_re" '$0 ~ re { print "TAB_VERDICT_RE='"'"'^VERDICT-X$'"'"'"; next } { print }' "$SCRIPT" > "$vcopy"
  printf '%s\t%s\n' src/a.test.ts src/a.ts > "$vfiles"
  v_req="$("${BASH:-bash}" -c '. "$1" || exit 9; printf "%s" "$TAB_REQUIRE"' _ "$vcopy" 2>/dev/null)"
  if [ "$v_req" = '^VERDICT-X$' ]; then pass "a changed TAB_VERDICT_RE reaches model-run's --require (TAB_REQUIRE)"; else bad "a changed TAB_VERDICT_RE does not reach TAB_REQUIRE (got [$v_req])"; fi
  printf '### src/a.test.ts\nVERDICT-X\n' > "$vrep"
  g1=0; "${BASH:-bash}" -c '. "$1" || exit 9; tab_gate "$2" "$3"' _ "$vcopy" "$vfiles" "$vrep" >/dev/null 2>&1 || g1=$?
  printf '### src/a.test.ts\nTier: A\n' > "$vrep"
  g2=0; "${BASH:-bash}" -c '. "$1" || exit 9; tab_gate "$2" "$3"' _ "$vcopy" "$vfiles" "$vrep" >/dev/null 2>&1 || g2=$?
  if [ "$g1" -eq 0 ] && [ "$g2" -eq 1 ]; then pass "a changed TAB_VERDICT_RE is what the DONE gate looks for (its line passes, a Tier line no longer does)"
  else bad "the DONE gate does not follow TAB_VERDICT_RE (new-pattern report: $g1, want 0; Tier-line report: $g2, want 1)"; fi
  rm -f "$vcopy" "$vfiles" "$vrep"
fi

echo "  ---- $npass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
