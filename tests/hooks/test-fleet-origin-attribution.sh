#!/usr/bin/env bash
# Foreign-host retros: attribute them, and stop writing counts into verdict columns.
#
# Two defects, both measured on the live corpus on 2026-08-29, both of which made the fleet
# uplink produce data nobody could act on:
#
#   1. retro-mine.py's `mine_retros_log(path, origin)` accepted `origin` and never used it. Every
#      row — this Mac's 2132, a popebot's 68, four anonymous fleet installs' 160 — landed in the
#      same two anonymous Counters, so the weekly digest could not say whether a friction pattern
#      was ours or a stranger's. That distinction is the entire reason the uplink exists.
#
#   2. fleet-retro-pull.py wrote `blind=N` / `adv=N` into canonical columns 14 (BLIND_AUDIT) and
#      15 (ADVERSARIAL), which are VERDICT enums. The rollup carries a RAN-COUNT and no verdict,
#      so all 759 fleet-origin rows held values outside the enum and "the review ran and came back
#      clean" was indistinguishable from "the review never ran". A rollup is also not uniform:
#      `count: 4, adversarial_ran: 2` means two of those four runs ran it — so ONE repeated line
#      cannot state the bucket honestly, and the expansion has to split.
#
# What this suite guards, in one sentence each:
#   T1  the bucket split is exact (ran -> ran:unknown, remainder -> not_run)
#   T2  every value the puller emits is accepted by append-retro's validator (no enum drift)
#   T3  an absent field is N/A, and an untrusted ran-count cannot exceed the bucket
#   T4  the miner separates origins while leaving the global totals untouched
#   T5  a malformed line is COUNTED, not silently dropped
#   T6  the digest headings other tools parse are unchanged, and in the same order
#   T7  rows already on disk in the old `blind=0`/`adv=1` shape still mine without error
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PULL="$ROOT/scripts/zuvo-home/fleet-retro-pull.py"
MINE="$ROOT/scripts/zuvo-home/retro-mine.py"
APPEND="$ROOT/scripts/zuvo-home/append-retro"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0
ok(){ echo "  ✓ $1"; }
bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

for f in "$PULL" "$MINE" "$APPEND"; do
  [ -f "$f" ] || { bad "missing: $f"; echo "FAILED: 1"; exit 1; }
done
python3 -c "import ast,sys; [ast.parse(open(p,encoding='utf-8').read()) for p in sys.argv[1:]]" \
  "$PULL" "$MINE" && ok "both python helpers parse" || bad "a python helper does not parse"
bash -n "$APPEND" && ok "append-retro parses" || bad "append-retro does not parse"

echo "=== T1-T3: puller emits enum-valid verdicts, split per bucket ==="
ZUVO_HOME="$TMP/pull" python3 - "$PULL" > "$TMP/pull.out" <<'PY'
import sys, os, json, io

src = sys.argv[1]
zuvo = os.environ["ZUVO_HOME"]; os.makedirs(zuvo, exist_ok=True)
g = {"__name__": "stub"}
exec(compile(open(src, encoding="utf-8").read(), src, "exec"), g)

fails = []
def check(cond, msg):
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond: fails.append(msg)

FOREIGN = "ffffffff-1111-2222-3333-444455556666"
def rollups(rs):
    return json.dumps({"anon_id": FOREIGN,
                       "payload": {"anon_id": FOREIGN, "retros": rs}})

def run(rs):
    """One pull into a FRESH tree.

    Every call used to share one ZUVO_HOME and then walk it whole, so `over`/`absent`/`junk` each
    read whatever earlier cases had left behind. It happened to pass — the puller rewrites each
    install's file atomically — but the assertions claimed isolation they did not have, and the
    set-based distinguishability check could have stayed green on stale rows alone.
    """
    import shutil
    fleet = os.path.join(zuvo, "remote", "fleet")
    shutil.rmtree(fleet, ignore_errors=True)
    g["fetch"] = lambda _vps, _rs=rs: rollups(_rs)
    g["collector_ssh"] = lambda: "stub@collector"
    g["local_anon_id"] = lambda: "aaaaaaaa-0000-0000-0000-000000000000"
    buf = io.StringIO(); real = sys.stdout; sys.stdout = buf
    sys.argv = ["fleet-retro-pull.py"]
    rc = g["main"]()
    sys.stdout = real
    out = []
    for dp, _dn, fn in os.walk(fleet):
        for f in fn:
            with open(os.path.join(dp, f), encoding="utf-8") as fh:
                out += [l.rstrip("\n") for l in fh if l.startswith("RETRO:")]
    return rc, out

