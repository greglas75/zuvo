"""THE WORK QUEUE and how it is SPLIT: one row per entry, chunked by block bytes, never mid-entry.
Imported by backlog-groom.py; not a script, no shebang, no executable bit.

WHY THE SPLIT IS BY BYTES AND NOT BY COUNT, measured rather than assumed. This repo's backlog is
~290 KB over 483 entries, which averages 0.6 KB — and a count-based split of it produces a 40 KB
agent, because one section holds 117 entries in 13 KB while a single heading entry runs to 17.7 KB.
8 of 9 sub-agents measurably jammed on 90-180 KB chunks, so the cap is the CQ6 control and not a
tidiness preference. A 1-line block cannot under-measure here, because the measurement is bytes.

WHY `end_lineno` AND NOT THE ENTRY'S OWN LINE. PR 1's `entry_block` is the only producer of a
meaningful span: an entry is not one line (real entries run 30+ lines of continuation prose, file
lists and recipes), and measuring the first line alone reports the largest entry in the file as the
smallest. A HEADING entry's block deliberately CONTAINS its children, so a parent and its children
are both measured — the total over-counts the file, which is the conservative direction for a cap.

Its own module for the reason the six siblings are, and the number is the argument: backlog-groom.py
measured 439 raw lines with this inlined, against `rules/file-limits.md`'s 400-line default for a
Python module (800 is the automatic CQ11 FAIL). And this is ONE cohesive concern — what a verifier is
handed, and how much of it at a time. WHICH entries are queued is the command's decision; this decides
the shape and the batching.

The underscore in the name is load-bearing, as in the siblings: `install.sh` globs
`scripts/zuvo-home/*` into the machine-global `~/.zuvo/`, so these end up FLAT with no package around
them and a plain same-directory import resolves identically in both layouts. `sys.path` is the
IMPORTER's job. By importing the parser this module joins the pin-guard family that
`tests/hooks/test-backlog-headings.sh` (H19c) DERIVES, where its expectation is the default one: NO
`iter_entries` call lives here — reading the file is backlog-groom.py's job.
"""
import json
import os
from typing import Any, Dict, List, Optional, Sequence

import zuvo_backlog_ledger as zl
import zuvo_backlog_parse as zb
import zuvo_backlog_verdicts as zv
from zuvo_backlog_block import entry_block

Row = Dict[str, Any]                 # what goes into the JSONL; typing it tighter would be fiction,
                                     # exactly as `zuvo_backlog_ledger.Row` says of its own
QUEUE_NAME = "backlog-verify-queue.jsonl"
CHUNK_CAP = 25000                    # ~25 KB per agent — see the module docstring for the measurement


def queue_row(lines: List[str], e: zb.Entry, verdict: Optional[zv.Verdict], reused: bool) -> Row:
    """One row per entry — the verifier contract's `{id, keys, text_sha, raw_text, section,
    cited_paths}` plus the span and the batching this module adds.

    EVERY entry gets a row, including the ones already decided, so the queue's length IS
    `entry_count` and conservation against it is a number a reader can check against the file. The
    dispatcher skips a row that already carries a `verdict`; dropping those rows instead would make
    "483 entries, 405 queued" two figures nobody can reconcile without re-parsing the backlog.
    """
    end = entry_block(lines, e.lineno - 1)
    return {"id": e.ident or e.key,
            "keys": sorted(zb.keys_for(e.body, e.ident)),
            "text_sha": zl.text_sha(e.body),
            "raw_text": "".join(lines[e.lineno - 1:end]),
            "section": e.section,
            "cited_paths": zv.cited_paths(e.body),
            "kind": e.kind,
            "lineno": e.lineno,
            "end_lineno": end,
            "bytes": sum(len(ln.encode("utf-8")) for ln in lines[e.lineno - 1:end]),
            "chunk": None,
            "reused": reused,
            "verdict": verdict.verdict if verdict else None,
            "evidence": verdict.evidence if verdict else None,
            "verified_by": zv.VERIFIED_BY % verdict.klass if verdict else None}


def assign_chunks(rows: Sequence[Row], cap: int) -> List[int]:
    """Number every row that still needs a model, in document order, into byte-capped chunks, and
    return the per-chunk byte totals so a caller prints the split instead of recomputing it.

    AN ENTRY IS NEVER SPLIT. A row larger than `cap` therefore becomes a chunk of its own and that
    chunk exceeds the cap — the alternative is handing an agent half an entry, which is a wrong
    question rather than a big one.
    """
    totals: List[int] = []
    cur = 0
    for row in rows:
        if row["verdict"] is not None or row["reused"]:
            continue
        size = row["bytes"]
        # `cur` and not `totals`: an oversize FIRST row leaves `totals` empty, and testing that
        # instead let the row after it join the chunk the oversize one had already filled.
        if cur and cur + size > cap:
            totals.append(cur)
            cur = 0
        row["chunk"] = len(totals)
        cur += size
    if cur:
        totals.append(cur)
    return totals


def chunk_report(rows: Sequence[Row], cap: int) -> List[str]:
    """`CHUNKS=`/`CHUNK=` report lines, after assigning the chunks. Returned rather than printed, so a
    test can read the split without parsing stdout.

    The span is min(lineno)..max(end_lineno) over the chunk's OWN rows, never the first and last row's
    numbers: a heading entry's block contains its children, so the last row's `end_lineno` is routinely
    SMALLER than its parent's and a first/last label reads as a chunk that ends before it began.
    """
    totals = assign_chunks(rows, cap)
    out = ["CHUNKS=%d cap=%d max=%d" % (len(totals), cap, max(totals) if totals else 0)]
    for i, size in enumerate(totals):
        mine = [r for r in rows if r["chunk"] == i]
        lo = min(r["lineno"] for r in mine) if mine else "-"
        hi = max(r["end_lineno"] for r in mine) if mine else "-"
        out.append("CHUNK=%d bytes=%d entries=%d lines=%s-%s" % (i, size, len(mine), lo, hi))
    return out


def write(path: str, rows: Sequence[Row]) -> None:
    """The queue file, one JSON object per line, newline-terminated — the same shape as the ledger, so
    a truncated final line is detectable by the missing terminator rather than by a parse error."""
    # `os.path.dirname("queue.jsonl")` is "", and `os.makedirs("")` raises FileNotFoundError — so a
    # relative bare filename crashed the write rather than creating it in the current directory.
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)
    with open(path, "w", encoding="utf-8") as fh:
        for row in rows:
            fh.write(json.dumps(row, sort_keys=True, ensure_ascii=False) + "\n")
