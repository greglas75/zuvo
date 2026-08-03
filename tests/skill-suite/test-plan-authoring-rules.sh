#!/usr/bin/env bash
# test-plan-authoring-rules.sh — Task 6: Declared failure strategy, plan side.
#
# RED-first: authored BEFORE Task 6's edits land in skills/plan/SKILL.md.
# Assertion (a) fails TODAY because the Task Authoring Rules list has TWO
# rules numbered "17." (the scope-split rule at the top of the section and a
# trailing literal-string-dispositions rule) — that duplicate is the intended
# RED evidence. Once Task 6 renumbers the trailing rule to 19 and appends the
# two new Failure-strategy rules as 20/21, (a) goes green along with (b)-(d).
#
# Four assertions, all plan-side only (no linter/execute-side parity — that
# is a LATER task's job, see the note on (d) below):
#
#   (a) STRUCTURAL — the "### Task Authoring Rules" list is a strict 1..N
#       sequence with no repeated or skipped numbers. The scan is BOUNDED
#       between the "### Task Authoring Rules" heading and the next "^### "
#       heading. skills/plan/SKILL.md has other numbered lists elsewhere
#       (Step 1 path resolution, plan-existence check, artifact-adoption
#       rules, the Review Loop, the Reviewed-status checklist) that live
#       OUTSIDE this section — a file-wide `^[0-9]+\.` scan would see those
#       as "repeats" too and the task could never go green even after a
#       correct renumber.
#   (b) TEMPLATE — the Task 1 template in "## Plan Document Structure"
#       carries a `**Failure:**` line as ITS OWN independent line, directly
#       after `**Dependencies:**` — never appended onto the Dependencies
#       line after a `·` bullet or any other separator. This matters because
#       verify-plan-dag's Dependencies parser truncates at `(`/`>` and
#       hard-exits 2 on a non-numeric token; a `degraded:<description>`
#       squeezed onto that line (especially one containing a comma) would be
#       tokenized as a bogus dependency and crash the linter.
#   (c) GATE — the Completion Gate Check block contains the reworded,
#       mechanically-checkable Failure-strategy item ("declares a valid
#       value, or omits the line entirely") and NOT the old self-contradictory
#       wording ("declares a Failure strategy (or `halt` by omission)").
#   (d) ENUM — the new Task Authoring Rule that defines the field names
#       EXACTLY the three enum tokens (`halt`, `skip-and-continue`,
#       `degraded`) and no fourth. This is checked against the task
#       TEMPLATE line itself (the canonical enum spelling), not against
#       scripts/zuvo-home/verify-plan-dag: that script has ZERO occurrences
#       of any of these three tokens today (verified below, informationally)
#       because teaching the linter about the field is Task 7's job. Asserting
#       parity here would compare against a file that does not yet exist in
#       that shape and would invert the T7-depends-on-T6 edge.
#
# ── Task 9 additions: the EXECUTE side of the same field ──────────────────────
#
# Five further assertions, labelled (T9-a)..(T9-e) so they can never be confused
# with the plan-side (a)..(d) above. These are the runtime half of rule 20 —
# every one of them spans a file the plan-side assertions never touch, and three
# of them are CROSS-FILE on purpose (a one-sided edit must fail):
#
#   (T9-a) ANTI-REGRESSION — skills/execute/SKILL.md still carries the literal
#          sentence `Never silently skip or auto-resolve a BLOCKED task.`
#          byte-for-byte. The whole carve-out exists to narrow that rule without
#          deleting it; if a future edit "simplifies" the sentence away, the
#          carve-out has silently become a licence to skip.
#   (T9-b) CLOSED TABLE — the carve-out table between the literal anchors
#          `<!-- zuvo:blocked-carveout-start -->` / `<!-- zuvo:blocked-carveout-end -->`
#          has EXACTLY 4 `|`-rows (header + separator + 2 data rows). The anchor
#          pair is validated by anchor_ok() first — EXACTLY ONE of each, start
#          before end — because a missing END anchor makes awk's range operator
#          run to EOF and a duplicated anchor silently changes which rows the
#          count covers.
#   (T9-c) REASON CODE, CROSS-FILE — `skipped-plan-declared` appears in BOTH
#          shared/includes/session-state.md (the reason-code SSOT) and
#          skills/execute/SKILL.md (the site that emits it).
#   (T9-d) TELEMETRY, TWO SITES IN ONE FILE — `failure-strategy` appears in the
#          prose `## Required Telemetry` field list AND, quoted, in the python
#          key list inside the `# >>> zuvo:task-telemetry` fence. Both scans are
#          section-bounded: a file-wide grep would let either site alone
#          false-green the other. The fence goes through the SAME anchor_ok()
#          precondition as (T9-b) — its awk walk stops only on the CLOSING
#          anchor, so without that anchor the "fence" is really everything to
#          EOF and any `"failure-strategy"` in the file would satisfy it.
#   (T9-e) degraded: IS NOT A BLOCK, CROSS-FILE — the statement is READ OUT of
#          shared/includes/no-pause-protocol.md (never hardcoded here) and must
#          appear byte-identically in skills/execute/SKILL.md. Both sides are
#          delimited by the dedicated anchor pair
#          `<!-- zuvo:degraded-not-blocked-start -->` / `…-end -->` rather than
#          by a first-match grep: several other paragraphs in these files talk
#          about `BLOCKED_*` states, and a substring grep would happily lock
#          onto one of those decoys instead. So: delete it from either file, or
#          reword it in only one, and this fails. It matters because
#          no-pause-protocol.md lists `BLOCKED_*` as a legitimate stop, and a
#          literal-minded agent reads "reduced outcome" as a gate failure.
#
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$ROOT/skills/plan/SKILL.md"
EXEC_FILE="$ROOT/skills/execute/SKILL.md"
SS_FILE="$ROOT/shared/includes/session-state.md"
NPP_FILE="$ROOT/shared/includes/no-pause-protocol.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ── shared anchor precondition for EVERY awk-range extraction below ──────────
# awk's `/start/,/end/` range operator is silently forgiving in exactly the ways
# that produce a false GREEN: a MISSING end anchor runs the range to EOF, a
# DUPLICATED start anchor re-opens the range after it closed, and an end anchor
# placed BEFORE its start yields either nothing or the whole rest of the file.
# Any of those changes what the extracted block actually is, so the row/key
# counts measured inside it stop meaning what the assertion claims. Every
# extraction below must call this FIRST and only proceed on rc 0. Counting is by
# OCCURRENCE (grep -oF), not by matching line, so two anchors sharing one line
# are still caught.
anchor_ok() {
  _lbl="$1"; _f="$2"; _s="$3"; _e="$4"
  if [ ! -f "$_f" ]; then
    bad "($_lbl) anchor precondition: file not found: $_f"
    return 1
  fi
  _sn="$(grep -oF -- "$_s" "$_f" 2>/dev/null | grep -c . || true)"
  _en="$(grep -oF -- "$_e" "$_f" 2>/dev/null | grep -c . || true)"
  _sn="${_sn:-0}"; _en="${_en:-0}"
  if [ "$_sn" -ne 1 ] || [ "$_en" -ne 1 ]; then
    bad "($_lbl) anchors must occur EXACTLY ONCE each in $(basename "$_f") — found start=$_sn [$_s], end=$_en [$_e]; 0 makes the awk range run to EOF, >1 silently re-opens it"
    return 1
  fi
  _sl="$(grep -nF -- "$_s" "$_f" | head -1 | cut -d: -f1)"
  _el="$(grep -nF -- "$_e" "$_f" | head -1 | cut -d: -f1)"
  if [ "$_sl" -ge "$_el" ]; then
    bad "($_lbl) start anchor (line $_sl) does not precede end anchor (line $_el) in $(basename "$_f") — the range is inverted, so the extracted block is not the intended one"
    return 1
  fi
  pass "($_lbl) anchor pair well-formed in $(basename "$_f"): exactly one of each, start line $_sl < end line $_el"
  return 0
}

