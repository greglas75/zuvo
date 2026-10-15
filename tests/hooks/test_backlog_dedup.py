"""scripts/zuvo-home/zuvo_backlog_verdicts.py — table rows must not be paired or archived through a
signature made only of metadata columns. And scripts/zuvo-home/zuvo_backlog_dedup.py's add-time
candidate: which entry a new finding may duplicate, scored against tests/lib/rerank_stub.py only.

`normalize_signature` reads a path token and the 8 words AFTER it. On a table row whose Problem cell
precedes the File cell those 8 words are Severity/Source/Date, so two different findings in one file
share one `fp:` key. The keys stay frozen (H10 pins them); what is tested here is that the GROUPING
built on them (`duplicate_anchors`, the `archive_index` match in `classify`) no longer trusts a
table-row key alone. Every row names the defect it catches. Fixtures are synthetic.
"""

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
sys.path.insert(0, HOME_DIR)
sys.path.insert(0, os.path.join(ROOT, "tests", "lib"))
import zuvo_backlog_admit as adm  # noqa: E402
import zuvo_backlog_dedup as dd  # noqa: E402
import zuvo_backlog_entry as ent  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402
import zuvo_rerank as rr  # noqa: E402
from rerank_stub import RerankStub  # noqa: E402

HEADER = "## Open\n| ID | Problem | File | Severity | Source | Date |\n|---|---|---|---|---|---|\n"
ROW_RACE = "| B-1 | race in cache invalidation | src/a.py:10 | WARNING | review | 2026-10-01 |\n"
ROW_LEAK = "| B-2 | leaking file handle on error | src/a.py:90 | WARNING | review | 2026-10-01 |\n"
ROW_RACE_AGAIN = "| B-7 | race in cache invalidation | src/a.py:12 | WARNING | review | 2026-10-03 |\n"
ROW_RACE_DONE = "| B-1 | race in cache invalidation | src/a.py:10 | WARNING | review | DONE |\n"
ROW_RACE_NOTED = ("| B-1 | race in cache invalidation | FIXED in PR #123 - changed lock order"
                  " | src/a.py:10 | WARNING | review |\n")
SHARED_FP = "fp:77f5d45a1fa9"
DESCRIPTIVE_ID = "B-cache-race"


def with_id(rows: List[zb.Entry]) -> List[zb.Entry]:
    """The rows as if each carried a descriptive id, so their only key is `id:`."""
    return [e._replace(ident=DESCRIPTIVE_ID) for e in rows]


def entries(text: str) -> List[zb.Entry]:
    return list(zb.iter_entries(text))


