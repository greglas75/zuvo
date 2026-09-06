"""Bounded POSIX execution and opt-in phase timings (not part of replay identity)."""

from contextlib import contextmanager
from collections.abc import Iterator
import os
from pathlib import Path
import signal
import sys
import threading
import time


def require_farm() -> None:
    """Accidental-bypass guard, not host authentication; rt exports its pinned server release."""
    release = os.environ.get("TF_RELEASE_DIR")
    if sys.platform != "linux" or not release or not (Path(release) / "tf-run.sh").is_file():
        raise ValueError("--execution farm requires the Linux rt worker context; do not bypass on the laptop")


class ScanDeadline(RuntimeError):
    """Must bypass optional-provider OSError/ValueError fallbacks, up to the CLI boundary."""


@contextmanager
def deadline(seconds: int) -> Iterator[None]:
    if threading.current_thread() is not threading.main_thread():
        raise ValueError("scan deadline requires the main thread")
    if type(seconds) is not int or not 0 < seconds <= 100_000:
        raise ValueError("scan deadline requires 1..100000 seconds")

    def expired(signum, frame):
        raise ScanDeadline("scan deadline exceeded; no complete report; use the farm, never drop files")

    previous_timer = signal.getitimer(signal.ITIMER_REAL)
    previous = signal.signal(signal.SIGALRM, expired)
    started = time.monotonic()
    try:
        signal.setitimer(
            signal.ITIMER_REAL, min(seconds, previous_timer[0]) if previous_timer[0] else seconds
        )
        yield
    finally:
        try:
            signal.setitimer(signal.ITIMER_REAL, 0)
        finally:
            signal.signal(signal.SIGALRM, previous)
            if previous_timer[0]:
                signal.setitimer(
                    signal.ITIMER_REAL,
                    max(0.001, previous_timer[0] - (time.monotonic() - started)),
                    previous_timer[1],
                )


@contextmanager
def phase(name: str, enabled: bool) -> Iterator[None]:
    started = time.monotonic()
    if enabled:
        print(f"radar phase={name} started", file=sys.stderr, flush=True)
    try:
        yield
    finally:
        if enabled:
            print(f"radar phase={name} seconds={time.monotonic() - started:.3f}", file=sys.stderr, flush=True)
