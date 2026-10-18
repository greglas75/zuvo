"""scripts/zuvo-home/bill and its zuvo_bill_* modules — the launcher's install guard and what the split
onto the shared review modules must not break. Behaviour Bill already had is pinned by test-bill.sh."""

from __future__ import annotations

import configparser
import contextlib
import hashlib
import io
import json
import os
import plistlib
import shlex
import signal
import subprocess
import sys
import time
import unittest
from typing import Any
from unittest import mock

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bill_testlib import BillTestCase, ago  # noqa: E402
from review_testlib import ROOT, finding, verdict  # noqa: E402

DRIVER = ROOT / "scripts" / "adversarial-review.sh"

BROKEN_INSTALLS: dict[str, dict[str, Any]] = {
    "missing module": {"skip": "zuvo_bill_status"},
    "a module of the release before (API 2)": {"api": {"zuvo_bill_judge": 2}},
}


class InstallGuard(BillTestCase):
    def test_tick_on_a_broken_install_exits_0_saying_install_in_progress(self) -> None:
        # bug: the installer replaces files one at a time; a tick between two of them tracebacks every
        # 10 minutes (a module raising at import included), or runs an old module whose lock contract
        # (acquire_lock: True/False before API 2) the new tick reads inverted
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
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
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
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
        bd = os.path.join(self.zuvo, "bill-data")
        self.assertEqual(self.read_lines(f"{bd}/judged-runs.txt"), ["r-1"])
        self.assertEqual(len(self.read_lines(f"{bd}/defects.jsonl")), 1)
        self.assertFalse(os.path.exists(f"{bd}/lessons.jsonl"))

    def test_a_ledger_path_that_cannot_be_read_skips_the_tick_and_releases_the_lock(self) -> None:
        # bug: the shared reader raises on a read error (here the ledger path is a directory) where bill's
        # own reader returned nothing; uncaught, the tick tracebacks every 10 minutes, and a lock kept
        # past it makes the next tick report "already running"
        os.makedirs(os.path.join(self.zuvo, "adversarial-findings.log"))
        import zuvo_bill_config
        import zuvo_bill_tick
        out = io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            self.assertEqual(zuvo_bill_tick.tick(False), 1)
        self.assertIn("bill: cannot read the ledger", out.getvalue())
        # flock locks taken through two open() calls conflict even inside one process: a kept fd fails this
        self.addCleanup(zuvo_bill_config.release_lock)
        self.assertIsNone(zuvo_bill_config.acquire_lock())

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


def good_defect(fid: str = "a.py:1:x") -> dict[str, Any]:
    return {"verdict": "real", "finding_ids": [fid]}


FINDING_ROW = {"lane": "codex", "model": "m", "severity": "W", "confidence": "1"}


def kill_quietly(pid: int) -> None:
    with contextlib.suppress(ProcessLookupError):
        os.kill(pid, signal.SIGKILL)


