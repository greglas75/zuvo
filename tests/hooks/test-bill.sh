#!/usr/bin/env bash
# Tests ~/.zuvo/bill (scripts/zuvo-home/bill), the judge of untriaged adversarial findings.
# Each case names the defect it catches. The model call and the ledger driver are stand-in scripts
# on PATH / in ZUVO_HOME; everything else is Bill's real code, imported as a module.
# Level: medium — real files and subprocesses in a temp ZUVO_HOME.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/zh/adversarial-inputs" "$TMP/proj/.git"   # proj: a git checkout, as Bill records from one

python3 - "$ROOT/scripts/zuvo-home/bill" "$TMP" <<'PY'
import json, os, stat, sys
from datetime import datetime, timedelta, timezone

bill_path, tmp = sys.argv[1], sys.argv[2]
zh, binp, proj = f"{tmp}/zh", f"{tmp}/bin", f"{tmp}/proj"
# BILL_MODEL pins the claude path the fake below answers: Bill's default is a gpt-* model, which goes
# through codex — the real, paid CLI where one is installed. A codex on PATH that only fails keeps it so.
os.environ.update(ZUVO_HOME=zh, BILL_MAX_TRIES="3", BILL_MIN_AGE_MINUTES="30", BILL_MAX_AGE_HOURS="48",
                  BILL_MODEL="claude-test", PATH=f"{binp}:{os.environ.get('PATH', '/usr/bin:/bin')}")
sys.path.insert(0, os.path.dirname(bill_path))   # Bill's logic: flat modules beside the launcher
import types, zuvo_bill_config, zuvo_bill_judge, zuvo_bill_tick
bill = types.SimpleNamespace(LEDGER=zuvo_bill_config.ledger(), BD=zuvo_bill_config.bill_data(),
                             read_ledger=zuvo_bill_tick.read_ledger, pending=zuvo_bill_tick.pending,
                             judge=zuvo_bill_judge.judge, settle=zuvo_bill_tick.settle)
os.makedirs(bill.BD, exist_ok=True)

fails = 0
def check(name, cond, detail=""):
    global fails
    print(("  ✓ " if cond else "  ✗ ") + name + ("" if cond else f" — {detail}"))
    fails += 0 if cond else 1

def ago(**kw):
    return (datetime.now(timezone.utc) - timedelta(**kw)).strftime("%Y-%m-%dT%H:%M:%SZ")

def script(path, body):
    with open(path, "w") as f:
        f.write("#!/bin/sh\n" + body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IEXEC)

def fake_claude(stdout):
    with open(f"{tmp}/claude.out", "w") as f:
        f.write(stdout if isinstance(stdout, str) else json.dumps(stdout))
    script(f"{binp}/claude", f"cat >/dev/null; cat {tmp}/claude.out\n")

script(f"{binp}/codex", "echo 'test-bill: the real codex must never be called' >&2; exit 97\n")

def row(ts, run, fp, disp="new", lane="codex", mode="code"):
    return "\t".join([ts, run, mode, lane, "m", fp, "WARNING", "80", "a.py", disp, proj])

print("=== read_ledger + pending: what gets judged ===")
with open(bill.LEDGER, "w") as f:
    f.write("\n".join([
        "date\trun\tmode\tlane\tmodel\tfp\tsev\tconf\tfile\tdisp\tproject",
        row(ago(hours=2), "r-ok", "a.py:1:x"),
        row(ago(hours=2), "r-ok", "a.py:2:y", lane="mock-codex"),     # a test lane, never judged
        row(ago(hours=3), "r-docs", "a.py:3:z", mode="docs"),          # not a code review
        row(ago(minutes=5), "r-young", "a.py:4:w"),                    # its agent is still triaging
        row(ago(hours=72), "r-old", "a.py:5:v"),                       # outside the window
        row(ago(hours=2), "r-judged", "a.py:6:u"),
        row(ago(hours=1), "r-judged", "a.py:6:u", disp="fixed"),       # the agent already ruled
        row(ago(hours=1), "r-nodiff", "a.py:7:t"),
    ]) + "\n")
for r in ("r-ok", "r-docs", "r-young", "r-old", "r-judged"):
    open(f"{zh}/adversarial-inputs/{r}.diff", "w").write("+x = 1\n")
runs, judged = bill.read_ledger()
check("a mock lane's finding is never queued (catches judging the test fixtures)",
      [x["id"] for x in runs["r-ok"]["rows"]] == ["a.py:1:x"], runs.get("r-ok"))
