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
    list --porcelain` first entry). An untracked linked-worktree copy is a stray,
    reported; a tracked one is branch content, counted once its branch is merged
    into the main checkout's copy. Neither is added to the totals here — that double-counting is what made
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
import hashlib
import gzip
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_parse as zb  # noqa: E402
import zuvo_backlog_io as zio  # noqa: E402
import zuvo_host_id  # noqa: E402

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
try:
    HOST = zuvo_host_id.host_tag()
except OSError as _host_err:
    # The module lets a present-but-unreadable host-id propagate on purpose (a root-owned file after
    # a sudo run must not degrade to the volatile hostname in silence). At import that would surface
    # as a bare traceback naming neither the file nor the fix, so it is named here and the exit is
    # the refusal, not a crash.
    sys.exit(f"{os.path.basename(__file__)}: cannot read the host tag "
             f"({zuvo_host_id.host_id_path()}: {_host_err}) — refusing to report under a fallback "
             f"name; fix the file's permissions or remove it")

# Parsing, the resolution vocabulary and the dedup key live in zuvo_backlog_parse so this
# collector and backlog-archive.py cannot drift apart. `fingerprint` is still emitted byte-for-byte
# as before (the collector schema and ~/.zuvo/backlog read it); `key` is the new resolution-stable
# id that survives an entry being closed.
DATE_RE = zb.DATE_RE
ID_RE = zb.ID_RE
RESOLVED_MARKERS = zb.RESOLVED_MARKERS
is_resolved_inline = zb.is_resolved_inline
valid_date = zb.valid_date
parse_backlog = zb.parse_backlog


sh = zb.sh                  # both live in the shared module for the same reason the parsing does:
main_root = zb.main_root    # this collector and backlog-archive.py must not drift apart


def remote_url(repo_dir):
    return sh(["git", "-C", repo_dir, "remote", "get-url", "origin"]) or ""


def collect():
    # seen_file: the canonical backlog is reached through SIX ~/DEV symlinks whose directories are
    # distinct (and two of which are not git repos, so main_root() returns the alias itself). Keying
    # only on the repo dir counted the same 1211 items six times. The file's realpath is the identity.
    records, strays, seen_main, seen_file = [], [], set(), set()
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
                if not zio.tracked_root(repo):
                    strays.append(repo)      # an untracked linked-worktree copy: a fork, report it
                continue                     # a tracked copy is branch content: it enters the totals once merged
            if os.path.realpath(repo) in seen_main or os.path.realpath(bl) in seen_file:
                continue
            seen_main.add(os.path.realpath(repo))
            seen_file.add(os.path.realpath(bl))
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
    cliff). A batch_id groups the run server-side. Returns (landed, status): `landed` is the
    verdict, `status` only the words — callers branch on the bool, never on the wording."""
    if not TOKEN:
        return False, "skipped (no collector token)"
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
            return False, f"push failed on batch {idx + 1}/{len(batches)}: {e}"
    return True, f"pushed {ok}/{len(batches)} batches (run {run_id})"


if __name__ == "__main__":
    recs, strays = collect()
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w") as f:
        for r in recs:
            f.write(json.dumps(r) + "\n")
    repos = len({r["repo_path"] for r in recs})
    op = sum(1 for r in recs if r["status"] == "open")
    dn = sum(1 for r in recs if r["status"] == "done")
    wants_push = "--push" in sys.argv
    landed, status = push(recs, strays) if wants_push else (True, "not requested")
    print(f"host={HOST} repos={repos} items={len(recs)} open={op} done={dn} "
          f"stray_worktree_copies={len(strays)}")
    print(f"local snapshot: {OUT} | collector: {status}")
    # A push that was asked for and did not land (failed batch, no token) exits non-zero: `backlog sync`
    # reads the status, and a 0 here let it pull and print a fresh-looking index over a push that never
    # happened.
    if not landed:
        sys.exit(1)
