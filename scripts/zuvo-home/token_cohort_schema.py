"""Schema v1 boundaries for explicit, local token-cohort inputs."""
from __future__ import annotations

import hashlib
import math
import re
from datetime import datetime, timezone
from typing import Any

Json = dict[str, Any]
AMOUNTS = ("input", "cached_input", "output", "reasoning_output", "fresh", "gross")
QUALITY = ("review_corrections", "ci_corrections", "critical_regressions")
EVENTS = ("pending", "empty_poll", "changed_result", "error", "stdin_write",
          "probe_interrupt", "human_interrupt", "heartbeat")
TASK_FIELDS = ("provider", "model", "reasoning", "workload_class", "cohort", "assignment_order",
               "accepted_at", "protocol_ref", "brief_sha256")


def require(condition: bool, message: str) -> None:
    if not condition:
        raise ValueError(message)


def obj(value: Any, label: str) -> Json:
    require(isinstance(value, dict), f"{label} must be an object")
    return value


def text(value: Any, label: str) -> str:
    require(isinstance(value, str) and bool(value.strip()), f"{label} must be nonempty text")
    return value


def number(value: Any, label: str, integer: bool = False) -> int | float:
    valid = type(value) is int if integer else type(value) in (int, float)
    require(valid, f"{label} must be a number (not boolean)")
    if integer:
        require(value <= 2**63 - 1, f"{label} exceeds the int64 counter limit")
    require(value >= 0 and math.isfinite(value), f"{label} must be finite and nonnegative")
    return value


def timestamp(value: Any) -> datetime:
    text(value, "timestamp")
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    require(parsed.tzinfo is not None, "timestamps must include timezone")
    return parsed.astimezone(timezone.utc)


def choice(value: Any, options: tuple[str, ...], label: str) -> None:
    require(isinstance(value, str) and value in options, f"invalid {label}")


def paths(value: Any, label: str) -> list[str]:
    require(isinstance(value, list), f"{label} must be a list")
    for item in value:
        text(item, label)
    return value


def version(value: Any, label: str = "document") -> Json:
    result = obj(value, label)
    require(type(result.get("schema_version")) is int and result["schema_version"] == 1,
            f"unsupported {label} schema_version")
    return result


def validate_policy(value: Any) -> Json:
    policy = version(value, "policy")
    allowed = {"schema_version", "frozen_at", "assignment_seed", "min_completed", "min_savings_fraction",
               "max_p90_regression", "require_leave_one_out"}
    require(set(policy) <= allowed, "unsupported policy fields")
    timestamp(policy.get("frozen_at"))
    text(policy.get("assignment_seed"), "assignment_seed")
    require(number(policy.get("min_completed"), "min_completed", True) >= 1, "min_completed must be >=1")
    for key in ("min_savings_fraction", "max_p90_regression"):
        require(number(policy.get(key), key) <= 1, f"{key} must be <=1")
    require(type(policy.get("require_leave_one_out")) is bool, "require_leave_one_out must be boolean")
    return policy


def validate_attempt(value: Any, policy: Json) -> Json:
    attempt = obj(value, "attempt")
    for key in ("task_id", "attempt_id", "root_thread_id", "model", "reasoning", "workload_class",
                "protocol_ref", "brief_sha256"):
        text(attempt.get(key), key)
    require(bool(re.fullmatch(r"[a-fA-F0-9]{64}", attempt["brief_sha256"])), "invalid brief_sha256")
    choice(attempt.get("provider"), ("codex", "claude"), "provider")
    choice(attempt.get("cohort"), ("control", "candidate", "unknown"), "cohort")
    attempt.setdefault("assignment_order", None)
    attempt.setdefault("accepted_at", None)
    if attempt["cohort"] == "unknown":
        if attempt["assignment_order"] is not None:
            number(attempt["assignment_order"], "assignment_order", True)
        if attempt["accepted_at"] is not None:
            timestamp(attempt["accepted_at"])
    else:
        number(attempt["assignment_order"], "assignment_order", True)
        require(timestamp(attempt["accepted_at"]) >= timestamp(policy["frozen_at"]),
                "policy must be frozen before task acceptance")
    for key in ("transcript_paths", "missing_transcript_paths", "usage_paths", "profiler_summary_paths"):
        paths(attempt.get(key, []), key)
    for key in ("runtime_receipt", "result_receipt"):
        if attempt.get(key) is not None:
            text(attempt[key], key)
    return attempt


def validate_assignment(attempts: list[Json], policy: Json) -> None:
    tasks: dict[str, Json] = {}
    attempt_ids: set[str] = set()
    orders: set[int] = set()
    for attempt in attempts:
        identity = attempt["task_id"]
        require(attempt["attempt_id"] not in attempt_ids, "duplicate attempt_id")
        attempt_ids.add(attempt["attempt_id"])
        if identity in tasks:
            require(all(attempt[key] == tasks[identity][key] for key in TASK_FIELDS),
                    "retry changed task assignment or metadata")
        else:
            if attempt["cohort"] != "unknown":
                require(attempt["assignment_order"] not in orders, "duplicate task assignment_order")
                orders.add(attempt["assignment_order"])
            tasks[identity] = attempt
    assigned = [task for task in tasks.values() if task["cohort"] != "unknown"]
    chronological = sorted(assigned, key=lambda task: task["assignment_order"])
    accepted = [timestamp(task["accepted_at"]) for task in chronological]
    require(accepted == sorted(accepted) and len(accepted) == len(set(accepted)),
            "assignment_order must follow unique chronological acceptance")
    class_orders: dict[str, int] = {}
    for task in chronological:
        workload = task["workload_class"]
        order = class_orders.get(workload, 0)
        digest = hashlib.sha256(f"{policy['assignment_seed']}:{workload}".encode()).hexdigest()
        expected = ("control", "candidate")[(int(digest, 16) + order) % 2]
        require(task["cohort"] in (expected, "unknown"), "cohort contradicts predeclared assignment")
        class_orders[workload] = order + 1


