"""Shared harness for the scripts/zuvo-home/bill unit specs (test_bill_*.py).

Not a test module itself (no `test_` prefix). Built on review_testlib.ReviewTestCase: every test gets
its own HOME and ZUVO_HOME in a temp dir, `zuvo_bill_*` / `zuvo_review_*` purged from sys.modules
before and after (a module object left over from another test must never be the one under test), and
a fake-executable directory first on PATH.
"""

from __future__ import annotations

import functools
import json
import os
import re
import select
import shutil
import subprocess
import sys
from datetime import datetime, timedelta, timezone
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from review_testlib import ZUVO_HOME_SRC, ReviewTestCase, finding  # noqa: E402

LAUNCHER = ZUVO_HOME_SRC / "bill"


def ago(**delta: float) -> str:
    return (datetime.now(timezone.utc) - timedelta(**delta)).strftime("%Y-%m-%dT%H:%M:%SZ")


class BillTestCase(ReviewTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.setenv(BILL_MAX_TRIES="3", BILL_MIN_AGE_MINUTES="30", BILL_MAX_AGE_HOURS="48")

    def diff(self, run: str, text: str = "+x = 1\n") -> str:
        return self.write(os.path.join(self.zuvo, "adversarial-inputs", run + ".diff"), text)

    def install_set(self, where: str = "install", skip: str = "", api: dict[str, int] | None = None,
                    tail: dict[str, str] | None = None) -> str:
        """A copy of the launcher and every module it imports in directory `where` (what ~/.zuvo holds):
        without module `skip`, `API = n` rewritten for each module in `api`, `tail[m]` appended to m."""
        dest = os.path.join(self.tmp, where)
        os.makedirs(dest, exist_ok=True)
        shutil.copy2(LAUNCHER, os.path.join(dest, "bill"))
        for src in ZUVO_HOME_SRC.glob("zuvo_*.py"):
            name = src.stem
            if not name.startswith(("zuvo_bill_", "zuvo_review_")) or name == skip:
                continue
            text = src.read_text(encoding="utf-8")
            if api and name in api:
                text = re.sub(r"^API = \d+$", f"API = {api[name]}", text, count=1, flags=re.M)
            self.write(os.path.join(dest, src.name), text + (tail or {}).get(name, ""))
        return os.path.join(dest, "bill")

    def queue_review(self, run: str, fps: list[str], hours: float = 2) -> str:
        """`run`'s findings as new ledger rows of project <tmp>/proj, plus its diff; returns the project."""
        proj = os.path.join(self.tmp, "proj")
        os.makedirs(proj, exist_ok=True)
        rows = [finding(ago(hours=hours), run, fp, fp.rsplit(":", 1)[0], proj) for fp in fps]
        os.makedirs(self.zuvo, exist_ok=True)
        with open(os.path.join(self.zuvo, "adversarial-findings.log"), "a", encoding="utf-8") as f:
            f.write("\n".join(rows) + "\n")
        self.diff(run)
        return proj

    def fake_claude_answer(self, answer: dict[str, Any], **envelope: Any) -> None:
        """A `claude` that prints the CLI's JSON envelope with `answer` as the model's reply."""
        out = self.write("claude.out", json.dumps({"result": json.dumps(answer), **envelope}))
        self.fake_exe("claude", f'cat >/dev/null; cat "{out}"\n')

    def fake_driver(self, rc: int = 0) -> str:
        """~/.zuvo/adversarial-review that records its argv (one per line) and exits `rc`."""
        args = os.path.join(self.tmp, "driver.args")
        path = self.write(os.path.join(self.zuvo, "adversarial-review"),
                          f'#!/bin/sh\nprintf "%s\\n" "$@" > "{args}"\nexit {rc}\n')
        os.chmod(path, 0o755)
        return args

    def read_lines(self, path: str) -> list[str]:
        with open(path, encoding="utf-8") as f:
            return f.read().splitlines()

    def skip_if_root(self) -> None:
        if hasattr(os, "geteuid") and os.geteuid() == 0:
            self.skipTest("root ignores file modes")

    def lock_holder(self) -> subprocess.Popen[str]:
        """Another process holding the tick lock. It answers commands on stdin: `release` (prints
        `released`), `spawn` (starts `sleep 30` the way a careless spawn would, close_fds=False, and
        prints its pid). It and anything it spawned are killed at cleanup."""
        code = ("import subprocess, sys; sys.path.insert(0, sys.argv[1]); import zuvo_bill_config as C\n"
                "r = C.acquire_lock(); print('held' if r is None else f'refused: {r}', flush=True)\n"
                "for cmd in sys.stdin:\n"
                "    if cmd.strip() == 'release': C.release_lock(); print('released', flush=True)\n"
                "    if cmd.strip() == 'spawn':\n"
                "        print(subprocess.Popen(['sleep', '30'], close_fds=False).pid, flush=True)\n")
        p = subprocess.Popen([sys.executable, "-c", code, str(ZUVO_HOME_SRC)], stdin=subprocess.PIPE,
                             stdout=subprocess.PIPE, text=True, env=dict(os.environ))
        assert p.stdin is not None and p.stdout is not None
        for cleanup in (p.stdout.close, p.stdin.close, functools.partial(p.wait, 10), p.kill):
            self.addCleanup(cleanup)   # run last-first: kill, reap, close the pipes
        self.assertEqual(self.read_reply(p), "held")
        return p

    def tell(self, p: subprocess.Popen[str], command: str) -> str:
        assert p.stdin is not None
        p.stdin.write(command + "\n")
        p.stdin.flush()
        return self.read_reply(p)

    def read_reply(self, p: subprocess.Popen[str], timeout: float = 10) -> str:
        """The holder's next line; a holder that never answers fails the test instead of hanging it."""
        assert p.stdout is not None
        ready, _, _ = select.select([p.stdout], [], [], timeout)
        if not ready:
            self.fail(f"lock holder {p.pid} sent nothing in {timeout} s")
        return p.stdout.readline().strip()

    def run_bill(self, *args: str, launcher: str = str(LAUNCHER)) -> subprocess.CompletedProcess[str]:
        """The launcher as cron runs it: its own process, this test's environment."""
        return subprocess.run([sys.executable, launcher, *args], capture_output=True, text=True,
                              timeout=60, env=dict(os.environ), cwd=self.tmp)
