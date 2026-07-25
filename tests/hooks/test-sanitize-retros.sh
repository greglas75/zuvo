#!/usr/bin/env bash
# Tests scripts/zuvo-home/sanitize-retros — normalizes key=value RETRO drift to canonical 17-TSV.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/scripts/zuvo-home/sanitize-retros"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
F="$TMP/retros.log"

echo "=== normalizes key=value, leaves canonical + near-canonical untouched ==="
{
printf '# v2 DATE\tSKILL\tPROJECT\n'
printf 'RETRO: 2026-07-24T10:00:00Z\texecute\tprojX\t-\t-\t-\t-\t1\t1\t1\t1\tmain\tabc1234\tclean\t2findings\tindexed\tok\n'   # canonical
printf 'RETRO: skill=plan project=QuotasMobi at=2026-05-29T11:13:06Z verdict=APPROVED\n'                                        # pure key=value
printf 'RETRO: 2026-05-28T16:15:00Z\tskill=review\tproject=Q\ttier=3\tadversarial_passes=2\n'                                    # mixed key=value
printf 'RETRO: 2026-05-27T10:55:00Z\treview\tQ/viz\t13_commits/4280L\ttier=3/SELF\n'                                            # near-canonical (positional, = in notes)
} > "$F"
python3 "$S" --apply --target "$F" >/dev/null 2>&1
canon=$(awk -F'\t' '/^RETRO:/ && NF==17' "$F" | wc -l | tr -d ' ')
[ "$canon" -eq 3 ] && ok "key=value lines rewritten to 17-field (3 canonical now)" || bad "expected 3 canonical, got $canon"
grep -q $'RETRO: 2026-05-29T11:13:06Z\tplan\tQuotasMobi' "$F" && ok "pure key=value: date/skill/project mapped positionally" || bad "pure key=value not mapped"
grep -q $'RETRO: 2026-07-24T10:00:00Z\texecute\tprojX' "$F" && ok "canonical line untouched" || bad "canonical line altered"
grep -q 'review\tQ/viz\t13_commits' "$F" && ok "near-canonical (positional) kept as-is, not mangled" || bad "near-canonical corrupted"

echo "=== idempotent + no data loss ==="
before=$(grep -c '^RETRO:' "$F")
python3 "$S" --apply --target "$F" 2>&1 | grep -q '0 normalized' && ok "second run: 0 normalized (idempotent)" || bad "not idempotent"
[ "$(grep -c '^RETRO:' "$F")" -eq "$before" ] && ok "entry count preserved ($before)" || bad "entries lost"
[ -f "$F.pre-sanitize" ] && ok "backup kept before rewrite" || bad "no backup"

echo "=== undecodable drift kept, not dropped ==="
printf 'RETRO: garbage=only nothing=here\n' >> "$F"
python3 "$S" --apply --target "$F" >/dev/null 2>&1
grep -q 'garbage=only' "$F" && ok "undecodable line kept (data never dropped)" || bad "undecodable line lost"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
