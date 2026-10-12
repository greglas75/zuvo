"""Shared harness for the scripts/zuvo-home/zuvo_review_* unit specs (test_review_*.py).

Not a test module itself (no `test_` prefix). Each test gets its own HOME and ZUVO_HOME, a fresh
import of the modules (they resolve paths at call time, but a stale module object from another
test must never be the one under test), and a directory for fake executables put first on PATH.
"""

from __future__ import annotations

import contextlib
import os
import signal
import stat
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest
from pathlib import Path
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
ZUVO_HOME_SRC = ROOT / "scripts" / "zuvo-home"
LEDGER_HEADER = ("date\trun_id\tmode\tprovider\tmodel\tfingerprint\tseverity\tconfidence\tfile\t"
                 "disposition\tproject")
SCRUBBED_ENV = ("ZUVO_HOME", "ZUVO_FINDINGS_LOG_FILE", "ZUVO_DIR")


def purge_modules() -> None:
    for name in [n for n in sys.modules if n.startswith(("zuvo_review_", "zuvo_bill_"))]:
        del sys.modules[name]


def finding(ts: str, run: str, fp: str, file: str, project: str, lane: str = "codex-5.3") -> str:
    return "\t".join([ts, run, "code", lane, "gpt", fp, "WARNING", "medium", file, "new", project])


def verdict(ts: str, fp: str, disposition: str, project: str, run: str = "bill") -> str:
    return "\t".join([ts, run, "", "", "", fp, "", "", "", disposition, project])


def wait_for(path: str, seconds: float) -> None:
    deadline = time.monotonic() + seconds
    while not os.path.exists(path):
        if time.monotonic() > deadline:
            raise AssertionError(f"fake claude never signalled {path}")
        time.sleep(0.02)


# A fake claude that starts a sleeper and records both pids, then waits. The pid file is written
# whole (tmp + mv), so a reader never sees half of it. Its first pid is claude's, which is also its
# process-group id: run_claude starts it with start_new_session=True.
SLEEPER_FAKE = 'sleep 15 &\necho "$$ $!" > "{pids}.tmp" && mv "{pids}.tmp" "{pids}"\nwait\n'


def read_pids(path: str) -> list[int]:
    with open(path, encoding="utf-8") as f:
        return [int(x) for x in f.read().split()]


def pid_alive(pid: int) -> bool:
    """Our process `pid` still runs. A zombie (exited, not yet reaped) is dead, and EPERM means the
    pid now belongs to another user's process — ours is gone. Unlike killpg(pgid, 0), whose EPERM
    on macOS can mean either, neither case reads as "alive"."""
    try:
        os.kill(pid, 0)
    except (ProcessLookupError, PermissionError):
        return False
    stat = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True,
                          timeout=10).stdout.strip()
    return bool(stat) and not stat.startswith("Z")


def any_alive_after(pids: list[int], seconds: float) -> bool:
    """Whether any of `pids` still runs after `seconds` (polled: SIGKILL delivery is asynchronous)."""
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        if not any(pid_alive(p) for p in pids):
            return False
        time.sleep(0.05)
    return True


class ReviewTestCase(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = tmp.name
        self.home = os.path.join(self.tmp, "home")
        self.zuvo = os.path.join(self.home, ".zuvo")
        self.bin = os.path.join(self.tmp, "bin")
        os.makedirs(self.zuvo)
        os.makedirs(self.bin)
        env = mock.patch.dict(os.environ, {"HOME": self.home, "ZUVO_HOME": self.zuvo,
                                           "PATH": self.bin + os.pathsep + os.environ.get("PATH", "")})
        env.start()
        self.addCleanup(env.stop)
        for key in SCRUBBED_ENV:
            if key != "ZUVO_HOME":
                os.environ.pop(key, None)
        purge_modules()
        sys.path.insert(0, str(ZUVO_HOME_SRC))
        self.addCleanup(sys.path.remove, str(ZUVO_HOME_SRC))
        self.addCleanup(purge_modules)

    def setenv(self, **values: str) -> None:
        """Set env vars for this test only (the setUp patch restores the whole environment too)."""
        patch = mock.patch.dict(os.environ, values)
        patch.start()
        self.addCleanup(patch.stop)

    def reap_on_cleanup(self, pidfile: str) -> None:
        """A test that fails mid-way must not leave its fake claude's sleeper running."""
        def reap() -> None:
            with contextlib.suppress(OSError, ValueError):
                for pid in read_pids(pidfile):
                    if pid_alive(pid):
                        os.kill(pid, signal.SIGKILL)
        self.addCleanup(reap)

    def write(self, rel: str, text: str) -> str:
        path = os.path.join(self.tmp, rel) if not os.path.isabs(rel) else rel
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
        return path

    def write_ledger(self, rows: list[str], header: bool = True) -> str:
        lines = ([LEDGER_HEADER] if header else []) + rows
        return self.write(os.path.join(self.zuvo, "adversarial-findings.log"), "\n".join(lines) + "\n")

    def fake_exe(self, name: str, body: str) -> str:
        """An executable `name` first on PATH; `body` is a /bin/sh script."""
        path = os.path.join(self.bin, name)
        with open(path, "w", encoding="utf-8") as f:
            f.write("#!/bin/sh\n" + textwrap.dedent(body))
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)
        return path
