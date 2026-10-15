"""groom's semantic pass: open entries that reword one another, which the exact keys cannot see.

    SEMANTIC_DUPLICATE=<lineno> <key> <other key> <score>    one per pair, against the earlier entry
    SEMANTIC_CHECKED=<entries answered>/<entries eligible>
    SEMANTIC_DUPLICATES=<n>[+partial] | skipped:<disabled|dry-run|no-client|no-key|failed|error>

REPORT LINES ONLY. A pair never enters the verdicts, a queue row, the groom ledger or `plan_reuse`: at
~0.89 F1 roughly one strong pair in ten is wrong, so the entry still goes to the verifier, and a later
run without a key has nothing to reuse. Entries `classify` already decided are neither asked nor sent,
and two entries with a shared exact key AND group signature are never a pair (classify's job, even when
it refused the row); table rows whose shared `fp:` key is metadata only still pair.

Each eligible entry with a BM25 candidate is one rerank request (its top-15 among the others,
`rerank-2.5-lite`, the add path's model and strong threshold), 8 workers walking the file in order; at
most ZUVO_GROOM_RERANK_MAX (300) requests are sent, and entries left when the budget is spent are not.
An entry is ANSWERED when its request succeeded or it shares no word with any other (no possible
duplicate, so no request and no budget); any entry that is not marks the count `+partial`. A failed
request, a wrong-length answer or an exception fails only its own entry. After BREAKER failures in a
row (in-flight requests count against it, so no more than BREAKER can fail before it opens) the
remaining entries fail without a request. `skipped:failed` means no entry was answered and every request
sent failed.
ZUVO_RERANK=0 (or a cap of 0) is read BEFORE the client is imported: the grooming suites run copies
holding only `zuvo_backlog_*.py`, and must read `disabled` there, not `no-client`. `--dry-run` sends
nothing. Any other failure is a skip line, with only the exception's type on stderr.
"""
from __future__ import annotations

import math
import os
import sys
import threading
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from types import ModuleType
from typing import NamedTuple, Sequence

import zuvo_backlog_dedup as zd
import zuvo_backlog_parse as zb
import zuvo_backlog_verdicts as zv

DEFAULT_MAX = 300
WORKERS = 8
BREAKER = 5
CALLER = "backlog-groom"


class Pair(NamedTuple):
    entry: zb.Entry       # the later of the two
    other: zb.Entry
    score: float


class Found(NamedTuple):
    pairs: list[Pair]
    checked: int          # entries answered: request succeeded, or nothing to compare with
    eligible: int


class Skipped(Exception):
    """The pass did not run; the message is the outcome."""


def _max_calls() -> int:
    try:  # not str.isdigit(): "²" and "--5" pass it, and int() then raises outside report's guard
        return max(0, int(os.environ.get("ZUVO_GROOM_RERANK_MAX") or DEFAULT_MAX))
    except ValueError:
        return DEFAULT_MAX


def _client(max_calls: int) -> tuple[ModuleType, ModuleType]:
    if os.environ.get("ZUVO_RERANK") == "0" or not max_calls:
        raise Skipped("disabled")
    try:
        import zuvo_bm25 as bm25
        import zuvo_rerank as rr
        refused = rr.available()   # an older copy has no available(): AttributeError, same skip
    except Exception as exc:   # absent or half-copied: a SyntaxError is not an ImportError
        sys.stderr.write("backlog-groom: semantic pass has no client: %s\n" % type(exc).__name__)
        raise Skipped("no-client") from exc
    if refused is not None:
        raise Skipped(refused)
    return bm25, rr


class _Index:
    """zuvo_bm25's scoring over docs tokenised ONCE; `top(i)` ranks the others against doc i."""

    def __init__(self, docs: list[str], bm25: ModuleType) -> None:
        self.k1, self.bags = bm25.K1, [Counter(bm25.tokens(d)) for d in docs]
        lens = [sum(bag.values()) for bag in self.bags]
        avg = sum(lens) / len(docs) if sum(lens) else 1.0
        self.norm = [bm25.K1 * (1 - bm25.B + bm25.B * n / avg) for n in lens]
        df = Counter(t for bag in self.bags for t in bag)
        self.idf = {t: math.log(1 + (len(docs) - c + 0.5) / (c + 0.5)) for t, c in df.items()}

    def _score(self, i: int, j: int) -> float:
        b = self.bags[j]
        return sum(self.idf[t] * b[t] * (self.k1 + 1) / (b[t] + self.norm[j]) for t in self.bags[i] if t in b)

    def top(self, i: int, k: int) -> list[int]:
        ranked = sorted((-self._score(i, j), j) for j in range(len(self.bags)) if j != i)
        return [j for s, j in ranked if s < 0][:k]