def validate_manifest(value: Any) -> Json:
    manifest = version(value, "manifest")
    require(timestamp(manifest.get("window_start")) < timestamp(manifest.get("window_end")),
            "window_start must precede window_end")
    choice(manifest.get("experiment", "protocol"), ("protocol", "compaction"), "experiment")
    policy = validate_policy(manifest.get("policy"))
    attempts = manifest.get("attempts")
    if not isinstance(attempts, list) or not attempts:
        raise ValueError("attempts must be a nonempty list")
    for attempt in attempts:
        validate_attempt(attempt, policy)
    validate_assignment(attempts, policy)
    paths(manifest.get("observation_paths", []), "observation_paths")
    return manifest


def validate_usage(value: Any) -> Json:
    row = obj(value, "usage row")
    require(type(row.get("accounting_version")) is int and row["accounting_version"] == 2,
            "unsupported accounting_version")
    timestamp(row.get("timestamp"))
    choice(row.get("provider"), ("codex", "claude"), "usage provider")
    for key in ("response_id", "thread_id", "parent_id"):
        require(key in row, f"missing {key}")
        if row[key] is not None:
            text(row[key], key)
    for key in AMOUNTS:
        number(row.get(key), key, True)
    require(row["cached_input"] <= row["input"] and row["reasoning_output"] <= row["output"],
            "usage subset exceeds total")
    require(row["fresh"] == row["input"] - row["cached_input"] + row["output"] and
            row["gross"] == row["input"] + row["output"], "inconsistent exported totals")
    require(type(row.get("missing_response_id")) is bool and
            row["missing_response_id"] == (row["response_id"] is None), "inconsistent identity flag")
    sources = (("token_usage_record", "info.last_token_usage")
               if row["provider"] == "codex" else ("message.usage",))
    choice(row.get("source"), sources, "provider usage source")
    require("polling_proxy" in row, "missing polling_proxy")
    if row["polling_proxy"] is not None:
        choice(row["polling_proxy"], ("tool-label-regex-v1",), "polling_proxy")
    return row


def validate_result(value: Any) -> Json:
    receipt = version(value, "result receipt")
    for key, choices in (("outcome", ("completed", "failed", "incomplete")),
                         ("reviewer_verdict", ("pass", "fail", "unknown"))):
        if receipt.get(key) is not None:
            choice(receipt[key], choices, key)
    for key in QUALITY:
        if receipt.get(key) is not None:
            number(receipt[key], key, True)
    for key in ("started_at", "green_at"):
        if receipt.get(key) is not None:
            timestamp(receipt[key])
    if receipt.get("queue_duration_seconds") is not None:
        number(receipt["queue_duration_seconds"], "queue_duration_seconds")
    if receipt.get("started_at") is not None and receipt.get("green_at") is not None:
        duration = (timestamp(receipt["green_at"]) - timestamp(receipt["started_at"])).total_seconds()
        require(duration >= 0, "green_at precedes started_at")
        require(receipt.get("queue_duration_seconds") is None or
                receipt["queue_duration_seconds"] <= duration, "queue exceeds attempt duration")
    return receipt


def validate_runtime(value: Any) -> Json:
    receipt = version(value, "runtime receipt")
    choice(receipt.get("status"), ("confirmed", "unknown"), "runtime status")
    obj(receipt.get("declared"), "declared")
    confirmed = obj(receipt.get("confirmed"), "confirmed")
    text(receipt.get("evidence_kind"), "evidence_kind")
    paths(receipt.get("evidence_paths"), "evidence_paths")
    for role in ("parent", "child"):
        require(role in confirmed, f"missing confirmed.{role}")
        if confirmed[role] is None:
            continue
        config = obj(confirmed[role], f"confirmed.{role}")
        for key in ("provider", "model", "reasoning"):
            if config.get(key) is not None:
                text(config[key], key)
        for key in ("context_window", "compaction_threshold"):
            if config.get(key) is not None:
                require(number(config[key], key, True) > 0, f"{key} must be positive")
    return receipt


def effective_runtime(receipt: Json | None, attempt: Json, evidence_exists: bool) -> Json | None:
    if not receipt or receipt["status"] != "confirmed" or not evidence_exists:
        return None
    parent, child = receipt["confirmed"]["parent"], receipt["confirmed"]["child"]
    keys = ("provider", "model", "reasoning", "context_window", "compaction_threshold")
    if not parent or not child or any(parent.get(key) is None or child.get(key) is None for key in keys):
        return None
    if any(parent[key] != child[key] for key in keys):
        return None
    if any(parent[key] != attempt[key] for key in ("provider", "model", "reasoning")):
        return None
    if parent["compaction_threshold"] > parent["context_window"]:
        return None
    return {key: parent[key] for key in keys}


def validate_observation(value: Any, task_ids: set[str]) -> Json:
    row = version(value, "observation")
    for key in ("task_id", "subject_id", "state_hash", "source"):
        text(row.get(key), key)
    require(row["task_id"] in task_ids, "observation references unknown task")
    timestamp(row.get("timestamp"))
    choice(row.get("event"), EVENTS, "observation event")
    require("nonempty" in row and (row["nonempty"] is None or type(row["nonempty"]) is bool),
            "nonempty must be boolean or null")
    return row
