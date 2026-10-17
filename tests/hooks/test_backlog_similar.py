"""scripts/zuvo-home/zuvo_backlog_similar — the ADVISORY duplicate hint of `backlog-add` (stage 1 of
B-20261015-DEDUP-ANCHOR-CHOICE-SPLITS).

The module decides nothing and writes nothing, so what these specs protect is the opposite of a
feature: that it stays off unless asked, that it never reaches the network when it has nothing to
ask, that it cannot fail the one locked write path, and that its call is made OUTSIDE the lock. Every
test names the defect it catches. No test reaches a real network: the unit specs replace the one
transport seam, and the two launcher specs run a stub HTTP server on loopback.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
LAUNCHER = os.path.join(HOME_DIR, "backlog-add")
sys.path.insert(0, HOME_DIR)
import zuvo_backlog_admit as adm  # noqa: E402
import zuvo_backlog_findings as fnd  # noqa: E402
import zuvo_backlog_similar as sim  # noqa: E402

NOW = "2026-10-17T10:00:00+00:00"
KEY = "sk-or-fixture"
ANCHOR_A = "if total > limit:"
ANCHOR_B = "return total - limit"
SOURCE = "a = 1\nb = 2\nif total > limit:\n    return total - limit\n"
HERMETIC_GIT = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": os.devnull}
SCRUB = ("ZUVO_BACKLOG_PR", "ZUVO_BACKLOG_ADMIT", "ZUVO_LOCK_WAIT", "ZUVO_BACKLOG_READY_FILE",
         "ZUVO_BACKLOG_SIMILAR", "ZUVO_BACKLOG_SIMILAR_URL", "ZUVO_BACKLOG_SIMILAR_MODEL",
         "ZUVO_BACKLOG_SIMILAR_THRESHOLD", "ZUVO_BACKLOG_SIMILAR_TIMEOUT", "OPENROUTER_API_KEY",
         "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
         "GIT_PREFIX", "GIT_CEILING_DIRECTORIES")


def finding(anchor: str = ANCHOR_A, cls: str = "BUG", path: Optional[str] = "src/a.py",
            line: Any = 3, title: str = "off-by-one at the limit") -> adm.Finding:
    return adm.Finding(cls=cls, conf=85, source="review", title=title, file=path, line=line,
                       anchor=anchor, evidence="the loop runs one iteration too many")


def decision(f: adm.Finding) -> adm.Decision:
    return adm.decide(f, set(), False)


def record(f: adm.Finding, *, ts: str = NOW, backlog: Optional[str] = None) -> fnd.Record:
    fields = fnd.record_for(f, decision(f), adm.fingerprint(f), backlog=backlog, ts=ts)
    return fnd.Record(dict(fields), 1)


def records_of(*findings: adm.Finding) -> Dict[str, fnd.Record]:
    return {adm.fingerprint(f): record(f) for f in findings}


def scrubbed_env() -> Dict[str, str]:
    env = {k: v for k, v in os.environ.items() if k not in SCRUB}
    env.update(HERMETIC_GIT)
    return env


class StubDecisions:
    """A loopback Decisions endpoint. Records every request body, answers with `probability` (or the
    HTTP status in `status`), and runs `on_request` before answering so a spec can observe what the
    caller had already done to the filesystem at the moment the call was made."""

    def __init__(self, probability: float = 0.9, status: int = 200, on_request: Any = None) -> None:
        self.bodies: List[Dict[str, Any]] = []
        self.notes: List[Any] = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler's name
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                outer.bodies.append(json.loads(raw or b"{}"))
                if on_request is not None:
                    outer.notes.append(on_request())
                if status != 200:
                    self.send_error(status)
                    return
                payload = json.dumps({"choice": "DUP", "confidence": 0.5,
                                      "probabilities": {"DUP": probability,
                                                        "DIFFERENT": 1.0 - probability}}).encode()
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(payload)))
                self.end_headers()
                self.wfile.write(payload)

            def log_message(self, *_: Any) -> None:
                return

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)

    def __enter__(self) -> "StubDecisions":
        self.thread.start()
        return self

    def __exit__(self, *_: Any) -> None:
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=5)

    @property
    def url(self) -> str:
        host, port = self.server.server_address[:2]
        return f"http://{host}:{port}/api/alpha/decisions"


class GateCase(unittest.TestCase):
    """What must be true before a paid endpoint is reached at all."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="similar-gate-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.f = finding()
        self.calls: List[Any] = []

    def advise(self, **env: str) -> Optional[str]:
        """`advise` over a ledger holding ONE same-file same-class finding with another anchor, with
        the transport replaced so any attempt to reach it is recorded rather than made."""
        other = finding(anchor=ANCHOR_B, line=4)
        with mock.patch.object(sim, "_post", side_effect=lambda *a, **k: self.calls.append(a)), \
             mock.patch.object(fnd, "fold", return_value=(records_of(other), [])), \
             mock.patch.dict(os.environ, {k: v for k, v in env.items()}, clear=False):
            for name in SCRUB:
                if name not in env:
                    os.environ.pop(name, None)
            return sim.advise(self.tmp, self.f, decision(self.f), adm.fingerprint(self.f))

    def test_off_unless_the_flag_is_set(self) -> None:
        """Defect: the hint ships enabled and every ACCEPT on every machine makes a paid API call."""
        self.assertIsNone(self.advise(OPENROUTER_API_KEY=KEY))
        self.assertEqual(self.calls, [])

    def test_a_flag_that_is_not_exactly_one_does_not_enable_it(self) -> None:
        """Defect: `ZUVO_BACKLOG_SIMILAR=0` (or `false`) read as truthy, turning the opt-out on."""
        for value in ("0", "false", "no", "", " "):
            with self.subTest(value=value):
                self.assertIsNone(self.advise(ZUVO_BACKLOG_SIMILAR=value, OPENROUTER_API_KEY=KEY))
        self.assertEqual(self.calls, [])

    def test_no_key_is_a_silent_no_op(self) -> None:
        """Defect: a machine with the flag but no key gets a warning (or a traceback) on every
        ACCEPT — stderr nagging on the one write path trains callers to stop reading it."""
        self.assertIsNone(self.advise(ZUVO_BACKLOG_SIMILAR="1"))
        self.assertEqual(self.calls, [])

    def test_a_key_file_readable_by_others_is_not_used(self) -> None:
        """Defect: the hint reads a key the adversarial driver refuses, so tightening the mode in one
        place leaves the other reading it anyway."""
        home = self.tmp / "home"
        (home / ".zuvo").mkdir(parents=True)
        key_file = home / ".zuvo" / "openrouter.key"
        key_file.write_text(KEY, encoding="utf-8")
        for mode, expected in ((0o644, None), (0o600, KEY)):
            with self.subTest(mode=oct(mode)):
                key_file.chmod(mode)
                with mock.patch.dict(os.environ, {"HOME": str(home)}, clear=False):
                    os.environ.pop("OPENROUTER_API_KEY", None)
                    self.assertEqual(sim.api_key(), expected)

    def test_a_fingerprint_the_ledger_knows_is_not_asked_about(self) -> None:
        """Defect: the hint fires on a finding that is about to be BUMPED by the structural key —
        paying for an answer to a question `backlog-add` has already answered correctly."""
        with mock.patch.object(sim, "_post", side_effect=lambda *a, **k: self.calls.append(a)), \
             mock.patch.object(fnd, "fold", return_value=(records_of(self.f), [])), \
             mock.patch.dict(os.environ, {"ZUVO_BACKLOG_SIMILAR": "1", "OPENROUTER_API_KEY": KEY}):
            self.assertIsNone(sim.advise(self.tmp, self.f, decision(self.f), adm.fingerprint(self.f)))
        self.assertEqual(self.calls, [])


