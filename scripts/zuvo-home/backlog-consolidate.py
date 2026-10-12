#!/bin/sh
# Polyglot sh/python header. `#!/usr/bin/env python3` fails on Windows: python.org installs
# `python` and `py`, Git Bash ships neither, and the shebang dies with
#     env: python3: No such file or directory
# (reproduced). /bin/sh executes the next line, which re-execs this file with whatever Python 3
# the machine actually has; Python parses that same line as a string literal and ignores it.
# Keep it on ONE line and do not "tidy" the quoting — both interpreters depend on it exactly.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Consolidate worktree-forked project state into the MAIN checkout.

Rule (zuvo backlog-protocol): memory/backlog.md, memory/ideas.md and knowledge/*.jsonl
live ONCE per repository, at the main checkout root. Linked worktrees must not have
their own copies. This script:
  1. finds every copy under ~/DEV/*/,
  2. groups by main checkout (git worktree list --porcelain, first entry),
  3. merges unique content from worktree copies into the main copy (backup first),
  4. replaces the worktree copy with a pointer stub once main holds all of it.

Git decides first. A worktree copy git tracks is git's to merge: the branch merge carries it, and
writing main would create or dirty the very path that merge needs. A main copy git tracks is never
written either (an append leaves the main checkout dirty and `git merge --ff-only` stops working);
entries only an untracked worktree copy holds are then reported for a hand merge.

