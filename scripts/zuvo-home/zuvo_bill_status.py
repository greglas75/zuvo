"""`bill --status`: attempts, errors, give-ups and cost of the last 24 h, and the defect verdict counts."""

from __future__ import annotations

import os
from collections import Counter
from datetime import timedelta

import zuvo_bill_config as C
from zuvo_review_ledger import iter_jsonl

API = 1


def status() -> int:
    bd = C.bill_data()
    recs = list(iter_jsonl(os.path.join(bd, "bill.log")))
    since = C.stamp(C.now() - timedelta(hours=24))
    day = [r for r in recs if r.get("ts", "") >= since]
    print(f"attempts: {len(recs)} total, {len(day)} in 24 h; errors 24 h: {sum('error' in r for r in day)}; "
          f"given up 24 h: {sum(bool(r.get('gave_up')) for r in day)}")
    print(f"API-price USD 24 h: {sum(r.get('usd') or 0 for r in day):.2f}; mean seconds: "
          f"{(sum(r.get('secs') or 0 for r in day) / len(day)) if day else 0:.0f}")
    c = Counter(d.get("verdict") for d in iter_jsonl(os.path.join(bd, "defects.jsonl")))
    if c:
        print("defect verdicts:", dict(c))
    return 0
