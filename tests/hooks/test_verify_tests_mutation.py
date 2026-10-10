"""Native mutation evidence, survivor gaps, and production restoration."""

import contextlib
import io
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import sys
import tempfile
import types
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "scripts/zuvo-home/verify-tests"
vt = types.ModuleType("verify_tests_mutation")
vt.__file__ = str(SOURCE)
# Compile current bytes so same-size mutants cannot reuse SourceFileLoader's stale .pyc.
exec(compile(SOURCE.read_bytes(), str(SOURCE), "exec"), vt.__dict__)


class MutationTests(unittest.TestCase):
    @unittest.skipUnless(os.name == "posix", "signal startup race requires POSIX")
    def test_signal_during_spawn_waits_until_child_is_registered(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            prod = base / "target.ts"
            spec = base / "target.spec.ts"
            pristine = "export const target = true;\n"
            prod.write_text(pristine)
            spec.write_text("test")

            class Child:
                pid = 54321

                def wait(self, timeout=None):
                    return 0

            child = Child()
            deliveries = []

            def fake_popen(*_args, **_kwargs):
                self.assertTrue(vt._MUTATION_SPAWNING)
                prod.write_text("stryMutAct_ active\n")
                signal.getsignal(signal.SIGTERM)(signal.SIGTERM, None)
                self.assertEqual(vt._DEFERRED_MUTATION_SIGNAL, signal.SIGTERM)
                self.assertIn("stryMutAct_", prod.read_text())
                return child

            def fake_kill(_pid, signum):
                deliveries.append((signum, vt._ACTIVE_MUTATION_CHILD is child,
                                   vt._MUTATION_SPAWNING))
                if len(deliveries) == 1:
                    signal.getsignal(signum)(signum, None)
                else:
                    raise SystemExit(signum)

            try:
                with (
                    mock.patch.object(vt, "ensure_stryker", return_value=(root, "project")),
                    mock.patch.object(vt.subprocess, "Popen", side_effect=fake_popen),
                    mock.patch.object(vt.os, "kill", side_effect=fake_kill),
                    mock.patch.object(vt.os, "killpg") as kill_group,
                    self.assertRaises(SystemExit),
                ):
                    vt.check_mutation(
                        {"kind": "vitest", "cwd": root}, str(prod),
                        [str(spec)], root, 5, False,
                    )
                kill_group.assert_called_once_with(child.pid, signal.SIGTERM)
                self.assertEqual(deliveries[0], (signal.SIGTERM, True, False))
                self.assertEqual(prod.read_text(), pristine)
            finally:
                vt._ACTIVE_MUTATION_CHILD = None
                vt._MUTATION_SPAWNING = False
                vt._DEFERRED_MUTATION_SIGNAL = None

    @unittest.skipUnless(os.name == "posix", "process-group signals require POSIX")
    def test_mutation_child_cleanup_signals_its_own_group_and_reaps(self):
        class Child:
            pid = 4321

            def __init__(self, timeout_once=False):
                self.waits = []
                self.timeout_once = timeout_once

            def wait(self, timeout=None):
                self.waits.append(timeout)
                if self.timeout_once:
                    self.timeout_once = False
                    raise subprocess.TimeoutExpired(["npx", "stryker"], timeout)
                return 0

        for timeout_once, expected_signals, expected_waits in (
            (False, [signal.SIGTERM], [3]),
            (True, [signal.SIGTERM, signal.SIGKILL], [3, 5]),
        ):
            with self.subTest(timeout_once=timeout_once):
                child = Child(timeout_once)
                with mock.patch.object(vt.os, "killpg") as kill_group:
                    vt._stop_mutation_child(child)
                self.assertEqual(
                    [call.args for call in kill_group.call_args_list],
                    [(child.pid, sig) for sig in expected_signals],
                )
                self.assertEqual(child.waits, expected_waits)

    def test_stop_child_tolerates_eperm_from_an_exited_group_leader(self):
        # macOS raises PermissionError (EPERM), not ProcessLookupError, when killpg targets an
        # exited-but-unreaped group leader. The caller's next step is restoring the mutated
        # source, so the reaper must not raise for a group that is already gone.
        class Child:
            pid = 43210

            def __init__(self):
                self.waits = []

            def wait(self, timeout=None):
                self.waits.append(timeout)
                return 0

        child = Child()
        with mock.patch.object(vt.os, "killpg", side_effect=PermissionError(1, "EPERM")):
            vt._stop_mutation_child(child)
        self.assertEqual(child.waits, [3])

    def test_stop_child_final_wait_is_bounded(self):
        # An unkillable child must not hang the reaper forever before the source is restored.
        class Child:
            pid = 43211

            def __init__(self):
                self.waits = []

            def wait(self, timeout=None):
                self.waits.append(timeout)
                raise subprocess.TimeoutExpired(["npx", "stryker"], timeout)

        child = Child()
        with mock.patch.object(vt.os, "killpg"):
            vt._stop_mutation_child(child)
        self.assertEqual(child.waits, [3, 5])

    def test_missing_stryker_requires_both_packages_and_never_launches(self):
        with tempfile.TemporaryDirectory() as root:
            runner = {"kind": "vitest", "cwd": root}
            prod = str(Path(root) / "target.ts")
            spec = str(Path(root) / "target.spec.ts")
            Path(prod).write_text("export const x = 1")
            Path(spec).write_text("test")
            with mock.patch.object(vt, "run") as launch:
                result = vt.check_mutation(runner, prod, [spec], root, 5, False)
            self.assertEqual(result.status, "SKIP")
            self.assertIn("StrykerJS not installed", result.detail)
            launch.assert_not_called()
            core = Path(root) / "node_modules/@stryker-mutator/core"
            core.mkdir(parents=True)
            with mock.patch.object(vt, "run") as launch:
                result = vt.check_mutation(runner, prod, [spec], root, 5, False)
            self.assertEqual(result.status, "SKIP")
            launch.assert_not_called()
            (Path(root) / "node_modules/@stryker-mutator/vitest-runner").mkdir()
            self.assertEqual(vt.ensure_stryker(runner, root, False), (root, "project"))

    def test_stryker_install_error_and_peer_retry(self):
        with tempfile.TemporaryDirectory() as root:
            runner = {"kind": "jest", "cwd": root}
            with mock.patch.object(vt, "run", side_effect=[(1, "ERESOLVE peer graph"),
                                                      (1, "still broken")]) as launch:
                node_root, note = vt.ensure_stryker(runner, root, True)
            self.assertIsNone(node_root)
            self.assertIn("install failed (exit 1)", note)
            self.assertEqual(launch.call_count, 2)
            self.assertEqual(launch.call_args_list[0].kwargs["cwd"], root)
            self.assertEqual(launch.call_args_list[1].args[0][5], "--legacy-peer-deps")

    def test_survivors_rank_no_coverage_and_zero_decided_never_green(self):
        with tempfile.TemporaryDirectory() as root:
            prod = str(Path(root) / "target.ts")
            Path(prod).write_text("const x = 1")
            manifest = str(Path(root) / "manifest.json")
            empty = vt.Result("mutation")
            vt.record_survivors(empty, [], 5, prod, None, manifest, root, decided=0,
                                coverage_analysis="perTest")
            self.assertEqual(empty.status, "FAIL")
            self.assertTrue(any("NO mutants with a verdict" in g for g in empty.gaps))
            green = vt.Result("mutation")
            vt.record_survivors(green, [], 5, prod, None, manifest, root, decided=2,
                                coverage_analysis="perTest")
            self.assertEqual((green.status, green.gaps), ("PASS", []))
            majority = vt.Result("mutation")
            vt.record_survivors(majority, [], 5, prod, None, manifest, root,
                                decided=2, undecided=3, coverage_analysis="perTest")
            self.assertEqual(majority.status, "FAIL")
            self.assertIn("3 of 5 mutants produced NO verdict", majority.gaps[0])
            survivors = [
                {"status": "Survived", "location": {"start": {"line": 4}},
                 "mutatorName": "Arithmetic", "replacement": "x + 1"},
                {"status": "NoCoverage", "location": {"start": {"line": 10}},
                 "mutatorName": "Boolean", "replacement": "false"},
            ]
            result = vt.Result("mutation")
            vt.record_survivors(result, survivors, 1, prod, None, manifest, root, decided=2,
                                coverage_analysis="perTest")
            self.assertEqual(result.status, "FAIL")
            self.assertIn("NoCoverage L10 Boolean", result.gaps[0])
            self.assertIn("1 more survivors", result.gaps[1])
            report = json.loads(Path(manifest + ".survivors.json").read_text())
            self.assertEqual(report["count"], 2)
            self.assertEqual(report["survivors"][0]["line"], 10)

    def test_atomic_restore_preserves_bytes_mode_and_failure_keeps_destination(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "script.sh"
            path.write_bytes(b"mutated")
            path.chmod(0o755)
            self.assertTrue(vt.restore_file(str(path), b"original\n"))
            self.assertEqual(path.read_bytes(), b"original\n")
            self.assertTrue(os.access(path, os.X_OK))
            self.assertFalse(Path(str(path) + ".zuvo-restore-tmp").exists())
            path.write_bytes(b"still here")
            with mock.patch.object(vt.os, "replace", side_effect=OSError("disk full")):
                self.assertFalse(vt.restore_file(str(path), b"replacement"))
            self.assertEqual(path.read_bytes(), b"still here")
            self.assertFalse(Path(str(path) + ".zuvo-restore-tmp").exists())
            target = Path(root) / "real.sh"
            target.write_bytes(b"mutated")
            link = Path(root) / "link.sh"
            link.symlink_to(target)
            self.assertTrue(vt.restore_file(str(link), b"restored"))
            self.assertTrue(link.is_symlink())
            self.assertEqual(target.read_bytes(), b"restored")

    def test_stryker_report_zero_survivor_timeout_and_restoration(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            prod = base / "src/target.ts"
            spec = base / "src/target.spec.ts"
            prod.parent.mkdir()
            original = b"export const target = true;\n"
            prod.write_bytes(original)
            spec.write_text("test")
            manifest = str(base / "manifest.json")
            runner = {"kind": "vitest", "cwd": root}

            def drive(report, exit_code=0):
                def fake_run(cmd, cwd=None, timeout=None):
                    self.assertEqual(cmd[:3], ["npx", "stryker", "run"])
                    self.assertEqual(cwd, root)
                    config = json.loads((base / cmd[3]).read_text())
                    self.assertEqual(config["mutate"], ["src/target.ts"])
                    self.assertEqual(config["testFiles"], ["src/target.spec.ts"])
                    self.assertTrue(config["inPlace"])
                    prod.write_bytes(b"stryMutAct_ corrupted")
                    output = Path(config["jsonReporter"]["fileName"])
                    output.parent.mkdir()
                    if report is not None:
                        output.write_text(json.dumps(report))
                    return exit_code, "runner finished"
                with (
                    mock.patch.object(vt, "ensure_stryker", return_value=(root, "project")),
                    mock.patch.object(vt, "_run_mutation", side_effect=fake_run) as launch,
                ):
                    result = vt.check_mutation(runner, str(prod), [str(spec)], root, 5,
                                               False, None, manifest)
                launch.assert_called_once()
                self.assertEqual(prod.read_bytes(), original)
                self.assertFalse(Path(str(prod) + ".zuvo-mutation-pristine").exists())
                self.assertEqual(list(base.glob("stryker.zuvo-verify-*.json")), [])
                return result

            no_report = drive(None)
            self.assertEqual(no_report.status, "ERROR")
            self.assertIn("no report", no_report.detail)
            zero = drive({"files": {str(prod): {"mutants": []}}})
            self.assertEqual(zero.status, "FAIL")
            self.assertIn("NO mutants with a verdict", " ".join(zero.gaps))
            timeout = drive({"files": {str(prod): {"mutants": [
                {"status": "Killed"}, {"status": "Timeout"}, {"status": "Timeout"}
            ]}}})
            self.assertEqual(timeout.status, "FAIL")
            self.assertIn("100.0%", timeout.detail)
            self.assertIn("2 TIMED OUT", timeout.detail)
            self.assertIn("more than were decided", " ".join(timeout.gaps))
            nonzero = drive({"files": {str(prod): {"mutants": [
                {"status": "Killed"}
            ]}}}, exit_code=1)
            self.assertEqual(nonzero.status, "ERROR")
            self.assertIn("stryker exited 1", nonzero.detail)
            self.assertNotIn("100.0%", nonzero.detail)

    def test_infection_nonzero_summary_is_error(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            (base / "vendor/bin").mkdir(parents=True)
            (base / "vendor/bin/infection").write_text("")
            (base / "infection.json5").write_text("{}")
            (base / "codeception.yml").write_text("paths:\n  tests: tests\n")
            prod = base / "src/Foo.php"
            spec = base / "tests/unit/FooTest.php"
            prod.parent.mkdir()
            spec.parent.mkdir(parents=True)
            prod.write_text("<?php")
            spec.write_text("<?php")
            report = "1 mutations were generated:\n  1 mutants were killed by Test Framework\n"
            with (
                mock.patch.dict(os.environ, {"ZUVO_VERIFY_EXEC": ""}),
                mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)),
                mock.patch.object(vt, "run", return_value=(1, report)) as launch,
            ):
                result = vt.check_mutation({"kind": "codecept", "cwd": root},
                                           str(prod), [str(spec)], root, 5, False)
            self.assertEqual(launch.call_args.kwargs["cwd"], root)
            self.assertIn("--filter=src/Foo.php", launch.call_args.args[0])
            self.assertIn("--threads=1", launch.call_args.args[0])
            self.assertEqual(result.status, "ERROR")
            self.assertIn("infection exited 1", result.detail)
            self.assertNotIn("100.0%", result.detail)

    def test_interrupted_instrumentation_requires_clean_sidecar(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            prod = base / "target.ts"
            spec = base / "target.spec.ts"
            prod.write_text("stryMutAct_ leftover")
            spec.write_text("test")
            runner = {"kind": "jest", "cwd": root}
            with mock.patch.object(vt, "ensure_stryker", return_value=(root, "project")):
                with mock.patch.object(vt, "_run_mutation") as launch:
                    error = vt.check_mutation(runner, str(prod), [str(spec)], root, 5, False)
                self.assertEqual(error.status, "ERROR")
                self.assertIn("instrumentation left by an interrupted run", error.detail)
                launch.assert_not_called()
                sidecar = Path(str(prod) + ".zuvo-mutation-pristine")
                sidecar.write_text("clean source")
                with mock.patch.object(vt, "_run_mutation", return_value=(1, "no report")):
                    healed = vt.check_mutation(runner, str(prod), [str(spec)], root, 5, False)
                self.assertEqual(healed.status, "ERROR")
                self.assertEqual(prod.read_text(), "clean source")
                self.assertFalse(sidecar.exists())


def drive_stryker(case, root, report, coverage_analysis):
    """Run check_mutation over a fake Stryker run; returns (result, the cfg Stryker was given)."""
    base = Path(root)
    prod = base / "src/target.ts"
    spec = base / "src/target.spec.ts"
    prod.parent.mkdir(exist_ok=True)
    prod.write_text(report["files"]["src/target.ts"]["source"] if report else "x\n")
    spec.write_text("test")
    seen = {}

    def fake_run(cmd, cwd=None, timeout=None):
        seen["cfg"] = json.loads((base / cmd[3]).read_text())
        output = Path(seen["cfg"]["jsonReporter"]["fileName"])
        output.parent.mkdir()
        output.write_text(json.dumps(report))
        return 0, "runner finished"

    with (
        mock.patch.object(vt, "ensure_stryker", return_value=(root, "project")),
        mock.patch.object(vt, "_run_mutation", side_effect=fake_run),
    ):
        result = vt.check_mutation({"kind": "vitest", "cwd": root}, str(prod), [str(spec)],
                                   root, 5, False, None, str(base / "manifest.json"),
                                   coverage_analysis=coverage_analysis)
    case.assertIn("cfg", seen, "Stryker was never launched")
    return result, seen["cfg"]


SOURCE_TS = "export function f(a: number, b: number) {\n  return a > b;\n}\n"
SURVIVOR = {"id": "7", "status": "Survived", "mutatorName": "EqualityOperator",
            "replacement": "a >= b",
            "location": {"start": {"line": 2, "column": 10}, "end": {"line": 2, "column": 15}}}


def stryker_report(*mutants):
    return {"files": {"src/target.ts": {"source": SOURCE_TS, "mutants": list(mutants)}}}


class CoverageAnalysisTests(unittest.TestCase):
    def test_resolve_coverage_analysis_precedence_and_validation(self):
        # Bugs: env ignored, the CLI not overriding the env, an unset env not defaulting to perTest.
        for name, cli, env, want in (
            ("cli off beats env all", "off", "all", "off"),
            ("env all is honoured", None, "all", "all"),
            ("empty env defaults to perTest", None, "", "perTest"),
            ("cli perTest beats env off", "perTest", "off", "perTest"),
            ("absent env defaults to perTest", None, None, "perTest"),
        ):
            with self.subTest(name), mock.patch.dict(os.environ):
                os.environ.pop("ZUVO_VERIFY_COVERAGE_ANALYSIS", None)
                if env is not None:
                    os.environ["ZUVO_VERIFY_COVERAGE_ANALYSIS"] = env
                self.assertEqual(vt.resolve_coverage_analysis(cli), want)

    def test_invalid_env_coverage_analysis_exits_2(self):
        # Bug: a misspelt value (Stryker spells it perTest) silently becomes the default.
        with mock.patch.dict(os.environ, {"ZUVO_VERIFY_COVERAGE_ANALYSIS": "pertest"}), \
                mock.patch("sys.stderr"), self.assertRaises(SystemExit) as stop:
            vt.resolve_coverage_analysis(None)
        self.assertEqual(stop.exception.code, 2)

    def test_invalid_cli_coverage_analysis_exits_2(self):
        # Bug: the flag accepts any spelling and Stryker receives a mode it does not know.
        argv = ["verify-tests", "--manifest", "absent.json", "--coverage-analysis", "pertest"]
        with mock.patch.object(vt.sys, "argv", argv), mock.patch("sys.stderr"), \
                self.assertRaises(SystemExit) as stop:
            vt.main()
        self.assertEqual(stop.exception.code, 2)

    def test_stryker_cfg_and_incremental_file_follow_the_mode(self):
        # Bugs: the flag is parsed but the cfg keeps a hardcoded perTest; an off run reuses the
        # perTest incremental cache, whose results were computed under the other mode.
        killed = dict(SURVIVOR, status="Killed")
        for mode, suffix in (("off", ".stryker-incremental.off.json"),
                             ("all", ".stryker-incremental.all.json"),
                             ("perTest", ".stryker-incremental.json")):
            with self.subTest(mode), tempfile.TemporaryDirectory() as root:
                _result, cfg = drive_stryker(self, root, stryker_report(killed), mode)
                self.assertEqual(cfg["coverageAnalysis"], mode)
                self.assertEqual(cfg["incrementalFile"],
                                 str(Path(root) / "manifest.json") + suffix)

    def test_zero_survivors_still_record_the_mode_in_the_receipt(self):
        # Bug: the mode is only written beside survivors, so a clean run loses it entirely.
        with tempfile.TemporaryDirectory() as root:
            result, _cfg = drive_stryker(self, root,
                                         stryker_report(dict(SURVIVOR, status="Killed")), "all")
        self.assertEqual(result.status, "PASS")
        self.assertTrue(result.detail.endswith(" [coverageAnalysis=all]"), result.detail)

    def test_unmeasured_results_carry_no_mode(self):
        # Bug: a SKIP or ERROR reads as if it had been measured under the mode it names.
        def no_stryker(_root):
            with mock.patch.object(vt, "ensure_stryker",
                                   return_value=(None, "none — StrykerJS not installed")):
                return vt.check_mutation({"kind": "vitest", "cwd": _root}, "p.ts", ["p.spec.ts"],
                                         _root, 5, False, coverage_analysis="off")

        def stryker_crashes(_root):
            prod = Path(_root) / "p.ts"
            prod.write_text("export const p = 1;\n")
            with mock.patch.object(vt, "ensure_stryker", return_value=(_root, "project")), \
                    mock.patch.object(vt, "_run_mutation", return_value=(1, "boom")):
                return vt.check_mutation({"kind": "vitest", "cwd": _root}, str(prod),
                                         [str(Path(_root) / "p.spec.ts")], _root, 5, False,
                                         coverage_analysis="off")

        for name, run_it, status in (("stryker missing", no_stryker, "SKIP"),
                                     ("stryker exits 1", stryker_crashes, "ERROR")):
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                result = run_it(root)
                self.assertEqual(result.status, status)
                self.assertNotIn("[coverageAnalysis=", result.detail)

    def test_survivor_confirmation_label_per_mode(self):
        # Bugs: perTest survivors presented as confirmed gaps; the gap names no way to confirm one;
        # an unconfirmed survivor turning the verdict green.
        for mode, want, reprobe_hint in (("perTest", "unconfirmed", True),
                                         ("off", "not-required", False),
                                         ("all", "not-required", False)):
            with self.subTest(mode), tempfile.TemporaryDirectory() as root:
                result, _cfg = drive_stryker(self, root, stryker_report(SURVIVOR), mode)
                rows = json.loads(Path(root, "manifest.json.survivors.json").read_text())
                self.assertEqual(result.status, "FAIL")
                self.assertEqual(rows["schema"], "zuvo-survivors/v2")
                self.assertEqual(rows["coverage_analysis"], mode)
                self.assertEqual(rows["count"], 1)
                self.assertIn("obligation", rows["survivors"][0])
                self.assertEqual(rows["survivors"][0]["confirmation"], want)
                self.assertEqual(rows["survivors"][0]["id"], "7")
                self.assertEqual(rows["survivors"][0]["original"], "a > b")
                self.assertEqual(rows["survivors"][0]["location"], SURVIVOR["location"])
                gap = result.gaps[0]
                self.assertTrue(gap.startswith("Survived L2 EqualityOperator"), gap)
                self.assertEqual("~/.zuvo/mutation-survivor-reprobe.sh --file src/target.ts"
                                 in gap, reprobe_hint, gap)

    def test_reprobe_hint_names_every_argument_the_reprobe_needs(self):
        # Bug: the hint names only --label, a command the reprobe rejects as a usage error.
        with tempfile.TemporaryDirectory() as root:
            result, _cfg = drive_stryker(self, root, stryker_report(SURVIVOR), "perTest")
        for arg in ("--file src/target.ts", "--original", "--mutated", "--test-cmd",
                    "--label 7"):
            self.assertIn(arg, result.gaps[0])

    def test_reprobe_hint_is_paste_safe(self):
        # Bug: a path with a space or a quote in the id splits the printed command when pasted.
        with tempfile.TemporaryDirectory() as root:
            r = vt.Result("mutation")
            vt.record_survivors(r, [dict(SURVIVOR, id="7'x", original="a > b")], 5,
                                str(Path(root) / "src dir" / "t.ts"), None, None, root,
                                decided=1, coverage_analysis="perTest")
        self.assertIn("--file 'src dir/t.ts'", r.gaps[0])
        self.assertIn("--label '7'\"'\"'x'", r.gaps[0])

    def test_survivor_without_exact_original_is_not_offered_a_reprobe_command(self):
        # Bug: a reprobe command is printed for a mutant whose anchor text the report lacks.
        unsliceable = dict(SURVIVOR, location={"start": {"line": 9, "column": 1},
                                               "end": {"line": 9, "column": 2}})
        with tempfile.TemporaryDirectory() as root:
            result, _cfg = drive_stryker(self, root, stryker_report(unsliceable), "perTest")
            rows = json.loads(Path(root, "manifest.json.survivors.json").read_text())
        self.assertIsNone(rows["survivors"][0]["original"])
        self.assertNotIn("mutation-survivor-reprobe.sh", result.gaps[0])
        self.assertIn("cannot be reprobed from the report", result.gaps[0])

    def test_replacement_is_kept_exact_or_null(self):
        # Bug: a replacement cut to 160 chars is handed to the reprobe as the mutated text.
        long_text = "x" * 300
        for name, replacement, want in (("300 chars kept whole", long_text, long_text),
                                        ("over 400 is null", "y" * 401, None)):
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                drive_stryker(self, root, stryker_report(dict(SURVIVOR, replacement=replacement)),
                              "perTest")
                rows = json.loads(Path(root, "manifest.json.survivors.json").read_text())
                self.assertEqual(rows["survivors"][0]["replacement"], want)

    def test_unwritable_survivor_report_is_a_gap(self):
        # Bug: a failed survivors.json write is swallowed, and the hint points at a missing file.
        with tempfile.TemporaryDirectory() as root:
            r = vt.Result("mutation")
            vt.record_survivors(r, [dict(SURVIVOR, original="a > b")], 5, "p.ts", None,
                                str(Path(root) / "absent-dir" / "manifest.json"), root,
                                decided=1, coverage_analysis="perTest")
        self.assertTrue(any("survivors.json was not written" in g for g in r.gaps), r.gaps)

    def test_infection_survivors_are_labelled_not_applicable(self):
        # Bug: Infection survivors carry the Stryker perTest label, so they read as unconfirmable.
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            (base / "vendor/bin").mkdir(parents=True)
            (base / "vendor/bin/infection").write_text("")
            (base / "infection.json5").write_text("{}")
            (base / "codeception.yml").write_text("paths:\n  tests: tests\n")
            prod = base / "src/Foo.php"
            spec = base / "tests/unit/FooTest.php"
            prod.parent.mkdir()
            spec.parent.mkdir(parents=True)
            prod.write_text("<?php")
            spec.write_text("<?php")
            report = ("2 mutations were generated:\n"
                      "  1 mutants were killed by Test Framework\n"
                      "  1 covered mutants were not detected\n"
                      "Escaped mutants:\n\n"
                      "1) %s:3    [M] TrueValue [ID] abc\n"
                      "-    return true;\n+    return false;\n" % prod)
            with (
                mock.patch.dict(os.environ, {"ZUVO_VERIFY_EXEC": ""}),
                mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)),
                mock.patch.object(vt, "run", return_value=(0, report)),
            ):
                result = vt.check_mutation({"kind": "codecept", "cwd": root}, str(prod),
                                           [str(spec)], root, 5, False, None,
                                           str(base / "manifest.json"))
            rows = json.loads(Path(root, "manifest.json.survivors.json").read_text())
        self.assertEqual(result.status, "FAIL")
        self.assertTrue(result.detail.endswith(" [coverageAnalysis=n/a (infection)]"),
                        result.detail)
        self.assertEqual(rows["survivors"][0]["confirmation"], "n/a")
        self.assertIsNone(rows["survivors"][0]["original"])

    def test_original_slice_is_exact_or_null(self):
        # Bug: Stryker columns count UTF-16 units and Python slices code points, so an astral
        # character before the mutant shifts the slice; a wrong anchor is worse than none.
        emoji = 'const s = "\U0001F600"; if (a > b) x();\n'
        multi = "function f(a) {\n  if (a) {\n    return 1;\n  }\n}\n"

        def loc(sl, sc, el, ec):
            return {"start": {"line": sl, "column": sc}, "end": {"line": el, "column": ec}}

        for name, source, location, want in (
            # Real Stryker 4 report excerpt: BooleanLiteral id 5 on `    if (!index) {`.
            ("real report: columns are 1-based", "    if (!index) {\n", loc(1, 9, 1, 15),
             "!index"),
            ("astral char before the mutant on its line", emoji, loc(1, 21, 1, 26), "a > b"),
            ("start column splits a surrogate pair", emoji, loc(1, 13, 1, 15), None),
            ("start line beyond the source", multi, loc(8, 1, 9, 2), None),
            ("reversed span", multi, loc(3, 1, 2, 1), None),
            ("location is a list", multi, [1, 1, 1, 2], None),
            ("column is infinite", multi, {"start": {"line": 1, "column": float("inf")},
                                           "end": {"line": 1, "column": 2}}, None),
            ("lone surrogate in the source", "\ud800abc\n", loc(1, 2, 1, 3), None),
            ("multi-line block", multi, loc(2, 10, 4, 4), "{\n    return 1;\n  }"),
            ("CRLF line endings", "a;\r\nif (x) y;\r\n", loc(2, 5, 2, 6), "x"),
            ("end column splits a surrogate pair", emoji, loc(1, 11, 1, 13), None),
            ("line past the end of the source", multi, loc(9, 1, 9, 2), None),
            ("end column past the end of its line", multi, loc(2, 1, 2, 99), None),
            ("no source in the report", None, loc(1, 1, 1, 2), None),
            ("longer than the 400-char cap", "x" * 500, loc(1, 1, 1, 450), None),
        ):
            with self.subTest(name):
                self.assertEqual(vt.mutant_original(source, location), want)

REPROBE = Path(__file__).resolve().parents[2] / "scripts/mutation-survivor-reprobe.sh"
REFUTED_NOTE = "killed by physical reprobe — a perTest false survivor; triage it"


def reprobe_block(label, verdict, restored, reason="r", file=None):
    """One block in mutation-survivor-reprobe.sh's KEY=VALUE shape."""
    return ("label=%s\n%sverdict=%s\ntest_exit=0\nrestored=%s\n"
            "sha_before=a\nsha_after=a\nreason=%s\n"
            % (label, "file=%s\n" % file if file else "", verdict, restored, reason))


def perTest_survivors(root, *ids, mode="perTest"):
    """A manifest whose survivors.json holds one row per id for src/target.ts, labelled per mode."""
    manifest = str(Path(root) / "manifest.json")
    r = vt.Result("mutation")
    vt.record_survivors(r, [dict(SURVIVOR, id=i, original="a > b") for i in ids], 5,
                        str(Path(root) / "src/target.ts"), None, manifest, root,
                        decided=len(ids), coverage_analysis=mode)
    if not Path(manifest + ".survivors.json").exists():
        raise AssertionError("fixture survivors.json not written: %s" % r.gaps)
    return manifest


def record(manifest, text, *extra):
    """Run `verify-tests --record-reprobe` in-process; returns (exit code, stdout, stderr)."""
    feed = Path(manifest).parent / "reprobe.out"
    feed.write_text(text)
    argv = ["verify-tests", "--manifest", manifest, "--repo-root", str(Path(manifest).parent),
            "--record-reprobe", str(feed)] + list(extra)
    out, err = io.StringIO(), io.StringIO()
    with mock.patch.object(vt.sys, "argv", argv), contextlib.redirect_stdout(out), \
            contextlib.redirect_stderr(err):
        try:
            rc = vt.main()
        except SystemExit as stop:
            rc = stop.code
    return rc, out.getvalue(), err.getvalue()


def rows_of(manifest):
    return {r["id"]: r for r in
            json.loads(Path(manifest + ".survivors.json").read_text())["survivors"]}


class RecordReprobeTests(unittest.TestCase):
    def test_reprobe_verdict_moves_the_label_only_on_a_restored_run(self):
        # Bugs: a KILLED probe left as unconfirmed; an ERROR read as a verdict; a probe that left
        # the source mutated (restored=no) counted as evidence.
        for name, verdict, restored, want, note in (
            ("survived and restored confirms", "SURVIVED", "yes", "confirmed", None),
            ("killed and restored refutes", "KILLED", "yes", "refuted", REFUTED_NOTE),
            ("error stays unconfirmed with its reason", "ERROR", "yes", "unconfirmed",
             "baseline FAILED"),
            ("survived but not restored is no evidence", "SURVIVED", "no", "unconfirmed",
             "did not restore"),
            ("killed but not restored is no evidence", "KILLED", "no", "unconfirmed",
             "did not restore"),
        ):
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                manifest = perTest_survivors(root, "7")
                rc, _out, err = record(manifest, reprobe_block("7", verdict, restored,
                                                               "baseline FAILED: x"))
                self.assertEqual(rc, 0, err)
                row = rows_of(manifest)["7"]
                self.assertEqual(row["confirmation"], want)
                if note:
                    self.assertIn(note, row["confirmation_note"])

    def test_several_blocks_in_one_input_each_move_their_own_row(self):
        # Bug: only the first (or last) block of a concatenated reprobe log is applied.
        with tempfile.TemporaryDirectory() as root:
            manifest = perTest_survivors(root, "7", "8", "9")
            rc, _out, err = record(manifest, reprobe_block("7", "KILLED", "yes")
                                   + reprobe_block("8", "SURVIVED", "yes"))
            rows = rows_of(manifest)
        self.assertEqual(rc, 0, err)
        self.assertEqual((rows["7"]["confirmation"], rows["8"]["confirmation"],
                          rows["9"]["confirmation"]), ("refuted", "confirmed", "unconfirmed"))

    def test_unknown_label_exits_1_and_leaves_the_file_byte_identical(self):
        # Bug: a typo'd label is dropped silently while the known blocks are written, so the
        # caller believes every probe was recorded.
        with tempfile.TemporaryDirectory() as root:
            manifest = perTest_survivors(root, "7")
            before = Path(manifest + ".survivors.json").read_bytes()
            rc, _out, err = record(manifest, reprobe_block("7", "KILLED", "yes")
                                   + reprobe_block("70", "SURVIVED", "yes"))
            after = Path(manifest + ".survivors.json").read_bytes()
        self.assertEqual(rc, 1)
        self.assertIn("70", err)
        self.assertEqual(after, before)

    def test_unusable_input_is_a_usage_error_and_changes_nothing(self):
        # Bug: a truncated or hand-typed block is half-applied instead of refused.
        for name, text, setup, says in (
            ("block without a verdict", "label=7\nrestored=yes\n", None, "verdict"),
            ("verdict outside the contract", reprobe_block("7", "PASSED", "yes"), None,
             "verdict"),
            ("restored is neither yes nor no", reprobe_block("7", "KILLED", "maybe"), None,
             "restored"),
            ("a key before any label", "verdict=KILLED\n" + reprobe_block("7", "KILLED", "yes"),
             None, "label"),
            ("no block at all", "nothing here\n", None, "label"),
            # Bug: a later block for the same label silently overwrites the earlier verdict.
            ("the same label in two blocks", reprobe_block("7", "KILLED", "yes")
             + reprobe_block("7", "SURVIVED", "yes"), None, "more than one block"),
            # Bug: the cap counts characters, so multi-byte input reads past it.
            ("over the cap in bytes, under it in characters",
             reprobe_block("7", "KILLED", "yes") + "\u00e9" * (vt.REPROBE_INPUT_CAP // 2 + 1),
             None, "bytes"),
            ("no survivors.json beside the manifest", reprobe_block("7", "KILLED", "yes"),
             "drop-report", "survivors.json"),
        ):
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                manifest = perTest_survivors(root, "7")
                report = Path(manifest + ".survivors.json")
                if setup == "drop-report":
                    report.rename(report.with_name("elsewhere.json"))
                before = report.read_bytes() if report.exists() else None
                rc, _out, err = record(manifest, text)
                self.assertEqual(rc, 2)
                self.assertIn(says, err)
                self.assertEqual(report.read_bytes() if report.exists() else None, before)

    def test_refuted_label_does_not_move_the_mutation_verdict(self):
        # Bug: a typed KEY=VALUE block exempts a survivor — the receipt turns PASS, the row is
        # dropped, or the record spends/rewrites the pass state.
        with tempfile.TemporaryDirectory() as root:
            mutation, _cfg = drive_stryker(self, root, stryker_report(SURVIVOR), "perTest")
            self.assertEqual(mutation.status, "FAIL")
            manifest = str(Path(root) / "manifest.json")
            spec = str(Path(root) / "src/target.spec.ts")
            Path(manifest).write_text(json.dumps({"production_file": "src/target.ts",
                                                  "test_files": ["src/target.spec.ts"]}))
            suite = vt.Result("suite")
            suite.status = "PASS"
            vt.stamp_receipt(manifest, [suite, mutation], [spec], root)
            receipt = Path(manifest).read_bytes()
            rc, _out, err = record(manifest, reprobe_block("7", "KILLED", "yes"))
            report = json.loads(Path(manifest + ".survivors.json").read_text())
            self.assertEqual(rc, 0, err)
            self.assertEqual(report["survivors"][0]["confirmation"], "refuted")
            self.assertEqual(Path(manifest).read_bytes(), receipt)
            self.assertTrue(json.loads(receipt)["verification"]["mutation"].startswith("FAIL"))
            self.assertEqual((report["count"], report["survivors"][0]["status"]),
                             (1, "Survived"))
            self.assertFalse(Path(vt.state_path(manifest)).exists())

    def test_only_an_unconfirmed_row_is_relabelled(self):
        # Bugs: a probe relabels a survivor that perTest never doubted (off / Infection), or a
        # second probe flips a label an earlier probe already settled.
        for name, mode, first, want, says in (
            ("off run: not a perTest survivor", "off", None, "not-required",
             "not a perTest survivor"),
            ("infection: not a perTest survivor", vt.INFECTION_COVERAGE, None, "n/a",
             "not a perTest survivor"),
            ("already confirmed stays confirmed", "perTest", "SURVIVED", "confirmed",
             "already labelled"),
        ):
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                manifest = perTest_survivors(root, "7", mode=mode)
                if first:
                    self.assertEqual(record(manifest, reprobe_block("7", first, "yes"))[0], 0)
                rc, out, err = record(manifest, reprobe_block("7", "KILLED", "yes"))
                self.assertEqual(rc, 0, err)
                self.assertEqual(rows_of(manifest)["7"]["confirmation"], want)
                self.assertIn(says, out + err)

    def test_unrestored_probe_warns_that_the_source_is_left_mutated(self):
        # Bug: restored=no is recorded quietly while the production file still holds the mutant.
        with tempfile.TemporaryDirectory() as root:
            manifest = perTest_survivors(root, "7")
            rc, out, err = record(manifest, reprobe_block("7", "SURVIVED", "no"))
        self.assertEqual(rc, 0, err)
        self.assertIn("WARNING", out + err)
        self.assertIn("left mutated", out + err)

    def test_block_for_another_file_is_refused(self):
        # Bug: a probe of a different file with a colliding mutant id relabels this file's row.
        for name, file, want in (("another file", "/elsewhere/src/target.ts", 1),
                                 ("this file", None, 0)):
            with self.subTest(name), tempfile.TemporaryDirectory() as root:
                manifest = perTest_survivors(root, "7")
                before = Path(manifest + ".survivors.json").read_bytes()
                rc, _out, err = record(manifest, reprobe_block(
                    "7", "KILLED", "yes", file=file or str(Path(root) / "src/target.ts")))
                self.assertEqual(rc, want, err)
                if want:
                    self.assertIn("file", err)
                    self.assertEqual(Path(manifest + ".survivors.json").read_bytes(), before)

    def test_invalid_utf8_on_stdin_is_decoded_not_a_traceback(self):
        # Bug: stdin is decoded strictly, so one stray byte in a reason crashes the recorder.
        with tempfile.TemporaryDirectory() as root:
            manifest = perTest_survivors(root, "7")
            done = subprocess.run(
                [sys.executable, str(SOURCE), "--manifest", manifest, "--repo-root", root,
                 "--record-reprobe", "-"],
                input=reprobe_block("7", "KILLED", "yes", reason="X").encode().replace(
                    b"reason=X", b"reason=\xff\xfe"),
                env=dict(os.environ, PYTHONIOENCODING="utf-8", LC_ALL="C.UTF-8"),
                capture_output=True, timeout=60)
            rows = rows_of(manifest)
        self.assertNotIn(b"Traceback", done.stderr)
        self.assertEqual(done.returncode, 0, done.stderr)
        self.assertEqual(rows["7"]["confirmation"], "refuted")

    @unittest.skipUnless(os.name == "posix", "the reprobe helper is a bash script")
    @unittest.skipUnless(shutil.which("timeout") or shutil.which("gtimeout"),
                         "the reprobe helper refuses to run without timeout/gtimeout")
    def test_real_reprobe_output_is_recorded_from_stdin(self):
        # Bug: the KEY=VALUE contract drifts between the reprobe helper and its recorder.
        with tempfile.TemporaryDirectory() as root:
            prod = Path(root) / "calc.sh"
            prod.write_text("add() { echo $((2 + 3)); }\ngreet() { echo hi; }\nadd\ngreet\n")
            loc = {"start": {"line": 1, "column": 1}, "end": {"line": 1, "column": 2}}
            manifest = str(Path(root) / "manifest.json")
            vt.record_survivors(vt.Result("mutation"), [
                {"id": "s1", "status": "Survived", "location": loc,
                 "mutatorName": "ArithmeticOperator", "original": "2 + 3",
                 "replacement": "2 - 3"},
                {"id": "s2", "status": "Survived", "location": loc,
                 "mutatorName": "StringLiteral", "original": "echo hi",
                 "replacement": "echo bye"},
            ], 5, str(prod), None, manifest, root, decided=2, coverage_analysis="perTest")
            env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null")
            logs = []
            for row in rows_of(manifest).values():
                probe = subprocess.run(
                    ["bash", str(REPROBE), "--file", str(prod), "--original", row["original"],
                     "--mutated", row["replacement"], "--timeout", "30",
                     "--test-cmd", '[ "$(bash calc.sh | head -n 1)" = 5 ]',
                     "--label", row["id"]],
                    cwd=root, env=env, capture_output=True, text=True, timeout=120)
                self.assertIn(probe.returncode, (0, 1), probe.stdout + probe.stderr)
                logs.append(probe.stdout)
            done = subprocess.run(
                [sys.executable, str(SOURCE), "--manifest", manifest, "--repo-root", root,
                 "--record-reprobe", "-"],
                input="".join(logs), env=env, capture_output=True, text=True, timeout=60)
            rows = rows_of(manifest)
        self.assertEqual(done.returncode, 0, done.stdout + done.stderr)
        self.assertEqual((rows["s1"]["confirmation"], rows["s2"]["confirmation"]),
                         ("refuted", "confirmed"))


if __name__ == "__main__":
    unittest.main()
