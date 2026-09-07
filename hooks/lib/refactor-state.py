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
import re

TERMINAL = {"COMPLETE", "BLOCKED", "ABORTED"}
REDUCTION_TYPES = {"SPLIT_FILE", "GOD_CLASS", "SIMPLIFY"}


def contract_version(contract):
    """One version interpretation for CLI writes and shell gate reads."""
    try:
        return int(contract.get("version") or 0)
    except (TypeError, ValueError, OverflowError):
        return 0


def fixes_claimed(contract):
    """v6 outcomes are enums; narrative mentions of 'fix' do not claim a fix."""
    return contract.get("findings_outcome") in ("fixed", "mixed") or bool(contract.get("fix_findings"))


def test_quality_report(value, root):
    """Validate the complete field without trimming commentary or legitimate path spaces."""
    if isinstance(value, str) and (value == "N/A" or value.startswith("N/A:")):
        return None
    parts = value.split(":", 2) if isinstance(value, str) else []
    if len(parts) != 3 or parts[0] not in ("PASS", "WARN") or not parts[1].strip():
        raise ValueError(
            "prove.test_quality: use 'PASS:<tier>:<report path>', 'WARN:<tier>:<report path>', or 'N/A'"
        )
    name = parts[2]
    if (not name or os.path.isabs(name) or ntpath.isabs(name)
            or ".." in name.replace("\\", "/").split("/")):
        raise ValueError("prove.test_quality: report path must be repo-relative with no '..' segments")
    path = (Path(root) / name).resolve()
    try:
        path.relative_to(Path(root).resolve())
    except ValueError:
        raise ValueError("prove.test_quality: report path resolves outside the repository") from None
    if not path.is_file():
        raise ValueError(
            "prove.test_quality: named report does not exist at %r; supply only the report path "
            "after the tier, with commentary in the report" % name
        )
    return path


def report_assessments(text):
    """Current summary values only; quoted examples and history cannot veto a new verdict."""
    summaries, gates, headings = {}, [], []
    fenced = False
    for number, line in enumerate(text.splitlines(), 1):
        if re.match(r"^\s*(?:```|~~~)", line):
            fenced = not fenced
            continue
        if fenced:
            continue
        heading = re.match(r"^\s*(#{1,6})\s+(.+)", line)
        if heading:
            depth, title = len(heading[1]), heading[2]
            headings = [(d, t) for d, t in headings if d < depth] + [(depth, title)]
        if any(re.match(r"(?:(?:version\s+)?history|historical|previous|baseline|archive)\b",
                        section.strip(), re.I)
               for _, title in headings for section in re.split(r"\s+[—–-]\s+|:\s*", title)):
            continue
        gate = re.match(r"^\s*\[GATE:\s*test-quality\]\s*(.*)", line, re.I)
        summary = re.search(r"\bTier/status\s*:\s*(.*)", line, re.I)
        if summary is None:
            summary = re.match(r"^\s*(?:Status|Verdict)\s*:\s*(.*)", line, re.I)
        if gate:
            gates.append((number, gate[1]))
        elif summary:
            kind = "tier" if re.search(r"\bTier/status\s*:", line, re.I) else "status"
            summaries[(tuple(headings), kind)] = (number, summary[1])
    # Repeated GATE rows are revisions of the overall verdict, not independent file audits.
    return list(summaries.values()) + gates[-1:]


