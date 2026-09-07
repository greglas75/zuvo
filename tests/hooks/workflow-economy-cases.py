#!/usr/bin/env python3
"""Negative fixtures for structural gates, proof semantics and instruction/evidence reuse."""

import json
import os
from pathlib import Path
import runpy
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "scripts/zuvo-home"))
from workflow_evidence import evidence_key  # noqa: E402

STATE = runpy.run_path(str(ROOT / "hooks/lib/refactor-state.py"))
CLI = ROOT / "scripts/zuvo-home/refactor-contract"
LOADER = ROOT / "scripts/zuvo-home/load-includes"


class Workflow(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.env = dict(os.environ, GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
        self.run_cmd(["git", "init", "-q"])
        (self.root / "src").mkdir()
        (self.root / "tests").mkdir()
        (self.root / "src/value").write_text("0")
        (self.root / "tests/check.sh").write_text(
            'if [ "$(cat src/value)" = 0 ]; then echo "Tests 1 failed"; exit 1; fi\necho "Tests 1 passed"\n'
        )
        self.contract = self.root / "refactor-abcdef12.json"
        self.data = {
            "kind": "refactor-contract",
            "version": 6,
            "file": "src/value",
            "stage": "PHASE-3",
            "fix_findings": [],
            "findings_outcome": "none",
            "scope_fence": ["src/value"],
            "modules_created": [],
            "prove": {
                "blind_audit": "clean",
                "adversarial": "clean",
                "test_quality": "N/A",
                "split_coverage": "N/A",
                "findings_disposition": "none",
            },
        }
        # State is output, not an input whose writes invalidate every test snapshot.
        (self.root / "zuvo/contracts").mkdir(parents=True)
        self.contract = self.root / "zuvo/contracts/refactor-abcdef12.json"
        self.save()

    def run_cmd(self, cmd, **kwargs):
        return subprocess.run(cmd, cwd=self.root, env=self.env, capture_output=True, text=True, **kwargs)

    def cli(self, *args):
        return self.run_cmd([sys.executable, str(CLI), "--contract", str(self.contract), *args])

    def save(self):
        self.contract.write_text(json.dumps(self.data))

    def read(self):
        return json.loads(self.contract.read_text())

    def characterize(self):
        self.assertEqual(self.cli("baseline", "printf 'Tests 2 passed\\n'").returncode, 0)
        self.assertEqual(self.cli("recheck").returncode, 0)

    def errors(self):
        # Evidence logs resolve relative to the checkout, as they do in the real CLI and hook.
        result = self.run_cmd(
            [sys.executable, str(ROOT / "hooks/lib/refactor-state.py"), str(self.contract), "evidence"]
        )
        return result

    def test_legacy_target_names_resolve_without_migrating_the_contract(self):
        result = self.run_cmd([sys.executable, str(CLI), "--file", "src/value", "show"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read()["version"], 6)
        self.assertTrue(self.contract.exists())

    def test_installed_helpers_use_bundled_reader_and_gate_over_stale_claude(self):
        with tempfile.TemporaryDirectory() as home:
            self.env["HOME"] = home
            stale = Path(home) / ".claude/hooks/lib"
            stale.mkdir(parents=True)
            stale_reader = "raise RuntimeError('stale Claude reader was loaded')\n"
            (stale / "refactor-state.py").write_text(stale_reader)
            (stale / "refactor-gate-lib.sh").write_text(
                "refactor_gate_check() { return 0; }\nrefactor_prove_v4_check() { return 0; }\n"
            )
            result = self.run_cmd([
                "bash", "-c", '. "$1"; install_zuvo_home; test "$INSTALL_VERIFY_MISSING" -eq 0',
                "install-helpers", str(ROOT / "scripts/install.sh"),
            ])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            bundle = Path(home) / ".zuvo"
            for name in ("refactor-state.py", "refactor-gate-lib.sh", "agent-env.sh"):
                self.assertEqual((bundle / name).read_bytes(), (ROOT / "hooks/lib" / name).read_bytes())
            self.assertEqual((stale / "refactor-state.py").read_text(), stale_reader)

            def installed(*args):
                return self.run_cmd([
                    sys.executable, str(bundle / "refactor-contract"),
                    "--contract", str(self.contract), *args,
                ])

            for args in (("baseline", "printf 'Tests 2 passed\\n'"), ("recheck",),
                         ("stage", "PHASE-3"), ("check",)):
                result = installed(*args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            report = self.quality_report()
            result = installed("prove", "test_quality", "PASS:B:" + report + "; commentary")
            self.assertEqual(result.returncode, 2)
            self.assertIn("supply only the report path", result.stderr)
            self.data = self.read()
            self.data["cq_after"] = {"status": "INCOMPLETE"}
            self.save()
            result = installed("check")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("cq_after.status=INCOMPLETE", result.stdout)
            self.assertEqual(installed("stage", "COMPLETE").returncode, 1)

    def test_helper_install_verification_detects_corrupt_reader_copy(self):
        with tempfile.TemporaryDirectory() as home:
            self.env["HOME"] = home
            result = self.run_cmd([
                "bash", "-c",
                '. "$1"; cp() { case "$1" in */hooks/lib/refactor-state.py) '
                'printf "stale reader\\n" > "$2" ;; *) command cp "$@" ;; esac; }; '
                'install_zuvo_home; test "$INSTALL_VERIFY_MISSING" -gt 0',
                "install-corrupt-reader", str(ROOT / "scripts/install.sh"),
            ])
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("refactor-contract dependency refactor-state.py did not match", result.stdout)

    def test_nested_prove_cannot_supply_missing_real_proof(self):
        self.data["previous"] = {"prove": {"adversarial": "clean"}, "stage": "COMPLETE"}
        self.data["prove"]["adversarial"] = "not_run"
        self.save()
        result = self.run_cmd(
            [
                sys.executable,
                str(ROOT / "hooks/lib/refactor-state.py"),
                str(self.contract),
                "field",
                "prove.adversarial",
            ]
        )
        self.assertEqual(result.stdout.strip(), "not_run")
        self.assertEqual(self.cli("check").returncode, 1)

    def test_prose_path_is_not_scope(self):
        self.data["note"] = "src/elsewhere"
        self.save()
        result = self.run_cmd(
            [
                sys.executable,
                str(ROOT / "hooks/lib/refactor-state.py"),
                str(self.contract),
                "contains",
                "scope_fence",
                "src/elsewhere",
            ]
        )
        self.assertEqual(result.returncode, 1)

    def test_bom_legacy_and_arrays_duplicate_keys_wrong_kind(self):
        self.contract.write_text('\ufeff{"file":"src/value","stage":"PHASE-2"}')
        self.assertIsNotNone(STATE["read_contract"](self.contract))
        for text in (
            "[]",
            '{"stage":"COMPLETE","stage":"PHASE-1"}',
            '{"kind":"findings","stage":"COMPLETE"}',
            '{"prove":[]}',
            "{",
        ):
            self.contract.write_text(text)
            self.assertIsNone(STATE["read_contract"](self.contract), text)
            self.assertNotEqual(self.cli("check").returncode, 0)

    def test_characterization_never_fabricates_red(self):
        self.characterize()
        c = self.read()
        self.assertNotIn("regression_red", c["prove"])
        self.assertEqual(self.errors().returncode, 0)
        self.assertEqual(self.cli("check").returncode, 0)

    def test_v6_phase_three_requires_complexity_only_for_reduction_intents(self):
        self.assertEqual(self.cli("baseline", "printf 'Tests 2 passed\\n'").returncode, 0)
        original = self.read()
        for kind in ("EXTRACT_METHODS", "MOVE", "RENAME", "SPLIT_FILE", "GOD_CLASS", "SIMPLIFY"):
            self.data = json.loads(json.dumps(original))
            self.data.update(type=kind, stage="PHASE-2")
            self.save()
            result = self.cli("stage", "PHASE-3")
            expected = 1 if kind in ("SPLIT_FILE", "GOD_CLASS", "SIMPLIFY") else 0
            self.assertEqual(result.returncode, expected, result.stderr)
            if expected:
                self.assertIn("complexity_before", result.stderr)
                self.assertEqual(self.read()["stage"], "PHASE-2")
                self.assertEqual(
                    self.cli("prove", "complexity_before", "maxfn:80,branches:10,loc:200").returncode, 0
                )
                self.assertEqual(self.cli("stage", "PHASE-3").returncode, 0)
        self.data = original
        self.data.update(version=5, type="EXTRACT_METHODS", stage="PHASE-2")
        self.save()
        self.assertEqual(self.cli("stage", "PHASE-3").returncode, 1)

    def test_v6_no_fix_narrative_needs_no_red_in_cli_or_gate(self):
        self.characterize()
        self.data = self.read()
        self.data["prove"]["findings_disposition"] = "none; no production fix-now finding"
        self.save()
        for stage in ("PHASE-3.5", "PHASE-3.6", "PHASE-4", "COMPLETE"):
            result = self.cli("stage", stage)
            self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.cli("check").returncode, 0)
        self.data = self.read()
        self.data["stage"] = "PHASE-3.6"
        self.save()
        self.assertEqual(self.cli("check").returncode, 0)
        self.data["findings_outcome"] = "fixed"
        self.save()
        result = self.cli("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("fix_findings", result.stdout)
        self.assertIn("regression_red", result.stdout)

    def quality_report(self, content="Tier/status: B; complete assessment\n", name="test quality.md"):
        path = self.root / "zuvo/audits" / name
        path.parent.mkdir(exist_ok=True)
        path.write_text(content)
        return "zuvo/audits/" + name

    def test_v6_test_quality_writer_rejects_bad_paths_without_mutation(self):
        report = self.quality_report()
        for value in ("PASS tests", "WARN:B:missing.md", "PASS:B:/etc/passwd",
                      "WARN:B:../outside.md", "PASS:B:" + report + "; review completed"):
            previous = self.contract.read_bytes()
            result = self.cli("prove", "test_quality", value)
            self.assertEqual(result.returncode, 2, result.stderr)
            self.assertIn("prove.test_quality", result.stderr)
            self.assertEqual(self.contract.read_bytes(), previous)
        for value in ("PASS:B:" + report, "WARN:B:" + report, "N/A", "N/A:no tests changed"):
            result = self.cli("prove", "test_quality", value)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(self.read()["prove"]["test_quality"], value)

    def test_v6_quality_warn_is_complete_but_incomplete_report_is_not(self):
        self.characterize()
        report = self.quality_report()
        self.assertEqual(self.cli("prove", "test_quality", "WARN:B:" + report).returncode, 0)
        result = self.cli("check")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("QUALITY: WARN", result.stdout)
        self.assertEqual(self.cli("stage", "COMPLETE").returncode, 0)
        self.quality_report("Tier/status: C: Q7 formal INCOMPLETE\n")
        self.data = self.read()
        self.data["stage"] = "PHASE-4"
        self.save()
        result = self.cli("check")
        self.assertEqual(result.returncode, 1)
        self.assertIn("INCOMPLETE", result.stdout)
        self.assertEqual(self.cli("prove", "test_quality", "PASS:B:" + report).returncode, 2)
        self.assertEqual(self.cli("stage", "COMPLETE", "--force").returncode, 1)

    def test_v6_current_cq_assessment_blocks_completion_and_quality_pass(self):
        self.characterize()
        report = self.quality_report()
        original = self.read()
        for assessment in ({"status": "INCOMPLETE"},
                           {"status": "WARN", "files": [{"status": "INCOMPLETE: N/A cap exceeded"}]},
                           {"status": "WARN", "critical_failures": ["CQ14"]},
                           {"status": "WARN", "files": [{"status": "FAIL"}]}):
            self.data = json.loads(json.dumps(original))
            self.data["cq_after"] = assessment
            self.data["prove"]["test_quality"] = "WARN:B:" + report
            self.save()
            self.assertEqual(self.cli("stage", "COMPLETE").returncode, 1)
            self.assertEqual(self.cli("stage", "COMPLETE", "--force").returncode, 1)
            result = self.cli("check")
            self.assertEqual(result.returncode, 1)
            self.assertIn("cq_after", result.stdout)
            self.assertEqual(self.cli("prove", "test_quality", "PASS:B:" + report).returncode, 2)
        self.data = original
        self.data["cq_before"] = {"status": "INCOMPLETE", "critical_failures": ["CQ14"]}
        self.data["cq_after"] = {
            "status": "CONDITIONAL PASS", "critical_failures": [], "note": "Fixed prior INCOMPLETE"
        }
        self.save()
        self.quality_report(
            "Historical finding: INCOMPLETE before remediation.\nTier/status: B; complete assessment\n"
        )
        self.assertEqual(self.cli("prove", "test_quality", "PASS:B:" + report).returncode, 0)
        self.assertEqual(self.cli("stage", "COMPLETE").returncode, 0)
        self.assertEqual(self.cli("check").returncode, 0)

    def test_v6_report_current_status_does_not_reopen_resolved_history(self):
        self.characterize()
        for content in (
            "Status: PASS (previous FAIL fixed)\n",
            "Status: PASS; FAIL on the pre-fix baseline run\n",
            "Tier/status: A: PASS; BLOCKED items resolved\n",
            "## History\nStatus: INCOMPLETE\n### First audit\nVerdict: FAIL\n"
            "## Current\n[GATE: test-quality] PASS (previous INCOMPLETE resolved)\n",
            "## Test Quality — Historical Baseline\nVerdict: FAIL\n"
            "## Current\n[GATE: test-quality] PASS\n",
            "## Version History\nStatus: INCOMPLETE\n## Current\nStatus: PASS\n",
            "## Appendix A — Historical Runs\nStatus: FAIL\n## Current\nStatus: PASS\n",
            "[GATE: test-quality] INCOMPLETE\n[GATE: test-quality] WARN (previous FAIL fixed)\n",
            "Status: INCOMPLETE\nStatus: PASS (prior incomplete resolved)\n",
            "## Current\n```text\nStatus: FAIL\n```\nStatus: PASS\n",
        ):
            report = self.quality_report(content)
            claim = "WARN:B:" if "[GATE: test-quality] WARN" in content else "PASS:B:"
            result = self.cli("prove", "test_quality", claim + report)
            self.assertEqual(result.returncode, 0, result.stderr)
            result = self.cli("check")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for content in (
            "## History\nStatus: PASS\n## Current\nStatus: INCOMPLETE\n",
            "[GATE: test-quality] PASS\n[GATE: test-quality] FAIL\n",
            "## File one\nStatus: INCOMPLETE\n## File two\nStatus: PASS\n"
            "[GATE: test-quality] WARN\n",
            "Tier/status: C: unverified whole-file coverage; Q7 formal INCOMPLETE also retained.\n",
            "[GATE: test-quality] WARN worst=C; formal Q7 INCOMPLETE\n",
            "Status: \n",
            "## Current results compared with baseline\nStatus: INCOMPLETE\n",
            "## Results vs baseline\n[GATE: test-quality] FAIL\n",
            "## No previous issues\nStatus: FAIL\n",
            "## Q7 baseline verification\nStatus: INCOMPLETE\n",
        ):
            report = self.quality_report(content)
            self.data = self.read()
            self.data["prove"]["test_quality"] = "WARN:B:" + report
            self.save()
            result = self.cli("check")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("prove.test_quality: assessment", result.stdout)

    def test_v6_assessment_maps_and_malformed_metadata_cannot_hide_failures(self):
        self.characterize()
        original = self.read()
        for assessment in (
            {"files": {"src/a.py": {"status": "INCOMPLETE"}}},
            {"files": {"src/a.py": {"status": "WARN", "critical_failures": ["CQ14"]}}},
            {"gates": {"CQ14": {"status": "FAIL"}}},
            {"assessments": {"current": [{"status": "INCOMPLETE"}]}},
            {"status": {"unexpected": "PASS"}},
            {"status": "pending"},
            {"score": {"unexpected": "PASS"}},
            {"files": None},
            {"files": {"src/a.py": None}},
            {"critical_failures": False},
            {"CQ3": {"status": "FAILED"}},
            {"results": {"status": "FAIL"}},
            {"modules": {"reader": {"status": "INCOMPLETE"}}},
            {},
            {"files": {}},
            {"assessments": {"security": "FAIL"}},
        ):
            self.data = json.loads(json.dumps(original))
            self.data["cq_after"] = assessment
            self.save()
            result = self.cli("check")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("cq_after", result.stdout)
            self.assertEqual(self.cli("stage", "COMPLETE", "--force").returncode, 1)
        self.data = original
        self.data["cq_after"] = {"status": "PASS", "files": {
            "src/a.py": {"status": "PASS", "critical_failures": [], "note": "previous FAIL fixed"},
            "src/b.py": {"status": "CONDITIONAL PASS", "gates": {"CQ14": {"status": "PASS"}}},
        }}
        self.data["cq_after"].update(config={}, scope={}, prove={})
        self.save()
        self.assertEqual(self.cli("check").returncode, 0)
        self.assertEqual(self.cli("stage", "COMPLETE").returncode, 0)

    def test_v6_pass_claim_cannot_promote_current_warn_report(self):
        self.characterize()
        for content in ("Status: WARN\n", "[GATE: test-quality] WARN worst=B\n",
                        "Tier/status: A: PASS; Q7 formal WARN\n",
                        "[GATE: test-quality] PASS; formal Q7 WARN\n"):
            report = self.quality_report(content)
            result = self.cli("prove", "test_quality", "PASS:B:" + report)
            self.assertEqual(result.returncode, 2)
            self.assertIn("PASS contradicts current report WARN", result.stderr)
            self.data = self.read()
            self.data["prove"]["test_quality"] = "PASS:B:" + report
            self.save()
            self.assertEqual(self.cli("check").returncode, 1)
            self.assertEqual(self.cli("stage", "COMPLETE").returncode, 1)
            self.assertEqual(self.cli("prove", "test_quality", "WARN:B:" + report).returncode, 0)
            result = self.cli("check")
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("QUALITY: WARN", result.stdout)

    def test_v6_version_normalization_applies_to_cli_and_hook(self):
        self.characterize()
        original = self.read()
        for version in (6, "6", " 6 ", "+6"):
            self.data = json.loads(json.dumps(original))
            self.data["version"] = version
            self.data["cq_after"] = {"status": "INCOMPLETE"}
            self.save()
            report = self.quality_report()
            self.assertEqual(self.cli("prove", "test_quality", "PASS:B:" + report).returncode, 2)
            self.assertEqual(self.cli("stage", "COMPLETE").returncode, 1)
            result = self.cli("check")
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertIn("cq_after.status=INCOMPLETE", result.stdout)

    def test_null_prove_is_rejected_before_candidate_construction(self):
        self.data["prove"] = None
        self.save()
        result = self.cli("prove", "test_quality", "N/A")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("unreadable contract", result.stderr)

    def test_no_tests_and_reused_run_cannot_supply_characterization(self):
        self.assertEqual(self.cli("baseline", "true").returncode, 1)
        self.characterize()
        self.data = self.read()
        self.data["evidence"]["characterization_after"] = self.data["evidence"]["characterization_before"]
        self.save()
        self.assertNotEqual(self.errors().returncode, 0)

    def test_explicit_compilation_and_subdirectory_check(self):
        self.data["test_mode"] = "VERIFY_COMPILATION"
        self.save()
        self.assertEqual(self.cli("baseline", "--mode", "compilation", "true").returncode, 0)
        self.assertEqual(self.cli("recheck").returncode, 0)
        result = subprocess.run(
            [sys.executable, str(CLI), "--contract", str(self.contract), "check"],
            cwd=self.root / "src",
            env=self.env,
            capture_output=True,
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fix_proof_is_not_optional_via_different_wording(self):
        self.characterize()
        self.data = self.read()
        self.data["prove"]["findings_disposition"] = "resolved review issues"
        self.data["findings_outcome"] = "fixed"
        self.save()
        self.assertNotEqual(self.errors().returncode, 0)

    def test_green_green_does_not_prove_a_fix(self):
        self.characterize()
        self.data = self.read()
        self.data["prove"]["findings_disposition"] = "fixed:1"
        self.data["prove"]["regression_red"] = "PASS -> PASS"
        self.data["fix_findings"] = ["F1"]
        self.save()
        self.assertNotEqual(self.errors().returncode, 0)
        self.assertEqual(self.cli("stage", "COMPLETE").returncode, 1)

    def test_green_without_executed_tests_is_refused(self):
        (self.root / "tests/check.sh").write_text(
            'if [ "$(cat src/value)" = 0 ]; then echo "Tests 1 failed"; exit 1; fi\nexit 0\n'
        )
        self.assertEqual(self.cli("regression", "F1", "red", "sh tests/check.sh").returncode, 0)
        (self.root / "src/value").write_text("1")
        self.assertEqual(self.cli("regression", "F1", "green", "sh tests/check.sh").returncode, 1)
        self.assertNotIn("green", self.read()["evidence"]["fix_regressions"][0])

    def test_invalid_compilation_mode_does_not_execute_the_command(self):
        result = self.cli("baseline", "--mode", "compilation", "touch command-ran")
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "command-ran").exists())

    def test_actual_red_green_is_linked_and_test_weakening_invalidates(self):
        self.characterize()
        self.assertEqual(self.cli("regression", "F1", "red", "sh tests/check.sh").returncode, 0)
        (self.root / "src/value").write_text("1")
        self.assertEqual(self.cli("regression", "F1", "green", "sh tests/check.sh").returncode, 0)
        self.assertEqual(self.cli("recheck").returncode, 0)
        self.data = self.read()
        self.data["fix_findings"] = ["F1"]
        self.data["prove"]["findings_disposition"] = "fixed:1"
        self.save()
        self.assertEqual(self.errors().returncode, 0)
        (self.root / "tests/check.sh").write_text('echo "Tests 1 passed"\n')
        self.assertEqual(self.cli("regression", "F1", "green", "sh tests/check.sh").returncode, 0)
        self.assertNotEqual(self.errors().returncode, 0)

    def test_infrastructure_failure_and_changed_command_are_not_regression_proof(self):
        self.assertEqual(self.cli("regression", "F1", "red", "exit 127").returncode, 1)
        self.assertEqual(self.cli("regression", "F1", "red", "sh tests/check.sh").returncode, 0)
        self.assertEqual(self.cli("regression", "F1", "green", "printf 'Tests 1 passed'").returncode, 2)

    def test_failed_baseline_cannot_become_unchanged_green(self):
        self.assertEqual(self.cli("baseline", "sh tests/check.sh").returncode, 1)
        (self.root / "src/value").write_text("1")
        self.assertEqual(self.cli("recheck").returncode, 1)

    def test_changed_source_cannot_reuse_old_characterization(self):
        self.characterize()
        (self.root / "src/value").write_text("changed after verification")
        self.assertNotEqual(self.errors().returncode, 0)

    def test_evidence_from_another_checkout_is_not_reused(self):
        self.characterize()
        self.data = self.read()
        self.data["evidence"]["characterization_after"]["repo_root"] = str(self.root / "different-checkout")
        self.save()
        self.assertNotEqual(self.errors().returncode, 0)

    def test_boolean_results_and_false_green_are_rejected(self):
        self.characterize()
        original = self.read()
        for field, value in (("exit_code", False), ("passed", True), ("failed", 1)):
            self.data = json.loads(json.dumps(original))
            self.data["evidence"]["characterization_after"][field] = value
            self.save()
            self.assertNotEqual(self.errors().returncode, 0, field)

    def test_malformed_evidence_reports_a_diagnostic(self):
        self.characterize()
        self.data = self.read()
        self.data["evidence"] = ["wrong shape"]
        self.save()
        result = self.errors()
        self.assertIn("invalid object", result.stdout)
        self.assertNotIn("Traceback", result.stderr)
        self.data["evidence"] = {"fix_regressions": [{}]}
        self.save()
        result = self.cli("regression", "F1", "green", "true")
        self.assertEqual(result.returncode, 2)
        self.assertNotIn("Traceback", result.stderr)

    def test_atomic_write_rejects_stale_read_and_accepts_next_current_write(self):
        module = runpy.run_path(str(CLI))
        path = str(self.contract)
        old = module["read_json"](path)
        self.data["progress"] = ["other writer"]
        self.save()
        self.assertFalse(module["write_atomic"](path, old))
        self.assertEqual(self.read()["progress"], ["other writer"])
        current = module["read_json"](path)
        current["progress"].append("our write")
        self.assertTrue(module["write_atomic"](path, current))
        current["progress"].append("next write")
        self.assertTrue(module["write_atomic"](path, current))
        self.assertEqual(self.read()["progress"], ["other writer", "our write", "next write"])

    def test_log_tampering_invalidates_record(self):
        self.characterize()
        log = self.root / self.read()["evidence"]["characterization_before"]["log"]
        log.write_text("invented")
        self.assertNotEqual(self.errors().returncode, 0)

    def key(self, **changes):
        args = dict(
            command="test",
            scope=["tests/check.sh"],
            toolchain="python-3/cache-a",
            environment="runner-a/services-v1",
        )
        args.update(changes)
        return evidence_key(self.root, **args)

    def test_every_reuse_input_invalidates_key(self):
        base = self.key()
        self.assertEqual(base, self.key())
        for change in (
            {"command": "test --flag"},
            {"scope": ["other"]},
            {"toolchain": "new"},
            {"environment": "new"},
        ):
            self.assertNotEqual(base, self.key(**change))
        for name in ("src/value", "tests/check.sh", "package-lock.json", "test.config.json"):
            path = self.root / name
            before = self.key()
            path.write_text("changed")
            self.assertNotEqual(before, self.key(), name)
        with self.assertRaises(ValueError):
            self.key(environment="unknown")

    def test_staging_a_deletion_does_not_invalidate_content_proof(self):
        self.run_cmd(["git", "add", "src/value"])
        (self.root / "src/value").unlink()
        before = self.key()
        self.run_cmd(["git", "add", "src/value"])
        self.assertEqual(before, self.key())

    def test_recheck_refuses_a_run_that_changes_inputs(self):
        (self.root / "tests/stable.sh").write_text(
            'if [ "$(cat src/value)" = change ]; then echo changed > src/value; fi\necho "Tests 2 passed"\n'
        )
        self.assertEqual(self.cli("baseline", "sh tests/stable.sh").returncode, 0)
        (self.root / "src/value").write_text("change")
        self.assertEqual(self.cli("recheck").returncode, 1)
        self.assertEqual(self.read()["prove"]["characterization_after"], "not_run")

    def test_duplicate_fix_entries_are_refused_before_running(self):
        self.data["evidence"] = {"fix_regressions": [{"finding_id": "F1"}, {"finding_id": "F1"}]}
        self.save()
        result = self.cli("regression", "F1", "red", "touch command-ran")
        self.assertEqual(result.returncode, 2)
        self.assertFalse((self.root / "command-ran").exists())

    def test_native_summary_parsers_and_unknown_output(self):
        parser = runpy.run_path(str(CLI))["parse_counts"]
        cases = [
            ("=== 2 failed, 3 passed in 0.1s ===", (3, 2)),
            ("test result: ok. 4 passed; 0 failed; 0 ignored;", (4, 0)),
            ("# pass 3\n# fail 1", (3, 1)),
            ("Ran 4 tests in 0.3s\n\nFAILED (failures=1, errors=1)", (2, 2)),
            ("Ran 1 test in 0.1s\nOK", (1, 0)),
            ("OK (3 tests, 7 assertions)", (3, 0)),
            ("RESULT: PASS=4 FAIL=1 SKIP=2", (4, 1)),
            ("Tests 7 passed\nTests 1 failed", (0, 1)),
            ("the build passed; no test summary", (None, None)),
        ]
        for output, expected in cases:
            self.assertEqual(parser(output), expected, output)

    def test_output_artifact_does_not_invalidate_key(self):
        before = self.key()
        (self.root / "zuvo/result.json").write_text("report")
        self.assertEqual(before, self.key())

    def load(self, *args):
        self.env["ZUVO_BASE"] = str(ROOT)
        return self.run_cmd(
            [sys.executable, str(LOADER), "refactor", "--files", str(self.root / "rule.md"), *args]
        )

    def test_read_once_needs_matching_generation_and_hash(self):
        rule = self.root / "rule.md"
        rule.write_text("FULL RULE BODY")
        receipt = str(self.root / "receipt.json")
        first = self.load("--generation", "A", "--receipt-out", receipt)
        self.assertIn("FULL RULE BODY", first.stdout)
        second = self.load("--generation", "A", "--retained", receipt)
        self.assertNotIn("FULL RULE BODY", second.stdout)
        self.assertIn("retained: 1", second.stdout)
        self.assertIn("FULL RULE BODY", self.load("--generation", "B", "--retained", receipt).stdout)
        rule.write_text("CHANGED RULE BODY")
        self.assertIn("CHANGED RULE BODY", self.load("--generation", "A", "--retained", receipt).stdout)

    def test_manifest_cannot_launder_a_read(self):
        (self.root / "rule.md").write_text("FULL RULE BODY")
        receipt = str(self.root / "receipt.json")
        self.load("--generation", "A", "--manifest-only", "--receipt-out", receipt)
        self.assertIn("FULL RULE BODY", self.load("--generation", "A", "--retained", receipt).stdout)

    def test_all_refactor_phases_exist_and_preserve_final_gates(self):
        skill = ROOT / "skills/refactor"
        router = (skill / "SKILL.md").read_text()
        names = (
            "bootstrap",
            "planning",
            "characterization",
            "transformation",
            "review",
            "remediation",
            "completion",
        )
        for name in names:
            self.assertIn("references/" + name + ".md", router)
            self.assertGreater(len((skill / "references" / (name + ".md")).read_text()), 500)
        self.assertIn("refactor-contract --contract", (skill / "references/completion.md").read_text())
        self.assertNotIn("sed -n", router)


if __name__ == "__main__":
    unittest.main(verbosity=2)
