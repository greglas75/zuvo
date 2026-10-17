"""scripts/zuvo-home/zuvo_backlog_similar — the ADVISORY duplicate hint of `backlog-add` (stage 1 of
B-20261015-DEDUP-ANCHOR-CHOICE-SPLITS).

The module decides nothing and writes nothing, so what these specs protect is the opposite of a
feature: that it stays off unless asked, that it never reaches the network when it has nothing to
ask, that it cannot fail the one locked write path, and that its call is made OUTSIDE the lock. Every
test names the defect it catches. No test reaches a real network: the unit specs replace the one
transport seam, and the two launcher specs run a stub HTTP server on loopback.
"""

import contextlib
import http.client
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import threading
import time
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
DUP_KEY = "DUP"
KEY = "sk-or-fixture"
ANCHOR_A = "if total > limit:"
ANCHOR_B = "return total - limit"
SOURCE = "a = 1\nb = 2\nif total > limit:\n    return total - limit\n"
HERMETIC_GIT = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1", "XDG_CONFIG_HOME": os.devnull}
SCRUB = ("ZUVO_BACKLOG_PR", "ZUVO_BACKLOG_ADMIT", "ZUVO_LOCK_WAIT", "ZUVO_BACKLOG_READY_FILE",
         "ZUVO_BACKLOG_SIMILAR", "ZUVO_BACKLOG_SIMILAR_URL", "ZUVO_BACKLOG_SIMILAR_MODEL",
         "ZUVO_BACKLOG_SIMILAR_THRESHOLD", "ZUVO_BACKLOG_SIMILAR_TIMEOUT",
         "ZUVO_BACKLOG_SIMILAR_BUDGET", "ZUVO_BACKLOG_SIMILAR_DEBUG", "OPENROUTER_API_KEY",
         "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_COMMON_DIR", "GIT_OBJECT_DIRECTORY",
         "GIT_PREFIX", "GIT_CEILING_DIRECTORIES")