class DuplicateAnchorTests(unittest.TestCase):
    def test_distinct_table_rows_sharing_a_metadata_signature_are_not_paired(self) -> None:
        # Bug: B-2 (file handle leak) reported as DUPLICATE-OF B-1 (cache race) because both keys
        # hash "a.py|warning review".
        rows = entries(HEADER + ROW_RACE + ROW_LEAK)
        self.assertEqual([e.key for e in rows], [SHARED_FP, SHARED_FP])
        self.assertEqual(zv.duplicate_anchors(rows), {})

    def test_two_table_rows_that_really_are_the_same_still_pair(self) -> None:
        # Bug caught: a guard so strict it stops reporting genuine table-row duplicates.
        rows = entries(HEADER + ROW_RACE + ROW_RACE_AGAIN)
        self.assertEqual(rows[0].key, rows[1].key)
        dups = zv.duplicate_anchors(rows)
        self.assertEqual(list(dups), [rows[1].lineno])
        self.assertEqual(dups[rows[1].lineno][1].lineno, rows[0].lineno)

    def test_distinct_rows_with_a_short_problem_and_a_longer_source_cell_are_not_paired(self) -> None:
        # Bug: the problem cell was chosen as the LONGEST cell, so `code-audit` beat `NPE`/`OOM` and
        # both rows signed alike — the guard went inert and the NPE row was reported DUPLICATE-OF OOM.
        rows = entries(HEADER + "| B-1 | NPE | src/a.py:10 | HIGH | code-audit |\n"
                       "| B-2 | OOM | src/a.py:20 | HIGH | code-audit |\n")
        self.assertEqual(rows[0].key, rows[1].key)
        self.assertEqual(zv.duplicate_anchors(rows), {})

    def test_same_finding_cited_through_an_underscore_path_at_two_lines_still_pairs(self) -> None:
        # Bug: `_` was stripped before the path test, so `src/zuvo_backlog_io.py:10` stopped being a
        # path cell, became the "problem", carried its line number, and the twin at :99 went unseen.
        rows = entries(HEADER + "| B-1 | NPE | src/zuvo_backlog_io.py:10 | HIGH | review |\n"
                       "| B-7 | NPE | src/zuvo_backlog_io.py:99 | HIGH | review |\n")
        self.assertEqual(rows[0].key, rows[1].key)
        self.assertEqual(list(zv.duplicate_anchors(rows)), [rows[1].lineno])

    def test_checkbox_entries_sharing_a_key_are_unaffected(self) -> None:
        # Bug caught: the table guard applied to checkbox entries, whose key ignores the prose
        # before the path by design (it survives resolution notes), so a real duplicate goes unseen.
        text = ("- [ ] fix race in src/a.py when cache drops entries early on reload\n"
                "- [ ] reported again src/a.py when cache drops entries early on reload\n")
        rows = entries(text)
        self.assertEqual(rows[0].key, rows[1].key)
        self.assertEqual(list(zv.duplicate_anchors(rows)), [rows[1].lineno])

    def test_table_rows_sharing_an_id_key_pair_whatever_their_signatures(self) -> None:
        # Bug caught: the signature guard applied to `id:` keys, which are identities, not content.
        rows = with_id(entries(HEADER + ROW_RACE + ROW_LEAK))
        self.assertEqual(list(zv.duplicate_anchors(rows)), [rows[1].lineno])


class ArchiveMatchTests(unittest.TestCase):
    refused: List[str]

    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="dedup-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "src").mkdir()
        (self.tmp / "src" / "a.py").write_text("x = 1\n" * 100, encoding="utf-8")

    def classify(self, open_text: str, done_text: str, ident: bool = False) -> List[zv.Verdict]:
        real = self.tmp / "backlog.md"
        done = self.tmp / "backlog-done.md"
        real.write_text(open_text, encoding="utf-8")
        done.write_text(done_text, encoding="utf-8")
        tree = zv.Tree(root=str(self.tmp), real=str(real), archive=str(done))
        open_rows, done_rows = entries(open_text), entries(done_text)
        if ident:
            open_rows, done_rows = with_id(open_rows), with_id(done_rows)
        verdicts, refused = zv.classify(open_rows, tree, done_rows)
        self.refused = refused
        return verdicts

    def test_archived_twin_behind_a_different_row_with_the_same_fp_is_the_one_cited(self) -> None:
        # Bug: only the FIRST archived entry per key was consulted, so the leak row at :4 hid the
        # cache-race twin at :5 (HEAD cited :4, the guarded lookup found nothing).
        verdicts = self.classify(HEADER + ROW_RACE_AGAIN, HEADER + ROW_LEAK + ROW_RACE_DONE)
        self.assertEqual(self.refused, [])
        self.assertEqual([(v.klass, v.evidence.split(" ")[0]) for v in verdicts],
                         [(zv.CLASS_ARCHIVED, "backlog-done.md:5")])

    def test_open_row_and_archived_row_sharing_an_id_key_match_whatever_their_signatures(self) -> None:
        # Bug caught: the signature guard applied to `id:` keys in the archive lookup.
        verdicts = self.classify(HEADER + ROW_LEAK, HEADER + ROW_RACE_DONE, ident=True)
        self.assertEqual(self.refused, [])
        self.assertEqual([(v.verdict, v.klass) for v in verdicts],
                         [(zv.zl.VERDICT_STALE_FIXED, zv.CLASS_ARCHIVED)])

    def test_open_table_row_is_not_stale_fixed_by_a_different_archived_row_sharing_its_fp(self) -> None:
        # Bug: the open leak finding B-2 is archived as STALE-FIXED because the closed cache-race
        # row B-1 carries the same metadata-only `fp:` key.
        self.assertEqual(entries(HEADER + ROW_RACE_DONE)[0].key, SHARED_FP)
        self.assertEqual(self.classify(HEADER + ROW_LEAK, HEADER + ROW_RACE_DONE), [])
        self.assertEqual(self.refused, [])

    def test_open_table_row_whose_twin_is_archived_is_still_stale_fixed(self) -> None:
        # Bug caught: a guard that stops the archive bridge for a genuinely closed table row.
        verdicts = self.classify(HEADER + ROW_RACE_AGAIN, HEADER + ROW_RACE_DONE)
        self.assertEqual(self.refused, [])
        self.assertEqual([(v.verdict, v.klass) for v in verdicts],
                         [(zv.zl.VERDICT_STALE_FIXED, zv.CLASS_ARCHIVED)])

    def test_archived_twin_with_a_closure_note_cell_still_marks_the_open_row_stale_fixed(self) -> None:
        # Bug: the closure note was the longest cell, so the archived row signed as "in changed lock
        # order" and the STALE-FIXED bridge to its still-open copy broke.
        verdicts = self.classify(HEADER + ROW_RACE_AGAIN, HEADER + ROW_RACE_NOTED)
        self.assertEqual(self.refused, [])
        self.assertEqual([(v.verdict, v.klass) for v in verdicts],
                         [(zv.zl.VERDICT_STALE_FIXED, zv.CLASS_ARCHIVED)])


