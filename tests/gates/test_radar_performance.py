"""Medium integration gates (filesystem/subprocess) and bounded in-process scale probes."""

from copy import deepcopy
import json
import os
import random
import re
import subprocess
import time
import unittest
from unittest.mock import patch

from test_refactor_radar import RadarRepo
import radar_cli as cli
import radar_git as git
import radar_metrics as metrics
import radar_runtime
import radar_snapshot


def census(size: int) -> dict:
    sources = [f"src/m{i}.ts" for i in range(size)]
    tests = [f"src/m{i}.test.ts" for i in range(size)]
    return dict(
        sources=sources,
        tests=tests,
        contents={p: "line\n\nsecond\n" for p in sources + tests},
        metrics={p: [dict(name="work", cc=2, line=1, lines=3, nest=1)] for p in sources},
        graph={p: {sources[(i + 1) % size]} for i, p in enumerate(sources + tests)},
        commits=[dict(id=str(i), files=[p], epoch=1000, kind="fix") for i, p in enumerate(sources)],
        cutoff=2000,
        since_days=180,
        fresh_days=30,
        scope=".",
        min_cc=1,
        mode="refactor",
        cfg={},
        busy=dict(complete=True, paths=[], hints=[]),
    )


class WalkBudget(list):
    """A deterministic complexity assertion, independent of host wall-clock/load."""

    def __init__(self, values):
        super().__init__(values)
        self.walks = 0

    def __iter__(self):
        self.walks += 1
        if self.walks > 3:
            raise AssertionError("repeated full-census walk")
        return super().__iter__()

    def __contains__(self, value):
        raise AssertionError("linear source membership in ranking")


class RadarScaling(unittest.TestCase):
    def test_rank_indexes_each_census_once_not_per_family(self):
        data = census(40)
        groups = metrics.families(data["sources"], data["graph"], {})
        for key in ("sources", "tests", "commits"):
            data[key] = WalkBudget(data[key])
        rows, excluded, floor = metrics.rank(groups, data)
        self.assertEqual((len(rows), excluded, floor), (40, [], 1))
        # Contract: sigma * sqrt(fix + 1) * default K = 2 * sqrt(2) * 3.
        self.assertEqual(rows[0]["score"], 8.485281)
        self.assertEqual(rows[0]["fix"], 1)

    def test_seeded_family_projections_match_brute_force_for_every_family(self):
        data = census(90)
        rng = random.Random(6092026)
        paths = data["sources"]
        data["graph"] = {p: set(rng.sample(paths, 4)) for p in paths + data["tests"]}
        for commit in data["commits"]:
            commit.update(files=rng.sample(paths, 4), kind=rng.choice(["fix", "feat", "refactor", "unknown"]))
        groups = [dict(files=paths[i : i + 3], evidence=[]) for i in range(0, len(paths), 3)]
        rows, _, _ = metrics.rank(groups, data)
        for row in rows:
            members = set(row["files"])
            touching = [c for c in data["commits"] if members & set(c["files"])]
            tests = sorted(
                t
                for t in data["tests"]
                if (members & data["graph"].get(t, set()) or re.sub(r"\.(test|spec)\.", ".", t) in members)
            )
            incoming = sorted(p for p in paths if p not in members and members & data["graph"].get(p, set()))
            self.assertEqual(row["test_files"], tests)
            self.assertEqual(row["importers"], incoming)
            self.assertEqual(row["fan_in"], len(incoming))
            self.assertEqual(row["test_loc_ratio"], round(len(tests) / 3, 2))
            for field, kind in [
                ("fix", "fix"),
                ("feat", "feat"),
                ("ref", "refactor"),
                ("unknown_churn", "unknown"),
            ]:
                self.assertEqual(row[field], sum(c["kind"] == kind for c in touching))
            self.assertEqual((row["sum"], row["decisions"], row["n"]), (6, 3, 3))

    def test_large_census_finishes_with_all_rows_and_correct_edges(self):
        data = census(6000)
        started = time.monotonic()
        groups = metrics.families(data["sources"], data["graph"], {})
        for key in ("sources", "tests", "commits"):
            data[key] = WalkBudget(data[key])
        rows, excluded, _ = metrics.rank(groups, data)
        self.assertEqual((len(rows), len(excluded)), (6000, 0))
        first = next(r for r in rows if r["files"] == ["src/m0.ts"])
        self.assertEqual(first["importers"], ["src/m5999.ts"])
        self.assertEqual(first["test_files"], ["src/m0.test.ts", "src/m5999.test.ts"])
        print(f"RADAR SCALE sources=6000 tests=6000 seconds={time.monotonic() - started:.3f}")

    def test_deadline_is_explicit_and_restores_signal_handler(self):
        import signal

        before = signal.getsignal(signal.SIGALRM)
        with (
            self.assertRaisesRegex(radar_runtime.ScanDeadline, "no complete report"),
            radar_runtime.deadline(1),
        ):
            signal.raise_signal(signal.SIGALRM)
        self.assertIs(signal.getsignal(signal.SIGALRM), before)

    def test_farm_flag_requires_actual_worker_context_not_just_a_cli_string(self):
        for platform, env in [("darwin", dict(os.environ)), ("linux", {})]:
            with (
                self.subTest(platform=platform),
                patch.object(radar_runtime.sys, "platform", platform),
                patch.dict(os.environ, env, clear=True),
                self.assertRaisesRegex(ValueError, "Linux rt worker context"),
            ):
                radar_runtime.require_farm()

    def test_existing_timer_is_restored_with_elapsed_time_deducted(self):
        import signal

        for elapsed, remaining in [(3, 7), (12, 0.001)]:
            with (
                self.subTest(elapsed=elapsed),
                patch.object(signal, "getitimer", return_value=(10, 2)),
                patch.object(signal, "setitimer") as timer,
                patch.object(radar_runtime.time, "monotonic", side_effect=[100, 100 + elapsed]),
                radar_runtime.deadline(60),
            ):
                pass
            timer.assert_any_call(signal.ITIMER_REAL, 0)
            timer.assert_any_call(signal.ITIMER_REAL, 10)
            timer.assert_called_with(signal.ITIMER_REAL, remaining, 2)

    def test_handler_is_restored_even_if_alarm_arrives_during_disarm(self):
        import signal

        before = signal.getsignal(signal.SIGALRM)
        with (
            patch.object(signal, "setitimer", side_effect=[(0, 0), radar_runtime.ScanDeadline("cleanup")]),
            self.assertRaisesRegex(radar_runtime.ScanDeadline, "cleanup"),
            radar_runtime.deadline(1),
        ):
            pass
        self.assertIs(signal.getsignal(signal.SIGALRM), before)

    def test_deadline_rejects_nonpositive_budget_and_non_main_thread(self):
        for budget in (0, -1, 100001):
            with (
                self.subTest(budget=budget),
                self.assertRaisesRegex(ValueError, "1..100000"),
                radar_runtime.deadline(budget),
            ):
                self.fail("invalid budget was entered")
        with (
            patch.object(radar_runtime.threading, "current_thread", return_value=object()),
            self.assertRaisesRegex(ValueError, "main thread"),
            radar_runtime.deadline(1),
        ):
            self.fail("worker thread was entered")


