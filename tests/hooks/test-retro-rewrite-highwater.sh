#!/usr/bin/env bash
# rotate-retros against the high-water and snapshots append-retro keeps beside retros.log.
#
# append-retro treats any retros.log holding fewer RETRO rows than `.retros-highwater` as a
# truncation and unions the newest snapshot back in. A rotation is a legitimate shrink, so it has to
# lower the high-water and leave a post-rotation snapshot, and it must never rotate a log that is
# already below the high-water (that would archive part of a truncated file and bless the loss).
# Runs on Linux and macOS: the append-only flag helpers degrade to no-ops where chflags is absent.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"
holder=""
cleanup() { [ -n "$holder" ] && kill "$holder" 2>/dev/null; chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"; }
trap cleanup EXIT
fails=0
ok() { echo "  ✓ $1"; }
bad() { echo "  ✗ $1"; fails=$((fails + 1)); }
export GIT_CONFIG_GLOBAL=/dev/null

BIN="$TMP/bin"; mkdir -p "$BIN"
cp "$ROOT/scripts/zuvo-home/rotate-retros" "$ROOT/scripts/zuvo-home/append-retro" \
   "$ROOT/scripts/lib/retro-appendonly.sh" "$BIN/" || { echo "FAILED: fixture copy"; exit 1; }
chmod +x "$BIN/rotate-retros" "$BIN/append-retro"

NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
row() { printf 'RETRO: %s\tship\tp\tOTHER\tother\t-\tnone\t1\t1\t1\t1\tmain\t%s\tnot_run\tnot_run\tN/A\tN/A\n' "$1" "$2"; }
# mklog <file> <old rows> <recent rows>: old rows predate any rotation cutoff, recent ones are dated now.
mklog() {
  printf '# v2 DATE\tSKILL\tPROJECT\n' > "$1"
  i=0; while [ "$i" -lt "$2" ]; do i=$((i + 1)); row "2020-01-0${i}T00:00:00Z" "old$i" >> "$1"; done
  i=0; while [ "$i" -lt "$3" ]; do i=$((i + 1)); row "$NOW" "new$i" >> "$1"; done
}
mkmd() { printf '<!-- RETRO -->\n\n## 2020-01-01 ship p archived-section\n\n<!-- RETRO -->\n\n## %s ship p kept-section\n' "$NOW" > "$1"; }
sethw() { printf 'rows=%s\nbytes=1\nat=2020-01-01T00:00:00Z\n' "$2" > "$1/.retros-highwater"; }
hw() { sed -n 's/^rows=//p' "$1/.retros-highwater" 2>/dev/null | head -1; }
sum() { cksum < "$1"; }
rows() { n=$(grep -c '^RETRO:' "$1" 2>/dev/null) || n=0; echo "$n"; }
newest() { ls -t "$1"/retros-snapshots/"$2".*.gz 2>/dev/null | head -1; }
rotate() { ZUVO_HOME="$1" bash "$BIN/rotate-retros" --apply --target "$2"; }
hold_lock() { mkdir -p "$1/.retro.lock.d"; echo "$holder" > "$1/.retro.lock.d/pid"; }

echo "=== (1) a log already below the high-water is refused, untouched ==="
# Bug: rotating a truncated log archives part of it and records the shrunken count as healthy.
Z1="$TMP/c1"; mkdir -p "$Z1"; mklog "$Z1/retros.log" 2 4; sethw "$Z1" 10
log_before=$(sum "$Z1/retros.log"); hw_before=$(sum "$Z1/.retros-highwater")
rotate "$Z1" "$Z1/retros.log" >/dev/null 2>"$TMP/err1"; rc=$?
[ "$rc" = 4 ] && grep -q 'operating.md §12' "$TMP/err1" \
  && ok "exit 4 with the runbook named on stderr" || bad "rc=$rc, stderr: $(tail -1 "$TMP/err1")"
[ "$(sum "$Z1/retros.log")" = "$log_before" ] && [ "$(sum "$Z1/.retros-highwater")" = "$hw_before" ] \
  && [ -z "$(ls "$Z1"/retros-archive-* "$Z1"/retros-snapshots/* 2>/dev/null)" ] \
  && ok "log, high-water, archives and snapshots all unchanged" || bad "the refused rotation still wrote something"
[ ! -d "$Z1/.retro.lock.d" ] && ok "lock released after the refusal" || bad "refusal left the lock behind"

echo "=== (2) a rotation lowers the high-water and re-snapshots ==="
# Bug: the next append-retro sees rows < high-water and unions the archived rows back from the
# pre-rotation snapshot, filing a false retros-SHRANK marker.
Z2="$TMP/c2"; mkdir -p "$Z2/retros-snapshots"; mklog "$Z2/retros.log" 4 6; sethw "$Z2" 10; mkmd "$Z2/retros.md"
gzip -c "$Z2/retros.log" > "$Z2/retros-snapshots/retros.log.20200101T000000Z.gz"
touch -t 202001010000 "$Z2/retros-snapshots/retros.log.20200101T000000Z.gz"
rotate "$Z2" "$Z2/retros.log" >/dev/null 2>"$TMP/err2"; rc=$?
[ "$rc" = 0 ] && [ "$(hw "$Z2")" = 6 ] && ok "high-water lowered to the kept 6 rows" \
  || bad "rc=$rc, high-water rows='$(hw "$Z2")' (want 6)"
snap=$(newest "$Z2" retros.log)
snap_rows=$(gzip -cd "$snap" 2>/dev/null | grep -c '^RETRO:') || snap_rows=0
[ "$snap_rows" = 6 ] && ok "newest snapshot holds the rotated 6 rows" || bad "newest snapshot $snap has $snap_rows rows"
# Bug: an unrotated retros.md copy from the log branch becomes the newest md snapshot.
[ -z "$(newest "$Z2" retros.md)" ] && ok "the log rotation writes no retros.md snapshot" \
  || bad "log rotation snapshotted retros.md: $(newest "$Z2" retros.md)"
ZUVO_HOME="$Z2" bash "$BIN/append-retro" --skill=ship --project=p --sha7=abc1234 --branch=main \
  --friction=other >/dev/null 2>"$TMP/err2b"; arc=$?
[ "$arc" = 0 ] && ! grep -q 'AUTO-RECOVERED' "$TMP/err2b" && [ -z "$(ls "$Z2"/retros-SHRANK-* 2>/dev/null)" ] \
  && ! grep -q '^RETRO: 2020-01' "$Z2/retros.log" && [ "$(rows "$Z2/retros.log")" = 7 ] \
  && ok "the next append keeps the rotation (7 rows, no recovery, no marker)" \
  || bad "append rc=$arc undid the rotation: $(tr '\n' ' ' < "$TMP/err2b")"

echo "=== (3) a busy lock beside the target stops the rotation ==="
# Bug: a rebuild swapped in under a live writer drops the row it appended meanwhile.
sleep 30 & holder=$!
Z3="$TMP/c3"; mkdir -p "$Z3"; mklog "$Z3/retros.log" 2 2; mkmd "$Z3/retros.md"; hold_lock "$Z3"
log_before=$(sum "$Z3/retros.log"); md_before=$(sum "$Z3/retros.md")
ZUVO_LOCK_WAIT=1 rotate "$Z3" "$Z3/retros.log" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(sum "$Z3/retros.log")" = "$log_before" ] \
  && ok "retros.log target: exit 3, file byte-identical" || bad "retros.log target: rc=$rc under a held lock"
ZUVO_LOCK_WAIT=1 rotate "$Z3" "$Z3/retros.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 3 ] && [ "$(sum "$Z3/retros.md")" = "$md_before" ] \
  && ok "retros.md target: exit 3, file byte-identical" || bad "retros.md target: rc=$rc under a held lock"

echo "=== (4) the lock is taken beside the target, not in ZUVO_HOME ==="
# Bug: a --target in another directory waits on (and races) the wrong lock.
Z4="$TMP/c4home"; O4="$TMP/c4other"; mkdir -p "$Z4" "$O4"; hold_lock "$Z4"; mklog "$O4/retros.log" 2 2
ZUVO_LOCK_WAIT=1 rotate "$Z4" "$O4/retros.log" >/dev/null 2>"$TMP/err4"; rc=$?
[ "$rc" = 0 ] && [ -n "$(ls "$O4"/retros-archive-*.log 2>/dev/null)" ] \
  && ok "rotation in another dir proceeds while ZUVO_HOME is locked" || bad "rc=$rc: $(tail -1 "$TMP/err4")"
[ "$(cat "$Z4/.retro.lock.d/pid" 2>/dev/null)" = "$holder" ] \
  && ok "the unrelated ZUVO_HOME lock is left to its holder" || bad "rotation touched the ZUVO_HOME lock"

echo "=== (5) a markdown rotation re-snapshots, but never a log below the high-water ==="
# Bug: md auto-recovery unions archived sections back from the pre-rotation retros.md snapshot.
Z5="$TMP/c5"; mkdir -p "$Z5"; mkmd "$Z5/retros.md"; mklog "$Z5/retros.log" 0 3; sethw "$Z5" 3
rotate "$Z5" "$Z5/retros.md" >/dev/null 2>&1; rc=$?
md_snap=$(newest "$Z5" retros.md); log_snap=$(newest "$Z5" retros.log)
[ "$rc" = 0 ] && [ -n "$md_snap" ] && ! gzip -cd "$md_snap" | grep -q 'archived-section' \
  && [ "${log_snap##*retros.log.}" = "${md_snap##*retros.md.}" ] \
  && ok "rotated retros.md and the log snapshotted under one stamp" || bad "rc=$rc md='$md_snap' log='$log_snap'"
# Bug: a truncated log becomes the newest snapshot and poisons the next recovery.
Z6="$TMP/c6"; mkdir -p "$Z6"; mkmd "$Z6/retros.md"; mklog "$Z6/retros.log" 0 2; sethw "$Z6" 9
rotate "$Z6" "$Z6/retros.md" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ -z "$(newest "$Z6" retros.log)" ] && [ "$(hw "$Z6")" = 9 ] \
  && ok "a log below the high-water is not snapshotted; high-water untouched" \
  || bad "rc=$rc log snapshot='$(newest "$Z6" retros.log)' hw='$(hw "$Z6")'"