FIXTURES = Path(ROOT) / "tests" / "fixtures" / "rerank" / "backlog"
QUERY = "zuvo_comment_scan.py:540 — [BUG] f-strings are not understood by the tokenize fallback"
A3 = "B-20261005-CP-R-A3"
LEGACY_TEXT = ("# Backlog\n\n## Open\n\n### B-heading-1 — heading entry: f-string model missing in the"
               " tokenize fallback\n\nprose\n\n| ID | Problem | File |\n|---|---|---|\n"
               "| B-table-1 | table row: f-string model missing | zuvo_comment_scan.py:536 |\n")
# Cleared from these specs' env: the OpenRouter key and key file, the base URLs, the proxies, the opt-in
# bump and every ZUVO_RERANK* / ZUVO_BACKLOG_DUP* setting.
RERANK_KEYS = ("OPENROUTER_API_KEY", "ZUVO_OR_KEY_FILE", "ZUVO_OPENROUTER_BASE_URL",
               "ZUVO_BACKLOG_DEDUP_BUMP", "NO_PROXY", "no_proxy", "HTTP_PROXY", "HTTPS_PROXY", "http_proxy",
               "https_proxy", "ALL_PROXY", "all_proxy")
RERANK_PREFIXES = ("ZUVO_RERANK", "ZUVO_BACKLOG_DUP")


def rerank_free(env: Dict[str, str]) -> Dict[str, str]:
    return {k: v for k, v in env.items() if k not in RERANK_KEYS and not k.startswith(RERANK_PREFIXES)}


class FixtureCase(unittest.TestCase):
    open_text = ""
    done_text = ""

    @classmethod
    def setUpClass(cls) -> None:
        cls.open_text = (FIXTURES / "open.md").read_text(encoding="utf-8").rstrip("\n") + "\n"
        cls.done_text = (FIXTURES / "done.md").read_text(encoding="utf-8").rstrip("\n") + "\n"


