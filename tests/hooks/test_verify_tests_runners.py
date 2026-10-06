"""Suite, gate, coverage, and typecheck decisions at fake process boundaries."""

import json
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "scripts/zuvo-home/verify-tests"
vt = types.ModuleType("verify_tests_runners")
vt.__file__ = str(SOURCE)
# Compile current bytes so same-size mutants cannot reuse SourceFileLoader's stale .pyc.
exec(compile(SOURCE.read_bytes(), str(SOURCE), "exec"), vt.__dict__)


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
            with (
                mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)),
                mock.patch.object(vt, "run", side_effect=[
                    (0, "OK (3 tests, 4 assertions)"),
                    (0, "OK (2 tests, 3 assertions)"),
                ]) as launch,
            ):
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
                    with (
                        mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(outdir)),
                        mock.patch.object(vt, "run", return_value=(0, "complete")) as launch,
                    ):
                        result = vt.check_coverage({"kind": "vitest", "cwd": root},
                                                   str(prod), [str(spec)], root)
                    self.assertEqual(result.status, status)
                    self.assertTrue(fragment in (result.detail + " ".join(result.gaps)))
                    command = launch.call_args.args[0]
                    self.assertEqual(command[:4], ["npx", "vitest", "run", "src/target.spec.ts"])
                    self.assertIn("--coverage.include=src/target.ts", command)
                    # The project's own thresholds must not turn a complete report into an ERROR.
                    for flag in vt.VITEST_NO_PROJECT_THRESHOLDS:
                        self.assertIn(flag, command)
                    self.assertEqual(launch.call_args.kwargs["cwd"], root)
                    outdir.mkdir(exist_ok=True)
            with (
                mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(outdir)),
                mock.patch.object(vt, "run", return_value=(0, "no report")) as launch,
            ):
                result = vt.check_coverage({"kind": "jest", "cwd": root},
                                           str(prod), [str(spec)], root)
            self.assertEqual(result.status, "SKIP")
            self.assertIn("no coverage-summary.json", result.detail)
            self.assertIn("--coverageThreshold={}", launch.call_args.args[0])

    def test_js_coverage_nonzero_with_partial_report_is_error(self):
        # A partial JSON summary does not make a failed coverage run trustworthy.
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
            with (
                mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(outdir)),
                mock.patch.object(vt, "run", return_value=(1, "FAIL suite red")) as launch,
            ):
                result = vt.check_coverage({"kind": "vitest", "cwd": root},
                                           str(prod), [str(spec)], root)
            self.assertEqual(launch.call_args.kwargs["cwd"], root)
            self.assertEqual(result.status, "ERROR")
            self.assertIn("exited 1", result.detail)
            self.assertTrue(any("not measured" in gap for gap in result.gaps))

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
            with (
                mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)),
                mock.patch.object(vt, "run", return_value=(1, report)) as launch,
            ):
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


def coveragepy_record(covered, statements, branches=None, missing=(), functions=None):
    """One file's record as `coverage json` writes it (7.5+ adds the "functions" regions)."""
    summary = {"covered_lines": covered, "num_statements": statements}
    if branches is not None:
        summary["covered_branches"], summary["num_branches"] = branches
    rec = {"summary": summary, "missing_lines": list(missing)}
    if functions is not None:
        rec["functions"] = {name: {"summary": {"covered_lines": c, "num_statements": n}}
                            for name, (c, n) in functions.items()}
    return rec


