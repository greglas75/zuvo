"""Deterministic task costs and conservative, stratified trial decisions."""
from __future__ import annotations

from collections import Counter, defaultdict
from typing import Any

from token_cohort_schema import AMOUNTS, QUALITY, Json, require, timestamp


def cost(rows: list[Json]) -> Json:
    return {**{key: sum(row[key] for row in rows) for key in AMOUNTS}, "calls": len(rows)}


def distribution(values: list[int | float]) -> Json:
    if not values:
        return {"median": None, "p90": None}
    ordered = sorted(values)

    def quantile(fraction: float) -> float:
        index = (len(ordered) - 1) * fraction
        lower = int(index)
        upper = min(lower + 1, len(ordered) - 1)
        return ordered[lower] + (ordered[upper] - ordered[lower]) * (index - lower)

    return {"median": quantile(.5), "p90": quantile(.9)}


def outcome(receipt: Json | None) -> str:
    if not receipt:
        return "unknown"
    if receipt.get("outcome") == "failed" or receipt.get("reviewer_verdict") == "fail":
        return "failed"
    if receipt.get("outcome") == "incomplete":
        return "incomplete"
    if receipt.get("outcome") == "completed" and receipt.get("reviewer_verdict") == "pass":
        return "completed"
    return "unknown"


def nullable_sum(values: list[Any]) -> int | float | None:
    return sum(values) if values and all(value is not None for value in values) else None


def task_report(attempts: list[Json], records: list[Json]) -> Json:
    spec = attempts[0]["spec"]
    results = [attempt["result"] or {} for attempt in attempts]
    issues = sorted({issue for attempt in attempts for issue in attempt["issues"]})
    rows = [record["row"] for record in records]
    if not rows:
        issues.append("no_usage_in_window")
    configs = [attempt["runtime"] for attempt in attempts]
    runtime = configs[0] if configs[0] and all(config == configs[0] for config in configs) else None
    final = outcome(results[-1])
    starts = [timestamp(result["started_at"]) for result in results if result.get("started_at")]
    require(starts == sorted(starts), "retry attempts must be in chronological order")
    elapsed = None
    if len(starts) == len(results) and final == "completed" and results[-1].get("green_at"):
        elapsed = (timestamp(results[-1]["green_at"]) - starts[0]).total_seconds()
    quality = {key: nullable_sum([result.get(key) for result in results]) for key in QUALITY}
    queue = nullable_sum([result.get("queue_duration_seconds") for result in results])
    known_result = final != "unknown" and all(result.get("outcome") is not None and
                  result.get("reviewer_verdict") in ("pass", "fail") for result in results)
    quality_known = (known_result and all(value is not None for value in quality.values()) and
                     queue is not None and len(starts) == len(results) and
                     (final != "completed" or elapsed is not None))
    return {"task_id": spec["task_id"], "assignment_order": spec["assignment_order"],
            "attempt_ids": [attempt["spec"]["attempt_id"] for attempt in attempts],
            "stratum": {key: spec[key] for key in ("provider", "model", "reasoning", "workload_class")},
            "assignment_evidence": "unassigned" if spec["cohort"] == "unknown" else "declared",
            "declared_cohort": spec["cohort"], "cohort": spec["cohort"] if runtime else "unknown",
            "effective_config": runtime, "protocol_ref": spec["protocol_ref"],
            "brief_sha256": spec["brief_sha256"], "outcome": final,
            "attempt_outcomes": dict(Counter(outcome(result) for result in results)),
            "observed_cost": cost(rows), "cost": None if issues else cost(rows), "issues": issues,
            "quality": quality, "quality_known": quality_known, "time_to_green_seconds": elapsed,
            "queue_seconds": queue}


def arm_report(tasks: list[Json]) -> Json:
    observed = {key: sum(task["observed_cost"][key] for task in tasks) for key in (*AMOUNTS, "calls")}
    outcomes = {key: sum(task["outcome"] == key for task in tasks)
                for key in ("completed", "failed", "incomplete", "unknown")}
    complete = bool(tasks) and all(task["cost"] is not None for task in tasks)
    return {"tasks": len(tasks), "outcomes": outcomes, "observed_cost": observed,
            "cost_complete": complete,
            "fresh_per_completed": (observed["fresh"] / outcomes["completed"]
                                    if complete and outcomes["completed"] else None),
            "fresh_distribution": distribution([task["cost"]["fresh"] for task in tasks if task["cost"]]),
            "time_to_green_seconds": distribution([task["time_to_green_seconds"] for task in tasks
                                                    if task["time_to_green_seconds"] is not None]),
            "queue_seconds": distribution([task["queue_seconds"] for task in tasks
                                           if task["queue_seconds"] is not None]),
            "quality": {key: nullable_sum([task["quality"][key] for task in tasks]) for key in QUALITY},
            "failed_attempts": sum(task["attempt_outcomes"].get("failed", 0) for task in tasks)}