class CandidateCase(unittest.TestCase):
    """Which ledger findings become one paid call each."""

    def test_only_the_same_class_in_the_same_file_is_offered(self) -> None:
        """Defect: every finding in the ledger is offered, so the cost and the false-positive rate
        both scale with the ledger instead of with the population the anchor split lives in."""
        f = finding()
        same = finding(anchor=ANCHOR_B, line=4)
        other_class = finding(anchor=ANCHOR_B, line=4, cls="SEC")
        other_file = finding(anchor=ANCHOR_B, line=4, path="src/b.py")
        rows = sim.candidates(records_of(same, other_class, other_file), f, adm.fingerprint(f))
        self.assertEqual([fid for fid, _ in rows], [adm.fingerprint(same)])

    def test_a_finding_with_no_file_asks_nothing(self) -> None:
        """Defect: a target-only finding (no cited path) is compared against every entry in the
        ledger, because the same-file filter silently matched everything."""
        f = adm.Finding(cls="BUG", conf=85, source="review", title="t", target="pkg::sym",
                        anchor=ANCHOR_A, evidence="e")
        self.assertEqual(sim.candidates(records_of(finding()), f, adm.fingerprint(f)), [])

    def test_the_cap_keeps_the_newest(self) -> None:
        """Defect: the cap slices an unordered dict, so which candidates are asked about depends on
        insertion order and the most recent (most likely duplicate) can be the one dropped."""
        f = finding(title="the new one")
        olds = {}
        for i in range(sim.MAX_CANDIDATES + 3):
            other = finding(anchor=f"anchor {i}", title=f"old {i}")
            olds[adm.fingerprint(other)] = record(other, ts=f"2026-10-{i + 1:02d}T10:00:00+00:00")
        rows = sim.candidates(olds, f, adm.fingerprint(f))
        self.assertEqual(len(rows), sim.MAX_CANDIDATES)
        newest = sorted((r.fields["ts"] for r in olds.values()), reverse=True)[:sim.MAX_CANDIDATES]
        self.assertEqual([r.fields["ts"] for _, r in rows], newest)