class CandidateTests(FixtureCase):
    """`candidates` against the stub: the band each score lands in, and every way it stays silent."""

    def setUp(self) -> None:
        home = tempfile.mkdtemp(prefix="dedup-home-")
        self.addCleanup(shutil.rmtree, home, True)
        env = rerank_free(dict(os.environ))
        env.update(HOME=home, ZUVO_HOME=os.path.join(home, ".zuvo"), NO_PROXY="127.0.0.1",
                   no_proxy="127.0.0.1", OPENROUTER_API_KEY="test-key-not-a-real-credential")
        patcher = mock.patch.dict(os.environ, env, clear=True)
        patcher.start()
        self.addCleanup(patcher.stop)
        rr.reset_budget()
        self.entries = dd.load((self.open_text, self.done_text))

    def stub(self, scores: Optional[Dict[str, float]] = None, **kw: Any) -> RerankStub:
        """A stub stopped when the TEST ends; a subTest loop uses `scored` instead."""
        s = RerankStub(scores, **kw).start()
        self.addCleanup(s.stop)
        os.environ["ZUVO_RERANK_BASE_URL"] = s.base_url
        return s

    def scored(self, scores: Dict[str, float], entries: List[zb.Entry]) -> Optional[dd.Candidate]:
        """`candidates` against a stub that lives for this one call."""
        rr.reset_budget()
        with RerankStub(scores) as s, mock.patch.dict(os.environ, {"ZUVO_RERANK_BASE_URL": s.base_url}):
            return dd.candidates(entries, QUERY)

    BANDS = [
        ("a strong score is reported as weak, or not at all", 0.81, "strong"),
        ("the 0.72 boundary itself falls out of the strong band", 0.72, "strong"),
        ("a weak score is dropped or promoted to strong", 0.60, "weak"),
        ("the 0.55 boundary itself falls out of the weak band", 0.55, "weak"),
        ("a score under 0.55 still names a candidate", 0.54, None),
    ]

    def test_score_bands(self) -> None:
        for name, score, band in self.BANDS:
            with self.subTest(name):
                got = self.scored({"f-string model": score}, self.entries)
                self.assertEqual((got.b_id, got.band) if got else None, (A3, band) if band else None)

    THRESHOLDS: List[Tuple[str, Dict[str, str], float, Optional[str]]] = [
        ("an overridden HIGH is ignored", {"ZUVO_BACKLOG_DUP_HIGH": "0.9"}, 0.81, "weak"),
        ("an overridden pair is ignored", {"ZUVO_BACKLOG_DUP_HIGH": "0.9", "ZUVO_BACKLOG_DUP_LOW": "0.8"},
         0.6, None),
        ("a non-number raises or disables the band", {"ZUVO_BACKLOG_DUP_HIGH": "abc"}, 0.81, "strong"),
        ("nan makes every score fail the strong test", {"ZUVO_BACKLOG_DUP_HIGH": "nan"}, 0.81, "strong"),
        ("inf makes the strong band unreachable", {"ZUVO_BACKLOG_DUP_HIGH": "inf"}, 0.81, "strong"),
        ("a threshold above 1 makes the band unreachable", {"ZUVO_BACKLOG_DUP_HIGH": "1.5"}, 0.81, "strong"),
        ("a negative threshold flags every neighbour", {"ZUVO_BACKLOG_DUP_LOW": "-0.1"}, 0.54, None),
        ("LOW above HIGH turns weak scores strong or drops them", {"ZUVO_BACKLOG_DUP_LOW": "0.8"}, 0.6,
         "weak"),
    ]

    def test_thresholds_from_the_env(self) -> None:
        for name, env, score, band in self.THRESHOLDS:
            with self.subTest(name), mock.patch.dict(os.environ, env):
                got = self.scored({"f-string model": score}, self.entries)
                self.assertEqual((got.b_id, got.band) if got else None, (A3, band) if band else None)

    def test_at_most_fifteen_documents_are_sent(self) -> None:
        # Bug caught: the whole backlog (hundreds of entries) goes to the API on every add.
        stub = self.stub({"f-string model": 0.81})
        extra = "".join(f"- [ ] B-x-{i} tokenize fallback f-strings {i}\n" for i in range(40))
        dd.candidates(dd.load((self.open_text + extra,)), QUERY)
        self.assertEqual(stub.requests, 1)
        docs = stub.bodies[0]["documents"]
        self.assertEqual(len(docs), 15)
        self.assertTrue(any(d.startswith(A3) for d in docs), "the real near-duplicate was not sent")

    def test_the_lite_model_is_asked(self) -> None:
        # Bug caught: the add path calls the dearer knowledge model the thresholds were not calibrated on.
        stub = self.stub({"f-string model": 0.81})
        dd.candidates(self.entries, QUERY)
        self.assertEqual(stub.requests, 1)
        self.assertEqual(stub.bodies[0]["model"], "voyageai/rerank-2.5-lite")

    def test_kill_switch_sends_nothing(self) -> None:
        # Bug caught: ZUVO_RERANK=0 still reaches the network from backlog-add.
        stub = self.stub({"f-string model": 0.81})
        os.environ["ZUVO_RERANK"] = "0"
        self.assertIsNone(dd.candidates(self.entries, QUERY))
        self.assertEqual(stub.requests, 0)

    def test_a_failing_api_names_no_candidate(self) -> None:
        # Bug caught: an HTTP 500 is read as scores, or raises into backlog-add.
        stub = self.stub(status=500, body=b"oops")
        self.assertIsNone(dd.candidates(self.entries, QUERY))
        self.assertEqual(stub.requests, 1)

    def test_without_the_client_modules_no_candidate_and_no_error(self) -> None:
        # Bug caught: a flat copy without zuvo_rerank.py (the backlog suites' mutant dirs) crashes.
        stub = self.stub({"f-string model": 0.81})
        with mock.patch.dict(sys.modules, {"zuvo_rerank": None}):
            self.assertIsNone(dd.candidates(self.entries, QUERY))
        self.assertEqual(stub.requests, 0)

    def test_a_half_copied_client_names_no_candidate_and_no_error(self) -> None:
        # Bug caught: a truncated zuvo_rerank.py raises SyntaxError, which is not an ImportError, so it
        # escapes into backlog-add and the finding is never filed.
        broken = tempfile.mkdtemp(prefix="dedup-broken-")
        self.addCleanup(shutil.rmtree, broken, True)
        Path(broken, "zuvo_rerank.py").write_text("def rerank(:\n", encoding="utf-8")
        stub = self.stub({"f-string model": 0.81})
        with mock.patch.dict(sys.modules), mock.patch.object(sys, "path", [broken, *sys.path]):
            sys.modules.pop("zuvo_rerank", None)
            self.assertIsNone(dd.candidates(self.entries, QUERY))
        self.assertEqual(stub.requests, 0)

    LEGACY_KINDS = [
        ("a hand-written heading entry is never compared", "heading entry", "B-heading-1"),
        ("a table row is never compared, though its id sits in a cell", "table row", "B-table-1"),
    ]

    def test_heading_and_table_entries_are_candidates(self) -> None:
        for name, marker, b_id in self.LEGACY_KINDS:
            with self.subTest(name):
                got = self.scored({marker: 0.81}, dd.load((LEGACY_TEXT,)))
                self.assertEqual((got.b_id, got.band) if got else None, (b_id, "strong"))


