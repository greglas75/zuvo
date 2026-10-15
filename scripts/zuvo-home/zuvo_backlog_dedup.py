"""Which backlog entries are the same finding — checks layered on the frozen keys (H10 pins them).

`normalize_signature` signs a path plus the 8 words after it; on a table row whose Problem cell precedes
the File cell those words are metadata, so different findings in one file share an `fp:` key. Grouping
therefore also requires equal `group_signature`s, which can only remove a match the key made.

`candidates` is backlog-add's guess at a REWORDED duplicate the F- fingerprint does not merge (another
anchor, class or file; a hand-written entry): BM25 top-15 over the open and archived checkbox, heading
and table entries, then `rerank-2.5-lite`. It runs BEFORE the backlog lock and only names a candidate;
`confirm` re-checks it under the lock, and a concurrent change to that entry (gone, or its body
rewritten) drops the flag. Like `zuvo_rerank.rerank`, `candidates` never raises: a missing or
half-copied client module, or any other failure, is no candidate. `load` is this module's one parser
read (H19c in test-backlog-headings.sh counts it).
"""
import hashlib
import os
import re
from typing import List, NamedTuple, Optional, Sequence

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


MODEL = "voyageai/rerank-2.5-lite"
POOL = 15
DOC_CAP = 2000
TIMEOUT_S = 5.0
HIGH, LOW = 0.72, 0.55        # calibrated for MODEL on one gold set; rerank scores are not probabilities


class Candidate(NamedTuple):
    b_id: str
    score: float
    band: str                   # "strong" (>= HIGH) or "weak" (>= LOW)
    digest: str                 # of the body that was scored, so `recheck` sees a rewrite


def digest(body: str) -> str:
    return hashlib.sha256(body.encode("utf-8")).hexdigest()


def _with_id(e: zb.Entry) -> zb.Entry:
    """A table row with its id taken from the id cell; the parser gives rows none."""
    if e.ident or e.kind != zb.KIND_TABLE:
        return e
    return e._replace(ident=next((c for c in (c.strip() for c in e.body.split("|"))
                                  if zb.ID_RE.fullmatch(c)), ""))


def load(texts: Sequence[str]) -> List[zb.Entry]:
    """The checkbox, heading and table entries with an id in each text, open or ticked."""
    found = (_with_id(e) for text in texts
             for e in zb.iter_entries(text, kinds=(zb.KIND_CHECKBOX, zb.KIND_HEADING, zb.KIND_TABLE)))
    return [e for e in found if e.ident]


def _threshold(name: str, default: float) -> float:
    """The env override when it is a number in [0, 1] (nan fails both bounds), else `default`."""
    try:
        value = float(os.environ.get(name) or default)
    except ValueError:
        return default
    return value if 0.0 <= value <= 1.0 else default


def _band(score: float) -> Optional[str]:
    high, low = _threshold("ZUVO_BACKLOG_DUP_HIGH", HIGH), _threshold("ZUVO_BACKLOG_DUP_LOW", LOW)
    high, low = (high, low) if high >= low else (HIGH, LOW)
    return "strong" if score >= high else "weak" if score >= low else None


band = _band   # public: groom's semantic pass reuses the add path's bands


def candidates(entries: Sequence[zb.Entry], query: str) -> Optional[Candidate]:
    """The entry `query` most likely duplicates, or None: no band, no client, the API failed."""
    try:
        return _candidates(entries, query)
    except Exception:  # never fatal, like zuvo_rerank.rerank: a SyntaxError in a half-copied client too
        return None


def _candidates(entries: Sequence[zb.Entry], query: str) -> Optional[Candidate]:
    if os.environ.get("ZUVO_RERANK") == "0" or not entries:
        return None
    import zuvo_bm25 as bm25
    import zuvo_rerank as rr
    docs = [e.body[:DOC_CAP] for e in entries]
    lexical = bm25.scores(query, docs)
    top = sorted((i for i, s in enumerate(lexical) if s > 0), key=lambda i: -lexical[i])[:POOL]
    scores = rr.rerank(MODEL, query, [docs[i] for i in top], timeout=TIMEOUT_S, caller="backlog-add") \
        if top else None
    if not scores:
        return None
    best = max(range(len(top)), key=scores.__getitem__)
    band = _band(scores[best])
    e = entries[top[best]]
    return Candidate(e.ident, round(scores[best], 3), band, digest(e.body)) if band else None


def confirm(cand: Candidate, texts: Sequence[str]) -> Optional[Candidate]:
    """`cand` when an entry with its id still has the body that was scored; None once it is gone or
    rewritten. Parses only the texts that contain the id; backlog-add calls it under the lock, and only
    when it is about to append."""
    entries = load([text for text in texts if cand.b_id in text])
    return cand if any(e.ident == cand.b_id and digest(e.body) == cand.digest for e in entries) else None
