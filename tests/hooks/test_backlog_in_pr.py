"""Unit and integration invariants for the IN-PR open-backlog convention (RD-2176).

An open backlog entry fixed on an unmerged PR branch stays open (`- [ ]` / `OPEN`) with an
`IN-PR` stamp (`[IN-PR #N branch @ sha7, YYYY-MM-DD]`, heading `— IN-PR #N @sha7`, or table
`IN-PR #N`) rather than `- [x]`, `- [~]`, or closure words (`FIXED`/`DONE`/`RESOLVED`/`CLOSED`),
so parser, lookup, archive, verify, and grooming pre-pass continue tracking it as OPEN until merge.
"""

import glob
import os
import re
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from typing import Dict

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
HOME_DIR = os.path.join(ROOT, "scripts", "zuvo-home")
if HOME_DIR not in sys.path:
    sys.path.insert(0, HOME_DIR)

import zuvo_backlog_parse as zb  # noqa: E402
import zuvo_backlog_verdicts as zv  # noqa: E402

ARCHIVER = os.path.join(HOME_DIR, "backlog-archive.py")


def _clean_git_env(root_parent: Path) -> Dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    env["GIT_CEILING_DIRECTORIES"] = str(root_parent)
    return env


class BacklogInPrTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp(prefix="inpr-")).resolve()
        self.addCleanup(shutil.rmtree, self.tmp, True)
        (self.tmp / "memory").mkdir()
        (self.tmp / "src").mkdir()
        (self.tmp / "src" / "foo.ts").write_text("export const x = 1;\n", encoding="utf-8")
        (self.tmp / "src" / "bar.ts").write_text("export const y = 2;\n", encoding="utf-8")
        (self.tmp / "src" / "done.ts").write_text("export const z = 3;\n", encoding="utf-8")

    def _run_archiver(
        self, subcmd: str, *args: str, heading_archive: bool = False
    ) -> subprocess.CompletedProcess:
        env = _clean_git_env(self.tmp.parent)
        if heading_archive:
            env["ZUVO_BACKLOG_HEADING_ARCHIVE"] = "1"
        else:
            env.pop("ZUVO_BACKLOG_HEADING_ARCHIVE", None)
        return subprocess.run(
            [sys.executable, ARCHIVER, subcmd, "--repo", str(self.tmp), *args],
            env=env,
            capture_output=True,
            text=True,
            timeout=15,
        )

    def test_in_pr_dialects_parse_as_open_without_resolution_marker(self) -> None:
        checkbox = (
            "- [ ] **B-inpr-guard** [P2][CQ][conf 85] — src/foo.ts:1 missing guard "
            "[IN-PR #2201 feat/foo @ abc1234, 2026-11-15]"
        )
        heading = "## B-20261115-FOO — OPEN (P2) — IN-PR #2201 @abc1234"
        table = (
            "| B-inpr-tbl | IN-PR #2201 | src/bar.ts|CQ1|x | src/bar.ts:1 | "
            "missing check | high | CQ | zuvo:review | 1 | 2026-11-15 |"
        )
        doc = "\n".join([checkbox, "", heading, "- file: src/foo.ts:1", "", table, ""])
        all_kinds = (zb.KIND_CHECKBOX, zb.KIND_BULLET, zb.KIND_TABLE, zb.KIND_HEADING)
        entries = list(zb.iter_entries(doc, kinds=all_kinds))

        by_key = {e.key: e for e in entries}
        self.assertIn("id:b-inpr-guard", by_key)
        self.assertIn("id:b-20261115-foo", by_key)

        cb_entry = by_key["id:b-inpr-guard"]
        self.assertEqual(cb_entry.status, "open")
        self.assertEqual(cb_entry.ident, "B-inpr-guard")
        self.assertFalse(zb.has_resolution_marker(cb_entry.body))

        hd_entry = by_key["id:b-20261115-foo"]
        self.assertEqual(hd_entry.status, "open")
        self.assertEqual(hd_entry.ident, "B-20261115-FOO")
        self.assertEqual(zb.heading_resolution_pos(hd_entry.body), -1)

        tbl_entries = [e for e in entries if e.kind == zb.KIND_TABLE]
        self.assertEqual(len(tbl_entries), 1)
        self.assertEqual(tbl_entries[0].status, "open")
        self.assertFalse(zb.has_resolution_marker(tbl_entries[0].body))

    def test_lookup_verify_and_archive_keep_in_pr_open_until_merged(self) -> None:
        cb_open = (
            "- [ ] **B-inpr-guard** [P2][CQ][conf 85] — src/foo.ts:1 missing guard "
            "[IN-PR #2201 feat/foo @ abc1234, 2026-11-15]"
        )
        hd_open = "## B-20261115-FOO — OPEN (P2) — IN-PR #2201 @abc1234"
        tbl_open = (
            "| B-inpr-tbl | IN-PR #2201 | src/bar.ts|CQ1|x | src/bar.ts:1 | "
            "missing check | high | CQ | zuvo:review | 1 | 2026-11-15 |"
        )
        cb_merged = (
            "- [x] **B-merged-done** [P3][CQ][conf 80] — src/done.ts:1 stale helper "
            "[FIXED def5678 — PR #2200 merged 2026-11-15]"
        )
        backlog_path = self.tmp / "memory" / "backlog.md"
        archive_path = self.tmp / "memory" / "backlog-done.md"
        backlog_path.write_text(
            "\n".join(
                ["# Backlog", "", cb_open, cb_merged, "", hd_open, "- file: src/foo.ts:1", "", tbl_open, ""],
            ),
            encoding="utf-8",
        )

        res_cb = self._run_archiver("lookup", "--", "B-inpr-guard")
        self.assertEqual(res_cb.returncode, 10, res_cb.stdout + res_cb.stderr)
        self.assertTrue(res_cb.stdout.startswith("OPEN id:b-inpr-guard "), res_cb.stdout)

        res_hd = self._run_archiver("lookup", "--", "B-20261115-FOO")
        self.assertEqual(res_hd.returncode, 10, res_hd.stdout + res_hd.stderr)
        self.assertTrue(res_hd.stdout.startswith("OPEN id:b-20261115-foo "), res_hd.stdout)

        res_verify = self._run_archiver("verify")
        self.assertEqual(res_verify.returncode, 0, res_verify.stdout + res_verify.stderr)

        res_arch = self._run_archiver("archive", heading_archive=True)
        self.assertEqual(res_arch.returncode, 0, res_arch.stdout + res_arch.stderr)

        remaining = backlog_path.read_text(encoding="utf-8")
        archived = archive_path.read_text(encoding="utf-8")
        self.assertIn("B-inpr-guard", remaining)
        self.assertIn("B-20261115-FOO", remaining)
        self.assertIn("B-inpr-tbl", remaining)
        self.assertNotIn("B-merged-done", remaining)
        self.assertIn("B-merged-done", archived)

    def test_grooming_verdicts_leave_in_pr_entries_open_with_b_id(self) -> None:
        cb_open = (
            "- [ ] **B-inpr-guard** [P2][CQ][conf 85] — src/foo.ts:1 missing guard "
            "[IN-PR #2201 feat/foo @ abc1234, 2026-11-15]"
        )
        hd_open = "## B-20261115-FOO — OPEN (P2) — IN-PR #2201 @abc1234"
        cb_closed = (
            "- [x] **B-closed-done** [P3][CQ][conf 80] — src/bar.ts:1 dead import "
            "[FIXED 1234567 — PR #2199 merged 2026-11-14]"
        )
        doc = "\n".join([cb_open, hd_open, cb_closed, ""])
        backlog_path = self.tmp / "memory" / "backlog.md"
        archive_path = self.tmp / "memory" / "backlog-done.md"
        backlog_path.write_text(doc, encoding="utf-8")

        entries = list(zb.iter_entries(doc, kinds=(zb.KIND_CHECKBOX, zb.KIND_HEADING)))
        tree = zv.Tree(root=str(self.tmp), real=str(backlog_path), archive=str(archive_path))
        verdicts, refused = zv.classify(entries, tree, [])
        self.assertEqual(refused, [])
        verdict_ids = {v.entry.ident for v in verdicts}
        self.assertNotIn("B-inpr-guard", verdict_ids)
        self.assertNotIn("B-20261115-FOO", verdict_ids)
        self.assertEqual(verdict_ids, {"B-closed-done"})

    def test_no_markdown_instructs_tilde_checkbox_state(self) -> None:
        tilde_re = re.compile(r"-\s*\[~\]")
        allow_prohibition = re.compile(r"\b(?:never|not|forbidden|do not)\b", re.I)
        violations = []
        for pattern in (
            "skills/*/SKILL.md",
            "skills/*/agents/*.md",
            "skills/*/references/*.md",
            "shared/includes/*.md",
        ):
            for path in sorted(glob.glob(os.path.join(ROOT, pattern))):
                rel = os.path.relpath(path, ROOT)
                for lineno, line in enumerate(Path(path).read_text(encoding="utf-8").splitlines(), 1):
                    if tilde_re.search(line) and not allow_prohibition.search(line):
                        violations.append(f"{rel}:{lineno}: {line.strip()}")
        self.assertEqual(violations, [], "Found non-prohibition `- [~]` checkbox instruction")


if __name__ == "__main__":
    unittest.main()
