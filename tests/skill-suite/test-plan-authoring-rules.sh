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
# bash 3.2-compatible (macOS default): no mapfile, no associative arrays.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FILE="$ROOT/skills/plan/SKILL.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

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

# ── informational only: confirm scope boundary with Task 7, never asserted ───
# Not a pass/fail check — a note in the RED evidence trail. Task 7 teaches
# verify-plan-dag about these tokens; until then it must have none, or the
# T7-depends-on-T6 edge in the plan is backwards.
DAG_SCRIPT="$ROOT/scripts/zuvo-home/verify-plan-dag"
if [ -f "$DAG_SCRIPT" ]; then
  DAG_HITS="$(grep -cE 'halt|skip-and-continue|degraded' "$DAG_SCRIPT" 2>/dev/null || true)"
  printf 'INFO: verify-plan-dag currently has %s occurrence(s) of the enum tokens (Task 7 scope, not asserted here)\n' "${DAG_HITS:-0}"
fi

echo "----"
if [ "$fail" -eq 0 ]; then
  echo "ALL PASSED"
  exit 0
else
  echo "SOME FAILED"
  exit 1
fi
