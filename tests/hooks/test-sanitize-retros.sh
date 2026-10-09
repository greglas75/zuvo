#!/usr/bin/env bash
# Tests scripts/zuvo-home/sanitize-retros — normalizes key=value RETRO drift to canonical 17-TSV.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/scripts/zuvo-home/sanitize-retros"
TMP="$(mktemp -d)"
# An armed file cannot be deleted, so disarm the tree before rm or the fixture leaks on every run
# (observed: `rm: Operation not permitted` + `Directory not empty` at the end of a failing run).
trap 'command -v chflags >/dev/null 2>&1 && chflags -R nouappnd "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export ROOT="$ROOT"
# The default target and module-level LOCK resolve from ZUVO_HOME; ZUVO_DIR is unset so no step here
# can reach a real ~/.zuvo/.retro.lock.d.
export ZUVO_HOME="$TMP"
unset ZUVO_DIR
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
grep -q $'review\tQ/viz\t13_commits' "$F" && ok "near-canonical (positional) kept as-is, not mangled" || bad "near-canonical corrupted"

echo "=== idempotent + no data loss ==="
before=$(grep -c '^RETRO:' "$F")
python3 "$S" --apply --target "$F" 2>&1 | grep -q '0 normalized' && ok "second run: 0 normalized (idempotent)" || bad "not idempotent"
[ "$(grep -c '^RETRO:' "$F")" -eq "$before" ] && ok "entry count preserved ($before)" || bad "entries lost"
[ -f "$F.pre-sanitize" ] && ok "backup kept before rewrite" || bad "no backup"

echo "=== undecodable drift kept, not dropped ==="
printf 'RETRO: garbage=only nothing=here\n' >> "$F"
python3 "$S" --apply --target "$F" >/dev/null 2>&1
grep -q 'garbage=only' "$F" && ok "undecodable line kept (data never dropped)" || bad "undecodable line lost"

echo "=== concurrency: lock held on --apply, refuses when busy (no lost append) ==="
# $F IS $TMP/retros.log, and the --apply runs above left it ARMED with the append-only flag —
# that is the production behaviour working, not a fault. The fixture reset below TRUNCATES the
# file, which the flag correctly refuses, so this block has to lift the flag first. Without it
# the reset silently fails and the next assertion measures the OLD content (macOS only: Linux
# has no chflags, so the farm never saw this).
command -v chflags >/dev/null 2>&1 && chflags nouappnd "$TMP/retros.log" 2>/dev/null
printf '# hdr
RETRO: skill=plan project=X at=2026-05-29T11:00:00Z
' > "$TMP/retros.log"
# Busy lock held by a LIVE pid (this shell) -> must refuse, even if the dir looks old.
mkdir -p "$TMP/.retro.lock.d"; echo $$ > "$TMP/.retro.lock.d/pid"; touch -t 202001010000 "$TMP/.retro.lock.d"
r=$(python3 "$S" --apply --target "$TMP/retros.log" 2>&1; echo "rc=$?")
printf '%s' "$r" | grep -q 'rc=3' && ok "refuses (exit 3) when a LIVE process holds the lock (no lock-steal)" || bad "did not refuse on a live-held lock"
[ "$(grep -c '^RETRO:' "$TMP/retros.log")" -eq 1 ] && ok "file untouched while lock live-held (no lost append)" || bad "file modified under a live lock"
rm -f "$TMP/.retro.lock.d/pid"; rmdir "$TMP/.retro.lock.d" 2>/dev/null
# A lock whose holder pid is DEAD is correctly broken (not treated as busy forever).
mkdir -p "$TMP/.retro.lock.d"; echo 999999 > "$TMP/.retro.lock.d/pid"; touch -t 202001010000 "$TMP/.retro.lock.d"
python3 "$S" --apply --target "$TMP/retros.log" >/dev/null 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -d "$TMP/.retro.lock.d" ] && ok "dead-holder lock broken, not stuck busy" || bad "dead-holder lock not broken (rc=$rc)"
[ -d "$TMP/.retro.lock.d" ] && rmdir "$TMP/.retro.lock.d" 2>/dev/null
# now with lock free it proceeds and releases the lock
python3 "$S" --apply --target "$TMP/retros.log" >/dev/null 2>&1
[ ! -d "$TMP/.retro.lock.d" ] && ok "lock released after apply" || bad "lock leaked"

