"""scripts/zuvo-home/knowledge-rank (+ zuvo_knowledge_rank.py) — knowledge-prime Steps 3 and 4 in code.

Every test runs the CLI as a subprocess, as knowledge-prime does, against a copy of the synthetic store in
tests/fixtures/rerank/knowledge/ and the local rerank stub on 127.0.0.1 (temp HOME and ZUVO_HOME, proxies
cleared), so no test can reach the paid API. Each test names the defect it catches.
"""

from __future__ import annotations

import contextlib
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from collections.abc import Iterator
from typing import Any

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tests" / "lib"))
sys.path.insert(0, str(ROOT / "scripts" / "zuvo-home"))
import zuvo_knowledge_rank_score as krs  # noqa: E402
from rerank_stub import RerankStub  # noqa: E402

CLI = ROOT / "scripts" / "zuvo-home" / "knowledge-rank"
FIXTURE = ROOT / "tests" / "fixtures" / "rerank" / "knowledge"
KEY = "test-key-not-a-real-credential-4242"
CAPS = {"MUST AVOID": 3, "GOTCHAS": 2, "DECISIONS": 2, "CODEBASE FACTS": 2, "PATTERNS": 1}
# Every fixture tag as keywords: each entry then has lexical overlap and enters the pool, so the stub's
# scores alone decide the order.


def fixture_tags() -> list[str]:
    tags: set[str] = set()
    for f in FIXTURE.glob("*.jsonl"):
        for line in f.read_text().split("\n"):
            with contextlib.suppress(ValueError, AttributeError):
                tags.update(json.loads(line).get("tags", []))
    return sorted(tags)


EVERY = ",".join(fixture_tags())


def days_ago(n: int) -> str:
    return (datetime.now(UTC).date() - timedelta(days=n)).isoformat()


def store_digest(store: Path) -> dict[str, str]:
    return {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(store.glob("*.jsonl"))}


