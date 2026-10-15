"""Rank a repo's knowledge entries for one task: knowledge-prime Steps 3 and 4 in code.

    rank(main_root, keywords, files, k=10) -> [{"id", "type", "section", "score"}, ...]
    # sections in Step 4 priority order, best first within each

With keywords or files: only entries with BM25 overlap (tags + fact + recommendation; legacy entries:
content + implication) or an affectedFiles glob hit are candidates; glob hits first, then BM25 order, fill
a pool of POOL. The shared rerank client scores the pool (ZUVO_KNOWLEDGE_RERANK_MODEL), a glob hit adds
GLOB_BOOST, and recency breaks the remaining ties. A failed rerank keeps the BM25 scores; an empty pool
makes no request. Every pool member stays eligible, a negative rerank score sorting it last, and nothing
outside the pool is kept, so the boost cannot surface an entry nobody scored.

With neither (the session prime) there is no query to rank by: Step 3's rows that need no task decide
(krs.prime_score), entries below 1 are dropped, and no request is made, so the store stays on the machine.

Read-only: the store is never written. A malformed line is reported on stderr in Step 2's wording and
skipped, never repaired; of two lines with one type and id the newer is kept and the other reported.
"""

from __future__ import annotations

import errno
import json
import os
import sys
from pathlib import Path

import zuvo_bm25 as bm25
import zuvo_knowledge_rank_score as krs
import zuvo_rerank as rerank_client
from zuvo_knowledge_rank_score import Entry

DEFAULT_MODEL = "voyageai/rerank-2.5"
POOL = 50
MAX_DOC_CHARS = 2000  # per document sent to the reranker: bounds egress and spend per entry
MAX_QUERY_CHARS = 1000
GLOB_BOOST = 0.1  # times the pool's best score: decides between near-equals, never buries a strong match
TOTAL_CAP = 10
SECTIONS = {"MUST AVOID": 3, "GOTCHAS": 2, "DECISIONS": 2, "CODEBASE FACTS": 2, "PATTERNS": 1}


def _lines(path: Path) -> list[str]:
    # Iterating a newline="" file ends lines at \n and \r\n only; splitlines() would also cut at U+2028 and
    # \x1c-\x1e, legal inside JSON strings. utf-8-sig drops a BOM a Windows editor left on line 1.
    try:
        with path.open(encoding="utf-8-sig", errors="replace", newline="") as f:
            return list(f)
    except OSError as exc:
        reason = errno.errorcode.get(exc.errno or 0, type(exc).__name__)
        print(f"[KNOWLEDGE] could not read knowledge/{path.name}: {reason}", file=sys.stderr)
        return []


def _parse(line: str) -> Entry | None:
    try:
        entry = json.loads(line)
    except (ValueError, RecursionError):
        return None
    return entry if isinstance(entry, dict) and isinstance(entry.get("id"), str) else None


def load(main_root: Path) -> list[Entry]:
    kept: dict[tuple[str, str], tuple[Entry, str]] = {}
    for path in sorted((main_root / "knowledge").glob("*.jsonl")):
        for n, line in enumerate(_lines(path), 1):
            entry = _parse(line) if line.strip() else {}
            where = f"knowledge/{path.name} line {n}"
            if entry is None:
                print(f"[KNOWLEDGE] Preserved malformed line {n} in knowledge/{path.name}"
                      " — skipped for parsing", file=sys.stderr)
            if not entry:
                continue
            entry.setdefault("type", path.stem.removesuffix("s"))
            key = (str(entry["type"]), entry["id"])
            prev = kept.get(key)
            if prev is None or krs.recency(entry) > krs.recency(prev[0]):
                kept[key] = (entry, where)
            if prev is not None:
                skipped = prev[1] if kept[key][1] == where else where
                print(f"[KNOWLEDGE] duplicate id {entry['id']}: kept {kept[key][1]}, skipped {skipped}",
                      file=sys.stderr)
    return [entry for entry, _ in kept.values()]


def _relevance(entries: list[Entry], keywords: list[str], files: list[str]
               ) -> tuple[list[float], list[int]]:
    """Scores, and the pool: the only entries that may be kept, whatever their score."""
    query = " ".join(keywords + files)
    docs = [krs.text(e) for e in entries]
    lexical = bm25.scores(query, docs)
    hits = [krs.glob_hit(e, files) for e in entries]
    candidates = [i for i in range(len(entries)) if hits[i] or lexical[i] > 0]
    pool = sorted(candidates, key=lambda i: (not hits[i], -lexical[i]))[:POOL]
    scores = [0.0] * len(entries)
    if not pool:
        return scores, pool
    model = os.environ.get("ZUVO_KNOWLEDGE_RERANK_MODEL") or DEFAULT_MODEL
    reranked = rerank_client.rerank(model, query[:MAX_QUERY_CHARS], [docs[i][:MAX_DOC_CHARS] for i in pool],
                                    caller="knowledge-rank")
    for j, i in enumerate(pool):
        scores[i] = reranked[j] if reranked is not None and len(reranked) == len(pool) else lexical[i]
    best = max(scores)
    boost = GLOB_BOOST * (best if best > 0 else 1.0)  # a best of 0 or below would cancel or invert it
    for i in pool:
        scores[i] += boost if hits[i] else 0.0
    return scores, pool


def rank(main_root: Path, keywords: list[str], files: list[str], k: int = TOTAL_CAP) -> list[Entry]:
    entries = [e for e in load(main_root) if krs.section(e)]
    if keywords or files:
        scores, keep = _relevance(entries, keywords, files)
    else:
        scores = [krs.prime_score(e) for e in entries]
        keep = [i for i in range(len(entries)) if scores[i] >= 1]
    keep.sort(key=lambda i: krs.recency(entries[i]), reverse=True)
    keep.sort(key=lambda i: -scores[i])  # stable: recency survives only among equal scores
    taken = dict.fromkeys(SECTIONS, 0)
    picked: list[Entry] = []
    for i in keep:
        name = krs.section(entries[i]) or ""
        if len(picked) < min(k, TOTAL_CAP) and taken[name] < SECTIONS[name]:
            taken[name] += 1
            picked.append({"id": entries[i]["id"], "type": entries[i]["type"], "section": name,
                           "score": round(scores[i], 6)})
    order = list(SECTIONS)
    return sorted(picked, key=lambda r: order.index(r["section"]))
