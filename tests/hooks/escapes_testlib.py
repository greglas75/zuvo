"""Shared harness for the review-escapes unit specs (test_escapes_*.py).

Not a test module itself (no `test_` prefix). Every test gets the review harness's sandboxed HOME and
ZUVO_HOME plus a real git repository built commit by commit. Git runs with no global or system config:
the owner's global core.hooksPath would otherwise run push/commit gates on every fixture commit, and a
global blame.ignoreRevsFile would change what blame answers. Commit dates are fixed offsets from NOW,
which is also the `now` handed to the code under test, so results never depend on the wall clock.
"""

from __future__ import annotations

import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
import subprocess
import sys
import time
from collections.abc import Mapping
from types import ModuleType

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from review_testlib import ZUVO_HOME_SRC, ReviewTestCase  # noqa: E402

NOW = dt.datetime(2026, 10, 1, 12, 0, 0, tzinfo=dt.timezone.utc)
AUTHOR_EMAIL = "dev.person@example.com"
GIT_ENV = {
    "GIT_CONFIG_GLOBAL": os.devnull,
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_AUTHOR_NAME": "Dev Person",
    "GIT_AUTHOR_EMAIL": AUTHOR_EMAIL,
    "GIT_COMMITTER_NAME": "Dev Person",
    "GIT_COMMITTER_EMAIL": AUTHOR_EMAIL,
}
LAUNCHER = ZUVO_HOME_SRC / "review-escapes"
# Holds an exclusive flock on argv[1] and creates argv[2] once it has it, then waits to be killed.
LOCK_HOLDER = ("import fcntl, os, sys, time\n"
               "fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR, 0o644)\n"
               "fcntl.flock(fd, fcntl.LOCK_EX)\n"
               "open(sys.argv[2], 'w').close()\n"
               "time.sleep(60)\n")
# Set by git for hooks and by wrappers; any of them would point a fixture command at another repository.
REPO_ENV = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_NAMESPACE", "GIT_PREFIX")


def git_date(days_ago: float) -> str:
    return (NOW - dt.timedelta(days=days_ago)).strftime("%Y-%m-%dT%H:%M:%S+0000")


class FixtureRepo:
    """A git repository on branch `develop`, built from the test (no network, no hooks)."""

    def __init__(self, path: str, clone_of: str | None = None) -> None:
        self.path = path
        if clone_of is None:
            os.makedirs(path)
            self.git("init", "-q", "-b", "develop")
        else:
            self.git("clone", "-q", clone_of, path)

    def git(self, *args: str, days_ago: float = 0.0) -> str:
        env = {k: v for k, v in os.environ.items() if k not in REPO_ENV}
        env.update(GIT_ENV, GIT_AUTHOR_DATE=git_date(days_ago), GIT_COMMITTER_DATE=git_date(days_ago))
        where = ["-C", self.path] if os.path.isdir(self.path) else []
        # gc.auto=0 keeps every object loose, which drop_object relies on
        proc = subprocess.run(["git", "-c", "gc.auto=0", *where, *args], capture_output=True, text=True,
                              env=env, timeout=60)
        if proc.returncode != 0:
            raise AssertionError(f"fixture git {args} failed: {proc.stderr}")
        return proc.stdout.strip()

    def commit(self, subject: str, files: Mapping[str, str | None], days_ago: float,
               allow_empty: bool = False) -> str:
        """Write (or, for None, delete) each file, then commit everything; returns the sha. A commit
        that stages nothing fails unless allow_empty: a fixture that silently built an empty commit
        would test nothing."""
        for rel, text in files.items():
            full = os.path.join(self.path, rel)
            if text is None:
                os.remove(full)
                continue
            os.makedirs(os.path.dirname(full) or self.path, exist_ok=True)
            with open(full, "w", encoding="utf-8") as f:
                f.write(text)
        self.git("add", "-A")
        if not allow_empty and not self.git("diff", "--cached", "--name-only"):
            raise AssertionError(f"fixture commit {subject!r} staged nothing")
        self.git("commit", "-q", "--allow-empty", "-m", subject, days_ago=days_ago)
        return self.git("rev-parse", "HEAD")

    def branch(self, name: str) -> None:
        self.git("checkout", "-q", "-b", name)

    def checkout(self, name: str) -> None:
        self.git("checkout", "-q", name)

    def drop_object(self, spec: str) -> None:
        """Delete the loose object `spec` names (e.g. `<sha>:path`), so git fails reading it."""
        sha = self.git("rev-parse", spec)
        loose = os.path.join(self.path, ".git", "objects", sha[:2], sha[2:])
        if not os.path.exists(loose):
            raise AssertionError(f"{spec} is not a loose object; the fixture must not pack")
        os.remove(loose)

    def merge(self, branch: str, subject: str, days_ago: float) -> str:
        """A true (two-parent) merge of `branch` into the current branch."""
        self.git("merge", "-q", "--no-ff", "-m", subject, branch, days_ago=days_ago)
        return self.git("rev-parse", "HEAD")


