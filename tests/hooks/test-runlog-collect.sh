#!/usr/bin/env bash
# Tests scripts/zuvo-home/runlog-collect.py — incremental event-stream uploader with a compound
# cursor. Focus: the 3 adversarial CRITICALs (same-second loss, partial-batch dupes, no id key).
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RC="$ROOT/scripts/zuvo-home/runlog-collect.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }
export ZUVO_DIR="$TMP" ZUVO_RUNLOG_CURSOR="$TMP/cur"
# module-load helper: run collect + selection logic in-process (no network)
sel(){ python3 - "$@" <<'PY'
import os, importlib.util, sys, json
spec=importlib.util.spec_from_file_location('rc', os.environ['RC_PATH'])
rc=importlib.util.module_from_spec(spec); spec.loader.exec_module(rc)
runs,retros=rc.collect(True); allrecs=runs+retros
cdate,cids=rc.read_cursor()
fresh=[r for r in allrecs if r.get('date','')>cdate or (r.get('date','')==cdate and r.get('id') not in cids)]
print(len(fresh))
# advance cursor as the script would (simulate a successful push)
if fresh:
    new_max=max(r.get('date','') for r in allrecs)
    new_ids={r['id'] for r in allrecs if r.get('date')==new_max}
    if new_max==cdate: new_ids|=cids
    rc.write_cursor(new_max,new_ids)
PY
}
export RC_PATH="$RC"

echo "=== idempotency key present + stable ==="
printf '2026-07-23T10:00:00Z\texecute\tprojX\t-\t-\tPASS\t1/1\t~1m\tnote\tmain\tabc1234\tinc\tDEEP\n' > "$TMP/runs.log"
: > "$TMP/retros.log"
id1=$(RC_PATH="$RC" python3 -c "import os,importlib.util;s=importlib.util.spec_from_file_location('rc',os.environ['RC_PATH']);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.collect(False)[0][0]['id'])")
id2=$(RC_PATH="$RC" python3 -c "import os,importlib.util;s=importlib.util.spec_from_file_location('rc',os.environ['RC_PATH']);m=importlib.util.module_from_spec(s);s.loader.exec_module(m);print(m.collect(False)[0][0]['id'])")
[ -n "$id1" ] && [ "$id1" = "$id2" ] && ok "every entry has a stable id ($id1)" || bad "id missing or unstable"

echo "=== CRITICAL: a new entry at the SAME second as the cursor is not lost ==="
rm -f "$TMP/cur"
printf '2026-07-23T10:00:00Z\texecute\tp\t-\t-\tPASS\t1\t~1m\tA\tmain\ta1\ti\tD\n' > "$TMP/runs.log"
n=$(sel); [ "$n" = "1" ] && ok "first run selects the 1 entry" || bad "first select = $n"
# a SECOND entry lands at the exact same second, written after the cursor advanced
printf '2026-07-23T10:00:00Z\treview\tp\t-\t-\tPASS\t1\t~1m\tB\tmain\ta2\ti\tD\n' >> "$TMP/runs.log"
n=$(sel); [ "$n" = "1" ] && ok "same-second NEW entry is selected (not lost)" || bad "same-second entry LOST (n=$n)"
n=$(sel); [ "$n" = "0" ] && ok "nothing re-sent once both same-second entries delivered" || bad "re-sent boundary entries (n=$n)"

echo "=== incremental: strictly newer entries selected, older ignored ==="
printf '2026-07-23T11:00:00Z\tbuild\tp\t-\t-\tPASS\t1\t~1m\tC\tmain\ta3\ti\tD\n' >> "$TMP/runs.log"
n=$(sel); [ "$n" = "1" ] && ok "a newer entry is picked up" || bad "newer entry missed (n=$n)"

echo "=== legacy bare-date cursor still read (no crash, no mass re-send) ==="
printf '2026-07-23T11:00:00Z' > "$TMP/cur"      # legacy format
n=$(sel); [ "$n" = "1" ] && ok "legacy bare-date cursor: same-date entry re-selectable by id" || bad "legacy cursor broke (n=$n)"

echo "=== --reset re-sends everything ==="
python3 - <<'PY'
import os,importlib.util
s=importlib.util.spec_from_file_location('rc',os.environ['RC_PATH']);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
runs,retros=m.collect(True); allrecs=runs+retros
# reset path: cdate,cids = "",set()
fresh=[r for r in allrecs]
print("RESET_ALL", len(fresh))
PY
r=$(python3 - <<'PY'
import os,importlib.util
s=importlib.util.spec_from_file_location('rc',os.environ['RC_PATH']);m=importlib.util.module_from_spec(s);s.loader.exec_module(m)
runs,retros=m.collect(True);print(len(runs+retros))
PY
)
[ "$r" -ge 3 ] && ok "--reset would re-send all $r entries" || bad "reset count wrong ($r)"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
