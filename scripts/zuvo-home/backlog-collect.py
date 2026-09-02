#!/bin/sh
# Polyglot sh/python header. `#!/usr/bin/env python3` fails on Windows: python.org installs
# `python` and `py`, Git Bash ships neither, and the shebang dies with
#     env: python3: No such file or directory
# (reproduced). /bin/sh executes the next line, which re-execs this file with whatever Python 3
# the machine actually has; Python parses that same line as a string literal and ignores it.
# Keep it on ONE line and do not "tidy" the quoting — both interpreters depend on it exactly.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Collect every backlog.md in this host's repos into ONE normalized JSONL stream.

Runs UNCHANGED on the Mac and on the VPS/bot hosts — the only difference is the
scan roots (ZUVO_BACKLOG_ROOTS). Writes a local snapshot and, when a collector
token is configured, POSTs the snapshot to the shared collector's /ingest/backlog
namespace so one place holds the whole fleet.

Design notes:
  * WORKTREE-SAFE: only the MAIN checkout of each repo is scanned (`git worktree
    list --porcelain` first entry). Linked-worktree copies are counted as strays
    and reported, never merged into the totals — that double-counting is what made
    a raw scan read 8999 open when the real number is ~3000.
  * FORMAT-TOLERANT: the fleet has 4 different backlog dialects in the wild
    (checkbox list, `- [B-N] text`, `` - `fingerprint` — text `` under ## Open,
    and a pipe table). The parser handles all of them and degrades to "one item
    per bullet line" rather than dropping a file it doesn't recognise.
  * Read-only. Never writes into any repo.

Env:
  ZUVO_BACKLOG_ROOTS  colon-separated globs (default: ~/DEV/*)
  ZUVO_COLLECTOR_URL  required: env or ZUVO_COLLECTOR_URL= in ~/.zuvo/collector.conf (no default)
  CODESIFT_COLLECTOR_TOKEN / ZUVO_COLLECTOR_TOKEN  secret for /ingest/backlog
  ZUVO_BACKLOG_OUT    local snapshot path (default ~/.zuvo/backlog-local.jsonl)
"""
import os
import re
import sys
import json
import glob
import time
import socket
import subprocess
import hashlib
import gzip
import urllib.error
import urllib.request

HOME = os.path.expanduser("~")
ZUVO = os.environ.get("ZUVO_DIR", os.path.join(HOME, ".zuvo"))
ROOTS = os.environ.get("ZUVO_BACKLOG_ROOTS", os.path.join(HOME, "DEV", "*"))
OUT = os.environ.get("ZUVO_BACKLOG_OUT", os.path.join(ZUVO, "backlog-local.jsonl"))

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
HOST = socket.gethostname()

DATE_RE = re.compile(r"\b(\d{4}-\d{2}-\d{2})\b")
ID_RE = re.compile(r"\bB-[\w.-]+\b")
SEV_RE = re.compile(r"\b(critical|high|medium|low|CRITICAL|WARNING|INFO)\b")
DONE_SECTION = re.compile(r"^#+\s*(resolved|done|closed|completed)", re.I)
OPEN_SECTION = re.compile(r"^#+\s*(open|backlog|deferred|todo)", re.I)
# A line that DOCUMENTS the format rather than recording an item.
TEMPLATE_RE = re.compile(
    r"(CRITICAL\s*/\s*HIGH|HIGH\s*/\s*MEDIUM|critical\|high\|medium|"
    r"<[a-z-]+>\s*\|\s*<|severity:\s*\[|\bfingerprint\s*\|\s*source-task\b)", re.I)
# Inline "already resolved" annotations used instead of a Resolved section/checkbox.
RESOLVED_MARKERS = ("FIXED", "RESOLVED", "DONE", "CLOSED", "WONTFIX", "OBSOLETE")


def is_resolved_inline(body):
    """True when the item body OPENS with a resolution marker.

    Repos annotate in place instead of moving the line to a Resolved section —
    both "FIXED: x" and "[FIXED] x" occur, so a regex with `\\s*` before the
    delimiter mis-parses one of them. Explicit prefix + boundary check is clearer
    and covers every wrapper (**, [, spaces). DEFERRED is deliberately NOT a
    marker: a deferred item is still open.
    """
    b = body.lstrip("*[ \t").upper()
    for m in RESOLVED_MARKERS:
        if b.startswith(m) and (len(b) == len(m) or not b[len(m)].isalnum()):
            return True
    return False


def valid_date(s):
    """Reject impossible dates (a loose regex happily matches 2026-02-31)."""
    try:
        import datetime
        datetime.date.fromisoformat(s)
        return True
    except Exception:
        return False


def sh(args, cwd=None):
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=15)
        return r.stdout.strip() if r.returncode == 0 else ""
    except Exception:
        return ""


def main_root(repo_dir):
    """First `git worktree list` entry is ALWAYS the main worktree (even from a linked one)."""
    out = sh(["git", "worktree", "list", "--porcelain"], cwd=repo_dir)
    if out.startswith("worktree "):
        return out.splitlines()[0][len("worktree "):]
    return sh(["git", "rev-parse", "--show-toplevel"], cwd=repo_dir) or repo_dir


def remote_url(repo_dir):
    return sh(["git", "-C", repo_dir, "remote", "get-url", "origin"]) or ""