class PytestCoverageTests(unittest.TestCase):
    """coverage.py --branch over pytest, scoped to the production file, judged on the shared floors."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.prod = self.root / "pkg/mod.py"
        self.spec = self.root / "tests/test_mod.py"
        for f in (self.prod, self.spec):
            f.parent.mkdir(parents=True, exist_ok=True)
            f.write_text("x = 1\n")
        self.outdir = self.root / "cov-out"
        self.outdir.mkdir()
        self.runner = {"kind": "pytest", "cwd": str(self.root)}

    def measure(self, files=None, run_rc=0, json_rc=0, json_out="Wrote JSON report", probe_rc=0):
        calls = []

        def fake_run(cmd, cwd=None, timeout=900, env=None):
            calls.append((cmd, cwd))
            if cmd[1:3] == ["-c", "import coverage"]:
                return probe_rc, "" if probe_rc == 0 else "ModuleNotFoundError: No module named 'coverage'"
            if cmd[1:4] == ["-m", "coverage", "run"]:
                return run_rc, "1 passed" if run_rc == 0 else "FAILED tests/test_mod.py::test_a"
            if cmd[1:4] == ["-m", "coverage", "json"]:
                if json_rc == 0:
                    Path(cmd[cmd.index("-o") + 1]).write_text(json.dumps({"files": files or {}}))
                return json_rc, json_out
            raise AssertionError("unexpected command %r" % cmd)
        with (
            mock.patch.object(vt.tempfile, "mkdtemp", return_value=str(self.outdir)),
            mock.patch.object(vt, "run", side_effect=fake_run),
        ):
            result = vt.check_coverage(self.runner, str(self.prod), [str(self.spec)], str(self.root))
        return result, calls

    def test_measures_the_production_file_through_pytest_with_branch_coverage(self):
        full = coveragepy_record(10, 10, (4, 4), functions={"": (2, 2), "f": (3, 3), "g": (5, 5)})
        result, calls = self.measure({"pkg/mod.py": full})
        self.assertEqual("PASS", result.status)
        self.assertEqual("statements 100.0%  branches 100.0%  functions 100.0%  lines 100.0%  "
                         "(coverage.py --branch, pytest)", result.detail)
        run_cmd, run_cwd = calls[1]
        self.assertEqual([sys.executable, "-m", "coverage", "run", "--branch",
                          "--data-file=" + str(self.outdir / ".coverage"), "--include=" + str(self.prod),
                          "-m", "pytest", "-q", "tests/test_mod.py"], run_cmd)
        self.assertEqual(str(self.root), run_cwd)
        json_cmd = calls[2][0]
        self.assertIn("--include=" + str(self.prod), json_cmd)
        self.assertFalse(self.outdir.exists(), "the coverage temp dir must be removed")

    def test_each_metric_is_held_to_its_floor_and_uncovered_lines_are_ranges(self):
        rec = coveragepy_record(8, 10, (2, 4), missing=[9, 4, 5, 6],
                                functions={"": (1, 1), "f": (3, 3), "g": (0, 2), "h": (0, 0)})
        result, _calls = self.measure({str(self.prod): rec})   # an absolute key matches too
        self.assertEqual("FAIL", result.status)
        self.assertEqual(["statements 80.0% < 85%", "branches 50.0% < 75%", "functions 50.0% < 90%",
                          "lines 80.0% < 85%", "uncovered lines: 4-6, 9"], result.gaps)

    def test_a_file_without_branches_scores_full_branch_coverage(self):
        rec = coveragepy_record(5, 5, (0, 0), functions={"f": (5, 5)})
        result, _calls = self.measure({"pkg/mod.py": rec})
        self.assertEqual("PASS", result.status)
        self.assertIn("branches 100.0%", result.detail)

    def test_an_old_coveragepy_without_function_regions_is_not_measured_not_zero(self):
        rec = coveragepy_record(10, 10, (4, 4))
        result, _calls = self.measure({"pkg/mod.py": rec})
        self.assertEqual("SKIP", result.status)
        self.assertIn("not measured (functions='Unknown')", result.detail)

    def test_missing_coveragepy_is_a_named_skip_and_nothing_runs(self):
        result, calls = self.measure(probe_rc=1)
        self.assertEqual("SKIP", result.status)
        self.assertIn("coverage.py is not importable by %s" % sys.executable, result.detail)
        self.assertIn("No module named 'coverage'", result.evidence)
        self.assertEqual(1, len(calls))

    def test_a_red_run_is_an_error_and_no_report_is_read(self):
        result, calls = self.measure(run_rc=1)
        self.assertEqual("ERROR", result.status)
        self.assertIn("coverage runner exited 1", result.detail)
        self.assertIn("FAILED tests/test_mod.py::test_a", result.evidence)
        self.assertEqual(["coverage not measured because the test run failed"], result.gaps)
        self.assertEqual(2, len(calls))

    def test_no_data_names_the_subprocess_blind_spot_instead_of_scoring_zero(self):
        result, _calls = self.measure(json_rc=1, json_out="No data to report.")
        self.assertEqual("SKIP", result.status)
        self.assertIn("no coverage data for pkg/mod.py", result.detail)
        self.assertIn("subprocess is not traced", result.detail)
        result, _calls = self.measure(json_rc=2, json_out="Couldn't parse the file")
        self.assertEqual(("SKIP", "coverage json exited 2; no report"), (result.status, result.detail))

    def test_a_report_about_another_file_is_not_attributed(self):
        rec = coveragepy_record(10, 10, (4, 4), functions={"f": (3, 3)})
        result, _calls = self.measure({"pkg/other.py": rec})
        self.assertEqual("SKIP", result.status)
        self.assertIn("no entry for pkg/mod.py in the coverage.py report (1 file(s))", result.detail)


if __name__ == "__main__":
    unittest.main()