def savings(control: Json, candidate: Json) -> float | None:
    baseline, changed = control["fresh_per_completed"], candidate["fresh_per_completed"]
    return 1 - changed / baseline if baseline is not None and baseline > 0 and changed is not None else None


def sensitivity(tasks: list[Json]) -> tuple[bool, bool]:
    """Check both signs in O(n), subtracting a task's complete attempt totals each time."""
    if not tasks or any(task["cost"] is None or task["cohort"] == "unknown" for task in tasks):
        return False, False
    totals = {arm: [sum(t["cost"]["fresh"] for t in tasks if t["cohort"] == arm),
                    sum(t["outcome"] == "completed" for t in tasks if t["cohort"] == arm)]
              for arm in ("control", "candidate")}
    positive = negative = True
    for task in tasks:
        control, candidate = list(totals["control"]), list(totals["candidate"])
        changed = control if task["cohort"] == "control" else candidate
        changed[0] -= task["cost"]["fresh"]
        changed[1] -= task["outcome"] == "completed"
        if control[1] == 0 or candidate[1] == 0:
            return False, False
        # Integer cross-products avoid division and preserve signs at large counter values.
        delta = control[0] * candidate[1] - candidate[0] * control[1]
        positive = positive and delta > 0
        negative = negative and delta < 0
    return positive, negative


def protocols_comparable(tasks: list[Json], experiment: str) -> bool:
    if experiment == "compaction":
        return len({task["protocol_ref"] for task in tasks}) == 1
    return all(len({task["protocol_ref"] for task in tasks if task["cohort"] == arm}) <= 1
               for arm in ("control", "candidate"))


def runtime_comparable(tasks: list[Json], experiment: str) -> bool:
    configs = [task["effective_config"] for task in tasks]
    if (not configs or any(config is None for config in configs)
            or not protocols_comparable(tasks, experiment)):
        return False
    if experiment == "protocol":
        return all(config == configs[0] for config in configs)
    # Stage B is Codex only; identical protocol, window and model, differing confirmed threshold.
    return (all(config["provider"] == "codex" and config["context_window"] == configs[0]["context_window"]
                and config["compaction_threshold"] == (500000 if task["cohort"] == "control" else 300000)
                for config, task in zip(configs, tasks, strict=True)))


def adverse_reasons(control: Json, candidate: Json, policy: Json) -> list[str]:
    reasons = []
    quality_worse = (candidate["quality"]["critical_regressions"] > 0 or
                     candidate["outcomes"]["failed"] > control["outcomes"]["failed"] or
                     candidate["failed_attempts"] > control["failed_attempts"] or
                     any(candidate["quality"][key] > control["quality"][key] for key in QUALITY))
    time_worse = (candidate["time_to_green_seconds"]["p90"] >
                  control["time_to_green_seconds"]["p90"] * (1 + policy["max_p90_regression"]))
    if quality_worse: reasons.append("quality_regression")
    if time_worse: reasons.append("time_regression")
    return reasons


def stratum_decision(tasks: list[Json], policy: Json, experiment: str) -> Json:
    arms = {arm: arm_report([task for task in tasks if task["cohort"] == arm])
            for arm in ("control", "candidate")}
    control, candidate = arms["control"], arms["candidate"]
    reduction = savings(control, candidate)
    positive, negative = sensitivity(tasks)
    enough = all(arm["outcomes"]["completed"] >= policy["min_completed"] for arm in arms.values())
    complete = all(task["cost"] is not None and task["quality_known"] and
                   task["outcome"] not in ("unknown", "incomplete") and task["cohort"] != "unknown"
                   for task in tasks)
    reasons = []
    if not enough: reasons.append("insufficient_completions")
    if control["tasks"] != candidate["tasks"]: reasons.append("unequal_arm_sizes")
    if not complete: reasons.append("incomplete_cost_or_quality")
    if not runtime_comparable(tasks, experiment): reasons.append("runtime_or_protocol_not_comparable")
    result = {"verdict": "INCONCLUSIVE", "reasons": reasons, "savings_fraction": reduction,
              "leave_one_out_stable": positive, "leave_one_out_cost_harm_stable": negative, "arms": arms}
    if reasons:
        return result
    reasons.extend(adverse_reasons(control, candidate, policy))
    if reduction is not None and reduction < 0 and negative:
        reasons.append("stable_cost_regression")
    if reasons:
        result["verdict"] = "ROLLBACK"
        return result
    if reduction is None: reasons.append("undefined_savings")
    elif reduction < policy["min_savings_fraction"]: reasons.append("savings_below_policy")
    if policy["require_leave_one_out"] and not positive: reasons.append("unstable_leave_one_out")
    if not reasons:
        result["verdict"] = "KEEP"
    return result