class Verdicts(BillTestCase):
    def test_bad_or_conflicting_defects_are_dropped_and_the_rest_of_the_answer_kept(self) -> None:
        # bug: one malformed element threw away a whole paid answer; an id in two defects wrote two
        # conflicting disposition rows; an unknown verdict or a non-string id reached the driver
        import zuvo_bill_judge
        defects = [good_defect("a.py:1:x"),
                   {"verdict": "maybe", "finding_ids": ["a.py:2:y"]},              # unknown verdict
                   {"verdict": ["real"], "finding_ids": ["a.py:3:z"]},             # verdict not a string
                   {"verdict": "real", "finding_ids": [7]},                        # id not a string
                   {"verdict": "real", "finding_ids": "a.py:4:w"},                 # ids not a list
                   "a.py:5:v is real",                                             # not an object
                   good_defect("a.py:6:u"), {"verdict": "false_positive", "finding_ids": ["a.py:6:u"]},
                   {"verdict": "uncertain", "finding_ids": ["a.py:7:t", "a.py:7:t"]}]   # repeat inside one
        got, dropped = zuvo_bill_judge.valid_verdicts({"defects": defects, "lessons": ["l", 3]})
        self.assertEqual(got, {"defects": [good_defect("a.py:1:x"),
                                           {"verdict": "uncertain", "finding_ids": ["a.py:7:t"]}],
                               "lessons": ["l"]})
        self.assertEqual(dropped, 7)
        with self.assertRaises(ValueError):
            zuvo_bill_judge.valid_verdicts({"defects": None})

    def test_reviewer_text_holding_a_placeholder_is_never_expanded(self) -> None:
        # bug: replace() ran twice, so a finding id holding `{diff}` pulled the whole diff into the
        # findings list (and a diff line holding `{findings}` the findings into the diff)
        import zuvo_bill_judge
        rows = [{**FINDING_ROW, "id": "a.py:1:{diff}", "file": "a.py:1"}]
        prompt = zuvo_bill_judge.build_prompt(rows, "+x = '{findings}'\n")
        self.assertIn("id=a.py:1:{diff} |", prompt)
        self.assertIn("+x = '{findings}'\n", prompt)
        self.assertEqual(prompt.count("+x = "), 1)

    def test_a_diff_over_the_cap_is_cut_at_a_line_end_and_says_how_to_judge_the_rest(self) -> None:
        # bug: a multi-megabyte diff went into the prompt whole (a paid call failing on context size);
        # cut mid-line or mid-character it showed the model code that does not exist
        import zuvo_bill_judge
        cap = zuvo_bill_judge.DIFF_CAP_BYTES
        line = "+ zażółć gęślą jaźń — ünïcödé\n"
        width = len(line.encode("utf-8"))
        full = line * (cap // width + 50)
        self.diff("r-1", full)
        prompt = os.path.join(self.tmp, "prompt")
        self.fake_exe("claude", f'cat > "{prompt}"; echo "{{}}"\n')
        row = {**FINDING_ROW, "id": "a", "file": "a"}
        rec, _ = zuvo_bill_judge.judge((ago(hours=2), "r-1", self.tmp, [row]))
        with open(prompt, "rb") as f:
            sent = f.read().decode("utf-8", errors="replace").split("=== DIFF ===\n", 1)[1]
        shown, marker = sent.split("[diff truncated: ", 1)
        self.assertEqual(shown, line * (cap // width))
        self.assertTrue(marker.startswith(f"{(cap // width) * width} of {len(full.encode('utf-8'))} bytes]"))
        self.assertIn("`uncertain`, never `false_positive`", marker)
        self.assertEqual((rec["diff_bytes"], rec["diff_bytes_sent"]),
                         (len(full.encode("utf-8")), (cap // width) * width))

    def test_a_first_line_longer_than_the_cap_is_cut_at_a_character_boundary(self) -> None:
        # bug: one minified line over the cap gave an empty diff, or one cut inside a character
        import zuvo_bill_judge
        cap = zuvo_bill_judge.DIFF_CAP_BYTES
        self.diff("r-1", "+" + "é" * cap + "\n")
        diff = zuvo_bill_judge.read_diff(os.path.join(self.zuvo, "adversarial-inputs", "r-1.diff"))
        self.assertEqual(diff.sent, cap - 1)                        # "+" then whole 2-byte characters
        self.assertTrue(diff.text.startswith("+" + "é" * ((cap - 1) // 2) + "\n[diff truncated: "))

    def test_a_false_positive_on_a_file_the_cut_diff_does_not_show_whole_becomes_uncertain(self) -> None:
        # bug: the model rejected a finding in a file it never saw, or saw only the start of (the file
        # the cap cuts) — a permanent `rejected` row
        import zuvo_bill_judge
        big = "+a = 1\n" * (zuvo_bill_judge.DIFF_CAP_BYTES // 7 + 9)        # part.py alone fills the cap
        self.diff("r-1", f"--- a/whole.py\n+++ b/whole.py\n+w = 0\n--- a/part.py\n+++ b/part.py\n{big}"
                         "--- a/cut.py\n+++ b/cut.py\n+b = 2\n")
        files = ("whole.py", "part.py", "cut.py")
        self.fake_claude_answer({"defects": [{"verdict": "false_positive", "finding_ids": [f"{p}:1:x"]}
                                             for p in files]})
        rows = [{**FINDING_ROW, "id": f"{p}:1:x", "file": f"{p}:1"} for p in files]
        rec, _ = zuvo_bill_judge.judge((ago(hours=2), "r-1", self.tmp, rows))
        self.assertEqual([d["verdict"] for d in rec["verdicts"]["defects"]],
                         ["false_positive", "uncertain", "uncertain"])
        self.assertEqual(rec["unseen_to_uncertain"], 2)

    def test_a_finding_names_a_shown_file_exactly_or_by_one_unique_suffix(self) -> None:
        # bug: `a.py` matched whichever of src/a.py and lib/a.py came first, and `x/a.py` matched
        # `xx/a.py`-style partial segments — a rejection kept for a file the model never saw
        import zuvo_bill_judge
        shown = ("diff --git a/src/a.py b/src/a.py\n--- a/src/a.py\n+++ b/src/a.py\n+1\n"
                 "--- a/lib/a.py\n+++ b/lib/a.py\n+2\n--- a/pkg/only.py\n+++ b/pkg/only.py\n+3\n"
                 "--- a/cut.py\n+++ b/cut.py\n+4\n")
        table = [("src/a.py", "false_positive"), ("./src/a.py", "false_positive"),
                 ("/Users/x/DEV/repo/pkg/only.py", "false_positive"),      # unique whole-segment suffix
                 ("a.py", "uncertain"),                                    # src/a.py or lib/a.py: neither
                 ("kg/only.py", "uncertain"),                              # not a whole segment
                 ("cut.py", "uncertain")]                                  # the file the cap cut
        cut = zuvo_bill_judge.Diff(shown, len(shown) + 100, len(shown))
        for path, expected in table:
            with self.subTest(path):
                defects = [{"verdict": "false_positive", "finding_ids": ["f"]}]
                zuvo_bill_judge.unseen_to_uncertain(defects, [{"id": "f", "file": f"{path}:1"}], cut)
                self.assertEqual(defects[0]["verdict"], expected)

    def test_a_diff_shown_whole_keeps_a_false_positive_on_its_last_file(self) -> None:
        # bug: the cut file's rule applied to an uncut diff — a single-file review could never keep a
        # false_positive
        import zuvo_bill_judge
        text = "--- a/only.py\n+++ b/only.py\n+1\n"
        defects = [{"verdict": "false_positive", "finding_ids": ["f"]}]
        rows = [{"id": "f", "file": "only.py:1"}]
        whole = zuvo_bill_judge.Diff(text, 30, 30)
        self.assertEqual(zuvo_bill_judge.unseen_to_uncertain(defects, rows, whole), 0)
        self.assertEqual(defects[0]["verdict"], "false_positive")

    def test_a_quoted_spaced_or_crlf_path_is_read_as_the_file_it_names(self) -> None:
        # bug: git C-quotes a non-ASCII name ("b/\\303\\251.py") and tab-ends one holding a space; read
        # raw, both looked unseen and a shown file's false_positive became uncertain
        import zuvo_bill_judge
        lf = ('diff --git a/sp ace.py b/sp ace.py\n--- a/sp ace.py\t\n+++ b/sp ace.py\t\n'
              '@@ -1 +1 @@\n-a\n+b\n'
              'diff --git "a/\\303\\251.py" "b/\\303\\251.py"\n--- "a/\\303\\251.py"\n+++ "b/\\303\\251.py"\n'
              "@@ -1 +1 @@\n--- removed sql comment\n+++ added, starts with ++\n--- a/cut.py\n+++ b/cut.py\n")
        for label, text in (("LF", lf), ("CRLF", lf.replace("\n", "\r\n"))):
            with self.subTest(label):
                self.assertEqual(zuvo_bill_judge.diff_files(text), ["sp ace.py", "é.py", "cut.py"])

    def test_a_run_id_that_is_not_a_plain_name_is_never_judged(self) -> None:
        # bug: the run id joins a path (adversarial-inputs/<run>.diff): `../x` read a file outside it
        proj = os.path.join(self.tmp, "proj")
        self.write_ledger([finding(ago(hours=2), run, "a.py:1:x", "a.py:1", proj)
                           for run in ("../outside", "r 1", "r-1")])
        for run in ("../outside", "r 1", "r-1"):
            self.diff(run)
        import zuvo_bill_judge
        import zuvo_bill_tick
        runs, judged = zuvo_bill_tick.read_ledger()
        self.assertEqual([q[1] for q in zuvo_bill_tick.pending(runs, judged, done=set())], ["r-1"])
        with self.assertRaises(ValueError):
            zuvo_bill_judge.judge((ago(hours=2), "../outside", proj, []))


class Lock(BillTestCase):
    def setUp(self) -> None:
        super().setUp()
        os.makedirs(os.path.join(self.zuvo, "bill-data"))

    def acquire(self) -> Any:
        import zuvo_bill_config
        got = zuvo_bill_config.acquire_lock()
        if got is None:
            self.addCleanup(zuvo_bill_config.release_lock)
        return got

    def test_the_lock_is_refused_while_another_process_holds_it_and_free_once_it_is_gone(self) -> None:
        # bug: a lock that outlives its holder (a killed tick) or is taken from a live one (a laptop
        # asleep mid-tick, a wall-clock staleness guess) stops Bill or runs two ticks paying twice
        import zuvo_bill_config
        for how in ("released", "killed"):
            with self.subTest(how):
                holder = self.lock_holder()
                self.assertEqual(self.acquire(), zuvo_bill_config.Refused("a tick is already running", False))
                if how == "released":
                    self.assertEqual(self.tell(holder, "release"), "released")
                else:
                    holder.kill()
                    holder.wait(10)
                self.assertIsNone(self.acquire())
                zuvo_bill_config.release_lock()

    def test_a_child_of_a_dead_tick_does_not_keep_the_lock(self) -> None:
        # bug: claude or the driver inheriting the lock's fd would hold the lock after the tick died,
        # until that child exits (up to the 30-minute call timeout)
        holder = self.lock_holder()
        child = int(self.tell(holder, "spawn"))
        self.addCleanup(kill_quietly, child)
        holder.kill()
        holder.wait(10)
        self.assertIsNone(self.acquire())

    def test_a_tick_of_the_release_before_is_respected_until_its_lock_is_old(self) -> None:
        # bug: during an upgrade the old release's tick (a `.lock` directory) and a new tick both ran;
        # a dead old tick's directory must not block Bill for good either
        import zuvo_bill_config
        legacy = os.path.join(self.zuvo, "bill-data", ".lock")
        for age_h, refused in ((1, True), (4, False)):
            with self.subTest(age_h=age_h):
                os.makedirs(legacy, exist_ok=True)
                then = time.time() - age_h * 3600
                os.utime(legacy, (then, then))
                got = self.acquire()
                expected = zuvo_bill_config.Refused("a tick is already running (legacy lock)", False)
                self.assertEqual(got, expected if refused else None)
                self.assertIs(os.path.isdir(legacy), refused)
                zuvo_bill_config.release_lock()

    def test_a_lock_that_cannot_be_checked_refuses_with_its_reason_and_leaks_no_fd(self) -> None:
        # bug: an unopenable lock file or an unreadable legacy path raised out of the tick (a traceback
        # every 10 minutes) and left the lock fd open
        cases = {"lock file is a directory": lambda bd: os.mkdir(os.path.join(bd, "tick.flock")),
                 "legacy path loops": lambda bd: os.symlink(".lock", os.path.join(bd, ".lock"))}
        for label, breaks in cases.items():
            with self.subTest(label):
                self.setenv(ZUVO_HOME=os.path.join(self.tmp, label))
                bd = os.path.join(self.tmp, label, "bill-data")
                os.makedirs(bd)
                breaks(bd)
                before = len(os.listdir("/dev/fd"))
                got = self.acquire()
                self.assertEqual(len(os.listdir("/dev/fd")), before)
                self.assertIsNotNone(got)
                self.assertTrue(got.error, got)

    def test_status_names_the_process_holding_the_lock(self) -> None:
        # bug: flock has no age takeover, so a hung live tick stops Bill — invisibly without this
        holder = self.lock_holder()
        out = self.run_bill("--status")
        self.assertRegex(out.stdout, rf"lock held by pid {holder.pid} since \d{{4}}-\d\d-\d\dT")
        self.tell(holder, "release")
        self.assertNotIn("lock held", self.run_bill("--status").stdout)


class Schedule(BillTestCase):
    def install(self, platform: str, cmd: str, step: str) -> tuple[int, str, list[str]]:
        """install_schedule() in a fresh HOME — named after the steps, so a check matching inside the
        path shows — with launchctl/systemctl stubs that log every call; `cmd` fails (exit 3) only on
        an argv starting with `step`, and a trailing \xff makes it print undecodable bytes."""
        import zuvo_bill_schedule
        home = os.path.join(self.tmp, f"home-load-enable-daemon-reload-{len(os.listdir(self.tmp))}")
        os.makedirs(home)
        self.setenv(HOME=home)
        if step == "no-agents-dir":
            self.write(os.path.join(home, "Library"), "a file, not a directory")
        log = shlex.quote(os.path.join(home, "calls"))
        fail = step.rstrip("\xff")
        say = r"printf '\377 refused\n' >&2" if step.endswith("\xff") else "echo refused >&2"
        for name in ("launchctl", "systemctl"):
            fails = f'case "$*" in "{fail}"|"{fail} "*) {say}; exit 3;; esac\n' if name == cmd else ""
            self.fake_exe(name, f'echo "{name} $*" >> {log}\n{fails}')
        err = io.StringIO()
        with mock.patch.object(sys, "platform", platform), \
                contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            rc = zuvo_bill_schedule.install_schedule()
        calls = os.path.join(home, "calls")
        return rc, err.getvalue(), self.read_lines(calls) if os.path.exists(calls) else []

    def test_install_schedule_fails_loudly_when_the_scheduler_refuses(self) -> None:
        # bug: a refused launchctl/systemctl call (or no LaunchAgents dir, or undecodable output) still
        # exited 0 or tracebacked — the owner believed Bill was scheduled while nothing would run it
        cases = [("darwin", "launchctl", "load"), ("darwin", "launchctl", "load\xff"),
                 ("darwin", "", "no-agents-dir"), ("linux", "systemctl", "--user daemon-reload"),
                 ("linux", "systemctl", "--user enable")]
        for platform, cmd, step in cases:
            with self.subTest(platform=platform, step=step):
                rc, err, calls = self.install(platform, cmd, step)
                self.assertEqual(rc, 1)
                self.assertIn("schedule not installed", err)
                if cmd:
                    self.assertIn(f"{cmd} {step.rstrip(chr(255))}", "\n".join(calls))

    def test_a_failed_daemon_reload_does_not_enable_the_timer(self) -> None:
        # bug: enabling after a failed daemon-reload starts units systemd has not re-read
        _rc, _err, calls = self.install("linux", "systemctl", "--user daemon-reload")
        self.assertFalse([c for c in calls if " enable" in c], calls)

    def test_install_schedule_succeeds_when_the_scheduler_accepts(self) -> None:
        # bug: an install the scheduler accepted reported as refused (exit 1, a reason on stderr), or the
        # job never handed to the scheduler at all
        for platform, last in (("darwin", "launchctl load"), ("linux", "systemctl --user enable")):
            with self.subTest(platform):
                rc, err, calls = self.install(platform, "", "")
                self.assertEqual((rc, err), (0, ""))
                self.assertTrue(calls[-1].startswith(last), calls)


class State(BillTestCase):
    def test_a_tick_that_cannot_write_its_state_stops_before_any_paid_call(self) -> None:
        # bug: with judged-runs.txt or attempts.json unwritable a finished run was paid for, and its
        # defects recorded, again on every tick — the try cap could not persist either
        self.skip_if_root()
        cases = {"bill-data read-only": lambda bd: os.chmod(bd, 0o555),
                 "judged-runs.txt read-only":
                     lambda bd: os.chmod(self.write(f"{bd}/judged-runs.txt", ""), 0o444),
                 "attempts.json.tmp a directory": lambda bd: os.mkdir(f"{bd}/attempts.json.tmp"),
                 "attempts.json a directory": lambda bd: os.mkdir(f"{bd}/attempts.json")}
        for label, breaks in cases.items():
            with self.subTest(label):
                self.setenv(ZUVO_HOME=os.path.join(self.tmp, label, "zh"))
                self.zuvo = os.environ["ZUVO_HOME"]
                self.queue_review("r-1", ["a.py:1:x"])
                calls = os.path.join(self.tmp, label, "calls")
                self.fake_exe("claude", f'cat >/dev/null; echo call >> "{calls}"; exit 1\n')
                bd = os.path.join(self.zuvo, "bill-data")
                os.makedirs(bd)
                self.write(f"{bd}/tick.flock", "")
                breaks(bd)
                self.addCleanup(os.chmod, bd, 0o755)
                p = self.run_bill()
                self.assertEqual((p.returncode, "Traceback" in p.stdout + p.stderr), (1, False))
                self.assertIn("tick skipped before any paid call", p.stdout)
                self.assertFalse(os.path.exists(calls))

    def test_settle_reports_a_state_write_it_cannot_make_and_goes_on(self) -> None:
        # bug: settle() claims never to raise, but an OSError writing bill.log or judged-runs.txt (a
        # file going read-only mid-tick) escaped it and killed the tick with a traceback
        self.skip_if_root()
        import zuvo_bill_tick
        bd = os.path.join(self.zuvo, "bill-data")
        for name in ("bill.log", "judged-runs.txt"):
            with self.subTest(name):
                os.chmod(self.write(os.path.join(bd, name), ""), 0o444)
                self.addCleanup(os.chmod, os.path.join(bd, name), 0o644)
                err = io.StringIO()
                with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
                    zuvo_bill_tick.settle({"run": "r-1", "project": "", "findings": 1, "error": "x"},
                                          [], {"r-1": 2}, os.path.join(bd, "judged-runs.txt"))
                self.assertIn(f"cannot write {name}", err.getvalue())

    def test_a_run_settled_but_not_marked_done_keeps_counting_tries(self) -> None:
        # bug: a run settled (answered all-uncertain, or given up) while judged-runs.txt could not take
        # it had its tries forgotten — re-queued with a fresh budget, paid for on every tick
        self.skip_if_root()
        import zuvo_bill_tick
        done_f = os.path.join(self.zuvo, "bill-data", "judged-runs.txt")
        os.chmod(self.write(done_f, ""), 0o444)
        answered = {"run": "r-1", "project": "", "findings": 1,
                    "verdicts": {"defects": [{"verdict": "uncertain", "finding_ids": ["a.py:1:x"]}],
                                 "lessons": []}}
        for label, rec, before, after in (("answered", answered, {}, {"r-1": 1}),
                                          ("given up", {"run": "r-1", "project": "", "findings": 1,
                                                        "error": "x"}, {"r-1": 2}, {"r-1": 3})):
            with self.subTest(label), contextlib.redirect_stderr(io.StringIO()), \
                    contextlib.redirect_stdout(io.StringIO()):
                attempts = dict(before)
                zuvo_bill_tick.settle(json.loads(json.dumps(rec)), [{"id": "a.py:1:x", "lane": "c"}],
                                      attempts, done_f)
                self.assertEqual(attempts, after)

    def test_a_corrupt_attempts_file_is_moved_aside_and_reported(self) -> None:
        # bug: a corrupt attempts.json silently read as {} every tick — the cap on paid retries reset
        # with no trace of why
        import zuvo_bill_state
        bd = os.path.join(self.zuvo, "bill-data")
        self.write(os.path.join(bd, "attempts.json"), '{"r-1": 2,')
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(zuvo_bill_state.load_attempts({"r-1"}), {})
        self.assertFalse(os.path.exists(os.path.join(bd, "attempts.json")))
        self.assertEqual(len([n for n in os.listdir(bd) if n.startswith("attempts.json.corrupt-")]), 1)
        self.assertIn("attempts.json", err.getvalue())


class Status(BillTestCase):
    def test_status_counts_what_settled_answers_left_unjudged(self) -> None:
        # bug: findings an answer did not cover and defects dropped from it stay unjudged by design,
        # but nothing showed how many; counting a retried attempt too counts them once per try
        import zuvo_bill_status
        rows = [{"ts": ago(hours=1), "omitted": 2, "dropped_defects": 1, "recorded": True},
                {"ts": ago(hours=2), "omitted": 1, "recorded": "project-missing"},   # retired: not settled
                {"ts": ago(hours=30), "omitted": 4, "dropped_defects": 2, "recorded": True},
                {"ts": ago(hours=1), "omitted": 5, "dropped_defects": 9, "recorded": False},   # retried
                {"ts": ago(hours=1), "omitted": 6, "recorded": 1},      # not a settled marker
                {"ts": ago(hours=1)}]
        log = "".join(f"{json.dumps(r)}\n" for r in rows)
        self.write(os.path.join(self.zuvo, "bill-data", "bill.log"), log)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            zuvo_bill_status.status()
        self.assertIn("omitted findings: 6 total, 2 in 24 h; dropped defects: 3 total, 1 in 24 h",
                      out.getvalue())


class EnvInts(BillTestCase):
    def test_a_count_or_timeout_that_is_not_positive_falls_back_to_the_default_once_said(self) -> None:
        # bug: BILL_MAX_TRIES=0 or BILL_WORKERS=-1 silently meant 1 (one try, one worker) — a typo
        # changed how Bill pays without a word
        import zuvo_bill_config as C
        table = [("BILL_MAX_TRIES", C.max_tries, "0", 3), ("BILL_WORKERS", C.workers, "-1", 5),
                 ("BILL_TICK_SECONDS", C.budget, "x", 540), ("BILL_MAX_AGE_HOURS", C.max_age_h, "5", 5)]
        for var, read, raw, expected in table:
            with self.subTest(var=var, raw=raw):
                self.setenv(**{var: raw})
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    got = [read(), read()]
                self.assertEqual(got, [expected, expected])
                self.assertEqual(err.getvalue().count(var), 0 if raw == "5" else 1)


class Classes(BillTestCase):
    def test_the_prompt_lists_the_closed_class_vocabulary(self) -> None:
        # bug: the prompt offered a few examples ("e.g. race-condition, …"), so the judge invented
        # classes and one class written two ways read as two half-sized ones in the per-class rates
        import zuvo_bill_judge
        from zuvo_review_classes import CLASSES
        self.assertIn(", ".join(CLASSES), zuvo_bill_judge.build_prompt([], ""))

    def test_an_answer_class_outside_the_vocabulary_is_normalized_never_dropped(self) -> None:
        # bug: free text ("Concurrency", "made-up", none) reached defects.jsonl as its own class; a
        # defect dropped for its class would throw away a paid verdict
        fps = ["a.py:1:x", "a.py:2:y", "a.py:3:z", "a.py:4:w"]
        self.queue_review("r-1", fps)
        self.fake_driver()
        classes: list[Any] = ["Concurrency", "made-up", None, "logic"]
        self.fake_claude_answer({"defects": [{"verdict": "real", "class": c, "finding_ids": [fp]}
                                             for c, fp in zip(classes, fps, strict=True)]})
        import zuvo_bill_tick
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
        rows = self.read_lines(os.path.join(self.zuvo, "bill-data", "defects.jsonl"))
        self.assertEqual([json.loads(x)["class"] for x in rows],
                         ["race-condition", "other", "other", "logic"])


class DiffCounts(BillTestCase):
    def test_the_log_counts_added_and_removed_lines_of_the_whole_diff(self) -> None:
        # bug: no reviewed-lines denominator; counting by prefix alone reads a removed `-- comment` and
        # an added `++ x` as file headers, and counting the prompt's part stops at the cap
        import zuvo_bill_judge
        filler = "+a\n" * (zuvo_bill_judge.DIFF_CAP_BYTES // 3 + 10)          # past the cap on its own
        n = filler.count("\n")
        diff = ("diff --git a/q.sql b/q.sql\n--- a/q.sql\n+++ b/q.sql\n"
                "@@ -1,3 +1,3 @@\n ctx\n--- removed sql comment\n-old\n+++ added, starts with ++\n"
                "\\ No newline at end of file\n+new\n"
                f"--- a/big.py\n+++ b/big.py\n@@ -0,0 +1,{n} @@\n{filler}")
        self.queue_review("r-1", ["q.sql:1:x"])
        self.diff("r-1", diff)
        self.fake_driver()
        self.fake_claude_answer({"defects": [{"verdict": "uncertain", "finding_ids": ["q.sql:1:x"]}]})
        import zuvo_bill_tick
        zuvo_bill_tick.tick(False)
        log = json.loads(self.read_lines(os.path.join(self.zuvo, "bill-data", "bill.log"))[0])
        self.assertEqual((log["diff_added"], log["diff_removed"]), (2 + n, 2))
        self.assertLess(log["diff_bytes_sent"], log["diff_bytes"])


# sha256 of the service unit `bill --install-schedule` wrote before install_unit existed, with this test's
# temp directory written as <TMP> (HOME=<TMP>/home, ZUVO_HOME=<TMP>/home/.zuvo, PATH=<TMP>/bin:/usr/bin:/bin).
# The timer and the plist changed on purpose (owner 2026-10-18: a minute between ticks, not ten).
TODAY_UNITS = {
    ("linux", ".config/systemd/user/zuvo-bill.service"):
        "efc40180f0fc1151f03627ec13a3f649b9f9a9d2924000684866349dbcb4d9eb",
}


class UnitCase(BillTestCase):
    def setUp(self) -> None:
        super().setUp()
        self.calls = os.path.join(self.tmp, "calls")
        for name in ("launchctl", "systemctl"):   # FAIL_ON=<args prefix>: that call prints "failed", exits 3
            self.fake_exe(name, f'echo "{name} $*" >> "{self.calls}"\n'
                                'if [ -n "$FAIL_ON" ]; then\n'
                                '  case "$*" in "$FAIL_ON"*) echo failed >&2; exit 3;; esac\nfi\n')
        self.setenv(PATH=f"{self.bin}:/usr/bin:/bin", FAIL_ON="")

    def on(self, platform: str, call: Any) -> Any:
        with mock.patch.object(sys, "platform", platform), contextlib.redirect_stdout(io.StringIO()):
            return call()

    def unit_text(self, rel: str) -> str:
        with open(os.path.join(self.home, rel), encoding="utf-8") as f:
            return f.read()



class Units(UnitCase):
    def test_the_job_service_is_written_byte_for_byte_as_before(self) -> None:
        # bug: moving the writer behind install_unit changed the live job's unit text — a reinstall on
        # either host reschedules (or breaks) Bill
        import zuvo_bill_schedule
        for (platform, rel), digest in TODAY_UNITS.items():
            with self.subTest(rel):
                self.assertEqual(self.on(platform, zuvo_bill_schedule.install_schedule), 0)
                text = self.unit_text(rel).replace(self.tmp, "<TMP>")
                self.assertEqual(hashlib.sha256(text.encode()).hexdigest(), digest)

    def test_the_next_tick_starts_a_minute_after_the_last(self) -> None:
        # bug: ten idle minutes after every 9-minute tick — Bill worked half the time while the queue of
        # unjudged reviews grew past the 48 h window (2026-10-18: 205 queued, ~2 900 judged a day of ~6 000)
        import zuvo_bill_schedule
        self.assertEqual(self.on("linux", zuvo_bill_schedule.install_schedule), 0)
        self.assertIn("OnUnitInactiveSec=1min\n", self.unit_text(".config/systemd/user/zuvo-bill.timer"))
        self.assertEqual(self.on("darwin", zuvo_bill_schedule.install_schedule), 0)
        plist = plistlib.loads(self.unit_text("Library/LaunchAgents/com.zuvo.bill.plist").encode())
        self.assertEqual(plist["StartInterval"], 60)

    def test_a_calendar_unit_is_well_formed_for_both_schedulers(self) -> None:
        # bug: the weekly curation unit (Mon 06:00) written with an interval key, a malformed plist, or
        # an OnCalendar systemd rejects never runs, and nothing says so
        import zuvo_bill_schedule as S
        argv = ["/opt/z/bill", "--curate"]
        when = S.Calendar(weekday=1, hour=6, minute=0)
        self.assertEqual(self.on("darwin", lambda: S.install_unit("bill-curate", argv, calendar=when,
                                                                  description="zuvo Bill curation")), 0)
        plist = plistlib.loads(self.unit_text("Library/LaunchAgents/com.zuvo.bill-curate.plist").encode())
        self.assertEqual((plist["Label"], plist["ProgramArguments"], plist["StartCalendarInterval"]),
                         ("com.zuvo.bill-curate", argv, {"Weekday": 1, "Hour": 6, "Minute": 0}))
        self.assertNotIn("StartInterval", plist)
        self.assertEqual(self.on("linux", lambda: S.install_unit("bill-curate", argv, calendar=when,
                                                                 description="zuvo Bill curation")), 0)
        timer = configparser.ConfigParser(interpolation=None)
        timer.read_string(self.unit_text(".config/systemd/user/zuvo-bill-curate.timer"))
        self.assertEqual(dict(timer["Timer"]), {"oncalendar": "Mon *-*-* 06:00:00", "persistent": "true"})
        service = configparser.ConfigParser(interpolation=None)
        service.read_string(self.unit_text(".config/systemd/user/zuvo-bill-curate.service"))
        self.assertEqual(shlex.split(service["Service"]["ExecStart"]), argv)

    def test_uninstall_stops_the_job_and_removes_its_files(self) -> None:
        # bug: a unit that can only be installed keeps running after its feature is turned off; a stop
        # the scheduler refused reported as done leaves the job running with nothing to show for it
        import zuvo_bill_schedule as S
        plist, units = "Library/LaunchAgents/com.zuvo.bill-x.plist", ".config/systemd/user/zuvo-bill-x"
        table = [("darwin", [plist], "", 0, [f"launchctl unload {self.home}/{plist}"]),
                 ("darwin", [plist], "unload", 1, [f"launchctl unload {self.home}/{plist}"]),
                 ("linux", [f"{units}.service", f"{units}.timer"], "", 0,
                  ["systemctl --user disable --now zuvo-bill-x.timer", "systemctl --user daemon-reload"]),
                 ("linux", [f"{units}.service", f"{units}.timer"], "--user disable", 1,
                  ["systemctl --user disable --now zuvo-bill-x.timer"])]
        for platform, files, fail, rc, calls in table:
            with self.subTest(platform=platform, fail=fail):
                self.setenv(FAIL_ON="")
                self.on(platform, lambda: S.install_unit("bill-x", ["/b"], interval_s=60, description="x"))
                self.write(self.calls, "")
                self.setenv(FAIL_ON=fail)
                self.assertEqual(self.on(platform, lambda: S.uninstall_unit("bill-x")), rc)
                self.assertEqual(self.read_lines(self.calls), calls)
                left = [f for f in files if os.path.exists(os.path.join(self.home, f))]
                self.assertEqual(left, files if rc else [])


def defect(run: str, lanes: list[str], verdict_: str) -> str:
    return json.dumps({"ts": ago(hours=1), "run": run, "lanes": lanes, "verdict": verdict_}) + "\n"


PRECISION_FIXTURE = "".join([
    defect("r1", ["codex", "kimi"], "real"), defect("r1", ["codex"], "false_positive"),
    defect("r2", ["kimi"], "uncertain"), defect("r2", ["codex"], "real"),
    defect("r3", ["agy"], "false_positive"), defect("r3", ["mercury"], "uncertain"),
    defect("r3", [], "real"),                     # its findings were all judged by the agent meanwhile
])


class PrecisionTables(BillTestCase):
    def table(self, flag: str) -> dict[str, list[str]]:
        self.write(os.path.join(self.zuvo, "bill-data", "defects.jsonl"), PRECISION_FIXTURE)
        out = self.run_bill("--status", flag).stdout
        rows = out.split(f"precision {flag[2:].replace('-', ' ')}:\n", 1)[1].splitlines()[1:]
        return {r.split()[0]: r.split()[1:] for r in rows if r.startswith("  ")}

    def test_precision_by_lane(self) -> None:
        # bug: per-lane precision rested on the agents' ~6 % of verdicts while Bill's own sat unread;
        # a lane with only uncertain verdicts must read "-", not 0 (or a ZeroDivisionError)
        self.assertEqual(self.table("--by-lane"), {
            "codex": ["2", "3", "2", "1", "0", "0.67"], "kimi": ["2", "2", "1", "0", "1", "1.00"],
            "agy": ["1", "1", "0", "1", "0", "0.00"], "mercury": ["1", "1", "0", "0", "1", "-"]})

    def test_precision_by_how_many_lanes_agreed(self) -> None:
        # bug: whether a defect raised by two lanes is likelier real than one raised by one was
        # unmeasured; a defect with no recorded lane counted as an agreement of 0
        self.assertEqual(self.table("--by-agreement"), {
            "1": ["3", "5", "1", "2", "2", "0.33"], "2": ["1", "1", "1", "0", "0", "1.00"]})

    def test_plain_status_prints_no_table(self) -> None:
        # bug: the tables leaking into the plain --status output the bill page and the live checks parse
        self.write(os.path.join(self.zuvo, "bill-data", "defects.jsonl"), PRECISION_FIXTURE)
        self.assertNotIn("precision by", self.run_bill("--status").stdout)


class Projects(BillTestCase):
    def queue_under(self, project: str, label: str = "") -> str:
        """One review of `project` in a ZUVO_HOME of its own; returns the file fake claude logs calls to."""
        self.setenv(ZUVO_HOME=os.path.join(self.tmp, label or "zh"))
        self.zuvo = os.environ["ZUVO_HOME"]
        self.write_ledger([finding(ago(hours=2), "r-1", "a.py:1:x", "a.py:1", project)])
        self.diff("r-1")
        calls = os.path.join(self.tmp, label or "zh", "calls")
        self.fake_exe("claude", f'cat >/dev/null; echo call >> "{calls}"; exit 1\n')
        return calls

    def tick(self) -> int:
        import zuvo_bill_tick
        with contextlib.redirect_stdout(io.StringIO()):
            return zuvo_bill_tick.tick(False)

    def done(self) -> list[str]:
        path = os.path.join(self.zuvo, "bill-data", "judged-runs.txt")
        return self.read_lines(path) if os.path.exists(path) else []

    def test_a_bare_name_is_judged_and_recorded_from_the_checkout_it_names(self) -> None:
        # bug: rows keyed by a bare name (the driver before absolute paths) were judged and their verdict
        # dropped, or never judged at all — the driver now records them from their checkout
        dev = os.path.join(self.home, "DEV", "repo")
        mirrored = os.path.join(self.tmp, "elsewhere", "repo2")
        for d in (dev, mirrored):
            os.makedirs(os.path.join(d, ".git"))
        table = {"~/DEV/<name>": ("repo", dev), "a mirrored ledger's absolute path": ("repo2", mirrored)}
        for label, (name, checkout) in table.items():
            with self.subTest(label):
                self.queue_under(name, label)
                self.write(os.path.join(self.zuvo, "remote", "host", "adversarial-findings.log"),
                           finding(ago(hours=90), "old", "b.py:1:y", "b.py:1", mirrored) + "\n")
                args = self.fake_driver()
                self.fake_claude_answer({"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}]})
                self.assertEqual(self.tick(), 0)
                self.assertEqual(self.read_lines(args), ["--record-disposition", "a.py:1:x", "deferred"])
                cwd = self.read_lines(args + ".cwd")[0]
                self.assertEqual(os.path.realpath(cwd), os.path.realpath(checkout))
                self.assertEqual(self.done(), ["r-1"])

    def test_a_review_without_a_checkout_is_never_paid_for_and_rechecked_every_tick(self) -> None:
        # bug: it was judged and its verdict dropped ("project-missing"), or marked done for good though
        # the checkout could appear within the window (a volume mounted, a repo cloned, a .git restored)
        not_git = os.path.join(self.tmp, "plain")
        os.makedirs(not_git)
        table = {"bare name, no checkout here": ("gone-repo", "no-checkout"),
                 "no project": ("", "no-project"),
                 "absolute path, not a git checkout": (not_git, "not-a-checkout"),
                 "absolute path gone": (os.path.join(self.tmp, "volume", "repo"), "project-gone")}
        for label, (project, reason) in table.items():
            with self.subTest(label):
                calls = self.queue_under(project, label)
                for _ in range(2):
                    self.assertEqual(self.tick(), 0)
                self.assertFalse(os.path.exists(calls))
                self.assertEqual(self.done(), [])
                logged = self.read_lines(os.path.join(self.zuvo, "bill-data", "unrecordable.jsonl"))
                self.assertEqual(len(logged), 1)
                status = self.run_bill("--status").stdout
                self.assertIn(f"unjudged inside the 48 h window: 1 — {reason} 1", status)

    def test_a_review_whose_checkout_appears_is_judged_and_no_longer_counted(self) -> None:
        # bug: a run recorded later, once its checkout was back, still counted as unrecordable for good
        project = os.path.join(self.tmp, "volume", "repo")
        self.queue_under(project)
        self.tick()
        os.makedirs(os.path.join(project, ".git"))
        self.fake_driver()
        self.fake_claude_answer({"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}]})
        self.tick()
        self.assertEqual(self.done(), ["r-1"])
        self.assertNotIn("unrecordable", self.run_bill("--status").stdout)

    def test_the_driver_records_an_id_raised_under_the_checkouts_bare_name(self) -> None:
        # bug: the contract Bill's bare-name resolution rests on — run from the checkout, the driver
        # must accept an id raised under its basename, or every such verdict is refused after a paid call
        repo = os.path.join(self.tmp, "repo")
        env = {**os.environ, "GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        subprocess.run(["git", "init", "-q", repo], check=True, env=env, timeout=30)
        ledger = self.write_ledger([finding(ago(hours=2), "r-1", "a.py:1:x", "a.py:1", "repo")])
        p = subprocess.run([str(DRIVER), "--record-disposition", "a.py:1:x", "deferred"], cwd=repo,
                           env=env, capture_output=True, text=True, timeout=60)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(self.read_lines(ledger)[-1].split("\t")[9], "deferred")


class Record(BillTestCase):
    def test_a_defect_left_without_ids_is_not_written(self) -> None:
        # bug: a defect whose every id was judged by the agent meanwhile, or never raised by the review,
        # reached defects.jsonl with no lanes — counted in every precision table as Bill's verdict
        proj = self.queue_review("r-1", ["a.py:1:x", "a.py:2:y"])
        with open(os.path.join(self.zuvo, "adversarial-findings.log"), "a", encoding="utf-8") as f:
            f.write(verdict(ago(minutes=1), "a.py:2:y", "fixed", proj) + "\n")
        self.fake_driver()
        self.fake_claude_answer({"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]},
                                             {"verdict": "real", "finding_ids": ["a.py:2:y"]},
                                             {"verdict": "real", "finding_ids": ["forged:9:id"]}]})
        import zuvo_bill_tick
        with contextlib.redirect_stdout(io.StringIO()):
            zuvo_bill_tick.tick(False)
        rows = self.read_lines(os.path.join(self.zuvo, "bill-data", "defects.jsonl"))
        self.assertEqual([json.loads(x)["finding_ids"] for x in rows], [["a.py:1:x"]])

    def test_a_checkout_gone_during_the_call_writes_nothing_and_is_retried(self) -> None:
        # bug: defects and lessons were written although the ledger never took the verdict, and the run
        # was marked done — Bill's tables counted verdicts the ledger never saw
        import zuvo_bill_tick
        rec = {"run": "r-1", "project": os.path.join(self.tmp, "gone"), "findings": 1,
               "verdicts": {"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}], "lessons": ["l"]}}
        attempts: dict[str, int] = {}
        done_f = os.path.join(self.zuvo, "bill-data", "judged-runs.txt")
        os.makedirs(os.path.dirname(done_f))
        with contextlib.redirect_stdout(io.StringIO()):
            zuvo_bill_tick.settle(rec, [{"id": "a.py:1:x", "lane": "codex"}], attempts, done_f)
        self.assertEqual((rec["recorded"], attempts), (False, {"r-1": 1}))
        self.assertEqual(sorted(os.listdir(os.path.dirname(done_f))), ["bill.log"])


class RecordDriver(BillTestCase):
    def test_a_driver_that_cannot_start_is_a_retry_not_a_traceback(self) -> None:
        # bug: a missing driver (or a cwd gone between the check and the call) raised out of record()
        import zuvo_bill_tick
        proj = self.queue_review("r-1", ["a.py:1:x"])
        rec = {"run": "r-1", "project": proj, "findings": 1,
               "verdicts": {"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}], "lessons": []}}
        zuvo_bill_tick.record(rec, [{"id": "a.py:1:x", "lane": "codex"}])
        self.assertIs(rec["recorded"], False)
        self.assertIn("FileNotFoundError", str(rec["error"]))


class Flags(BillTestCase):
    def test_a_flag_bill_does_not_take_exits_2_and_never_ticks(self) -> None:
        # bug: `bill --by-lane` (without --status) or a typo like `--stauts` started a paid tick
        self.queue_review("r-1", ["a.py:1:x"])
        calls = os.path.join(self.tmp, "calls")
        self.fake_exe("claude", f'cat >/dev/null; echo call >> "{calls}"; exit 1\n')
        for argv in (["--by-lane"], ["--by-agreement", "--dry-run"], ["--stauts"]):
            with self.subTest(argv=argv):
                p = self.run_bill(*argv)
                self.assertEqual(p.returncode, 2, p.stdout + p.stderr)
                self.assertIn(f"bill: {argv[0]}: not a flag here", p.stderr)
        self.assertFalse(os.path.exists(calls))


class UnitChecks(UnitCase):
    def test_a_bad_label_or_time_is_refused_before_anything_is_written(self) -> None:
        # bug: a label with a slash or a space wrote outside LaunchAgents / an unloadable unit; weekday 0 or
        # 8 wrapped onto another day; a 1-second interval made a paid job run back to back
        import zuvo_bill_schedule as S
        table: list[tuple[str, dict[str, Any]]] = [
                 ("../evil", {"interval_s": 600}), ("a b", {"interval_s": 600}), ("", {"interval_s": 600}),
                 ("ok", {"interval_s": 59}), ("ok", {"interval_s": True}), ("ok", {}),
                 ("ok", {"interval_s": 600, "calendar": S.Calendar(1, 6, 0)}),
                 ("ok", {"calendar": S.Calendar(0, 6, 0)}), ("ok", {"calendar": S.Calendar(8, 6, 0)}),
                 ("ok", {"calendar": S.Calendar(1, 24, 0)}), ("ok", {"calendar": S.Calendar(1, 6, 60)})]
        for label, when in table:
            with self.subTest(label=label, when=when), self.assertRaises(ValueError):
                S.install_unit(label, ["/b"], description="x", **when)
        with self.assertRaises(ValueError):
            S.uninstall_unit("../evil")
        self.assertFalse(os.path.exists(os.path.join(self.home, ".config")))
        self.assertFalse(os.path.exists(self.calls))

    def test_a_refused_install_takes_back_the_files_it_wrote(self) -> None:
        # bug: a plist launchd refused stayed behind and loaded at the next login; one that replaced a
        # working unit left the job broken
        import zuvo_bill_schedule as S
        plist = os.path.join(self.home, "Library/LaunchAgents/com.zuvo.bill-x.plist")
        for before in (None, "<plist>the working one</plist>"):
            with self.subTest(before=before):
                if before is not None:
                    self.write(plist, before)
                self.setenv(FAIL_ON="load")
                rc = self.on("darwin",
                             lambda: S.install_unit("bill-x", ["/b"], interval_s=600, description="x"))
                self.assertEqual(rc, 1)
                if before is None:
                    self.assertFalse(os.path.exists(plist))
                else:
                    with open(plist, encoding="utf-8") as f:
                        self.assertEqual(f.read(), before)

    def test_a_refused_start_is_stopped_again(self) -> None:
        # bug: `load` / `enable --now` can start the job and still report failure; the rollback removed
        # its files and left it running
        import zuvo_bill_schedule as S
        plist = f"{self.home}/Library/LaunchAgents/com.zuvo.bill-x.plist"
        table = [("darwin", "load", [f"launchctl load {plist}", f"launchctl unload {plist}"]),
                 ("linux", "--user enable", ["systemctl --user enable --now zuvo-bill-x.timer",
                                             "systemctl --user disable --now zuvo-bill-x.timer"])]
        for platform, fail, tail in table:
            with self.subTest(platform):
                self.write(self.calls, "")
                self.setenv(FAIL_ON=fail)
                self.on(platform, lambda: S.install_unit("bill-x", ["/b"], interval_s=600, description="x"))
                calls = self.read_lines(self.calls)
                self.assertEqual(calls[calls.index(tail[0]):calls.index(tail[0]) + 2], tail)

    def test_install_schedule_reports_a_refused_unit_and_exits_1(self) -> None:
        # bug: install_unit's ValueError escaped `bill --install-schedule` as a traceback
        import zuvo_bill_schedule as S
        err = io.StringIO()
        with mock.patch.object(S, "MIN_INTERVAL_S", 61), contextlib.redirect_stderr(err):
            self.assertEqual(S.install_schedule(), 1)
        self.assertIn("schedule not installed — install_unit: interval_s 60 ", err.getvalue())

    def test_a_percent_in_a_systemd_value_is_escaped(self) -> None:
        # bug: systemd reads % as a specifier — "50% of runs" or a log path with % became another text
        import zuvo_bill_schedule as S
        log = os.path.join(self.tmp, "logs 100%", "curate.log")
        self.on("linux", lambda: S.install_unit("bill-x", ["/b", "50%"], interval_s=600,
                                                description="50% of runs", log=log))
        text = self.unit_text(".config/systemd/user/zuvo-bill-x.service")
        self.assertIn("Description=50%% of runs\n", text)
        self.assertIn('ExecStart="/b" "50%%"\n', text)
        self.assertIn(f"StandardOutput=append:{log.replace('%', '%%')}\n", text)


class StatusInput(BillTestCase):
    def test_status_survives_malformed_rows(self) -> None:
        # bug: one hand-edited or torn-and-rewritten row (usd "n/a" or NaN, a numeric ts, a list as run id,
        # a number as lane, "error": null) made --status raise or print nonsense — the one command that
        # says why Bill is not working
        bd = os.path.join(self.zuvo, "bill-data")
        self.write(f"{bd}/bill.log", "".join(json.dumps(r) + "\n" for r in [
            {"ts": ago(hours=1), "usd": 0.5, "secs": 12, "error": "x"},
            {"ts": ago(hours=1), "usd": "n/a", "secs": None, "error": None},
            {"ts": ago(hours=1), "usd": float("nan")}, {"ts": ago(hours=1), "usd": float("inf")},
            {"ts": 5, "usd": 1}]))
        self.write(f"{bd}/unrecordable.jsonl", "".join(json.dumps(r) + "\n" for r in [
            {"run": ["x"], "ts": ago(hours=1)},
            {"run": "aged-out", "review_ts": ago(hours=72), "reason": "project-gone"}]))
        self.write(f"{bd}/defects.jsonl", "".join(json.dumps(r) + "\n" for r in [
            {"run": ["x"], "lanes": ["codex", 7], "verdict": "real"},
            {"run": "r2", "lanes": [7], "verdict": "real"}]))
        p = self.run_bill("--status", "--by-lane")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("errors 24 h: 1;", p.stdout)
        self.assertIn("API-price USD 24 h: 0.50; mean seconds: 3", p.stdout)
        self.assertNotIn("unrecordable", p.stdout)
        table = p.stdout.split("precision by lane:\n", 1)[1].splitlines()[1:]
        self.assertEqual([r.split()[0] for r in table], ["codex"])

    def test_status_says_an_unreadable_unrecordable_log_and_goes_on(self) -> None:
        # bug: an OSError reading unrecordable.jsonl ended --status with a traceback
        os.makedirs(os.path.join(self.zuvo, "bill-data", "unrecordable.jsonl"))
        p = self.run_bill("--status")
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertIn("unrecordable runs: unreadable", p.stdout)


if __name__ == "__main__":
    unittest.main()


class CodexJudge(BillTestCase):
    """BILL_MODEL gpt-* runs through `codex exec --json` (owner 2026-10-18: Bill on gpt-6.1-sol high)."""

    def codex(self, events: list[dict[str, Any]], rc: int = 0) -> str:
        """A fake `codex` printing `events` as JSONL; it logs its argv and the CODEX_HOME config it got."""
        out = self.write("codex.out", "".join(json.dumps(e) + "\n" for e in events))
        log = os.path.join(self.tmp, "codex.log")
        self.fake_exe("codex", f'cat >/dev/null; echo "$*" >> "{log}"; cat "$CODEX_HOME/config.toml" >> "{log}"\n'
                               f'ls "$CODEX_HOME" >> "{log}"; cat "{out}"; exit {rc}\n')
        self.setenv(BILL_MODEL="gpt-6.1-sol", BILL_EFFORT="high", CODEX_HOME=self.write_dir("codex-src"))
        self.write(os.path.join(self.tmp, "codex-src", "auth.json"), "{}")
        return log

    def write_dir(self, name: str) -> str:
        path = os.path.join(self.tmp, name)
        os.makedirs(path, exist_ok=True)
        return path

    def test_gpt_model_verdicts_land_through_codex_with_its_model_and_effort(self) -> None:
        # bug: Bill hardwired to claude — BILL_MODEL=gpt-6.1-sol still called claude (or nothing)
        self.queue_review("r-1", ["a.py:1:x"], hours=2)
        self.fake_driver()
        answer = {"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}], "lessons": []}
        log = self.codex([{"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(answer)}},
                          {"type": "turn.completed", "usage": {"input_tokens": 900, "output_tokens": 70}}])
        import zuvo_bill_tick
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
        seen = open(log, encoding="utf-8").read()
        self.assertIn('model = "gpt-6.1-sol"', seen)
        self.assertIn('model_reasoning_effort = "high"', seen)
        self.assertIn("--disable shell_tool", seen)
        self.assertIn("auth.json", seen)
        rec = json.loads(self.read_lines(os.path.join(self.zuvo, "bill-data", "bill.log"))[-1])
        self.assertEqual((rec.get("error"), rec["recorded"], rec["tokens_in"], rec["tokens_out"]),
                         (None, True, 900, 70))

    def test_a_reconnect_codex_recovered_from_does_not_fail_the_verdict(self) -> None:
        # bug: codex reports "Reconnecting... 1/5" as an `error` event and then answers with rc 0 — read
        # as a failure, the paid verdict was thrown away and the review retried
        self.queue_review("r-1", ["a.py:1:x"], hours=2)
        self.fake_driver()
        answer = {"defects": [{"verdict": "real", "finding_ids": ["a.py:1:x"]}], "lessons": []}
        self.codex([{"type": "error", "message": "Reconnecting... 1/5 (stream disconnected)"},
                    {"type": "item.completed", "item": {"type": "agent_message", "text": json.dumps(answer)}}])
        import zuvo_bill_tick
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
        rec = json.loads(self.read_lines(os.path.join(self.zuvo, "bill-data", "bill.log"))[-1])
        self.assertEqual((rec.get("error"), rec["recorded"]), (None, True))

    def test_codex_usage_limit_event_stops_the_tick_without_using_a_try(self) -> None:
        # bug: a codex limit arrives as a JSONL `error` event, not on stderr — read as an ordinary failure
        # it burned every queued review's tries while the account was out
        self.queue_review("r-1", ["a.py:1:x"], hours=2)
        self.codex([{"type": "error", "message": "You've hit your usage limit. Try again at 7:05 PM."}], rc=1)
        self.setenv(BILL_WORKERS="1")
        import zuvo_bill_tick
        self.assertEqual(zuvo_bill_tick.tick(False), 0)
        with open(os.path.join(self.zuvo, "bill-data", "attempts.json"), encoding="utf-8") as f:
            self.assertEqual(json.load(f), {})


class LimitText(BillTestCase):
    def test_weekly_and_session_limits_are_limits(self) -> None:
        # bug: "You've hit your weekly limit" / "session limit" did not match — 1 215 + 1 500 reviews on
        # ryzen-dev (2026-10) used up their tries on an account that was out, then aged out unjudged
        import zuvo_bill_judge as J
        for text, limited in (("You've hit your weekly limit · resets Oct 22", True),
                              ("You've hit your session limit · resets 4:30", True),
                              ("You've hit your limit", True), ("You've reached your 5-hour limit", True),
                              ("You've hit your model usage limit", True),
                              ("no JSON object in the reply", False)):
            with self.subTest(text=text):
                self.assertEqual(bool(J.LIMIT_RE.search(text)), limited)
