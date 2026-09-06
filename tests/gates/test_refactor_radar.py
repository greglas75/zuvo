"""Medium tests: real git and CLI, disposable files; no live provider calls."""

from __future__ import annotations

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts/lib"))
import radar_remote


ROOT = Path(__file__).resolve().parents[2]
RADAR = ROOT / "scripts/refactor-radar.sh"
SIMPLE = "export function route(x: number) { if (x) { return 1; } return 0; }\n"


class RadarRepo(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory(prefix="radar-test-")
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.repo = self.home / "repo with spaces"
        self.repo.mkdir()
        self.env = dict(
            os.environ, GIT_AUTHOR_DATE="2026-08-01T12:00:00Z", GIT_COMMITTER_DATE="2026-08-01T12:00:00Z"
        )
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.email", "fixture@example.invalid")
        self.git("config", "user.name", "Radar Fixture")
        self.write("src/order-service.ts", SIMPLE)
        self.write("src/unrelated.ts", SIMPLE)
        self.commit("chore: fixture")
        self.sequence = 0

    def git(self, *args: str, cwd: Path | None = None) -> str:
        proc = subprocess.run(
            ["git", "-C", str(cwd or self.repo), *args],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=15,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def write(self, path: str, content: str, repo: Path | None = None) -> Path:
        target = (repo or self.repo) / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(content, encoding="utf-8")
        return target

    def commit(self, message: str, repo: Path | None = None) -> None:
        paths = self.git("ls-files", "--modified", "--others", "--exclude-standard", cwd=repo).splitlines()
        if paths:
            self.git("add", "--", *paths, cwd=repo)
        self.git("commit", "-qm", message, cwd=repo)

    def invoke(self, *args: str, expected: int = 0) -> subprocess.CompletedProcess[str]:
        proc = subprocess.run(
            ["bash", str(RADAR), "--repo", str(self.repo), "--cutoff", "2026-09-05T12:00:00Z", *args],
            cwd=self.home,
            capture_output=True,
            text=True,
            env=self.env,
            timeout=30,
        )
        self.assertEqual(proc.returncode, expected, proc.stdout + proc.stderr)
        return proc

    def scan(self, *args: str) -> dict:
        self.sequence += 1
        target = self.home / f"report-{self.sequence}.json"
        self.invoke(
            "--no-remote", "--fresh-days", "0", "--min-cc", "1", "--json", str(target), "--quiet", *args
        )
        return json.loads(target.read_text())

    def row(self, report: dict, path: str) -> dict:
        matches = [r for r in report["rows"] + report["excluded_rows"] if path in r["files"]]
        self.assertEqual(len(matches), 1, f"Expected one candidate for {path}")
        return matches[0]


class RadarCLI(RadarRepo):
    def test_explicit_head_reads_committed_blobs_even_when_dirty(self) -> None:
        before = self.scan("--ref", "HEAD")
        self.write("src/order-service.ts", SIMPLE.replace("if (x)", "if (x && x > 3 || x < 0)"))
        after = self.scan("--ref", "HEAD")
        self.assertEqual(
            self.row(before, "src/order-service.ts")["sum"], self.row(after, "src/order-service.ts")["sum"]
        )
        self.assertEqual(self.row(after, "src/order-service.ts")["availability"], "BUSY")

    def test_nested_maximum_is_not_taken_from_only_the_max_cc_function(self) -> None:
        self.write(
            "src/order-service.ts",
            """
export function flat(x) { if (x) {} if (x) {} if (x) {} if (x) {} if (x) {} if (x) {} }
export function deep(x) { if (x) { if (x) { if (x) { if (x) { return 1; } } } } }
""",
        )
        self.commit("fix: fixture")
        candidate = self.row(self.scan(), "src/order-service.ts")
        self.assertEqual(candidate["nest"], 4)
        self.assertEqual(candidate["max_fn"], "flat")

    def test_detached_committed_worktree_is_busy(self) -> None:
        wt = self.home / "detached with spaces"
        self.git("worktree", "add", "-q", "--detach", str(wt), "HEAD")
        self.write("src/order-service.ts", SIMPLE + "// pending fix\n", repo=wt)
        self.commit("fix: detached", repo=wt)
        report = self.scan()
        self.assertEqual(self.row(report, "src/order-service.ts")["availability"], "BUSY")
        self.assertEqual(self.row(report, "src/unrelated.ts")["availability"], "UNKNOWN")

    def test_worktree_staged_unstaged_and_untracked_paths_are_collected(self) -> None:
        wt = self.home / "editing with spaces"
        self.git("worktree", "add", "-q", "-b", "task/anything", str(wt), "HEAD")
        self.write("src/order-service.ts", SIMPLE + "// staged\n", repo=wt)
        self.git("add", "--", "src/order-service.ts", cwd=wt)
        self.write("src/unrelated.ts", SIMPLE + "// unstaged\n", repo=wt)
        self.write("src/new-helper.ts", SIMPLE, repo=wt)
        report = self.scan()
        self.assertEqual(self.row(report, "src/order-service.ts")["availability"], "BUSY")
        self.assertEqual(self.row(report, "src/unrelated.ts")["availability"], "BUSY")
        self.assertIn("src/new-helper.ts", report["meta"]["busy"]["paths"])

    def test_name_only_reservation_is_unknown_not_an_exclusion(self) -> None:
        wt = self.home / "planned"
        self.git("worktree", "add", "-q", "-b", "refactor/order-service-split", str(wt), "HEAD")
        report = self.scan()
        candidate = self.row(report, "src/order-service.ts")
        self.assertIsNone(candidate["excluded"])
        self.assertEqual(candidate["availability"], "UNKNOWN")
        self.assertIn("refactor/order-service-split", candidate["reservation_hints"])

    def test_fresh_refactor_is_a_signal_not_a_blanket_exclusion(self) -> None:
        self.env.update(GIT_AUTHOR_DATE="2026-09-05T00:00:00Z", GIT_COMMITTER_DATE="2026-09-05T00:00:00Z")
        self.write("src/order-service.ts", SIMPLE + "// split\n")
        self.commit("refactor: split")
        report = self.scan("--fresh-days", "30", "--cutoff", "2026-09-05T12:00:00Z")
        candidate = self.row(report, "src/order-service.ts")
        self.assertIsNone(candidate["excluded"])
        self.assertTrue(candidate["fresh"])

    def test_same_stem_without_an_edge_does_not_merge_families(self) -> None:
        self.write("src/order-service.mapper.ts", SIMPLE)
        self.commit("feat: unrelated mapper")
        candidate = self.row(self.scan(), "src/order-service.ts")
        self.assertEqual(candidate["files"], ["src/order-service.ts"])

    def test_test_lines_never_prove_coverage_or_remove_test_candidates(self) -> None:
        self.write("src/order-service.test.ts", "// long test comment\n" * 200)
        self.commit("test: large file")
        report = self.scan("--mode", "tests")
        candidate = self.row(report, "src/order-service.ts")
        self.assertIsNone(candidate["excluded"])
        self.assertIsNone(candidate["coverage"])
        self.assertGreater(candidate["test_loc_ratio"], 1)
        self.assertEqual(candidate["rtype"], "COVER")

    def test_no_remote_means_unknown_not_free(self) -> None:
        candidate = self.row(self.scan(), "src/order-service.ts")
        self.assertEqual(candidate["availability"], "UNKNOWN")

    def test_repo_identity_never_serializes_remote_credentials(self) -> None:
        self.git(
            "remote",
            "add",
            "origin",
            "https://fixture@example.invalid:token-super-secret@github.com/owner/product.git?key=query-secret",
        )
        report = self.scan()
        self.assertEqual(report["meta"]["repo_id"], "https://github.com/owner/product")
        self.assertNotIn("token-super-secret", json.dumps(report))
        self.assertNotIn("query-secret", json.dumps(report))

    def test_exact_user_exclusion_does_not_exclude_same_basename_elsewhere(self) -> None:
        self.write("elsewhere/order-service.ts", SIMPLE)
        self.write(".radar.json", json.dumps({"exclude_paths": ["src/order-service.ts"]}))
        self.commit("chore: profile")
        report = self.scan()
        self.assertEqual(self.row(report, "src/order-service.ts")["excluded"], "user")
        self.assertIsNone(self.row(report, "elsewhere/order-service.ts")["excluded"])

    def test_tooling_profile_keeps_production_scripts(self) -> None:
        self.write("scripts/calc.py", "def compute(x):\n    if x:\n        return 1\n    return 0\n")
        self.write(".radar.json", json.dumps({"profile": "tooling"}))
        self.commit("feat: tooling")
        self.assertEqual(self.row(self.scan(), "scripts/calc.py")["sum"], 2)

    def test_scope_does_not_include_prefix_neighbour(self) -> None:
        self.write("src2/order-service.ts", SIMPLE)
        self.commit("feat: other directory")
        report = self.scan("--scope", "src")
        self.assertEqual(
            {p for r in report["rows"] for p in r["files"]}, {"src/order-service.ts", "src/unrelated.ts"}
        )

    def test_dry_run_does_not_create_queue_history_or_json(self) -> None:
        queue = self.home / "queue.md"
        queue.write_text("existing approved queue\n")
        history = self.home / "history"
        report = self.home / "ignored.json"
        self.invoke(
            "--no-remote",
            "--dry-run",
            "--queue",
            str(queue),
            "--history",
            str(history),
            "--json",
            str(report),
        )
        self.assertEqual(queue.read_text(), "existing approved queue\n")
        self.assertFalse(history.exists())
        self.assertFalse(report.exists())

    def test_skill_bash_example_runs_with_verified_paths(self) -> None:
        skill = (ROOT / "skills/refactor-radar/SKILL.md").read_text()
        block = skill.split("# >>> zuvo:refactor-radar-generate\n", 1)[1].split(
            "# <<< zuvo:refactor-radar-generate", 1
        )[0]
        proc = subprocess.run(
            ["bash", "-eu", "-c", block],
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=30,
            env=dict(self.env, RADAR=str(RADAR), REPO_ROOT=str(self.repo), TOP="1", SCOPE="src"),
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertIn("REFACTOR RADAR", proc.stdout)
        self.assertIn("src/order-service", proc.stdout)

    def test_bad_manifest_fails_with_usage_status_and_does_not_write(self) -> None:
        self.write(".radar.json", "{broken")
        target = self.home / "never.json"
        proc = self.invoke("--json", str(target), expected=2)
        self.assertIn("config", proc.stderr.lower())
        self.assertFalse(target.exists())

    def test_related_family_counts_one_fix_and_one_test_file(self) -> None:
        self.write("src/order-service.ts", "import { helper } from './order-service.helpers';\n" + SIMPLE)
        self.write("src/order-service.helpers.ts", "export function helper(x) { return x ? 1 : 0; }\n")
        self.write("src/order-service.test.ts", "import { helper } from './order-service.helpers';\n" * 4)
        self.commit("fix(orders): two files, one logical fix")
        report = self.scan()
        row = self.row(report, "src/order-service.ts")
        self.assertEqual(row["files"], ["src/order-service.helpers.ts", "src/order-service.ts"])
        self.assertEqual(row["fix"], 1)
        self.assertEqual(row["test_files"], ["src/order-service.test.ts"])
        self.assertEqual(row["test_loc_ratio"], 1.33)  # four test lines / three source lines

    def test_fix_prefix_is_not_a_fix_commit(self) -> None:
        self.write("src/order-service.ts", SIMPLE + "// not a conventional fix\n")
        self.commit("fixture: seed a case")
        row = self.row(self.scan(), "src/order-service.ts")
        self.assertEqual((row["fix"], row["unknown_churn"]), (0, 2))

    def test_fix_churn_ranks_above_feature_churn_for_equal_functions(self) -> None:
        self.write("src/order-service.ts", SIMPLE + "// corrected\n")
        self.commit("fix(orders): guard")
        self.write("src/unrelated.ts", SIMPLE + "// extended\n")
        self.commit("feat(other): optional mode")
        report = self.scan()
        self.assertEqual(report["rows"][0]["files"], ["src/order-service.ts"])
        self.assertEqual(self.row(report, "src/unrelated.ts")["feat"], 1)

    def test_fan_in_counts_unique_external_importers_not_edges_or_tests(self) -> None:
        self.write("src/order-service.ts", "import { helper } from './order-service.helpers';\n" + SIMPLE)
        self.write("src/order-service.helpers.ts", SIMPLE)
        self.write(
            "src/unrelated.ts",
            "import { a } from './order-service';\nimport { b } from './order-service.helpers';\n" + SIMPLE,
        )
        self.write("src/order-service.test.ts", "import { route } from './order-service';\n")
        self.commit("feat: graph")
        row = self.row(self.scan(), "src/order-service.ts")
        self.assertEqual(row["importers"], ["src/unrelated.ts"])
        self.assertEqual(row["fan_in"], 1)

    def test_nested_python_functions_do_not_double_count_decisions_or_strings(self) -> None:
        self.write(
            "src/calc.py",
            'def outer(x):\n    label = "if and or"\n    def inner(y):\n'
            "        if y:\n            return 1\n        return 0\n"
            "    if x:\n        return inner(x)\n    return 0\n",
        )
        self.commit("feat: python")
        row = self.row(self.scan(), "src/calc.py")
        self.assertEqual((row["n"], row["sum"], row["decisions"]), (2, 4, 2))

    def test_missing_git_repo_exits_three(self) -> None:
        proc = subprocess.run(
            ["bash", str(RADAR), "--repo", str(self.home)], capture_output=True, text=True, timeout=15
        )
        self.assertEqual(proc.returncode, 3)
        self.assertIn("not a git repo", proc.stderr)

    def test_installed_bundle_runs_in_another_repo_and_preserves_previous_bundle(self) -> None:
        target = self.home / "installed radar"
        command = [
            "bash",
            "-c",
            'source "$1"; install_refactor_radar_bundle "$2"',
            "fixture",
            str(ROOT / "scripts/install.sh"),
            str(target),
        ]
        first = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
        old_bundle = (target / "current").resolve()
        second = subprocess.run(command, capture_output=True, text=True, timeout=20)
        self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
        self.assertTrue((old_bundle / "lib/radar_cli.py").is_file())
        report = self.home / "installed.json"
        proc = subprocess.run(
            [
                "bash",
                str(target / "current/refactor-radar.sh"),
                "--repo",
                str(self.repo),
                "--no-remote",
                "--min-cc",
                "1",
                "--json",
                str(report),
            ],
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)
        self.assertEqual(self.row(json.loads(report.read_text()), "src/order-service.ts")["sum"], 2)

    def test_invalid_arguments_never_write_output(self) -> None:
        for args in [
            ("--top", "0"),
            ("--since", "-1"),
            ("--min-cc", "nan"),
            ("--fresh-days", "false"),
            ("--engine", "invented"),
            ("--scope", "../outside"),
            ("--top",),
            ("--mode", "unknown"),
        ]:
            with self.subTest(args=args):
                proc = self.invoke(*args, expected=2)
                self.assertNotEqual(proc.stderr.strip(), "")

    def test_config_zero_and_ordered_criticality_are_not_replaced_by_defaults(self) -> None:
        self.write(
            ".radar.json",
            json.dumps(
                {
                    "min_cc": 0,
                    "fresh_days": 0,
                    "critical": [{"pattern": "order", "k": 1}, {"pattern": "order-service", "k": 5}],
                }
            ),
        )
        report = self.scan()
        self.assertEqual(self.row(report, "src/order-service.ts")["k"], 1)
        for value in [True, -1, float("inf"), "5"]:
            self.write(".radar.json", json.dumps({"k_default": value}))
            self.assertIn("criticality", self.invoke(expected=2).stderr)

    def test_explicit_busy_file_reserves_exact_paths(self) -> None:
        busy = self.home / "busy.txt"
        busy.write_text("src/order-service.ts\n")
        report = self.scan("--busy-file", str(busy))
        self.assertEqual(self.row(report, "src/order-service.ts")["availability"], "BUSY")
        self.assertEqual(self.row(report, "src/unrelated.ts")["availability"], "UNKNOWN")

    def test_deleted_clean_worktree_does_not_leave_permanent_name_exclusion(self) -> None:
        wt = self.home / "ephemeral"
        self.git("worktree", "add", "-q", "-b", "refactor/order-service-split", str(wt), "HEAD")
        self.git("worktree", "remove", str(wt))  # branch remains; name is not an active reservation
        self.write(".radar.json", json.dumps({"remote": "none"}))
        report = self.scan_without_remote_override()
        row = self.row(report, "src/order-service.ts")
        self.assertEqual(row["availability"], "FREE")
        self.assertEqual(row["reservation_hints"], [])

    def scan_without_remote_override(self, *args: str) -> dict:
        self.sequence += 1
        target = self.home / f"registered-report-{self.sequence}.json"
        self.invoke("--fresh-days", "0", "--min-cc", "1", "--quiet", "--json", str(target), *args)
        return json.loads(target.read_text())

    def test_history_is_read_only_until_explicit_snapshot_record(self) -> None:
        history = self.home / "history"
        report = self.scan("--history", str(history), "--cutoff", "2026-09-05T12:00:00Z")
        self.assertFalse(history.exists())
        self.assertEqual(report["meta"]["policy_version"], "discovery-v2")
        self.scan("--history", str(history), "--record-snapshot", "--cutoff", "2026-09-05T12:00:00Z")
        self.assertEqual(len(list(history.glob("*.json"))), 1)
        self.scan("--history", str(history), "--record-snapshot", "--cutoff", "2026-09-05T12:00:00Z")
        self.assertEqual(len(list(history.glob("*.json"))), 1)

    def test_incompatible_history_cannot_penalize_new_candidate(self) -> None:
        history = self.home / "history"
        history.mkdir()
        (history / "old.json").write_text(
            json.dumps({"meta": {"schema": 1, "engine": "codesift"}, "rows": []})
        )
        before = self.scan("--cutoff", "2026-09-05T12:00:00Z")
        after = self.scan("--history", str(history), "--cutoff", "2026-09-05T12:00:00Z")
        self.assertEqual([r["score"] for r in before["rows"]], [r["score"] for r in after["rows"]])
        self.assertIsNone(after["meta"]["prev"])

    def test_fixed_inputs_have_stable_rows_and_fingerprint(self) -> None:
        before = self.scan("--cutoff", "2026-09-05T12:00:00Z")
        after = self.scan("--cutoff", "2026-09-05T12:00:00Z")
        self.assertEqual(before["rows"], after["rows"])
        self.assertEqual(before["meta"]["input_fingerprint"], after["meta"]["input_fingerprint"])

    def test_capture_and_reuse_busy_metadata_without_a_worktree_dependency(self) -> None:
        self.write(".radar.json", json.dumps({"remote": "none", "repo_id": "fixture/product"}))
        snapshot = self.home / "control.json"
        self.invoke("--capture-busy", str(snapshot))
        control = json.loads(snapshot.read_text())
        self.assertEqual((control["repo_id"], control["complete"]), ("fixture/product", True))
        report = self.scan_without_remote_override("--busy-snapshot", str(snapshot))
        self.assertEqual(self.row(report, "src/order-service.ts")["availability"], "FREE")
        control["captured_at"] = 0
        snapshot.write_text(json.dumps(control))
        stale = self.scan_without_remote_override("--busy-snapshot", str(snapshot))
        self.assertEqual(self.row(stale, "src/order-service.ts")["availability"], "UNKNOWN")

    def test_queue_requires_explicit_registration_and_never_overwrites(self) -> None:
        queue = self.home / "approved.md"
        queue.write_text("keep original queue\n")
        proc = self.invoke("--queue", str(queue), "--no-remote", expected=2)
        self.assertIn("--register", proc.stderr)
        target = self.repo / "src/order-service.ts"
        self.invoke("--json", str(target), "--no-remote", expected=2)
        self.assertEqual(target.read_text(), SIMPLE)
        self.assertEqual(queue.read_text(), "keep original queue\n")

    def test_register_only_validated_free_scope_and_bind_to_input(self) -> None:
        self.write(".radar.json", json.dumps({"remote": "none"}))
        fixed = ["--cutoff", "2026-09-05T12:00:00Z"]
        report = self.scan_without_remote_override(*fixed)
        decisions = self.home / "decisions.json"
        selection = {
            "input_fingerprint": report["meta"]["input_fingerprint"],
            "candidates": [
                {
                    "family": "src/order-service",
                    "type": "EXTRACT_METHODS",
                    "write_scope": ["src/order-service.ts"],
                    "verification_scope": ["test: route guard characterization"],
                    "gates": {key: True for key in ["G1", "G2", "G3", "G4", "G5"]},
                    "evidence": "Fixture route and guards verified",
                }
            ],
        }
        decisions.write_text(json.dumps(selection))
        queue = self.home / "queue.md"
        self.invoke(
            "--min-cc",
            "1",
            "--fresh-days",
            "0",
            *fixed,
            "--register",
            "--decisions",
            str(decisions),
            "--queue",
            str(queue),
        )
        self.assertIn("- [ ] src/order-service.ts | EXTRACT_METHODS | Score:", queue.read_text())
        self.assertIn('# write_scope=["src/order-service.ts"]', queue.read_text())
        selection["input_fingerprint"] = "stale"
        decisions.write_text(json.dumps(selection))
        proc = self.invoke(
            "--min-cc",
            "1",
            "--fresh-days",
            "0",
            *fixed,
            "--register",
            "--decisions",
            str(decisions),
            "--queue",
            str(self.home / "never.md"),
            expected=2,
        )
        self.assertIn("fingerprint", proc.stderr)
        self.assertFalse((self.home / "never.md").exists())

    def test_stale_or_incomplete_codesift_data_is_rejected(self) -> None:
        self.write(".radar.json", json.dumps({"repo_id": "fixture/product"}))
        envelope = self.home / "codesift.json"
        for sha, complete in [("0" * 40, True), (self.git("rev-parse", "HEAD"), False)]:
            envelope.write_text(
                json.dumps(
                    {
                        "meta": {
                            "repo": "fixture/product",
                            "sha": sha,
                            "complete": complete,
                            "version": "test",
                            "total_functions": 0,
                        },
                        "functions": [],
                    }
                )
            )
            proc = self.invoke(
                "--no-remote", "--engine", "codesift", "--codesift-json", str(envelope), expected=2
            )
            self.assertIn("CodeSift envelope", proc.stderr)

    def test_short_churn_window_is_not_expanded_by_freshness_window(self) -> None:
        self.write("src/order-service.ts", SIMPLE + "// old fix\n")
        self.commit("fix: old correction")
        report = self.scan("--since", "7", "--fresh-days", "60", "--cutoff", "2026-09-05T12:00:00Z")
        self.assertEqual(self.row(report, "src/order-service.ts")["fix"], 0)

    def test_mode_is_part_of_decision_fingerprint(self) -> None:
        before = self.scan("--mode", "refactor", "--cutoff", "2026-09-05T12:00:00Z")
        after = self.scan("--mode", "tests", "--cutoff", "2026-09-05T12:00:00Z")
        self.assertNotEqual(before["meta"]["input_fingerprint"], after["meta"]["input_fingerprint"])

    def test_invalid_flag_combinations_fail_before_creating_reports(self) -> None:
        for extra in [("--record-snapshot",), ("--capture-busy", str(self.home / "busy.json"), "--register")]:
            target = self.home / "never.json"
            self.invoke("--no-remote", "--json", str(target), *extra, expected=2)
            self.assertFalse(target.exists())

    def test_snapshot_cannot_claim_complete_with_an_incomplete_provider(self) -> None:
        self.write(".radar.json", json.dumps({"remote": "none"}))
        snapshot = self.home / "control.json"
        self.invoke("--capture-busy", str(snapshot))
        control = json.loads(snapshot.read_text())
        control["remote"]["complete"] = False
        snapshot.write_text(json.dumps(control))
        report = self.scan_without_remote_override("--busy-snapshot", str(snapshot))
        self.assertEqual(self.row(report, "src/order-service.ts")["availability"], "UNKNOWN")

    def test_expired_snapshot_does_not_permanently_exclude_old_worktree_paths(self) -> None:
        self.write(".radar.json", json.dumps({"remote": "none"}))
        self.write("src/order-service.ts", SIMPLE + "// previously busy\n")
        snapshot = self.home / "control.json"
        self.invoke("--capture-busy", str(snapshot))
        control = json.loads(snapshot.read_text())
        self.assertIn("src/order-service.ts", control["paths"])
        control["captured_at"] = 0
        snapshot.write_text(json.dumps(control))
        report = self.scan_without_remote_override("--busy-snapshot", str(snapshot))
        row = self.row(report, "src/order-service.ts")
        self.assertEqual(row["availability"], "UNKNOWN")
        self.assertIsNone(row["excluded"])
        self.assertIn("src/order-service.ts", report["meta"]["busy"]["expired_paths"])
        self.assertEqual(report["meta"]["busy"]["local"]["paths"], [])
        self.assertEqual(report["meta"]["busy"]["remote"]["paths"], [])

    def test_source_noise_and_seeds_are_not_production_candidates(self) -> None:
        for path in [
            "node_modules/copied.ts",
            ".worktrees/clone/src/order-service.ts",
            "prisma/seed-example.ts",
            "src/generated/output.ts",
            "docs/example.ts",
            "playwright-report/example.ts",
        ]:
            self.write(path, SIMPLE)
        self.commit("chore: fixture noise")
        report = self.scan()
        self.assertEqual(
            {p for row in report["rows"] for p in row["files"]}, {"src/order-service.ts", "src/unrelated.ts"}
        )

    def test_history_and_queue_have_unique_family_ids_for_same_stem(self) -> None:
        self.write(
            "src/order-service.mapper.ts", "import { helper } from './order-service.helper';\n" + SIMPLE
        )
        self.write("src/order-service.helper.ts", SIMPLE)
        self.write("src/order-service.py", "def route(x):\n    return x\n")
        self.commit("feat: independent families")
        rows = self.scan()["rows"]
        self.assertEqual(len({row["family"] for row in rows}), len(rows))

    def test_python_match_cases_are_counted_without_charging_the_default(self) -> None:
        self.write(
            "src/calc.py",
            "def calc(x):\n    match x:\n        case 1: return 10\n"
            "        case 2: return 20\n        case _: return 0\n",
        )
        self.commit("feat: python match")
        self.assertEqual(self.row(self.scan(), "src/calc.py")["sum"], 3)


class RemoteEvidence(unittest.TestCase):
    """Small tests: external CLI/HTTP responses only; no sockets or git repositories."""

    def test_github_lookup_is_explicit_and_file_pagination_is_complete(self) -> None:
        calls = []

        def respond(argv: list[str], root: Path) -> str:
            calls.append(argv[-1])
            if "/pulls?" in argv[-1]:
                return json.dumps(
                    [{"number": 9, "head": {"ref": "change", "sha": "a" * 40}, "base": {"ref": "main"}}]
                )
            if argv[-1].endswith("&page=1"):
                return json.dumps([{"filename": f"src/f{i}.ts"} for i in range(100)])
            return json.dumps([{"filename": "src/last.ts", "previous_filename": "src/old.ts"}])

        with patch.object(radar_remote, "command", side_effect=respond):
            result = radar_remote.collect(Path("."), {"remote": "gh", "gh_repo": "owner/product"}, False, "")
        self.assertTrue(result["complete"])
        self.assertIn("src/last.ts", result["paths"])
        self.assertIn("src/old.ts", result["paths"])
        self.assertEqual(
            calls,
            [
                "repos/owner/product/pulls?state=open&per_page=100&page=1",
                "repos/owner/product/pulls/9/files?per_page=100&page=1",
                "repos/owner/product/pulls/9/files?per_page=100&page=2",
            ],
        )

    def test_provider_failure_is_unknown_without_leaking_credentials(self) -> None:
        with patch.object(radar_remote, "command", side_effect=ValueError("token-super-secret")):
            result = radar_remote.collect(Path("."), {"remote": "gh", "gh_repo": "owner/product"}, False, "")
        self.assertFalse(result["complete"])
        self.assertEqual(result["errors"], ["gh: PR census incomplete (ValueError)"])
        self.assertNotIn("token-super-secret", json.dumps(result))

    def test_incomplete_pr_identity_is_not_a_complete_census(self) -> None:
        response = [{"number": 9, "head": {"ref": "change", "sha": None}, "base": {"ref": "main"}}]
        with patch.object(radar_remote, "command", return_value=json.dumps(response)):
            result = radar_remote.collect(Path("."), {"remote": "gh", "gh_repo": "owner/product"}, False, "")
        self.assertFalse(result["complete"])

    def test_bitbucket_malformed_diffstat_is_unknown(self) -> None:
        pages = [
            {
                "values": [
                    {
                        "id": 1,
                        "source": {"branch": {"name": "change"}, "commit": {"hash": "a" * 40}},
                        "destination": {"branch": {"name": "main"}},
                    }
                ]
            },
            {"values": [{}]},
        ]
        with (
            patch.dict(os.environ, {"RADAR_BB_TOKEN": "private"}),
            patch.object(radar_remote, "bb_page", side_effect=pages),
        ):
            result = radar_remote.collect(
                Path("."), {"remote": "bb", "bb_repo": "o/r", "bb_user": "fixture"}, False, ""
            )
        self.assertFalse(result["complete"])

    def test_no_remote_is_unknown_but_explicit_not_applicable_is_complete(self) -> None:
        with patch.object(radar_remote, "command") as boundary:
            skipped = radar_remote.collect(Path("."), {"remote": "none"}, True, "")
            not_applicable = radar_remote.collect(Path("."), {"remote": "none"}, False, "")
        boundary.assert_not_called()
        self.assertFalse(skipped["complete"])
        self.assertTrue(not_applicable["complete"])

    def test_bitbucket_next_link_cannot_send_auth_to_another_host(self) -> None:
        with (
            patch.object(radar_remote, "build_opener") as transport,
            self.assertRaisesRegex(ValueError, "unsafe pagination URL"),
        ):
            radar_remote.bb_page(
                "https://attacker.invalid/2.0/repositories/o/r/pullrequests",
                "/2.0/repositories/o/r",
                "secret",
            )
        transport.assert_not_called()

    def test_bitbucket_paginates_and_reads_changed_paths_not_branch_names(self) -> None:
        base = "https://api.bitbucket.org/2.0/repositories/o/r/pullrequests"
        pages = [
            {
                "values": [
                    {
                        "id": 2,
                        "source": {"branch": {"name": "unrelated-name"}, "commit": {"hash": "b" * 40}},
                        "destination": {"branch": {"name": "develop"}},
                    }
                ],
                "next": base + "?page=2",
            },
            {"values": []},
            {"values": [{"old": {"path": "src/a.ts"}, "new": {"path": "src/b.ts"}}]},
        ]
        with (
            patch.dict(os.environ, {"RADAR_BB_TOKEN": "private"}),
            patch.object(radar_remote, "bb_page", side_effect=pages) as transport,
        ):
            result = radar_remote.collect(
                Path("."), {"remote": "bb", "bb_repo": "o/r", "bb_user": "fixture"}, False, ""
            )
        self.assertTrue(result["complete"])
        self.assertEqual(result["paths"], ["src/a.ts", "src/b.ts"])
        self.assertEqual(
            [c.args[0] for c in transport.call_args_list],
            [base + "?state=OPEN&pagelen=100", base + "?page=2", base + "/2/diffstat?pagelen=100"],
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
