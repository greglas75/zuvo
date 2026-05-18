#!/usr/bin/env bash
# test-retro-enum-contract.sh — Plan Task 2 (G-SUPER definition).
# retrospective.md must define ONE canonical full-retro predicate + the
# checkpoint stub schema + the extended friction enum, token-lean (<=25 lines).

R="$ROOT/shared/includes/retrospective.md"
BASE=259   # line count before this task (verified 2026-05-18)
# Token-lean budget. Plan estimate was +25; the actual minimal-correct content
# is +30 because adversarial review (Task 2, 5 iters) MANDATED four correctness
# additions the estimate did not foresee: enum-valid neutral mapping,
# friction-preservation (no destructive TURNS_WASTED=0), and the write-time
# vs post-hoc dedup model (coherence via session-state retro-session-id at
# WRITE; retros.log post-hoc dedup keys only on in-line SKILL+PROJECT+SHA7 —
# resolves the date<->sha<->session-id oscillation). Squeezing these to hit a
# lower number re-introduces the exact CRITICALs review caught. 30 lines for 5
# contracts in a widely-loaded include is still lean. User-approved disposition
# (BLOCKED_ADVERSARIAL_LOOP accept, 2026-05-18). Budget stays HARD at +30 — it
# still catches genuine future bloat.
BUDGET=30

start_test "T2.1 FRICTION_CATEGORY enum ROW includes the stub friction values"
# Anchor to the actual enum table row (`| 5 | FRICTION_CATEGORY | enum | ... |`)
# so prose mentions elsewhere cannot false-green this (adversarial: regex
# precedence bypass).
ENUM_ROW=$(grep -E '^\|[[:space:]]*5[[:space:]]*\|[[:space:]]*FRICTION_CATEGORY' "$R" | head -1)
if [ -z "$ENUM_ROW" ]; then
  fail "T2.1" "could not locate the FRICTION_CATEGORY enum table row"
else
  for v in abandoned context-out partial-recovery; do
    if printf '%s' "$ENUM_ROW" | grep -qF "\`$v\`"; then pass "enum row has \`$v\`"
    else fail "T2.1" "FRICTION_CATEGORY enum ROW missing \`$v\`"; fi
  done
fi

start_test "T2.2 Canonical Full-Retro Predicate subsection is the single source of truth"
if grep -q 'Canonical Full-Retro Predicate' "$R"; then
  pass "subsection present"
else
  fail "T2.2" "missing 'Canonical Full-Retro Predicate' subsection"
fi
# Extract ONLY the predicate subsection (### Canonical ... up to next ###) and
# assert ONE coherent rule ties RETRO: + field 5 + NOT + the stub set together,
# so CI fails if the prose drifts/contradicts (not three independent greps).
SECTION=$(awk '/^### Canonical Full-Retro Predicate/{f=1} f&&/^### Checkpoint Stub Schema/{exit} f' "$R")
if printf '%s' "$SECTION" | grep -qiE 'RETRO:' \
   && printf '%s' "$SECTION" | grep -qiE 'field 5' \
   && printf '%s' "$SECTION" | grep -qE '∉|\bNOT in\b|not in|exclud' \
   && printf '%s' "$SECTION" | grep -qE 'abandoned' \
   && printf '%s' "$SECTION" | grep -qE 'context-out' \
   && printf '%s' "$SECTION" | grep -qE 'partial-recovery'; then
  pass "predicate section cohesively pins ^RETRO: AND field-5 NOT-in stub set"
else
  fail "T2.2" "predicate section does not state one coherent ^RETRO:+field5-exclusion rule"
fi

start_test "T2.3 Checkpoint Stub Schema subsection documents the 17-field shape"
if grep -q 'Checkpoint Stub Schema' "$R"; then pass "subsection present"
else fail "T2.3" "missing 'Checkpoint Stub Schema' subsection"; fi
# The stub schema must dictate ENUM-VALID neutrals (regression guard for the
# adversarial CRITICAL: CODESIFT=skipped / `-` in enum cols breaks strict parsers).
STUB=$(awk '/^### Checkpoint Stub Schema/{f=1} f&&/^## Markdown Emit/{exit} f' "$R")
if printf '%s' "$STUB" | grep -qiE 'enum-valid' \
   && printf '%s' "$STUB" | grep -qE 'CODESIFT=N/A' \
   && printf '%s' "$STUB" | grep -qiE 'skipped.*NOT a CODESIFT|NOT .* CODESIFT' \
   && printf '%s' "$STUB" | grep -qE 'BLIND_AUDIT=not_run'; then
  pass "stub schema dictates enum-valid neutrals (no out-of-enum tokens)"
else
  fail "T2.3" "stub schema does not pin enum-valid neutrals (CODESIFT=N/A etc.)"
fi

start_test "T2.4 additions are token-lean (<=+$BUDGET lines over base $BASE)"
NOW=$(wc -l < "$R"); MAX=$((BASE + BUDGET))
# Explicit comparison — no reliance on assert_le argument-order convention.
if [ "$NOW" -le "$MAX" ]; then
  pass "retrospective.md $NOW lines <= budget $MAX (base $BASE +$BUDGET)"
else
  fail "T2.4" "retrospective.md grew to $NOW lines, over budget $MAX (base $BASE +$BUDGET)"
fi
