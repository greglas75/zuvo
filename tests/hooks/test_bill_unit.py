"""scripts/zuvo-home/bill and its zuvo_bill_* modules — the launcher's install guard and what the split
onto the shared review modules must not break. Behaviour Bill already had is pinned by test-bill.sh."""

from __future__ import annotations

import json
import os
import sys
import time
import unittest
from typing import Any

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bill_testlib import BillTestCase, ago  # noqa: E402
from review_testlib import verdict  # noqa: E402

BROKEN_INSTALLS: dict[str, dict[str, Any]] = {
    "missing module": {"skip": "zuvo_bill_status"},
    "API mismatch": {"api": {"zuvo_bill_judge": 2}},
}


class InstallGuard(BillTestCase):
    def test_tick_on_a_broken_install_exits_0_saying_install_in_progress(self) -> None:
        # bug: the installer replaces files one at a time; a tick between two of them tracebacks every
        # 10 minutes (a module raising at import included) instead of waiting for the install to finish
        raises: dict[str, Any] = {"tail": {"zuvo_bill_tick": "\nraise OSError('at import')\n"}}
        cases = {**BROKEN_INSTALLS, "module raises at import": raises}
        for label, how in cases.items():
            with self.subTest(label):
                p = self.run_bill(launcher=self.install_set(where=label, **how))
                self.assertEqual(p.returncode, 0)
                self.assertNotIn("Traceback", p.stdout + p.stderr)
                self.assertTrue(p.stdout.startswith("bill: install in progress"), p.stdout)

    def test_status_reports_since_when_the_install_has_been_broken(self) -> None:
        # bug: a broken install skips every tick silently for good; a first-seen time rewritten on every
        # tick would always read "just now"
        for label, how in BROKEN_INSTALLS.items():
            with self.subTest(label):
                self.setenv(ZUVO_HOME=os.path.join(self.tmp, label, "zh"))
                launcher = self.install_set(where=label, **how)
                guard = os.path.join(os.environ["ZUVO_HOME"], "bill-data", "install-guard")
                self.run_bill(launcher=launcher)
                since = self.read_lines(guard)[0]
                time.sleep(1.1)   # the guard stamps whole seconds: a rewrite must be able to differ
                self.run_bill(launcher=launcher)
                status = self.run_bill("--status", launcher=launcher)
                self.assertEqual(self.read_lines(guard)[0], since)
                self.assertEqual(status.returncode, 1)
                self.assertIn(f"install BROKEN since {since}", status.stdout)

    def test_a_repaired_install_is_no_longer_reported_broken(self) -> None:
        # bug: a guard file outliving the repair reports an install broken that works again
        self.run_bill(launcher=self.install_set(api={"zuvo_bill_judge": 2}))
        # A fresh directory: rewritten in place within the same second, at the same size, a module would
        # be loaded from its stale __pycache__ entry (the pyc check is mtime-in-seconds + size).
        status = self.run_bill("--status", launcher=self.install_set(where="repaired"))
        self.assertEqual(status.returncode, 0)
        self.assertNotIn("BROKEN", status.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.zuvo, "bill-data", "install-guard")))