if [ ! -f "$FILE" ]; then
  bad "skills/plan/SKILL.md not found at $FILE"
  echo "SOME FAILED"
  exit 1
fi

# ── (a) Task Authoring Rules: strict 1..N, no repeats, section-bounded ───────
# Bound the scan between the section heading and the NEXT top-level "### "
# heading — a file-wide scan would false-positive on the unrelated numbered
# lists elsewhere in this file (see header comment).
SECTION="$(awk '
  /^### Task Authoring Rules/ { f=1; next }
  f && /^### /                { exit }
  f                           { print }
' "$FILE")"

if [ -z "$SECTION" ]; then
  bad "(a) could not locate '### Task Authoring Rules' section (or it is empty) — rest of (a)/(d) would be vacuous"
else
  # Only lines that OPEN a rule (start at column 0 with "N. ") count as list
  # items — indented continuation lines of a multi-line rule must not.
  NUMS="$(printf '%s\n' "$SECTION" | grep -oE '^[0-9]+\.' | sed 's/\.$//')"
  COUNT="$(printf '%s\n' "$NUMS" | grep -c . || true)"
  EXPECTED="$(seq 1 "$COUNT" 2>/dev/null)"

  # Compare the extracted list DIRECTLY against seq 1..COUNT with NO sorting
  # on either side — a sorted comparison would still pass a section numbered
  # 1..N but written out of ORDER (e.g. rules 5 and 6 swapped), even though
  # this assertion is named "strict 1..N". Order is part of what "strict"
  # means here, so it must be part of what gets checked.
  if [ "$COUNT" -gt 0 ] && [ "$NUMS" = "$EXPECTED" ]; then
    pass "(a) Task Authoring Rules is a strict 1..$COUNT sequence, no repeats, gaps, or reorders"
  else
    bad "(a) Task Authoring Rules is NOT a strict 1..N sequence in order — got: [$(printf '%s' "$NUMS" | tr '\n' ' ')]"
  fi
