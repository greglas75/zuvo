"""Bill's own state files: what each holds, the writes that never raise, and the check a tick makes
before any paid call that it can write them at all.

WHAT IT WRITES

  ~/.zuvo/adversarial-findings.log   verdict rows with run_id "bill" (so they are told apart from an agent's):
                                     real -> deferred (accepted as a real defect), false_positive -> rejected,
                                     uncertain -> nothing. A finding that already has a verdict is never
                                     touched, and an agent's later verdict wins (latest row wins).
  ~/.zuvo/bill-data/defects.jsonl         one record per judged defect: class, verdict, severity, reason,
                                          lanes, ids
  ~/.zuvo/bill-data/lessons.jsonl         the generalizable lessons, per review (the knowledge base)
  ~/.zuvo/bill-data/judged-runs.txt       run ids already judged or given up on (Bill's own state)
  ~/.zuvo/bill-data/attempts.json         failed attempts per run; after BILL_MAX_TRIES the run is given up
  ~/.zuvo/bill-data/bill.log              one line per attempt: seconds, tokens, API-price USD, error
"""

from __future__ import annotations

import json
import os
import sys
import time
from collections.abc import Callable

import zuvo_bill_config as C

API = 2
# Every file a tick appends to or replaces; attempts.json is replaced through attempts.json.tmp.
STATE_FILES = ("bill.log", "judged-runs.txt", "attempts.json.tmp", "defects.jsonl", "lessons.jsonl")


def unwritable() -> str | None:
    """Why the state files cannot be written, or None. bill-data must take new files and renames
    (attempts.json is replaced through attempts.json.tmp); an existing file is opened for append —
    nothing truncated, nothing created. Without judged-runs.txt or attempts.json a finished run is paid
    for again on every tick, so the tick stops before paying."""
    bd = C.bill_data()
    if not os.access(bd, os.W_OK | os.X_OK):
        return f"{bd}: not writable"
    for name in STATE_FILES:
        path = os.path.join(bd, name)
        try:
            if os.path.lexists(path):
                with open(path, "a"):
                    pass
        except OSError as ex:
            return f"{path}: {type(ex).__name__}: {ex}"
    return None


def read_done(path: str) -> set[str]:
    if not os.path.exists(path):
        return set()
    with open(path) as f:
        return set(f.read().split())


def load_attempts(live: set[str]) -> dict[str, int]:
    """Failed-attempt counts, limited to runs still in the window. A corrupt file reads as {} but is
    reported and moved aside (attempts.json.corrupt-<ts>): silently, the cap on paid retries would
    reset every tick with no trace of why."""
    p = os.path.join(C.bill_data(), "attempts.json")
    try:
        with open(p) as f:
            a = json.load(f)
    except FileNotFoundError:
        return {}
    except OSError as ex:
        warn(f"{p} unreadable ({type(ex).__name__}: {ex}) — retry counts start over")
        return {}
    except ValueError as ex:
        a = ex
    if isinstance(a, dict):
        return {k: v for k, v in a.items() if k in live and isinstance(v, int)}
    aside = f"{p}.corrupt-{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}"
    try:
        os.replace(p, aside)
    except OSError as ex:
        aside = f"left in place ({type(ex).__name__})"
    warn(f"{p} is not a JSON object ({type(a).__name__}) — retry counts start over; the file: {aside}")
    return {}


def save_attempts(a: dict[str, int]) -> bool:
    p = os.path.join(C.bill_data(), "attempts.json")
    return persist("attempts.json", lambda: replace_json(p, a))


def replace_json(path: str, obj: object) -> None:
    with open(path + ".tmp", "w") as f:
        json.dump(obj, f)
    os.replace(path + ".tmp", path)


def warn(message: str) -> None:
    print(f"bill: {message}", file=sys.stderr, flush=True)


def persist(what: str, write: Callable[[], None]) -> bool:
    """One state write; an OSError (disk full, a read-only file) is reported, never raised."""
    try:
        write()
        return True
    except OSError as ex:
        warn(f"cannot write {what} ({type(ex).__name__}: {ex}) — the tick goes on")
        return False
