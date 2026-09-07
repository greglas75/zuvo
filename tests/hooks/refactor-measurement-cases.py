"""Executable measurement checks, including ambiguity and error paths."""
from pathlib import Path
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "scripts/zuvo-home/measure-complexity"
PATTERN = re.compile(r"maxfn:(\d+),branches:(\d+),loc:(\d+)\n$")


class MeasurementTests(unittest.TestCase):
    def run_tool(self, *args):
        return subprocess.run([str(TOOL), *map(str, args)], capture_output=True, text=True, timeout=15)

    def measure(self, path):
        result = self.run_tool(path)
        self.assertEqual(result.returncode, 0, result.stderr)
        match = PATTERN.fullmatch(result.stdout)
        self.assertIsNotNone(match, result.stdout)
        if match is None:
            self.fail("missing metrics")
        return tuple(map(int, match.groups()))

    def test_before_after_and_repeatable_results_with_spaced_paths(self):
        with tempfile.TemporaryDirectory(prefix="refactor measurement ") as tmp:
            for suffix, original, reduced in [
                ("ts", "function choose(value) {\n  if (value) {\n    return 1;\n  }\n  return 0;\n}\n",
                 "function choose(value) {\n  return Number(Boolean(value));\n}\n"),
                ("py", "def choose(value):\n    if value:\n        return 1\n    return 0\n",
                 "def choose(value):\n    return int(bool(value))\n"),
            ]:
                with self.subTest(suffix=suffix):
                    path = Path(tmp) / ("input." + suffix)
                    path.write_text(original)
                    before = self.measure(path)
                    self.assertGreater(before[0], 0)
                    self.assertEqual(before[1], 1)
                    self.assertEqual(before, self.measure(path))
                    path.write_text(reduced)
                    after = self.measure(path)
                    self.assertLess(after[0], before[0])
                    self.assertLess(after[1], before[1])

    def test_multiline_python_signature_includes_body(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.py"
            path.write_text("def choose(\n    value,\n):\n    if value:\n        return 1\n    return 0\n")
            self.assertEqual(self.measure(path), (6, 1, 6))

    def test_ambiguous_js_signature_is_not_certified_as_zero(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("function choose(\n  value: boolean,\n) {\n  return value;\n}\n")
            result = self.run_tool(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AST analyzer", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_data_object_is_not_a_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("const options = {\n  first: 1,\n  second: 2,\n  third: 3,\n};\n")
            self.assertEqual(self.measure(path)[0], 0)

    def test_usage_and_missing_source_fail_without_fake_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            for args in [(), (Path(tmp) / "absent.ts",)]:
                result = self.run_tool(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