fi

# ── (b) task template: **Failure:** on its own line, right after Dependencies ─
TEMPLATE="$(awk '
  /^### Task 1: / { f=1 }
  f               { print }
  f && /^### Task 2:/ { exit }
' "$FILE")"

if [ -z "$TEMPLATE" ]; then
  bad "(b) could not locate the '### Task 1:' template block — rest of (b)/(d) would be vacuous"
else
  DEP_LINE="$(printf '%s\n' "$TEMPLATE" | grep -m1 '^\*\*Dependencies:\*\*')"
  FAIL_LINE="$(printf '%s\n' "$TEMPLATE" | grep -m1 '^\*\*Failure:\*\*')"

  if [ -n "$FAIL_LINE" ]; then
    pass "(b) template has a standalone '**Failure:**' line: [$FAIL_LINE]"
  else
    bad "(b) template has no standalone '**Failure:**' line"
  fi

  # Never appended after a bullet (or anything else) on the Dependencies line.
  # Two precise assertions, not one loose substring check: (1) the line must
  # not contain the literal '**Failure:**' field marker (checking for the bare
  # word "Failure" would both false-positive on unrelated prose and not
  # actually prove the marker itself is absent), and (2) the line must not
  # carry a `·`-appended continuation at all — that inline-bullet syntax is
  # exactly how a second field gets squeezed onto this line elsewhere in the
  # template (`**Surface:** ui · **Dependencies:** Task 1 · **Execution
  # routing:** deep`). Together these actually enforce "own line" instead of
  # approximating it with a single substring test.
  case "$DEP_LINE" in
    *'**Failure:**'*)
      bad "(b) Dependencies line contains an inline '**Failure:**' marker (not on its own line): [$DEP_LINE]" ;;
    *'·'*)
      bad "(b) Dependencies line has a ·-appended continuation: [$DEP_LINE]" ;;
    *)
      pass "(b) Dependencies line stays clean (no inline '**Failure:**' marker, no · bullet-appended continuation)" ;;
  esac

  # The Failure line must immediately follow the Dependencies line (only
  # blank/comment continuation lines of the SAME field are tolerated between
  # them, but not another field). This locks in "immediately after
  # Dependencies" from the task spec rather than just "somewhere in the file".
  DEP_LINENO="$(printf '%s\n' "$TEMPLATE" | grep -n -m1 '^\*\*Dependencies:\*\*' | cut -d: -f1)"
  FAIL_LINENO="$(printf '%s\n' "$TEMPLATE" | grep -n -m1 '^\*\*Failure:\*\*' | cut -d: -f1)"
  if [ -n "$DEP_LINENO" ] && [ -n "$FAIL_LINENO" ] && [ "$FAIL_LINENO" -eq $((DEP_LINENO + 1)) ]; then
    pass "(b) '**Failure:**' line immediately follows '**Dependencies:**'"
  else
    bad "(b) '**Failure:**' (line $FAIL_LINENO) does not immediately follow '**Dependencies:**' (line $DEP_LINENO)"
  fi
fi

# ── (c) Completion Gate Check contains the new literal item ──────────────────
GATE="$(awk '
  /^## Completion Gate Check/ { f=1 }
  f { print }
  f && /^```$/ && seen { exit }
  f && /^```$/ { seen=1 }
' "$FILE")"

if printf '%s\n' "$GATE" | grep -qF 'declares a valid `**Failure:**` value, or omits the line entirely'; then
  pass "(c) Completion Gate Check contains the reworded, checkable Failure-strategy item"
