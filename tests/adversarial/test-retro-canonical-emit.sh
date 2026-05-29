#!/usr/bin/env bash
# test-retro-canonical-emit.sh — append-retro ALWAYS emits exactly one
# canonical NF==17 `RETRO: ` line, self-resolves PROJECT (ignoring an exported
# $PROJECT plan-slug), and survives a multi-line field. Closes M2 (NF==1 prose
# / NF==12 key=value drift) and the Codex plan-slug PROJECT mis-attribution.

ARET="$ROOT/scripts/zuvo-home/append-retro"
_o=""; _oc(){ for d in $_o; do rm -rf "$d" 2>/dev/null; done; }; trap _oc EXIT INT TERM
_z(){ local d; d=$(mktemp -d); _o="$_o $d"; printf '%s' "$d"; }
T="2026-05-29T00:00:00Z"

start_test "emit is exactly NF==17 with the RETRO: prefix"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=review --project=Demo --friction=no-friction \
  --code-type=MIXED --date="$T" --sha7=abc1234 >/dev/null 2>&1
line=$(grep '^RETRO:' "$Z/retros.log" | head -1)
nf=$(printf '%s' "$line" | awk -F'\t' '{print NF}')
assert_eq 17 "$nf" "canonical 17 TSV fields"
f2=$(printf '%s' "$line" | awk -F'\t' '{print $2}')
assert_eq "review" "$f2" "field2 = bare skill name (not 'skill=review')"

start_test "PROJECT self-resolves to git basename, IGNORING exported \$PROJECT"
Z=$(_z)
# Hostile env: a Codex-style orchestrator exports a plan-slug as $PROJECT.
( cd "$ROOT" && PROJECT="t3a-api-scaffold-reconciliation-plan" \
    ZUVO_HOME="$Z" "$ARET" --skill=execute --friction=other --date="$T" >/dev/null 2>&1 )
f3=$(grep '^RETRO:' "$Z/retros.log" | head -1 | awk -F'\t' '{print $3}')
realbase=$(basename "$(git -C "$ROOT" rev-parse --show-toplevel)")
assert_eq "$realbase" "$f3" "PROJECT = repo basename, not the exported plan-slug"

start_test "explicit --project is honoured (deliberate caller override)"
Z=$(_z)
PROJECT="ignored-env" ZUVO_HOME="$Z" "$ARET" --skill=execute --project=Explicit \
  --friction=other --date="$T" >/dev/null 2>&1
f3=$(grep '^RETRO:' "$Z/retros.log" | head -1 | awk -F'\t' '{print $3}')
assert_eq "Explicit" "$f3" "explicit --project wins over env"

start_test "a multi-line MISSING_TEMPLATE still yields ONE NF==17 line"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=build --project=Demo --friction=missing-pattern \
  --missing-template="$(printf 'line1\nline2 with a very long tail that exceeds the cap')" \
  --date="$T" >/dev/null 2>&1
# Embedded newline must be rejected (no silent multi-line record).
rc=$?
data=$(grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0)
if [ "$rc" -eq 2 ]; then
  pass "embedded-newline MISSING_TEMPLATE rejected (exit 2) — no NF drift"
else
  # If accepted, it MUST be exactly one NF==17 line (newline stripped to space).
  nf=$(grep '^RETRO:' "$Z/retros.log" | head -1 | awk -F'\t' '{print NF}')
  if [ "$data" -eq 1 ] && [ "$nf" -eq 17 ]; then
    pass "newline normalized to a single NF==17 line"
  else
    fail "multi-line MT" "produced $data lines / NF=$nf (drift)"
  fi
fi

start_test "default DATE is machine-stamped (no --date) and ISO-Z"
Z=$(_z)
ZUVO_HOME="$Z" "$ARET" --skill=docs --project=Demo --friction=other --sha7=z >/dev/null 2>&1
f1=$(grep '^RETRO:' "$Z/retros.log" | head -1 | sed 's/^RETRO: //' | awk -F'\t' '{print $1}')
case "$f1" in
  [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z) pass "field1 is machine-stamped ISO-Z" ;;
  *) fail "default date" "field1 not ISO-Z: <$f1>" ;;
esac
