#!/usr/bin/env python3
"""Push this host's zuvo runs.log (and retros.log) telemetry to the shared collector.

Runs UNCHANGED on the Mac and on the VPS/bot hosts. Companion to backlog-collect.py, but a
DIFFERENT storage model: backlog is a per-host SNAPSHOT (overwrite), runs.log is an EVENT STREAM
— each run is a distinct event that must be sent ONCE and never re-sent. So this uploader is
INCREMENTAL: it keeps a cursor (the ISO date of the last run already uploaded) and sends only
entries newer than it. That survives log archival (rotate-retros moves OLD entries out; we only
ever care about DATE > cursor) and never duplicates on the append-only stream.

Privacy: runs.log/retros.log carry repo + project names and free-text notes, so this is
FULL-detail data — the collector's /ingest/zuvo namespace is secret-gated (deny-by-default).
The token is CODESIFT_COLLECTOR_TOKEN, same as backlog-collect.py.

Env:
  ZUVO_HOME             default ~/.zuvo
  ZUVO_COLLECTOR_URL    default https://coding.tgmedit.com
  CODESIFT_COLLECTOR_TOKEN / ZUVO_COLLECTOR_TOKEN   secret for /ingest/zuvo
  ZUVO_RUNLOG_CURSOR    cursor file (default ~/.zuvo/runlog-upload.cursor)

Flags:
  --push     actually POST (default: dry-run, prints counts only)
  --reset    ignore the cursor and (with --push) re-send everything (use sparingly)
  --no-retros  skip retros.log, send runs.log only
"""
import os, sys, json, time, socket, gzip, urllib.request

HOME = os.path.expanduser("~")
ZUVO = os.environ.get("ZUVO_DIR", os.path.join(HOME, ".zuvo"))
URL = os.environ.get("ZUVO_COLLECTOR_URL", "https://coding.tgmedit.com").rstrip("/")
TOKEN = os.environ.get("CODESIFT_COLLECTOR_TOKEN") or os.environ.get("ZUVO_COLLECTOR_TOKEN") or ""
CURSOR = os.environ.get("ZUVO_RUNLOG_CURSOR", os.path.join(ZUVO, "runlog-upload.cursor"))
HOST = socket.gethostname()
BATCH = int(os.environ.get("ZUVO_RUNLOG_BATCH", "500"))

RUNS_FIELDS = ["date", "skill", "project", "cq", "q", "verdict", "tasks",
               "duration", "notes", "branch", "sha7", "includes", "tier"]
RETRO_FIELDS = ["date", "skill", "project", "code_type", "friction", "missing_template",
                "context_gap", "turns", "tool_calls", "files_read", "files_modified",
                "branch", "sha7", "blind_audit", "adversarial", "codesift", "routing"]


def read_cursor():
    """Last ISO date already uploaded. Empty string => nothing sent yet."""
    try:
        with open(CURSOR) as f:
            return f.read().strip()
    except Exception:
        return ""


def write_cursor(iso):
    try:
        os.makedirs(os.path.dirname(CURSOR), exist_ok=True)
        with open(CURSOR, "w") as f:
            f.write(iso)
    except Exception:
        pass


def parse_log(path, fields, prefix):
    """Yield dicts for every non-header data line. `date` is field 0 with an optional
    'RETRO: ' / 'Run: ' prefix stripped."""
    out = []
    try:
        text = open(path, errors="replace").read()
    except Exception:
        return out
    for raw in text.splitlines():
        line = raw.rstrip("\n")
        if not line.strip() or line.startswith("#"):
            continue
        # retros.log lines start with 'RETRO: '; runs.log lines have no prefix (append-runlog
        # strips a stray 'Run:'). Strip a known prefix off field 0 either way.
        cells = line.split("\t")
        cells[0] = cells[0].replace("RETRO: ", "").replace("Run: ", "").strip()
        # A real entry's field 0 is an ISO-8601 Z date. Skip anything else (stray prose).
        d = cells[0]
        if not (len(d) >= 20 and d[4] == "-" and d.endswith("Z")):
            continue
        rec = {fields[i]: cells[i] for i in range(min(len(fields), len(cells)))}
        rec["kind"] = prefix
        out.append(rec)
    return out


def collect(want_retros=True):
    runs = parse_log(os.path.join(ZUVO, "runs.log"), RUNS_FIELDS, "run")
    retros = parse_log(os.path.join(ZUVO, "retros.log"), RETRO_FIELDS, "retro") if want_retros else []
    return runs, retros


def _post(payload):
    req = urllib.request.Request(
        f"{URL}/ingest/zuvo", data=gzip.compress(json.dumps(payload).encode()),
        headers={"content-type": "application/json", "content-encoding": "gzip",
                 "x-api-key": TOKEN, "x-telemetry-client": "zuvo-runlog"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
        return r.status


def push(records, run_id):
    """Chunked push — the collector caps a body at 256 KB; batch to stay under it regardless
    of how many new entries accumulated since the last upload."""
    if not TOKEN:
        return "skipped (no collector token)", 0
    batches = [records[i:i + BATCH] for i in range(0, len(records), BATCH)] or [[]]
    ok = 0
    for idx, chunk in enumerate(batches):
        payload = {
            "schema_version": 1, "source": "zuvo-runlog", "host": HOST,
            "run_id": run_id, "batch": idx, "batches": len(batches),
            "level": "full", "entries": chunk,
        }
        try:
            _post(payload); ok += 1
        except Exception as e:
            return f"push failed on batch {idx + 1}/{len(batches)}: {e}", ok
    return f"pushed {ok}/{len(batches)} batches (run {run_id})", ok


if __name__ == "__main__":
    do_push = "--push" in sys.argv
    reset = "--reset" in sys.argv
    want_retros = "--no-retros" not in sys.argv

    runs, retros = collect(want_retros)
    cursor = "" if reset else read_cursor()

    # Incremental: only entries strictly newer than the cursor. ISO-8601 Z sorts lexically.
    fresh = [r for r in (runs + retros) if r.get("date", "") > cursor]
    fresh.sort(key=lambda r: r.get("date", ""))

    new_max = max([r.get("date", "") for r in fresh], default=cursor)
    run_id = "%s%s" % (int(time.time_ns()), len(fresh))
    run_id = run_id[-18:]

    status, ok = ("dry-run (not requested)", 0)
    if do_push and fresh:
        status, ok = push(fresh, run_id)
        # Advance the cursor only on a fully successful push (all batches sent).
        if ok and ok == ((len(fresh) + BATCH - 1) // BATCH or 1):
            write_cursor(new_max)
    elif do_push and not fresh:
        status = "nothing new since cursor"

    print(f"host={HOST} runs={len(runs)} retros={len(retros)} cursor={cursor or '(none)'} "
          f"new={len(fresh)} -> {new_max or '(none)'}")
    print(f"collector: {status}")