else
  bad "(c) Completion Gate Check is missing the reworded Failure-strategy checklist item"
fi

# The old wording pulled "declares" and "by omission" in opposite directions
# (self-contradictory, not mechanically checkable). Guard against a
# regression back to that phrasing.
if printf '%s\n' "$GATE" | grep -qF 'every task declares a Failure strategy (or `halt` by omission)'; then
  bad "(c) Completion Gate Check regressed to the old self-contradictory wording"
else
  pass "(c) Completion Gate Check does not contain the old contradictory wording"
fi

# ── (d) enum: exactly halt | skip-and-continue | degraded, no fourth ─────────
# Checked against the canonical template line — the field's authoritative
# spelling — not against verify-plan-dag (see header comment: that linter has
# zero occurrences of these tokens until Task 7).
if [ -n "${FAIL_LINE:-}" ]; then
  TOKEN_PART="${FAIL_LINE#*\*\*Failure:\*\* }"
  # Split on the literal " | " separator into alternatives.
  ALT_COUNT=0
  HAS_HALT=0; HAS_SKIP=0; HAS_DEGRADED=0; HAS_EXTRA=0
  OLDIFS="$IFS"
  IFS='|'
  # shellcheck disable=SC2086
  set -- $TOKEN_PART
  IFS="$OLDIFS"
  for alt in "$@"; do
    alt_trimmed="$(printf '%s' "$alt" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    [ -z "$alt_trimmed" ] && continue
    ALT_COUNT=$((ALT_COUNT + 1))
    case "$alt_trimmed" in
      halt) HAS_HALT=1 ;;
      skip-and-continue) HAS_SKIP=1 ;;
      degraded:*) HAS_DEGRADED=1 ;;
      *) HAS_EXTRA=1 ;;
    esac
  done

  if [ "$ALT_COUNT" -eq 3 ] && [ "$HAS_HALT" -eq 1 ] && [ "$HAS_SKIP" -eq 1 ] \
     && [ "$HAS_DEGRADED" -eq 1 ] && [ "$HAS_EXTRA" -eq 0 ]; then
    pass "(d) Failure enum is exactly halt | skip-and-continue | degraded:<...> (3 alternatives, no fourth)"
  else
    bad "(d) Failure enum is not exactly the 3 expected tokens — parsed [$TOKEN_PART] into $ALT_COUNT alternative(s)"
  fi
else
  bad "(d) no '**Failure:**' template line to check the enum against (see (b))"
fi

# ── (d2) the THIRD side of the enum: execute's own restatement ────────────────
# The failure-strategy enum is stated in three independent places: rule 20 in
# plan/SKILL.md (asserted by (d) above), the `# >>> failure-enum` fence in
# verify-plan-dag (diffed against rule 20 by test-plan-dag-failure-strategy.sh
# case (h)), and the telemetry-field list in execute/SKILL.md — which was pinned
# by NOTHING. Two of three sides were checked, so execute could rename or add a
# token and both existing suites stayed green; the drift would surface only when
# a human happened to cross-read the prose. This closes the triangle.
EXEC_SK="$ROOT/skills/execute/SKILL.md"
if [ ! -f "$EXEC_SK" ]; then
  bad "(d2) skills/execute/SKILL.md not found — cannot pin the third side of the enum"
else
  EXEC_FS_LINE="$(grep -n '^- `failure-strategy`:' "$EXEC_SK" | head -1)"
  if [ -z "$EXEC_FS_LINE" ]; then
    # Re-point this assertion at the new location; do NOT delete it. A missing
    # anchor means the restatement moved, not that the contract stopped existing.
    bad "(d2) no '- \`failure-strategy\`:' line in execute/SKILL.md — the enum restatement moved or was renamed; re-point this assertion"
  else
    EXEC_FS_TEXT="${EXEC_FS_LINE#*:}"        # drop the grep line-number prefix
    EXEC_ENUM="${EXEC_FS_TEXT%%—*}"          # keep the enum, drop the trailing prose
    EXEC_TOKENS="$(printf '%s\n' "$EXEC_ENUM" \
      | grep -o '`[^`]*`' | tr -d '`' \
      | sed -e 's/<[^>]*>//' -e 's/[[:space:]]*$//' \
      | grep -v '^failure-strategy$' | sort -u | tr '\n' ' ')"
    if [ "$EXEC_TOKENS" = "degraded: halt skip-and-continue " ]; then
      pass "(d2) execute/SKILL.md restates the SAME three tokens as rule 20 (halt | skip-and-continue | degraded:)"
    else
      bad "(d2) execute/SKILL.md enum drifted from rule 20 — parsed [$EXEC_TOKENS], expected [degraded: halt skip-and-continue ]"
    fi
  fi
