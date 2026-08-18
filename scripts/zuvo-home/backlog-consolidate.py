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
  4. replaces UNTRACKED worktree copies with a pointer stub; leaves tracked ones (reported).

Separate clones sharing a remote are NOT merged (no clear canonical) — only true
linked worktrees of one repository. Idempotent; safe to re-run.
"""
import subprocess
import sys
import hashlib
import json
from pathlib import Path

DEV = Path.home() / "DEV"
TODAY = "2026-07-19"
DRY = "--dry-run" in sys.argv

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

def norm(line):
    s = line.strip()
    for p in ("- [x] ", "- [X] ", "- [ ] "):
        if s.startswith(p):
            s = "- " + s[len(p):]
            break
    return " ".join(s.split())

def backup(path: Path):
    bak = path.with_name(path.name + f".bak-{TODAY.replace('-','')}")
    if not bak.exists() and path.exists() and not DRY:
        bak.write_text(path.read_text(errors="replace"))

def merge_md(main_file: Path, wt_file: Path, label: str):
    """Append lines from wt_file that main_file lacks. Returns count merged."""
    main_text = main_file.read_text(errors="replace") if main_file.exists() else "# Backlog\n" if "backlog" in main_file.name else ""
    have = {norm(l) for l in main_text.splitlines() if norm(l)}
    uniq = []
    for l in wt_file.read_text(errors="replace").splitlines():
        n = norm(l)
        if not n or n.startswith("# ") or "MOVED" in l and "Canonical" in l:
            continue
        if n not in have:
            uniq.append(l)
            have.add(n)
    if uniq and not DRY:
        backup(main_file)
        main_file.parent.mkdir(parents=True, exist_ok=True)
        with main_file.open("a") as f:
            f.write(f"\n## Merged from worktree {label} ({TODAY})\n")
            f.write("\n".join(uniq) + "\n")
    return len(uniq)

def merge_jsonl(main_file: Path, wt_file: Path):
    ids = set()
    if main_file.exists():
        for l in main_file.read_text(errors="replace").splitlines():
            try:
                ids.add(json.loads(l).get("id"))
            except Exception:
                ids.add(hashlib.sha1(l.encode()).hexdigest())
    uniq = []
    for l in wt_file.read_text(errors="replace").splitlines():
        if not l.strip():
            continue
        try:
            k = json.loads(l).get("id")
        except Exception:
            k = hashlib.sha1(l.encode()).hexdigest()
        if k not in ids:
            uniq.append(l)
            ids.add(k)
    if uniq and not DRY:
        backup(main_file)
        main_file.parent.mkdir(parents=True, exist_ok=True)
        with main_file.open("a") as f:
            f.write("\n".join(uniq) + "\n")
    return len(uniq)

STUB = ("# MOVED — canonical copy lives in the MAIN checkout\n\n"
        "Canonical: {main}/{rel}\n"
        "One state file per repository (zuvo backlog-protocol, worktree rule). "
        f"This worktree copy was merged into the canonical file on {TODAY}. Do not write here.\n")

merged_report, left_tracked, stubbed, skipped_clone = [], [], [], []

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
        if not wt.exists() or wt.stat().st_size == 0:
            continue
        if "MOVED — canonical" in wt.read_text(errors="replace")[:200]:
            continue  # already stubbed
        main_file = mr / rel
        label = repo.name
        n = merge_md(main_file, wt, label) if kind == "md" else merge_jsonl(main_file, wt)
        merged_report.append((repo.name, rel, n, mr.name))
        if is_tracked(str(repo), rel):
            left_tracked.append((repo.name, rel))
        else:
            if not DRY:
                wt.write_text(STUB.format(main=mr, rel=rel))
            stubbed.append((repo.name, rel))

print(f"{'DRY-RUN ' if DRY else ''}CONSOLIDATION REPORT ({TODAY})")
print(f"worktree copies processed: {len(merged_report)}")
for name, rel, n, main in merged_report:
    print(f"  {name}/{rel}: +{n} unique -> {main}/{rel}")
print(f"stubbed (untracked wt copies): {len(stubbed)}")
print(f"left in place (git-TRACKED in worktree — resolve via branch merge): {len(left_tracked)}")
for name, rel in left_tracked:
    print(f"  TRACKED: {name}/{rel}")