Entries are matched by their ID (a table row's first cell, a top-level list item's first word:
B-12, S-66, LGN-1; a jsonl record's "id"), so a row edited in a worktree is not appended again as a
new one. Nor is the edit dropped: a worktree copy holding an entry whose text differs from main's
(a status word, a ticked box, a rewrite) is kept, not stubbed, and the report names the entry.

Separate clones sharing a remote are NOT merged (no clear canonical) — only true
linked worktrees of one repository. Idempotent; safe to re-run.
"""
import subprocess
import sys
import hashlib
import datetime
import json
import re
from pathlib import Path

DEV = Path.home() / "DEV"
# NOT a literal. As `TODAY = "2026-07-19"` this quietly disabled the one safety step the file
# promises: backup() writes `<name>.bak-<TODAY>` only `if not bak.exists()`, and with a frozen date
# that filename never changes — so the SECOND real run, on any later day, skipped the backup and
# went straight to rewriting the file. Every "Merged from worktree … (TODAY)" header and every STUB
# notice was stamped 2026-07-19 forever, too.
TODAY = datetime.date.today().isoformat()
DRY = "--dry-run" in sys.argv
# Byte-exact round trip whatever the locale: a stray non-UTF-8 byte survives into main and the backup
# instead of becoming U+FFFD (or crashing the append under LC_ALL=C).
ENC = {"encoding": "utf-8", "errors": "surrogateescape"}

def sh(args, cwd=None):
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=15)
        return r.returncode, r.stdout.strip()
    except Exception:
        return 1, ""

def main_root(repo_dir):
    rc, out = sh(["git", "worktree", "list", "--porcelain"], cwd=repo_dir)
    if rc == 0 and out.startswith("worktree "):
        return out.splitlines()[0][len("worktree "):]
    rc, out = sh(["git", "rev-parse", "--show-toplevel"], cwd=repo_dir)
    return out if rc == 0 else None

def is_tracked(repo_dir, relpath):
    rc, _ = sh(["git", "ls-files", "--error-unmatch", relpath], cwd=repo_dir)
    return rc == 0

def ws(line):
    return " ".join(line.split())

def norm(line):
    s = line.strip()
    for p in ("- [x] ", "- [X] ", "- [ ] "):
        if s.startswith(p):
            s = "- " + s[len(p):]
            break
    return ws(s)

# An entry's ID: `B-12`, `S-66`, `LGN-1`, `B-20261005-import-choice-pool-blank-upload`. Markup, a size
# tag and a status word in front are not part of it (`| DONE B-12 |`, `| ~~B-12~~ |`,
# `- [x] **[S] B-12 [P3]** …`), and it ends at a boundary, so `B-12x` is not `B-12`.
ENTRY_ID = re.compile(
    r"(?:\[[A-Z]{1,3}\]\s+)?"
    r"(?:(?i:DONE|FIXED|WONTFIX|CLOSED|OPEN|WIP|TODO|BLOCKED|DEFERRED|PARTIAL|REJECTED|SUPERSEDED):?\s+)?"
    r"([A-Z][A-Z0-9]{0,9}-[A-Za-z0-9][A-Za-z0-9._-]*)(?=$|[\s|*`~:,;)\]])")
LIST_ITEM = re.compile(r"(?:[-*+]|\d{1,3}[.)])\s+(?:\[[ xX]\]\s+)?")

def entry_id(line):
    """The ID an entry line starts with — the first cell of a table row, or the first word of a
    top-level list item — or None. An indented list item is an entry's body, not an entry. Two lines
    with one ID are one entry, whatever their text says: a row edited in a worktree is the same row."""
    if line[:1].isspace() and not line.lstrip().startswith("|"):
        return None
    s = line.strip()
    if s.startswith("|"):
        head = s.strip("|").split("|", 1)[0]
    else:
        m = LIST_ITEM.match(s)
        if not m:
            return None
        head = s[m.end():]
    m = ENTRY_ID.match(head.strip().strip("*`~").strip())
    return m.group(1) if m else None

def entry_key(line):
    """What makes a line new: its entry ID when it has one, else the normalised line."""
    eid = entry_id(line)
    return ("id", eid) if eid else ("line", norm(line))

def backup(path: Path):
    """A copy of path before this run first appends to it. The day's backup is kept as it is; a
    second append that day, onto a file that changed since, gets its own timestamped copy."""
    if DRY or not path.exists():
        return
    data = path.read_bytes()
    bak = path.with_name(path.name + f".bak-{TODAY.replace('-','')}")
    if bak.exists():
        if bak.read_bytes() == data:
            return
        bak = path.with_name(path.name + f".bak-{datetime.datetime.now():%Y%m%d-%H%M%S-%f}")
    bak.write_bytes(data)

def append(main_file: Path, block: str):
    backup(main_file)
    main_file.parent.mkdir(parents=True, exist_ok=True)
    with main_file.open("a", **ENC) as f:
        f.write(block)  # one write: no header left dangling without its entries

def merge_md(main_file: Path, wt_file: Path, label: str, write=True):
    """Append the entries of wt_file that main_file lacks — by entry ID (entry_id), else by the
    normalised line. Returns (count merged, entries whose worktree text differs from main's).

    A differing entry is not appended (that duplicated the row) and not dropped either: the caller keeps
    the worktree copy instead of stubbing it, because the stub would erase the edit. "Differs" compares
    the raw line (whitespace collapsed), so a ticked box or a status word counts."""
    main_text = (main_file.read_text(**ENC) if main_file.exists()
                 else "# Backlog\n" if "backlog" in main_file.name else "")
    have, texts = set(), {}
    for l in main_text.splitlines():
        if norm(l):
            k = entry_key(l)
            have.add(k)
            texts.setdefault(k, set()).add(ws(l))
    uniq, differs = [], []
    for l in wt_file.read_text(**ENC).splitlines():
        n = norm(l)
        if not n or n.startswith("#"):
            continue  # headings are structure, not entries — incl. this script's own "## Merged from …"
        k = entry_key(l)
        if k not in have:
            uniq.append(l)
            have.add(k)
            texts.setdefault(k, set()).add(ws(l))
        elif ws(l) not in texts[k]:
            name = k[1] if k[0] == "id" else f"line '{ws(l)[:60]}'"
            if name not in differs:
                differs.append(name)
    if uniq and write and not DRY:
        append(main_file, f"\n## Merged from worktree {label} ({TODAY})\n" + "\n".join(uniq) + "\n")
    return len(uniq), differs

def jsonl_key(line):
    """(key, canonical body): a record's "id" and its sorted JSON, or the line's hash for both."""
    try:
        rec = json.loads(line)
        if isinstance(rec, dict) and "id" in rec:
            return json.dumps(rec["id"]), json.dumps(rec, sort_keys=True)
    except ValueError:
        pass
    h = hashlib.sha1(line.encode("utf-8", "surrogateescape")).hexdigest()
    return h, h

def merge_jsonl(main_file: Path, wt_file: Path, write=True):
    """Append the records of wt_file whose id main_file lacks. Returns (count merged, ids whose
    record differs from main's) — the same contract as merge_md."""
    bodies = {}
    if main_file.exists():
        for l in main_file.read_text(**ENC).splitlines():
            if l.strip():
                k, body = jsonl_key(l)
                bodies.setdefault(k, set()).add(body)
    uniq, differs = [], []
    for l in wt_file.read_text(**ENC).splitlines():
        if not l.strip():
            continue
        k, body = jsonl_key(l)
        if k not in bodies:
            uniq.append(l)
            bodies[k] = {body}
        elif body not in bodies[k] and k not in differs:
            differs.append(k)
    if uniq and write and not DRY:
        append(main_file, "\n".join(uniq) + "\n")
    return len(uniq), differs

def merge(kind, main_file, wt, label, write=True):
    if kind == "md":
        return merge_md(main_file, wt, label, write)
    return merge_jsonl(main_file, wt, write)

STUB = ("# MOVED — canonical copy lives in the MAIN checkout\n\n"
        "Canonical: {main}/{rel}\n"
        "One state file per repository (zuvo backlog-protocol, worktree rule). "
        f"This worktree copy was merged into the canonical file on {TODAY}. Do not write here.\n")

merged_report, left_tracked, stubbed, edited, hand_merge, failed = [], [], [], [], [], []

repos = sorted({p for p in DEV.glob("*/") if (p / ".git").exists()})
for repo in repos:
    mr = main_root(str(repo))
    if not mr:
        continue
    mr = Path(mr)
    if mr.resolve() == repo.resolve():
        continue  # this IS the main checkout
    if not str(mr).startswith(str(Path.home())):
        continue
    # this repo dir is a linked worktree of mr
    candidates = [("memory/backlog.md", "md"), ("memory/ideas.md", "md")]
    for kf in sorted((repo / "knowledge").glob("*.jsonl")) if (repo / "knowledge").exists() else []:
        candidates.append((str(kf.relative_to(repo)), "jsonl"))
    for rel, kind in candidates:
        wt = repo / rel
        try:
            if not wt.exists() or wt.stat().st_size == 0:
                continue
            if "MOVED — canonical" in wt.read_text(**ENC)[:200]:
                continue  # already stubbed
            main_file = mr / rel
            if is_tracked(str(repo), rel):
                left_tracked.append((repo.name, rel))
                continue
            if is_tracked(str(mr), rel):
                # Git will not carry an untracked worktree copy, and main must not be written.
                n, differs = merge(kind, main_file, wt, repo.name, write=False)
                if n or differs:
                    hand_merge.append((repo.name, rel, n, differs, mr.name))
                    continue
            else:
                n, differs = merge(kind, main_file, wt, repo.name)
                merged_report.append((repo.name, rel, n, mr.name))
                if differs:
                    edited.append((repo.name, rel, differs))
                    continue
            if not DRY:
                wt.write_text(STUB.format(main=mr, rel=rel), **ENC)
            stubbed.append((repo.name, rel))
        except OSError as e:
            failed.append((repo.name, rel, str(e)))

print(f"{'DRY-RUN ' if DRY else ''}CONSOLIDATION REPORT ({TODAY})")
print(f"worktree copies processed: {len(merged_report)}")
for name, rel, n, main in merged_report:
    print(f"  {name}/{rel}: +{n} unique -> {main}/{rel}")
print(f"stubbed (main holds all of it): {len(stubbed)}")
print(f"left in place (git-TRACKED in worktree — the branch merge carries it): {len(left_tracked)}")
for name, rel in left_tracked:
    print(f"  TRACKED: {name}/{rel}")
print(f"left in place (entries edited in the worktree — reconcile by hand): {len(edited)}")
for name, rel, ids in edited:
    print(f"  EDITED: {name}/{rel}: {', '.join(ids)}")
print(f"left in place (main copy git-TRACKED, worktree copy untracked — merge by hand): {len(hand_merge)}")
for name, rel, n, ids, main in hand_merge:
    extra = f"; edited: {', '.join(ids)}" if ids else ""
    print(f"  HAND MERGE: {name}/{rel}: +{n} entries {main}/{rel} lacks{extra}")
if failed:
    print(f"FAILED: {len(failed)}")
    for name, rel, err in failed:
        print(f"  FAILED: {name}/{rel}: {err}")
    sys.exit(1)
