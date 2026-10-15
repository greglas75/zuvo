"""scripts/zuvo-home/zuvo_backlog_groom_semantic.py — groom's semantic pass, scored against
tests/lib/rerank_stub.py only. The pass REPORTS reworded duplicates; it never decides one. A pair it
finds must not become a verdict, a queue verdict, a ledger row or a reused answer in a later run, and
every way it cannot run (kill switch, dry run, no client, no key, a failing API, a bug) leaves the plan
as it was. Each test names the defect it catches. Fixtures are synthetic.
"""

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
GROOM = os.path.join(HOME_DIR, "backlog-groom.py")
sys.path.insert(0, HOME_DIR)
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
import zuvo_backlog_dedup as zd  # noqa: E402
import zuvo_backlog_groom_semantic as zsem  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402
import zuvo_bm25 as bm25  # noqa: E402
import zuvo_rerank as rr  # noqa: E402
from rerank_stub import RerankStub  # noqa: E402

TEST_KEY = "test-key-not-a-real-credential"
# No two groups share a word once the id is stripped, so BM25 sends each query only its own twin and the
# stub's per-document scores cannot pair unrelated entries.
CACHE = "- [ ] B-20261015-CACHE-RACE cache invalidation races with reload worker\n"
RELOAD = "- [ ] B-20261015-RELOAD-RACE reload worker and cache invalidation race each other\n"
ROT_A = "- [ ] B-3 src/log.py rotation drops lines past five megabytes\n"
ROT_B = "- [ ] B-4 src/log.py rotation drops lines past five megabytes\n"
BADGE = "- [ ] B-20261015-BADGE colour of status badge is wrong\n"
BACKLOG = "# Backlog\n\n## Open\n\n" + CACHE + RELOAD + ROT_A + ROT_B + BADGE
CACHE_LINE, RELOAD_LINE = 5, 6
# Decided by classify as STALE-OBSOLETE (src/gone.py does not exist), with no exact-key twin.
GONE = "- [ ] B-20261015-GONE src/gone.py reload worker stalls\n"
GONE_LINE, GONE_KEY = 10, "id:b-20261015-gone"
SCORES = {"reload worker": 0.9, "rotation drops": 0.9}
# Two table rows Task 4 ungrouped: one metadata-only `fp:` key, different problems.
TABLE = ("## Open\n| ID | Problem | File | Severity | Source | Date |\n|---|---|---|---|---|---|\n"
         "| B-1 | race in cache invalidation | src/a.py:10 | WARNING | review | 2026-10-01 |\n"
         "| B-2 | leaking file handle on error | src/a.py:90 | WARNING | review | 2026-10-01 |\n")
# Inherited, each would change what these specs send, where, what the plan writes, or which modules load.
SCRUB = ("OPENROUTER_API_KEY", "ZUVO_OR_KEY_FILE", "ZUVO_OPENROUTER_BASE_URL", "ZUVO_OUTPUT_DIR",
         "ZUVO_DIR", "NO_PROXY", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
         "ALL_PROXY", "all_proxy", "GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "PYTHONPATH", "PYTHONHOME",
         "PYTHONSTARTUP")
SCRUB_PREFIXES = ("ZUVO_RERANK", "ZUVO_BACKLOG_DUP", "ZUVO_GROOM")