def decision(tasks: list[Json], policy: Json, experiment: str, unattributed: Json) -> Json:
    groups: dict[tuple[str, ...], list[Json]] = defaultdict(list)
    for task in tasks:
        groups[tuple(task["stratum"].values())].append(task)
    strata = [{"stratum": group[0]["stratum"], **stratum_decision(group, policy, experiment)}
              for _, group in sorted(groups.items())]
    total_control = sum(task["cohort"] == "control" for task in tasks)
    total_candidate = sum(task["cohort"] == "candidate" for task in tasks)
    balanced = all(item["arms"]["control"]["tasks"] * total_candidate ==
                   item["arms"]["candidate"]["tasks"] * total_control for item in strata)
    unknown = any(task["cohort"] == "unknown" for task in tasks) or unattributed["calls"] > 0
    verdicts = {item["verdict"] for item in strata}
    reasons = []
    if unknown: reasons.append("unknown_cohort_or_attribution")
    if not balanced: reasons.append("different_stratum_mix")
    if not protocols_comparable(tasks, experiment): reasons.append("protocol_not_comparable")
    if reasons or "INCONCLUSIVE" in verdicts or len(verdicts) != 1:
        verdict = "INCONCLUSIVE"
    else:
        verdict = next(iter(verdicts))
    if len(verdicts) > 1: reasons.append("mixed_stratum_verdicts")
    if "ROLLBACK" in verdicts: reasons.append("stratum_rollback")
    return {"verdict": verdict, "reasons": reasons,
            "leave_one_out_stable": all(item["leave_one_out_stable"] for item in strata), "strata": strata}


def observation_report(rows: list[Json] | None, window_start: str) -> Json:
    start = timestamp(window_start)
    in_window = [row for row in rows or [] if timestamp(row["timestamp"]) >= start]
    if not in_window:
        return {"empty_poll": None, "pending": None, "events": {}}
    previous: dict[tuple[str, str], Json] = {}
    empty = 0
    stopped: set[tuple[str, str]] = set()
    for row in sorted(rows or [], key=lambda item: timestamp(item["timestamp"])):
        if row["event"] == "heartbeat":
            continue  # Passive telemetry neither counts as a read nor changes the preceding read.
        key = (row["task_id"], row["subject_id"])
        old = previous.get(key)
        pending = row["event"] in ("pending", "empty_poll")
        if not pending:
            stopped.add(key)
        elif row["event"] == "pending" and key in stopped:
            old = None
            stopped.discard(key)
        if (key not in stopped and pending and row["nonempty"] is False and old
                and old["event"] in ("pending", "empty_poll")
                and old["nonempty"] is False and old["state_hash"] == row["state_hash"]):
            empty += timestamp(row["timestamp"]) >= start
        previous[key] = row
    counts = dict(Counter(row["event"] for row in in_window))
    return {"empty_poll": empty, "pending": counts.get("pending", 0), "events": counts}


def build_report(manifest: Json, attempts: list[Json], records: list[Json],
                 observed: list[Json] | None) -> Json:
    grouped_attempts: dict[str, list[Json]] = defaultdict(list)
    grouped_records: dict[str | None, list[Json]] = defaultdict(list)
    for attempt in attempts:
        grouped_attempts[attempt["spec"]["task_id"]].append(attempt)
    for record in records:
        grouped_records[record["task_id"]].append(record)
    tasks = [task_report(group, grouped_records[identity]) for identity, group in grouped_attempts.items()]
    tasks.sort(key=lambda task: (task["assignment_order"] is None,
                                 task["assignment_order"] or 0, task["task_id"]))
    unattributed = cost([record["row"] for record in grouped_records[None]])
    arms = {arm: arm_report([task for task in tasks if task["cohort"] == arm])
            for arm in ("control", "candidate", "unknown")}
    return {"schema_version": 1, "accounting_version": 2, "policy": manifest["policy"],
            "experiment": manifest.get("experiment", "protocol"),
            "window_start": manifest["window_start"], "window_end": manifest["window_end"],
            "tasks": tasks, "arms": arms, "observed_cost": cost([record["row"] for record in records]),
            "unattributed_cost": unattributed,
            "attempt_outcomes": dict(Counter(outcome(attempt["result"]) for attempt in attempts)),
            "coverage": {"total_tasks": len(tasks),
                         "known_cost_tasks": sum(t["cost"] is not None for t in tasks),
                         "known_quality_tasks": sum(t["quality_known"] for t in tasks),
                         "unknown_runtime_tasks": sum(t["effective_config"] is None for t in tasks),
                         "missing_response_ids": sum(r["row"]["missing_response_id"] for r in records)},
            "polling_proxy": cost([record["row"] for record in records if record["row"]["polling_proxy"]]),
            "observations": observation_report(observed, manifest["window_start"]),
            "decision": decision(tasks, manifest["policy"],
                                 manifest.get("experiment", "protocol"), unattributed)}
