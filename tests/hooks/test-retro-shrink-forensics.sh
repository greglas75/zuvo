#!/usr/bin/env bash
# retro-shrink-forensics.sh — the diagnosis half of the retro-truncation response.
#
# append-retro's guard detects and now auto-recovers, so data stops bleeding. That is treatment.
# This is diagnosis: ~/.zuvo/retros.log has been truncated at least three times (2026-08-16/17
# 422->100, 08-17 464->112, 08-17 519->104) and file-level forensics cannot name the writer, because
# by the time anything looks, the only evidence left is the damage. A launchd WatchPaths trigger runs
# this within moments of the write, while the writer may still hold the file open.
#
# The property that makes it usable rather than noise: retros.log changes ~100 times a day and
# WatchPaths fires on every one of them. A forensics job that dumps on each append buries the single
# event worth reading, so the FIRST thing asserted here is silence on a healthy write.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/zuvo-home/retro-shrink-forensics.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

[ -f "$SRC" ] || { bad "forensics script missing"; echo "FAILED: 1"; exit 1; }
bash -n "$SRC" 2>/dev/null && ok "script parses" || bad "script does not parse"

Z="$TMP/z"; mkdir -p "$Z"; export ZUVO_HOME="$Z"
OUT="$Z/retro-shrink-forensics.log"
row(){ printf 'RETRO: %s\tship\tp\tOTHER\tother\tN/A\tnone\t1\t1\t1\t1\tmain\tabc\tN/A\tN/A\tN/A\tok\n' "$1"; }
dumps(){ grep -c 'SHRINK DETECTED' "$OUT" 2>/dev/null || echo 0; }

for d in 01 02 03 04 05; do row "2026-08-${d}T00:00:00Z"; done > "$Z/retros.log"
echo "# retros" > "$Z/retros.md"
printf 'rows=5\n' > "$Z/.retros-highwater"

# 1. SILENCE ON HEALTHY. ~100 appends a day fire this trigger; only a shrink may write.
bash "$SRC"
[ "$(dumps)" = "0" ] && ok "healthy write (rows == high-water): silent" || bad "dumped on a healthy write — the signal would drown"
row "2026-08-06T00:00:00Z" >> "$Z/retros.log"
bash "$SRC"
[ "$(dumps)" = "0" ] && ok "an APPEND above the high-water: still silent" || bad "dumped on a plain append"

# 2. A shrink dumps, once, with the numbers that distinguish a trim from a rewrite.
head -2 "$Z/retros.log" > "$Z/.t" && mv "$Z/.t" "$Z/retros.log"
bash "$SRC"
[ "$(dumps)" = "1" ] && ok "a shrink produces exactly one dump" || bad "expected 1 dump, got $(dumps)"
grep -q 'rows: 5 -> 2' "$OUT" 2>/dev/null && ok "the dump records the before/after row counts" \
  || bad "row delta missing from the dump"
grep -q 'retros.md:' "$OUT" 2>/dev/null && ok "retros.md state is captured too (it is truncated in the same second)" \
  || bad "retros.md not captured"
for section in 'open file handles' 'suspects in the process table' 'launchd jobs'; do
  grep -q "$section" "$OUT" 2>/dev/null && ok "dump includes: $section" || bad "dump missing: $section"
done

# 3. ONE DUMP PER INCIDENT. WatchPaths fires again on the auto-recovery write and on every later
#    append; without deduplication one truncation would produce a dump per append, which is exactly
#    the failure the marker files had (seven files for one event).
bash "$SRC"; bash "$SRC"
[ "$(dumps)" = "1" ] && ok "repeat triggers during the SAME incident add no dump" \
  || bad "one incident produced $(dumps) dumps — the trigger is not deduplicated"

# 4. …and a genuinely new incident, after the high-water moves, dumps again.
for d in 01 02 03 04 05 06 07; do row "2026-08-${d}T00:00:00Z"; done > "$Z/retros.log"
printf 'rows=7\n' > "$Z/.retros-highwater"
bash "$SRC"                                   # healthy at the new high-water: silent
head -1 "$Z/retros.log" > "$Z/.t" && mv "$Z/.t" "$Z/retros.log"
bash "$SRC"
[ "$(dumps)" = "2" ] && ok "a NEW incident (different high-water) dumps again" \
  || bad "the second incident was swallowed; dumps=$(dumps)"

# 5. It must never touch the data it is diagnosing, and never fail loudly enough to matter.
BEFORE=$(wc -c < "$Z/retros.log")
bash "$SRC"; rc=$?
[ "$rc" = "0" ] && ok "always exits 0 (a diagnostic must not become an incident)" || bad "exited $rc"
[ "$(wc -c < "$Z/retros.log")" = "$BEFORE" ] && ok "retros.log is not modified by the forensics run" \
  || bad "the forensics script WROTE to retros.log"
rm -f "$Z/retros.log"; bash "$SRC"; [ $? = 0 ] && ok "missing retros.log: exits 0, no crash" || bad "crashed on a missing file"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