echo "=== (6) guard scope, dry-run, snapshot failure ==="
# Bug: retros.log's high-water refuses or rewrites state for a different .log in the same dir.
Z7="$TMP/c7"; mkdir -p "$Z7"; mklog "$Z7/other.log" 2 2; sethw "$Z7" 10
rotate "$Z7" "$Z7/other.log" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(hw "$Z7")" = 10 ] && [ ! -d "$Z7/retros-snapshots" ] && [ "$(rows "$Z7/other.log")" = 2 ] \
  && ok "a non-retros.log target rotates unguarded, no snapshot" || bad "rc=$rc hw='$(hw "$Z7")' other.log rows=$(rows "$Z7/other.log")"
# Bug: the default dry-run reports a refusal as a failure exit, breaking callers that preview.
Z8="$TMP/c8"; mkdir -p "$Z8"; mklog "$Z8/retros.log" 2 4; sethw "$Z8" 10
out=$(ZUVO_HOME="$Z8" bash "$BIN/rotate-retros" --target "$Z8/retros.log" 2>&1); rc=$?
[ "$rc" = 0 ] && printf '%s' "$out" | grep -q 'would refuse:.*§12' \
  && ok "dry-run below the high-water exits 0 and says it would refuse" || bad "dry-run rc=$rc: $(printf '%s' "$out" | tail -1)"
