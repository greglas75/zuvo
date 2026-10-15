"""Okapi BM25 over a small in-memory corpus — the cheap first stage before an API rerank.

    top_k("cache key", docs, 15) -> [indices of the 15 best docs, best first]

k1=1.5, b=0.75, idf = ln(1 + (N - df + 0.5) / (df + 0.5)), which is never negative, so a term no doc
holds scores 0 rather than reordering on noise. Tokens are `\\w+` runs after casefold, so Polish and
other non-ASCII words count. Ties keep input order; an empty query, an empty corpus or all-empty docs
return input order instead of dividing by zero. Stdlib only.
"""

from __future__ import annotations

import math
import re
from collections import Counter

K1 = 1.5
B = 0.75
_TOKEN = re.compile(r"\w+")


def tokens(text: str) -> list[str]:
    return _TOKEN.findall(text.casefold())


def scores(query: str, docs: list[str]) -> list[float]:
    """One BM25 score per doc, in input order."""
    terms = set(tokens(query))
    bags = [Counter(tokens(d)) for d in docs]
    lengths = [sum(b.values()) for b in bags]
    total = sum(lengths)
    if not terms or not docs or total == 0:
        return [0.0] * len(docs)
    n, avgdl = len(docs), total / len(docs)
    idf = {}
    for t in terms:
        df = sum(1 for bag in bags if t in bag)
        idf[t] = math.log(1 + (n - df + 0.5) / (df + 0.5))
    out = []
    for bag, dl in zip(bags, lengths, strict=True):
        s = 0.0
        for t in terms:
            tf = bag.get(t, 0)
            if tf:
                s += idf[t] * tf * (K1 + 1) / (tf + K1 * (1 - B + B * dl / avgdl))
        out.append(s)
    return out


def top_k(query: str, docs: list[str], k: int) -> list[int]:
    """Indices of the k best docs, best first; ties (and an all-zero corpus) keep input order."""
    s = scores(query, docs)
    return sorted(range(len(docs)), key=lambda i: -s[i])[:max(k, 0)]
