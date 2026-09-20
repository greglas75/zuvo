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
    backlog-archive.py status  [--repo R]                           # exit 12 when done work sits in backlog.md

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
from typing import Dict, List, Optional, Tuple

sys.path.insert(0, os.path.dirname(os.path.realpath(__file__)))
import zuvo_backlog_parse as zb  # noqa: E402  (path must be set before the import)

ARCHIVE_NAME = "backlog-done.md"
INDEX_NAME = ".backlog-index.tsv"
LOCK_NAME = ".backlog-archive.lock.d"
LOCK_WAIT = float(os.environ.get("ZUVO_LOCK_WAIT", "5"))
STALE_LOCK_S = 30.0


sh = zb.sh                  # shared with backlog-collect.py via the same module as the parsing —
main_root = zb.main_root    # duplicating them was the drift the shared module exists to prevent


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


def undeclared_pairs(real: str, archive: str) -> Tuple[List[str], List[str], Dict[str, zb.Entry],
                                                        Dict[str, zb.Entry]]:
    """Keys defined in BOTH files, split into undeclared (violations) and declared regressions."""
    op = {e.key: e for e in zb.iter_entries(read(real), checkbox_only=True)}
    dn = {e.key: e for e in zb.iter_entries(read(archive), checkbox_only=True)}
    both = sorted(set(op) & set(dn))
    regressions = [k for k in both if zb.REOPEN_RE.search(op[k].body)]
    return [k for k in both if k not in set(regressions)], regressions, op, dn


def cmd_verify(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    bad, regressions, op, dn = undeclared_pairs(real, archive)
    # A DECLARED regression is the contract's own re-open path, not a violation: the protocol says to
    # re-open under the SAME id with a back-link, which necessarily puts that id in both files. A gate
    # that flagged it would punish the behaviour it mandates — see undeclared_pairs().
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


def classify(text: str) -> Tuple[List[Tuple[int, zb.Entry]], List[str], List[str]]:
    """Split ticked entries into movable / held back. Shared so `status` and `archive` cannot drift.

    An entry stays put for exactly two reasons, both about not losing what was written: a live `[ ]`
    sub-item would go out of sight with its resolved parent, and a tick with no resolution marker is
    an entry whose WHY was never recorded — filing that away archives a decision nobody made.
    """
    movable: List[Tuple[int, zb.Entry]] = []
    nested: List[str] = []
    unmarked: List[str] = []
    for e in zb.iter_entries(text, checkbox_only=True):
        if e.status != "done":
            continue
        if "[ ]" in e.body:
            nested.append(e.ident or e.key)
            continue
        if not zb.has_resolution_marker(e.body):
            unmarked.append(e.ident or e.key)
            continue
        movable.append((e.lineno, e))
    return movable, nested, unmarked


def report_held(nested: List[str], unmarked: List[str]) -> None:
    """Held-back entries are printed even when nothing moves: they are finished work sitting in the
    open backlog too, and the only thing between them and the archive is a line saying why."""
    if nested:
        print(f"HELD {len(nested)} with a live [ ] sub-item (split the parent first): {nested[:5]}")
    if unmarked:
        print(f"HELD {len(unmarked)} ticked with no resolution marker (write the why, then they "
              f"move): {unmarked[:5]}")


def cmd_status(a: argparse.Namespace) -> int:
    """Is finished work sitting in the open backlog? Exit 12 when yes, 0 when the file is clean.

    Counts ENTRIES, never bytes. The reason for two files is order — a done item has no business in
    the list of what is left — so one archivable entry is already the finding, and the old "archive
    once it is ≥50 entries or >100 KB" framing measured the wrong thing.
    """
    _, real, archive = resolve(a.repo)
    text = read(real)
    if not text:
        print(f"OK no backlog at {real}")
        return 0
    movable, nested, unmarked = classify(text)
    total = sum(1 for _ in zb.iter_entries(text, checkbox_only=True))
    still_open = total - len(movable) - len(nested) - len(unmarked)
    if not movable:
        print(f"OK {real}: {still_open} open, nothing resolved left in backlog.md")
        report_held(nested, unmarked)
        return 0
    print(f"OVERDUE {real}: {len(movable)} resolved entries still in backlog.md "
          f"({still_open} genuinely open). They move VERBATIM into {os.path.basename(archive)} — "
          f"history is kept, nothing is deleted.")
    print(f"  run: backlog-archive.py archive --repo {a.repo}")
    report_held(nested, unmarked)
    return 12


def cmd_archive(a: argparse.Namespace) -> int:
    _, real, archive = resolve(a.repo)
    text = read(real)
    if not text:
        sys.exit(f"no backlog at {real}")
    lines = text.splitlines(keepends=True)

    movable, skipped_nested, skipped_unmarked = classify(text)

    # Never archive INTO an inconsistent namespace. If an id is already defined in both files, moving
    # more entries across cannot improve that and can compound it: a stale open copy of an entry the
    # archive already holds would land in the archive a SECOND time, and `verify` — which compares the
    # two files, not the archive against itself — would then report OK. The pairs need a per-entry
    # decision (stale copy / partial closure / real regression) before anything else moves.
    bad_pairs, _, _, _ = undeclared_pairs(real, archive)
    if bad_pairs:
        sys.exit(f"refusing to archive: {len(bad_pairs)} id(s) are already defined in BOTH files.\n"
                 f"run `backlog-archive.py verify --repo {a.repo}` and settle those first — "
                 f"archiving on top of them hides the duplicates inside the archive.")


    if len(movable) < a.min_resolved:
        print(f"nothing to do: {len(movable)} resolved entries < --min-resolved {a.min_resolved}")
        report_held(skipped_nested, skipped_unmarked)
        return 0

    mints = [e for _, e in movable if not e.ident]
    if a.dry_run:
        print(f"would move {len(movable)} resolved entries out of backlog.md into {ARCHIVE_NAME}")
        print(f"  would mint an id for {len(mints)} of them (unaddressable once archived otherwise)")
        for _, e in movable[:5]:
            print(f"  - {e.ident or '(no id)'} line {e.lineno}: {e.body[:80]}")
        report_held(skipped_nested, skipped_unmarked)
        return 0

    # `git check-ignore` answers for paths that do not exist yet, which is the whole point here:
    # the question is whether the archive WOULD be tracked, not whether it already is. Defaulting
    # an absent archive to the source's own status disabled this check entirely (caught by A10).
    src_ignored = is_ignored(real)
    arch_ignored = is_ignored(archive)
    if src_ignored and arch_ignored is False:
        rel = os.path.basename(archive)
        sys.exit(f"refusing to create a git-TRACKED archive beside a git-IGNORED backlog.\n"
                 f"add these lines to .gitignore first, then re-run:\n"
                 f"    /memory/{rel}\n"
                 f"    /memory/{LOCK_NAME}/\n"
                 f"    /memory/{INDEX_NAME}")

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
    report_held(skipped_nested, skipped_unmarked)
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
    sub.add_parser("status", parents=[common])
    p = sub.add_parser("archive", parents=[common])
    p.add_argument("--dry-run", action="store_true")
    p.add_argument("--min-resolved", type=int, default=1)
    a = ap.parse_args(argv)
    return {"path": cmd_path, "lookup": cmd_lookup, "index": cmd_index,
            "verify": cmd_verify, "status": cmd_status, "archive": cmd_archive}[a.cmd](a)


if __name__ == "__main__":
    sys.exit(main())
