"""The per-project escape store: ~/.zuvo/review-escapes-data/<project>.jsonl, one row per escaped line.

The file is rewritten as the rows sorted by key, then the unkeyed lines in their order, blank lines
dropped; so a rerun over the same history and store is byte-identical and a change in it is a change in
the data. A fresh row is merged OVER the stored one: fields a later step adds survive a rescan.
--reclassify drops the STORED classification fields (CLASSIFY_FIELDS, failed attempts included) of
every row first, so classification restarts for the whole project, not only this run's window, while
classes written by the same upsert are kept.
The file name is the project name when it is made of [A-Za-z0-9._-] and at most NAME_MAX long; any
other name is rewritten (other characters to `_`, cut to fit) and gets `-` plus 8 hex of its sha1, so
two names never share a file and none reaches outside the store directory — on a case-sensitive
filesystem: on a case-insensitive one (macOS by default) names differing only in case share a file,
and two checkouts whose project basenames differ only in case are not supported. `''`, `.` and `..` are
refused (BadProject).

Rows are written with ASCII escapes, so a path holding non-UTF-8 bytes (a surrogate escape) is kept
exactly. A line the store cannot key (not a JSON object, no string `key`) is kept verbatim after the
rows, never dropped (upsert counts them: kept_unkeyed). well_formed() is the row shape every reader
relies on. The file is replaced by one rename: a run that fails before it leaves the previous file
untouched; a failed directory fsync after it is only a warning, the new file being complete.

One run at a time: an exclusive, non-blocking flock on `<store>.lock` (locked()), taken by the launcher
BEFORE it scans and held through the scan, the classification (which reads the store under it) and
the write, so no run computes its rows from a store another run is rewriting. A held lock makes the
run refuse (StoreBusy) before any work. upsert() takes no lock itself: its caller holds it (a second
flock on another descriptor of the same file would block even within one process). The kernel
releases the lock when its holder exits or is killed, so there is no staleness rule to get wrong; the
lock file itself is never removed (a removed-and-recreated lock file would let two runs hold "the"
lock on different inodes).
The directory name is not `review-escapes`: that is the helper itself in ~/.zuvo.
"""

from __future__ import annotations

import contextlib
import fcntl
import json
import hashlib
import os
import re
import sys
import tempfile
from collections.abc import Iterable, Iterator
from typing import Any

from zuvo_review_ledger import zuvo_home

STORE_DIR = "review-escapes-data"
CLASSIFY_FIELDS = frozenset({"class", "catchable", "class_reason", "classified_at", "classify_model",
                             "classify_attempts", "classify_failed_at"})
_UNSAFE = re.compile(r"[^A-Za-z0-9._-]")
NAME_MAX = 100
_TEXT_KEYS = ("key", "fix_sha", "intro_sha", "intro_file", "file")
_OID = re.compile(r"^(?:[0-9a-f]{40}|[0-9a-f]{64})$")


class StoreBusy(RuntimeError):
    """Another run holds the store's lock."""


class BadProject(ValueError):
    """The project name cannot name a file inside the store directory."""


def store_path(project: str) -> str:
    if project in ("", ".", ".."):
        raise BadProject(f"no store file can be named after project {project!r}")
    name = _UNSAFE.sub("_", project)
    if name != project or len(name) > NAME_MAX:
        tag = hashlib.sha1(project.encode("utf-8", "surrogateescape")).hexdigest()[:8]
        name = f"{name[:NAME_MAX - 9]}-{tag}"
    return os.path.join(zuvo_home(), STORE_DIR, f"{name}.jsonl")


@contextlib.contextmanager
def locked(path: str) -> Iterator[None]:
    lock = path + ".lock"
    os.makedirs(os.path.dirname(path), exist_ok=True)
    fd = os.open(lock, os.O_CREAT | os.O_RDWR, 0o644)
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise StoreBusy(f"{lock} is held by another run") from None
        yield
    finally:
        os.close(fd)  # closing the descriptor releases the flock


def well_formed(row: dict[str, Any]) -> bool:
    """Non-empty string key and paths, fix_sha and intro_sha full object ids (they reach git's argv,
    where `--x` would be an option), positive integer intro_line and line_at_parent."""
    lines = [row.get("intro_line"), row.get("line_at_parent")]
    return (all(isinstance(row.get(k), str) and row[k] for k in _TEXT_KEYS)
            and all(_OID.match(row[k]) for k in ("fix_sha", "intro_sha"))
            and all(isinstance(n, int) and not isinstance(n, bool) and n > 0 for n in lines))


def read(path: str) -> tuple[list[dict[str, Any]], list[str]]:
    """(the keyed rows, the other non-blank lines verbatim). A missing store reads as empty."""
    rows: list[dict[str, Any]] = []
    other: list[str] = []
    try:
        fh = open(path, encoding="utf-8", errors="surrogateescape")
    except FileNotFoundError:
        return rows, other
    with fh:
        for line in fh:
            text = line.rstrip("\n")
            try:
                obj = json.loads(text)
            except ValueError:
                obj = None
            if isinstance(obj, dict) and isinstance(obj.get("key"), str):
                rows.append(obj)
            elif text.strip():
                other.append(text)
    return rows, other


def merge_rows(existing: Iterable[dict[str, Any]], fresh: Iterable[dict[str, Any]],
               reclassify: bool) -> list[dict[str, Any]]:
    """Stored rows with `fresh` merged over them by key, sorted by key; with `reclassify`, the stored
    rows lose their classification fields first (a fresh row's own are kept)."""
    rows = {r["key"]: r for r in existing if isinstance(r.get("key"), str)}
    if reclassify:
        rows = {k: {f: v for f, v in r.items() if f not in CLASSIFY_FIELDS} for k, r in rows.items()}
    for rec in fresh:
        rows[rec["key"]] = {**rows.get(rec["key"], {}), **rec}
    return [rows[k] for k in sorted(rows)]


def _write_atomic(path: str, rows: list[dict[str, Any]], other: list[str]) -> None:
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path), prefix=".tmp-", suffix=".jsonl")
    try:
        with os.fdopen(fd, "w", encoding="utf-8", errors="surrogateescape") as f:
            f.writelines(json.dumps(r, sort_keys=True) + "\n" for r in rows)
            f.writelines(line + "\n" for line in other)
            f.flush()
            os.fsync(f.fileno())
        os.replace(tmp, path)
    except BaseException:
        with contextlib.suppress(FileNotFoundError):
            os.unlink(tmp)
        raise
    try:
        _fsync_dir(os.path.dirname(path))
    except OSError as exc:  # the new file is complete; only its durability across a crash is unsure
        sys.stderr.write(f"review-escapes: warning: fsync of {os.path.dirname(path)} failed: {exc}\n")


def _fsync_dir(path: str) -> None:
    """Make the rename itself durable: without it a crash can bring back the old file."""
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def upsert(path: str, fresh: list[dict[str, Any]], reclassify: bool = False) -> tuple[int, int]:
    """Merge `fresh` into the store at `path`; the caller holds locked(path). (rows, kept_unkeyed)."""
    stored, other = read(path)
    rows = merge_rows(stored, fresh, reclassify)
    _write_atomic(path, rows, other)
    return len(rows), len(other)
