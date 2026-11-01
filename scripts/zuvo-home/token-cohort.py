#!/usr/bin/env python3
"""Compare explicit task cohorts without imputing missing evidence or hiding retries."""
from __future__ import annotations

import argparse
import json
import os
import stat
import sys
import tempfile
from contextlib import suppress
from pathlib import Path
from typing import Any, Callable

from token_cohort_metrics import build_report
from token_cohort_schema import (
    AMOUNTS, Json, effective_runtime, number, require, text, timestamp, validate_manifest,
    validate_observation, validate_result, validate_runtime, validate_usage, version,
)


def reject_constant(value: str) -> None:
    raise ValueError(f"nonfinite JSON constant {value}")


def unique_object(pairs: list[tuple[str, Any]]) -> Json:
    result: Json = {}
    for key, value in pairs:
        require(key not in result, f"duplicate JSON key {key}")
        result[key] = value
    return result


def decode(value: str) -> Any:
    return json.loads(value, parse_constant=reject_constant, object_pairs_hook=unique_object)


class Inputs:
    """Read only named regular files; retain even absent paths for output protection."""

    def __init__(self, manifest_path: Path) -> None:
        self.base = manifest_path.absolute().parent
        self.protected: set[Path] = set()

    def path(self, name: str) -> Path:
        path = (self.base / name).absolute()
        self.protected.add(path)
        return path

    def exists(self, path: Path) -> bool:
        if not path.exists():
            return False
        require(path.is_file(), f"input must be a regular file: {path}")
        return True

    def document(self, name: str, optional: bool = False) -> Any:
        path = self.path(name)
        if not self.exists(path):
            require(optional, f"missing input: {path}")
            return None
        return decode(path.read_text(encoding="utf-8"))

    def lines(self, name: str) -> list[tuple[int, Any]]:
        path = self.path(name)
        if not self.exists(path):
            return []
        with path.open(encoding="utf-8") as handle:
            return [(index, decode(line)) for index, line in enumerate(handle, 1) if line.strip()]

    def receipt(self, name: str | None, validator: Callable[[Any], Json]) -> Json | None:
        if name is None or not self.exists(self.path(name)):
            return None
        return validator(self.document(name))


def load_attempts(manifest: Json, inputs: Inputs) -> list[Json]:
    attempts = []
    for spec in manifest["attempts"]:
        issues = []
        transcripts = [inputs.path(name) for name in spec.get("transcript_paths", [])]
        missing = [inputs.path(name) for name in spec.get("missing_transcript_paths", [])]
        if not transcripts or missing or not all(inputs.exists(path) for path in transcripts):
            issues.append("missing_transcript")
        result = inputs.receipt(spec.get("result_receipt"), validate_result)
        runtime = inputs.receipt(spec.get("runtime_receipt"), validate_runtime)
        evidence = [inputs.path(name) for name in runtime["evidence_paths"]] if runtime else []
        config = effective_runtime(runtime, spec, bool(evidence) and all(inputs.exists(p) for p in evidence))
        if result:
            outside = ((result.get("started_at") is not None and
                        timestamp(result["started_at"]) < timestamp(manifest["window_start"])) or
                       (result.get("green_at") is not None and
                        timestamp(result["green_at"]) >= timestamp(manifest["window_end"])))
            if outside:
                issues.append("task_extends_beyond_window")
        if result and result.get("started_at") and spec["accepted_at"] is not None:
            require(timestamp(result["started_at"]) >= timestamp(spec["accepted_at"]),
                    "attempt started before acceptance")
        attempts.append({"spec": spec, "result": result, "runtime": config, "issues": issues})
    return attempts


def usage_records(attempts: list[Json], inputs: Inputs, manifest: Json) -> list[Json]:
    records: dict[tuple[Any, ...], Json] = {}
    cache: dict[Path, list[tuple[int, Any]]] = {}
    for index, attempt in enumerate(attempts):
        spec = attempt["spec"]
        seen = False
        for name in spec.get("usage_paths", []):
            path = inputs.path(name).resolve()
            if path not in cache:
                cache[path] = inputs.lines(name)
            if not cache[path]:
                attempt["issues"].append("missing_usage")
            for line, value in cache[path]:
                row = validate_usage(value)
                require(row["provider"] == spec["provider"], "usage provider differs from attempt")
                seen = True
                identity = ((row["provider"], row["response_id"]) if row["response_id"] is not None
                            else ("unknown", path, line))
                current = records.get(identity)
                if current is None:
                    records[identity] = {"row": dict(row), "owners": {index}, "origins": {str(path)},
                                         "threads": {row["thread_id"]}, "parents": {row["parent_id"]}}
                    continue
                old = current["row"]
                if timestamp(row["timestamp"]) == timestamp(old["timestamp"]):
                    require(all(row[key] == old[key] for key in AMOUNTS),
                            "conflicting same-time response amounts")
                    # A copied log may lack the parent's tool label; preserve the observed proxy.
                    if row["polling_proxy"]:
                        old["polling_proxy"] = row["polling_proxy"]
                elif timestamp(row["timestamp"]) > timestamp(old["timestamp"]):
                    current["row"] = dict(row)
                current["threads"].add(row["thread_id"])
                current["parents"].add(row["parent_id"])
                current["owners"].add(index)
                current["origins"].add(str(path))
        if not seen:
            attempt["issues"].append("missing_usage")
    start, end = timestamp(manifest["window_start"]), timestamp(manifest["window_end"])
    rows = [value for value in records.values() if start <= timestamp(value["row"]["timestamp"]) < end]
    for record in rows:
        row = record["row"]
        owners = record["owners"]
        direct = {index for index in owners if attempts[index]["spec"]["root_thread_id"] in record["threads"]}
        parents = {index for index in owners
                   if attempts[index]["spec"]["root_thread_id"] in record["parents"]}
        matches = direct or parents
        task_ids = {attempts[index]["spec"]["task_id"] for index in (matches or owners)}
        record["task_id"] = next(iter(task_ids)) if len(task_ids) == 1 else None
        for index in owners:
            if row["missing_response_id"] or row["source"] == "info.last_token_usage":
                attempts[index]["issues"].append("uncertain_usage_identity_or_source")
            if record["task_id"] is None:
                attempts[index]["issues"].append("ambiguous_response_ownership")
        record["origins"] = sorted(record["origins"])
    return sorted(rows, key=lambda record: (record["row"]["timestamp"], record["row"]["provider"],
                                           record["row"]["response_id"] or "", record["origins"]))


