"""Receipt evidence, bounded allowances, refunds, and CLI stop conditions."""

import contextlib
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest import mock


SOURCE = Path(__file__).resolve().parents[2] / "scripts/zuvo-home/verify-tests"
LOADER = importlib.machinery.SourceFileLoader("verify_tests_budget", str(SOURCE))
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
vt = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(vt)


def result(name, status, gap=None):
    item = vt.Result(name)
    item.status = status
    item.detail = name + " detail"
    if gap:
        item.gaps.append(gap)
    return item


class BudgetTests(unittest.TestCase):
    def fixture(self, root):
        base = Path(root)
        prod = base / "src/target.py"
        specs = [base / "tests/test_one.py", base / "tests/test_two.py"]
        prod.parent.mkdir()
        specs[0].parent.mkdir()
        prod.write_bytes(b"target = 1\n")
        specs[0].write_bytes(b"assert 1\n")
        specs[1].write_bytes(b"assert 2\n")
        manifest = base / "manifest.json"
        manifest.write_text(json.dumps({
            "production_file": "src/target.py",
            "production_sha256": hashlib.sha256(prod.read_bytes()).hexdigest(),
            "test_files": ["tests/test_one.py", "tests/test_two.py"],
            "stack": "python",
        }))
        return prod, specs, manifest

    def test_receipt_hashes_all_actual_spec_bytes_and_refuses_red_or_partial(self):
        with tempfile.TemporaryDirectory() as root:
            _prod, specs, manifest = self.fixture(root)
            clean = [result("suite", "PASS"), result("production-hash", "PASS"),
                     result("coverage", "FAIL"), result("mutation", "SKIP")]
            with mock.patch.object(vt.time, "time", return_value=42):
                vt.stamp_receipt(str(manifest), clean, list(map(str, specs)), root)
            receipt = json.loads(manifest.read_text())["verification"]
            self.assertEqual(receipt["schema"], "zuvo-verify/v1")
            self.assertEqual(receipt["epoch"], 42)
            self.assertEqual(receipt["spec_sha256"], {
                "tests/test_one.py": hashlib.sha256(b"assert 1\n").hexdigest(),
                "tests/test_two.py": hashlib.sha256(b"assert 2\n").hexdigest(),
            })
            self.assertEqual(receipt["coverage"], "FAIL coverage detail")
            original = manifest.read_bytes()
            for rows, files in (
                ([result("suite", "FAIL")], specs),
                ([result("suite", "ERROR")], specs),
                ([result("suite", "PASS"), result("production-hash", "FAIL")], specs),
                (clean, specs + [Path(root) / "tests/missing.py"]),
            ):
                with self.subTest(rows=[r.status for r in rows], files=len(files)):
                    vt.stamp_receipt(str(manifest), rows, list(map(str, files)), root)
                    self.assertEqual(manifest.read_bytes(), original)

    def test_gate_round_requires_spent_base_and_changed_measured_spec(self):
        with tempfile.TemporaryDirectory() as root:
            _prod, specs, manifest = self.fixture(root)
            vt.stamp_receipt(str(manifest), [result("suite", "PASS")],
                             list(map(str, specs)), root)
            self.assertFalse(vt.specs_changed_since_receipt(str(manifest), root))
            early = {"passes": 3}
            specs[0].write_bytes(b"assert 3\n")
            self.assertTrue(vt.specs_changed_since_receipt(str(manifest), root))
            self.assertFalse(vt.grant_gate_round(early, "adversarial", 3, str(manifest), root))
            self.assertEqual(early["gate_rounds"], {})
            spent = {"passes": 4}
            self.assertTrue(vt.grant_gate_round(spent, "adversarial", 3, str(manifest), root))
            self.assertFalse(vt.grant_gate_round(spent, "adversarial", 3, str(manifest), root))
            self.assertEqual(spent["gate_rounds"]["adversarial"]["claimed_on_pass"], 4)
            self.assertEqual(vt.effective_budget(spent, 3), 5)
            self.assertEqual(vt.effective_time_budget(spent, 15, 3, 5), 25)
            specs[0].write_bytes(b"assert 1\n")
            self.assertFalse(vt.specs_changed_since_receipt(str(manifest), root))
            self.assertFalse(vt.grant_gate_round(spent, "blind-audit", 3, str(manifest), root))
            specs[0].unlink()
            self.assertFalse(vt.specs_changed_since_receipt(str(manifest), root))
            self.assertFalse(vt.grant_gate_round(spent, "blind-audit", 3, str(manifest), root))

    def test_state_budget_cannot_widen_and_clock_only_counts_pass_work(self):
        with tempfile.TemporaryDirectory() as root:
            manifest = str(Path(root) / "manifest.json")
            with mock.patch.object(vt.time, "time", return_value=1000):
                first = vt.bump_state(manifest, 3, 15)
            self.assertEqual((first["passes"], first["budget"], first["time_budget_min"]),
                             (1, 3, 15))
            vt.save_state(manifest, first, [])
            with mock.patch.object(vt.time, "time", return_value=4600):
                second = vt.bump_state(manifest, 999, 0)
            self.assertEqual((second["passes"], second["budget"], second["time_budget_min"]),
                             (2, 3, 15))
            self.assertEqual(second["elapsed_min"], 60.0)
            self.assertEqual(second["measured_min"], 0.0)
            self.assertEqual(vt.add_measured_time(second, 60), 1.0)
            vt.save_state(manifest, second, [])
            with mock.patch.object(vt.time, "time", return_value=4700):
                third = vt.bump_state(manifest, 2, 8)
            self.assertEqual((third["passes"], third["budget"], third["time_budget_min"]),
                             (3, 2, 8))
            self.assertEqual(third["measured_min"], 1.0)

    def test_infrastructure_refunds_are_capped_and_record_cause(self):
        state = {"passes": 4, "infra_refunds": 0}
        for expected_pass in (3, 2, 1):
            self.assertTrue(vt.refund_pass(state, "coverage: unavailable"))
            self.assertEqual(state["passes"], expected_pass)
        self.assertFalse(vt.refund_pass(state, "coverage: unavailable"))
        self.assertEqual(state["passes"], 1)
        self.assertEqual(state["infra_refunds"], 3)
        self.assertEqual(len(state["refunded"]), 3)
        self.assertEqual(state["refunded"][0]["why"], "coverage: unavailable")

    def test_main_missing_inputs_exit_two_before_running_checks_or_writing_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            prod, specs, manifest = self.fixture(root)
            cases = (
                (Path(root) / "missing.json", "cannot read manifest"),
                (manifest, "missing file(s)"),
            )
            specs[1].unlink()
            for path, diagnostic in cases:
                with self.subTest(path=path):
                    stderr = io.StringIO()
                    with mock.patch.object(vt.sys, "argv", ["verify-tests", "--manifest",
                                                             str(path), "--repo-root", root]):
                        with mock.patch.object(vt, "check_suite") as suite:
                            with contextlib.redirect_stderr(stderr):
                                rc = vt.main()
                    self.assertEqual(rc, 2)
                    self.assertIn(diagnostic, stderr.getvalue())
                    suite.assert_not_called()
                    self.assertNotIn("verification", json.loads(manifest.read_text()))
                    self.assertFalse(Path(vt.state_path(str(manifest))).exists())
            specs[1].write_bytes(b"assert 2\n")
            prod.unlink()
            with mock.patch.object(vt.sys, "argv", ["verify-tests", "--manifest", str(manifest),
                                                     "--repo-root", root]):
                with mock.patch.object(vt, "check_suite") as suite:
                    with contextlib.redirect_stderr(io.StringIO()):
                        self.assertEqual(vt.main(), 2)
                suite.assert_not_called()

    def test_main_pass_three_exhausts_and_fourth_refuses_without_rerunning(self):
        with tempfile.TemporaryDirectory() as root:
            _prod, _specs, manifest = self.fixture(root)
            argv = ["verify-tests", "--manifest", str(manifest), "--repo-root", root,
                    "--budget", "3", "--time-budget", "0", "--skip",
                    "coverage,typecheck,mutation", "--json"]
            def gate(_manifest, _root, _base):
                self.assertIn("verification", json.loads(manifest.read_text()))
                return result("coverage-gate", "FAIL", "FAIL: uncovered row")
            with mock.patch.object(vt.sys, "argv", argv):
                with mock.patch.object(vt, "zuvo_base", return_value=root):
                    with mock.patch.object(vt, "check_suite", return_value=result("suite", "PASS")) as suite:
                        with mock.patch.object(vt, "check_gate", side_effect=gate) as gate_call:
                            codes = []
                            outputs = []
                            for _ in range(4):
                                output = io.StringIO()
                                with contextlib.redirect_stdout(output):
                                    codes.append(vt.main())
                                outputs.append(output.getvalue())
            self.assertEqual(codes, [1, 1, 4, 4])
            self.assertEqual(suite.call_count, 3)
            self.assertEqual(gate_call.call_count, 3)
            self.assertEqual([json.loads(x)["pass"] for x in outputs[:3]], [1, 2, 3])
            self.assertIn("REFUSED", outputs[3])
            state = json.loads(Path(vt.state_path(str(manifest))).read_text())
            self.assertEqual(state["passes"], 3)
            self.assertEqual(len([h for h in state["history"] if h["results"]]), 3)

    def test_main_red_or_unlaunched_suite_defers_later_checks_and_never_stamps_receipt(self):
        for status, expected_rc, expected_passes in (("FAIL", 1, 1), ("ERROR", 2, 0)):
            with self.subTest(status=status):
                with tempfile.TemporaryDirectory() as root:
                    _prod, _specs, manifest = self.fixture(root)
                    argv = ["verify-tests", "--manifest", str(manifest), "--repo-root", root,
                            "--time-budget", "0", "--json"]
                    suite_result = result("suite", status, "assertion failed" if status == "FAIL"
                                          else "the suite never executed")
                    with mock.patch.object(vt.sys, "argv", argv):
                        with mock.patch.object(vt, "check_suite", return_value=suite_result) as suite:
                            with mock.patch.object(vt, "check_gate") as gate:
                                with mock.patch.object(vt, "check_coverage") as coverage:
                                    with mock.patch.object(vt, "check_typecheck") as types:
                                        with mock.patch.object(vt, "check_mutation") as mutation:
                                            out = io.StringIO()
                                            with contextlib.redirect_stdout(out):
                                                rc = vt.main()
                    self.assertEqual(rc, expected_rc)
                    suite.assert_called_once()
                    gate.assert_not_called()
                    coverage.assert_not_called()
                    types.assert_not_called()
                    mutation.assert_not_called()
                    self.assertNotIn("verification", json.loads(manifest.read_text()))
                    payload = json.loads(out.getvalue())
                    self.assertEqual(payload["pass"], expected_passes)
                    self.assertTrue(all(r["status"] == "DEFER" for r in payload["results"][1:5]))

    def test_main_production_drift_blocks_receipt(self):
        with tempfile.TemporaryDirectory() as root:
            prod, _specs, manifest = self.fixture(root)
            argv = ["verify-tests", "--manifest", str(manifest), "--repo-root", root,
                    "--time-budget", "0", "--skip", "coverage,typecheck,mutation", "--json"]
            def mutate_during_suite(_runner, _files, _root):
                prod.write_bytes(b"target = changed\n")
                return result("suite", "PASS")
            with mock.patch.object(vt.sys, "argv", argv):
                with mock.patch.object(vt, "check_suite", side_effect=mutate_during_suite):
                    with mock.patch.object(vt, "check_gate", return_value=result("coverage-gate", "PASS")):
                        output = io.StringIO()
                        with contextlib.redirect_stdout(output):
                            rc = vt.main()
            self.assertEqual(rc, 1)
            self.assertNotIn("verification", json.loads(manifest.read_text()))
            rows = {r["check"]: r for r in json.loads(output.getvalue())["results"]}
            self.assertEqual(rows["production-hash"]["status"], "FAIL")
            self.assertIn("production file changed during verification",
                          rows["production-hash"]["detail"])

    def test_main_measured_time_threshold_just_below_at_and_above(self):
        for measured, refused in ((14.9, False), (15.0, True), (15.1, True)):
            with self.subTest(measured=measured):
                with tempfile.TemporaryDirectory() as root:
                    _prod, _specs, manifest = self.fixture(root)
                    state = {"schema": vt.SCHEMA, "passes": 1, "budget": 3,
                             "time_budget_min": 15, "started_epoch": 1,
                             "measured_min": measured, "history": [
                                 {"pass": 1, "results": [result("suite", "PASS").to_dict()]}
                             ]}
                    Path(vt.state_path(str(manifest))).write_text(json.dumps(state))
                    argv = ["verify-tests", "--manifest", str(manifest), "--repo-root", root,
                            "--skip", "coverage,typecheck,mutation"]
                    with mock.patch.object(vt.sys, "argv", argv):
                        with mock.patch.object(vt, "check_suite", return_value=result("suite", "PASS")) as suite:
                            with mock.patch.object(vt, "check_gate", return_value=result("coverage-gate", "PASS")):
                                with contextlib.redirect_stdout(io.StringIO()):
                                    rc = vt.main()
                    self.assertEqual(rc == 4, refused)
                    self.assertEqual(suite.call_count, 0 if refused else 1)
                    persisted = json.loads(Path(vt.state_path(str(manifest))).read_text())
                    self.assertEqual(persisted["passes"], 1 if refused else 2)


if __name__ == "__main__":
    unittest.main()
