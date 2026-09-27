"""Suite, gate, coverage, and typecheck decisions at fake process boundaries."""

import importlib.machinery
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "scripts/zuvo-home/verify-tests"
LOADER = importlib.machinery.SourceFileLoader("verify_tests_runners", str(SOURCE))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
vt = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(vt)


class RunnerTests(unittest.TestCase):
    def test_suite_green_red_and_unlaunched_are_distinct(self):
        with tempfile.TemporaryDirectory() as root:
            spec = Path(root) / "tests/one.spec.ts"
            spec.parent.mkdir()
            spec.write_text("test")
            runner = {"kind": "vitest", "cwd": root}
            cases = (
                (0, "Test Files 1 passed\nTests 12 passed\n", "PASS", "12 tests passed"),
                (1, "FAIL tests/one.spec.ts AssertionError: wrong", "FAIL", "runner exit 1"),
                (127, "[verify-tests] not found: npx", "ERROR", "runner could not run"),
                (124, "[verify-tests] TIMEOUT after 900s", "ERROR", "runner could not run"),
            )
            for rc, output, status, detail in cases:
                with self.subTest(rc=rc):
                    with mock.patch.object(vt, "run", return_value=(rc, output)) as launch:
                        result = vt.check_suite(runner, [str(spec)], root)
                    launch.assert_called_once_with(
                        ["npx", "vitest", "run", "tests/one.spec.ts"], cwd=root)
                    self.assertEqual(result.status, status)
                    self.assertIn(detail, result.detail)
                    if status == "FAIL":
                        self.assertTrue(any("AssertionError" in g for g in result.gaps))
                    if status == "ERROR":
                        self.assertTrue(any("never executed" in g for g in result.gaps))

    def test_suite_zero_executed_tests_is_infrastructure_error(self):
        # Exit 0 without a test count proves no test actually executed.
        with tempfile.TemporaryDirectory() as root:
            spec = Path(root) / "one.spec.ts"
            spec.write_text("test")
            with mock.patch.object(vt, "run", return_value=(0, "")) as launch:
                result = vt.check_suite({"kind": "vitest", "cwd": root}, [str(spec)], root)
            launch.assert_called_once_with(["npx", "vitest", "run", "one.spec.ts"], cwd=root)
            self.assertEqual(result.status, "ERROR")
            self.assertIn("no executed tests", result.detail)
            self.assertTrue(any("nothing" in gap for gap in result.gaps))

    def test_suite_reports_skips_and_jest_count_after_skips(self):
        with tempfile.TemporaryDirectory() as root:
            spec = Path(root) / "one.test.js"
            spec.write_text("test")
            output = "Tests: 35 skipped, 15 passed, 50 total\n"
            with mock.patch.object(vt, "run", return_value=(0, output)) as launch:
                result = vt.check_suite({"kind": "jest", "cwd": root}, [str(spec)], root)
            launch.assert_called_once_with(
                ["npx", "jest", "--runTestsByPath", "one.test.js"], cwd=root)
            self.assertEqual(result.status, "PASS")
            self.assertIn("15 tests passed", result.detail)
            self.assertIn("35 SKIPPED", result.detail)
            self.assertIn("35 of the declared tests are skipped", result.gaps[0])

    def test_codecept_suite_sums_each_spec_and_rejects_path_outside_suite(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            (base / "codeception.yml").write_text("paths:\n  tests: tests\n")
            specs = [base / "tests/unit/A.php", base / "tests/unit/B.php"]
            for spec in specs:
                spec.parent.mkdir(parents=True, exist_ok=True)
                spec.write_text("<?php")
            with mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)):
                with mock.patch.object(vt, "run", side_effect=[
                    (0, "OK (3 tests, 4 assertions)"), (0, "OK (2 tests, 3 assertions)")
                ]) as launch:
                    result = vt.check_suite({"kind": "codecept", "cwd": root},
                                            list(map(str, specs)), root)
            self.assertEqual((result.status, result.detail), ("PASS", "5 tests passed"))
            self.assertEqual(launch.call_count, 2)
            self.assertEqual(launch.call_args_list[0].args[0],
                             ["vendor/bin/codecept", "run", "unit", "tests/unit/A.php", "--no-colors"])
            outside = base / "foreign/A.php"
            outside.parent.mkdir()
            outside.write_text("<?php")
            with mock.patch.object(vt, "run") as launch:
                result = vt.check_suite({"kind": "codecept", "cwd": root}, [str(outside)], root)
            self.assertEqual(result.status, "ERROR")
            self.assertIn("not under the Codeception tests path", result.evidence)
            launch.assert_not_called()

    def test_gate_success_degraded_missing_base_and_validator_failure(self):
        with tempfile.TemporaryDirectory() as root:
            manifest = str(Path(root) / "manifest.json")
            missing = vt.check_gate(manifest, root, None)
            self.assertEqual(missing.status, "ERROR")
            self.assertIn("cannot locate scripts/test-coverage-gate.py", missing.detail)
            cmd = [sys.executable, str(Path(root) / "scripts/test-coverage-gate.py"),
                   "validate", "--manifest", manifest, "--phase", "final", "--repo-root", root]
            for rc, output, status, fragment in (
                (0, "Public entry points: 7/7", "PASS", "7/7"),
                (3, "textual extraction", "DEGRADED", "BLOCKED_DEGRADED"),
                (1, "FAIL: uncovered branch\nUncovered owned rows: 0", "FAIL", "validator exit 1"),
            ):
                with self.subTest(rc=rc):
                    with mock.patch.object(vt, "run", return_value=(rc, output)) as launch:
                        result = vt.check_gate(manifest, root, root)
                    launch.assert_called_once_with(cmd, cwd=root, timeout=300)
                    self.assertEqual(result.status, status)
                    self.assertIn(fragment, result.detail)
                    if rc == 1:
                        self.assertEqual(result.gaps, ["FAIL: uncovered branch"])

    def test_js_coverage_uses_production_entry_and_rejects_aggregate_or_unknown(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            prod = base / "src/target.ts"
            spec = base / "src/target.spec.ts"
            prod.parent.mkdir()
            prod.write_text("export const x = 1")
            spec.write_text("test")
            outdir = base / "coverage-output"
            outdir.mkdir()
            report = outdir / "coverage-summary.json"
            full = {k: {"pct": 100} for k in vt.COVERAGE_THRESHOLDS}
            low = dict(full, branches={"pct": 74})
            cases = (
                ({str(prod): full, str(base / "other.ts"): low, "total": low}, "PASS", "statements 100.0%"),
                ({str(prod): low, "total": full}, "FAIL", "branches 74.0% < 75%"),
                ({str(base / "a.ts"): full, str(base / "b.ts"): full, "total": full},
                 "SKIP", "coverage not attributable"),
                ({str(prod): dict(full, functions={"pct": "Unknown"})}, "SKIP", "not measured"),
            )
            for data, status, fragment in cases:
                with self.subTest(status=status, fragment=fragment):
                    report.write_text(json.dumps(data))
                    with mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(outdir)):
                        with mock.patch.object(vt, "run", return_value=(0, "complete")) as launch:
                            result = vt.check_coverage({"kind": "vitest", "cwd": root},
                                                       str(prod), [str(spec)], root)
                    self.assertEqual(result.status, status)
                    self.assertTrue(fragment in (result.detail + " ".join(result.gaps)))
                    command = launch.call_args.args[0]
                    self.assertEqual(command[:4], ["npx", "vitest", "run", "src/target.spec.ts"])
                    self.assertIn("--coverage.include=src/target.ts", command)
                    self.assertEqual(launch.call_args.kwargs["cwd"], root)
                    outdir.mkdir(exist_ok=True)
            with mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(outdir)):
                with mock.patch.object(vt, "run", return_value=(0, "no report")):
                    result = vt.check_coverage({"kind": "jest", "cwd": root},
                                               str(prod), [str(spec)], root)
            self.assertEqual(result.status, "SKIP")
            self.assertIn("no coverage-summary.json", result.detail)

    def test_js_coverage_nonzero_with_partial_report_current_characterization(self):
        # The coverage run can leave a JSON summary before failing. Pin the current
        # false green before changing the production check.
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            prod = base / "src/target.ts"
            spec = base / "src/target.spec.ts"
            prod.parent.mkdir()
            prod.write_text("export const x = 1")
            spec.write_text("test")
            outdir = base / "coverage-output"
            outdir.mkdir()
            full = {key: {"pct": 100} for key in vt.COVERAGE_THRESHOLDS}
            (outdir / "coverage-summary.json").write_text(json.dumps({str(prod): full}))
            with mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(outdir)):
                with mock.patch.object(vt, "run", return_value=(1, "FAIL suite red")) as launch:
                    result = vt.check_coverage({"kind": "vitest", "cwd": root},
                                               str(prod), [str(spec)], root)
            self.assertEqual(launch.call_args.kwargs["cwd"], root)
            self.assertEqual(result.status, "PASS")

    def test_codecept_nonzero_with_stale_coverage_is_error(self):
        # A partial report must not override the failed coverage process.
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            (base / "codeception.yml").write_text("paths:\n  tests: tests\n")
            prod = base / "src/Foo.php"
            spec = base / "tests/unit/FooTest.php"
            prod.parent.mkdir()
            spec.parent.mkdir(parents=True)
            prod.write_text("<?php")
            spec.write_text("<?php")
            report = "ERROR: a test failed\n\\App\\Foo\n  Methods: 100.00% (2/2)  Lines: 100.00% (12/12)\n"
            with mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)):
                with mock.patch.object(vt, "run", return_value=(1, report)) as launch:
                    result = vt.check_coverage({"kind": "codecept", "cwd": root},
                                               str(prod), [str(spec)], root)
            self.assertEqual(launch.call_args.kwargs["cwd"], root)
            self.assertIn("coverage: include: [src/Foo.php]", launch.call_args.args[0])
            self.assertEqual(result.status, "ERROR")
            self.assertIn("exited 1", result.detail)
            self.assertTrue(any("not measured" in gap for gap in result.gaps))

    def test_typecheck_only_written_spec_errors_are_gaps(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            (base / "tsconfig.json").write_text("{}")
            (base / "node_modules/.bin").mkdir(parents=True)
            (base / "node_modules/.bin/tsc").write_text("")
            prod = base / "src/target.ts"
            spec = base / "src/target.spec.ts"
            prod.parent.mkdir()
            prod.write_text("x")
            spec.write_text("x")
            output = ("src/target.spec.ts(5,2): error TS1234: spec broken\n"
                      "src/target.ts(8,2): error TS2345: inherited defect\n"
                      "other.ts(2,2): error TS3333: elsewhere\n")
            with mock.patch.object(vt, "run", return_value=(1, output)) as launch:
                result = vt.check_typecheck({"kind": "vitest", "cwd": root}, str(prod),
                                            [str(spec)], root, str(base / "manifest.json"))
            self.assertEqual(result.status, "FAIL")
            self.assertEqual(result.gaps, ["src/target.spec.ts:5 TS1234: spec broken"])
            self.assertIn("pre-existing in the production file", result.detail)
            self.assertIn("inherited defect", result.evidence)
            self.assertEqual(launch.call_args.args[0][:5],
                             ["npx", "tsc", "--noEmit", "-p", "tsconfig.json"])
            with mock.patch.object(vt, "run", return_value=(124, "timeout")):
                result = vt.check_typecheck({"kind": "vitest", "cwd": root}, str(prod),
                                            [str(spec)], root, str(base / "manifest.json"))
            self.assertEqual((result.status, result.detail), ("ERROR", "error: tsc timed out"))
            with mock.patch.object(vt, "run", return_value=(1, output.splitlines()[1])):
                result = vt.check_typecheck({"kind": "vitest", "cwd": root}, str(prod),
                                            [str(spec)], root, str(base / "manifest.json"))
            self.assertEqual(result.status, "PASS")
            self.assertEqual(result.gaps, [])


if __name__ == "__main__":
    unittest.main()