class KnowledgeRankTest(unittest.TestCase):
    def setUp(self) -> None:
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        base = Path(tmp.name)
        self.main_root = base / "repo"
        self.store = self.main_root / "knowledge"
        shutil.copytree(FIXTURE, self.store)
        self.zhome = base / "home" / ".zuvo"
        self.zhome.mkdir(parents=True)
        # A minimal env, not a scrubbed copy: no caller key, key file or ZUVO_RERANK* can leak in.
        self.env = {k: os.environ[k] for k in ("PATH", "LANG") if k in os.environ}
        self.env.update(HOME=str(base / "home"), ZUVO_HOME=str(self.zhome), NO_PROXY="127.0.0.1",
                        no_proxy="127.0.0.1", OPENROUTER_API_KEY=KEY,
                        ZUVO_RERANK_BASE_URL="http://127.0.0.1:9/unreachable")
        self.assertTrue(EVERY, "no tags parsed from the fixture store")

    def stub(self, scores: dict[str, float] | None = None, **kw: Any) -> RerankStub:
        s = RerankStub(scores, **kw).start()
        self.addCleanup(s.stop)
        self.env["ZUVO_RERANK_BASE_URL"] = s.base_url
        return s

    @contextlib.contextmanager
    def scoped_stub(self, scores: dict[str, float] | None = None, **kw: Any) -> Iterator[RerankStub]:
        with RerankStub(scores, **kw) as s:
            self.env["ZUVO_RERANK_BASE_URL"] = s.base_url
            yield s

    def run_cli(self, keywords: str, files: str | None = None, *extra: str
                ) -> tuple[list[dict[str, Any]], subprocess.CompletedProcess[str]]:
        proc = self.run_raw(keywords, files, "--json", *extra)
        return json.loads(proc.stdout), proc

    def run_raw(self, keywords: str, files: str | None, *extra: str) -> subprocess.CompletedProcess[str]:
        argv = [str(CLI), "--root", str(self.main_root), "--keywords", keywords, *extra]
        if files is not None:
            argv += ["--files", files]
        proc = subprocess.run(argv, env=self.env, cwd=self.main_root, capture_output=True, text=True,
                              timeout=60)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc

    def write_store(self, name: str, entries: list[dict[str, Any]]) -> None:
        shutil.rmtree(self.store)
        self.store.mkdir()
        (self.store / name).write_text("".join(json.dumps(e) + "\n" for e in entries))

    @staticmethod
    def ids(rows: list[dict[str, Any]], section: str | None = None) -> list[str]:
        return [r["id"] for r in rows if section is None or r["section"] == section]

    def test_malformed_line_is_skipped_and_the_store_is_byte_identical_afterwards(self) -> None:
        # Catches the helper crashing on, dropping, or "repairing" a malformed line by rewriting the store.
        self.stub({"": 0.5})
        before = store_digest(self.store)
        rows, proc = self.run_cli("timezone")
        self.assertNotIn("broken", self.ids(rows))
        self.assertIn("gotcha-timezone-midnight", self.ids(rows))
        self.assertIn("Preserved malformed line 4 in knowledge/gotchas.jsonl", proc.stderr)
        self.assertEqual(store_digest(self.store), before)

    def test_deeply_nested_line_is_skipped_not_fatal(self) -> None:
        # Catches json.loads' RecursionError escaping the malformed-line guard and killing the whole prime.
        with (self.store / "gotchas.jsonl").open("a") as f:
            f.write("[" * 200000 + "\n")
        self.env["ZUVO_RERANK"] = "0"
        rows, _ = self.run_cli("timezone")
        self.assertIn("gotcha-timezone-midnight", self.ids(rows))

    def test_unreadable_knowledge_file_is_reported_and_skipped(self) -> None:
        # Catches a read error vanishing silently (or killing the prime): a directory named *.jsonl is EISDIR.
        (self.store / "broken.jsonl").mkdir()
        self.env["ZUVO_RERANK"] = "0"
        rows, proc = self.run_cli("timezone")
        self.assertIn("[KNOWLEDGE] could not read knowledge/broken.jsonl: EISDIR", proc.stderr)
        self.assertIn("gotcha-timezone-midnight", self.ids(rows))

    def test_duplicate_id_keeps_the_newer_entry(self) -> None:
        # Catches one entry surfacing twice (two slots), or the older copy winning because it was read last.
        self.write_store("decisions.jsonl", [{"id": "dup", "type": "decision", "fact": "widget old",
                                              "updatedAt": days_ago(50)}])
        (self.store / "decisions-new.jsonl").write_text(json.dumps(
            {"id": "dup", "type": "decision", "fact": "widget new", "updatedAt": days_ago(5)}) + "\n")
        self.env["ZUVO_RERANK"] = "0"
        rows, proc = self.run_cli("widget")
        self.assertEqual(self.ids(rows), ["dup"])
        self.assertIn("duplicate id dup: kept knowledge/decisions-new.jsonl line 1, "
                      "skipped knowledge/decisions.jsonl line 1", proc.stderr)

    def test_unicode_line_separator_inside_a_string_keeps_the_entry(self) -> None:
        # Catches str.splitlines() cutting a JSON line at U+2028, which JSON allows unescaped in a string.
        entry = {"id": "fact-ls", "type": "codebase-fact", "fact": "widget\u2028second line",
                 "confidence": "medium"}
        self.write_store("codebase-facts.jsonl", [])
        (self.store / "codebase-facts.jsonl").write_text(json.dumps(entry, ensure_ascii=False) + "\n",
                                                         encoding="utf-8")
        self.env["ZUVO_RERANK"] = "0"
        rows, _ = self.run_cli("widget")
        self.assertEqual(self.ids(rows), ["fact-ls"])

    def test_missing_knowledge_dir_gives_an_empty_ranking(self) -> None:
        # Catches a fresh repo (no knowledge/ yet) crashing the helper instead of priming nothing.
        shutil.rmtree(self.store)
        rows, _ = self.run_cli("cache")
        self.assertEqual(rows, [])

    def test_legacy_content_implication_entry_is_ranked(self) -> None:
        # Catches reading only fact/recommendation: the legacy entry holds "errexit" in `content` alone.
        self.env["ZUVO_RERANK"] = "0"
        rows, _ = self.run_cli("errexit")
        self.assertEqual(self.ids(rows), ["gotcha-legacy-errexit"])

    def bm25_pair(self) -> None:
        # The weak entry is newer and listed first, so only the BM25 score can put the strong one ahead.
        self.write_store("codebase-facts.jsonl", [
            {"id": "fact-weak", "type": "codebase-fact", "fact": "One widget among many other words here.",
             "confidence": "medium", "updatedAt": days_ago(1)},
            {"id": "fact-strong", "type": "codebase-fact", "tags": ["widget"], "fact": "Widget widget.",
             "confidence": "medium", "updatedAt": days_ago(90)}])

    def test_no_key_keeps_the_bm25_order_and_exits_0(self) -> None:
        # Catches a missing key turning into an empty prime, a crash, or an order other than BM25's.
        self.bm25_pair()
        stub = self.stub({"among": 0.9})  # would reverse the pair if it were called
        del self.env["OPENROUTER_API_KEY"]
        rows, _ = self.run_cli("widget")
        self.assertEqual(self.ids(rows), ["fact-strong", "fact-weak"])
        self.assertEqual(stub.requests, 0)

    def test_failed_rerank_with_a_key_keeps_the_bm25_order(self) -> None:
        # Catches an HTTP error or an unparsable answer turning into an empty prime instead of BM25 order.
        cases: dict[str, dict[str, Any]] = {"http 500": {"status": 500, "body": b"{}"},
                                            "bad body": {"body": b"not json"}}
        for name, kw in cases.items():
            with self.subTest(name):
                self.bm25_pair()
                with self.scoped_stub({}, **kw) as stub:
                    rows, _ = self.run_cli(f"widget {name}")
                self.assertEqual(stub.requests, 1)
                self.assertEqual(self.ids(rows), ["fact-strong", "fact-weak"])

    def test_no_keywords_and_no_files_sends_nothing(self) -> None:
        # Catches the session prime (nothing to rank by) sending the whole store out for reranking.
        stub = self.stub({"": 0.5})
        self.run_cli("")
        self.assertEqual(stub.requests, 0)
        self.assertFalse((self.zhome / "rerank.log").exists())

    def test_no_keywords_and_no_files_applies_step3_and_keeps_score_1_and_up(self) -> None:
        # Catches the session prime surfacing entries Step 3 scores below 1. Each absent entry sits in a
        # section with room to spare, so only the score filter can keep it out.
        def e(id_: str, type_: str, conf: str, age: int | None, surfaced: int = 1) -> dict[str, Any]:
            out = {"id": id_, "type": type_, "fact": id_, "confidence": conf, "timesSurfaced": surfaced}
            return out if age is None else {**out, "updatedAt": days_ago(age)}
        self.write_store("mixed.jsonl", [
            e("high-recent", "anti-pattern", "high", 5),            # 1 + 1 = 2
            e("high-old", "anti-pattern", "high", 100),             # 1
            e("high-stale", "decision", "high", 400),               # 1: no staleness penalty when high
            e("medium-recent", "gotcha", "medium", 10),             # 0 + 1 = 1
            e("medium-35-days", "pattern", "medium", 35),           # 0
            e("medium-no-date", "codebase-fact", "medium", None),   # 0
            e("medium-old", "gotcha", "medium", 200),               # 0, stale non-high -1 = -1
            e("low-unsurfaced", "codebase-fact", "low", 5, 0)])     # low -1, recent +1, unvalidated -2 = -2
        rows, _ = self.run_cli("")
        self.assertEqual([(r["id"], r["score"]) for r in rows],
                         [("high-recent", 2), ("high-old", 1), ("medium-recent", 1), ("high-stale", 1)])

    def test_60_entry_corpus_sends_exactly_50_docs_to_the_reranker(self) -> None:
        # Catches an unbounded pool: the whole store would be billed and sent on every prime.
        shutil.rmtree(self.store)
        self.store.mkdir()
        lines = [json.dumps({"id": f"fact-{i:02d}", "type": "codebase-fact", "tags": ["widget"],
                             "fact": f"Widget fact number {i}.", "recommendation": "Read it.",
                             "confidence": "medium", "updatedAt": "2026-09-01"}) for i in range(60)]
        (self.store / "codebase-facts.jsonl").write_text("\n".join(lines) + "\n")
        stub = self.stub({"": 0.5})
        self.run_cli("widget")
        self.assertEqual(stub.requests, 1)
        self.assertEqual(len(stub.bodies[0]["documents"]), 50)

    def widgets(self, n: int, extra: list[dict[str, Any]]) -> None:
        weak = [{"id": f"fact-{i:02d}", "type": "codebase-fact", "confidence": "medium",
                 "fact": f"One widget among many other filler words number {i}."} for i in range(n)]
        self.write_store("codebase-facts.jsonl", weak + extra)

    def test_glob_hit_outside_the_lexical_top_50_still_reaches_the_reranker(self) -> None:
        # Catches the boost bypassing the pool: a glob-only entry must be sent, not scored unseen.
        self.widgets(60, [{"id": "fact-glob", "type": "codebase-fact", "fact": "Unrelated prose.",
                           "affectedFiles": ["src/glob/**"], "confidence": "medium"}])
        stub = self.stub({"": 0.5})
        self.run_cli("widget", "src/glob/x.ts")
        self.assertIn("Unrelated prose.", stub.bodies[0]["documents"])
        self.assertEqual(len(stub.bodies[0]["documents"]), 50)

    def test_strongest_lexical_match_listed_last_is_in_the_pool(self) -> None:
        # Catches a pool taken in file order instead of BM25 order.
        self.widgets(60, [{"id": "fact-strong", "type": "codebase-fact", "tags": ["widget"],
                           "fact": "Widget widget widget.", "confidence": "medium"}])
        stub = self.stub({"": 0.5})
        self.run_cli("widget")
        self.assertIn("widget Widget widget widget.", stub.bodies[0]["documents"])

    def test_unrelated_entry_is_neither_sent_nor_kept(self) -> None:
        # Catches a missing relevance floor: zero lexical overlap and no glob hit, however the stub scores it.
        stub = self.stub({"backoff": 0.99, "": 0.5})
        rows, _ = self.run_cli("cache")
        self.assertNotIn("pattern-retry-backoff", self.ids(rows))
        self.assertFalse(any("backoff" in d for d in stub.bodies[0]["documents"]))

    def test_no_candidate_makes_no_request(self) -> None:
        # Catches billing a rerank call for a pool that is empty once the relevance floor applies.
        stub = self.stub({"": 0.5})
        rows, _ = self.run_cli("zzznomatch")
        self.assertEqual((rows, stub.requests), ([], 0))

    def test_glob_boost_does_not_beat_a_stronger_rerank_score(self) -> None:
        # Catches GLOB_BOOST blown up: 0.44 + boost (0.1 x 0.50) stays under 0.50; a boost of 0.07+ fails.
        self.write_store("codebase-facts.jsonl", [
            {"id": "fact-glob", "type": "codebase-fact", "fact": "beta widget", "affectedFiles": ["src/**"]},
            {"id": "fact-strong", "type": "codebase-fact", "fact": "alpha widget"}])
        self.stub({"alpha": 0.50, "beta": 0.44})
        rows, _ = self.run_cli("widget", "src/x.ts")
        self.assertEqual(self.ids(rows), ["fact-strong", "fact-glob"])

    def test_negative_rerank_score_in_the_pool_is_kept_last(self) -> None:
        # Catches eligibility read off "score > 0": a pool member scored below 0 is still a match.
        self.write_store("codebase-facts.jsonl", [
            {"id": "fact-neg", "type": "codebase-fact", "fact": "beta widget", "affectedFiles": ["src/**"]},
            {"id": "fact-pos", "type": "codebase-fact", "fact": "alpha widget"}])
        self.stub({"alpha": 0.5, "beta": -2.0})
        rows, _ = self.run_cli("widget", "src/x.ts")
        self.assertEqual(self.ids(rows), ["fact-pos", "fact-neg"])

    def test_same_id_in_two_types_is_not_a_duplicate(self) -> None:
        # Catches dedup on id alone dropping a different entry that happens to share an id.
        self.write_store("gotchas.jsonl", [{"id": "shared", "type": "gotcha", "fact": "widget g"}])
        (self.store / "decisions.jsonl").write_text(json.dumps(
            {"id": "shared", "type": "decision", "fact": "widget d"}) + "\n")
        self.env["ZUVO_RERANK"] = "0"
        rows, _ = self.run_cli("widget")
        self.assertEqual([r["type"] for r in rows], ["gotcha", "decision"])

    def test_bom_prefixed_file_keeps_its_first_entry(self) -> None:
        # Catches a UTF-8 BOM (Windows editors) turning line 1 into a malformed line.
        self.write_store("codebase-facts.jsonl", [])
        (self.store / "codebase-facts.jsonl").write_text(
            "\ufeff" + json.dumps({"id": "fact-bom", "type": "codebase-fact", "fact": "widget"}) + "\n",
            encoding="utf-8")
        self.env["ZUVO_RERANK"] = "0"
        rows, _ = self.run_cli("widget")
        self.assertEqual(self.ids(rows), ["fact-bom"])

    def test_rerank_payload_is_truncated(self) -> None:
        # Catches an oversized entry or keyword list being sent (and billed) whole.
        self.write_store("codebase-facts.jsonl", [
            {"id": "fact-huge", "type": "codebase-fact", "fact": "widget " * 1000, "confidence": "medium"}])
        stub = self.stub({"": 0.5})
        self.run_cli(",".join(["widget"] * 400))
        body = stub.bodies[0]
        self.assertEqual((len(body["documents"][0]), len(body["query"])), (2000, 1000))

    def test_rerank_scores_reorder_past_the_bm25_order(self) -> None:
        # Catches the rerank answer being ignored (or read in response order) in favour of BM25.
        self.stub({"eval": 0.95, "retry": 0.3})
        rows, _ = self.run_cli("retry,queue,shell")  # BM25 alone puts ap-retry-unbounded first
        self.assertEqual(self.ids(rows, "MUST AVOID")[:2], ["ap-shell-eval", "ap-retry-unbounded"])
        self.assertEqual(rows[0]["score"], 0.95)
        self.assertTrue((self.zhome / "rerank.log").exists())  # gives the absence check elsewhere meaning

    def test_equal_scores_put_the_affected_files_glob_match_first(self) -> None:
        # Catches a missing glob boost: src/cache/** must match src/cache/ttl.ts.
        self.stub({"": 0.5})
        rows, _ = self.run_cli(EVERY, "src/cache/ttl.ts\n")
        self.assertEqual(self.ids(rows, "MUST AVOID"),
                         ["ap-cache-key-unscoped", "gotcha-timezone-midnight", "ap-retry-unbounded"])

    def test_a_near_miss_path_gets_no_glob_boost(self) -> None:
        # Catches substring matching: src/cache-old/ttl.ts contains "src/cache" but is not under src/cache/.
        self.stub({"": 0.5})
        rows, _ = self.run_cli(EVERY, "src/cache-old/ttl.ts\n")
        self.assertEqual({r["score"] for r in rows}, {0.5})

    def test_affected_files_globs_follow_gitignore_rules(self) -> None:
        # Catches fnmatch semantics: `*` crossing `/`, `**/` not matching zero dirs, a `./` prefix mismatch.
        cases = [("src/**/x.ts", "src/x.ts", True), ("src/**/x.ts", "src/a/b/x.ts", True),
                 ("src/*.ts", "src/a/x.ts", False), ("src/*.ts", "src/x.ts", True),
                 ("src/**", "src/a/b/c.py", True), ("./src/x.ts", "src/x.ts", True),
                 ("src/x.ts", "./src/x.ts", True), ("src/a?.ts", "src/a/.ts", False),
                 ("*.test.ts", "src/a/x.test.ts", True), ("Makefile", "a/Makefile", True),
                 ("*.ts", "src/x.tsx", False), ("src/", "src/a/b.ts", True), ("src/", "srcx/a.ts", False),
                 ("docs/", "a/docs/x.md", True)]
        for glob, path, expected in cases:
            with self.subTest(glob=glob, path=path):
                self.assertEqual(krs.glob_hit({"affectedFiles": [glob]}, [path]), expected)

    def test_text_output_keeps_three_columns_for_any_id(self) -> None:
        # Catches a raw id breaking the TSV: a tab or newline adds columns, a lone surrogate crashes print.
        cases = {"tab and newline": "a\tb\nc", "lone surrogate": "bad\udc80id"}
        for name, id_ in cases.items():
            with self.subTest(name):
                self.write_store("decisions.jsonl", [{"id": id_, "type": "decision", "fact": "widget"}])
                self.env["ZUVO_RERANK"] = "0"
                proc = self.run_raw("widget", None)
                fields = proc.stdout.rstrip("\n").split("\t")
                self.assertEqual((len(fields), fields[:2]), (3, ["DECISIONS", json.dumps(id_)]))

    def test_recency_only_breaks_ties(self) -> None:
        # Catches recency outranking relevance: an older anti-pattern scores highest and must lead the newer.
        self.stub({"sleep": 0.9, "": 0.5})
        rows, _ = self.run_cli(EVERY)
        self.assertEqual(self.ids(rows, "MUST AVOID"),
                         ["ap-sleep-in-tests", "gotcha-timezone-midnight", "ap-cache-key-unscoped"])

    def test_step4_section_caps_hold(self) -> None:
        # Catches a missing per-section or total cap: every entry scores 0.5, so only the caps limit output.
        self.stub({"": 0.5})
        rows, _ = self.run_cli(EVERY)
        self.assertEqual([r["section"] for r in rows], [s for s, n in CAPS.items() for _ in range(n)])

    def test_k_lowers_the_total_cap(self) -> None:
        # Catches --k being parsed but ignored, so a caller asking for fewer entries still gets ten.
        self.stub({"": 0.5})
        rows, _ = self.run_cli(EVERY, None, "--k", "4")
        self.assertEqual(len(rows), 4)

    def test_rerank_model_defaults_to_rerank_2_5_and_follows_the_env(self) -> None:
        # Catches the knowledge pass using the backlog's lite model, or ignoring the override.
        cases = {"default": ({}, "voyageai/rerank-2.5"),
                 "override": ({"ZUVO_KNOWLEDGE_RERANK_MODEL": "x/other"}, "x/other")}
        for name, (env, expected) in cases.items():
            with self.subTest(name):
                self.env.update(env)
                with self.scoped_stub({"": 0.5}) as stub:
                    self.run_cli(f"cache {name}")
                self.assertEqual(stub.bodies[0]["model"], expected)

    def run_step3_block(self, keywords: str, files: str) -> subprocess.CompletedProcess[str]:
        """Run the fenced command from knowledge-prime.md Step 3 from a subdirectory of the repo.

        Only the placeholder text inside the doc's own quotes is replaced, as an agent fills it, with the
        embedded-quote rule applied (' written as '\\'')."""
        doc = (ROOT / "shared" / "includes" / "knowledge-prime.md").read_text()
        step3 = doc.split("### Step 3", 1)[1].split("### Step 4", 1)[0]
        cmds = [b for b in re.findall(r"```bash\n(.*?)```", step3, re.S) if "knowledge-rank" in b]
        self.assertEqual(len(cmds), 1, "Step 3 must hold exactly one fenced knowledge-rank block")

        def fill(text: str, placeholder: str, value: str) -> str:
            self.assertRegex(text, placeholder)
            return re.sub(placeholder, lambda _: value.replace("'", "'\\''"), text)
        cmd = fill(cmds[0], r"<kw1,kw2>", keywords)
        cmd = fill(cmd, r"<path1>(?:\\n|\n)<path2>", files)
        (self.zhome / "knowledge-rank").symlink_to(CLI)  # the path the doc names: ~/.zuvo/knowledge-rank
        git = {"GIT_CONFIG_GLOBAL": os.devnull, "GIT_CONFIG_NOSYSTEM": "1"}
        subprocess.run(["git", "init", "-q", str(self.main_root)], env={**self.env, **git}, check=True)
        subdir = self.main_root / "src"
        subdir.mkdir()
        return subprocess.run(["bash", "-c", cmd], env={**self.env, **git}, cwd=subdir,
                              capture_output=True, text=True, timeout=60)

    def test_step3_command_in_knowledge_prime_runs_against_the_helper(self) -> None:
        # Catches the doc's command drifting from the helper (a renamed flag, a wrong path), and a Step 3
        # block that leans on $MAIN_ROOT set elsewhere: each Bash call is a fresh shell, so --root "" would
        # make the helper read the CWD's knowledge/ (none, from a subdirectory), exit 0 and never fall back.
        stub = self.stub({"eval": 0.95, "": 0.5})
        proc = self.run_step3_block(EVERY, "src/cache/ttl.ts")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        rows = json.loads(proc.stdout)
        self.assertEqual([r["section"] for r in rows], [s for s, n in CAPS.items() for _ in range(n)])
        self.assertGreaterEqual(stub.requests, 1)
        self.assertEqual((rows[0]["id"], rows[0]["score"]), ("ap-shell-eval", 0.95))

    def test_step3_block_does_not_execute_shell_syntax_in_the_filled_in_values(self) -> None:
        # Catches the placeholders sitting in double quotes or $'...': a keyword or path taken from task text
        # holding $(...) or a backtick would run as a command before the helper starts.
        self.stub({"": 0.5})
        marks = [self.main_root.parent / "pwned-subst", self.main_root.parent / "pwned-tick"]
        keywords = f"{EVERY},$(touch {marks[0]}),`touch {marks[1]}`,it's"
        proc = self.run_step3_block(keywords, f"src/$(touch {marks[0]})/`touch {marks[1]}`.ts")
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual([m.exists() for m in marks], [False, False])