fi

# ── informational only: confirm scope boundary with Task 7, never asserted ───
# Not a pass/fail check — a note in the RED evidence trail. Task 7 teaches
# verify-plan-dag about these tokens; until then it must have none, or the
# T7-depends-on-T6 edge in the plan is backwards.
DAG_SCRIPT="$ROOT/scripts/zuvo-home/verify-plan-dag"
if [ -f "$DAG_SCRIPT" ]; then
  DAG_HITS="$(grep -cE 'halt|skip-and-continue|degraded' "$DAG_SCRIPT" 2>/dev/null || true)"
  printf 'INFO: verify-plan-dag currently has %s occurrence(s) of the enum tokens (Task 7 scope, not asserted here)\n' "${DAG_HITS:-0}"
fi

# ══ Task 9: execute-side assertions (T9-a)..(T9-e) ═══════════════════════════
echo "---- execute side (Task 9) ----"

for f in "$EXEC_FILE" "$SS_FILE" "$NPP_FILE"; do
  [ -f "$f" ] || bad "(T9) required file not found: $f"
done

# ── (T9-a) the verbatim never-silently-skip clause survives ──────────────────
NEVER_CLAUSE='Never silently skip or auto-resolve a BLOCKED task.'
if [ -f "$EXEC_FILE" ] && grep -Fq "$NEVER_CLAUSE" "$EXEC_FILE"; then
  pass "(T9-a) skills/execute/SKILL.md still carries the verbatim clause: [$NEVER_CLAUSE]"
else
  bad "(T9-a) skills/execute/SKILL.md is MISSING the verbatim clause [$NEVER_CLAUSE] — the carve-out narrows this rule, it must never delete it"
fi

# ── (T9-b) carve-out table: exactly 4 |-rows between its literal anchors ─────
CO_START='<!-- zuvo:blocked-carveout-start -->'
CO_END='<!-- zuvo:blocked-carveout-end -->'
co_anchors=0
anchor_ok "T9-b" "$EXEC_FILE" "$CO_START" "$CO_END" && co_anchors=1
if [ "$co_anchors" -eq 1 ]; then
  # Range is safe now that BOTH anchors are known present exactly once and in
  # order (a missing end anchor would otherwise run to EOF, and a duplicated
  # anchor would change which rows the count covers — either way the row count
  # would misreport as a table-shape failure, or worse, false-green).
  CO_ROWS="$(awk '/<!-- zuvo:blocked-carveout-start -->/,/<!-- zuvo:blocked-carveout-end -->/' "$EXEC_FILE" | grep -c '^ *|')"
  if [ "${CO_ROWS:-0}" -eq 4 ]; then
    pass "(T9-b) carve-out table is closed: exactly 4 |-rows (header + separator + 2 data rows)"
  else
    bad "(T9-b) carve-out table has ${CO_ROWS:-0} |-row(s) between the anchors, expected exactly 4 (header + separator + 2 data rows)"
  fi
fi

# ── (T9-c) reason code present in BOTH the SSOT and the emitting skill ───────
REASON_CODE='skipped-plan-declared'
for pair in "session-state.md:$SS_FILE" "execute/SKILL.md:$EXEC_FILE"; do
  label="${pair%%:*}"; target="${pair#*:}"
  if [ -f "$target" ] && grep -Fq "$REASON_CODE" "$target"; then
    pass "(T9-c) reason code \`$REASON_CODE\` present in $label"
  else
    bad "(T9-c) reason code \`$REASON_CODE\` MISSING from $label — it must exist in the SSOT and at the site that emits it"
  fi
done

