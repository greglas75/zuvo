"""Regression tests for extensionless Python helpers in scripts/test-coverage-gate.py."""

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