def assessment_errors(contract, root, include_test_quality=True):
    """Inspect current assessment status fields, never baseline/history/free-form notes."""
    errors = []
    bad_status = re.compile(r"^(?:INCOMPLETE|FAIL(?:ED)?|BLOCKED)(?:\b|:)", re.I)
    known_status = re.compile(r"^(?:PASS(?:ED)?|CONDITIONAL PASS|WARN(?:ING)?|COMPLETE|N/A)(?:\b|:)", re.I)

    metadata = {"history", "previous", "baseline", "notes", "evidence", "artifacts", "progress",
                "config", "scope", "prove"}

    def visit(node, location, members=False):
        if isinstance(node, (dict, list)) and not node:
            errors.append(location + ": empty assessment")
            return
        if isinstance(node, dict):
            for key, value in node.items():
                if key in ("status", "verdict", "score"):
                    if key != "score" and (not isinstance(value, str) or not value.strip()):
                        errors.append(location + "." + key + ": invalid assessment status")
                    elif isinstance(value, str) and bad_status.match(value.strip()):
                        errors.append(location + "." + key + "=" + value)
                    elif key != "score" and not known_status.match(value.strip()):
                        errors.append(location + "." + key + ": unknown assessment status " + value)
                    elif key == "score" and not isinstance(value, (str, int, float)):
                        errors.append(location + ".score: invalid assessment score")
                elif key == "critical_failures":
                    if not isinstance(value, list):
                        errors.append(location + ".critical_failures: expected a list")
                    elif value:
                        errors.append(location + ".critical_failures: unresolved critical failures")
                elif key in ("files", "gates", "assessments", "results", "modules"):
                    visit(value, location + "." + key, members=True)
                elif re.fullmatch(r"CQ\d+|Q\d+", key) or "/" in key or "." in key:
                    visit(value, location + "." + key)
                elif key not in metadata and (members or isinstance(value, (dict, list))):
                    # Current assessment maps need not name files via one particular key.
                    # Historical/evidence containers do not represent the current verdict.
                    visit(value, location + "." + key)
        elif isinstance(node, list):
            for index, value in enumerate(node):
                visit(value, "%s[%d]" % (location, index))
        else:
            errors.append(location + ": expected an assessment object or collection")

    for key in ("cq_after", "q_after", "test_quality_assessment"):
        if key in contract:
            visit(contract[key], key)
    if not include_test_quality:
        return errors
    try:
        report = test_quality_report(field(contract, "prove.test_quality"), root)
        if report is not None:
            for number, value in report_assessments(report.read_text(encoding="utf-8")):
                # A leading verdict owns the value; 'PASS (previous FAIL fixed)' is PASS.
                # Tier rows can carry the established explicit 'Q7 formal INCOMPLETE'
                # clause, but arbitrary prose mentioning failure is not a status token.
                clauses = [re.sub(r"^(?:[A-D]|UNASSIGNED)\s*:\s*", "", value.strip(), flags=re.I)]
                clauses.extend(clause for clause in value.split(";")[1:]
                               if re.match(r"\s*(?:Q\d+\s+formal|formal\s+Q\d+)\s+", clause, re.I))
                invalid = not value.strip()
                warned = False
                for clause in clauses:
                    status = re.sub(
                        r"^(?:(?:Q\d+\s+formal|formal\s+Q\d+)\s+)", "", clause.strip(), flags=re.I
                    )
                    invalid = invalid or bool(bad_status.match(status))
                    warned = warned or bool(re.match(r"^WARN(?:ING)?\b", status, re.I))
                if invalid:
                    errors.append(
                        "prove.test_quality: assessment %s:%d is %s"
                        % (report.relative_to(Path(root).resolve()), number, value)
                    )
                elif str(field(contract, "prove.test_quality")).startswith("PASS:") and warned:
                    errors.append(
                        "prove.test_quality: PASS contradicts current report WARN at line %d" % number
                    )
    except (OSError, UnicodeError, ValueError) as exc:
        errors.append(str(exc))
    return errors


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
            if not path.is_file():
                return False
            digest = hashlib.sha256()
            with open(path, "rb") as stream:
                for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                    digest.update(chunk)
            return digest.hexdigest() == run.get("log_sha256")
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
    if outcome in ("none", "preserved") and (applied or pairs):
        errors.append("evidence.fix_regressions: no-fix outcome cannot carry applied findings or pairs")
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
        "action",
        choices=["valid", "field", "contains", "array", "count", "evidence", "intersects", "quality", "fixes"]
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
    if args.action == "fixes":
        return 0 if fixes_claimed(contract) else 1
    if args.action == "quality":
        errors = assessment_errors(contract, repository_root())
        for error in errors:
            print("BLOCK: " + error)
        return 1 if errors else 0
    if args.action == "evidence":
        errors = evidence_errors(contract)
        for error in errors:
            print("BLOCK: " + error)
        return 1 if errors else 0
    value = field(contract, args.key or "")
    if args.action == "field":
        if args.key == "version":
            print(contract_version(contract))
            return 0
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
