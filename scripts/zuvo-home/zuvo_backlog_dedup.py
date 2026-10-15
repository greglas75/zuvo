"""Which backlog entries are the same finding — checks layered on the frozen keys (H10 pins them).

`normalize_signature` signs a path plus the 8 words after it; on a table row whose Problem cell precedes
the File cell those words are metadata, so different findings in one file share an `fp:` key. Grouping
therefore also requires equal `group_signature`s, which can only remove a match the key made.
"""
import re
from typing import List

import zuvo_backlog_parse as zb

# Private on purpose: tokenise exactly like `normalize_signature`.
_PATH_RE = zb._PATH_RE
_WORD_RE = zb._WORD_RE

_SEVERITY_WORDS = frozenset({
    "critical", "crit", "high", "medium", "med", "low", "warning", "warn", "info", "error", "major",
    "minor", "blocker", "nit", "p0", "p1", "p2", "p3", "p4", "s1", "s2", "s3", "s4",
})
_STATUS_WORDS = frozenset({
    "open", "done", "resolved", "closed", "fixed", "wontfix", "won't fix", "todo", "in progress",
    "pending", "deferred", "stale", "new", "active", "blocked",
})
# Not `_`: it belongs to paths like `zuvo_backlog_io.py`.
_CELL_NOISE_RE = re.compile(r"[*`\[\]]")
_TOKEN_SPLIT_RE = re.compile(r"[\s,;]+")
_LINE_TAIL_RE = re.compile(r":\d+(?:[-–]\d+)?$")
_NON_WORD_RE = re.compile(r"[^\w\s']")
_SIGNATURE_WORDS = 8


def _cell_text(cell: str) -> str:
    return " ".join(_CELL_NOISE_RE.sub(" ", cell).split())


def _path_tokens(text: str) -> List[str]:
    tokens = [_LINE_TAIL_RE.sub("", t) for t in _TOKEN_SPLIT_RE.split(text) if t]
    return tokens if tokens and all(_PATH_RE.fullmatch(t) for t in tokens) else []


def _meta_text(text: str) -> str:
    return " ".join(_NON_WORD_RE.sub(" ", text.lower()).split())


def _is_metadata_cell(text: str) -> bool:
    meta = _meta_text(text)
    return (zb.ID_RE.fullmatch(text) is not None
            or bool(_path_tokens(text))
            or meta in _SEVERITY_WORDS
            or meta in _STATUS_WORDS
            or zb.DATE_RE.fullmatch(text) is not None)


def _basename(cells: List[str], body: str) -> str:
    for text in cells:
        tokens = _path_tokens(text)
        if tokens:
            return tokens[0].rsplit("/", 1)[-1].lower()
    m = _PATH_RE.search(body)
    return m.group(0).split(":", 1)[0].rsplit("/", 1)[-1].lower() if m else ""


def _problem_cell(cells: List[str]) -> str:
    """First non-metadata cell after the id. Positional, not longest: a source or closure-note cell
    can outrank a terse problem, and `Entry` carries no table header to pick the column by name."""
    ids = [i for i, text in enumerate(cells) if zb.ID_RE.fullmatch(text)]
    start = ids[0] + 1 if ids else 0
    return next((text for text in cells[start:] if not _is_metadata_cell(text)), "")


def table_signature(entry: zb.Entry) -> str:
    """basename + 8 words of the problem cell, markers stripped so a closed row signs like its twin."""
    cells = [text for text in (_cell_text(c) for c in entry.body.split("|")) if text]
    words = _WORD_RE.findall(zb.strip_resolution_markers(_problem_cell(cells)).lower())
    return _basename(cells, entry.body) + "|" + " ".join(words[:_SIGNATURE_WORDS])


def group_signature(entry: zb.Entry) -> str:
    """Table rows: `table_signature`; else "" — so a table row never groups with a non-table entry."""
    return table_signature(entry) if entry.kind == zb.KIND_TABLE else ""
