"""Native mutation evidence, survivor gaps, and production restoration."""

import json
import os
from pathlib import Path
import signal
import subprocess
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
                with mock.patch.object(vt, "ensure_stryker", return_value=(root, "project")):
                    with mock.patch.object(vt.subprocess, "Popen", side_effect=fake_popen):
                        with mock.patch.object(vt.os, "kill", side_effect=fake_kill):
                            with mock.patch.object(vt.os, "killpg") as kill_group:
                                with self.assertRaises(SystemExit):
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
            vt.record_survivors(empty, [], 5, prod, None, manifest, root, decided=0)
            self.assertEqual(empty.status, "FAIL")
            self.assertTrue(any("NO mutants with a verdict" in g for g in empty.gaps))
            green = vt.Result("mutation")
            vt.record_survivors(green, [], 5, prod, None, manifest, root, decided=2)
            self.assertEqual((green.status, green.gaps), ("PASS", []))
            majority = vt.Result("mutation")
            vt.record_survivors(majority, [], 5, prod, None, manifest, root,
                                decided=2, undecided=3)
            self.assertEqual(majority.status, "FAIL")
            self.assertIn("3 of 5 mutants produced NO verdict", majority.gaps[0])
            survivors = [
                {"status": "Survived", "location": {"start": {"line": 4}},
                 "mutatorName": "Arithmetic", "replacement": "x + 1"},
                {"status": "NoCoverage", "location": {"start": {"line": 10}},
                 "mutatorName": "Boolean", "replacement": "false"},
            ]
            result = vt.Result("mutation")
            vt.record_survivors(result, survivors, 1, prod, None, manifest, root, decided=2)
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
                with mock.patch.object(vt, "ensure_stryker", return_value=(root, "project")):
                    with mock.patch.object(vt, "_run_mutation", side_effect=fake_run) as launch:
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
            with mock.patch.dict(os.environ, {"ZUVO_VERIFY_EXEC": ""}):
                with mock.patch.object(vt, "codecept_cmd", side_effect=lambda *args: list(args)):
                    with mock.patch.object(vt, "run", return_value=(1, report)) as launch:
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


if __name__ == "__main__":
    unittest.main()
