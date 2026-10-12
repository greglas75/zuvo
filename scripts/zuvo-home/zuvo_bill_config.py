"""Bill's settings, paths, clock and tick lock.

Everything is read at CALL time, never at import: a test (or a second ZUVO_HOME) that changes the
environment after this module was imported must not have Bill read or write the real ~/.zuvo.
`API` is checked by the `bill` launcher against every module it loads: the installer replaces the
files one at a time, and a launcher running beside modules of another release must stop, not crash.
"""

from __future__ import annotations

import contextlib
import fcntl
import os
import re
import sys
import time
from datetime import datetime, timezone
from typing import NamedTuple

from zuvo_review_ledger import ledger_path, zuvo_home

API = 2
CALL_TIMEOUT = 1800
# The lock directory bill used before tick.flock. A tick of that older release may still be running
# during an upgrade; one older than this is a dead tick's (that release took such a lock over too).
LEGACY_LOCK_STALE_SECONDS = 3 * 3600
# A run id names its diff file (adversarial-inputs/<run>.diff): anything else could point outside it.
RUN_ID = re.compile(r"[A-Za-z0-9._-]+")
_warned: set[str] = set()


def env_int(name: str, default: int) -> int:
    """A positive count or timeout from the environment; anything else is `default`, said once on stderr
    (a 0 there meant one worker, one try, a one-second budget)."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError:
        value = 0
    if value > 0:
        return value
    if name not in _warned:
        _warned.add(name)
        print(f"bill: {name}={raw!r} is not a positive integer — using {default}",
              file=sys.stderr, flush=True)
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


_lock_fd: list[int] = []   # the open lock file while this process holds it


class Refused(NamedTuple):
    reason: str
    error: bool     # True: the lock could not be checked at all (the tick exits 1), not merely held


def lock_path() -> str:
    return os.path.join(bill_data(), "tick.flock")


def acquire_lock() -> Refused | None:
    """None when this tick now holds the lock, else why not.

    An flock on bill-data/tick.flock (never deleted). The kernel releases it when its process EXITS,
    however it dies, and it holds while a laptop sleeps mid-tick — no age guess. A hung live tick keeps
    it: `--status` names the holder (its pid and start, written into the file). The file is opened
    non-inheritable, so claude and the driver never carry the lock past this process. A tick of the
    release before (a `.lock` directory) is respected until it is LEGACY_LOCK_STALE_SECONDS old."""
    try:
        fd = os.open(lock_path(), os.O_RDWR | os.O_CREAT, 0o644)
    except OSError as ex:
        return Refused(f"cannot open the tick lock {lock_path()} ({type(ex).__name__}: {ex})", True)
    held = False
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return Refused("a tick is already running", False)
        legacy = os.path.join(bill_data(), ".lock")
        try:
            legacy_age: float | None = time.time() - os.stat(legacy).st_mtime
        except FileNotFoundError:
            legacy_age = None
        if legacy_age is not None and legacy_age < LEGACY_LOCK_STALE_SECONDS:
            return Refused("a tick is already running (legacy lock)", False)
        if legacy_age is not None:
            with contextlib.suppress(OSError):   # left behind, the next tick tries again
                os.rmdir(legacy)
        with contextlib.suppress(OSError):       # who holds it is for --status only
            os.ftruncate(fd, 0)
            os.pwrite(fd, f"{os.getpid()} {stamp(now())}\n".encode(), 0)
        held = True
        _lock_fd[:] = [fd]
        return None
    except OSError as ex:
        return Refused(f"cannot lock {lock_path()} ({type(ex).__name__}: {ex})", True)
    finally:
        if not held:
            os.close(fd)


def lock_holder() -> str | None:
    """`<pid> <since>` of the tick holding the lock now ("" before it has written them), or None when
    nobody holds it."""
    try:
        fd = os.open(lock_path(), os.O_RDONLY)
    except OSError:
        return None
    try:
        try:
            fcntl.flock(fd, fcntl.LOCK_SH | fcntl.LOCK_NB)
        except BlockingIOError:
            return os.pread(fd, 200, 0).decode("utf-8", errors="replace").strip()
        return None
    except OSError:
        return None
    finally:
        os.close(fd)


def release_lock() -> None:
    """Closing the file releases the flock; nothing to do when this process holds none."""
    while _lock_fd:
        os.close(_lock_fd.pop())