# Bug: a rotation that cannot snapshot still lowers the high-water and swaps, leaving no good copy.
Z9="$TMP/c9"; mkdir -p "$Z9/retros-snapshots"; mklog "$Z9/retros.log" 2 4; sethw "$Z9" 6
chmod 555 "$Z9/retros-snapshots"
if touch "$Z9/retros-snapshots/probe" 2>/dev/null; then
  echo "  - skipped: a read-only dir is still writable here (root), so a snapshot failure cannot be simulated"
else
  log_before=$(sum "$Z9/retros.log"); hw_before=$(sum "$Z9/.retros-highwater")
  rotate "$Z9" "$Z9/retros.log" >/dev/null 2>&1; rc=$?
  [ "$rc" = 1 ] && [ "$(sum "$Z9/retros.log")" = "$log_before" ] && [ "$(sum "$Z9/.retros-highwater")" = "$hw_before" ] \
    && [ -z "$(ls "$Z9"/retros-archive-* 2>/dev/null)" ] \
    && ok "a failed snapshot aborts with log, high-water and archives unchanged" || bad "snapshot failure: rc=$rc, state changed"
fi

# Bug: a snapshot append-retro took in the same second is overwritten, or deleted on rollback.
# A stub `date` pins the snapshot stamp so the collision is certain, not a matter of timing.
STUB="$TMP/stub"; mkdir -p "$STUB"; REAL_DATE=$(command -v date)
printf '#!/bin/sh\n[ "$*" = "-u +%%Y%%m%%dT%%H%%M%%SZ" ] && { echo 20200101T000000Z; exit 0; }\nexec %s "$@"\n' \
  "$REAL_DATE" > "$STUB/date"; chmod +x "$STUB/date"
Z10="$TMP/c10"; mkdir -p "$Z10/retros-snapshots"; mklog "$Z10/retros.log" 2 4; sethw "$Z10" 6
FOREIGN="$Z10/retros-snapshots/retros.log.20200101T000000Z.gz"
echo "foreign" | gzip -c > "$FOREIGN"; foreign_before=$(sum "$FOREIGN")
PATH="$STUB:$PATH" rotate "$Z10" "$Z10/retros.log" >/dev/null 2>&1; rc=$?
[ "$rc" = 0 ] && [ "$(sum "$FOREIGN")" = "$foreign_before" ] && [ -n "$(ls "$Z10"/retros-snapshots/retros.log.20200101T000000Z-*.gz 2>/dev/null)" ] \
  && ok "a same-stamp snapshot from another writer survives; ours gets a unique name" || bad "rc=$rc, the pre-existing snapshot was overwritten or ours is missing"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