TODAY = date(2026, 10, 15)


def ago(n: int) -> str:
    return (TODAY - timedelta(days=n)).isoformat()


class ScoreRulesTest(unittest.TestCase):
    def test_prime_score_reproduces_step3_rows(self) -> None:
        # Catches an off-by-one at a Step 3 boundary, a future date earning the recency bonus, or the
        # updatedAt offset being dropped (23:30 at -02:00 on day 31 is day 30 in UTC).
        cases = [("30 days", "medium", ago(30), 1, 1.0), ("31 days", "medium", ago(31), 1, 0.0),
                 ("180 days", "medium", ago(180), 1, 0.0), ("181 days", "medium", ago(181), 1, -1.0),
                 ("181 days high", "high", ago(181), 1, 1.0), ("low unsurfaced", "low", None, 0, -3.0),
                 ("low surfaced", "low", None, 1, -1.0), ("future", "medium", "2026-10-20", 1, 0.0),
                 ("offset", "medium", ago(31) + "T23:30:00-02:00", 1, 1.0),
                 ("unparseable", "medium", "soon", 1, 0.0)]
        for name, conf, updated, surfaced, expected in cases:
            with self.subTest(name):
                entry = {"confidence": conf, "timesSurfaced": surfaced, "updatedAt": updated}
                self.assertEqual(krs.prime_score(entry, today=TODAY), expected)

    def test_unusable_dates_are_the_oldest(self) -> None:
        # Catches a non-string or out-of-range updatedAt crashing the helper or parsing as a real date.
        cases = {"int": 20260901, "list": ["2026-09-01"], "dict": {"d": 1}, "None": None,
                 "overflow on astimezone": "0001-01-01T00:00:00+05:00"}
        for name, value in cases.items():
            with self.subTest(name):
                self.assertIsNone(krs.instant(value))

    def test_recency_compares_instants_not_text(self) -> None:
        # Catches raw-string comparison: offsets, the createdAt fallback, an unparseable date as newest.
        cases = {"offsets": ({"updatedAt": "2026-09-01T06:00:00Z"},
                             {"updatedAt": "2026-09-01T10:00:00+05:00"}),
                 "createdAt fallback": ({"createdAt": "2026-09-02"}, {"updatedAt": "2026-09-01"}),
                 "unparseable is oldest": ({"updatedAt": "1970-01-02"}, {"updatedAt": "garbage"})}
        for name, (newer, older) in cases.items():
            with self.subTest(name):
                self.assertGreater(krs.recency(newer), krs.recency(older))


if __name__ == "__main__":
    unittest.main()