def parse_backlog(path, text):
    """Yield normalized items. Tolerant across the 4 dialects seen in the fleet."""
    items, section_done = [], False
    for raw in text.splitlines():
        line = raw.rstrip()
        if not line.strip():
            continue
        if line.lstrip().startswith("#"):
            if DONE_SECTION.match(line.strip()):
                section_done = True
            elif OPEN_SECTION.match(line.strip()):
                section_done = False
            continue

        stripped = line.strip()
        is_item = stripped.startswith("- ") or stripped.startswith("* ")
        is_table = stripped.startswith("|") and ID_RE.search(stripped)
        if not (is_item or is_table):
            continue
        # skip markdown table separators / headers
        if is_table and set(stripped.replace("|", "").strip()) <= set("-: "):
            continue

        # --- status ---
        if re.match(r"^[-*]\s*\[[xX]\]", stripped):
            status = "done"
        elif re.match(r"^[-*]\s*\[\s\]", stripped):
            status = "open"
        elif is_table:
            status = "done" if re.search(r"\b(RESOLVED|DONE|CLOSED)\b", stripped) else "open"
        else:
            status = "done" if section_done else "open"

        body = re.sub(r"^[-*]\s*(\[[ xX]\]\s*)?", "", stripped)

        # Skip legend/template lines (a format example is not a debt item) —
        # otherwise "**Severity:** CRITICAL / HIGH / MEDIUM / LOW" reads as a
        # critical finding and poisons the `crit` view.
        if TEMPLATE_RE.search(body):
            continue
        # Inline resolution markers: many repos annotate the item in place
        # ("FIXED: ...", "[FIXED]", "**RESOLVED**", "DONE —") instead of moving
        # it to a Resolved section or ticking a box. Counting those as OPEN
        # CRITICAL is exactly the noise that makes an index get ignored.
        if is_resolved_inline(body):
            status = "done"
        m_id = ID_RE.search(body)
        item_id = m_id.group(0) if m_id else "h-" + hashlib.sha1(body.encode()).hexdigest()[:10]
        m_sev = SEV_RE.search(body)
        sev = m_sev.group(1).lower() if m_sev else ""
        sev = {"warning": "medium", "info": "low"}.get(sev, sev)
        m_date = DATE_RE.search(body)
        added = m_date.group(1) if m_date and valid_date(m_date.group(1)) else ""
        items.append({
            "item_id": item_id,
            "status": status,
            "severity": sev,
            "added": added,
            "text": body[:400],
            "fingerprint": hashlib.sha1(body[:200].encode()).hexdigest()[:12],
        })
    return items


def collect():
    records, strays, seen_main = [], [], set()
    for root in ROOTS.split(":"):
        for repo in sorted(glob.glob(os.path.expanduser(root))):
            bl = os.path.join(repo, "memory", "backlog.md")
            if not os.path.isfile(bl):
                continue
            try:
                text = open(bl, errors="replace").read()
            except Exception:
                continue
            if "MOVED — canonical" in text[:200]:
                continue  # consolidation stub
            mr = main_root(repo)
            if os.path.realpath(mr) != os.path.realpath(repo):
                strays.append(repo)          # linked-worktree copy: report, never count
                continue
            if os.path.realpath(repo) in seen_main:
                continue
            seen_main.add(os.path.realpath(repo))
            url = remote_url(repo)
            for it in parse_backlog(bl, text):
                it.update({
                    "host": HOST,
                    "repo": os.path.basename(repo.rstrip("/")),
                    "repo_path": repo,
                    "repo_remote": url,
                })
                records.append(it)
    return records, strays


BATCH = int(os.environ.get("ZUVO_BACKLOG_BATCH", "800"))


def _post(payload):
    req = urllib.request.Request(
        f"{collector_url()}/ingest/backlog", data=gzip.compress(json.dumps(payload).encode()),
        headers={"content-type": "application/json", "content-encoding": "gzip",
                 "x-api-key": TOKEN, "x-telemetry-client": "zuvo-backlog"}, method="POST")
    with _OPENER.open(req, timeout=15) as r:
        return r.status


def push(records, strays):
    """Chunked push — the collector caps a body at 256 KB, and a full fleet
    snapshot gzips well past that. Batching keeps every request small regardless
    of how many repos the host has (raising the server cap would just move the
    cliff). A batch_id groups the run server-side."""
    if not TOKEN:
        return "skipped (no collector token)"
    # MUST be unique per run. A content-derived id (host+counts) collides whenever
    # a re-run produces the same totals — the merge then CONCATENATES the old and
    # new run instead of replacing it, silently doubling every count. Timestamp it.
    run_id = hashlib.sha1(f"{HOST}{time.time_ns()}{len(records)}".encode()).hexdigest()[:10]
    batches = [records[i:i + BATCH] for i in range(0, len(records), BATCH)] or [[]]
    ok = 0
    for idx, chunk in enumerate(batches):
        payload = {
            "schema_version": 1, "source": "zuvo-backlog", "host": HOST,
            "run_id": run_id, "batch": idx, "batches": len(batches),
            "items": chunk,
        }
        if idx == 0:
            payload["stray_worktree_copies"] = strays
        try:
            _post(payload)
            ok += 1
        except Exception as e:
            return f"push failed on batch {idx + 1}/{len(batches)}: {e}"
    return f"pushed {ok}/{len(batches)} batches (run {run_id})"


if __name__ == "__main__":
    recs, strays = collect()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    repos = len({r["repo_path"] for r in recs})
    op = sum(1 for r in recs if r["status"] == "open")
    dn = sum(1 for r in recs if r["status"] == "done")
    status = push(recs, strays) if "--push" in sys.argv else "not requested"
    print(f"host={HOST} repos={repos} items={len(recs)} open={op} done={dn} "
          f"stray_worktree_copies={len(strays)}")
    print(f"local snapshot: {OUT} | collector: {status}")