def cols(lines):
    """(BLIND, ADVERSARIAL) of every row — canonical fields 14 and 15, 1-indexed."""
    return [(l[6:].strip().split("\t")[13], l[6:].strip().split("\t")[14]) for l in lines]

base = {"day": "2026-08-20", "skill": "refactor", "code_type": "OTHER",
        "friction": "other", "context_gap": "none"}

# T1 — a bucket of 4 where the review ran on 2 of them must produce exactly 2 + 2.
rc, lines = run([dict(base, count=4, adversarial_ran=2, blind_audit_ran=0)])
adv = sorted(c[1] for c in cols(lines))
blind = sorted(c[0] for c in cols(lines))
check(rc == 0 and len(lines) == 4, "count:4 still expands to 4 rows (got %d)" % len(lines))
check(adv == ["not_run", "not_run", "ran:unknown", "ran:unknown"],
      "adversarial_ran:2 of 4 -> 2x ran:unknown + 2x not_run (got %s)" % adv)
check(blind == ["not_run"] * 4,
      "blind_audit_ran:0 of 4 -> 4x not_run, never a value that reads as a verdict (got %s)" % blind)
check(not any("adv=" in l or "blind=" in l for l in lines),
      "no row carries the old count shape (blind=N / adv=N)")

# The whole point: 'ran and clean' and 'never ran' must not collapse to one value.
_, ran_all = run([dict(base, day="2026-08-21", count=2, adversarial_ran=2, blind_audit_ran=2)])
_, ran_none = run([dict(base, day="2026-08-22", count=2, adversarial_ran=0, blind_audit_ran=0)])
check({c[1] for c in cols(ran_all)} != {c[1] for c in cols(ran_none)},
      "a bucket where the step ran is distinguishable from one where it did not")

# T3 — absent field is N/A (not a fabricated verdict); an untrusted ran-count cannot exceed count.
_, absent = run([dict(base, day="2026-08-23", count=2)])
check(all(c == ("N/A", "N/A") for c in cols(absent)),
      "a rollup with neither field set writes N/A in both columns (got %s)" % cols(absent))
_, over = run([dict(base, day="2026-08-24", count=2, adversarial_ran=999, blind_audit_ran=-5)])
check([c[1] for c in cols(over)] == ["ran:unknown", "ran:unknown"],
      "ran-count above count is clamped to the bucket, never emits extra rows")
check([c[0] for c in cols(over)] == ["not_run", "not_run"],
      "a negative ran-count clamps to 0 rather than raising")
_, junk = run([dict(base, day="2026-08-25", count=2, adversarial_ran="lots")])
check(len(junk) == 2, "a non-numeric ran-count does not kill the pull (got %d rows)" % len(junk))
check([c[1] for c in cols(junk)] == ["N/A", "N/A"],
      "an unusable ran-count writes N/A, NOT not_run — garbage must not read as "
      "'the step applies and nobody ran it' (got %s)" % [c[1] for c in cols(junk)])
_, frac = run([dict(base, day="2026-08-26", count=2, blind_audit_ran=1.5)])
check([c[0] for c in cols(frac)] == ["N/A", "N/A"],
      "a fractional ran-count is rejected, not floored (got %s)" % [c[0] for c in cols(frac)])
_, boolean = run([dict(base, day="2026-08-27", count=2, adversarial_ran=True)])
check([c[1] for c in cols(boolean)] == ["N/A", "N/A"],
      "a bool is not a run count even though bool subclasses int (got %s)"
      % [c[1] for c in cols(boolean)])

