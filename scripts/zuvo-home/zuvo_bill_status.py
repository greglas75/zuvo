"""`bill --status`: attempts, errors, give-ups, cost, omitted findings, unrecordable runs and the defect
verdict counts; with `--by-lane` / `--by-agreement`, Bill's precision per lane and per number of lanes that
raised a defect, from bill-data/defects.jsonl."""

from __future__ import annotations

import math
import os
from collections import Counter, defaultdict
from collections.abc import Callable, Iterable
from datetime import timedelta
from typing import Any

import zuvo_bill_config as C
import zuvo_bill_state as S
from zuvo_review_ledger import iter_jsonl

API = 3
_VERDICTS = ("real", "false_positive", "uncertain")


def status(by_lane: bool = False, by_agreement: bool = False) -> int:
    bd = C.bill_data()
    recs = list(iter_jsonl(os.path.join(bd, "bill.log")))
    since = C.stamp(C.now() - timedelta(hours=24))
    day = [r for r in recs if isinstance(r.get("ts"), str) and r["ts"] >= since]
    errors = sum(bool(r.get("error")) for r in day)
    print(f"attempts: {len(recs)} total, {len(day)} in 24 h; errors 24 h: {errors}; "
          f"given up 24 h: {sum(bool(r.get('gave_up')) for r in day)}")
    print(f"API-price USD 24 h: {sum(_num(r.get('usd')) for r in day):.2f}; mean seconds: "
          f"{(sum(_num(r.get('secs')) for r in day) / len(day)) if day else 0:.0f}")
    # Findings an answer left out, and defects dropped from it as malformed or conflicting, stay
    # unjudged by design (re-asking re-pays the whole review): counted on settled attempts only — one
    # that is retried reports them again on the next try.
    print(f"omitted findings: {_settled(recs, 'omitted')} total, {_settled(day, 'omitted')} in 24 h; "
          f"dropped defects: {_settled(recs, 'dropped_defects')} total, "
          f"{_settled(day, 'dropped_defects')} in 24 h")
    _unrecordable(bd)
    holder = C.lock_holder()   # a hung tick keeps the lock: flock has no age takeover
    if holder is not None:
        pid, _, held_since = holder.partition(" ")
        print(f"lock held by pid {pid} since {held_since}" if held_since
              else "lock held (holder not named yet)")
    defects = list(iter_jsonl(os.path.join(bd, "defects.jsonl")))
    c = Counter(d.get("verdict") for d in defects)
    if c:
        print("defect verdicts:", dict(c))
    if by_lane:
        _precision("by lane", "lane", defects, lambda lanes: lanes, lambda k, n: (-n, k))
    if by_agreement:
        _precision("by agreement", "lanes", defects, lambda lanes: [str(len(lanes))], lambda k, n: int(k))
    return 0


def _unrecordable(bd: str) -> None:
    """Reviews not judged for want of a checkout that are still unjudged and inside the age window — one
    figure per reason. One that was recorded since, or aged out, is no longer counted."""
    try:
        rows = list(iter_jsonl(os.path.join(bd, "unrecordable.jsonl")))
        done = S.read_done(os.path.join(bd, "judged-runs.txt"))
    except OSError as ex:
        print(f"unrecordable runs: unreadable ({type(ex).__name__}: {ex})")
        return
    oldest = C.stamp(C.now() - timedelta(hours=C.max_age_h()))
    open_runs: dict[str, str] = {}
    for r in rows:
        run, ts = r.get("run"), r.get("review_ts", r.get("ts"))
        if isinstance(run, str) and run not in done and isinstance(ts, str) and ts >= oldest:
            open_runs.setdefault(run, str(r.get("reason", "?")))
    if open_runs:
        by = Counter(open_runs.values())
        print(f"unrecordable runs, unjudged inside the {C.max_age_h()} h window: {len(open_runs)} — "
              + ", ".join(f"{k} {n}" for k, n in sorted(by.items())))


def _num(v: object) -> float:
    if isinstance(v, bool) or not isinstance(v, (int, float)):
        return 0.0
    return float(v) if math.isfinite(v) else 0.0


def _precision(title: str, column: str, defects: list[dict[str, Any]],
               keys: Callable[[list[str]], Iterable[str]], order: Callable[[str, int], Any]) -> None:
    """One table: per key, the reviews and defects it appears in, the verdict counts, and precision =
    real / (real + false_positive) — `-` when Bill never ruled either way. A defect without lanes (the
    agent judged all its findings during Bill's call) or with a verdict Bill does not give is left out."""
    groups: dict[str, list[dict[str, Any]]] = defaultdict(list)
    for d in defects:
        lanes = d.get("lanes")
        names = sorted({x for x in lanes if isinstance(x, str)}) if isinstance(lanes, list) else []
        if names and d.get("verdict") in _VERDICTS:
            for k in keys(names):
                groups[k].append(d)
    print(f"precision {title}:")
    print(f"  {column:<24} {'reviews':>7} {'defects':>7} {'real':>5} {'false_positive':>14} "
          f"{'uncertain':>9} {'precision':>9}")
    for k in sorted(groups, key=lambda k: order(k, len(groups[k]))):
        n = Counter(d["verdict"] for d in groups[k])
        ruled = n["real"] + n["false_positive"]
        prec = f"{n['real'] / ruled:.2f}" if ruled else "-"
        reviews = len({str(d.get("run")) for d in groups[k]})
        print(f"  {k:<24} {reviews:>7} {len(groups[k]):>7} {n['real']:>5} "
              f"{n['false_positive']:>14} {n['uncertain']:>9} {prec:>9}")


def _settled(recs: list[dict[str, Any]], key: str) -> int:
    """Sum of the integer `key` over attempts whose verdicts were recorded."""
    return sum(r[key] for r in recs
               if r.get("recorded") is True and isinstance(r.get(key), int) and not isinstance(r[key], bool))
