"""scripts/zuvo-home/zuvo_rerank.py (+ its cache and zuvo_bm25.py) — the one rerank client the zuvo helpers
share. Every test runs against tests/lib/rerank_stub.py on 127.0.0.1 with a temp HOME and ZUVO_HOME; none
can reach the paid API (the base URL always points at a stub, proxies are cleared). Each test names the
defect it catches.
"""

from __future__ import annotations

import json
import os
import socket
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from typing import Any
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts" / "zuvo-home"))
sys.path.insert(0, str(ROOT / "tests" / "lib"))
import zuvo_bm25 as bm25  # noqa: E402
import zuvo_rerank as rr  # noqa: E402
import zuvo_rerank_cache as cache  # noqa: E402
import zuvo_rerank_http as rhttp  # noqa: E402
import zuvo_rerank_io as rio  # noqa: E402
from rerank_stub import RerankStub  # noqa: E402

KEY = "test-key-not-a-real-credential-4242"
MODEL = "voyageai/rerank-2.5-lite"
DOCS = ["alpha text", "beta text", "gamma text"]
FIXTURE = ROOT / "tests" / "fixtures" / "rerank" / "openrouter-rerank-response.json"
SCRUB = ("OPENROUTER_API_KEY", "ZUVO_OR_KEY_FILE", "ZUVO_RERANK", "ZUVO_RERANK_BASE_URL",
         "ZUVO_RERANK_BUDGET_USD", "ZUVO_RERANK_MAX_CALLS", "ZUVO_OPENROUTER_BASE_URL",
         "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "ALL_PROXY", "all_proxy")


def results(*pairs: tuple[Any, Any]) -> bytes:
    return json.dumps({"results": [{"index": i, "relevance_score": s} for i, s in pairs]}).encode()


def free_port() -> int:
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return int(s.getsockname()[1])


class Base(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.home = Path(tmp.name)
        self.zhome = self.home / ".zuvo"
        self.zhome.mkdir()
        env = {k: v for k, v in os.environ.items() if k not in SCRUB}
        env.update(HOME=str(self.home), ZUVO_HOME=str(self.zhome), NO_PROXY="127.0.0.1", no_proxy="127.0.0.1",
                   OPENROUTER_API_KEY=KEY, ZUVO_RERANK_BASE_URL="http://127.0.0.1:9/unreachable")
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        rr.reset_budget()

    def stub(self, scores: dict[str, float] | None = None, **kw: Any) -> RerankStub:
        s = RerankStub(scores, **kw).start()
        self.addCleanup(s.stop)
        os.environ["ZUVO_RERANK_BASE_URL"] = s.base_url
        return s

    def log_lines(self) -> list[str]:
        p = self.zhome / "rerank.log"
        return p.read_text().splitlines() if p.exists() else []

    def last_outcome(self) -> str:
        return self.log_lines()[-1].split("\t")[-1]


class ClientTest(Base):
    def test_scores_map_back_by_index_not_response_order(self) -> None:
        # The stub returns results sorted by score: reading them in list order would swap the scores.
        self.stub({"gamma": 0.9, "alpha": 0.1})
        self.assertEqual(rr.rerank(MODEL, "q", DOCS, caller="t"), [0.1, 0.0, 0.9])

    def test_real_openrouter_response_parses_by_index(self) -> None:
        # Ties the parser to the live shape (extra `document`, `model`, `provider` fields, sorted results).
        self.stub(body=FIXTURE.read_bytes())
        self.assertEqual(rr.rerank(MODEL, "q", DOCS, caller="t"),
                         [0.660357654094696, 0.27611243724823, 0.6537476181983948])
        cost, outcome = self.log_lines()[-1].split("\t")[5:]
        self.assertEqual((float(cost), outcome), (8.2e-7, "ok"))

    def test_empty_docs_return_empty_without_a_request(self) -> None:
        # An empty candidate list must not cost a call or read as a failure.
        stub = self.stub()
        self.assertEqual((rr.rerank(MODEL, "q", [], caller="t"), stub.requests), ([], 0))

    def test_cache_key_covers_model_and_doc_order(self) -> None:
        # A key over the doc SET would serve scores for [a, b] to [b, a] in the wrong positions.
        u = "https://openrouter.ai/api/v1"
        base = cache.key(MODEL, "q", ["a", "b"], base=u)
        for name, other in (("doc order", cache.key(MODEL, "q", ["b", "a"], base=u)),
                            ("model", cache.key("voyageai/rerank-2.5", "q", ["a", "b"], base=u)),
                            ("query", cache.key(MODEL, "q2", ["a", "b"], base=u)),
                            ("endpoint", cache.key(MODEL, "q", ["a", "b"], base="http://127.0.0.1:1/v1"))):
            with self.subTest(name):
                self.assertNotEqual(base, other)

    def test_cache_hit_makes_no_request_and_logs_cached(self) -> None:
        # A cache that is written but never read pays for every repeat call.
        stub = self.stub({"beta": 0.5})
        first = rr.rerank(MODEL, "q", DOCS, caller="t")
        self.assertEqual(rr.rerank(MODEL, "q", DOCS, caller="t"), first)
        self.assertEqual(stub.requests, 1)
        self.assertEqual(self.last_outcome(), "cached")

    def test_cache_does_not_serve_one_endpoint_scores_for_another(self) -> None:
        # A key without the endpoint served a stub's (or another vendor's) scores as OpenRouter's.
        self.stub({"alpha": 0.1})
        rr.rerank(MODEL, "q", DOCS, caller="t")
        other = self.stub({"alpha": 0.9})
        self.assertEqual(rr.rerank(MODEL, "q", DOCS, caller="t"), [0.9, 0.0, 0.0])
        self.assertEqual(other.requests, 1)

    def test_unusable_cache_shard_is_a_miss(self) -> None:
        # A half-written shard, or one for another doc count, must be neither fatal nor served as scores.
        for name, text in (("corrupt", '{"scores": [0.1,'), ("wrong length", '{"scores": [0.1, 0.2]}'),
                           ("strings", '{"scores": ["a", "b", "c"]}'), ("NaN", '{"scores": [NaN, 0.1, 0.2]}'),
                           ("bool", '{"scores": [true, 0.1, 0.2]}'),
                           ("huge int", '{"scores": [1' + "0" * 400 + ', 0.1, 0.2]}')):
            with self.subTest(name):
                stub = self.stub({"alpha": 0.7})
                k = cache.key(MODEL, f"q {name}", DOCS, base=stub.base_url)
                shard = self.zhome / "cache" / "rerank" / k[:2] / f"{k}.json"
                shard.parent.mkdir(parents=True, exist_ok=True)
                shard.write_text(text)
                self.assertEqual(rr.rerank(MODEL, f"q {name}", DOCS, caller="t"), [0.7, 0.0, 0.0])
                self.assertEqual(stub.requests, 1)

    def test_lone_surrogate_doc_is_reranked_not_raised(self) -> None:
        # json.dumps(ensure_ascii=False).encode() raised UnicodeEncodeError on text cut mid-pair.
        self.stub({"b": 0.4})
        self.assertEqual(rr.rerank(MODEL, "q", ["a\udc80", "\ud800b"], caller="t"), [0.0, 0.4])

    def test_bad_responses_return_none_without_raising(self) -> None:
        # Any malformed answer must fall back to today's behaviour, never raise or return wrong scores.
        cases = (
            ("http 500", {"status": 500, "body": b'{"error":"boom"}'}, "http-500"),
            ("error body on 200", {"body": b'{"error":{"message":"no credits"}}'}, "bad-shape"),
            ("duplicate index", {"body": results((0, 0.1), (0, 0.2), (1, 0.3))}, "bad-shape"),
            ("missing index", {"body": b'{"results":[{"index":0,"relevance_score":0.1},'
                                       b'{"relevance_score":0.2},{"index":2,"relevance_score":0.3}]}'},
             "bad-shape"),
            ("index -1", {"body": results((0, 0.1), (1, 0.2), (-1, 0.3))}, "bad-shape"),
            ("index out of range", {"body": results((0, 0.1), (1, 0.2), (3, 0.3))}, "bad-shape"),
            ("boolean index", {"body": results((0, 0.1), (True, 0.2), (2, 0.3))}, "bad-shape"),
            ("NaN score", {"body": b'{"results":[{"index":0,"relevance_score":NaN},'
                                   b'{"index":1,"relevance_score":0.1},{"index":2,"relevance_score":0.2}]}'},
             "bad-shape"),
            ("wrong length", {"body": results((0, 0.1))}, "bad-shape"),
            ("top level is a list", {"body": b"[0.1, 0.2, 0.3]"}, "bad-shape"),
            ("row is not an object", {"body": b'{"results":[0.1, 0.2, 0.3]}'}, "bad-shape"),
            ("missing score", {"body": b'{"results":[{"index":0,"relevance_score":0.1},'
                                       b'{"index":1},{"index":2,"relevance_score":0.3}]}'}, "bad-shape"),
            ("string score", {"body": b'{"results":[{"index":0,"relevance_score":0.1},'
                                      b'{"index":1,"relevance_score":"0.9"},{"index":2,"relevance_score":0.3}]}'},
             "bad-shape"),
            ("truncated JSON", {"body": b'{"results":[{"index":0,'}, "bad-json"),
            ("deep nesting", {"body": b"[" * 200_000}, "bad-json"),
            ("oversize body", {"body": results((0, 0.1), (1, 0.2), (2, 0.3))[:-1]
                               + b', "pad": "' + b"x" * (1024 * 1024) + b'"}'}, "bad-shape"),
            ("short body", {"raw": b'HTTP/1.1 200 OK\r\nContent-Length: 500\r\n\r\n{"results"'}, "http-000"),
            ("malformed status line", {"raw": b"HTTP/1.1 abc\r\n\r\n"}, "http-000"),
            ("delay over timeout", {"delay": 1.0}, "timeout"),
        )
        for name, kw, outcome in cases:
            with self.subTest(name):
                self.stub(**kw)
                self.assertIsNone(rr.rerank(MODEL, f"q {name}", DOCS, timeout=0.3, caller="t"))
                self.assertEqual(self.last_outcome(), outcome)
        self.assertNotIn(KEY, (self.zhome / "rerank.log").read_text())  # no error path writes the key

    def test_huge_integer_score_is_bad_shape_and_its_cost_still_counts(self) -> None:
        # math.isfinite(10**400) raises OverflowError: it escaped _parse and the paid call went unbilled.
        self.stub(body=b'{"results":[{"index":0,"relevance_score":1' + b"0" * 400 + b'},'
                       b'{"index":1,"relevance_score":0.1},{"index":2,"relevance_score":0.2}],'
                       b'"usage":{"cost":0.003}}')
        self.assertIsNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual(self.log_lines()[-1].split("\t")[5:], ["0.003", "bad-shape"])

    def test_transport_refuses_a_url_the_allowlist_refuses(self) -> None:
        # post() sends the key: it must enforce the host allowlist itself, not trust every caller to.
        got = rhttp.post("https://rerank.invalid/v1/rerank", KEY, b"{}", 1.0)
        self.assertEqual(got, (None, "foreign-host"))

    def test_unusable_base_urls_return_none_without_raising(self) -> None:
        # "foo" raised ValueError from Request(); cleartext http to a remote host would expose the key.
        cases = (("malformed", "foo", "bad-url"),
                 ("non-loopback http", "http://rerank.example.invalid/api/v1", "insecure-url"),
                 ("https to another host", "https://rerank.example.invalid/api/v1", "foreign-host"),
                 ("connection refused", f"http://127.0.0.1:{free_port()}/api/v1", "http-000"))
        for name, url, outcome in cases:
            with self.subTest(name):
                os.environ["ZUVO_RERANK_BASE_URL"] = url
                self.assertIsNone(rr.rerank(MODEL, f"q {name}", DOCS, timeout=0.5, caller="t"))
                self.assertEqual(self.last_outcome(), outcome)

    def test_redirect_is_not_followed_with_the_key(self) -> None:
        # urllib re-sends Authorization on a followed 302: the key would reach whatever host it names.
        target = RerankStub().start()
        self.addCleanup(target.stop)
        self.stub(redirect=target.base_url + "/rerank")
        self.assertIsNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual((target.requests, self.last_outcome()), (0, "http-302"))

    def test_trickled_body_hits_the_total_deadline(self) -> None:
        # A per-socket timeout restarts on every byte: 1 byte per 0.25 s never trips timeout=0.5.
        self.stub(trickle=0.25, body=b"[0123456]")
        t0 = time.monotonic()
        self.assertIsNone(rr.rerank(MODEL, "q", DOCS, timeout=0.5, caller="t"))
        self.assertEqual(self.last_outcome(), "timeout")
        self.assertLess(time.monotonic() - t0, 1.5)

    def test_trickled_headers_hit_the_total_deadline(self) -> None:
        # Catches a deadline that covers only the body: the status line and headers are read with a
        # per-recv timeout, so a header trickle would otherwise never trip timeout=0.5.
        self.stub(trickle_headers=0.25)
        t0 = time.monotonic()
        self.assertIsNone(rr.rerank(MODEL, "q", DOCS, timeout=0.5, caller="t"))
        self.assertEqual(self.last_outcome(), "timeout")
        self.assertLess(time.monotonic() - t0, 1.5)

    def test_proxy_environment_is_not_used(self) -> None:
        # urllib honours HTTP(S)_PROXY: the Bearer key would go to whatever proxy a shell exported.
        proxy = RerankStub().start()
        self.addCleanup(proxy.stop)
        real = self.stub()
        for name in ("NO_PROXY", "no_proxy"):
            os.environ.pop(name)
        os.environ.update(HTTP_PROXY=proxy.base_url, http_proxy=proxy.base_url)
        self.assertIsNotNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual((proxy.requests, real.requests), (0, 1))

    def test_unexpected_failure_returns_none_and_logs_error(self) -> None:
        # The never-fatal guard: a caller bug (docs=None) must not crash a hook, and must be visible.
        not_a_list: Any = None
        self.assertIsNone(rr.rerank(MODEL, "q", not_a_list, caller="t"))
        self.assertEqual(self.last_outcome(), "error")

    def test_url_classifier(self) -> None:
        # Loopback http is the stub's only way in; any other cleartext host would carry the key in clear.
        cases = (("https", "https://openrouter.ai/api/v1", None),
                 ("ipv4 loopback", "http://127.0.0.1:8080/v1", None),
                 ("localhost name", "http://localhost:8080/v1", "insecure-url"),
                 ("ipv6 loopback", "http://[::1]:8080/v1", None),
                 ("remote http", "http://openrouter.ai/api/v1", "insecure-url"),
                 ("loopback-looking remote", "http://127.0.0.1.evil.example/v1", "insecure-url"),
                 ("localhost-looking remote", "http://localhost.evil.example/v1", "insecure-url"),
                 ("loopback as userinfo", "http://127.0.0.1@evil.example/v1", "insecure-url"),
                 ("userinfo on loopback", "http://user:pw@127.0.0.1/v1", "bad-url"),
                 ("userinfo on openrouter", "https://u@openrouter.ai/api/v1", "bad-url"),
                 ("https to another host", "https://rerank.example.com/api/v1", "foreign-host"),
                 ("openrouter as a subdomain", "https://openrouter.ai.evil.example/v1", "foreign-host"),
                 ("other scheme", "ftp://openrouter.ai/v1", "bad-url"),
                 ("no scheme", "foo", "bad-url"),
                 ("broken ipv6", "http://[::1/v1", "bad-url"))
        for name, url, want in cases:
            with self.subTest(name):
                self.assertEqual(rio.url_problem(url), want)

    def test_unsafe_keys_are_refused_before_any_request(self) -> None:
        # Mirrors adversarial-lanes-http.sh: a shared-readable, empty or quote-bearing key is never sent.
        ok = "test-key-ok\n"
        cases = (("key file mode 644", "", ok, 0o644), ("key file mode 640", "", ok, 0o640),
                 ("key file mode 604", "", ok, 0o604), ("key file mode 660", "", ok, 0o660),
                 ("empty key file", "", "", 0o600),
                 ("quoted key file", "", 'sk-"x"\n', 0o600),
                 ("backslash in env wins over a good file", "test-key\\x", "test-key-ok\n", 0o600))
        for i, (name, env_key, content, mode) in enumerate(cases):
            with self.subTest(name):
                stub = self.stub()
                kf = self.home / f"case{i}.key"
                kf.write_text(content)
                kf.chmod(mode)
                os.environ.update(OPENROUTER_API_KEY=env_key, ZUVO_OR_KEY_FILE=str(kf))
                self.assertIsNone(rr.rerank(MODEL, f"q {name}", DOCS, caller="t"))
                self.assertEqual((stub.requests, self.last_outcome()), (0, "no-key"))

    def test_no_key_anywhere_makes_no_request(self) -> None:
        # The lane is opt-in: without a key it must skip, not call unauthenticated.
        stub = self.stub()
        os.environ.pop("OPENROUTER_API_KEY")
        self.assertIsNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual((stub.requests, self.last_outcome()), (0, "no-key"))

    def test_private_key_file_is_sent_as_bearer(self) -> None:
        # Positive control for the key table: a mode-600 file is the normal headless case.
        stub = self.stub({"alpha": 0.2})
        os.environ.pop("OPENROUTER_API_KEY")
        kf = self.home / ".zuvo" / "openrouter.key"
        kf.write_text("test-key-file-77\n")
        kf.chmod(0o600)
        self.assertIsNotNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual(stub.auth, ["Bearer test-key-file-77"])

    def test_symlinked_key_file_is_judged_by_its_target(self) -> None:
        # A link is followed, but the TARGET's mode decides: a private target is used, a shared one refused.
        for name, mode, sent in (("private target", 0o600, 1), ("shared target", 0o644, 0)):
            with self.subTest(name):
                stub = self.stub({"alpha": 0.2})
                target, link = self.home / f"{mode:o}.key", self.home / f"{mode:o}-link.key"
                target.write_text("test-key-linked-55\n")
                target.chmod(mode)
                link.symlink_to(target)
                os.environ.update(OPENROUTER_API_KEY="", ZUVO_OR_KEY_FILE=str(link))
                rr.rerank(MODEL, f"q {name}", DOCS, caller="t")
                self.assertEqual(stub.auth, ["Bearer test-key-linked-55"] * sent)
                self.assertNotIn("test-key-linked-55", (self.zhome / "rerank.log").read_text())

    def test_kill_switch_makes_no_request(self) -> None:
        # ZUVO_RERANK=0 is the documented egress opt-out; it must hold even with a key present.
        stub = self.stub()
        os.environ["ZUVO_RERANK"] = "0"
        self.assertIsNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual((stub.requests, self.last_outcome()), (0, "disabled"))

    def test_spent_budget_stops_further_calls(self) -> None:
        # Without the budget a runaway groom pass bills every entry pair.
        stub = self.stub(cost=0.001)
        os.environ["ZUVO_RERANK_BUDGET_USD"] = "0.001"
        self.assertIsNotNone(rr.rerank(MODEL, "q1", DOCS, caller="t"))
        self.assertIsNone(rr.rerank(MODEL, "q2", DOCS, caller="t"))
        self.assertEqual((stub.requests, self.last_outcome()), (1, "budget"))

    def test_unusable_cost_is_logged_as_unknown_and_the_scores_still_count(self) -> None:
        # A string or NaN usage.cost must not raise, drop good scores, or reach the budget as a number.
        for name, cost in (("string cost", "0.002"), ("boolean cost", True)):
            with self.subTest(name):
                self.stub(cost=cost)
                self.assertEqual(rr.rerank(MODEL, f"q {name}", DOCS, caller="t"), [0.0, 0.0, 0.0])
                self.assertEqual(self.log_lines()[-1].split("\t")[5:], ["-", "ok"])

    def test_default_endpoint_is_openrouter_rerank(self) -> None:
        # A wrong default would send every unconfigured run's documents, with the key, to another path.
        del os.environ["ZUVO_RERANK_BASE_URL"]
        with mock.patch.object(rhttp, "post", return_value=(None, "http-000")) as post:
            self.assertIsNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual(post.call_args.args[:2], ("https://openrouter.ai/api/v1/rerank", KEY))

    def test_reset_budget_lets_a_new_run_call_again(self) -> None:
        # A reset that kept the spent total would refuse every later run in a long-lived process.
        stub = self.stub(cost=0.001)
        os.environ["ZUVO_RERANK_BUDGET_USD"] = "0.001"
        rr.rerank(MODEL, "q1", DOCS, caller="t")
        self.assertIsNone(rr.rerank(MODEL, "q2", DOCS, caller="t"))
        rr.reset_budget()
        self.assertIsNotNone(rr.rerank(MODEL, "q3", DOCS, caller="t"))
        self.assertEqual(stub.requests, 2)

    def test_negative_cost_is_not_credited_to_the_budget(self) -> None:
        # A negative usage.cost would refill the budget and let calls run past it.
        self.stub(cost=-1.0)
        self.assertIsNotNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual(self.log_lines()[-1].split("\t")[5], "-")

    def test_call_cap_stops_calls_when_cost_is_absent(self) -> None:
        # A response with no usage.cost never moves the budget; only the call cap bounds it.
        stub = self.stub(cost=None)
        os.environ["ZUVO_RERANK_MAX_CALLS"] = "2"
        got = [rr.rerank(MODEL, f"q{i}", DOCS, caller="t") is None for i in range(3)]
        self.assertEqual(got, [False, False, True])
        self.assertEqual((stub.requests, self.last_outcome()), (2, "budget"))

    def test_openrouter_base_url_override_is_ignored(self) -> None:
        # The BytePlus lane reuses ZUVO_OPENROUTER_BASE_URL; following it would send the key elsewhere.
        decoy = RerankStub().start()
        self.addCleanup(decoy.stop)
        os.environ["ZUVO_OPENROUTER_BASE_URL"] = decoy.base_url
        real = self.stub()
        rr.rerank(MODEL, "q", DOCS, caller="t")
        self.assertEqual((decoy.requests, real.requests), (0, 1))

    def test_log_line_has_seven_fields_and_never_the_key(self) -> None:
        # A key in a world-readable log leaks it; a shifted column breaks every reader of the log.
        self.stub({"alpha": 0.3})
        rr.rerank(MODEL, "q", DOCS, caller="knowledge\tprime")
        fields = self.log_lines()[-1].split("\t")
        self.assertEqual((len(fields), fields[3], fields[5], fields[6]), (7, "3", "0.001", "ok"))
        self.assertNotIn(KEY, (self.zhome / "rerank.log").read_text())

    def test_log_sanitises_every_non_printable_character(self) -> None:
        # \v, \f, \x1c-\x1e, \x85, U+2028/9 split lines for splitlines(); ESC drives a terminal.
        self.stub()
        for i, ch in enumerate("\t\v\f\x1c\x1d\x1e\x85\u2028\u2029\x1b"):
            with self.subTest(repr(ch)):
                before = len(self.log_lines())
                rr.rerank(MODEL, f"q{i}", DOCS, caller=f"a{ch}b")
                self.assertEqual(len(self.log_lines()), before + 1)
                self.assertEqual(self.log_lines()[-1].split("\t")[1], "a b")

    def test_symlinked_log_is_never_followed(self) -> None:
        # Appending through a planted rerank.log link would write into whatever file it names.
        self.stub()
        target = self.home / "victim.txt"
        target.write_text("untouched\n")
        (self.zhome / "rerank.log").symlink_to(target)
        self.assertIsNotNone(rr.rerank(MODEL, "q", DOCS, caller="t"))
        self.assertEqual(target.read_text(), "untouched\n")

    def test_rotation_never_replaces_a_symlinked_dot_one(self) -> None:
        # Rotating onto a planted rerank.log.1 link is a write the user never asked for; skip rotation.
        self.stub()
        target = self.home / "victim.txt"
        target.write_text("untouched\n")
        (self.zhome / "rerank.log.1").symlink_to(target)
        (self.zhome / "rerank.log").write_bytes(b"x" * (5 * 1024 * 1024 + 1))
        rr.rerank(MODEL, "q", DOCS, caller="t")
        dot_one = self.zhome / "rerank.log.1"
        self.assertEqual((dot_one.is_symlink(), target.read_text()), (True, "untouched\n"))

    def test_log_over_five_mb_rotates_to_dot_one(self) -> None:
        # An unrotated log grows without bound on a machine that reranks every session.
        self.stub()
        log = self.zhome / "rerank.log"
        log.write_bytes(b"x" * (5 * 1024 * 1024 + 1))
        rr.rerank(MODEL, "q", DOCS, caller="t")
        self.assertEqual((self.zhome / "rerank.log.1").stat().st_size, 5 * 1024 * 1024 + 1)
        self.assertEqual(len(self.log_lines()), 1)

    def test_threads_never_exceed_call_cap_and_log_stays_whole(self) -> None:
        # The groom pass calls from 8 threads: unlocked counters overshoot, unlocked writes interleave.
        stub = self.stub(delay=0.05)
        os.environ["ZUVO_RERANK_MAX_CALLS"] = "3"
        threads = [threading.Thread(target=rr.rerank, args=(MODEL, f"q{i}", DOCS), kwargs={"caller": "t"})
                   for i in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        self.assertEqual(stub.requests, 3)
        self.assertEqual([len(line.split("\t")) for line in self.log_lines()], [7] * 8)


class PruneTest(Base):
    def shards(self, n: int) -> list[Path]:
        root = self.zhome / "cache" / "rerank"
        for i in range(n):
            cache.put(cache.key(MODEL, f"q{i}", DOCS, base="u"), [0.1, 0.2, 0.3], root=root)
        return sorted(root.glob("*/*.json"))

    def test_prune_removes_files_older_than_thirty_days(self) -> None:
        # Without age pruning the cache keeps every query ever made.
        files = self.shards(2)
        old = time.time() - 31 * 86400
        os.utime(files[0], (old, old))
        cache.prune(self.zhome / "cache" / "rerank")
        self.assertEqual(sorted((self.zhome / "cache" / "rerank").glob("*/*.json")), files[1:])

    def test_prune_enforces_the_file_count_cap_keeping_newest(self) -> None:
        # A burst of fresh queries must still be bounded by count.
        files = self.shards(3)
        for age, f in enumerate(files):
            t = time.time() - (3 - age) * 60
            os.utime(f, (t, t))
        cache.prune(self.zhome / "cache" / "rerank", max_files=1)
        self.assertEqual(sorted((self.zhome / "cache" / "rerank").glob("*/*.json")), files[-1:])


class Bm25Test(unittest.TestCase):
    def test_degenerate_inputs_keep_input_order(self) -> None:
        # Catches avgdl=0 or idf over an empty corpus raising ZeroDivisionError in the caller.
        cases = (("empty query", "", ["a b", "c"], 2, [0, 1]),
                 ("punctuation query", "!!", ["a", "b"], 5, [0, 1]),
                 ("empty corpus", "a", [], 3, []),
                 ("empty docs", "a", ["", ""], 2, [0, 1]),
                 ("absent term", "zzz", ["a", "b", "c"], 2, [0, 1]))
        for name, q, docs, k, want in cases:
            with self.subTest(name):
                self.assertEqual(bm25.top_k(q, docs, k), want)

    def test_term_in_every_doc_still_scores_above_zero(self) -> None:
        # Classic BM25 idf goes negative when df > N/2, ranking the matching docs BELOW the rest.
        self.assertTrue(all(s > 0 for s in bm25.scores("cache", ["cache a", "cache b", "cache c"])))

    def test_matching_doc_ranks_first_including_unicode(self) -> None:
        # An ASCII-only tokenizer drops Polish words and ranks by nothing.
        cases = (("ascii", "cache key", ["log rotate", "cache key order", "budget"], 1),
                 ("unicode casefold", "ZAŻÓŁĆ", ["gęślą jaźń", "zażółć gęślą"], 1))
        for name, q, docs, want in cases:
            with self.subTest(name):
                self.assertEqual(bm25.top_k(q, docs, 1), [want])


if __name__ == "__main__":
    unittest.main()