class AnswerCase(unittest.TestCase):
    """What the module does with the endpoint's answer."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="similar-answer-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.f = finding()
        self.other = finding(anchor=ANCHOR_B, line=4)

    def advise(self, post: Any, **env: str) -> Optional[str]:
        full = {"ZUVO_BACKLOG_SIMILAR": "1", "OPENROUTER_API_KEY": KEY, **env}
        with mock.patch.object(sim, "_post", post), \
             mock.patch.object(fnd, "fold", return_value=(records_of(self.other), [])), \
             mock.patch.dict(os.environ, full):
            return sim.advise(self.tmp, self.f, decision(self.f), adm.fingerprint(self.f))

    @staticmethod
    def answering(payload: Any) -> Any:
        return lambda *a, **k: payload

    def test_a_probability_above_the_threshold_names_the_other_finding(self) -> None:
        """The feature itself: the caller is told WHICH finding may be the same defect, and how
        sure the model is. Defect: a bare 'possible duplicate' nobody can act on."""
        line = self.advise(self.answering({"probabilities": {"DUP": 0.87}}))
        self.assertEqual(line, f"SIMILAR {adm.fingerprint(self.other)} p=0.87 "
                               f"(advisory: nothing was changed by this)")

    def test_a_probability_below_the_threshold_says_nothing(self) -> None:
        """Defect: every pair in the same file is announced, so the hint is noise and gets ignored
        exactly when it is right."""
        self.assertIsNone(self.advise(self.answering({"probabilities": {"DUP": 0.2}})))

    def test_the_threshold_is_the_boundary_it_claims(self) -> None:
        """Defect: an off-by-one at the threshold — `>` where the measured operating point is `>=`
        — quietly moves the operating point away from the one the corpus was scored at."""
        at = sim.THRESHOLD
        self.assertIsNotNone(self.advise(self.answering({"probabilities": {"DUP": at}})))
        self.assertIsNone(self.advise(self.answering({"probabilities": {"DUP": at - 0.01}})))

    def test_probabilities_nested_under_the_question_are_still_read(self) -> None:
        """Defect: the response shape is pinned to the flat one measured on 2026-10-15, so the day
        the alpha endpoint nests per question the hint becomes a permanent silent no-op."""
        nested = {"questions": {sim.QUESTION: {"choice": "DUP", "probabilities": {"DUP": 0.91}}}}
        self.assertIsNotNone(self.advise(self.answering(nested)))

    def test_a_response_without_a_dup_probability_says_nothing(self) -> None:
        """Defect: a shape this does not understand is read as 0.0 (or raises) instead of being
        treated as 'no answer'."""
        for payload in ({"choice": "DUP"}, {"probabilities": {"OTHER": 0.9}}, [], "nope", None):
            with self.subTest(payload=payload):
                self.assertIsNone(self.advise(self.answering(payload)))

    def test_a_failing_call_is_silent(self) -> None:
        """Defect: a timeout, a 500 or a DNS failure reaches the caller as a traceback — an advisory
        taking down the one write path for the backlog."""
        for exc in (TimeoutError("slow"), OSError("down"), ValueError("not json")):
            with self.subTest(exc=type(exc).__name__):
                self.assertIsNone(self.advise(mock.Mock(side_effect=exc)))

    def test_the_question_never_carries_the_fingerprint(self) -> None:
        """Defect: the F-id is pasted into the prompt, so the model answers 'different' from the
        hash of the very fields it is being asked to compare, and the hint silently measures the
        structural key instead of second-guessing it."""
        seen: List[str] = []
        self.advise(lambda key, state, timeout: seen.append(state) or {"probabilities": {"DUP": 0.9}})
        self.assertTrue(seen)
        for state in seen:
            self.assertNotIn(adm.fingerprint(self.f), state)
            self.assertNotIn(adm.fingerprint(self.other), state)
            self.assertIn(ANCHOR_A, state)
            self.assertIn(ANCHOR_B, state)


class LauncherCase(unittest.TestCase):
    """The wiring, driven as a caller sees it: `backlog-add` as a subprocess against a stub endpoint."""

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="similar-launcher-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = self.tmp / "home"
        self.home.mkdir()
        self.repo = self.make_repo()

    def git(self, *args: str) -> None:
        subprocess.run(["git", "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false",
                        "-c", "init.defaultBranch=main", *args], cwd=self.repo_path,
                       env=scrubbed_env(), capture_output=True, text=True, check=True)

    def make_repo(self) -> Path:
        self.repo_path = self.tmp / "r"
        (self.repo_path / "src").mkdir(parents=True)
        (self.repo_path / "src" / "a.py").write_text(SOURCE, encoding="utf-8")
        (self.repo_path / "memory").mkdir()
        (self.repo_path / "memory" / "backlog.md").write_text("# Backlog\n\n", encoding="utf-8")
        self.git("init", "-q")
        self.git("add", "-A")
        self.git("commit", "-qm", "init")
        self.git("checkout", "-qb", "feat/x")
        return self.repo_path

    def add(self, *args: str, **env: str) -> "subprocess.CompletedProcess[str]":
        base = scrubbed_env()
        base.update(HOME=str(self.home), ZUVO_PR_LOOKUP="0", ZUVO_BACKLOG_NOW=NOW,
                    ZUVO_BACKLOG_HOST="t", **env)
        return subprocess.run([sys.executable, LAUNCHER, *args], cwd=self.repo, env=base,
                              capture_output=True, text=True, timeout=180)

    def file_one(self) -> None:
        """The first sighting, with the advisory off: the ledger now holds one BUG in src/a.py."""
        first = self.add("--class", "BUG", "--conf", "85", "--file", "src/a.py", "--line", "3",
                         "--anchor", ANCHOR_A, "--title", "off-by-one at the limit", "--source", "review")
        self.assertEqual(first.returncode, 0, first.stderr)

    def second_args(self) -> Tuple[str, ...]:
        """The SAME defect filed against a different anchor three lines down: a different F-id, the
        same class and the same file — the split this hint exists for."""
        return ("--class", "BUG", "--conf", "85", "--file", "src/a.py", "--line", "4",
                "--anchor", ANCHOR_B, "--title", "the limit check is off by one", "--source", "review")

    def test_the_model_is_asked_before_the_lock_is_taken(self) -> None:
        """Defect: the network call sits inside `zio.Lock`, so a slow or hanging endpoint holds the
        one write path for the backlog and every other writer on the machine waits on a third party.
        `backlog-add` appends to ZUVO_BACKLOG_READY_FILE immediately before it requests the lock, so
        that file not existing yet when the request arrives is proof the call is outside it."""
        self.file_one()
        ready = self.tmp / "ready"
        with StubDecisions(probability=0.9, on_request=lambda: ready.exists()) as stub:
            run = self.add(*self.second_args(), ZUVO_BACKLOG_SIMILAR="1", OPENROUTER_API_KEY=KEY,
                           ZUVO_BACKLOG_SIMILAR_URL=stub.url, ZUVO_BACKLOG_READY_FILE=str(ready))
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(stub.bodies, f"the endpoint was never called: {run.stderr}")
        self.assertEqual(stub.notes, [False] * len(stub.bodies),
                         "the lock was already being requested when the model was asked")
        self.assertTrue(ready.exists(), "the run never reached the lock, so the proof is vacuous")

    def test_the_hint_reaches_stderr_without_changing_the_verdict(self) -> None:
        """Defect: the advisory writes, bumps or renames something — or prints onto stdout, where it
        would be parsed as a second verdict line by every caller that reads one."""
        self.file_one()
        before = (self.repo / "memory" / "backlog.md").read_text(encoding="utf-8")
        with StubDecisions(probability=0.93) as stub:
            run = self.add(*self.second_args(), ZUVO_BACKLOG_SIMILAR="1", OPENROUTER_API_KEY=KEY,
                           ZUVO_BACKLOG_SIMILAR_URL=stub.url)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(len(run.stdout.splitlines()), 1, run.stdout)
        self.assertTrue(run.stdout.startswith("ACCEPTED "), run.stdout)
        self.assertIn("SIMILAR F-", run.stderr)
        self.assertIn("p=0.93", run.stderr)
        after = (self.repo / "memory" / "backlog.md").read_text(encoding="utf-8")
        self.assertEqual(after.count("\n- [ ] "), before.count("\n- [ ] ") + 1,
                         "the advisory changed what was written")

    def test_an_endpoint_that_fails_changes_nothing_a_caller_sees(self) -> None:
        """Defect: a 500 from the endpoint fails the add — the advisory becomes a dependency of the
        write path it was explicitly designed not to be part of."""
        self.file_one()
        with StubDecisions(status=500) as stub:
            run = self.add(*self.second_args(), ZUVO_BACKLOG_SIMILAR="1", OPENROUTER_API_KEY=KEY,
                           ZUVO_BACKLOG_SIMILAR_URL=stub.url)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(run.stdout.startswith("ACCEPTED "), run.stdout)
        self.assertNotIn("SIMILAR", run.stderr)
        self.assertNotIn("Traceback", run.stderr)

    def test_the_default_run_reaches_no_endpoint(self) -> None:
        """Defect: the flag is read somewhere else (or defaulted on), so an ordinary `backlog-add`
        on a machine that happens to hold a key starts calling a paid API."""
        self.file_one()
        with StubDecisions() as stub:
            run = self.add(*self.second_args(), OPENROUTER_API_KEY=KEY,
                           ZUVO_BACKLOG_SIMILAR_URL=stub.url)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(stub.bodies, [])
        self.assertNotIn("SIMILAR", run.stderr)


if __name__ == "__main__":
    unittest.main()
