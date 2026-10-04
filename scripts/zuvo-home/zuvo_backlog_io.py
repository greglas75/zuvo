"""THE FILESYSTEM LAYER of the two-file backlog: where the files are, how they are read, the
cross-process lock, and the only write primitive. Imported by backlog-archive.py; not a script, no
shebang, no executable bit.

Its own module for the reason the other three siblings are, and the number is the argument rather
than the taste: backlog-archive.py measured **763 raw lines** with this inlined, against
`rules/file-limits.md`'s 400-line default for a Python module (800 is the automatic CQ11 FAIL, which
the block boundary, the heading policy and the mint each had to rescue this file from in turn). And
this is ONE cohesive concern — resolving the canonical path, reading it, holding the lock and
replacing the bytes are four halves of a single question, "which file, and how do two processes
write it without losing each other's work". The commands above it decide WHAT moves; this decides
where it lands.

The underscore in the name is load-bearing, exactly as in the siblings: `install_zuvo_home`
(scripts/install.d/zuvo-home.sh) globs `scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so
io and the parser end up as FLAT siblings with no package around them. A plain same-directory
`import zuvo_backlog_parse` therefore resolves identically in the repo checkout and on the flattened
layout, while a hyphenated filename would not be importable at all and would force a dynamic
importlib load that mypy cannot see through. Putting the importer's directory on `sys.path` is the
IMPORTER's job (backlog-archive.py does it before importing this module); nothing here touches
`sys.path`, because a module that rewrites the path of whoever imports it is the one thing that
breaks in exactly one of the two layouts. `tests/hooks/test-backlog-headings.sh` (H24) asserts BOTH
layouts.

WHY `main_root` COMES FROM THE PARSER and not from a fresh implementation here: `resolve()` below is
the definition of "which backlog file", and six ~/DEV checkouts reach ONE canonical backlog through
symlinks. Two of them are not git repos, so `main_root` degrades to cwd — a second copy of that
degradation rule is the drift `zuvo_backlog_parse` exists to prevent (the same reason
backlog-collect.py reads it from there). Importing the parser has a second, deliberate consequence:
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES its pin-guard family as "the archiver plus
every `zuvo_backlog_*.py` that imports the parser", so this module joins that scan by existing. A
sibling that reached `main_root` some other way would fall OUT of the family, and the day someone
added an `iter_entries` call here it would be invisible in all four of the guard's dimensions —
a coverage hole created by a refactor, which is worse than the duplication it would have avoided.

THE THREE FAIL-OPENS BELOW ARE LOAD-BEARING, not oversights, and each has its own assertion in H24:
  * `is_ignored()` returns None — not False — when the parent is not a git repository. The canonical
    backlog lives outside any repo, and `git check-ignore` there answers a question that was never
    asked. cmd_archive's refusal reads `is_ignored(archive) is False` precisely so that "unknown"
    cannot masquerade as "tracked".
  * `read()` returns "" for a file that does not exist. `cmd_status` on a repo with no backlog must
    print `OK no backlog`, not a traceback: it runs from `append-runlog` at the end of every skill
    run in every repo on the machine, most of which have no backlog at all.
  * the archive is read under `Lock` but `cmd_verify` (in backlog-archive.py) falls back to an
    UNLOCKED read when the lock cannot be taken. A gate that cannot answer is worse than one that
    occasionally reads a transient state, because `append-runlog` turns a non-zero `verify` into
    `BACKLOG_NAMESPACE_VIOLATION` and blocks the run.
"""
import contextlib
import os
import subprocess
import sys
import time
from typing import Dict, Optional, Tuple

import zuvo_backlog_parse as zb

ARCHIVE_NAME = "backlog-done.md"
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
                try:
                    with open(os.path.join(self.path, "pid"), "w", encoding="utf-8") as fh:
                        fh.write(str(os.getpid()))
                except OSError:
                    # The directory exists but __enter__ has not returned, so `with` will never call
                    # __exit__ and nothing would release it. _stale() reclaims it after 30s (a missing
                    # pid reads as unowned), but every other archiver on this repo blocks until then.
                    # Clean up here instead of leaving a lock nobody owns.
                    with contextlib.suppress(OSError):
                        os.remove(os.path.join(self.path, "pid"))
                    with contextlib.suppress(OSError):
                        os.rmdir(self.path)
                    self.mine = False
                    raise
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
    # CLEANUP ON THE FAILURE PATH. Without the try/finally the temp file survived any post-write error
    # — a read-only directory, EXDEV, EPERM — leaving `.backlog.md.tmp.<pid>` in a TRACKED `memory/`
    # directory for ever, where the next `git status` presents it as an untracked file nobody can
    # explain. Cleanup existed only where it was not needed (the success path removes it by renaming
    # it). Found by the aggregate review's CQ audit as CQ38; the success path is unchanged, since after
    # a successful `os.replace` there is nothing at `tmp` to unlink.
    #
    # This does NOT close `B-20260928-IO-PREEXISTING-DATALOSS` item 3: the temp NAME is still
    # predictable and still opened with plain `open()`, so a pre-planted symlink is still followed.
    # That fix is `mkstemp`/`O_EXCL|O_NOFOLLOW` at creation, and it needs this `finally` regardless.
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
        if mode is not None:
            os.chmod(tmp, mode)
        os.replace(tmp, real_path)
    finally:
        with contextlib.suppress(OSError):
            os.unlink(tmp)


# LINE COUNTS, MEMOISED BY (resolved path, mtime, size). `unresolvable` is called once per verdict and
# three of the four deterministic classes cite `backlog.md`/`backlog-done.md` by basename, so the two
# biggest files in the repo were re-read for almost every row: measured on this repo, 503 entries ->
# 80 verdicts -> 93 full re-reads of those two files, 31.0 MB of I/O for a number that cannot have
# changed between them. Keyed on mtime+size rather than path alone so a file rewritten under the lock
# (which `apply` does, between `drop-stale` and `archive`) is counted again rather than remembered.
_LINES: Dict[Tuple[str, int, int], int] = {}


def line_count(target: str) -> int:
    """Lines in `target`, remembered for as long as its mtime and size are unchanged."""
    try:
        st = os.stat(target)
    except OSError:
        return 0
    key = (target, int(st.st_mtime_ns), st.st_size)
    if key not in _LINES:
        with open(target, encoding="utf-8", errors="replace") as fh:
            _LINES[key] = sum(1 for _ in fh)
    return _LINES[key]