# T2 — hand the validator every distinct value the puller can now write.
vals = set()
for lines_ in (lines, ran_all, ran_none, absent, over, junk, frac, boolean):
    for b, a in cols(lines_): vals.add(("blind", b)); vals.add(("adv", a))
with open(os.path.join(zuvo, "emitted-values.txt"), "w", encoding="utf-8") as fh:
    for kind, v in sorted(vals): fh.write(f"{kind}\t{v}\n")
check(vals, "collected the emitted column values for the validator round-trip")

print("PYFAILS:%d" % len(fails))
PY
cat "$TMP/pull.out" | sed '/^PYFAILS:/d'
pf="$(sed -n 's/^PYFAILS:\([0-9]*\)$/\1/p' "$TMP/pull.out")"
[ "${pf:-1}" = "0" ] && ok "puller: all bucket-split assertions passed" \
                     || bad "puller: ${pf:-?} assertion(s) failed"

echo "=== T2: every emitted value survives append-retro's validator ==="
VALS="$TMP/pull/emitted-values.txt"
if [ -s "$VALS" ]; then
  drift=0
  while IFS="$(printf '\t')" read -r kind val; do
    [ -n "${val:-}" ] || continue
    if [ "$kind" = "blind" ]; then flag="--blind-audit=$val"; else flag="--adversarial=$val"; fi
    ZUVO_HOME="$TMP/validate" bash "$APPEND" --skill=refactor --project=p --code-type=OTHER \
      --friction=other --context-gap=none --turns=1 --tool-calls=1 --files-read=1 \
      --files-modified=1 --branch=main --sha7=abc1234 "$flag" >/dev/null 2>"$TMP/verr" \
      || { bad "append-retro REJECTS a value the puller writes: $flag ($(head -1 "$TMP/verr"))"; drift=1; }
  done < "$VALS"
  [ "$drift" = "0" ] && ok "no enum drift: every puller-emitted column value validates"
else
  bad "puller wrote no values to round-trip through the validator"
fi

echo "=== T4-T7: miner attributes origins and counts what it cannot read ==="
ZUVO_HOME="$TMP/mine-unused" HOME="$TMP/minehome" python3 - "$MINE" > "$TMP/mine.out" <<'PY'
import sys, os, io, datetime, subprocess

src = sys.argv[1]
home = os.environ["HOME"]
zuvo = os.path.join(home, ".zuvo")
os.makedirs(os.path.join(zuvo, "remote", "fleet", "aaaa1111"), exist_ok=True)
os.makedirs(os.path.join(zuvo, "remote", "popebot", "bbbb2222"), exist_ok=True)
today = datetime.datetime.now(datetime.timezone.utc).date().isoformat()  # rows are stamped Z;
# using the LOCAL date here puts the fixture on a different UTC day near midnight in a
# non-UTC timezone, and the window assertions then fail for a reason that is not the code.

def row(skill, friction, day=today):
    return ("RETRO: %sT00:00:00Z\t%s\tp\tOTHER\t%s\tN/A\tnone\t1\t1\t1\t1\tmain\tabc1234\t"
            "N/A\tN/A\tN/A\tok\n" % (day, skill, friction))

# Local rows.
with open(os.path.join(zuvo, "retros.log"), "w", encoding="utf-8") as fh:
    fh.write(row("ship", "pipeline-heavy"))
    fh.write(row("ship", "pipeline-heavy"))
    # T5 — the exact 4-field shape that exists in the real corpus (SKILL and DATE transposed).
    fh.write("RETRO: security-audit\t%sT00:00:00Z\tp\tHEALTHY 92/100\n" % today)

# T7 — a foreign install's rows in the OLD on-disk shape (blind=0/adv=1) must still mine.
with open(os.path.join(zuvo, "remote", "fleet", "aaaa1111", "retros.log"), "w", encoding="utf-8") as fh:
    fh.write(row("execute", "infra-failure").replace("\tN/A\tN/A\tN/A\tok", "\tblind=0\tadv=1\tindexed\tok"))

with open(os.path.join(zuvo, "remote", "popebot", "bbbb2222", "retros.log"), "w", encoding="utf-8") as fh:
    fh.write(row("refactor", "scope-mismatch"))

