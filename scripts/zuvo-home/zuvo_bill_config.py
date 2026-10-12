"""Bill's settings, paths, clock and tick lock.

Everything is read at CALL time, never at import: a test (or a second ZUVO_HOME) that changes the
environment after this module was imported must not have Bill read or write the real ~/.zuvo.
`API` is checked by the `bill` launcher against every module it loads: the installer replaces the
files one at a time, and a launcher running beside modules of another release must stop, not crash.
"""

from __future__ import annotations

import os
import time
from datetime import datetime, timezone

from zuvo_review_ledger import ledger_path, zuvo_home

API = 1
CALL_TIMEOUT = 1800
STALE_LOCK_SECONDS = 3 * 3600


def env_int(name: str, default: int) -> int:
    try:
        return max(1, int(os.environ.get(name, default)))
    except ValueError:
        return default


def home() -> str:
    return zuvo_home()


def bill_data() -> str:
    return os.path.join(zuvo_home(), "bill-data")


def inputs_dir() -> str:
    return os.path.join(zuvo_home(), "adversarial-inputs")


def ledger() -> str:
    return ledger_path()


def model() -> str:
    return os.environ.get("BILL_MODEL", "claude-opus-5-5")


def effort() -> str:
    return os.environ.get("BILL_EFFORT", "xhigh")


def workers() -> int:
    return env_int("BILL_WORKERS", 3)


def budget() -> int:
    return env_int("BILL_TICK_SECONDS", 540)


def max_age_h() -> int:
    return env_int("BILL_MAX_AGE_HOURS", 48)


def min_age_m() -> int:
    """A review younger than this is still being triaged by the agent that ran it; Bill's verdict,
    written after a long call, would land later and win over the agent's (latest row wins)."""
    return env_int("BILL_MIN_AGE_MINUTES", 30)


def max_tries() -> int:
    """Each attempt is a paid xhigh call; without a cap a review that always fails is retried every tick
    until it ages out (BILL_MAX_AGE_HOURS)."""
    return env_int("BILL_MAX_TRIES", 3)


def now() -> datetime:
    return datetime.now(timezone.utc)


def stamp(dt: datetime) -> str:
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")


def append(path: str, line: str) -> None:
    with open(path, "a", encoding="utf-8") as f:
        f.write(line + "\n")


def paused() -> bool:
    return os.path.exists(os.path.join(bill_data(), "PAUSE"))


def acquire_lock() -> bool:
    """The tick lock (a directory: mkdir is atomic). A lock older than STALE_LOCK_SECONDS belonged to a
    tick that died without releasing it and is taken over; False when another tick holds it."""
    lock = os.path.join(bill_data(), ".lock")
    try:
        os.mkdir(lock)
        return True
    except FileExistsError:
        pass
    try:
        fresh = time.time() - os.path.getmtime(lock) < STALE_LOCK_SECONDS
    except OSError:                      # the other tick released it between the two calls
        fresh = True
    if fresh:
        return False
    try:
        os.rmdir(lock)
        os.mkdir(lock)
    except OSError:                      # another tick took over the same stale lock first
        return False
    return True


def release_lock() -> None:
    os.rmdir(os.path.join(bill_data(), ".lock"))
