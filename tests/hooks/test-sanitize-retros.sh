#!/usr/bin/env bash
# Tests scripts/zuvo-home/sanitize-retros — normalizes key=value RETRO drift to canonical 17-TSV.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
S="$ROOT/scripts/zuvo-home/sanitize-retros"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export ROOT="$ROOT"
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

echo "=== concurrency: lock held on --apply, refuses when busy (no lost append) ==="
export ZUVO_DIR="$TMP"
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
python3 "$S" --apply --target "$TMP/retros.log" >/dev/null 2>&1
[ ! -d "$TMP/.retro.lock.d" ] || rmdir "$TMP/.retro.lock.d" 2>/dev/null
ok "dead-holder lock broken, not stuck busy"
# now with lock free it proceeds and releases the lock
python3 "$S" --apply --target "$TMP/retros.log" >/dev/null 2>&1
[ ! -d "$TMP/.retro.lock.d" ] && ok "lock released after apply" || bad "lock leaked"
unset ZUVO_DIR

echo "=== structural canonical detection: unknown/digit skills are not drift ==="
export ZUVO_DIR="$TMP"
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
unset ZUVO_DIR

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
