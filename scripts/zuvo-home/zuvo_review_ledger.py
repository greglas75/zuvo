"""The one reader of the adversarial findings ledger and of the JSON-lines stores beside it.

Bill, review-escapes and curation all join on the same ledger; each carrying its own parser is how
they would start disagreeing about which verdict counts. Ledger rules, in one place:

- TSV, 11 columns: date run_id mode provider model fingerprint severity confidence file disposition
  project. A header row, `#` comments and short rows (incl. legacy 10-column ones) are skipped;
  extra columns are ignored.
- A verdict row (fixed / deferred / rejected) leaves mode/provider/model empty. The LATEST verdict per
  (project, fingerprint) wins — by timestamp, then by order, because merged copies are not in time order.
  Timestamps compare as strings: the driver writes one fixed-width ISO-8601 UTC form (`…T…Z`).
- `project` is an absolute main-checkout path on new rows and a bare basename on old ones, and the
  same repo is /Users/… on the Mac and /home/… elsewhere: every join keys on the basename. A row
  with no project has no key and joins nothing.
- `file` is `path:line`, sometimes a range (`13-15`), a bare path, or a placeholder (`unknown`, `?`, '').
- A MISSING file reads as empty (a fresh host). Any other read failure raises: an unreadable ledger
  must never look like a ledger with no findings.

Paths are resolved at call time, never at import: tests and a second ZUVO_HOME must not be pointed
at the real ~/.zuvo by a module imported earlier.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Iterable, Iterator
from typing import Any, NamedTuple

VERDICTS = frozenset({"fixed", "deferred", "rejected"})
_PLACEHOLDERS = frozenset({"", "unknown", "?", "n/a", "none"})
# `path:12`, `path:12-14`; the range dash may be any Unicode dash (one ledger row has U+2011).
_FILE_LINE = re.compile(r"^(.*):([0-9]+)(?:[-\u2010-\u2015\u2212][0-9]+)?$")
REMOTE_DEPTH = 2


def zuvo_home() -> str:
    return os.environ.get("ZUVO_HOME") or os.path.join(os.path.expanduser("~"), ".zuvo")


def ledger_path() -> str:
    return os.environ.get("ZUVO_FINDINGS_LOG_FILE") or os.path.join(zuvo_home(), "adversarial-findings.log")


def project_key(project: str) -> str | None:
    """`/Users/x/DEV/repo`, `/home/x/DEV/repo/` and `repo` are one project: `repo`. None when empty."""
    return os.path.basename(project.strip().rstrip("/")) or None


class LedgerRow(NamedTuple):
    ts: str
    run_id: str
    mode: str
    provider: str
    model: str
    fingerprint: str
    severity: str
    confidence: str
    file: str
    disposition: str
    project: str

    @property
    def project_key(self) -> str | None:
        return project_key(self.project)

    @property
    def is_verdict(self) -> bool:
        return self.disposition in VERDICTS


def split_file(value: str) -> tuple[str | None, int | None]:
    """(path, line) of a ledger `file` cell. Only a trailing line number (or range) is split off — any
    other colon belongs to the path. A placeholder path is (None, None); no line number is None."""
    v = value.strip()
    m = _FILE_LINE.match(v)
    path, line = (m.group(1), int(m.group(2))) if m else (v, None)
    if path.strip().lower() in _PLACEHOLDERS:
        return None, None
    return path, line


def read_rows(path: str | None = None) -> Iterator[LedgerRow]:
    """Every well-formed row, streamed (the ledger is never rotated). A missing ledger yields nothing;
    any other OSError propagates."""
    try:
        fh = open(path or ledger_path(), encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return
    with fh:
        for line in fh:
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 11 or cols[0] == "date" or cols[0].startswith("#"):
                continue
            yield LedgerRow(*cols[:11])


def latest_verdicts(rows: Iterable[LedgerRow]) -> dict[tuple[str, str], str]:
    """(project key, fingerprint) -> the disposition of its latest verdict row; project-less rows skipped."""
    best: dict[tuple[str, str], tuple[str, str]] = {}
    for r in rows:
        pkey = r.project_key
        if not r.is_verdict or pkey is None:
            continue
        key = (pkey, r.fingerprint)
        seen = best.get(key)
        if seen is None or r.ts >= seen[0]:
            best[key] = (r.ts, r.disposition)
    return {k: v[1] for k, v in best.items()}


def iter_jsonl(path: str) -> Iterator[dict[str, Any]]:
    """Every JSON object in a JSON-lines file; a torn line (a write in progress) or a non-object is
    skipped. A missing file yields nothing; any other OSError propagates."""
    try:
        fh = open(path, encoding="utf-8", errors="replace")
    except FileNotFoundError:
        return
    with fh:
        for line in fh:
            try:
                obj = json.loads(line)
            except ValueError:
                continue
            if isinstance(obj, dict):
                yield obj


def remote_roots(name: str) -> list[str]:
    """Copies of `name` (a path relative to a host's ~/.zuvo) mirrored under ~/.zuvo/remote/, looked up
    in the directories one and two levels down (remote/<host>/, remote/<group>/<host>/), sorted."""
    base = os.path.join(zuvo_home(), "remote")
    found: list[str] = []
    level = [base]
    for _ in range(REMOTE_DEPTH):
        level = [os.path.join(d, e) for d in level for e in _subdirs(d)]
        found.extend(p for p in (os.path.join(d, name) for d in level) if os.path.exists(p))
    return sorted(found)


def _subdirs(path: str) -> list[str]:
    try:
        return sorted(e.name for e in os.scandir(path) if e.is_dir(follow_symlinks=False))
    except OSError:
        return []
