"""`bill --status`: attempts, errors, give-ups, cost and omitted findings, and the defect verdict counts."""

from __future__ import annotations

import os
from collections import Counter
from datetime import timedelta
from typing import Any

import zuvo_bill_config as C
from zuvo_review_ledger import iter_jsonl

API = 2


def status() -> int:
    bd = C.bill_data()
    recs = list(iter_jsonl(os.path.join(bd, "bill.log")))
    since = C.stamp(C.now() - timedelta(hours=24))
    day = [r for r in recs if r.get("ts", "") >= since]
    print(f"attempts: {len(recs)} total, {len(day)} in 24 h; errors 24 h: {sum('error' in r for r in day)}; "
          f"given up 24 h: {sum(bool(r.get('gave_up')) for r in day)}")
    print(f"API-price USD 24 h: {sum(r.get('usd') or 0 for r in day):.2f}; mean seconds: "
          f"{(sum(r.get('secs') or 0 for r in day) / len(day)) if day else 0:.0f}")
    # Findings an answer left out, and defects dropped from it as malformed or conflicting, stay
    # unjudged by design (re-asking re-pays the whole review): counted on settled attempts only — one
    # that is retried reports them again on the next try.
    print(f"omitted findings: {_settled(recs, 'omitted')} total, {_settled(day, 'omitted')} in 24 h; "
          f"dropped defects: {_settled(recs, 'dropped_defects')} total, "
          f"{_settled(day, 'dropped_defects')} in 24 h")
    holder = C.lock_holder()   # a hung tick keeps the lock: flock has no age takeover
    if holder is not None:
        pid, _, since = holder.partition(" ")
        print(f"lock held by pid {pid} since {since}" if since else "lock held (holder not named yet)")
    c = Counter(d.get("verdict") for d in iter_jsonl(os.path.join(bd, "defects.jsonl")))
    if c:
        print("defect verdicts:", dict(c))
    return 0


def _settled(recs: list[dict[str, Any]], key: str) -> int:
    """Sum of the integer `key` over attempts whose verdicts were settled: recorded, or project-missing
    (they can never land; the run is done)."""
    return sum(r[key] for r in recs
               if (r.get("recorded") is True or r.get("recorded") == "project-missing")
               and isinstance(r.get(key), int) and not isinstance(r[key], bool))