check("rows older than the window are not held in memory (catches unbounded ledger growth)", "r-old" not in runs)
check("a fixed/deferred/rejected row marks its finding judged", (proj, "a.py:6:u") in judged)
q = [x[1] for x in bill.pending(runs, judged, done={"r-done"})]
check("only r-ok is due: young, judged, diff-less and non-code runs are skipped", q == ["r-ok"], q)

print("=== judge: limit detection reads the CLI's error, not the parse error ===")
item = (ago(hours=2), "r-ok", proj, runs["r-ok"]["rows"])
fake_claude("not json at column 1429")
rec, _ = bill.judge(item)
check("a parse error mentioning 1429 is a failed attempt, not a rate limit (catches a tick stopped by '429' in text)",
      "error" in rec and rec["limited"] is False, rec)
fake_claude({"is_error": True, "result": "Claude AI usage limit reached"})
rec, _ = bill.judge(item)
check("the CLI's own usage-limit error stops the tick", rec["limited"] is True, rec)
fake_claude({"result": json.dumps({"defects": None})})
rec, _ = bill.judge(item)
check("a malformed verdict object is a failed attempt, not a crash in record()", "error" in rec and "verdicts" not in rec, rec)

print("=== settle: retries are capped, verdicts land once ===")
done_f = f"{bill.BD}/judged-runs.txt"
attempts = {}
for n in range(3):
    bill.settle({"run": "r-bad", "project": proj, "findings": 1, "error": "timeout"}, [], attempts, done_f)
check("after BILL_MAX_TRIES failed attempts the run is given up (catches a paid call every tick for 48 h)",
      open(done_f).read().split() == ["r-bad"] and "r-bad" not in attempts, (open(done_f).read(), attempts))
for n in range(4):
    bill.settle({"run": "r-limited", "project": proj, "findings": 1, "error": "x", "limited": True}, [], attempts, done_f)
check("a rate-limited call does not use up the run's tries (catches giving up a review the account could not run)",
      "r-limited" not in open(done_f).read().split() and "r-limited" not in attempts, attempts)

rows = [{"id": "a.py:1:x", "lane": "codex"}, {"id": "a.py:2:y", "lane": "kimi"}, {"id": "a.py:3:z", "lane": "agy"},
        {"id": "a.py:6:u", "lane": "codex"}]   # a.py:6:u: the agent recorded `fixed` (ledger fixture)
verdicts = {"defects": [
    {"verdict": "real", "finding_ids": ["a.py:1:x", "forged:9:id", "a.py:6:u"]},
    {"verdict": "false_positive", "finding_ids": ["a.py:2:y"]},
    {"verdict": "uncertain", "finding_ids": ["a.py:3:z"]}], "lessons": ["l1"]}
script(f"{zh}/adversarial-review", f"echo \"$@\" > {tmp}/driver.args; exit 1\n")
rec = bill.settle({"run": "r-ok", "project": proj, "findings": 3, "verdicts": json.loads(json.dumps(verdicts))},
                  rows, attempts, done_f)
check("a ledger write the driver refused is retried, not marked done (catches verdicts lost after a paid call)",
      "r-ok" not in open(done_f).read().split() and attempts.get("r-ok") == 1, rec)
check("…and no defect rows are written for it yet (catches duplicates on the retry)",
      not os.path.exists(f"{bill.BD}/defects.jsonl"))
script(f"{zh}/adversarial-review", f"echo \"$@\" > {tmp}/driver.args; exit 0\n")
bill.settle({"run": "r-ok", "project": proj, "findings": 3, "verdicts": json.loads(json.dumps(verdicts))},
            rows, attempts, done_f)
args = open(f"{tmp}/driver.args").read().split()
check("real -> deferred, false_positive -> rejected, uncertain -> nothing; a forged id and one the agent already judged are left alone",
      args == ["--record-disposition", "a.py:1:x", "deferred", "--record-disposition", "a.py:2:y", "rejected"], args)
check("a recorded run is done and its 3 defects are written once",
      "r-ok" in open(done_f).read().split() and len(open(f"{bill.BD}/defects.jsonl").readlines()) == 3)

print("=== RESULT ===")
print("ALL PASS" if fails == 0 else f"{fails} FAILED")
sys.exit(1 if fails else 0)
PY
