#!/usr/bin/env bash
# Tests ~/.zuvo/log-drive-by (scripts/zuvo-home/log-drive-by). Records a receipt that the
# "Drive-by findings" step ran, with per-category counts, without forcing findings.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LD="$ROOT/scripts/zuvo-home/log-drive-by"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_HOME="$TMP/zh"
LOG="$ZUVO_HOME/drive-by.log"

echo "=== records per-category counts and their total ==="
bash "$LD" --skill build --sec 2 --dup 1 --read=3 >/dev/null 2>&1
bash "$LD" --skill review >/dev/null 2>&1
[ "$(grep -c '^[0-9]' "$LOG" 2>/dev/null)" -eq 2 ] && ok "2 receipts logged" || bad "receipt count wrong"
# DATE SKILL PROJECT TOTAL SEC BUG SIZE DUP CPLX PERF DEAD READ
grep -q $'\tbuild\t[^\t]*\t6\t2\t0\t0\t1\t0\t0\t0\t3$' "$LOG" && ok "counts land in their columns, total 6 (catches a swapped or dropped column)" || bad "build row wrong: $(grep build "$LOG")"
grep -q $'\treview\t[^\t]*\t0\t0\t0\t0\t0\t0\t0\t0\t0$' "$LOG" && ok "no counts = honest all-zero row" || bad "default row not all zero"

echo "=== CRITICAL regression: a trailing value-flag must NOT infinite-loop ==="
# Stock macOS ships no `timeout`: an unresolved binary exits 127, which a "not 124" check would
# read as "no hang" without ever running the script. Resolve it, and fail loudly when it is absent.
TO="$(command -v timeout || command -v gtimeout || true)"
if [ -z "$TO" ]; then
  bad "no timeout/gtimeout on PATH — the hang regression cannot be checked here"
else
  for args in "--skill" "--sec" "--project" "--sec 3 --skill" "--skill build --read"; do
    "$TO" 3 bash "$LD" $args >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] && ok "no hang, exit 0: [$args]" || bad "rc=$rc (124 = HANG) on trailing flag: [$args]"
  done
fi

echo "=== a value-less flag must not swallow the next flag ==="
rm -f "$LOG"
bash "$LD" --skill --sec 3 >/dev/null 2>&1
tail -1 "$LOG" | grep -q $'\tunknown\t[^\t]*\t3\t3\t' && ok "--skill --sec 3 keeps SEC=3 (skill falls back to unknown)" || bad "next flag swallowed: $(tail -1 "$LOG")"
err="$(bash "$LD" --skill build --secc 2 2>&1 >/dev/null)"
case "$err" in *"unknown flag: --secc"*) ok "a misspelled flag is reported on stderr, not silently read as 0" ;; *) bad "typo silent: $err" ;; esac

echo "=== concurrent first writers keep one header and every row ==="
rm -f "$LOG"
for i in 1 2 3 4 5 6 7 8; do bash "$LD" --skill "c$i" >/dev/null 2>&1 & done; wait
[ "$(grep -c '^# DATE' "$LOG")" -eq 1 ] && ok "exactly one header" || bad "header count $(grep -c '^# DATE' "$LOG")"
[ "$(grep -c $'^[0-9].*\tc[1-8]\t' "$LOG")" -eq 8 ] && ok "all 8 concurrent rows survived (no truncation by a late header write)" || bad "rows lost: $(grep -c '^[0-9]' "$LOG")/8"

echo "=== an unwritable log is reported, still exit 0 ==="
RO="$TMP/ro"; mkdir -p "$RO/drive-by.log"            # a directory where the file should be
err="$(ZUVO_HOME="$RO" bash "$LD" --skill build 2>&1 >/dev/null)"; rc=$?
[ "$rc" -eq 0 ] && case "$err" in *"receipt NOT written"*) true ;; *) false ;; esac \
  && ok "failed write: exit 0 + 'receipt NOT written' on stderr" || bad "rc=$rc err=$err"

echo "=== hardening ==="
rm -f "$LOG"
bash "$LD" --skill "x'; rm -rf /tmp/xx" --sec "9a9" --bug 99999999999999999999 >/dev/null 2>&1
line="$(tail -1 "$LOG")"
case "$line" in *"rm"*"/"*|*";"*|*"'"*) bad "injection chars survived: $line" ;; *) ok "skill sanitized to safe tokens" ;; esac
printf '%s\n' "$line" | grep -q $'\t99\t' && ok "non-digits stripped from a count (9a9 -> 99)" || bad "count not sanitized: $line"
printf '%s\n' "$line" | grep -q $'\t999999\t' && ok "an absurd count is clipped, total still computed" || bad "huge count not clipped: $line"
bash "$LD" >/dev/null 2>&1 && ok "no args -> exit 0 (best-effort, never fails a skill)" || bad "no-args failed"
tail -1 "$LOG" | grep -q $'\tunknown\t' && ok "missing --skill defaults to 'unknown'" || bad "missing skill not defaulted"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
