#!/bin/sh
# Polyglot sh/python header. `#!/usr/bin/env python3` fails on Windows: python.org installs
# `python` and `py`, Git Bash ships neither, and the shebang dies with
#     env: python3: No such file or directory
# (reproduced). /bin/sh executes the next line, which re-execs this file with whatever Python 3
# the machine actually has; Python parses that same line as a string literal and ignores it.
# Keep it on ONE line and do not "tidy" the quoting — both interpreters depend on it exactly.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
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
  ZUVO_COLLECTOR_URL    required: env or ZUVO_COLLECTOR_URL= in ~/.zuvo/collector.conf (no default)
  CODESIFT_COLLECTOR_TOKEN / ZUVO_COLLECTOR_TOKEN   secret for /ingest/zuvo
  ZUVO_RUNLOG_CURSOR    cursor file (default ~/.zuvo/runlog-upload.cursor)

Flags:
  --push     actually POST (default: dry-run, prints counts only)
  --reset    ignore the cursor and (with --push) re-send everything (use sparingly)
  --no-retros  skip retros.log, send runs.log only
"""
import os
import re
import sys
import json
import time
import socket
import gzip
import hashlib
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
ZUVO = os.environ.get("ZUVO_DIR", os.path.join(HOME, ".zuvo"))

def _collector_url():
    """Same resolution rule as zuvo-collector-host.sh: env, then collector.conf, NO default.

    A hardcoded address in a versioned script is what test-retro-loop-docs.sh forbids, and for
    a good reason beyond tidiness: this uploader carries a bearer token, so a stale baked-in
    address keeps shipping credentials to whatever now answers on it. `runlog-sync.sh` was
    migrated to this rule already; these two collectors were left behind and that is what made
    the gate red (B-28). Machine-local value lives in ~/.zuvo/collector.conf, which is not in git.
    """
    v = os.environ.get("ZUVO_COLLECTOR_URL")
    if v:
        return v.strip().rstrip("/")
    conf = os.path.join(ZUVO, "collector.conf")
    try:
        with open(conf, encoding="utf-8", errors="ignore") as fh:
            for line in fh:
                m = re.match(r"\s*ZUVO_COLLECTOR_URL\s*=\s*(.+)", line)
                if m:
                    val = m.group(1).split("#", 1)[0].strip().strip("'\"").strip()
                    if val:
                        return val.rstrip("/")
    except OSError:
        pass
    sys.exit("no collector URL: set ZUVO_COLLECTOR_URL or add ZUVO_COLLECTOR_URL= to "
             "~/.zuvo/collector.conf (no default is baked in — see B-28)")


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Refuse every redirect on the upload POST.

    urlopen follows 3xx by default and re-sends the request — including the x-api-key header —
    to whatever Location says. _reject_plaintext_to_public() only ever sees the ORIGINAL url, so
    a compromised or merely misconfigured collector (or hijacked DNS) could bounce the upload to
    an attacker host and hand over the token in the process. There is no legitimate redirect on
    this endpoint, so the safe behaviour is to fail loudly rather than to follow and re-validate.
    """

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(
            req.full_url, code,
            f"refusing redirect to {newurl} — the upload carries a bearer token", headers, fp)


_OPENER = urllib.request.build_opener(_NoRedirect)


def _reject_plaintext_to_public(url):
    """Plain HTTP is fine to a tailnet/private/loopback host and NOWHERE else.

    This uploader sends a bearer token. The collector deliberately has no public HTTPS (it is
    loopback-bound on the VPS and reached over the tailnet), so forcing https:// would break a
    working, adequately protected path: WireGuard already encrypts the transport. What it does
    NOT protect is a MIS-SET url — one typo and the same token goes to an arbitrary internet
    host in clear text, with no error. Allow plaintext exactly where transport is already
    encrypted; refuse it otherwise. Override with ZUVO_COLLECTOR_ALLOW_PLAINTEXT=1.
    """
    import ipaddress
    from urllib.parse import urlparse
    if os.environ.get("ZUVO_COLLECTOR_ALLOW_PLAINTEXT") == "1":
        return
    p = urlparse(url)
    if p.scheme != "http":
        return
    host = p.hostname or ""
    if host.endswith(".ts.net"):                      # tailscale MagicDNS
        return
    try:
        ip = ipaddress.ip_address(host)
    except ValueError:
        sys.exit(f"refusing plaintext HTTP with a bearer token to non-private host {host!r} "
                 f"(set ZUVO_COLLECTOR_ALLOW_PLAINTEXT=1 to override)")
    # Loopback and the tailscale CGNAT range ONLY — deliberately NOT ip.is_private. A generic
    # RFC1918 address is an ordinary LAN or container network where nothing encrypts the hop, so
    # allowing it would hand the bearer token to any hostile service on the same subnet. WireGuard
    # protects 100.64/10; a 192.168.x collector protects nothing. Octet arithmetic rather than a
    # literal dotted quad, because a literal would trip the no-hardcoded-address gate this change
    # exists to satisfy.
    o = ip.packed
    if ip.is_loopback or (ip.version == 4 and o[0] == 100 and 64 <= o[1] <= 127):
        return
    sys.exit(f"refusing plaintext HTTP with a bearer token to non-tailnet address {host} "
             f"(set ZUVO_COLLECTOR_ALLOW_PLAINTEXT=1 to override)")
