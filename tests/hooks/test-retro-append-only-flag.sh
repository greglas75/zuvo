#!/usr/bin/env bash
#
# test-retro-append-only-flag.sh — the filesystem append-only guard on retros.{log,md}.
#
# Between 2026-08-17 and 2026-09-17 retros.log was truncated to ~101 rows six times by a writer
# that could not be identified: the forensics job is launchd WatchPaths + ThrottleInterval=10, so
# it samples the process table up to ten seconds after the change, while `head+tail+mv` finishes
# in milliseconds — in three of the six incidents its suspects table is EMPTY.
#
# `chflags uappnd` does not need to know the writer. What it must do, and what this file pins:
#   1. permit the append path (`>>`) — a guard that blocks retro writes costs more than it saves;
#   2. refuse the truncation recipe, the whole-file truncate, and deletion;
#   3. SURVIVE the three legitimate rewriters. This is the load-bearing one: the flag lives on
#      the INODE, so every atomic replace drops it. A rotation that lifts and forgets to re-arm
#      leaves the file unprotected while everything still looks healthy — the same
#      silently-off-after-looking-fine shape the flag exists to stop.
#
# macOS-only by design (Linux `chattr +a` needs root, which no zuvo helper has). On any other
# platform this SKIPs rather than failing: the helpers degrade to no-ops there.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/scripts/lib/retro-appendonly.sh"
TMP="$(mktemp -d)"; trap 'chflags -R nouappnd "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

if [ "$(uname -s)" != "Darwin" ] || ! command -v chflags >/dev/null 2>&1; then
  echo "SKIP: append-only flag is macOS-only (no chflags here)"
  exit 0
fi

[ -r "$LIB" ] || { echo "  ✗ missing $LIB"; exit 1; }
# shellcheck source=/dev/null
. "$LIB"

armed(){ ls -lO "$1" 2>/dev/null | grep -q uappnd; }

echo "=== the flag itself ==="
F="$TMP/retros.log"
printf 'RETRO: a\nRETRO: b\nRETRO: c\n' > "$F"
zuvo_ao_arm "$F"
armed "$F" && ok "zuvo_ao_arm sets uappnd" || bad "zuvo_ao_arm did not set the flag"
zuvo_ao_is_armed "$F" && ok "zuvo_ao_is_armed agrees" || bad "zuvo_ao_is_armed disagrees with ls -lO"

printf 'RETRO: d\n' >> "$F" 2>/dev/null \
  && ok "append (>>) still permitted — the write path is unaffected" \
  || bad "append was blocked: the guard costs more than it saves"

( : > "$F" ) 2>/dev/null
[ "$(wc -l < "$F" | tr -d ' ')" = "4" ] && ok "whole-file truncate refused" || bad "truncate went through"

# The exact recipe that caused the incidents.
head -1 "$F" > "$TMP/t" 2>/dev/null
tail -n 2 "$F" >> "$TMP/t" 2>/dev/null
mv "$TMP/t" "$F" 2>/dev/null
[ "$(wc -l < "$F" | tr -d ' ')" = "4" ] \
  && ok "head+tail+mv recipe refused (the one that cut 3929 rows to 99)" \
  || bad "the truncation recipe still replaces the file"

rm -f "$F" 2>/dev/null
[ -f "$F" ] && ok "deletion refused" || bad "the file could be deleted"

echo "=== rewriters must re-arm (the inode trap) ==="
zuvo_ao_rewrite "$F" sh -c 'cat "$1" > "$1.new" && echo "RETRO: e" >> "$1.new" && mv "$1.new" "$1"' _ "$F"
[ "$(wc -l < "$F" | tr -d ' ')" = "5" ] && ok "zuvo_ao_rewrite lets a legitimate replace through" || bad "legitimate rewrite was blocked"
armed "$F" && ok "zuvo_ao_rewrite re-arms the NEW inode" || bad "flag lost after rewrite — protection silently off"

# A failing rewrite must not leave the file bare either.
zuvo_ao_rewrite "$F" sh -c 'exit 7'; rc=$?
[ "$rc" = "7" ] && ok "zuvo_ao_rewrite propagates the command's exit code" || bad "exit code swallowed (got $rc)"
armed "$F" && ok "flag restored even when the rewrite FAILED" || bad "a failed rewrite left the file unprotected"

echo "=== the three real rewriters ==="
export ZUVO_HOME="$TMP/home"; mkdir -p "$ZUVO_HOME"
cp "$LIB" "$ZUVO_HOME/retro-appendonly.sh"
cp "$ROOT/scripts/zuvo-home/rotate-retros" "$ZUVO_HOME/rotate-retros"
cp "$ROOT/scripts/zuvo-home/append-retro" "$ZUVO_HOME/append-retro"
chmod +x "$ZUVO_HOME/rotate-retros" "$ZUVO_HOME/append-retro"

LOG="$ZUVO_HOME/retros.log"
printf '# v2 DATE\tSKILL\n' > "$LOG"
# one entry old enough to archive, one recent — so the rotation actually rewrites the file
printf 'RETRO: 2020-01-01T00:00:00Z\told\n' >> "$LOG"
printf 'RETRO: %s\tnew\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
zuvo_ao_arm "$LOG"

out="$("$ZUVO_HOME/rotate-retros" --apply --target "$LOG" 2>&1)"; rrc=$?
if [ "$rrc" -ne 0 ]; then
  bad "rotate-retros failed under the flag (rc=$rrc): $(echo "$out" | tail -1)"
else
  ok "rotate-retros completes with the flag armed"
fi
grep -q '^RETRO:.*new' "$LOG" && ok "rotation kept the recent entry" || bad "rotation lost the recent entry"
armed "$LOG" && ok "rotate-retros RE-ARMS the flag it had to lift" || bad "rotate-retros left retros.log unprotected"

# append-retro re-arms on every append, so a file that lost the flag heals itself within one write.
zuvo_ao_lift "$LOG"
armed "$LOG" && bad "lift did not work (test setup)" || ok "flag deliberately cleared for the heal test"
printf 'RETRO: %s\tmanual\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$LOG"
# `--key=value`, not `--key value`: append-retro parses `--skill=…` and ignores the spaced form.
# The first version of this assertion used spaces, so append-retro never ran and the test reported
# "protection did not heal" for a heal that was never attempted — a false RED that would have sent
# the next reader into the flag code instead of into the invocation.
ar_out="$(cd "$ZUVO_HOME" && ZUVO_HOME="$ZUVO_HOME" ./append-retro \
  --skill=test --project=p --code-type=OTHER --friction=none --missing-template=- \
  --context-gap=none --turns=1 --tool-calls=1 --files-read=0 --files-modified=0 \
  --blind-audit=skipped --adversarial=skipped --codesift=unavailable --routing=ok 2>&1)"; ar_rc=$?
if [ "$ar_rc" -ne 0 ]; then
  bad "append-retro itself failed (rc=$ar_rc): $(echo "$ar_out" | tail -1)"
else
  ok "append-retro wrote a retro under the flag"
fi
armed "$LOG" && ok "append-retro re-arms a file that had lost the flag" || bad "protection did not heal on append"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
