#!/usr/bin/env bash
# test-test-audit-subprocess-dispatch.sh — the test-audit batch auditor prompt
# lives in one shared include any client can be handed, and SKILL.md points at
# it instead of embedding the ~13.5 KB template inline.
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
# hosts") is NOT covered here; it lands in this same file in a later task.
#
# bash 3.2-compatible (macOS default /bin/bash) AND bash 5 (Homebrew):
# verified under both. No mapfile, no associative arrays, no python3
# dependency (same_paragraph() is pure awk, paragraph mode).
set -uo pipefail
case "$-" in *e*) printf 'FAIL: this script must not run under set -e (rc=$? capture pattern assumes it does not)\n'; exit 1 ;; esac

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/test-audit/SKILL.md"
PROMPT="$ROOT/shared/includes/test-audit-batch-prompt.md"

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
trap 'rm -f "$EB_REASON_FILE"' EXIT
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
extract_block() {
  eb_file="$1"; eb_smode="$2"; eb_slit="$3"; eb_emode="$4"; eb_elit="$5"
  if [ ! -r "$eb_file" ]; then
    printf '%s' "file unreadable: $eb_file" > "$EB_REASON_FILE"
    return 1
  fi
  eb_err="$(mktemp 2>/dev/null)" || { printf '%s' "mktemp failed" > "$EB_REASON_FILE"; return 1; }
  eb_rc=0
  eb_out="$(awk -v smode="$eb_smode" -v slit="$eb_slit" -v emode="$eb_emode" -v elit="$eb_elit" '
    function trimmed(s) { sub(/[ \t]+$/, "", s); return s }
    function matches(mode, lit, line) {
      if (mode == "exact")  { return (trimmed(line) == lit) }
      if (mode == "prefix") { return (index(line, lit) == 1) }
      return 0
    }
    !inside {
      if (matches(smode, slit, $0)) { inside = 1; buf[++n] = $0 }
      next
    }
    inside && !found {
      if (matches(emode, elit, $0)) { found = 1; next }
      buf[++n] = $0
      next
    }
    END {
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
  fb_out="$(awk '
    !heading {
      if (index($0, "### Agent Prompt") == 1) { heading = 1 }
      next
    }
    heading && !open {
      if ($0 ~ /^[ \t]*$/) { next }
      line = $0
      sub(/^ {0,3}/, "", line)
      if (match(line, /^`{3,}/)) {
        fence_len = RLENGTH
        open = 1
        next
      }
      no_open = 1
      exit 22
    }
    open && !closed {
      line = $0
      sub(/\r$/, "", line)
      sub(/[ \t]+$/, "", line)
      sub(/^ {0,3}/, "", line)
      if (line ~ /^`+$/ && length(line) >= fence_len) { closed = 1; next }
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
    23) fb_reason="opening fence found, but no closing fence with the same backtick count before EOF in $fb_file" ;;
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
if qregion=$(extract_block "$PROMPT" exact '<!-- GATES:BEGIN kind=q-prompt -->' exact '<!-- GATES:END kind=q-prompt -->'); then
  case "$qregion" in
    *"Q1:"*"Q25:"*)
      pass "q-prompt region is non-empty: carries both Q1: and Q25:" ;;
    *)
      bad "q-prompt region is non-empty: carries both Q1: and Q25:" ;;
  esac
else
  bad "q-prompt region is non-empty: carries both Q1: and Q25: ($(eb_reason))"
fi

if apregion=$(extract_block "$PROMPT" exact '<!-- GATES:BEGIN kind=ap-list -->' exact '<!-- GATES:END kind=ap-list -->'); then
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
if loading_block=$(extract_block "$SKILL" exact 'CORE FILES LOADED:' exact '```'); then
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

echo "  ---- $npass passed, $fail failed"
[ "$fail" -eq 0 ] && exit 0 || exit 1
