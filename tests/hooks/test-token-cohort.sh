#!/usr/bin/env bash
# Behaviour contract: copied logs, retries and missing evidence must not make a trial look cheap.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 - "$ROOT" <<'PY'
from __future__ import annotations

import copy
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from typing import Any

ROOT = Path(sys.argv.pop())
CLI = ROOT / "scripts/zuvo-home/token-cohort.py"
PROFILER = ROOT / "scripts/zuvo-home/profile-session.py"
FIXTURES = ROOT / "tests/fixtures/token-cohort"
START, END = "2026-01-02T00:00:00Z", "2026-01-03T00:00:00Z"

def arm(order: int, workload: str = "implementation") -> str:
    first = int(hashlib.sha256(f"seed:{workload}".encode()).hexdigest(), 16) % 2
    return ("control", "candidate")[(first + order) % 2]

class CohortContract(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name)
        self.manifest: dict[str, Any] = {
            "schema_version": 1, "experiment": "protocol", "window_start": START, "window_end": END,
            "policy": {"schema_version": 1, "frozen_at": "2026-01-01T00:00:00Z",
                       "assignment_seed": "seed", "min_completed": 2, "min_savings_fraction": .15,
                       "max_p90_regression": .1, "require_leave_one_out": True},
            "attempts": [], "observation_paths": [],
        }
        self.write("evidence.txt", "synthetic runtime observation")
        config = {"provider": "codex", "model": "synthetic", "reasoning": "high",
                  "context_window": 828400, "compaction_threshold": 500000}
        self.runtime = {"schema_version": 1, "status": "confirmed", "declared": {},
                        "confirmed": {"parent": config, "child": config},
                        "evidence_kind": "synthetic", "evidence_paths": ["evidence.txt"]}
        self.write("runtime.json", self.runtime)
        for order in range(6):
            self.add_task(order, 100 if arm(order) == "control" else 60)

    def write(self, name: str, value: Any) -> str:
        path = self.base / name
        path.write_text(value if isinstance(value, str) else json.dumps(value), encoding="utf-8")
        return name

    def usage(self, identity: str, fresh: int, thread: str | None = None) -> dict[str, Any]:
        return {"accounting_version": 2, "timestamp": START, "provider": "codex",
                "response_id": identity, "thread_id": thread or identity, "parent_id": None,
                "input": fresh + 90, "cached_input": 100, "output": 10, "reasoning_output": 0,
                "fresh": fresh, "gross": fresh + 100, "source": "token_usage_record",
                "polling_proxy": None, "missing_response_id": False}

    def add_task(self, order: int, fresh: int) -> dict[str, Any]:
        identity = f"t{order}"
        result = {"schema_version": 1, "outcome": "completed", "reviewer_verdict": "pass",
                  "review_corrections": 0, "ci_corrections": 0, "critical_regressions": 0,
                  "started_at": f"2026-01-02T00:{order:02d}:00Z",
                  "green_at": f"2026-01-02T00:{order + 1:02d}:00Z", "queue_duration_seconds": 5}
        attempt = {"task_id": identity, "attempt_id": identity, "root_thread_id": identity,
                   "provider": "codex", "model": "synthetic", "reasoning": "high",
                   "workload_class": "implementation", "cohort": arm(order), "assignment_order": order,
                   "accepted_at": f"2026-01-01T00:{order + 1:02d}:00Z",
                   "protocol_ref": arm(order), "brief_sha256": hashlib.sha256(arm(order).encode()).hexdigest(),
                   "runtime_receipt": "runtime.json", "result_receipt": f"{identity}-result.json",
                   "transcript_paths": [f"{identity}-raw.jsonl"], "missing_transcript_paths": [],
                   "usage_paths": [f"{identity}-usage.jsonl"]}
        self.write(attempt["usage_paths"][0], json.dumps(self.usage(identity, fresh)) + "\n")
        self.write(attempt["transcript_paths"][0], "synthetic transcript placeholder\n")
        self.write(attempt["result_receipt"], result)
        self.manifest["attempts"].append(attempt)
        return attempt

    def call(self, expected: int = 0, out: str = "report.json", error: str | None = None,
             diagnostic: str | None = None) -> dict[str, Any]:
        self.write("manifest.json", self.manifest)
        proc = subprocess.run([sys.executable, str(CLI), "--manifest", str(self.base / "manifest.json"),
                               "--out", str(self.base / out)], capture_output=True, text=True, check=False,
                              stdin=subprocess.DEVNULL, timeout=30)
        self.assertEqual(proc.returncode, expected, proc.stderr)
        self.assertNotIn("Traceback", proc.stderr)
        if error is not None:
            self.assertIn(error, proc.stderr)
        if diagnostic is not None:
            self.assertEqual(proc.stderr.strip(), f"token-cohort: {diagnostic}")
        return json.loads((self.base / out).read_text()) if expected == 0 else {}

    def expect_decision(self, verdict: str) -> dict[str, Any]:
        report = self.call()
        self.assertEqual(report["decision"]["verdict"], verdict)
        return report

    def result(self, index: int, **updates: Any) -> None:
        name = self.manifest["attempts"][index]["result_receipt"]
        value = json.loads((self.base / name).read_text())
        value.update(updates)
        self.write(name, value)

    def candidate_cost(self, fresh: int) -> None:
        for attempt in self.manifest["attempts"]:
            if attempt["cohort"] == "candidate":
                self.write(attempt["usage_paths"][0], json.dumps(self.usage(attempt["task_id"], fresh)))

    def test_complete_balanced_trial_keeps_with_deterministic_distributions(self) -> None:
        report = self.expect_decision("KEEP")
        self.assertEqual(report["arms"]["control"]["fresh_per_completed"], 100)
        self.assertEqual(report["arms"]["candidate"]["fresh_per_completed"], 60)
        self.assertEqual(report["arms"]["candidate"]["fresh_distribution"], {"median": 60, "p90": 60})
        self.assertEqual(report["arms"]["candidate"]["time_to_green_seconds"]["p90"], 60)
        self.assertEqual(report["arms"]["candidate"]["queue_seconds"]["median"], 5)
        self.assertIsNone(report["compactions"])
        self.assertIsNone(report["observations"]["empty_poll"])
        self.assertEqual(report, self.call())

    def test_real_exports_deduplicate_parent_child_and_keep_failed_retry_cost(self) -> None:
        self.manifest["attempts"] = []
        first = self.add_task(0, 100)
        first.update(root_thread_id="parent", usage_paths=["parent-usage.jsonl", "child-usage.jsonl"],
                     transcript_paths=["parent.jsonl", "child.jsonl"])
        self.result(0, outcome="failed", reviewer_verdict="fail", green_at=None)
        retry = copy.deepcopy(first)
        retry.update(attempt_id="retry", root_thread_id="retry", usage_paths=["retry-usage.jsonl"],
                     transcript_paths=["retry.jsonl"], result_receipt="retry-result.json")
        self.write("retry-result.json", {"schema_version": 1, "outcome": "completed",
                                        "reviewer_verdict": "pass"})
        self.manifest["attempts"].append(retry)
        claude = self.add_task(1, 100)
        claude.update(provider="claude", root_thread_id="claude", runtime_receipt=None,
                      usage_paths=["claude-usage.jsonl"], transcript_paths=["claude.jsonl"])
        for name in ("parent", "child", "retry", "claude"):
            raw = self.base / f"{name}.jsonl"
            raw.write_bytes((FIXTURES / raw.name).read_bytes())
            subprocess.run([sys.executable, str(PROFILER), str(raw),
                            "--usage-jsonl", str(self.base / f"{name}-usage.jsonl")],
                           check=True, capture_output=True, text=True, stdin=subprocess.DEVNULL, timeout=30)
        report = self.call()
        self.assertEqual(report["observed_cost"], json.loads((FIXTURES / "expected.json").read_text()))
        self.assertEqual(report["attempt_outcomes"]["failed"], 1)
        self.assertEqual(report["tasks"][0]["observed_cost"]["fresh"], 220)
        self.assertEqual(report["polling_proxy"]["calls"], 1)
        self.assertIsNone(report["observations"]["empty_poll"])
        first["usage_paths"].append("parent-copy.jsonl")
        (self.base / "parent-copy.jsonl").write_bytes((self.base / "parent-usage.jsonl").read_bytes())
        self.assertEqual(self.call()["observed_cost"], report["observed_cost"])

    def test_real_exports_retain_cross_transcript_final_usage_before_windowing(self) -> None:
        attempt = self.manifest["attempts"][0]
        self.manifest["attempts"] = [attempt]
        attempt.update(root_thread_id="parent", transcript_paths=["parent.jsonl", "child.jsonl"],
                       usage_paths=["parent-usage.jsonl", "child-usage.jsonl"])
        for name, at, amount in (("parent", START, 100), ("child", END, 200)):
            records = [{"type": "session_meta", "payload": {"id": name}},
                       {"type": "token_usage_record", "timestamp": at,
                        "payload": {"response_id": "shared-final", "thread_id": "parent",
                                    "usage": {"input_tokens": amount, "cached_input_tokens": 60,
                                              "output_tokens": 10}}}]
            self.write(f"{name}.jsonl", "\n".join(json.dumps(row) for row in records))
            # Cohort exports must retain the child's later final record outside the report window.
            args = [sys.executable, str(PROFILER), str(self.base / f"{name}.jsonl"),
                    "--usage-jsonl", str(self.base / f"{name}-usage.jsonl")]
            subprocess.run(args, check=True, capture_output=True, text=True,
                           stdin=subprocess.DEVNULL, timeout=30)
        observed = self.call()["observed_cost"]
        self.assertEqual((observed["fresh"], observed["gross"], observed["calls"]), (0, 0, 0))

    def test_global_response_identity_requires_unambiguous_thread_evidence(self) -> None:
        original = 100 if arm(0) == "control" else 60
        cases = (
            ("unmapped_copy", "extra", 90, "unmapped", None, 90, 570, "INCONCLUSIVE"),
            ("conflicting_threads", "t0", original, "t1", None, original, 480, "INCONCLUSIVE"),
            ("original_before_parent", "t0", original, "t0", "t1", 0, 480, "KEEP"),
        )
        for name, identity, fresh, thread, parent, unattributed, total, verdict in cases:
            with self.subTest(edge=name):
                self.setUp()
                row = {**self.usage(identity, fresh, thread), "parent_id": parent}
                self.write("copy.jsonl", json.dumps(row))
                self.manifest["attempts"][0]["usage_paths"].append("copy.jsonl")
                self.manifest["attempts"][1]["usage_paths"].append("copy.jsonl")
                report = self.expect_decision(verdict)
                self.assertEqual(report["unattributed_cost"]["fresh"], unattributed)
                self.assertEqual(report["observed_cost"]["fresh"], total)

    def test_unknown_evidence_cannot_become_zero_or_eligible(self) -> None:
        original = 100 if arm(0) == "control" else 60
        cases = (
            # case, known cost, unknown-arm fresh, observed task fresh, outcome, known quality, derived arm
            ("transcript", False, 0, original, "completed", True, arm(0)),
            ("empty_usage", False, 0, 0, "completed", True, arm(0)),
            ("response_id", False, 0, original, "completed", True, arm(0)),
            ("runtime", True, original, original, "completed", True, "unknown"),
            ("result", True, 0, original, "unknown", False, arm(0)),
            ("quality", True, 0, original, "completed", False, arm(0)),
            ("window_only", True, 480, original, "completed", True, "unknown"),
        )
        for case, cost_known, unknown_fresh, fresh, outcome, quality_known, cohort in cases:
            with self.subTest(case=case):
                self.setUp()
                attempt = self.manifest["attempts"][0]
                if case == "transcript": attempt["missing_transcript_paths"] = ["lost.jsonl"]
                elif case == "empty_usage": self.write("t0-usage.jsonl", "")
                elif case == "response_id":
                    row = self.usage("t0", original); row.update(response_id=None, missing_response_id=True)
                    self.write("t0-usage.jsonl", json.dumps(row))
                elif case == "runtime": attempt["runtime_receipt"] = None
                elif case == "result": attempt["result_receipt"] = None
                elif case == "quality": self.result(0, review_corrections=None)
                else:
                    self.runtime["confirmed"]["parent"]["compaction_threshold"] = None
                    self.write("runtime.json", self.runtime)
                report = self.expect_decision("INCONCLUSIVE")
                task = report["tasks"][0]
                actual = (task["cost"] is not None, report["arms"]["unknown"]["observed_cost"]["fresh"],
                          task["observed_cost"]["fresh"], task["outcome"], task["quality_known"],
                          task["cohort"], task["declared_cohort"])
                self.assertEqual(actual, (cost_known, unknown_fresh, fresh, outcome, quality_known, cohort, arm(0)))

    def test_runtime_mismatch_and_impossible_threshold_preserve_declared_assignment(self) -> None:
        cases = (
            ("different_child_model", {"parent": {}, "child": {"model": "other"}}),
            ("threshold_above_window", {"parent": {"compaction_threshold": 900000},
                                        "child": {"compaction_threshold": 900000}}),
        )
        for case, changes in cases:
            with self.subTest(case=case):
                self.setUp()
                runtime = json.loads((self.base / "runtime.json").read_text())
                for role, updates in changes.items(): runtime["confirmed"][role].update(updates)
                self.write("runtime.json", runtime)
                report = self.expect_decision("INCONCLUSIVE")
                self.assertEqual(report["arms"]["unknown"]["observed_cost"]["fresh"], 480)
                self.assertEqual(report["arms"]["unknown"]["tasks"], 6)
                self.assertEqual([(task["declared_cohort"], task["cohort"]) for task in report["tasks"]],
                                 [(arm(order), "unknown") for order in range(6)])

    def test_final_timestamp_wins_across_exports_before_exclusive_window_filter(self) -> None:
        original = 100 if arm(0) == "control" else 60
        cases = (
            ("later_inside_old_first", "2026-01-02T00:01:00Z", ["old.jsonl", "latest.jsonl"], 40, 6),
            ("later_inside_new_first", "2026-01-02T00:01:00Z", ["latest.jsonl", "old.jsonl"], 40, 6),
            ("later_at_end_old_first", END, ["old.jsonl", "latest.jsonl"], 0, 5),
            ("later_at_end_new_first", END, ["latest.jsonl", "old.jsonl"], 0, 5),
        )
        for case, at, paths, task_fresh, calls in cases:
            with self.subTest(case=case):
                self.setUp()
                self.write("old.jsonl", json.dumps(self.usage("t0", 200)))
                latest = {**self.usage("t0", 40), "timestamp": at}
                self.write("latest.jsonl", json.dumps(latest))
                self.manifest["attempts"][0]["usage_paths"] = paths
                report = self.call()
                self.assertEqual(report["observed_cost"]["fresh"], 480 - original + task_fresh)
                self.assertEqual(report["observed_cost"]["calls"], calls)
                self.assertEqual(report["tasks"][0]["observed_cost"]["fresh"], task_fresh)

    def test_nonconstant_task_costs_interpolate_median_and_p90(self) -> None:
        self.add_task(6, 100 if arm(6) == "control" else 60)
        self.add_task(7, 100 if arm(7) == "control" else 60)
        candidates = [attempt for attempt in self.manifest["attempts"] if attempt["cohort"] == "candidate"]
        for attempt, fresh in zip(candidates, (10, 20, 70, 100), strict=True):
            self.write(attempt["usage_paths"][0], json.dumps(self.usage(attempt["task_id"], fresh)))
        # Median=(20+70)/2=45; P90 lies 70% between 70 and 100, yielding 91.
        report = self.call()
        self.assertEqual(report["arms"]["candidate"]["fresh_distribution"], {"median": 45, "p90": 91})

    def test_descriptive_unknown_baseline_needs_no_invented_preregistration(self) -> None:
        self.manifest["policy"]["frozen_at"] = "2026-01-04T00:00:00Z"
        for attempt in self.manifest["attempts"]:
            attempt.update(cohort="unknown", assignment_order=None, accepted_at=None)
        report = self.expect_decision("INCONCLUSIVE")
        self.assertEqual(report["observed_cost"]["fresh"], 480)
        self.assertEqual(report["arms"]["unknown"]["tasks"], 6)

    def test_zero_completions_preserves_abandoned_spend_and_null_ratio(self) -> None:
        for index in range(6): self.result(index, outcome="failed", reviewer_verdict="fail", green_at=None)
        report = self.expect_decision("INCONCLUSIVE")
        self.assertEqual(report["observed_cost"]["fresh"], 480)
        self.assertIsNone(report["arms"]["candidate"]["fresh_per_completed"])

    def test_one_extreme_task_cannot_create_stable_savings(self) -> None:
        control = next(a for a in self.manifest["attempts"] if a["cohort"] == "control")
        self.write(control["usage_paths"][0], json.dumps(self.usage(control["task_id"], 1000)))
        self.candidate_cost(150)
        report = self.expect_decision("INCONCLUSIVE")
        self.assertFalse(report["decision"]["leave_one_out_stable"])

    def test_adverse_quality_or_time_cannot_keep(self) -> None:
        cases = (
            ("critical", {"critical_regressions": 1}, {}, "ROLLBACK", ["quality_regression"]),
            ("review", {"review_corrections": 1}, {}, "ROLLBACK", ["quality_regression"]),
            ("ci", {"ci_corrections": 1}, {}, "ROLLBACK", ["quality_regression"]),
            ("time", {"green_at": "2026-01-02T01:00:00Z"}, {}, "ROLLBACK", ["time_regression"]),
            ("both_critical", {"critical_regressions": 1}, {"critical_regressions": 1},
             "ROLLBACK", ["quality_regression"]),
            ("control_only", {}, {"critical_regressions": 1}, "KEEP", []),
        )
        for name, candidate_result, control_result, verdict, reasons in cases:
            with self.subTest(case=name):
                self.setUp()
                candidate = next(i for i, a in enumerate(self.manifest["attempts"]) if a["cohort"] == "candidate")
                control = next(i for i, a in enumerate(self.manifest["attempts"]) if a["cohort"] == "control")
                self.result(candidate, **candidate_result)
                self.result(control, **control_result)
                report = self.expect_decision(verdict)
                self.assertEqual(report["decision"]["strata"][0]["reasons"], reasons)
                self.assertEqual(report["arms"]["candidate"]["fresh_per_completed"], 60)

    def test_unequal_arm_sizes_cannot_turn_equal_correction_rates_into_harm(self) -> None:
        self.add_task(6, 100 if arm(6) == "control" else 60)
        for index in range(7): self.result(index, review_corrections=1)
        report = self.expect_decision("INCONCLUSIVE")
        self.assertIn("unequal_arm_sizes", report["decision"]["strata"][0]["reasons"])

    def test_mixed_stratum_verdicts_expose_the_adverse_stratum(self) -> None:
        for order in range(6, 12):
            assigned = arm(order - 6, "review")
            attempt = self.add_task(order, 100 if assigned == "control" else 60)
            attempt.update(workload_class="review", cohort=assigned, protocol_ref=assigned,
                           brief_sha256=hashlib.sha256(assigned.encode()).hexdigest())
            self.result(order, critical_regressions=int(assigned == "candidate"))
        report = self.expect_decision("INCONCLUSIVE")
        self.assertIn("mixed_stratum_verdicts", report["decision"]["reasons"])
        self.assertIn("stratum_rollback", report["decision"]["reasons"])

    def test_cost_harm_rolls_back_but_small_positive_savings_stay_inconclusive(self) -> None:
        for fresh, expected in ((200, "ROLLBACK"), (95, "INCONCLUSIVE"), (70, "KEEP")):
            with self.subTest(candidate_fresh=fresh):
                self.candidate_cost(fresh)
                self.expect_decision(expected)

    def test_mixed_protocol_revisions_cannot_earn_a_stage_a_keep(self) -> None:
        self.manifest["attempts"][0]["protocol_ref"] = "different-revision"
        self.expect_decision("INCONCLUSIVE")

    def test_compaction_trial_requires_observed_threshold_and_same_protocol(self) -> None:
        self.manifest["experiment"] = "compaction"
        for attempt in self.manifest["attempts"]:
            attempt.update(protocol_ref="same",
                           brief_sha256=hashlib.sha256(attempt["task_id"].encode()).hexdigest())
        self.expect_decision("INCONCLUSIVE")
        runtime = copy.deepcopy(self.runtime)
        runtime["confirmed"]["parent"]["compaction_threshold"] = 300000
        runtime["confirmed"]["child"]["compaction_threshold"] = 300000
        self.write("candidate-runtime.json", runtime)
        for attempt in self.manifest["attempts"]:
            if attempt["cohort"] == "candidate": attempt["runtime_receipt"] = "candidate-runtime.json"
        self.expect_decision("KEEP")
        runtime["confirmed"]["child"]["compaction_threshold"] = None
        self.write("candidate-runtime.json", runtime)
        self.expect_decision("INCONCLUSIVE")

    def test_provider_model_effort_and_workload_confounding_cannot_keep(self) -> None:
        for field in ("provider", "model", "reasoning", "workload_class"):
            with self.subTest(field=field):
                self.setUp()
                attempt = self.manifest["attempts"][0]
                attempt[field] = "claude" if field == "provider" else "other"
                attempt["runtime_receipt"] = None
                if field == "provider":
                    row = self.usage("t0", 100); row.update(provider="claude", source="message.usage")
                    self.write("t0-usage.jsonl", json.dumps(row))
                if field == "workload_class":
                    attempt["cohort"] = arm(0, "other")
                    # Remaining task order is chronological, not required to be contiguous globally.
                    for other in self.manifest["attempts"][1:]:
                        other["cohort"] = arm(other["assignment_order"] - 1)
                self.expect_decision("INCONCLUSIVE")

    def test_observation_state_not_tool_name_confirms_empty_polls(self) -> None:
        events = [("empty_poll", "a", False), ("pending", "a", False),
                  ("empty_poll", "b", False), ("empty_poll", "b", False),
                  ("stdin_write", "b", True), ("empty_poll", "b", False),
                  ("changed_result", "b", True), ("empty_poll", "b", False),
                  ("empty_poll", "b", False), ("error", "b", False),
                  ("empty_poll", "b", False), ("empty_poll", "b", False),
                  ("human_interrupt", "b", False), ("probe_interrupt", "b", False)]
        rows = [{"schema_version": 1, "task_id": "t0", "subject_id": "job", "timestamp":
                 f"2026-01-02T00:00:{index:02d}Z", "state_hash": state, "event": event,
                 "nonempty": nonempty, "source": "synthetic"}
                for index, (event, state, nonempty) in enumerate(events)]
        self.write("observations.jsonl", "\n".join(json.dumps(row) for row in rows))
        self.manifest["observation_paths"] = ["observations.jsonl"]
        report = self.call()
        self.assertEqual(report["observations"]["empty_poll"], 2)
        self.assertEqual(report["observations"]["pending"], 1)
        self.call(2, "observations.jsonl")

    def test_observation_edges_keep_passive_telemetry_separate_and_preserve_window_context(self) -> None:
        cases = (
            ("heartbeat_between_reads", [(START, "pending", "a", False),
             ("2026-01-02T00:00:01Z", "heartbeat", "different", True),
             ("2026-01-02T00:00:02Z", "empty_poll", "a", False)], 1,
             {"pending": 1, "heartbeat": 1, "empty_poll": 1}),
            ("nearest_prior_before_window", [("2026-01-01T23:59:59Z", "pending", "a", False),
             (START, "empty_poll", "a", False)], 1, {"empty_poll": 1}),
            ("no_in_window_observations", [("2026-01-01T23:59:59Z", "pending", "a", False)], None, {}),
            ("terminal_then_explicit_restart", [(START, "changed_result", "a", True),
             ("2026-01-02T00:00:01Z", "pending", "a", False),
             ("2026-01-02T00:00:02Z", "empty_poll", "a", False)], 1,
             {"changed_result": 1, "pending": 1, "empty_poll": 1}),
            ("nonempty_predecessor", [(START, "pending", "a", True),
             ("2026-01-02T00:00:01Z", "empty_poll", "a", False)], 0, {"pending": 1, "empty_poll": 1}),
            ("unknown_nonempty_predecessor", [(START, "pending", "a", None),
             ("2026-01-02T00:00:01Z", "empty_poll", "a", False)], 0, {"pending": 1, "empty_poll": 1}),
        )
        for name, states, expected_empty, expected_events in cases:
            with self.subTest(edge=name):
                rows = [{"schema_version": 1, "task_id": "t0", "subject_id": "job", "timestamp": at,
                         "state_hash": state, "event": event, "nonempty": nonempty, "source": "synthetic"}
                        for at, event, state, nonempty in states]
                self.write("edges.jsonl", "\n".join(json.dumps(row) for row in rows))
                self.manifest["observation_paths"] = ["edges.jsonl"]
                observed = self.call()["observations"]
                self.assertEqual(observed["empty_poll"], expected_empty)
                self.assertEqual(observed["events"], expected_events)

    def test_partial_task_window_cannot_claim_full_task_savings(self) -> None:
        self.result(0, green_at=END)
        report = self.expect_decision("INCONCLUSIVE")
        self.assertIsNone(report["tasks"][0]["cost"])

    def test_summary_requires_matching_provenance_and_complete_coverage(self) -> None:
        self.manifest["attempts"] = self.manifest["attempts"][:1]
        attempt = self.manifest["attempts"][0]
        summary = {"schema_version": 1, "accounting_version": 2, "window_start": START,
                   "window_end": END, "transcript_path": "t0-raw.jsonl", "thread_id": "t0", "compactions": 2}
        attempt["profiler_summary_paths"] = [self.write("summary.json", summary)]
        self.assertEqual(self.call()["compactions"], 2)
        self.call(2, "summary.json")
        summary["window_end"] = "2026-01-04T00:00:00Z"
        self.write("summary.json", summary)
        self.call(2)

    def test_invalid_input_table_fails_without_replacing_report(self) -> None:
        cases = ("empty", "json", "deep_json", "duplicate_keys", "version", "accounting", "negative", "bool", "nan", "totals",
                 "identity", "timestamp", "assignment", "chronology", "duplicate_attempt", "retry_arm",
                 "receipt", "null_receipt", "huge", "source", "provider_source", "policy_prompt",
                 "observation", "conflicting_copy")
        for case in cases:
            with self.subTest(case=case):
                self.setUp()
                attempt = self.manifest["attempts"][0]
                row = self.usage("t0", 100)
                if case == "empty": self.manifest["attempts"] = []
                elif case == "version": self.manifest["schema_version"] = 999
                elif case == "accounting": row["accounting_version"] = 1
                elif case == "negative": row["reasoning_output"] = -1
                elif case == "bool": self.result(0, ci_corrections=True)
                elif case == "nan": self.result(0, queue_duration_seconds=float("nan"))
                elif case == "totals": row["fresh"] = 3
                elif case == "identity": row["missing_response_id"] = True
                elif case == "timestamp": self.result(0, green_at="2025-01-01T00:00:00Z")
                elif case == "assignment": attempt["cohort"] = "candidate" if arm(0) == "control" else "control"
                elif case == "chronology": attempt["accepted_at"] = "2025-01-01T00:00:00Z"
                elif case == "duplicate_attempt": self.manifest["attempts"].append(copy.deepcopy(attempt))
                elif case == "retry_arm":
                    retry = copy.deepcopy(attempt); retry.update(attempt_id="retry", cohort="unknown")
                    self.manifest["attempts"].append(retry)
                elif case == "receipt": self.write("runtime.json", "[]")
                elif case == "null_receipt": self.write("runtime.json", "null")
                elif case == "huge": row = self.usage("t0", 2**63)
                elif case == "source": row["source"] = "invented-complete-source"
                elif case == "provider_source": row["source"] = "message.usage"
                elif case == "policy_prompt": self.manifest["policy"]["prompt"] = "PRIVATE_PROMPT_MARKER"
                elif case == "observation":
                    observation = {"schema_version": 1, "task_id": "t0", "subject_id": "job",
                                   "timestamp": START, "state_hash": "a", "event": "invented",
                                   "nonempty": False, "source": "synthetic"}
                    self.write("observations.jsonl", json.dumps(observation))
                    self.manifest["observation_paths"] = ["observations.jsonl"]
                elif case == "conflicting_copy":
                    self.write("copy.jsonl", json.dumps(self.usage("t0", 99)))
                    attempt["usage_paths"].append("copy.jsonl")
                raw = {"json": "{", "deep_json": "[" * 20000 + "0" + "]" * 20000,
                       "duplicate_keys": json.dumps(row)[:-1] + ',"source":"token_usage_record"}'
                       }.get(case, json.dumps(row))
                self.write("t0-usage.jsonl", raw)
                self.write("report.json", "sentinel")
                # deep_json: up to Python 3.14 the decoder hits its recursion limit; 3.15 parses the array and
                # the row is refused as a non-object. Both are a clean refusal (exit 2, no traceback).
                deep = "recursion" if sys.version_info < (3, 15) else "usage row must be an object"
                expected_error = {"negative": "reasoning_output must be finite and nonnegative",
                                  "deep_json": deep}.get(case)
                diagnostic = {"duplicate_keys": "duplicate JSON key source",
                              "observation": "invalid observation event"}.get(case)
                self.call(2, error=expected_error, diagnostic=diagnostic)
                self.assertEqual((self.base / "report.json").read_text(), "sentinel")

    def test_output_cannot_clobber_inputs_through_paths_or_aliases(self) -> None:
        for target in ("manifest.json", "t0-usage.jsonl", "runtime.json", "t0-result.json", "t0-raw.jsonl"):
            with self.subTest(target=target):
                self.call(2, target)
        self.write("report-link", "old")
        (self.base / "report-link").unlink()
        os.link(self.base / "runtime.json", self.base / "report-link")
        before = (self.base / "runtime.json").read_bytes()
        self.call(2, "report-link")
        self.assertEqual((self.base / "runtime.json").read_bytes(), before)
        (self.base / "link").symlink_to(self.base / "runtime.json")
        self.call(2, "link")
        (self.base / "directory").mkdir()
        self.call(2, "directory")
        os.mkfifo(self.base / "fifo")
        self.call(2, "fifo")
        self.write("report.json", "old report")
        self.expect_decision("KEEP")

unittest.main(verbosity=2)
PY