class _Gate:
    """The request budget and the breaker, decided under ONE lock: `admit` reserves a slot or says why
    not. In-flight requests count as possible failures, so at most BREAKER fail in a row before it opens."""

    def __init__(self, max_calls: int) -> None:
        self.cond, self.left, self.failures, self.inflight = threading.Condition(), max_calls, 0, 0

    def admit(self) -> str:
        with self.cond:
            while self.left and self.failures < BREAKER <= self.failures + self.inflight:
                self.cond.wait()
            go = int(self.failures < BREAKER and self.left > 0)
            self.left, self.inflight = self.left - go, self.inflight + go
            return "sent" if go else "failed" if self.failures >= BREAKER else "capped"

    def record(self, ok: bool) -> None:
        with self.cond:
            self.inflight, self.failures = self.inflight - 1, 0 if ok else self.failures + 1
            self.cond.notify_all()


def _ask(i: int, docs: list[str], index: _Index, rr: ModuleType, gate: _Gate
         ) -> tuple[str, list[tuple[int, float]]]:
    """("ok" | "none" (no doc shares a word) | "capped" | "failed", (index, score) of strong neighbours)."""
    top = index.top(i, zd.POOL)
    if not top:
        return "none", []
    if (admitted := gate.admit()) != "sent":
        return admitted, []
    try:
        scores = rr.rerank(zd.MODEL, docs[i], [docs[j] for j in top], timeout=zd.TIMEOUT_S, caller=CALLER)
        if scores is None or len(scores) != len(top):
            raise ValueError("no usable scores")
        found = [(j, s) for j, s in zip(top, scores, strict=True) if zd.band(s) == "strong"]
    except Exception:  # an unusable answer fails its own entry, never the pass
        gate.record(False)
        return "failed", []
    gate.record(True)
    return "ok", found


def semantic_pairs(entries: Sequence[zb.Entry], *, max_calls: int, workers: int = WORKERS) -> Found:
    """Strong pairs among `entries` (already free of decided ones). Raises Skipped when it cannot run,
    or when no entry was answered and every request it sent failed."""
    bm25, rr = _client(max_calls)
    docs = [zb.strip_ident(e.body)[:zd.DOC_CAP] for e in entries]
    index, gate = _Index(docs, bm25), _Gate(max_calls)
    with ThreadPoolExecutor(max_workers=workers) as pool:
        answers = list(pool.map(lambda i: _ask(i, docs, index, rr, gate), range(len(entries))))
    checked = sum(status in ("ok", "none") for status, _ in answers)
    if not checked and any(status == "failed" for status, _ in answers):
        raise Skipped("failed")
    same = [(zb.keys_for(e.body, e.ident), zd.group_signature(e)) for e in entries]
    best: dict[tuple[int, int], float] = {}
    for i, (_, found) in enumerate(answers):
        for j, s in found:
            if not (same[i][0] & same[j][0] and same[i][1] == same[j][1]):
                pair = (min(i, j), max(i, j))
                best[pair] = max(s, best.get(pair, s))
    pairs = [Pair(entries[j], entries[i], round(s, 3)) for (i, j), s in sorted(best.items())]
    return Found(pairs, checked, len(entries))


def report(entries: Sequence[zb.Entry], verdicts: Sequence[zv.Verdict], dry_run: bool = False) -> None:
    """Print every SEMANTIC_* line for the open entries `verdicts` left undecided."""
    decided = {v.entry.lineno for v in verdicts}
    todo = [e for e in entries if e.status == "open" and e.lineno not in decided]
    cap = _max_calls()
    try:
        if dry_run and cap and os.environ.get("ZUVO_RERANK") != "0":   # the kill switch outranks it
            raise Skipped("dry-run")
        found = semantic_pairs(todo, max_calls=cap)
    except Exception as exc:  # never fatal: the plan is complete without this report
        if not isinstance(exc, Skipped):
            sys.stderr.write("backlog-groom: semantic pass skipped: %s\n" % type(exc).__name__)
        print("SEMANTIC_DUPLICATES=skipped:%s" % (exc if isinstance(exc, Skipped) else "error"))
        return
    for p in found.pairs:
        print("SEMANTIC_DUPLICATE=%d %s %s %.3f" % (p.entry.lineno, p.entry.key, p.other.key, p.score))
    print("SEMANTIC_CHECKED=%d/%d" % (found.checked, found.eligible))
    print("SEMANTIC_DUPLICATES=%d%s" % (len(found.pairs), "+partial" * (found.checked < found.eligible)))
