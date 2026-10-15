"""scripts/zuvo-home/zuvo_backlog_verdicts.py — table rows must not be paired or archived through a
signature made only of metadata columns.

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
from typing import List

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
sys.path.insert(0, HOME_DIR)
import zuvo_backlog_parse as zb  # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402

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


if __name__ == "__main__":
    unittest.main()
