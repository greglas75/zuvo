"""Behavioral unit tests for verify-tests' pure helpers and runner selection."""

import hashlib
import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "scripts/zuvo-home/verify-tests"
LOADER = importlib.machinery.SourceFileLoader("verify_tests_core", str(SOURCE))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
vt = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(vt)


class CoreTests(unittest.TestCase):
    def test_sha256_uses_file_bytes(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "source.py"
            body = b"\x00binary\xff\n" * 10000
            path.write_bytes(body)
            self.assertEqual(vt.sha256(path), hashlib.sha256(body).hexdigest())

    def test_run_success_strips_ansi_and_passes_boundary_arguments(self):
        completed = subprocess.CompletedProcess(["tool", "arg"], 0, b"\x1b[31mOK\x1b[0m\n")
        with mock.patch.object(vt.subprocess, "run", return_value=completed) as launch:
            with mock.patch.dict(vt.os.environ, {"INHERITED": "yes"}):
                rc, output = vt.run(["tool", "arg"], cwd="/fixture", timeout=17,
                                    env={"EXTRA": "value"})
        self.assertEqual((rc, output), (0, "OK\n"))
        self.assertEqual(launch.call_args.args, (["tool", "arg"],))
        self.assertEqual(launch.call_args.kwargs["cwd"], "/fixture")
        self.assertEqual(launch.call_args.kwargs["timeout"], 17)
        self.assertEqual(launch.call_args.kwargs["env"]["INHERITED"], "yes")
        self.assertEqual(launch.call_args.kwargs["env"]["EXTRA"], "value")

    def test_run_timeout_missing_and_unexpected_launch_error(self):
        cases = (
            (subprocess.TimeoutExpired(["tool"], 7, output=b"\x1b[31mpartial\x1b[0m"),
             124, "partial", "TIMEOUT after 7s"),
            (FileNotFoundError("tool"), 127, "not found", "tool"),
            (PermissionError("denied"), 126, "denied", "[verify-tests]"),
        )
        for error, expected_rc, fragment, diagnostic in cases:
            with self.subTest(expected_rc=expected_rc):
                with mock.patch.object(vt.subprocess, "run", side_effect=error) as launch:
                    rc, output = vt.run(["tool"], cwd="/fixture", timeout=7)
                self.assertEqual(rc, expected_rc)
                self.assertIn(fragment, output)
                self.assertIn(diagnostic, output)
                launch.assert_called_once()

    def test_json_read_distinguishes_valid_from_absent_invalid_and_unreadable(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "report.json"
            self.assertIsNone(vt.read_json(path))
            path.write_text("{invalid", encoding="utf-8")
            self.assertIsNone(vt.read_json(path))
            with mock.patch("builtins.open", side_effect=PermissionError("denied")):
                self.assertIsNone(vt.read_json(path))
            path.write_text(json.dumps({"count": 0, "nested": [False]}), encoding="utf-8")
            self.assertEqual(vt.read_json(path), {"count": 0, "nested": [False]})

    def test_nearest_package_prefers_workspace_and_stops_at_root(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            spec = base / "apps/api/tests/unit.spec.ts"
            spec.parent.mkdir(parents=True)
            spec.write_text("test", encoding="utf-8")
            (base / "package.json").write_text('{"devDependencies":{"jest":"1"}}')
            (base / "apps/api/package.json").write_text('{"scripts":{"test":"vitest"},"devDependencies":{"vitest":"1"}}')
            pkgdir, data = vt.nearest_package(spec, root)
            self.assertEqual(pkgdir, str(base / "apps/api"))
            self.assertIn("vitest", data["devDependencies"])
            (base / "apps/api/package.json").write_text('{"name":"api"}')
            self.assertEqual(vt.nearest_package(spec, root)[0], root)
            (base / "package.json").unlink()
            self.assertEqual(vt.nearest_package(spec, root), (None, None))

    def test_detect_runner_known_stacks_and_named_errors(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            spec = base / "test.py"
            spec.write_text("pass")
            self.assertEqual(vt.detect_runner("python", [str(spec)], root),
                             {"kind": "pytest", "cwd": root})
            self.assertEqual(vt.detect_runner("php", [str(spec)], root)["kind"], "phpunit")
            (base / "codeception.yml").write_text("paths:\n  tests: tests\n")
            self.assertEqual(vt.detect_runner("php", [str(spec)], root)["kind"], "codecept")
            self.assertIn("unsupported stack", vt.detect_runner("ruby", [str(spec)], root)["error"])
            self.assertIn("no package.json", vt.detect_runner("js", [str(spec)], root)["error"])
            (base / "package.json").write_text('{"name":"app"}')
            self.assertIn("no vitest/jest", vt.detect_runner("js", [str(spec)], root)["error"])
            (base / "package.json").write_text('{"devDependencies":{"jest":"1"}}')
            self.assertEqual(vt.detect_runner("js", [str(spec)], root)["kind"], "jest")
            (base / "package.json").write_text('{"devDependencies":{"vitest":"1","jest":"1"}}')
            self.assertEqual(vt.detect_runner("ts", [str(spec)], root)["kind"], "vitest")

    def test_paths_codeception_and_prefix(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            spec = base / "tests/unit/FooTest.php"
            spec.parent.mkdir(parents=True)
            spec.write_text("<?php")
            self.assertEqual(vt.rel_to(spec, root), "tests/unit/FooTest.php")
            self.assertEqual(vt.codecept_tests_dir(root), "tests")
            self.assertEqual(vt.codecept_suite("tests/unit/FooTest.php", root), "unit")
            self.assertIsNone(vt.codecept_suite("outside/FooTest.php", root))
            (base / "codeception.yml").write_text("paths:\n  tests: 'specs/'\n")
            self.assertEqual(vt.codecept_tests_dir(root), "specs")
            self.assertEqual(vt.codecept_suite("specs/unit/FooTest.php", root), "unit")
        with mock.patch.dict(os.environ, {"ZUVO_VERIFY_EXEC": "rt --full --light"}):
            self.assertEqual(vt.exec_prefix(), ["rt", "--full", "--light"])

    def test_php_runtime_binary_and_ini_are_from_same_selected_runtime(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root)
            old = base / "php-8.3-pcov"
            new = base / "php-8.4-pcov"
            for runtime in (old, new):
                (runtime / "etc/conf.d").mkdir(parents=True)
                (runtime / "lib").mkdir()
                (runtime / "lib/pcov.so").write_bytes(b"pcov")
                (runtime / "bin").mkdir()
                (runtime / "bin/php").write_bytes(b"php")
                (runtime / "bin/php").chmod(0o755)
            with mock.patch.dict(os.environ, {"ZUVO_PHP_RUNTIMES": root}, clear=True):
                with mock.patch.object(vt.shutil, "which", return_value=None):
                    self.assertEqual(vt.php_runtime_base(), str(new))
                    self.assertEqual(vt.php_bin(), str(new / "bin/php"))
                    self.assertEqual(vt.php_coverage_env()["PHP_INI_SCAN_DIR"],
                                     str(new / "etc/conf.d"))
                with mock.patch.object(vt.shutil, "which", return_value="/profile/php"):
                    self.assertEqual(vt.php_bin(), "/profile/php")
                    self.assertNotIn("PHP_INI_SCAN_DIR", vt.php_coverage_env())
                os.environ["PHP_INI_SCAN_DIR"] = "/caller/ini"
                self.assertEqual(vt.php_coverage_env()["PHP_INI_SCAN_DIR"], "/caller/ini")
            with mock.patch.dict(os.environ, {"ZUVO_PHP_RUNTIMES": str(base / "absent")}, clear=True):
                with mock.patch.object(vt.shutil, "which", return_value=None):
                    self.assertEqual(vt.php_bin(), "php")
                    self.assertNotIn("PHP_INI_SCAN_DIR", vt.php_coverage_env())

    def test_git_root_uses_successful_last_line_and_falls_back_on_error(self):
        with mock.patch.object(vt, "run", return_value=(0, "notice\n/repo\n")) as launch:
            self.assertEqual(vt.git_root("/work"), "/repo")
        launch.assert_called_once_with(["git", "rev-parse", "--show-toplevel"], cwd="/work")
        with mock.patch.object(vt, "run", return_value=(1, "fatal")):
            self.assertEqual(vt.git_root("/work/../work"), "/work")

    def test_php_command_includes_prefix_and_selected_runtime_environment(self):
        with mock.patch.dict(os.environ, {"ZUVO_VERIFY_EXEC": "rt --full --light",
                                         "PHP_INI_SCAN_DIR": "/chosen/ini"}):
            with mock.patch.object(vt.shutil, "which", return_value="/chosen/php"):
                command = vt.codecept_cmd("vendor/bin/codecept", "run", "unit")
        self.assertEqual(command, ["rt", "--full", "--light", "env",
                                   "PHP_INI_SCAN_DIR=/chosen/ini", "XDEBUG_MODE=coverage",
                                   "/chosen/php", "vendor/bin/codecept", "run", "unit"])


if __name__ == "__main__":
    unittest.main()
