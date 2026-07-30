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
  ZUVO_COLLECTOR_URL  default https://coding.tgmedit.com
  CODESIFT_COLLECTOR_TOKEN / ZUVO_COLLECTOR_TOKEN  secret for /ingest/backlog
  ZUVO_BACKLOG_OUT    local snapshot path (default ~/.zuvo/backlog-local.jsonl)
"""
import os, re, sys, json, glob, time, socket, subprocess, hashlib, gzip, urllib.request

HOME = os.path.expanduser("~")
ZUVO = os.environ.get("ZUVO_DIR", os.path.join(HOME, ".zuvo"))
ROOTS = os.environ.get("ZUVO_BACKLOG_ROOTS", os.path.join(HOME, "DEV", "*"))
OUT = os.environ.get("ZUVO_BACKLOG_OUT", os.path.join(ZUVO, "backlog-local.jsonl"))
URL = os.environ.get("ZUVO_COLLECTOR_URL", "https://coding.tgmedit.com").rstrip("/")
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
        f"{URL}/ingest/backlog", data=gzip.compress(json.dumps(payload).encode()),
        headers={"content-type": "application/json", "content-encoding": "gzip",
                 "x-api-key": TOKEN, "x-telemetry-client": "zuvo-backlog"}, method="POST")
    with urllib.request.urlopen(req, timeout=15) as r:
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