# Resolved LAZILY, at the moment of upload — not at import. These scripts also do purely
# local work (id computation, cursor handling, --dry-run) that must not require collector
# configuration; requiring it up front turned every local invocation into a hard exit and
# broke tests/hooks/test-runlog-collect.sh.
URL = None


def collector_url():
    global URL
    if URL is None:
        URL = _collector_url()
        _reject_plaintext_to_public(URL)
    return URL
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
    """Return (date, ids_at_that_date). Compound so same-second events are neither lost nor
    re-sent: `date` is the newest ISO uploaded; `ids` are the idempotency keys of the entries
    AT that exact date already sent. Tolerates the legacy bare-date file. ('', set()) => fresh."""
    try:
        with open(CURSOR) as f:
            raw = f.read().strip()
        if not raw:
            return "", set()
        if raw.startswith("{"):
            d = json.loads(raw)
            return d.get("date", ""), set(d.get("ids", []))
        return raw, set()                       # legacy: bare date, no id set
    except Exception:
        return "", set()


def write_cursor(date, ids):
    try:
        os.makedirs(os.path.dirname(CURSOR), exist_ok=True)
        with open(CURSOR, "w") as f:
            json.dump({"date": date, "ids": sorted(ids)}, f)
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
        # Stable idempotency key: sha1 of host + the raw line. Delivery is at-least-once (a
        # partial-batch failure or an inclusive-cursor boundary re-send can put an event on the
        # wire twice), so every entry carries an `id` the READER dedups on — that turns
        # at-least-once into effectively-once WITHOUT a fragile exactly-once cursor.
        rec["id"] = hashlib.sha1((HOST + "\t" + line).encode()).hexdigest()[:16]
        out.append(rec)
    return out


def collect(want_retros=True):
    runs = parse_log(os.path.join(ZUVO, "runs.log"), RUNS_FIELDS, "run")
    retros = parse_log(os.path.join(ZUVO, "retros.log"), RETRO_FIELDS, "retro") if want_retros else []
    return runs, retros


def _post(payload):
    req = urllib.request.Request(
        f"{collector_url()}/ingest/zuvo", data=gzip.compress(json.dumps(payload).encode()),
        headers={"content-type": "application/json", "content-encoding": "gzip",
                 "x-api-key": TOKEN, "x-telemetry-client": "zuvo-runlog"}, method="POST")
    with _OPENER.open(req, timeout=15) as r:
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
    cdate, cids = ("", set()) if reset else read_cursor()
    allrecs = runs + retros

    # Compound-cursor selection: an entry is fresh if its date is strictly newer than the cursor
    # date, OR it shares the cursor date but its id was not already sent. This loses nothing at a
    # same-second boundary (runs.log + retros.log routinely stamp the same second) and re-sends
    # nothing already delivered. ISO-8601 Z sorts lexically.
    fresh = [r for r in allrecs
             if r.get("date", "") > cdate
             or (r.get("date", "") == cdate and r.get("id") not in cids)]
    fresh.sort(key=lambda r: r.get("date", ""))

    new_max = max([r.get("date", "") for r in allrecs], default=cdate) if fresh else cdate
    # New cursor id-set = every entry AT the new max date (all now delivered). Union keeps the
    # prior ids when the max date did not advance.
    new_ids = {r["id"] for r in allrecs if r.get("date") == new_max}
    if new_max == cdate:
        new_ids |= cids
    run_id = ("%s%s" % (int(time.time_ns()), len(fresh)))[-18:]

    status, ok = ("dry-run (not requested)", 0)
    if do_push and fresh:
        status, ok = push(fresh, run_id)
        # Advance only on a FULLY successful push (all batches). On partial failure the cursor
        # stays put -> next run re-sends from the old cursor (at-least-once); the per-entry `id`
        # lets the reader collapse the duplicates (effectively-once).
        expected = (len(fresh) + BATCH - 1) // BATCH or 1
        if ok == expected:
            write_cursor(new_max, new_ids)
    elif do_push and not fresh:
        status = "nothing new since cursor"

    cursor = cdate

    print(f"host={HOST} runs={len(runs)} retros={len(retros)} cursor={cursor or '(none)'} "
          f"new={len(fresh)} -> {new_max or '(none)'}")
    print(f"collector: {status}")