env = dict(os.environ, HOME=home)
p = subprocess.run([sys.executable, src, "--days", "3"], capture_output=True, text=True, env=env)
out = p.stdout
digest = os.path.join(zuvo, "mining", "digest-%s.md" % datetime.date.today())   # the miner names it by LOCAL date
body = open(digest, encoding="utf-8").read() if os.path.exists(digest) else ""

fails = []
def check(cond, msg):
    print(("  ✓ " if cond else "  ✗ ") + msg)
    if not cond: fails.append(msg)

check(p.returncode == 0, "miner exits 0 (rc=%d, stderr=%s)" % (p.returncode, p.stderr[-200:]))

# T4 — origins separated, global totals unchanged.
check("## Origin breakdown" in body, "digest carries an Origin breakdown section")
check("| mac | 2 |" in body, "mac's 2 rows attributed to mac (not pooled)")
check("| fleet:fleet/aaaa1111 | 1 |" in body, "the anonymous fleet install is its own row")
check("| fleet:popebot/bbbb2222 | 1 |" in body, "the popebot install is its own row")
check("rows-by-source" in out and "'mac': 2" in out,
      "stdout summary reports rows by source (got %r)" % [l for l in out.splitlines() if "source" in l])
# Globals must still see all four canonical rows: 2 mac + 1 fleet + 1 popebot.
check("4x ship" not in body and "2x ship" in body, "global Skills histogram unchanged (2x ship)")
check("1x execute" in body and "1x refactor" in body, "global histogram still includes foreign rows")

# T5 — malformed counted, not silently dropped.
check("malformed=1" in out, "the 4-field line is COUNTED as malformed on stdout")
check("malformed retro line(s) skipped" in body, "and named in the digest, not dropped in silence")
check("| mac | 2 | 1 |" in body, "attributed to the origin it came from")

# T7 — old-shape rows still mined.
check("1x infra-failure" in body, "a legacy blind=0/adv=1 row still mines (backward compatible)")

# T6 — the headings other tools parse are unchanged and still in order.
order = [l.split(" (")[0] for l in body.splitlines() if l.startswith("## ")]
def pos(h):
    return order.index(h) if h in order else -1
check(-1 not in (pos("## Skills"), pos("## Origin breakdown"), pos("## Change proposals")),
      "all three ordered headings are present (got %s)" % order)
check(pos("## Skills") < pos("## Origin breakdown") < pos("## Change proposals"),
      "Origin breakdown sits AFTER Skills and BEFORE Change proposals — the placement that keeps "
      "digest-proposals' last-block trailing swallow unchanged (got %s)" % order)
check(any(o.startswith("## Change proposals") for o in order), "## Change proposals still present")
check(any(o.startswith("## Backlog health") for o in order), "## Backlog health still present")
check(any(o.startswith("## New ideas") for o in order), "## New ideas still present")

print("PYFAILS:%d" % len(fails))
PY
cat "$TMP/mine.out" | sed '/^PYFAILS:/d'
mf="$(sed -n 's/^PYFAILS:\([0-9]*\)$/\1/p' "$TMP/mine.out")"
[ "${mf:-1}" = "0" ] && ok "miner: all origin-attribution assertions passed" \
                     || bad "miner: ${mf:-?} assertion(s) failed"

echo "=== schema SSOT carries the value the code emits ==="
SPEC="$ROOT/shared/includes/retrospective.md"
# Counting occurrences proves nothing: two mentions in prose satisfy it while a field row stays
# wrong, and both mentions on one line fail it. Match each field's own table row.
for fld in 14 15; do
  if grep -E "^\| $fld \| (BLIND_AUDIT|ADVERSARIAL) \|" "$SPEC" | grep -q 'ran:unknown'; then
    ok "field $fld's schema ROW documents ran:unknown"
  else
    bad "field $fld's schema row omits ran:unknown (schema and validator disagree)"
  fi
done

echo
if [ "$fails" -eq 0 ]; then echo "PASSED"; else echo "FAILED: $fails"; fi
exit "$fails"