echo "=== structural canonical detection: unknown/digit skills are not drift ==="
python3 - <<'PYEOF'
import os
from importlib.machinery import SourceFileLoader
S=SourceFileLoader('s',os.path.join(os.environ['ROOT'] if 'ROOT' in os.environ else '.','scripts/zuvo-home/sanitize-retros')).load_module()
c17='RETRO: 2026-07-25T10:00:00Z\tbrand-new-2027\tp\t-\t-\t-\t-\t1\t1\t1\t1\tm\ts\tc\t2f\ti\tok'
a='RETRO: 2026-07-24T10:00:00Z\ta11y-audit\tp\t-\t-\t-\t-\t1\t1\t1\t1\tm\ts\tc\t2f\ti\tok'
d='RETRO: skill=plan project=X at=2026-05-29T11:00:00Z'
assert S.is_drifted(c17) is False, 'unknown skill flagged'
assert S.is_drifted(a) is False, 'a11y-audit flagged'
assert S.is_drifted(d) is True, 'real drift missed'
print('OK')
PYEOF
[ "$(ROOT="$ROOT" python3 - <<'PYEOF' 2>/dev/null
import os
from importlib.machinery import SourceFileLoader
S=SourceFileLoader('s',os.path.join(os.environ['ROOT'],'scripts/zuvo-home/sanitize-retros')).load_module()
c='RETRO: 2026-07-25T10:00:00Z\tbrand-new-2027\tp\t-\t-\t-\t-\t1\t1\t1\t1\tm\ts\tc\t2f\ti\tok'
print('yes' if S.is_drifted(c) is False else 'no')
PYEOF
)" = "yes" ] && ok "canonical line for an unknown/new skill is NOT rewritten (structural, not list-based)" || bad "unknown-skill canonical line misclassified"

echo "=== release only removes OUR lock (never another process's) ==="
python3 - <<'PYEOF'
import os
from importlib.machinery import SourceFileLoader
S=SourceFileLoader('s',os.path.join(os.environ['ROOT'],'scripts/zuvo-home/sanitize-retros')).load_module()
os.makedirs(S.LOCK, exist_ok=True); open(os.path.join(S.LOCK,'pid'),'w').write('999999')
S.release_lock()
assert os.path.isdir(S.LOCK), 'released another process lock'
import shutil; shutil.rmtree(S.LOCK)
print('OK')
PYEOF
[ $? -eq 0 ] && ok "release_lock leaves a lock owned by another pid intact" || bad "release_lock removed a foreign lock"
# A pid file that is not a number names no owner: release_lock treats it as unowned and cleans it up. Its
# ValueError is caught next to the OSError — narrowing that except to OSError alone crashed the release.
python3 - <<'PYEOF'
import os
from importlib.machinery import SourceFileLoader
S=SourceFileLoader('s',os.path.join(os.environ['ROOT'],'scripts/zuvo-home/sanitize-retros')).load_module()
os.makedirs(S.LOCK, exist_ok=True); open(os.path.join(S.LOCK,'pid'),'w').write('not-a-pid')
S.release_lock()
assert not os.path.isdir(S.LOCK), 'unowned lock left behind'
print('OK')
PYEOF
[ $? -eq 0 ] && ok "release_lock clears a lock whose pid file is not a number, without raising" || bad "release_lock on a non-numeric pid file"

