#!/usr/bin/env bash
# fleet-retro-pull.py --restore-self — pull THIS install's own rollups back down from the collector
# for days the local retros.log no longer covers.
#
# Why it exists: on 2026-08-15 11:17 ~/.zuvo/retros.log and retros.md were rewritten in the same
# second; the log went 143486 -> 70167 bytes and lost 02-11.08 with no archive anywhere in ~/.zuvo.
# `rotate-retros` was NOT responsible (its own log says "0 older than 90 days", and its launchd job
# runs weekly, last on 08-13). The collector was the only surviving copy — 717 rollups.
#
# The two things this suite actually guards:
#   1. THE OVERLAP FENCE. Rollups are AGGREGATES. Re-importing a day the local log still covers
#      double-counts those runs in retro-mine, and the second count is indistinguishable from real
#      activity. The fence defaults to the oldest day retros.log still holds, so overlap is
#      impossible by construction rather than by remembering to pass a flag.
#   2. THE DESTINATION. Restored rows are lossy reconstructions — the rollup never carried project,
#      note, branch or sha7 — so they go to remote/self/<anon8>/, never into retros.log, where they
#      would be indistinguishable from real rows.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/scripts/zuvo-home/fleet-retro-pull.py"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

[ -f "$SRC" ] || { bad "fleet-retro-pull.py missing"; echo "FAILED: 1"; exit 1; }
python3 -c "import ast,sys; ast.parse(open('$SRC',encoding='utf-8').read())" 2>/dev/null \
  && ok "script parses" || bad "script does not parse"

echo "=== overlap fence + destination (collector stubbed) ==="
ZUVO_HOME="$TMP/zuvo" python3 - "$SRC" <<'PY'
import sys, os, json, io, types

src_path = sys.argv[1]
zuvo = os.environ["ZUVO_HOME"]
os.makedirs(zuvo, exist_ok=True)

# A local log that still covers 08-12..08-13 — so 08-12 and later must NOT be re-imported.
with open(os.path.join(zuvo, "retros.log"), "w", encoding="utf-8") as fh:
    for d in ("2026-08-12", "2026-08-13"):
        fh.write("RETRO: %sT00:00:00Z\tship\tp\tOTHER\tother\tN/A\tnone\t1\t1\t1\t1\tmain\tabc1234\tN/A\tN/A\tN/A\tok\n" % d)

g = {"__name__": "stub"}
exec(compile(open(src_path, encoding="utf-8").read(), src_path, "exec"), g)

fails = []
def check(cond, msg):
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond: fails.append(msg)

check(g["local_earliest_day"]() == "2026-08-12",
      "fence auto-detects the oldest day retros.log still holds (2026-08-12)")

# Stub the collector: one own rollup per day across the boundary.
MINE = "aaaabbbb-1111-2222-3333-444455556666"
def fake_fetch(_vps):
    out = []
    for day in ("2026-08-09", "2026-08-11", "2026-08-12", "2026-08-14"):
        out.append(json.dumps({"anon_id": MINE, "payload": {"anon_id": MINE, "retros": [
            {"day": day, "skill": "refactor", "code_type": "OTHER", "friction": "other",
             "context_gap": "none", "count": 2}]}}))
    return "\n".join(out)
g["fetch"] = fake_fetch
g["collector_ssh"] = lambda: "stub@collector"
g["local_anon_id"] = lambda: MINE

buf = io.StringIO(); real = sys.stdout; sys.stdout = buf
sys.argv = ["fleet-retro-pull.py", "--restore-self"]
rc = g["main"]()
sys.stdout = real
out = buf.getvalue()

self_dir = os.path.join(zuvo, "remote", "self")
fleet_dir = os.path.join(zuvo, "remote", "fleet")
check(rc == 0, "restore-self exits 0")
check(os.path.isdir(self_dir), "wrote under remote/self/")
check(not os.path.isdir(fleet_dir), "did NOT write under remote/fleet/ (own data is not foreign)")

lines = []
for dp, _dn, fn in os.walk(self_dir):
    for f in fn:
        lines += [l for l in open(os.path.join(dp, f), encoding="utf-8") if l.startswith("RETRO:")]
days = sorted({l[6:].strip().split("\t")[0][:10] for l in lines})
check(days == ["2026-08-09", "2026-08-11"],
      "imported ONLY days before the fence (got %s)" % days)
check(len(lines) == 4, "count:2 expanded to 2 rows per day, 4 total (got %d)" % len(lines))

# The printed path must match where the file actually went — a summary naming remote/fleet/ while
# writing remote/self/ is the kind of output that sends the next reader to an empty directory.
check("remote/self/" in out, "printed destination says remote/self/")
check("remote/fleet/" not in out, "printed destination does not claim remote/fleet/")
check("own (restored)" in out, "summary calls this an own restore, not a foreign install")

# Fence must be refuseable-but-not-guessable: no local log and no --before => refuse.
os.remove(os.path.join(zuvo, "retros.log"))
buf2 = io.StringIO(); err = sys.stderr; sys.stderr = buf2
sys.argv = ["fleet-retro-pull.py", "--restore-self"]
rc2 = g["main"]()
sys.stderr = err
check(rc2 == 1, "refuses when the fence cannot be derived (no retros.log, no --before)")
check("--before" in buf2.getvalue(), "and says how to supply the fence")

# Without --restore-self the own rollups must still be SKIPPED — no regression in the normal path.
with open(os.path.join(zuvo, "retros.log"), "w", encoding="utf-8") as fh:
    fh.write("RETRO: 2026-08-12T00:00:00Z\tship\tp\tOTHER\tother\tN/A\tnone\t1\t1\t1\t1\tmain\tabc1234\tN/A\tN/A\tN/A\tok\n")
buf3 = io.StringIO(); real = sys.stdout; sys.stdout = buf3
sys.argv = ["fleet-retro-pull.py"]
g["main"]()
sys.stdout = real
check("own uploads skipped: 4" in buf3.getvalue() or "0 foreign" in buf3.getvalue(),
      "normal mode still skips own uploads")

sys.exit(1 if fails else 0)
PY
[ $? -eq 0 ] && ok "restore-self behaviour verified end to end" || bad "restore-self behaviour assertions failed"

echo ""
if [ "$fails" -eq 0 ]; then echo "ALL PASS"; else echo "FAILED: $fails"; exit 1; fi