def clean_env(home: str, **extra: str) -> Dict[str, str]:
    """A scrubbed env; ZUVO_HOME follows the effective HOME (an `extra` HOME included)."""
    env = {k: v for k, v in os.environ.items() if k not in SCRUB and not k.startswith(SCRUB_PREFIXES)}
    home = extra.get("HOME", home)
    env.update(HOME=home, ZUVO_HOME=os.path.join(home, ".zuvo"), NO_PROXY="127.0.0.1", no_proxy="127.0.0.1",
               GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1")
    env.update(extra)
    return env


def verdict(e: zb.Entry) -> zv.Verdict:
    return zv.Verdict(e, zv.zl.VERDICT_DUPLICATE_OF, "backlog.md:1 duplicates", zv.CLASS_DUPLICATE)


def semantic_lines(out: str) -> List[str]:
    return [ln for ln in out.splitlines() if ln.startswith("SEMANTIC_")]


def pair_lines(out: str) -> List[List[str]]:
    return [ln.split("=", 1)[1].split() for ln in out.splitlines() if ln.startswith("SEMANTIC_DUPLICATE=")]


def summary(out: str) -> str:
    return next((ln.split("=", 1)[1] for ln in out.splitlines() if ln.startswith("SEMANTIC_DUPLICATES=")), "")


def variants(n: int) -> str:
    """`n` open entries that all share words, so every one of them is sent."""
    return "## Open\n" + "".join(f"- [ ] B-x-{i} reload worker variant {i}\n" for i in range(n))


def isolated(n: int) -> str:
    """`n` open entries sharing no word with anything, so none of them is sent."""
    return "".join(f"- [ ] B-iso-{i} zq{i}alpha zq{i}beta\n" for i in range(n))


class FailAfterFirst(RerankStub):
    """Answers the first request, then HTTP 500 for every later one."""

    def __init__(self, *a: Any, **kw: Any) -> None:
        super().__init__(*a, **kw)
        self.served = 0

    def _answer(self, req: Dict[str, Any]) -> Tuple[int, bytes]:
        with self._lock:
            self.served += 1
            first = self.served == 1
        return super()._answer(req) if first else (500, b"oops")


class SemanticCase(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="groom-sem-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.home = str(self.tmp / "home")
        key = Path(self.home, ".zuvo", "openrouter.key")
        key.parent.mkdir(parents=True)
        key.write_text(TEST_KEY + "\n", encoding="utf-8")
        key.chmod(0o600)
        self.nokey = str(self.tmp / "nokey")         # a fresh home with no key file
        os.mkdir(self.nokey)

    def stub(self, scores: Optional[Dict[str, float]] = None, **kw: Any) -> RerankStub:
        s = RerankStub(SCORES if scores is None else scores, **kw).start()
        self.addCleanup(s.stop)
        return s


class PairTests(SemanticCase):
    """`semantic_pairs` and `report` in this process, against the stub."""

    def setUp(self) -> None:
        super().setUp()
        patcher = mock.patch.dict(os.environ, clean_env(self.home), clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        rr.reset_budget()
        self.addCleanup(rr.reset_budget)

    def found(self, text: str, stub: RerankStub, max_calls: int = 300, workers: int = zsem.WORKERS
              ) -> "zsem.Found":
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        return zsem.semantic_pairs(list(zb.iter_entries(text)), max_calls=max_calls, workers=workers)

    def pairs(self, text: str, stub: RerankStub) -> List[Tuple[str, str, float]]:
        return [(p.entry.ident or p.entry.key, p.other.ident or p.other.key, p.score)
                for p in self.found(text, stub).pairs]

    def report(self, text: str, verdict_lines: Tuple[int, ...] = (), dry_run: bool = False) -> str:
        entries = list(zb.iter_entries(text))
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            zsem.report(entries, [verdict(e) for e in entries if e.lineno in verdict_lines], dry_run)
        return out.getvalue()

    def test_a_pair_found_from_both_sides_is_reported_once_against_the_later_entry(self) -> None:
        # Defect: each entry of a pair reports the other, so one reworded duplicate reads as two.
        self.assertEqual(self.pairs(BACKLOG, self.stub()),
                         [("B-20261015-RELOAD-RACE", "B-20261015-CACHE-RACE", 0.9)])

    def test_entries_sharing_an_exact_key_and_signature_are_not_reported_again(self) -> None:
        # Defect: a pair the exact keys already found (here both undecided, as when classify refused the
        # verdict's evidence) is reported a second time as a "semantic" duplicate.
        self.assertEqual(self.pairs("## Open\n" + ROT_A + ROT_B, self.stub()), [])

    def test_table_rows_sharing_only_a_metadata_key_are_still_reported(self) -> None:
        # Defect: the exact-key suppression hides a real reworded pair between two table rows whose
        # shared `fp:` key is metadata only — the very rows classify no longer groups.
        rows = list(zb.iter_entries(TABLE))
        self.assertEqual(rows[0].key, rows[1].key)
        got = self.found(TABLE, self.stub({"race in cache": 0.9})).pairs
        self.assertEqual([(p.entry.lineno, p.other.lineno, p.score) for p in got], [(5, 4, 0.9)])

    def test_a_score_under_the_strong_band_is_not_reported(self) -> None:
        # Defect: groom reports weak neighbours, flooding the report with unrelated entries.
        self.assertEqual(self.pairs(BACKLOG, self.stub({"reload worker": 0.6})), [])

    def test_max_calls_bounds_requests_and_each_request_holds_at_most_pool_documents(self) -> None:
        # Defect: semantic_pairs sends one request per entry past `max_calls`, or a whole backlog per request.
        stub = self.stub()
        self.found(variants(20), stub, max_calls=2)
        self.assertEqual(stub.requests, 2)
        self.assertTrue(all(isinstance(b["query"], str) and 0 < len(b["documents"]) <= zd.POOL
                            for b in stub.bodies), [len(b["documents"]) for b in stub.bodies])

    def test_the_env_cap_bounds_requests_and_the_count_reads_partial(self) -> None:
        # Defect: ZUVO_GROOM_RERANK_MAX is ignored, or a capped run reads as a complete check.
        stub = self.stub()
        os.environ.update(ZUVO_RERANK_BASE_URL=stub.base_url, ZUVO_GROOM_RERANK_MAX="3")
        out = self.report(variants(6))
        self.assertEqual(stub.requests, 3)
        lines = semantic_lines(out)
        self.assertEqual(lines[-2:], ["SEMANTIC_CHECKED=3/6",
                                      f"SEMANTIC_DUPLICATES={len(lines) - 2}+partial"])

    def test_an_isolated_entry_is_checked_and_does_not_make_the_count_partial(self) -> None:
        # Defect: an entry sharing no word with any other (no possible duplicate, so nothing to send)
        # marks a run whose every request succeeded as +partial, so the marker means nothing.
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        self.assertEqual(semantic_lines(self.report("## Open\n" + CACHE + RELOAD + BADGE))[-2:],
                         ["SEMANTIC_CHECKED=3/3", "SEMANTIC_DUPLICATES=1"])
        self.assertEqual(stub.requests, 2)

    def test_a_non_number_cap_falls_back_to_the_default_not_to_zero(self) -> None:
        # Defect: a typo in ZUVO_GROOM_RERANK_MAX raises out of the plan or silently disables the pass;
        # "--5" and "²" pass a str.isdigit() guard that int() then rejects.
        for raw in ("lots", "--5", "²"):
            with self.subTest(raw=raw):
                stub = self.stub()
                os.environ.update(ZUVO_RERANK_BASE_URL=stub.base_url, ZUVO_GROOM_RERANK_MAX=raw)
                self.assertEqual(semantic_lines(self.report("## Open\n" + CACHE + RELOAD))[-2:],
                                 ["SEMANTIC_CHECKED=2/2", "SEMANTIC_DUPLICATES=1"])

    def test_an_empty_backlog_is_a_complete_check_of_nothing(self) -> None:
        # Defect: no open entry divides by zero building the index, or reads as a skip.
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        self.assertEqual(semantic_lines(self.report("## Open\n")),
                         ["SEMANTIC_CHECKED=0/0", "SEMANTIC_DUPLICATES=0"])
        self.assertEqual(stub.requests, 0)

    def test_a_ticked_entry_is_neither_counted_nor_sent(self) -> None:
        # Defect: a closed entry is re-reported as a duplicate of an open one, and costs a request.
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        out = self.report("## Open\n" + CACHE + RELOAD.replace("- [ ]", "- [x]", 1))
        self.assertEqual(semantic_lines(out), ["SEMANTIC_CHECKED=1/1", "SEMANTIC_DUPLICATES=0"])
        self.assertEqual(stub.requests, 0)

    def test_semantic_pairs_raises_the_skip_it_reports(self) -> None:
        # Defect: semantic_pairs returns an empty Found when it could not run, which reads as "0 duplicates".
        os.environ["ZUVO_RERANK"] = "0"
        with self.assertRaises(zsem.Skipped) as ctx:
            zsem.semantic_pairs(list(zb.iter_entries(BACKLOG)), max_calls=300)
        self.assertEqual(str(ctx.exception), "disabled")

    def test_a_full_check_reads_a_plain_count(self) -> None:
        # Defect: "+partial" printed on a run that answered every entry, so the marker means nothing.
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        self.assertEqual(semantic_lines(self.report("## Open\n" + CACHE + RELOAD))[-2:],
                         ["SEMANTIC_CHECKED=2/2", "SEMANTIC_DUPLICATES=1"])

    def test_an_entry_with_a_deterministic_verdict_is_neither_asked_nor_sent(self) -> None:
        # Defect: an entry classify already decided is re-reported, and still costs a request.
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        out = self.report(BACKLOG, verdict_lines=(RELOAD_LINE,))
        self.assertEqual(pair_lines(out), [], out)
        sent = [d for b in stub.bodies for d in [b["query"], *b["documents"]]]
        self.assertFalse(any("race each other" in d for d in sent))

    SKIPS: List[Tuple[str, Dict[str, str], bool, str]] = [
        ("the kill switch still sends a request", {"ZUVO_RERANK": "0"}, False, "disabled"),
        ("a dry run hides the kill switch", {"ZUVO_RERANK": "0"}, True, "disabled"),
        ("a cap of 0 reads as zero duplicates", {"ZUVO_GROOM_RERANK_MAX": "0"}, False, "disabled"),
        ("a negative cap sends requests or reads as zero duplicates", {"ZUVO_GROOM_RERANK_MAX": "-5"}, False,
         "disabled"),
        ("a dry run sends entry text", {}, True, "dry-run"),
        ("no key still sends a request, or reads as zero duplicates", {}, False, "no-key"),
    ]

    def test_skips(self) -> None:
        for name, env, dry, outcome in self.SKIPS:
            stub = self.stub()
            home = self.nokey if outcome == "no-key" else self.home
            scoped = {"ZUVO_RERANK_BASE_URL": stub.base_url, "HOME": home,
                      "ZUVO_HOME": os.path.join(home, ".zuvo"), **env}
            with self.subTest(name), mock.patch.dict(os.environ, scoped):
                self.assertEqual(semantic_lines(self.report(BACKLOG, dry_run=dry)),
                                 [f"SEMANTIC_DUPLICATES=skipped:{outcome}"])
                self.assertEqual(stub.requests, 0)

    def test_without_the_client_modules_the_pass_says_so(self) -> None:
        # Defect: a copy without zuvo_rerank.py crashes the plan, or reports "0 duplicates".
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        with mock.patch.dict(sys.modules, {"zuvo_rerank": None}):
            out = self.report(BACKLOG)
        self.assertEqual(semantic_lines(out), ["SEMANTIC_DUPLICATES=skipped:no-client"])
        self.assertEqual(stub.requests, 0)

    def test_a_half_copied_client_is_a_no_client_skip(self) -> None:
        # Defect: a truncated zuvo_rerank.py raises SyntaxError, not ImportError, and escapes the client
        # guard as "skipped:error" (or kills the plan) instead of naming the missing client.
        broken = tempfile.mkdtemp(prefix="groom-broken-")
        self.addCleanup(shutil.rmtree, broken, True)
        Path(broken, "zuvo_rerank.py").write_text("def rerank(:\n", encoding="utf-8")
        stub = self.stub()
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        err = io.StringIO()
        with mock.patch.dict(sys.modules), mock.patch.object(sys, "path", [broken, *sys.path]), \
                contextlib.redirect_stderr(err):
            sys.modules.pop("zuvo_rerank", None)
            out = self.report(BACKLOG)
        self.assertEqual(semantic_lines(out), ["SEMANTIC_DUPLICATES=skipped:no-client"])
        self.assertEqual(err.getvalue(), "backlog-groom: semantic pass has no client: SyntaxError\n")
        self.assertEqual(stub.requests, 0)

    def test_a_failing_api_is_a_skip_and_stops_after_breaker_requests(self) -> None:
        # Defect: every request fails and the report says "no duplicates"; or a dead API still costs one
        # timed-out request per entry, or every worker already in flight, instead of tripping the breaker.
        stub = self.stub(status=500, body=b"oops")
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        self.assertEqual(semantic_lines(self.report(variants(30))), ["SEMANTIC_DUPLICATES=skipped:failed"])
        self.assertLessEqual(stub.requests, zsem.BREAKER)

    def test_failures_after_a_success_still_trip_the_breaker(self) -> None:
        # Defect: one early success disarms the breaker, so an API that dies mid-run is asked once per entry.
        stub = FailAfterFirst(SCORES).start()
        self.addCleanup(stub.stop)
        found = self.found(variants(30), stub, workers=1)
        self.assertEqual((found.checked, stub.requests), (1, 1 + zsem.BREAKER))

    def test_answered_entries_are_a_count_even_when_every_request_failed(self) -> None:
        # Defect: an isolated entry was checked, yet the run reads skipped:failed as if nothing was.
        stub = self.stub(status=500, body=b"oops")
        os.environ["ZUVO_RERANK_BASE_URL"] = stub.base_url
        self.assertEqual(semantic_lines(self.report(variants(3) + isolated(1)))[-2:],
                         ["SEMANTIC_CHECKED=1/4", "SEMANTIC_DUPLICATES=0+partial"])

    def test_the_cap_counts_requests_and_isolated_entries_are_checked_for_free(self) -> None:
        # Defect: the cap counts entries, so isolated entries early in the file use up the request budget.
        stub = self.stub()
        found = self.found("## Open\n" + isolated(5) + variants(10).split("\n", 1)[1], stub, max_calls=3)
        self.assertEqual((stub.requests, found.checked, found.eligible), (3, 8, 15))

    def test_a_bad_answer_fails_that_entry_and_the_pass_goes_on(self) -> None:
        # Each case: the first request's answer is unusable; that entry is failed, the other three answered.
        cases = [
            ("a wrong-length score list raises or pairs the wrong entries", lambda *a, **k: [0.9]),
            ("an exception from the client aborts the whole pass", mock.Mock(side_effect=RuntimeError("x"))),
            ("a None answer (today's behaviour) is read as scores", lambda *a, **k: None),
        ]
        for name, bad in cases:
            stub = self.stub()
            real, calls = rr.rerank, []

            def once(*a: Any, bad: Any = bad, real: Any = real, calls: List[int] = calls, **k: Any) -> Any:
                calls.append(1)
                return bad(*a, **k) if len(calls) == 1 else real(*a, **k)

            with self.subTest(name), mock.patch.object(rr, "rerank", once):
                found = self.found(variants(4), stub, workers=1)
                self.assertEqual((found.checked, found.eligible), (3, 4))
                self.assertEqual(stub.requests, 3)

    def test_pairs_come_only_from_answered_requests_after_a_partial_failure(self) -> None:
        # Defect: a failed request's entry is counted as checked, or pairs are invented for it.
        stub = FailAfterFirst(SCORES).start()
        self.addCleanup(stub.stop)
        found = self.found(variants(6), stub, workers=1)
        self.assertEqual((found.checked, found.eligible), (1, 6))
        self.assertEqual(sorted((p.entry.lineno, p.other.lineno) for p in found.pairs),
                         [(n, 2) for n in range(3, 8)])

    def test_the_corpus_is_tokenised_once_not_once_per_request(self) -> None:
        # Defect: every request re-tokenises the whole backlog, O(N^2) tokenising on a 800-entry file.
        stub = self.stub()
        with mock.patch.object(bm25, "tokens", wraps=bm25.tokens) as tok:
            self.found(variants(12), stub)
        self.assertEqual(tok.call_count, 12)

    def test_any_exception_is_a_skip_naming_only_its_type(self) -> None:
        # Defect: a bug in the pass aborts the plan, or leaves no trace of what went wrong.
        err = io.StringIO()
        with mock.patch.object(zsem, "semantic_pairs", side_effect=RuntimeError("entry text")), \
                contextlib.redirect_stderr(err):
            self.assertEqual(semantic_lines(self.report(BACKLOG)), ["SEMANTIC_DUPLICATES=skipped:error"])
        self.assertIn("RuntimeError", err.getvalue())
        self.assertNotIn("entry text", err.getvalue())


class PlanTests(SemanticCase):
    """`backlog-groom.py plan` as a subprocess on temp repos, always pointed at a stub."""

    def setUp(self) -> None:
        super().setUp()
        self.repo = self.make_repo("repo")

    def make_repo(self, name: str) -> Path:
        repo = self.tmp / name
        (repo / "memory").mkdir(parents=True)
        (repo / "src").mkdir()
        (repo / "src" / "log.py").write_text("x = 1\n", encoding="utf-8")
        (repo / "memory" / "backlog.md").write_text(BACKLOG, encoding="utf-8")
        subprocess.run(["git", "init", "-q", str(repo)], env=clean_env(self.home), check=True)
        return repo

    def plan(self, *args: str, stub: Optional[RerankStub] = None, groom: str = GROOM,
             repo: Optional[Path] = None, **extra: str) -> str:
        env = clean_env(self.home, ZUVO_RERANK_BASE_URL=(stub or self.stub()).base_url, **extra)
        p = subprocess.run([sys.executable, groom, "plan", "--repo", str(repo or self.repo), *args], env=env,
                           capture_output=True, text=True, timeout=120)
        self.assertEqual(p.returncode, 0, p.stdout + p.stderr)
        return p.stdout

    def queue(self) -> Dict[int, Dict[str, Any]]:
        path = self.repo / "zuvo" / "context" / "backlog-verify-queue.jsonl"
        rows = [json.loads(ln) for ln in path.read_text(encoding="utf-8").splitlines() if ln.strip()]
        return {r["lineno"]: r for r in rows}

    def test_report_line_names_both_entries_keys(self) -> None:
        # Defect: the report names a line only, so a reader cannot tell which entries pair up.
        out = self.plan()
        self.assertEqual(pair_lines(out), [[str(RELOAD_LINE), "id:b-20261015-reload-race",
                                            "id:b-20261015-cache-race", "0.900"]])

    def test_a_dry_run_sends_no_entry_text(self) -> None:
        # Defect: `plan --dry-run`, documented as touching nothing, sends the backlog to the API.
        stub = self.stub()
        self.assertEqual(summary(self.plan("--dry-run", stub=stub)), "skipped:dry-run")
        self.assertEqual(stub.requests, 0)

    def test_a_semantic_duplicate_is_still_dispatched_and_never_a_ledger_row(self) -> None:
        # Defect: a ~0.89-F1 guess is stamped deterministic:duplicate, so the verifier never sees it.
        out = self.plan()
        self.assertEqual(len(pair_lines(out)), 1)
        rows = self.queue()
        self.assertEqual([rows[n]["verdict"] for n in (CACHE_LINE, RELOAD_LINE)], [None, None])
        self.assertIn("DETERMINISTIC=1", out)
        self.assertIn("LEDGER_APPENDED=1 ", out)

    def test_a_decided_entry_gets_no_semantic_report(self) -> None:
        # Defect: an entry classify decided (STALE-OBSOLETE: its only cited file is gone; no exact-key twin)
        # is still sent and paired with the entries it reads like.
        backlog = self.repo / "memory" / "backlog.md"
        backlog.write_text(BACKLOG + GONE, encoding="utf-8")
        stub = self.stub()
        out = self.plan(stub=stub)
        self.assertIn("DET_CLASS=obsolete 1", out)
        self.assertFalse([p for p in pair_lines(out) if p[0] == str(GONE_LINE) or GONE_KEY in p], out)
        self.assertEqual([p[0] for p in pair_lines(out)], [str(RELOAD_LINE)])
        sent = [d for b in stub.bodies for d in [b["query"], *b["documents"]]]
        self.assertFalse(any("stalls" in d for d in sent))
        self.assertTrue(any("race each other" in d for d in sent))

    def test_a_later_keyless_run_does_not_reuse_the_report_as_a_verdict(self) -> None:
        # Defect: the pair is written somewhere plan_reuse reads, so a run without a key treats it as decided.
        self.plan()
        key = Path(self.home, ".zuvo", "openrouter.key")
        key.rename(key.with_name("openrouter.key.moved"))
        out = self.plan(ZUVO_OR_KEY_FILE=str(self.tmp / "no-such.key"), OPENROUTER_API_KEY="")
        self.assertEqual(summary(out), "skipped:no-key")
        rows = self.queue()
        self.assertEqual([(rows[n]["verdict"], rows[n]["reused"]) for n in (CACHE_LINE, RELOAD_LINE)],
                         [(None, False), (None, False)])

    def test_no_key_leaves_every_other_line_of_the_plan_identical(self) -> None:
        # Defect: the semantic pass changes the verdict set or a count, so a keyless machine plans
        # differently from one with a key.
        other = self.make_repo("other")
        with_key = self.plan().replace(str(self.repo), "<repo>")
        without = self.plan(repo=other, HOME=self.nokey).replace(str(other), "<repo>")
        self.assertEqual(summary(without), "skipped:no-key")
        drop = [ln for ln in with_key.splitlines() if not ln.startswith("SEMANTIC_")]
        self.assertEqual(drop, [ln for ln in without.splitlines() if not ln.startswith("SEMANTIC_")])

    def test_a_glob_only_copy_reports_the_kill_switch_not_a_missing_client(self) -> None:
        # Defect: the grooming suites' copies (backlog-groom.py + zuvo_backlog_*.py, no zuvo_rerank.py)
        # print skipped:no-client under ZUVO_RERANK=0, so their assertion cannot tell the two apart.
        flat = self.tmp / "flat"
        flat.mkdir()
        for src in [Path(GROOM), *Path(HOME_DIR).glob("zuvo_backlog_*.py")]:
            shutil.copy(src, flat)
        groom = str(flat / "backlog-groom.py")
        stub = self.stub()
        self.assertEqual(summary(self.plan("--dry-run", stub=stub, groom=groom, ZUVO_RERANK="0")),
                         "skipped:disabled")
        self.assertEqual(summary(self.plan(stub=stub, groom=groom)), "skipped:no-client")
        self.assertEqual(stub.requests, 0)


if __name__ == "__main__":
    unittest.main()