echo "=== lock and high-water are taken beside --target, not from ZUVO_DIR ==="
# Bug caught: the lock came from ZUVO_DIR while the writers lock the target's own dir, so a sanitize
# could rewrite a log another process was appending to.
mkdir -p "$TMP/a" "$TMP/other"
printf 'RETRO: skill=plan project=X at=2026-05-29T11:00:00Z\n' > "$TMP/a/retros.log"
mkdir -p "$TMP/a/.retro.lock.d"; echo $$ > "$TMP/a/.retro.lock.d/pid"
sum_a=$(cksum < "$TMP/a/retros.log")
r=$(ZUVO_DIR="$TMP/other" python3 "$S" --apply --target "$TMP/a/retros.log" 2>&1; echo "rc=$?")
printf '%s' "$r" | grep -q 'rc=3' && ok "live lock beside the target refuses (exit 3) although ZUVO_DIR points elsewhere" || bad "lock not taken beside the target"
[ "$(cksum < "$TMP/a/retros.log")" = "$sum_a" ] && ok "target untouched while its own lock is held" || bad "target rewritten under a live lock"
rm -f "$TMP/a/.retro.lock.d/pid"; rmdir "$TMP/a/.retro.lock.d"

echo "=== refuses (exit 4) a rewrite that would leave fewer RETRO rows than the high-water ==="
# Bug caught: sanitizing a truncated log overwrote the last .pre-sanitize backup and cemented the loss.
mkdir -p "$TMP/b"
printf 'RETRO: skill=plan project=X at=2026-05-29T11:00:00Z\nRETRO: skill=plan project=Y at=2026-05-30T11:00:00Z\n' > "$TMP/b/retros.log"
printf 'rows=5\nbytes=999\nat=2026-05-30T12:00:00Z\n' > "$TMP/b/.retros-highwater"
sum_b=$(cksum < "$TMP/b/retros.log")
r=$(python3 "$S" --apply --target "$TMP/b/retros.log" 2>&1; echo "rc=$?")
printf '%s' "$r" | grep -q 'rc=4' && ok "exit 4 when output rows (2) < high-water (5)" || bad "no refusal below the high-water: $r"
printf '%s' "$r" | grep -q 'operating.md §12' && ok "refusal names the recovery runbook section" || bad "refusal does not name operating.md §12"
[ "$(cksum < "$TMP/b/retros.log")" = "$sum_b" ] && ok "refused file is byte-identical" || bad "refused file changed"
[ ! -e "$TMP/b/retros.log.pre-sanitize" ] && ok "no .pre-sanitize written on refusal" || bad ".pre-sanitize overwritten on refusal"
[ ! -d "$TMP/b/.retro.lock.d" ] && ok "lock released after refusal" || bad "lock leaked after refusal"
printf 'rows=2\n' > "$TMP/b/.retros-highwater"
python3 "$S" --apply --target "$TMP/b/retros.log" >/dev/null 2>&1
[ "$(cksum < "$TMP/b/retros.log")" != "$sum_b" ] && ok "at the high-water the rewrite proceeds" || bad "rewrite blocked at the high-water"

echo "=== high-water is read exactly as append-retro reads it ==="
# Bug caught: trimming the value let "rows=5 " count as 5 and block a rewrite append-retro treats as
# no high-water at all; a non-ASCII digit must read as 0 as well.
for hw in 'rows=5 ' 'rows=٥'; do
  mkdir -p "$TMP/c"
  printf 'RETRO: skill=plan project=X at=2026-05-29T11:00:00Z\n' > "$TMP/c/retros.log"
  printf '%s\n' "$hw" > "$TMP/c/.retros-highwater"
  sum_c=$(cksum < "$TMP/c/retros.log")
  python3 "$S" --apply --target "$TMP/c/retros.log" >/dev/null 2>&1
  [ "$(cksum < "$TMP/c/retros.log")" != "$sum_c" ] && ok "high-water '$hw' reads as 0, rewrite proceeds" || bad "high-water '$hw' blocked the rewrite"
  chflags nouappnd "$TMP/c/retros.log" 2>/dev/null
done

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