class Tick(BillTestCase):
    def test_answer_reaches_the_ledger_and_the_lessons_file(self) -> None:
        # bug: run_claude's answer and valid_verdicts disagree on the shape, so no verdict ever lands
        self.queue_review("r-1", ["a.py:1:x", "a.py:2:y"])
        args = self.fake_driver()
        defects = [{"verdict": "real", "class": "logic", "finding_ids": ["a.py:1:x"]},
                   {"verdict": "false_positive", "finding_ids": ["a.py:2:y"]}]
        self.fake_claude_answer({"defects": defects, "lessons": ["l1"]},
                                total_cost_usd=0.5, usage={"output_tokens": 7})
        import zuvo_bill_tick
        zuvo_bill_tick.tick(False)
        bd = os.path.join(self.zuvo, "bill-data")
        self.assertEqual(self.read_lines(args), ["--record-disposition", "a.py:1:x", "deferred",
                                                 "--record-disposition", "a.py:2:y", "rejected"])
        self.assertEqual([json.loads(x)["lesson"] for x in self.read_lines(f"{bd}/lessons.jsonl")], ["l1"])
        self.assertEqual(self.read_lines(f"{bd}/judged-runs.txt"), ["r-1"])
        log = json.loads(self.read_lines(f"{bd}/bill.log")[0])
        self.assertEqual((log.get("error"), log["usd"], log["tokens_out"]), (None, 0.5, 7))

    def test_answer_without_lessons_is_recorded_not_retried(self) -> None:
        # bug: requiring a `lessons` key turns a "nothing to learn" answer into a paid failed attempt x3
        self.queue_review("r-1", ["a.py:1:x"])
        self.fake_driver()
        self.fake_claude_answer({"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}]})
        import zuvo_bill_tick
        zuvo_bill_tick.tick(False)
        bd = os.path.join(self.zuvo, "bill-data")
        self.assertEqual(self.read_lines(f"{bd}/judged-runs.txt"), ["r-1"])
        self.assertEqual(len(self.read_lines(f"{bd}/defects.jsonl")), 1)
        self.assertFalse(os.path.exists(f"{bd}/lessons.jsonl"))

    def test_a_ledger_path_that_cannot_be_read_skips_the_tick_and_releases_the_lock(self) -> None:
        # bug: the shared reader raises on a read error (here the ledger path is a directory) where bill's
        # own reader returned nothing; uncaught, the tick tracebacks every 10 minutes and the lock it
        # leaves makes every tick of the next 3 hours report "already running"
        os.makedirs(os.path.join(self.zuvo, "adversarial-findings.log"))
        p = self.run_bill()
        self.assertEqual(p.returncode, 1)
        self.assertNotIn("Traceback", p.stdout + p.stderr)
        self.assertIn("bill: cannot read the ledger", p.stdout)
        self.assertFalse(os.path.exists(os.path.join(self.zuvo, "bill-data", ".lock")))

    def test_limit_reported_as_a_cli_exit_stops_the_tick_without_using_a_try(self) -> None:
        # bug: a limit the CLI reports by exiting 1 with the message on stderr (no envelope; run_claude's
        # error reads `exit 1: …`) not seen as a limit — a limited account burns every queued review's try
        self.queue_review("r-1", ["a.py:1:x"], hours=2)
        self.queue_review("r-2", ["a.py:2:y"], hours=3)
        calls = os.path.join(self.tmp, "calls")
        self.fake_exe("claude", f'cat >/dev/null; echo call >> "{calls}"\n'
                                'echo "Claude AI usage limit reached" >&2; exit 1\n')
        self.setenv(BILL_WORKERS="1")
        import zuvo_bill_tick
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
        self.assertEqual(len(self.read_lines(calls)), 1)
        with open(os.path.join(self.zuvo, "bill-data", "attempts.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), {})
        runs, judged = zuvo_bill_tick.read_ledger()
        self.assertEqual([q[1] for q in zuvo_bill_tick.pending(runs, judged, done=set())], ["r-1", "r-2"])
        self.assertFalse(os.path.exists(os.path.join(self.zuvo, "bill-data", "judged-runs.txt")))


class Judged(BillTestCase):
    def test_a_verdict_joins_its_finding_whatever_form_the_project_path_takes(self) -> None:
        # bug: a verdict written under another form of the project path (/home/… vs /Users/…, a bare
        # basename) is missing from the judged set; a project-less row must join nothing
        self.write_ledger([verdict(ago(hours=1), "a.py:1:x", "fixed", "/home/b/DEV/repo/"),
                           verdict(ago(hours=1), "a.py:2:y", "rejected", "repo"),
                           verdict(ago(hours=1), "a.py:3:z", "deferred", "")])
        import zuvo_bill_tick
        _, judged = zuvo_bill_tick.read_ledger()
        table = [("/Users/a/DEV/repo", "a.py:1:x", True), ("/Users/a/DEV/repo", "a.py:2:y", True),
                 ("/Users/a/DEV/other", "a.py:1:x", False),    # same fingerprint, another repo
                 ("/Users/a/DEV/repo", "a.py:3:z", False),     # a project-less verdict joins nothing
                 ("", "a.py:3:z", False)]                      # …and a project-less finding has no key
        for project, fp, expected in table:
            with self.subTest(project=project, fp=fp):
                self.assertIs((project, fp) in judged, expected)


class Config(BillTestCase):
    def test_paths_follow_a_zuvo_home_set_after_import(self) -> None:
        # bug: a path frozen at import sends a later ZUVO_HOME (a test, a second home) to the real ~/.zuvo
        import zuvo_bill_config
        other = os.path.join(self.tmp, "other-home")
        self.setenv(ZUVO_HOME=other)
        self.assertEqual(zuvo_bill_config.bill_data(), os.path.join(other, "bill-data"))
        self.assertEqual(zuvo_bill_config.ledger(), os.path.join(other, "adversarial-findings.log"))


if __name__ == "__main__":
    unittest.main()
