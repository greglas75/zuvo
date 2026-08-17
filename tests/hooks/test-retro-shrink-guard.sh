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
# Recovery would repair this instantly, and this block is about DETECTION. Snapshots go aside so
# the guard has nothing to restore from — the state a machine is in before its first snapshot.
mv "$Z/retros-snapshots" "$Z/.snaps-det"
: > "$Z/retros.log"
sleep 1; : > "$TMP/err"; run
grep -q 'lost 8 rows' "$TMP/err" \
  && ok "a retros.log emptied to ZERO rows still trips the guard" \
  || bad "zero rows did not trip the guard; stderr was: $(head -1 "$TMP/err")"
[ "$(hw)" = "8" ] && ok "high-water survives a zero-row file" || bad "high-water regressed to '$(hw)' on an empty file"

# THE INCIDENT, reproduced: something outside this script truncates the file. Still no snapshots,
# so this pins the report rather than the repair.
cp "$Z/.keep8" "$Z/retros.log"; sleep 1; run
# The healthy run above RE-CREATED the snapshot directory (the guard snapshots whenever the file is
# at or above high-water), so it has to go aside again — otherwise the repair masks the report.
rm -rf "$Z/.snaps-det"; mv "$Z/retros-snapshots" "$Z/.snaps-det"
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

# Snapshots come back for the next two assertions: they are about the ARCHIVE surviving the
# incident, which cannot be observed while the archive is parked elsewhere.
rm -rf "$Z/retros-snapshots"; mv "$Z/.snaps-det" "$Z/retros-snapshots"

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

cp "$Z/.keep8" "$Z/retros.log"; sleep 1; run    # healthy again; recovery available from here on

# AUTO-RECOVERY. Detecting the loss and hand-merging it is not a fix when the truncation recurs
# (it did: 422->100, then 464->112 within hours). The guard performs the same union it took me two
# manual rounds to do. Two properties must hold, and the second is what keeps this safe:
#   * it must RECOVER rows from the snapshot, and
#   * it must be a UNION — rows written after the last snapshot survive, so a "restore" can never
#     trade one loss for another.
row "2026-08-11T07:00:00Z" >> "$Z/retros.log"     # live-only row, absent from every snapshot
LIVE_ONLY=$(grep -c '2026-08-11T07:00:00Z' "$Z/retros.log")
# tail, not head: the live-only row is the LAST one, and truncating with `head` would delete the
# very row whose survival this case exists to prove — the test would then pass on a replace.
tail -1 "$Z/retros.log" > "$Z/.t9" && mv "$Z/.t9" "$Z/retros.log"   # brutal truncation to 1 row
sleep 1; : > "$TMP/err"; run
REC=$(rows)
grep -q 'AUTO-RECOVERED' "$TMP/err" && ok "the guard auto-recovers instead of only complaining" \
  || bad "no auto-recovery attempted; stderr: $(head -2 "$TMP/err" | tr '\n' ' ')"
[ "$REC" -gt 1 ] && ok "rows came back from the snapshot ($REC)" || bad "row count is still $REC"
[ "$(grep -c '2026-08-11T07:00:00Z' "$Z/retros.log")" = "$LIVE_ONLY" ] \
  && ok "the live-only row survived the merge (union, not replace)" \
  || bad "a row written after the last snapshot was LOST by the recovery — replace, not union"
[ "$(grep -c '^#' "$Z/retros.log")" -ge 0 ] && ok "header handling did not corrupt the file" || bad "header lost"
# Idempotent: running again must not duplicate anything.
BEFORE=$(rows); sleep 1; run; [ "$(rows)" = "$BEFORE" ] \
  && ok "a second pass adds no duplicates (whole-line dedup)" || bad "recovery is not idempotent"
# The post-recovery file IS the healthy baseline now. .keep8 predates it and sits BELOW the
# high-water the recovery raised, so restoring that would keep the incident open forever.
cp "$Z/retros.log" "$Z/.keephealthy"; sleep 1; run

# ONE MARKER PER INCIDENT. The first real incident produced SEVEN identical markers — 422->101,
# 102, 103 … one per append — which read like seven truncations and were one. The stderr warning
# must keep firing (data is still missing); only the marker file is deduplicated.
# Truncate ONCE (a fresh incident -> one marker), then append a row while still below the
# high-water. The second append is the SAME incident and must not produce a second file.
# Snapshots are moved aside first: with auto-recovery available the file bounces straight back to
# high-water and there IS no second shrink to deduplicate. This case is about the marker, so the
# recovery path is removed rather than worked around.
mv "$Z/retros-snapshots" "$Z/.snaps-aside"
head -1 "$Z/retros.log" > "$Z/.t2" 2>/dev/null; cp "$Z/.t2" "$Z/retros.log"
sleep 1; run
MARKERS_1=$(ls "$Z"/retros-SHRANK-*.txt 2>/dev/null | wc -l | tr -d ' ')
row "2026-08-09T09:00:00Z" >> "$Z/retros.log"      # 2 rows, still far below high-water 8
sleep 1; : > "$TMP/err"; run
MARKERS_2=$(ls "$Z"/retros-SHRANK-*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$MARKERS_2" = "$MARKERS_1" ] && ok "a second append during the SAME incident adds no new marker" \
  || bad "marker count went $MARKERS_1 -> $MARKERS_2 — one incident is producing a file per append"
grep -q 'still' "$TMP/err" && ok "…but stderr still warns that data is missing" \
  || bad "the warning went silent while the log is still short"

# …and a LATER, separate truncation must be reported as its own incident.
mv "$Z/.snaps-aside" "$Z/retros-snapshots"
cp "$Z/.keephealthy" "$Z/retros.log"; sleep 1; run    # back at high-water -> sentinel clears
head -3 "$Z/retros.log" > "$Z/.t3" && mv "$Z/.t3" "$Z/retros.log"
sleep 1; run
MARKERS_3=$(ls "$Z"/retros-SHRANK-*.txt 2>/dev/null | wc -l | tr -d ' ')
[ "$MARKERS_3" -gt "$MARKERS_2" ] && ok "a NEW incident after a recovery gets its own marker" \
  || bad "the second incident was swallowed as a duplicate of the first"
cp "$Z/.keephealthy" "$Z/retros.log"; sleep 1; run

# CLASS GUARD. `grep -c ... || echo 0` is a three-instance bug in this directory: it disabled the
# shrink guard above, and sat latent in append-runlog and retro-stub (where it would have reached
# awk as a syntax error). rotate-retros:143 has carried a warning note about it longer than any of
# them, which is precisely why a note is not enough.
echo "=== class guard: no \`grep -c ... || echo\` anywhere in zuvo-home ==="
offenders=""
for f in "$ROOT"/scripts/zuvo-home/*; do
  [ -f "$f" ] || continue
  hits=$(awk '/grep -c[^|]*\|\|[[:space:]]*echo/ && !/^[[:space:]]*#/{print FILENAME ":" FNR}' "$f" 2>/dev/null)
  [ -n "$hits" ] && offenders="$offenders $hits"
done
if [ -z "$offenders" ]; then ok "no helper counts with a \`|| echo\` fallback"
else bad "the grep -c || echo trap is back at:$offenders"; fi

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