class RecheckTests(FixtureCase):
    """The lock-time check: the candidate scored before the lock must still be there, unchanged."""

    def setUp(self) -> None:
        body = next((e.body for e in dd.load((self.open_text,)) if e.ident == A3), None)
        self.assertIsNotNone(body, f"{A3} is not in the fixture")
        self.cand = dd.Candidate(A3, 0.81, "strong", dd.digest(body or ""))
        self.line = next(ln for ln in self.open_text.splitlines(keepends=True) if A3 in ln)

    def test_recheck(self) -> None:
        cases = [
            ("an unchanged candidate loses its flag", self.open_text, True),
            ("a candidate whose id was renamed keeps its flag", self.open_text.replace(A3, "B-gone"), False),
            ("a candidate rewritten between scoring and the lock keeps its flag",
             self.open_text.replace("no f-string model", "a full f-string model now"), False),
        ]
        for name, text, kept in cases:
            with self.subTest(name):
                self.assertEqual(dd.confirm(self.cand, (text,)), self.cand if kept else None)

    def test_a_candidate_archived_before_the_lock_is_still_named(self) -> None:
        # Bug caught: the archiver moving the entry between scoring and the lock drops a flag that is
        # still true (the archived entry is the same finding, and groom reports against the archive).
        moved_open = self.open_text.replace(self.line, "")
        moved_done = self.done_text + self.line.replace("- [ ] ", "- [x] ", 1)
        self.assertNotIn(A3, moved_open)
        self.assertEqual(dd.confirm(self.cand, (moved_open, moved_done)), self.cand)

    def test_only_a_text_that_names_the_candidate_is_parsed_under_the_lock(self) -> None:
        # Bug caught: the lock-time check re-parses the whole archive on every add, inside the budget.
        with mock.patch.object(zb, "iter_entries", wraps=zb.iter_entries) as parse:
            self.assertEqual(dd.confirm(self.cand, (self.open_text, self.done_text)), self.cand)
        self.assertEqual([c.args[0] for c in parse.call_args_list], [self.open_text])

    LEGACY_RECHECK = [
        ("an unchanged heading candidate loses its flag", "B-heading-1", LEGACY_TEXT, True),
        ("an unchanged table candidate loses its flag", "B-table-1", LEGACY_TEXT, True),
        ("a table candidate rewritten before the lock keeps its flag", "B-table-1",
         LEGACY_TEXT.replace("table row: f-string", "table row: full f-string"), False),
    ]

    def test_recheck_heading_and_table_candidates(self) -> None:
        scored = {e.ident or "": e for e in dd.load((LEGACY_TEXT,))}
        for name, b_id, text, kept in self.LEGACY_RECHECK:
            with self.subTest(name):
                self.assertIn(b_id, scored)
                cand = dd.Candidate(b_id, 0.81, "strong", dd.digest(scored[b_id].body))
                self.assertEqual(dd.confirm(cand, (text,)), cand if kept else None)