def lines(*items: str) -> str:
    return "".join(f"{i}\n" for i in items)


def load_launcher() -> ModuleType:
    """The extensionless launcher as a module (its polyglot header is a Python string literal)."""
    loader = importlib.machinery.SourceFileLoader("review_escapes_launcher", str(LAUNCHER))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    if spec is None:
        raise AssertionError(f"cannot load {LAUNCHER}")
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


class EscapesTestCase(ReviewTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.setenv(**GIT_ENV)
        self.addCleanup(self._purge_escapes)
        self._purge_escapes()
        self.repo = FixtureRepo(os.path.join(self.tmp, "proj"))

    @staticmethod
    def _purge_escapes() -> None:
        for name in [n for n in sys.modules if n.startswith("zuvo_escapes_")]:
            del sys.modules[name]

    def run_main(self, *argv: str) -> tuple[int, str]:
        """review-escapes in-process with the fixture clock on the fixture repo's develop branch;
        later --repo / --ref arguments override those (argparse keeps the last)."""
        return self.run_bare("--repo", self.repo.path, "--ref", "develop", *argv)

    def run_bare(self, *argv: str) -> tuple[int, str]:
        """review-escapes in-process with exactly `argv` and the fixture clock; (exit code, stdout)."""
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            rc = load_launcher().main(list(argv), now=NOW)
        return rc, out.getvalue()

    def summary(self, *argv: str) -> dict:
        rc, out = self.run_main("--json", *argv)
        self.assertEqual(0, rc, out)
        return json.loads(out)

    @property
    def store(self) -> str:
        return os.path.join(self.zuvo, "review-escapes-data", "proj.jsonl")

    def rows(self) -> list[dict]:
        if not os.path.exists(self.store):
            return []
        with open(self.store, encoding="utf-8") as f:
            return [json.loads(line) for line in f if line.strip()]

    def hold_lock(self) -> subprocess.Popen[bytes]:
        """Another process holding the store's lock until killed."""
        os.makedirs(os.path.dirname(self.store), exist_ok=True)
        ready = os.path.join(self.tmp, "locked")
        holder = subprocess.Popen([sys.executable, "-c", LOCK_HOLDER, self.store + ".lock", ready])
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        deadline = time.monotonic() + 10
        while not os.path.exists(ready):
            if time.monotonic() > deadline or holder.poll() is not None:
                raise AssertionError("lock holder never took the lock")
            time.sleep(0.02)
        return holder

    def use_zone(self, name: str) -> None:
        """Run this test with the host's local zone set to `name` (restored afterwards)."""
        old = os.environ.get("TZ")
        os.environ["TZ"] = name
        time.tzset()

        def restore() -> None:
            if old is None:
                os.environ.pop("TZ", None)
            else:
                os.environ["TZ"] = old
            time.tzset()
        self.addCleanup(restore)
