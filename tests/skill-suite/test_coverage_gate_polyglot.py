"""Regression tests for extensionless Python helpers in scripts/test-coverage-gate.py."""

import contextlib
import io
import os
import runpy
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
GATE = runpy.run_path(str(ROOT / "scripts/test-coverage-gate.py"))


class PolyglotLanguageTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.source = Path(self.tmp.name) / "verify-tests"

    def test_extensionless_polyglot_has_python_symbols_and_boundaries(self):
        self.source.write_text(
            "#!/bin/sh\n"
            "# Polyglot sh/python header.\n"
            "''''exec \"$(command -v python3 || echo python3)\" \"$0\" \"$@\" # '''\n"
            "def decide(value):\n"
            "    if value < 0:\n"
            "        raise ValueError('negative')\n"
            "    return value + 1\n",
            encoding="utf-8",
        )
        self.assertEqual("python", GATE["detect_language"](str(self.source)))
        symbols, mode = GATE["extract"](str(self.source))
        self.assertEqual("ast", mode)
        self.assertEqual(["decide"], [item["symbol"] for item in symbols])
        self.assertIn("<", [item.get("op") for item in GATE["boundaries"](str(self.source))])

    def test_polyglot_line_after_a_comment_block_is_python(self):
        # The real helpers' shape: shebang, a comment block explaining the trick, THEN the exec
        # line (line 8 in scripts/zuvo-home/backlog). A 3-line sniff called it unsupported.
        self.source.write_text(
            "#!/bin/sh\n" + "# why the polyglot exists\n" * 6
            + "''''exec \"$(command -v python3 || echo python3)\" \"$0\" \"$@\" # '''\n"
            "def decide(value):\n    return value\n",
            encoding="utf-8",
        )
        self.assertEqual("python", GATE["detect_language"](str(self.source)))

    def test_exec_line_after_the_header_ended_is_not_a_polyglot(self):
        # The header ends at the first non-comment line; an exec line further down is shell text.
        self.source.write_text(
            "#!/bin/sh\n# comment\necho hi\n''''exec python3 \"$0\" # '''\n",
            encoding="utf-8",
        )
        self.assertIsNone(GATE["detect_language"](str(self.source)))

    def test_exec_line_on_the_last_line_read_is_found_and_one_past_it_is_not(self):
        bound = GATE["POLYGLOT_HEADER_LINES"]
        exec_line = "''''exec \"$(command -v python3 || echo python3)\" \"$0\" \"$@\" # '''\n"
        for comments, want, warned in ((bound - 2, "python", False), (bound - 1, None, True)):
            with self.subTest(exec_on_line=comments + 2):
                self.source.write_text("#!/bin/sh\n" + "# comment\n" * comments + exec_line, encoding="utf-8")
                err = io.StringIO()
                with contextlib.redirect_stderr(err):
                    self.assertEqual(want, GATE["detect_language"](str(self.source)))
                # Running out of read lines inside the comment block is said, not swallowed.
                self.assertEqual(warned, f"shell header longer than {bound} lines" in err.getvalue())

    def test_unreadable_header_is_unsupported_not_an_exception(self):
        self.source.write_text("#!/usr/bin/env python3\n", encoding="utf-8")
        os.chmod(self.source, 0)
        self.addCleanup(os.chmod, self.source, 0o600)
        if os.access(self.source, os.R_OK):
            self.skipTest("this account can read a mode-000 file (root)")
        err = io.StringIO()
        with contextlib.redirect_stderr(err):
            self.assertIsNone(GATE["detect_language"](str(self.source)))
        self.assertIn("cannot read the header to detect the language", err.getvalue())

    def test_repo_helpers_with_a_late_exec_line_are_python(self):
        for name in ("backlog", "verify-audit", "compute-preload"):
            with self.subTest(name=name):
                helper = ROOT / "scripts/zuvo-home" / name
                self.assertTrue(helper.is_file(), f"{helper} moved: update this list")
                self.assertEqual("python", GATE["detect_language"](str(helper)))

    def test_header_variants_that_are_still_a_polyglot(self):
        exec_line = "''''exec \"$(command -v python3 || echo python3)\" \"$0\" \"$@\" # '''\n"
        cases = {
            "comment longer than one read": "#!/bin/sh\n# " + "x" * 2000 + "\n" + exec_line,
            "blank line in the header": "#!/bin/sh\n# note\n\n" + exec_line,
            "env sh shebang": "#!/usr/bin/env sh\n# note\n" + exec_line,
            "bash shebang": "#!/bin/bash\n" + exec_line,
            "tab after exec": "#!/bin/sh\n" + exec_line.replace("''''exec ", "''''exec\t"),
            "BOM before the shebang": "﻿#!/bin/sh\n" + exec_line,
        }
        for name, text in cases.items():
            with self.subTest(name):
                self.source.write_text(text, encoding="utf-8")
                self.assertEqual("python", GATE["detect_language"](str(self.source)))

    def test_bom_before_a_python_shebang_is_python(self):
        self.source.write_text("﻿#!/usr/bin/env python3\ndef answer():\n    return 42\n", encoding="utf-8")
        self.assertEqual("python", GATE["detect_language"](str(self.source)))

    def test_a_minified_single_line_file_is_not_read_to_its_end(self):
        # The overlong-line drain is bounded: a 1 MiB one-line file is classified, not slurped.
        self.source.write_text("#!/bin/sh\n" + "y" * (1 << 20) + "\n", encoding="utf-8")
        self.assertIsNone(GATE["detect_language"](str(self.source)))

    def test_python_shebang_without_extension_is_python(self):
        self.source.write_text("#!/usr/bin/env python3\ndef answer():\n    return 42\n")
        self.assertEqual("python", GATE["detect_language"](str(self.source)))

    def test_ordinary_shell_script_stays_unsupported(self):
        self.source.write_text("#!/bin/sh\nprintf shell-only\\n\n")
        self.assertIsNone(GATE["detect_language"](str(self.source)))

    def test_missing_file_stays_unsupported(self):
        self.assertIsNone(GATE["detect_language"](str(self.source)))

    def test_python_inventory_excludes_private_functions(self):
        source = self.source.with_suffix(".py")
        source.write_text(
            "def public():\n    return 1\n"
            "def _internal():\n    return 2\n",
            encoding="utf-8",
        )
        symbols, mode = GATE["extract"](str(source))
        self.assertEqual("ast", mode)
        self.assertEqual(["public"], [item["symbol"] for item in symbols])

    def test_scaffold_rejects_a_polyglot_without_public_surface(self):
        self.source.write_text(
            "#!/bin/sh\n"
            "''''exec \"$(command -v python3 || echo python3)\" \"$0\" \"$@\" # '''\n"
            "def _internal():\n    return 2\n",
            encoding="utf-8",
        )
        with self.assertRaisesRegex(GATE["SystemExit2"], "no public symbols"):
            GATE["scaffold"](
                str(self.source), [], self.tmp.name,
                str(Path(self.tmp.name) / "inventory.json"),
            )


if __name__ == "__main__":
    unittest.main()
