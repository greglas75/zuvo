#!/usr/bin/env bash
# append-retro's shrink guard + rolling snapshot.
#
# The incident: 2026-08-15 11:17, retros.log and retros.md rewritten in the same second. The log
# went 143486 -> 70167 bytes and lost 02-11.08; retros.md went 2828907 -> 944395. No archive
# anywhere in ~/.zuvo, and nobody noticed for four days. `rotate-retros` was NOT the writer — its
# own log ends 08-13 and its job runs weekly — so a guard inside the archiving scripts would have
# missed it entirely. The writer is unknown. That is the design constraint this suite encodes: the
# guard must be indifferent to WHO wrote, comparing the file only against what it was last seen to be.
#
# The assertion that matters most is the LAST one. A naive version of this feature snapshots on a
# timer and would have faithfully backed up the truncated file over the last good copy — turning a
# recoverable incident into a permanent one. A snapshot is therefore taken ONLY when the file is at
# or above the high-water.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/zuvo-home/append-retro"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

bash -n "$SRC" 2>/dev/null && ok "append-retro parses" || bad "append-retro does not parse"

# Extract the guard and drive it directly: the full script needs a valid 17-field retro and a lock,
# which would test append-retro's argument parsing rather than the guard.
python3 - "$SRC" "$TMP/guard.sh" <<'PY'
import sys
s = open(sys.argv[1], encoding="utf-8").read()
i = s.find("_shrink_guard() {"); j = s.find("_shrink_guard || true")
if i < 0 or j < 0: sys.exit("could not extract _shrink_guard")
open(sys.argv[2], "w").write(
    '#!/usr/bin/env bash\nset -u\nRETRO_LOG="$ZUVO_HOME/retros.log"\nRETRO_MD="$ZUVO_HOME/retros.md"\n'
    + s[i:j] + "\n_shrink_guard\n")
PY
[ -s "$TMP/guard.sh" ] && ok "guard extracted from the real script" || { bad "extraction failed"; echo "FAILED: $fails"; exit 1; }

Z="$TMP/z"; mkdir -p "$Z"
export ZUVO_HOME="$Z"
row(){ printf 'RETRO: %s\tship\tp\tOTHER\tother\tN/A\tnone\t1\t1\t1\t1\tmain\tabc\tN/A\tN/A\tN/A\tok\n' "$1"; }
run(){ ZUVO_RETRO_SNAPSHOT_SEC=0 bash "$TMP/guard.sh" 2>"$TMP/err"; }
rows(){ grep -c '^RETRO:' "$Z/retros.log" 2>/dev/null || echo 0; }
hw(){ sed -n 's/^rows=//p' "$Z/.retros-highwater" 2>/dev/null | head -1; }

for d in 01 02 03 04 05; do row "2026-08-${d}T00:00:00Z"; done > "$Z/retros.log"
echo "# retros" > "$Z/retros.md"
run
[ "$(hw)" = "5" ] && ok "high-water recorded on first run (5)" || bad "high-water not recorded (got '$(hw)')"

for d in 06 07 08; do row "2026-08-${d}T00:00:00Z"; done >> "$Z/retros.log"
sleep 1; run
[ "$(hw)" = "8" ] && ok "high-water advances as the log grows (8)" || bad "high-water did not advance (got '$(hw)')"
[ -n "$(ls "$Z/retros-snapshots"/retros.log.*.gz 2>/dev/null)" ] && ok "a snapshot exists while healthy" || bad "no snapshot taken"
[ -n "$(ls "$Z/retros-snapshots"/retros.md.*.gz 2>/dev/null)" ] && ok "retros.md is snapshotted too (it was truncated as well)" || bad "retros.md not snapshotted"
SNAP_BEFORE=$(ls -t "$Z/retros-snapshots"/retros.log.*.gz | head -1)
GOOD_ROWS=$(gunzip -c "$SNAP_BEFORE" | grep -c '^RETRO:')

# ZERO ROWS — the worst case, and the one the first version of this guard silently ignored.
# `grep -c ... || echo 0` yields "0\n0" on an empty file (grep prints 0 AND exits 1), the newline
# matches the non-digit escape, and the guard returned early: it switched itself off at exactly the
# moment it exists for. Found by adversarial review, reproduced, fixed.
cp "$Z/retros.log" "$Z/.keep8"
: > "$Z/retros.log"
sleep 1; : > "$TMP/err"; run
grep -q 'lost 8 rows' "$TMP/err" \
  && ok "a retros.log emptied to ZERO rows still trips the guard" \
  || bad "zero rows did not trip the guard; stderr was: $(head -1 "$TMP/err")"
[ "$(hw)" = "8" ] && ok "high-water survives a zero-row file" || bad "high-water regressed to '$(hw)' on an empty file"
cp "$Z/.keep8" "$Z/retros.log"; sleep 1; run

# THE INCIDENT, reproduced: something outside this script truncates the file.
head -2 "$Z/retros.log" > "$Z/.t" && mv "$Z/.t" "$Z/retros.log"
sleep 1; run
[ "$(rows)" = "2" ] && ok "fixture truncated to 2 rows" || bad "fixture not truncated"

grep -q 'lost 6 rows' "$TMP/err" && ok "shrink is reported loudly on stderr, with the row delta" \
  || bad "shrink not reported; stderr was: $(head -1 "$TMP/err")"
[ -n "$(ls "$Z"/retros-SHRANK-*.txt 2>/dev/null)" ] && ok "a dated marker file records the incident" \
  || bad "no marker file written"
grep -q 'restore-self' "$Z"/retros-SHRANK-*.txt 2>/dev/null \
  && ok "the marker names both recovery routes (local snapshot + collector)" \
  || bad "the marker does not say how to recover"

[ "$(hw)" = "8" ] && ok "high-water does NOT regress to the truncated size" \
  || bad "high-water followed the truncation down to '$(hw)' — the next shrink would go unnoticed"

# THE ONE THAT MATTERS: the good copy must survive the incident.
SNAP_AFTER=$(ls -t "$Z/retros-snapshots"/retros.log.*.gz | head -1)
AFTER_ROWS=$(gunzip -c "$SNAP_AFTER" | grep -c '^RETRO:')
[ "$AFTER_ROWS" = "$GOOD_ROWS" ] && [ "$AFTER_ROWS" -gt 2 ] \
  && ok "the truncated file did NOT overwrite the last good snapshot (still $AFTER_ROWS rows)" \
  || bad "the snapshot now holds $AFTER_ROWS rows — the backup was overwritten with the damage"

# …and recovery from it is real, not theoretical.
gunzip -c "$SNAP_AFTER" > "$Z/recovered.log" 2>/dev/null
[ "$(grep -c '^RETRO:' "$Z/recovered.log")" = "8" ] \
  && ok "the pre-shrink state is recoverable from the snapshot alone (no collector needed)" \
  || bad "could not recover the pre-shrink state locally"

# Recovery must also clear the alarm rather than leaving it latched forever.
cp "$Z/recovered.log" "$Z/retros.log"; sleep 1; : > "$TMP/err"; run
grep -q 'lost' "$TMP/err" && bad "still warns after the file was restored — the alarm never clears" \
                          || ok "the warning clears once the log is back at high-water"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
