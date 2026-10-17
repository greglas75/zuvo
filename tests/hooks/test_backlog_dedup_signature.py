"""scripts/zuvo-home/zuvo_backlog_dedup.py — which cell of a table row is its problem statement, and
that grouping by it stays linear. Every row names the defect it catches. Fixtures are synthetic.
"""

import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path
from typing import List
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
sys.path.insert(0, HOME_DIR)
import zuvo_backlog_dedup as zd  # noqa: E402
import zuvo_backlog_parse as zb  # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402

HEADER = "## Open\n| ID | Problem | File | Severity | Source |\n|---|---|---|---|---|\n"
ROWS = 40


def entries(text: str) -> List[zb.Entry]:
    return list(zb.iter_entries(text))


def one(row: str) -> zb.Entry:
    return entries(HEADER + row)[0]


def same_key_rows(n: int) -> str:
    """`n` different findings in one file whose `fp:` keys all collide on `a.py|high review`."""
    return "".join(f"| B-{i} | problem number {i} | src/a.py:{i} | HIGH | review |\n"
                   for i in range(1, n + 1))


class ProblemCellTests(unittest.TestCase):
    def test_a_ranged_path_cell_is_not_read_as_the_problem(self) -> None:
        # Bug: `src/a.py:10-20` failed the path test, so the range became the "problem".
        self.assertEqual(zd.table_signature(one("| B-1 | src/a.py:10-20 | NPE | review |\n")), "a.py|npe")

    def test_an_emoji_severity_cell_is_not_read_as_the_problem(self) -> None:
        # Bug: `🔴 HIGH` was not recognised as a severity and outranked the problem text.
        self.assertEqual(zd.table_signature(one("| B-1 | 🔴 HIGH | NPE | src/a.py:10 |\n")), "a.py|npe")

    FALLBACKS = [
        ("no path cell: an empty basename, never one borrowed from another cell",
         "| B-1 | NPE on save | HIGH |\n",
         "|npe on save"),
        ("a path only inside the problem text still yields its basename",
         "| B-1 | NPE when src/a.py:10 saves | HIGH |\n", "a.py|npe when src a py 10 saves"),
        ("a metadata-only row: an empty problem, never a metadata cell read as one",
         "| B-1 | src/a.py:10 | HIGH | open |\n", "a.py|"),
    ]

    def test_signature_fallbacks(self) -> None:
        for name, row, sig in self.FALLBACKS:
            with self.subTest(name):
                self.assertEqual(zd.table_signature(one(row)), sig)

    def test_a_non_table_entry_never_signs(self) -> None:
        # Bug caught: a checkbox entry groups with a table row that happens to share its words.
        self.assertEqual(zd.group_signature(entries("## Open\n- [ ] B-1 NPE on save in src/a.py\n")[0]), "")


class LinearGroupingTests(unittest.TestCase):
    def test_duplicate_anchors_signs_each_entry_once(self) -> None:
        # Bug caught: a quadratic scan recomputing signatures against every earlier same-key anchor.
        rows = entries(HEADER + same_key_rows(ROWS))
        with mock.patch.object(zd, "table_signature", wraps=zd.table_signature) as sig:
            self.assertEqual(zv.duplicate_anchors(rows), {})
        self.assertEqual(sig.call_count, ROWS)

    def test_classify_signs_each_open_and_archived_entry_at_most_once(self) -> None:
        # Bug: the archived entry's signature was recomputed for every open row that hit its key.
        tmp = Path(tempfile.mkdtemp(prefix="dedup-sig-")).resolve()
        self.addCleanup(shutil.rmtree, tmp, True)
        (tmp / "src").mkdir()
        (tmp / "src" / "a.py").write_text("x = 1\n" * 100, encoding="utf-8")
        open_text = HEADER + same_key_rows(ROWS)
        done_text = HEADER + "| B-99 | something else entirely | src/a.py:1 | HIGH | review |\n"
        (tmp / "backlog.md").write_text(open_text, encoding="utf-8")
        (tmp / "backlog-done.md").write_text(done_text, encoding="utf-8")
        tree = zv.Tree(root=str(tmp), real=str(tmp / "backlog.md"), archive=str(tmp / "backlog-done.md"))
        with mock.patch.object(zd, "table_signature", wraps=zd.table_signature) as sig:
            zv.classify(entries(open_text), tree, entries(done_text))
        self.assertLessEqual(sig.call_count, ROWS + 1)


if __name__ == "__main__":
    unittest.main()