class RadarFarm(RadarRepo):
    def prepare(self, *extra):
        target = self.home / "farm job"
        self.write(".radar.json", json.dumps({"repo_id": "fixture/product", "remote": "none"}))
        self.invoke("--prepare-farm", str(target), "--min-cc", "1", *extra)
        return target

    def worker(self, job, *extra, expected=0):
        result = subprocess.run(
            ["bash", str(job / "refactor-radar.sh"), "--snapshot", str(job / "input.json"), *extra],
            cwd=self.home,
            capture_output=True,
            text=True,
            timeout=30,
        )
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        return result

    def test_prepare_never_measures_and_worker_needs_no_git_or_source_checkout(self):
        with patch.object(cli.metrics, "measure", side_effect=AssertionError("local measurement")):
            args = cli.arguments(["--no-remote", "--prepare-farm", str(self.home / "farm job")])
            cli.run(args, self.repo)
        job = self.home / "farm job"
        frozen = json.loads((job / "input.json").read_text())["payload"]
        self.repo.rename(self.home / "moved-original")
        report = self.home / "worker.json"
        self.worker(job, "--json", str(report), "--timings")
        data = json.loads(report.read_text())
        self.assertEqual(data["meta"]["sha"], frozen["sha"])
        self.assertEqual(self.row(data, "src/order-service.ts")["sum"], 2)
        self.assertEqual(data["meta"]["busy"]["complete"], False)

    def test_every_report_row_matches_direct_scan_on_same_frozen_inputs(self):
        for kind in ("test", "style"):
            self.write("src/order-service.ts", f"export function check(x) {{ if (x) return '{kind}'; }}")
            self.commit(f"{kind}: fixture")
        job = self.prepare()
        payload = json.loads((job / "input.json").read_text())["payload"]
        raw = deepcopy(payload["data"])
        expected = cli.report_for(cli.measure_inputs(raw), payload["sha"], payload["config_path"])
        target = self.home / "remote.json"
        self.worker(job, "--json", str(target))
        self.assertEqual(json.loads(target.read_text()), expected)

    def test_worker_expires_busy_paths_instead_of_excluding_them_forever(self):
        job = self.prepare()
        path = job / "input.json"
        envelope = json.loads(path.read_text())
        busy = envelope["payload"]["data"]["busy"]
        busy.update(captured_at=1, paths=["src/order-service.ts"])
        busy["local"]["paths"] = ["src/order-service.ts"]
        envelope["checksum"] = git.digest(envelope["payload"])
        path.write_text(json.dumps(envelope))
        result = self.home / "expired.json"
        self.worker(job, "--json", str(result))
        row = self.row(json.loads(result.read_text()), "src/order-service.ts")
        self.assertEqual((row["availability"], row["busy_paths"], row["excluded"]), ("UNKNOWN", [], None))

    def test_checksum_and_option_override_are_rejected_without_report(self):
        job = self.prepare()
        output = self.home / "never.json"
        result = self.worker(job, "--ref", "HEAD", "--json", str(output), expected=2)
        self.assertIn("frozen options", result.stderr)
        path = job / "input.json"
        envelope = json.loads(path.read_text())
        envelope["payload"]["data"]["sources"].append("src/fake.ts")
        path.write_text(json.dumps(envelope))
        result = self.worker(job, "--json", str(output), expected=2)
        self.assertIn("checksum", result.stderr)
        self.assertFalse(output.exists())

    def test_large_local_scan_refuses_before_loading_or_measuring_blobs(self):
        args = cli.arguments(["--no-remote"])
        with (
            patch.object(cli.git, "tree", return_value={f"src/m{i}.ts": {} for i in range(1001)}),
            patch.object(cli.git, "blobs", side_effect=AssertionError("local blobs loaded")),
            self.assertRaisesRegex(ValueError, "--prepare-farm"),
        ):
            cli.run(args, self.repo)

    def test_farm_snapshot_must_match_declared_profile_identity(self):
        job = self.prepare()
        path = job / "input.json"
        envelope = json.loads(path.read_text())
        envelope["payload"]["data"]["cfg"]["repo_id"] = "other/product"
        envelope["checksum"] = git.digest(envelope["payload"])
        path.write_text(json.dumps(envelope))
        result = self.worker(job, expected=2)
        self.assertIn("repo identity mismatch", result.stderr)

    def test_git_farm_execution_checks_context_and_preserves_computed_metrics(self):
        with patch.object(radar_runtime, "require_farm") as context_check:
            report = cli.run(cli.arguments(["--execution", "farm", "--no-remote", "--quiet"]), self.repo)
        context_check.assert_called_once_with()
        self.assertEqual(self.row(report, "src/order-service.ts")["sum"], 2)

    def test_codesift_never_invokes_builtin_measurement(self):
        data = census(2)
        data.update(engine="codesift", parser_version="fixture", issues=[])
        expected = deepcopy(data["metrics"])
        with patch.object(cli.metrics, "measure", side_effect=AssertionError("builtin called")):
            actual = cli.measure_inputs(data)
        self.assertEqual(actual["metrics"], expected)

    def test_prepare_dry_run_and_existing_target_are_non_destructive(self):
        target = self.home / "dry-job"
        self.invoke("--prepare-farm", str(target), "--dry-run", "--no-remote")
        self.assertFalse(target.exists())
        target.mkdir()
        sentinel = target / "keep"
        sentinel.write_text("keep")
        result = self.invoke("--prepare-farm", str(target), "--no-remote", expected=2)
        self.assertIn("empty directory", result.stderr)
        self.assertEqual(sentinel.read_text(), "keep")

    def test_profile_history_is_not_read_on_worker_but_explicit_history_is_rejected(self):
        self.write(".radar.json", json.dumps({"history_dir": "/not/a/farm/path", "remote": "none"}))
        job = self.home / "history-job"
        result = self.invoke("--prepare-farm", str(job))
        self.assertIn("trend unavailable", result.stderr)
        report = self.home / "no-history.json"
        self.worker(job, "--json", str(report))
        self.assertIsNone(json.loads(report.read_text())["meta"]["prev"])
        self.invoke("--prepare-farm", str(self.home / "never"), "--history", "explicit", expected=2)

    def test_malformed_snapshot_is_rejected_before_measurement(self):
        job = self.prepare()
        path = job / "input.json"
        original = json.loads(path.read_text())
        for key, value in [("busy", []), ("cfg", []), ("commits", [None]), ("engine", "unknown")]:
            with self.subTest(key=key):
                envelope = deepcopy(original)
                envelope["payload"]["data"][key] = value
                envelope["checksum"] = git.digest(envelope["payload"])
                path.write_text(json.dumps(envelope))
                result = self.worker(job, "--timings", expected=2)
                self.assertIn("farm input:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)
                self.assertNotIn("phase=measure", result.stderr)

    def test_snapshot_validation_boundaries_have_specific_diagnostics(self):
        job = self.prepare()
        path = job / "input.json"
        original = json.loads(path.read_text())
        cases = [
            ("mode", "invalid", "mode or scope"),
            ("scope", None, "mode or scope"),
            ("top", -1, "numeric options"),
            ("min_cc", "high", "complexity floor"),
            ("commits", {}, "invalid history"),
            ("sources", None, "file census"),
            ("sources", [{}], "file census"),
            ("sources", ["src/a.ts", "src/a.ts"], "file census"),
            ("contents", {"outside.ts": "export const v = 1"}, "outside file census"),
            ("contents", {"src/order-service.ts": 4}, "source blob"),
            ("issues", [None], "source issues"),
            ("issues", [{"file": "outside.ts", "reason": "missing"}], "issue outside"),
            ("tests", ["src/order-service.ts"], "sources/tests overlap"),
            ("contents", {}, "missing source"),
            ("history", "host-only", "host history paths"),
        ]
        for key, value, diagnostic in cases:
            with self.subTest(key=key, value=value):
                envelope = deepcopy(original)
                envelope["payload"]["data"][key] = value
                envelope["checksum"] = git.digest(envelope["payload"])
                path.write_text(json.dumps(envelope))
                with self.assertRaisesRegex(ValueError, diagnostic):
                    radar_snapshot.load(path)
        for key, value in [("sha", "not-a-sha"), ("data", [])]:
            envelope = deepcopy(original)
            envelope["payload"][key] = value
            envelope["checksum"] = git.digest(envelope["payload"])
            path.write_text(json.dumps(envelope))
            with self.assertRaisesRegex(ValueError, "missing source identity"):
                radar_snapshot.load(path)
        for value in [[], {"payload": []}]:
            path.write_text(json.dumps(value))
            with self.assertRaisesRegex(ValueError, "invalid envelope"):
                radar_snapshot.load(path)
        envelope = deepcopy(original)
        envelope["payload"]["config_path"] = []
        envelope["checksum"] = git.digest(envelope["payload"])
        path.write_text(json.dumps(envelope))
        with self.assertRaisesRegex(ValueError, "config path metadata"):
            radar_snapshot.load(path)

    def test_prepare_and_load_enforce_size_budgets_without_partial_output(self):
        job = self.prepare()
        path = job / "input.json"
        payload = json.loads(path.read_text())["payload"]
        target = self.home / "over-budget"
        with patch.object(git, "MAX_TOTAL", 1), self.assertRaisesRegex(ValueError, "byte budget"):
            radar_snapshot.prepare(target, payload["data"], payload["sha"], None)
        self.assertFalse(target.exists())
        with patch.object(git, "MAX_FILES", 1), self.assertRaisesRegex(ValueError, "file census"):
            radar_snapshot.load(path)
        with patch.object(git, "MAX_BLOB", 1), self.assertRaisesRegex(ValueError, "source blob"):
            radar_snapshot.load(path)

    def test_prepare_rejects_dangling_symlink_without_following_it(self):
        target = self.home / "broken-job"
        destination = self.home / "must-not-exist"
        target.symlink_to(destination)
        result = self.invoke("--prepare-farm", str(target), "--no-remote", expected=2)
        self.assertIn("new or empty directory", result.stderr)
        self.assertTrue(target.is_symlink())
        self.assertFalse(destination.exists())

    def test_imported_codesift_values_validate_without_running_builtin(self):
        data = census(2)
        data.update(parser_version="verified-fixture")
        radar_snapshot.validate_metrics(data)
        for key, value, diagnostic in [
            ("metrics", None, "metrics or version"),
            ("parser_version", None, "metrics or version"),
            ("metrics", {"src/m0.ts": None, "src/m1.ts": []}, "functions"),
            ("metrics", {"src/m0.ts": [{}], "src/m1.ts": []}, "function"),
        ]:
            with self.subTest(key=key, value=value), self.assertRaisesRegex(ValueError, diagnostic):
                radar_snapshot.validate_metrics(dict(data, **{key: value}))
        for field, value in [("cc", 0), ("line", 100001), ("lines", "1"), ("nest", -1)]:
            mutated = deepcopy(data)
            mutated["metrics"]["src/m0.ts"][0][field] = value
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "invalid CodeSift function"):
                radar_snapshot.validate_metrics(mutated)

    def test_codesift_snapshot_replay_keeps_supplied_function_measurements(self):
        envelope = self.home / "codesift.json"
        envelope.write_text(
            json.dumps(
                {
                    "meta": {
                        "repo": "fixture/product",
                        "sha": self.git("rev-parse", "HEAD"),
                        "complete": True,
                        "version": "verified-fixture",
                        "total_functions": 2,
                    },
                    "functions": [
                        {
                            "file": path,
                            "name": "route",
                            "line": 1,
                            "lines": 1,
                            "cyclomatic_complexity": 7,
                            "max_nesting_depth": 2,
                        }
                        for path in ["src/order-service.ts", "src/unrelated.ts"]
                    ],
                }
            )
        )
        job = self.prepare("--engine", "codesift", "--codesift-json", str(envelope))
        output = self.home / "provided.json"
        self.worker(job, "--json", str(output))
        result = json.loads(output.read_text())
        self.assertEqual(result["meta"]["measurement"], "provided-codesift-envelope")
        self.assertEqual(self.row(result, "src/order-service.ts")["sum"], 7)

    def test_missing_blob_with_explicit_issue_stays_unmeasured(self):
        job = self.prepare()
        path = job / "input.json"
        envelope = json.loads(path.read_text())
        data = envelope["payload"]["data"]
        del data["contents"]["src/order-service.ts"]
        data["issues"] = [{"file": "src/order-service.ts", "reason": "non-UTF8 source"}]
        envelope["checksum"] = git.digest(envelope["payload"])
        path.write_text(json.dumps(envelope))
        output = self.home / "unmeasured.json"
        self.worker(job, "--json", str(output))
        result = json.loads(output.read_text())
        self.assertEqual(self.row(result, "src/order-service.ts")["sum"], 0)
        self.assertEqual(result["meta"]["source_issues"], data["issues"])

    def test_large_snapshot_also_requires_explicit_farm_execution(self):
        job = self.prepare()
        path = job / "input.json"
        envelope = json.loads(path.read_text())
        data = envelope["payload"]["data"]
        data["sources"] = [f"src/m{i}.ts" for i in range(1001)]
        data["tests"] = []
        data["contents"] = {p: "export const v = 1;" for p in data["sources"]}
        envelope["checksum"] = git.digest(envelope["payload"])
        path.write_text(json.dumps(envelope))
        output = self.home / "no-local.json"
        result = self.worker(job, "--json", str(output), expected=2)
        self.assertIn("requires --execution farm through rt", result.stderr)
        self.assertFalse(output.exists())
        self.worker(job, "--execution", "farm", "--json", str(output))
        self.assertEqual(json.loads(output.read_text())["meta"]["source_files"], 1001)

    def test_measurement_timeout_never_writes_a_partial_report(self):
        job = self.prepare()
        output = self.home / "partial.json"
        with patch.object(
            cli.metrics, "measure", side_effect=radar_runtime.ScanDeadline("scan deadline exceeded")
        ):
            self.assertEqual(cli.main(["--snapshot", str(job / "input.json"), "--json", str(output)]), 2)
        self.assertFalse(output.exists())

    def test_overall_deadline_is_not_swallowed_as_an_optional_worktree_failure(self):
        import signal

        def stall(*args, **kwargs):
            signal.raise_signal(signal.SIGALRM)

        with (
            patch.object(git, "worktrees", return_value=[{"worktree": str(self.repo)}]),
            patch.object(git, "git", side_effect=stall),
            self.assertRaisesRegex(RuntimeError, "no complete report"),
            radar_runtime.deadline(1),
        ):
            git.local_busy(self.repo, "a" * 40)

    def test_test_debt_mode_is_frozen_in_snapshot(self):
        job = self.prepare("--mode", "tests")
        output = self.home / "tests-mode.json"
        self.worker(job, "--json", str(output))
        self.assertEqual(json.loads(output.read_text())["meta"]["mode"], "tests")


if __name__ == "__main__":
    unittest.main()
