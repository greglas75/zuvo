#!/bin/sh
# Polyglot sh/python header — same reason as backlog-collect.py: `#!/usr/bin/env python3` dies on
# Windows/Git Bash. Keep it on ONE line and do not "tidy" the quoting.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Two-file backlog: move resolved entries into backlog-done.md, and answer "is this already known?"
over BOTH files at a cost that does not grow with the backlog.

    backlog-archive.py path    [--repo R]
    backlog-archive.py lookup  [--repo R] [--json] <text-or-B-id>   # exit 10 OPEN / 11 ARCHIVED / 0 ABSENT
    backlog-archive.py index   [--repo R] [--rebuild]
    backlog-archive.py archive [--repo R] [--dry-run] [--min-resolved N]
    backlog-archive.py verify  [--repo R]                           # exit 1 when a key is in BOTH

Why realpath everywhere: six ~/DEV checkouts reach ONE canonical backlog.md through symlinks, and
two of them are not git repos, so MAIN_ROOT degrades to cwd and `dirname($BACKLOG)` is six
different directories. Resolving is what stops one archive becoming six — and writing onto the
REALPATH is what stops os.replace() from turning the symlink into a regular file and forking the
1.2 MB backlog (the 2026-07-19 incident, which a naive fix would re-cause).

MEASURED, and why archiving mints ids: on the five entries that are currently in both files of the
canonical backlog, the id key matches 5/5 while the content key matches 0/5 — because closing an
entry REWRITES its text into a description of the fix (often in another language). Content hashing
therefore cannot bridge open→archived, and an entry without a `B-` id would be unfindable once
archived. So `archive` assigns an id to any entry that lacks one BEFORE moving it, and the contract
requires the resolution to be APPENDED to the original problem text rather than replacing it.
"""
import argparse
import contextlib
import hashlib
import os
import re
import subprocess
import sys
import time
from typing import List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_parse as zb  # noqa: E402  (path must be set before the import)

ARCHIVE_NAME = "backlog-done.md"
INDEX_NAME = ".backlog-index.tsv"
LOCK_NAME = ".backlog-archive.lock.d"
LOCK_WAIT = float(os.environ.get("ZUVO_LOCK_WAIT", "5"))
STALE_LOCK_S = 30.0


def sh(args: List[str], cwd: Optional[str] = None) -> str:
    try:
        r = subprocess.run(args, cwd=cwd, capture_output=True, text=True, timeout=15)
        return r.stdout.strip() if r.returncode == 0 else ""
    except (OSError, subprocess.SubprocessError):
        return ""


def main_root(repo_dir: str) -> str:
    """First `git worktree list` entry is ALWAYS the main worktree, even from a linked one."""
    out = sh(["git", "worktree", "list", "--porcelain"], cwd=repo_dir)
    if out.startswith("worktree "):
        return out.splitlines()[0][len("worktree "):]
    return sh(["git", "rev-parse", "--show-toplevel"], cwd=repo_dir) or repo_dir


def resolve(repo: str) -> Tuple[str, str, str]:
    """(declared backlog path, REAL backlog path, archive path beside the real file)."""
    root = main_root(repo)
    declared = os.path.join(root, "memory", "backlog.md")
    real = os.path.realpath(declared)
    return declared, real, os.path.join(os.path.dirname(real), ARCHIVE_NAME)


def read(path: str) -> str:
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except FileNotFoundError:
        return ""


def is_ignored(path: str) -> Optional[bool]:
    """True/False when the parent is a git repo, None when it is not (the canonical backlog is
    outside any repository, and `git check-ignore` there means nothing)."""
    d = os.path.dirname(path)
    if sh(["git", "rev-parse", "--is-inside-work-tree"], cwd=d) != "true":
        return None
    r = subprocess.run(["git", "check-ignore", "-q", path], cwd=d, capture_output=True)
    return r.returncode == 0


# ── lock: mkdir-atomic, pid-stamped, bounded retry, stale reclaim ────────────────────────────────
# Same semantics as scripts/zuvo-home/e2e-preflight's _lock_acquire (macOS ships no flock(1)):
# claim = mkdir + pid stamp, retry for ZUVO_LOCK_WAIT at 5 ticks/s, reclaim only a lock whose pid
# is dead or absent AND older than 30 s, release only what this pid owns.
class Lock:
    def __init__(self, directory: str) -> None:
        self.path = os.path.join(directory, LOCK_NAME)
        self.mine = False

    def __enter__(self) -> "Lock":
        waited = 0.0
        while True:
            try:
                os.mkdir(self.path)
                self.mine = True
                with open(os.path.join(self.path, "pid"), "w", encoding="utf-8") as fh:
                    fh.write(str(os.getpid()))
                return self
            except FileExistsError:
                if self._stale():
                    self._force_release()
                    continue
                if waited >= LOCK_WAIT:
                    sys.exit(f"backlog archive lock held: {self.path} (waited {LOCK_WAIT:g}s)")
                time.sleep(0.2)
                waited += 0.2
            except OSError as e:
                sys.exit(f"cannot take the archive lock at {self.path}: {e}")

    def _stale(self) -> bool:
        pidfile = os.path.join(self.path, "pid")
        try:
            age = time.time() - os.stat(self.path).st_mtime
        except OSError:
            return False
        if age < STALE_LOCK_S:
            return False
        try:
            with open(pidfile, encoding="utf-8") as fh:
                pid = int(fh.read().strip())
        except (OSError, ValueError):
            return True                      # no readable pid and older than the stale window
        try:
            os.kill(pid, 0)
            return False                     # a live holder is never stolen from
        except ProcessLookupError:
            return True
        except PermissionError:
            return False

    def _force_release(self) -> None:
        with contextlib.suppress(OSError):
            os.unlink(os.path.join(self.path, "pid"))
        with contextlib.suppress(OSError):
            os.rmdir(self.path)

    def __exit__(self, *exc: object) -> None:
        if not self.mine:
            return
        try:
            with open(os.path.join(self.path, "pid"), encoding="utf-8") as fh:
                owner = fh.read().strip()
        except OSError:
            owner = ""
        if owner in ("", str(os.getpid())):
            self._force_release()
        self.mine = False


def atomic_write(real_path: str, text: str, mode: Optional[int]) -> None:
    """Write onto the REAL path. Never onto a symlink: os.replace() would replace the link itself."""
    d = os.path.dirname(real_path) or "."
    tmp = os.path.join(d, f".{os.path.basename(real_path)}.tmp.{os.getpid()}")
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(text)
    if mode is not None:
        os.chmod(tmp, mode)
    os.replace(tmp, real_path)


def query_key(q: str) -> str:
    """A bare B-id keys as an id; anything else is treated as candidate entry text."""
    s = q.strip()
    if zb.ID_RE.fullmatch(s):
        return "id:" + s.lower()
    return zb.entry_key(s)


def find(path: str, key: str) -> Optional[zb.Entry]:
    for e in zb.iter_entries(read(path)):
        if e.key == key:
            return e
    return None


def cmd_path(a: argparse.Namespace) -> int:
    declared, real, archive = resolve(a.repo)
    print(f"declared {declared}")
    print(f"real     {real}" + ("  (symlinked)" if os.path.realpath(declared) != declared else ""))
    print(f"archive  {archive}" + ("" if os.path.exists(archive) else "  (absent)"))
    return 0


def cmd_lookup(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    key = query_key(a.query)
    op, dn = find(real, key), find(archive, key)
    if op is not None:
        extra = f' (ALSO ARCHIVED {ARCHIVE_NAME}:{dn.lineno} — run verify)' if dn else ""
        print(f"OPEN {key} {op.ident or '-'} backlog.md:{op.lineno}{extra}")
        return 10
    if dn is not None:
        print(f'ARCHIVED {key} {dn.ident or "-"} {ARCHIVE_NAME}:{dn.lineno} section="{dn.section}"')
        return 11
    print(f"ABSENT {key}")
    return 0


def cmd_index(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    out = os.path.join(os.path.dirname(real), INDEX_NAME)
    rows = ["# key\tstatus\tfile\tline\tid\tsection"]
    for path, label in ((real, "backlog.md"), (archive, ARCHIVE_NAME)):
        for e in zb.iter_entries(read(path)):
            sec = e.section.replace("\t", " ")
            rows.append(f"{e.key}\t{e.status}\t{label}\t{e.lineno}\t{e.ident or '-'}\t{sec}")
    atomic_write(out, "\n".join(rows) + "\n", None)
    print(f"{out}: {len(rows) - 1} entries")
    return 0


def cmd_verify(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    op = {e.key: e for e in zb.iter_entries(read(real), checkbox_only=True)}
    dn = {e.key: e for e in zb.iter_entries(read(archive), checkbox_only=True)}
    both = sorted(set(op) & set(dn))
    # A DECLARED regression is the contract's own re-open path, not a violation: the protocol says to
    # re-open under the SAME id with a back-link, which necessarily puts that id in both files. A gate
    # that flagged it would punish the behaviour it mandates. Only an UNdeclared pair is a violation —
    # and that distinction is why the marker is required wording rather than a free-form note.
    regressions = [k for k in both if zb.REOPEN_RE.search(op[k].body)]
    bad = [k for k in both if k not in set(regressions)]
    if not bad:
        extra = f", {len(regressions)} declared regression(s)" if regressions else ""
        print(f"OK disjoint: {len(op)} open, {len(dn)} archived{extra}")
        return 0
    print(f"VIOLATION {len(bad)} key(s) defined in BOTH files without declaring a regression:")
    for k in bad:
        print(f"  {k}  backlog.md:{op[k].lineno}  {ARCHIVE_NAME}:{dn[k].lineno}")
    if regressions:
        print(f"  ({len(regressions)} further pair(s) declare REGRESSION and are legitimate)")
    print("  Each one is either a stale open copy (remove it), a partial closure (say which part the")
    print("  archived entry closed), or a genuine regression (re-open per backlog-protocol.md).")
    return 1


def mint_id(body: str) -> str:
    """Deterministic id for an entry being archived without one, so it stays addressable."""
    return "B-A" + time.strftime("%Y%m%d") + "-" + hashlib.sha1(body.encode()).hexdigest()[:6]


def cmd_archive(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    text = read(real)
    if not text:
        sys.exit(f"no backlog at {real}")
    lines = text.splitlines(keepends=True)

    movable: List[Tuple[int, zb.Entry]] = []
    skipped_nested: List[str] = []
    skipped_unmarked: List[str] = []
    for e in zb.iter_entries(text, checkbox_only=True):
        if e.status != "done":
            continue
        if "[ ]" in e.body:
            skipped_nested.append(e.ident or e.key)      # a live sub-item would go out of sight
            continue
        if not zb.has_resolution_marker(e.body):
            skipped_unmarked.append(e.ident or e.key)    # ticked but silent about why
            continue
        movable.append((e.lineno, e))

    if len(movable) < a.min_resolved:
        print(f"nothing to do: {len(movable)} resolved entries < --min-resolved {a.min_resolved}")
        return 0

    mints = [e for _, e in movable if not e.ident]
    if a.dry_run:
        print(f"would move {len(movable)} resolved entries out of backlog.md into {ARCHIVE_NAME}")
        print(f"  would mint an id for {len(mints)} of them (unaddressable once archived otherwise)")
        for _, e in movable[:5]:
            print(f"  - {e.ident or '(no id)'} line {e.lineno}: {e.body[:80]}")
        if skipped_nested:
            print(f"  SKIP {len(skipped_nested)} with a live [ ] sub-item: {skipped_nested[:5]}")
        if skipped_unmarked:
            print(f"  SKIP {len(skipped_unmarked)} ticked without a resolution marker: "
                  f"{skipped_unmarked[:5]}")
        return 0

    # `git check-ignore` answers for paths that do not exist yet, which is the whole point here:
    # the question is whether the archive WOULD be tracked, not whether it already is. Defaulting
    # an absent archive to the source's own status disabled this check entirely (caught by A10).
    src_ignored = is_ignored(real)
    arch_ignored = is_ignored(archive)
    if src_ignored and arch_ignored is False:
        rel = os.path.basename(archive)
        sys.exit(f"refusing to create a git-TRACKED archive beside a git-IGNORED backlog.\n"
                 f"add this line to .gitignore first, then re-run:\n    /memory/{rel}")

    with Lock(os.path.dirname(real)):
        text = read(real)                                   # re-read under the lock
        lines = text.splitlines(keepends=True)
        moved: List[str] = []
        drop = set()
        for lineno, e in movable:
            idx = lineno - 1
            if idx >= len(lines) or lines[idx].rstrip("\n") != e.raw:
                sys.exit("backlog changed under the lock — re-run")
            line = lines[idx]
            if not e.ident:
                # Insert the minted id right after the checkbox. Explicit slicing rather than a
                # lambda in re.sub: the callback would close over the loop variable (ruff B023),
                # which is correct here only by accident of evaluation order.
                m_cb = re.match(r"^(\s*[-*]\s*\[[ xX]\]\s*)", line)
                if m_cb:
                    line = line[:m_cb.end()] + mint_id(e.body) + " " + line[m_cb.end():]
            moved.append(line if line.endswith("\n") else line + "\n")
            drop.add(idx)
        kept = [ln for i, ln in enumerate(lines) if i not in drop]

        header = (f"\n## Archived from backlog.md on {time.strftime('%Y-%m-%d')} "
                  f"({len(moved)} completed items moved out)\n")
        old_archive = read(archive)
        new_archive = old_archive + header + "".join(moved)

        # byte conservation, BEFORE either rename: every moved line must be present verbatim in the
        # new archive, and the open file must shrink by exactly the moved lines.
        for ln in moved:
            if ln not in new_archive:
                sys.exit("internal: a moved line is not present in the archive — nothing written")
        if len(kept) != len(lines) - len(moved):
            sys.exit("internal: line accounting mismatch — nothing written")

        src_mode = os.stat(real).st_mode & 0o7777
        atomic_write(archive, new_archive, src_mode if not os.path.exists(archive) else None)
        atomic_write(real, "".join(kept), None)

    print(f"moved {len(moved)} entries to {archive}")
    if mints:
        print(f"minted an id for {len(mints)} entries that had none")
    if skipped_nested:
        print(f"skipped {len(skipped_nested)} with a live [ ] sub-item (split them first): "
              f"{skipped_nested[:5]}")
    if skipped_unmarked:
        print(f"skipped {len(skipped_unmarked)} ticked without a resolution marker: "
              f"{skipped_unmarked[:5]}")
    return 0


def main(argv: Optional[List[str]] = None) -> int:
    ap = argparse.ArgumentParser(prog="backlog-archive.py", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--repo", default=os.getcwd())
    sub.add_parser("path", parents=[common])
    p = sub.add_parser("lookup", parents=[common]); p.add_argument("query")
    p = sub.add_parser("index", parents=[common]); p.add_argument("--rebuild", action="store_true")
    sub.add_parser("verify", parents=[common])
    p = sub.add_parser("archive", parents=[common])
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--min-resolved", type=int, default=1)
    a = ap.parse_args(argv)
    return {"path": cmd_path, "lookup": cmd_lookup, "index": cmd_index,
            "verify": cmd_verify, "archive": cmd_archive}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