# ── (T9-d) failure-strategy in the telemetry field list AND the fence key list ─
if [ -f "$EXEC_FILE" ]; then
  TELEM_SECTION="$(awk '
    /^## Required Telemetry/ { f=1; next }
    f && /^## /               { exit }
    f                         { print }
  ' "$EXEC_FILE")"
  if printf '%s\n' "$TELEM_SECTION" | grep -Fq 'failure-strategy'; then
    pass "(T9-d) 'failure-strategy' is listed in the '## Required Telemetry' field list"
  else
    bad "(T9-d) 'failure-strategy' is NOT in the '## Required Telemetry' field list"
  fi

  # The fence's python key list quotes its keys; asserting the QUOTED form is
  # what separates the schema key from the TT_FAILURE_STRATEGY shell variable.
  # BOTH fence anchors are validated first — exactly like (T9-b) — because the
  # awk walk below stops only on the CLOSING anchor: without it the "fence"
  # silently becomes "everything from the opening anchor to EOF", and any later
  # `"failure-strategy"` anywhere in the file would satisfy this assertion.
  TT_START='# >>> zuvo:task-telemetry'
  TT_END='# <<< zuvo:task-telemetry'
  if anchor_ok "T9-d" "$EXEC_FILE" "$TT_START" "$TT_END"; then
    FENCE="$(awk '
      /# >>> zuvo:task-telemetry/ { f=1 }
      f                           { print }
      f && /# <<< zuvo:task-telemetry/ { exit }
    ' "$EXEC_FILE")"
    if [ -z "$FENCE" ]; then
      bad "(T9-d) the task-telemetry fence extracted EMPTY despite well-formed anchors — the key-list assertion would be vacuous"
    elif printf '%s\n' "$FENCE" | grep -Fq '"failure-strategy"'; then
      pass "(T9-d) '\"failure-strategy\"' is in the task-telemetry fence key list"
    else
      bad "(T9-d) '\"failure-strategy\"' is NOT in the task-telemetry fence key list"
    fi
  else
    bad "(T9-d) task-telemetry fence anchors are not well-formed — the fence key-list assertion is SKIPPED rather than false-greened on an EOF-extended range"
  fi
fi

# ── (T9-e) the degraded:-never-BLOCKED statement agrees across both files ────
# The expected string is READ OUT of no-pause-protocol.md, never hardcoded: the
# assertion is agreement between two files, so hardcoding it here would let the
# pair drift together while the test kept passing.
#
# It is ANCHOR-SCOPED on both sides, not `grep -m1` on a substring. The old
# first-match grep could be satisfied by ANY line mentioning `BLOCKED_*` — a
# decoy sentence elsewhere in either file (this skill has several paragraphs
# about `BLOCKED_*` states) would be picked up as "the" sentence, and the
# cross-file check would then compare the wrong line, or pass on a match that
# has nothing to do with `degraded:`. The dedicated anchor pair names exactly
# one statement in each file, so the comparison is unambiguous by construction.
DG_START='<!-- zuvo:degraded-not-blocked-start -->'
DG_END='<!-- zuvo:degraded-not-blocked-end -->'
# Body between the anchors, anchors themselves excluded, blank lines dropped.
dg_body() {
  awk -v s="$DG_START" -v e="$DG_END" '
    index($0, s) { f=1; next }
    f && index($0, e) { exit }
    f && NF { print }
  ' "$1"
}
dg_ok=1
anchor_ok "T9-e/npp" "$NPP_FILE" "$DG_START" "$DG_END" || dg_ok=0
anchor_ok "T9-e/exec" "$EXEC_FILE" "$DG_START" "$DG_END" || dg_ok=0

if [ "$dg_ok" -ne 1 ]; then
  bad "(T9-e) degraded:-never-BLOCKED anchor pair is not well-formed in both files — the cross-file agreement assertion is SKIPPED rather than false-greened on a substring match elsewhere"
else
  DEGRADED_NPP="$(dg_body "$NPP_FILE")"
  DEGRADED_EXEC="$(dg_body "$EXEC_FILE")"
  DEGRADED_KEY='NEVER yields a `BLOCKED_*` state'
  if [ -z "$DEGRADED_NPP" ]; then
    bad "(T9-e) the anchored block in shared/includes/no-pause-protocol.md is EMPTY — the degraded: rule is unstated at its one read site"
  elif ! printf '%s\n' "$DEGRADED_NPP" | grep -Fq "$DEGRADED_KEY"; then
    bad "(T9-e) the anchored block in no-pause-protocol.md no longer contains [$DEGRADED_KEY] — the anchors survived but the rule they carry did not"
  elif [ "$DEGRADED_NPP" = "$DEGRADED_EXEC" ]; then
    pass "(T9-e) the degraded:-never-BLOCKED statement is byte-identical between the anchors in no-pause-protocol.md and execute/SKILL.md"
  else
    bad "(T9-e) the anchored degraded:-never-BLOCKED statements DIFFER between no-pause-protocol.md and skills/execute/SKILL.md (one-sided edit) — npp: [$DEGRADED_NPP] vs exec: [$DEGRADED_EXEC]"
  fi
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
