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

    def test_typescript_declarations_are_skipped_without_hiding_implementations(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text(
                "interface Service {\n"
                "  find(id: string): Result;\n"
                "}\n"
                "abstract class Base {\n"
                "  abstract save(value: Result): void;\n"
                "}\n"
                "function implemented(value: boolean) {\n"
                "  if (value) return 1;\n"
                "  return 0;\n"
                "}\n"
            )
            maxfn, branches, _ = self.measure(path)
            self.assertEqual(maxfn, 4)
            self.assertEqual(branches, 1)

    def test_js_braces_in_comments_strings_templates_and_regex_do_not_change_extent(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text(
                "const handler = function(value: string) {\n"
                "  // unmatched { must not extend the function\n"
                "  const a = '}';\n"
                "  const b = `template { text }`;\n"
                "  const c = /\\{/;\n"
                "  if (c.test(value)) return a + b;\n"
                "  return value;\n"
                "};\n"
            )
            self.assertEqual(self.measure(path)[:2], (7, 1))

    def test_top_level_control_flow_is_not_counted_as_a_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("if (enabled) {\n  boot();\n}\n")
            self.assertEqual(self.measure(path)[0], 0)

    def test_anonymous_function_expression_is_measured(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("export default function(value) {\n  return value;\n}\n")
            self.assertEqual(self.measure(path)[0], 3)

    def test_complex_function_signature_is_refused_instead_of_silently_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("function choose(value = outer(inner())) {\n  return value;\n}\n")
            result = self.run_tool(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AST analyzer", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_jsx_closing_tag_does_not_mask_later_functions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.tsx"
            path.write_text(
                "const view = <div></div>;\n"
                "function visible(value) {\n"
                "  return value;\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[0], 3)

    def test_regex_after_a_closed_block_does_not_mask_later_functions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.js"
            path.write_text(
                "function first(value) {\n"
                "  if (value) {\n"
                "    use(value);\n"
                "  }\n"
                "  /^\\{/.test(value);\n"
                "}\n"
                "function later(value) {\n"
                "  return value;\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[:2], (6, 1))

    def test_regex_after_arrow_does_not_truncate_enclosing_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.js"
            path.write_text(
                "function outer(value) {\n"
                "  const matches = () => /\\}/.test(value);\n"
                "  if (matches()) return value;\n"
                "  return '';\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[:2], (5, 1))

    def test_deeply_indented_method_is_measured(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text(
                "const service = {\n"
                "        choose(value: boolean) {\n"
                "          if (value) return 1;\n"
                "          return 0;\n"
                "        },\n"
                "};\n"
            )
            self.assertEqual(self.measure(path)[:2], (4, 1))

    def test_generic_method_with_default_call_is_not_silently_skipped(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text(
                "class Service {\n"
                "  choose<T>(value = fallback()) {\n"
                "    if (value) return value as T;\n"
                "    return null;\n"
                "  }\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[:2], (4, 1))

    def test_unsupported_nested_method_parameters_are_refused(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text(
                "class Service {\n"
                "  choose(value = outer(inner())) {\n"
                "    if (value) return value;\n"
                "    return null;\n"
                "  }\n"
                "}\n"
            )
            result = self.run_tool(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AST analyzer", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_division_after_postfix_increment_is_not_masked_as_regex(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.js"
            path.write_text(
                "function ratio(count, max) {\n"
                "  count++;\n"
                "  const value = count++ / max;\n"
                "  if (value) return value;\n"
                "  return 0;\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[:2], (6, 1))

    def test_regex_after_control_condition_does_not_truncate_function(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.js"
            path.write_text(
                "function check(value) {\n"
                "  if (value) /\\}/.test(value);\n"
                "  return value;\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[:2], (4, 1))

    def test_private_method_and_concise_arrow_are_not_silently_omitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.js"
            path.write_text(
                "const double = value => value * 2;\n"
                "class Service {\n"
                "  #choose(value) {\n"
                "    if (value) return double(value);\n"
                "    return 0;\n"
                "  }\n"
                "}\n"
            )
            self.assertEqual(self.measure(path)[:2], (4, 1))

    def test_computed_method_is_refused_instead_of_silently_omitted(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.js"
            path.write_text("class Service {\n  [methodName]() { return 1; }\n}\n")
            result = self.run_tool(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AST analyzer", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_unterminated_literal_is_refused_instead_of_hiding_later_functions(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("const broken = 'oops;\nfunction hidden() { return 1; }\n")
            result = self.run_tool(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("unterminated JS/TS", result.stderr)
            self.assertIn("AST analyzer", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_literal_content_counts_toward_file_size_but_not_branches(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("const text = `first\nif while catch\nthird`;\n")
            self.assertEqual(self.measure(path), (0, 0, 3))

    def test_interpolated_template_is_refused_instead_of_mismeasured(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "example.ts"
            path.write_text("function render(value) {\n  return `value: ${value}`;\n}\n")
            result = self.run_tool(path)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("AST analyzer", result.stderr)
            self.assertEqual(result.stdout, "")

    def test_usage_and_missing_source_fail_without_fake_metrics(self):
        with tempfile.TemporaryDirectory() as tmp:
            for args in [(), (Path(tmp) / "absent.ts",)]:
                result = self.run_tool(*args)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