def observations(manifest: Json, inputs: Inputs) -> list[Json] | None:
    names = manifest.get("observation_paths", [])
    if not names:
        return None
    task_ids = {attempt["task_id"] for attempt in manifest["attempts"]}
    rows: dict[tuple[str, str, str], Json] = {}
    for name in names:
        require(inputs.exists(inputs.path(name)), "missing observation file")
        for _, value in inputs.lines(name):
            row = validate_observation(value, task_ids)
            key = (row["task_id"], row["subject_id"], timestamp(row["timestamp"]).isoformat())
            require(key not in rows or rows[key] == row, "conflicting observation timestamp")
            rows[key] = row
    end = timestamp(manifest["window_end"])
    # Earlier genuine reads establish context for the first in-window observation.
    return [rows[key] for key in sorted(rows) if timestamp(rows[key]["timestamp"]) < end]


def compactions(manifest: Json, inputs: Inputs) -> int | None:
    summaries: dict[tuple[str, str], int] = {}
    complete = True
    for attempt in manifest["attempts"]:
        names = attempt.get("profiler_summary_paths", [])
        covered: set[Path] = set()
        for name in names:
            summary = version(inputs.document(name), "profiler summary envelope")
            require(type(summary.get("accounting_version")) is int and summary["accounting_version"] == 2,
                    "invalid summary accounting_version")
            for window_key in ("window_start", "window_end"):
                require(timestamp(summary.get(window_key)) == timestamp(manifest[window_key]),
                        "summary window mismatch")
            source = inputs.path(text(summary.get("transcript_path"), "transcript_path")).resolve()
            require(source in {inputs.path(p).resolve() for p in attempt.get("transcript_paths", [])},
                    "summary does not belong to attempt transcript")
            thread_id = text(summary.get("thread_id"), "summary thread_id")
            count = number(summary.get("compactions"), "compactions", True)
            summary_key = (attempt["provider"], thread_id)
            require(summary_key not in summaries or summaries[summary_key] == count,
                    "conflicting thread compaction counts")
            summaries[summary_key] = int(count)
            covered.add(source)
        complete = complete and bool(names) and covered == {
            inputs.path(p).resolve() for p in attempt.get("transcript_paths", [])}
    return sum(summaries.values()) if complete else None


def check_output(destination: Path, inputs: Inputs) -> None:
    if destination.exists() or destination.is_symlink():
        require(stat.S_ISREG(destination.lstat().st_mode), "output must be a regular file")
    for path in inputs.protected:
        require(destination.resolve() != path.resolve(), "output aliases an input")
        if destination.exists() and path.exists():
            require(not os.path.samefile(destination, path), "output aliases an input inode")


def write_report(destination: Path, report: Json, inputs: Inputs) -> None:
    check_output(destination, inputs)
    temporary: str | None = None
    try:
        with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=destination.absolute().parent,
                                         delete=False) as handle:
            temporary = handle.name
            json.dump(report, handle, ensure_ascii=False, allow_nan=False, sort_keys=True, indent=2)
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        check_output(destination, inputs)
        os.replace(temporary, destination)
    finally:
        if temporary:
            with suppress(FileNotFoundError):
                os.unlink(temporary)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--out", required=True, type=Path)
    args = parser.parse_args()
    try:
        inputs = Inputs(args.manifest)
        manifest = validate_manifest(inputs.document(str(args.manifest.absolute())))
        attempts = load_attempts(manifest, inputs)
        rows = usage_records(attempts, inputs, manifest)
        observed = observations(manifest, inputs)
        count = compactions(manifest, inputs)
        report = build_report(manifest, attempts, rows, observed)
        report["compactions"] = count
        report["sources"] = sorted(str(path) for path in inputs.protected)
        write_report(args.out, report, inputs)
    except (ValueError, OSError, UnicodeError, OverflowError, RecursionError) as error:
        print(f"token-cohort: {error}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