PROXY_VARS = frozenset({"HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "NO_PROXY"})


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
    """The launcher's environment, minus everything that would change what these specs see. The
    proxy variables are part of that: `urllib` honours them for 127.0.0.1 too, so on a host with a
    proxy configured the stub would never be reached and the specs that assert it WAS reached would
    fail for a reason that has nothing to do with the code."""
    env = {k: v for k, v in os.environ.items()
           if k not in SCRUB and k.upper() not in PROXY_VARS}
    env.update(HERMETIC_GIT)
    env["NO_PROXY"] = env["no_proxy"] = "127.0.0.1,localhost"
    return env


class StubDecisions:
    """A loopback Decisions endpoint. Records every request body, answers with `probability` (or the
    HTTP status in `status`), and runs `on_request` before answering so a spec can observe what the
    caller had already done to the filesystem at the moment the call was made."""

    def __init__(self, probability: float = 0.9, status: int = 200, on_request: Any = None,
                 pad: int = 0) -> None:
        self.bodies: List[Dict[str, Any]] = []
        self.notes: List[Any] = []
        self.lock = threading.Lock()
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler's name
                raw = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                note = on_request() if on_request is not None else None
                with outer.lock:                 # ThreadingHTTPServer: one thread per request
                    outer.bodies.append(json.loads(raw or b"{}"))
                    if on_request is not None:
                        outer.notes.append(note)
                if status != 200:
                    self.send_error(status)
                    return
                answer: Dict[str, Any] = {"choice": "DUP", "confidence": 0.5,
                                          "probabilities": {"DUP": probability,
                                                            "DIFFERENT": 1.0 - probability}}
                if pad:
                    answer["pad"] = "x" * pad
                payload = json.dumps(answer).encode()
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
        self.empty_home = self.tmp / "empty-home"
        self.empty_home.mkdir()

    def advise(self, **env: str) -> Optional[str]:
        """`advise` over a ledger holding ONE same-file same-class finding with another anchor, with
        the transport replaced so any attempt to reach it is recorded rather than made."""
        other = finding(anchor=ANCHOR_B, line=4)
        with mock.patch.object(sim, "_post", side_effect=lambda *a, **k: self.calls.append(a)), \
             mock.patch.object(fnd, "fold", return_value=(records_of(other), [])), \
             mock.patch.dict(os.environ, {"HOME": str(self.empty_home), **env}, clear=False):
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
        ACCEPT — stderr nagging on the one write path trains callers to stop reading it. HOME is a
        fresh empty directory here: `api_key` also reads ~/.zuvo/openrouter.key, so without that
        isolation this spec passes on CI and fails on exactly the machines that have a key."""
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertIsNone(self.advise(ZUVO_BACKLOG_SIMILAR="1"))
        self.assertEqual(self.calls, [])
        self.assertEqual(err.getvalue(), "", "the no-key path said something on stderr")

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
        (self.tmp / "home").mkdir()

    def advise(self, post: Any, **env: str) -> Optional[str]:
        """`HOME` is isolated and every SCRUB variable the caller did not set is removed: these
        specs read the module's defaults, not whatever the developer's shell happens to export."""
        full = {"HOME": str(self.tmp / "home"), "ZUVO_BACKLOG_SIMILAR": "1",
                "OPENROUTER_API_KEY": KEY, **env}
        with mock.patch.object(sim, "_post", post), \
             mock.patch.object(fnd, "fold", return_value=(records_of(self.other), [])), \
             mock.patch.dict(os.environ, full):
            for name in SCRUB:
                if name not in full:
                    os.environ.pop(name, None)
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

    def test_a_probability_that_is_not_one_is_refused(self) -> None:
        """Defect: NaN fails every comparison, so an unchecked NaN slides past `p < THRESHOLD` and
        the caller is told `SIMILAR F-… p=nan`; a bool or an out-of-range number is not a
        probability either, and `{"DUP": true}` reading as 1.0 would flag every pair."""
        for value in (float("nan"), float("inf"), -0.5, 1.5, True, "0.9", None):
            with self.subTest(value=value):
                self.assertIsNone(self.advise(self.answering({"probabilities": {DUP_KEY: value}})))

    def test_the_api_key_only_goes_to_an_endpoint_worth_trusting(self) -> None:
        """Defect: `ZUVO_BACKLOG_SIMILAR_URL` is an ordinary environment variable and whatever it
        names receives the OpenRouter bearer key. Plain http to a real host puts it on the wire, and
        a `file:` URL is not an endpoint at all. https anywhere and http to loopback are allowed;
        everything else is refused before the request is built."""
        # "" is not a refusal: an unset or empty override means "no override", and the default
        # endpoint is the https one.
        allowed = ("https://openrouter.ai/api/alpha/decisions", "http://127.0.0.1:8080/x",
                   "http://localhost:8080/x", "")
        refused = ("http://example.com/x", "file:///etc/passwd", "ftp://example.com/x",
                   "example.com/x", "http://10.0.0.5/x")
        for url in allowed:
            with self.subTest(url=url), mock.patch.dict(os.environ, {"ZUVO_BACKLOG_SIMILAR_URL": url}):
                self.assertIsNotNone(sim._checked_url())
        for url in refused:
            with self.subTest(url=url), mock.patch.dict(os.environ, {"ZUVO_BACKLOG_SIMILAR_URL": url}):
                self.assertIsNone(sim._checked_url(), f"{url!r} would have received the key")

    def test_the_whole_advisory_stops_at_one_deadline(self) -> None:
        """Defect: the per-call timeout multiplies by the candidate count, so five candidates and a
        degraded endpoint stall the caller for 5 x 8 s before the verdict appears. The lock is not
        held, which was the point — but the human waiting for the verdict is."""
        rows = {}
        for i in range(sim.MAX_CANDIDATES):
            other = finding(anchor=f"anchor {i}")
            rows[adm.fingerprint(other)] = record(other, ts=f"2026-10-{i + 1:02d}T10:00:00+00:00")
        seen: List[float] = []

        def slow(key: str, url: str, state: str, timeout: float) -> Any:
            seen.append(timeout)
            time.sleep(0.5)                      # 5 candidates x 0.5 s cannot fit a 1 s budget
            raise TimeoutError("slow")

        with mock.patch.object(sim, "_post", slow), \
             mock.patch.object(fnd, "fold", return_value=(rows, [])), \
             mock.patch.dict(os.environ, {"ZUVO_BACKLOG_SIMILAR": "1", "OPENROUTER_API_KEY": KEY,
                                          "ZUVO_BACKLOG_SIMILAR_BUDGET": "1",
                                          "ZUVO_BACKLOG_SIMILAR_TIMEOUT": "8"}):
            started = time.monotonic()
            self.assertIsNone(sim.advise(self.tmp, self.f, decision(self.f), adm.fingerprint(self.f)))
            elapsed = time.monotonic() - started
        # Without the budget this is 5 x 0.5 s; with it, calls stop once 1 s is spent. The bound is
        # generous enough for a loaded runner and still far below the unbudgeted cost.
        self.assertLess(elapsed, 2.0, f"the budget did not stop the calls ({elapsed:.1f}s)")
        self.assertLess(len(seen), len(rows), "every candidate was asked despite the budget")
        self.assertTrue(all(t <= 8.0 for t in seen), f"a socket timeout exceeded the per-call cap: {seen}")
        self.assertTrue(all(t > 0 for t in seen), f"a call started with no time left: {seen}")

    def test_a_dropped_or_truncated_response_is_silent(self) -> None:
        """Defect: `http.client` failures are neither OSError nor ValueError, so a truncated body
        (IncompleteRead) or a dropped connection (RemoteDisconnected) raises straight through the
        advisory and out of the one locked write path."""
        for exc in (http.client.IncompleteRead(b""), http.client.BadStatusLine(""),
                    http.client.RemoteDisconnected("closed"), UnicodeDecodeError("utf-8", b"", 0, 1, "bad")):
            with self.subTest(exc=type(exc).__name__):
                self.assertIsNone(self.advise(mock.Mock(side_effect=exc)))

    def test_the_candidate_is_described_by_the_file_it_matched_on(self) -> None:
        """Defect: a record citing several files is SELECTED on the file that matches and then
        DESCRIBED by its first one, so the model is shown a different place than the one that made
        the pair a candidate."""
        rec = record(finding(anchor=ANCHOR_B))
        rec.fields["files"] = [{"path": "src/other.py", "line": 9, "note": ""},
                               {"path": "src/a.py", "line": 4, "note": ""}]
        text = sim._candidate_text(rec, "src/a.py")
        self.assertIn("src/a.py:4", text)
        self.assertNotIn("src/other.py", text)

    def test_the_question_never_carries_the_fingerprint(self) -> None:
        """Defect: the F-id is pasted into the prompt, so the model answers 'different' from the
        hash of the very fields it is being asked to compare, and the hint silently measures the
        structural key instead of second-guessing it."""
        seen: List[str] = []
        self.advise(lambda key, url, state, timeout: seen.append(state) or {"probabilities": {"DUP": 0.9}})
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
        that file not existing yet when the request arrives is proof the call is outside it. The
        observation is made in the handler thread, which is not a race: the caller is blocked inside
        `urlopen` until the handler answers, so it cannot have reached the ready file meanwhile."""
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
        added = after[len(before):]
        self.assertTrue(after.startswith(before), "the advisory rewrote what was already there")
        self.assertEqual(added.count("\n"), 1, f"one appended entry expected, got {added!r}")
        self.assertIn("[BUG]", added)

    def test_an_endpoint_that_fails_changes_nothing_a_caller_sees(self) -> None:
        """Defect: a 500 from the endpoint fails the add — the advisory becomes a dependency of the
        write path it was explicitly designed not to be part of."""
        self.file_one()
        with StubDecisions(status=500) as stub:
            run = self.add(*self.second_args(), ZUVO_BACKLOG_SIMILAR="1", OPENROUTER_API_KEY=KEY,
                           ZUVO_BACKLOG_SIMILAR_URL=stub.url)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertTrue(stub.bodies, "the endpoint was never called, so the 500 path is untested")
        self.assertTrue(run.stdout.startswith("ACCEPTED "), run.stdout)
        self.assertNotIn("SIMILAR", run.stderr)
        self.assertNotIn("Traceback", run.stderr)

    def test_a_dry_run_sends_nothing_to_the_endpoint(self) -> None:
        """Defect: `--dry-run` means "writes nothing", and a caller reads that as "changes nothing
        anywhere". Shipping the finding's title, evidence and anchor to a third party on a dry run
        breaks that reading in the one direction nobody checks."""
        self.file_one()
        with StubDecisions() as stub:
            run = self.add(*self.second_args(), "--dry-run", ZUVO_BACKLOG_SIMILAR="1",
                           OPENROUTER_API_KEY=KEY, ZUVO_BACKLOG_SIMILAR_URL=stub.url)
        self.assertEqual(run.returncode, 0, run.stderr)
        self.assertEqual(stub.bodies, [], "a dry run reached the network")
        self.assertNotIn("SIMILAR", run.stderr)

    def test_an_oversized_response_is_refused_rather_than_truncated(self) -> None:
        """Defect: `read(CAP)` hands a TRUNCATED body to the parser, so an endpoint streaming more
        than the cap yields a parse error indistinguishable from an honest 'no answer' — and the
        body is read through the real transport here, because patching `_post` would bypass the
        very cap this checks. A body just under the cap must still be answered, or the spec would
        also pass with the request broken outright."""
        for pad, expected in ((sim.MAX_RESPONSE_BYTES + 1024, False), (16, True)):
            with self.subTest(pad=pad), StubDecisions(probability=0.9, pad=pad) as stub:
                with mock.patch.dict(os.environ, {"ZUVO_BACKLOG_SIMILAR_URL": stub.url}):
                    answer = sim.ask(KEY, "EXISTING", "NEW")
                self.assertTrue(stub.bodies, "the stub was never reached")
                self.assertEqual(answer is not None, expected, f"pad={pad} answer={answer}")

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