class RenderFieldTests(unittest.TestCase):
    """`possible-dup-of` in the line backlog-add writes: visible, bumpable, and identity-neutral."""

    F = adm.Finding(cls="BUG", conf=85, source="review", title="off-by-one at the limit", file="src/a.py",
                    line=3)
    D = adm.Decision(route="backlog", reason="", cls="BUG", title="off-by-one at the limit", forced=False)
    FID = "F-0123456789ab"

    def line(self, dup: str = "") -> str:
        return ent.render(self.F, self.D, "B-a-BUG-01234567", self.FID, 1, "[pr:7]", "2026-10-15", dup=dup)

    def test_field_sits_between_ledger_and_date_and_reads_back(self) -> None:
        # Bug caught: the field breaks parse_own, so a flagged entry is never bumped again (legacy).
        line = self.line("B-x-1 (strong)")
        self.assertIn("| ledger: F-0123456789ab | possible-dup-of: B-x-1 (strong) | 2026-10-15 [pr:7]", line)
        own = ent.parse_own(line)
        self.assertEqual((own.dup, own.f_id, own.date, own.tag) if own else None,
                         ("B-x-1 (strong)", self.FID, "2026-10-15", "[pr:7]"))
        self.assertTrue(ent.self_check(line, "B-a-BUG-01234567"))

    def test_field_does_not_change_the_entry_identity(self) -> None:
        # Bug caught: the flag rotates the entry's fp: key, so groom and lookup see a different entry.
        flagged, plain = (zb.entry_key(zb.strip_ident(zb.body_of(x))) for x in (self.line("B-x-1 (weak)"),
                                                                                  self.line()))
        self.assertEqual(flagged, plain)
        self.assertTrue(plain.startswith("fp:"))

    def test_bump_keeps_the_field(self) -> None:
        # Bug caught: a re-sighting rewrites the tail and silently drops the flag groom reports on.
        flagged = self.line("B-x-1 (strong)")
        bumped = ent.bump([flagged + "\n"], "B-a-BUG-01234567", 90, "audit", "2026-10-16")
        want = flagged.replace("source: review | conf: 85 | seen: 1",
                               "source: review, audit | conf: 90 | seen: 2")
        self.assertEqual(bumped, [want.replace("2026-10-15", "2026-10-16") + "\n"])

    def test_a_malformed_field_is_refused(self) -> None:
        # Bug caught: a caller's typo writes a field parse_own cannot read, so the entry is never bumped.
        with self.assertRaises(ValueError):
            self.line("B-x-1 (maybe)")


if __name__ == "__main__":
    unittest.main()
