#!/usr/bin/env python3
"""Structural contract access shared by hooks and refactor-contract. No prose search."""

import argparse
import json
import hashlib
import os
import ntpath
import sys
from pathlib import Path
import importlib.util
import subprocess

TERMINAL = {"COMPLETE", "BLOCKED", "ABORTED"}


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate JSON key: " + key)
        result[key] = value
    return result


def read_contract(path):
    if not isinstance(path, (str, os.PathLike)):
        return None
    if os.path.basename(path).endswith(("-findings.json", "-adversarial.json")):
        return None
    try:
        with open(path, encoding="utf-8-sig") as stream:
            value = json.load(stream, object_pairs_hook=unique_object)
        if not isinstance(value, dict):
            return None
        if value.get("kind", "refactor-contract") != "refactor-contract":
            return None
        # Legacy contracts may omit version, kind and prove. Identity must still be top-level.
        if not any(key in value for key in ("stage", "file", "prove", "cq_before")):
            return None
        if "prove" in value and not isinstance(value["prove"], dict):
            return None
        return value
    except (OSError, ValueError, TypeError):
        return None


def field(contract, key):
    node = contract
    for part in key.split("."):
        if not isinstance(node, dict):
            return None
        node = node.get(part)
    return node


def repository_root():
    result = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], capture_output=True, text=True, check=True
    )
    return Path(result.stdout.strip()).resolve()


def current_snapshot():
    for candidate in (
        Path(__file__).resolve().parents[2] / "scripts/zuvo-home/workflow_evidence.py",
        Path.home() / ".zuvo/workflow_evidence.py",
    ):
        if candidate.is_file():
            spec = importlib.util.spec_from_file_location("workflow_evidence", candidate)
            if spec is None or spec.loader is None:
                raise OSError("snapshot helper cannot load")
            module = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(module)
            return module.snapshot(repository_root())
    raise OSError("snapshot helper unavailable")


def evidence_errors(contract, include_fixes=True):
    """v6 records: characterization stays green; each applied fix links actual red and green runs."""
    errors = []
    evidence = contract.get("evidence", {})
    if not isinstance(evidence, dict):
        return ["evidence: invalid object"]
    try:
        root = repository_root()
    except (OSError, subprocess.CalledProcessError):
        return ["evidence: repository root unavailable"]
    before, after = (evidence.get(k) for k in ("characterization_before", "characterization_after"))

    def valid(run):
        if (
            not isinstance(run, dict)
            or run.get("stable") is not True
            or not run.get("snapshot")
            or not run.get("run_id")
        ):
            return False
        if run.get("repo_root") != str(root):
            return False
        if type(run.get("exit_code")) is not int:
            return False
        if run.get("kind") != "compilation" and not (
            type(run.get("passed")) is int
            and type(run.get("failed")) is int
            and run["passed"] >= 0
            and run["failed"] >= 0
        ):
            return False
        log = run.get("log", "")
        if (
            not isinstance(log, str)
            or os.path.isabs(log)
            or ntpath.isabs(log)
            or ".." in log.replace("\\", "/").split("/")
        ):
            return False
        try:
            path = (root / log).resolve()
            path.relative_to(root)
            with open(path, "rb") as stream:
                return hashlib.sha256(stream.read()).hexdigest() == run.get("log_sha256")
        except (OSError, ValueError):
            return False

    if not (
        valid(before)
        and valid(after)
        and before.get("exit_code") == after.get("exit_code") == 0
        and before.get("command") == after.get("command")
        and before.get("passed") == after.get("passed")
        and before.get("run_id") != after.get("run_id")
        and not before.get("failed")
        and not after.get("failed")
        and (
            before.get("kind") == after.get("kind") == "compilation"
            and contract.get("test_mode") == "VERIFY_COMPILATION"
            or type(before.get("passed")) is int
            and before["passed"] > 0
        )
    ):
        errors.append("evidence.characterization_before/after")
    try:
        if not isinstance(after, dict) or after.get("snapshot") != current_snapshot():
            errors.append("evidence.characterization_after: stale snapshot")
    except (OSError, RuntimeError, ValueError, subprocess.CalledProcessError):
        errors.append("evidence.characterization_after: snapshot unavailable")
    if not include_fixes:
        return errors
    outcome = contract.get("findings_outcome")
    if outcome not in ("none", "preserved", "fixed", "mixed"):
        errors.append("findings_outcome (none|preserved|fixed|mixed required)")
    pairs = evidence.get("fix_regressions", [])
    applied = contract.get("fix_findings")
    # Contracts with no applied fixes legitimately omit fix_findings.  Treat an
    # omitted field as an empty list only for the no-change outcomes; malformed
    # data remains an evidence error, and fixed/mixed outcomes still require the
    # explicit applied finding IDs and red/green regression pairs.
    if applied is None and outcome in ("none", "preserved"):
        applied = []
    if not isinstance(pairs, list) or not isinstance(applied, list):
        return errors + ["evidence.fix_regressions"]
    fixes_claimed = outcome in ("fixed", "mixed")
    if fixes_claimed and not applied:
        errors.append("fix_findings (explicit applied finding IDs required)")
    for finding in applied:
        matches = [p for p in pairs if isinstance(p, dict) and p.get("finding_id") == finding]
        pair = matches[0] if len(matches) == 1 else {}
        red, green = pair.get("red"), pair.get("green")
        if not (
            valid(red)
            and valid(green)
            and red.get("exit_code") not in (0, 124, 126, 127, None)
            and type(red.get("failed")) is int
            and red["failed"] > 0
            and green.get("exit_code") == 0
            and type(green.get("passed")) is int
            and green["passed"] > 0
            and not green.get("failed")
            and red.get("command") == green.get("command")
            and red.get("run_id") != green.get("run_id")
            and red.get("test_snapshot")
            and red.get("test_snapshot") == green.get("test_snapshot")
        ):
            errors.append("evidence.fix_regressions:" + str(finding))
    return errors


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("path")
    parser.add_argument(
        "action", choices=["valid", "field", "contains", "array", "count", "evidence", "intersects"]
    )
    parser.add_argument("key", nargs="?")
    parser.add_argument("value", nargs="?")
    args = parser.parse_args()
    contract = read_contract(args.path)
    if contract is None:
        print("zuvo contract: unreadable or non-contract: " + args.path, file=sys.stderr)
        return 2
    if args.action == "valid":
        return 0
    if args.action == "evidence":
        errors = evidence_errors(contract)
        for error in errors:
            print("BLOCK: " + error)
        return 1 if errors else 0
    value = field(contract, args.key or "")
    if args.action == "field":
        if isinstance(value, (str, int, float)) and not isinstance(value, bool):
            print(value)
        return 0
    if not isinstance(value, list) or not all(isinstance(v, str) for v in value):
        return 2
    if args.action == "intersects":
        return 0 if set(value).intersection(sys.stdin.read().splitlines()) else 1
    if args.action == "contains":
        return 0 if args.value in value else 1
    if args.action == "count":
        print(len(value))
    else:
        print("\n".join(value))
    return 0


if __name__ == "__main__":
    sys.exit(main())
