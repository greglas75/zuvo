#!/usr/bin/env python3
"""Run content-anchored shell mutations in one disposable farm job.

The normal mutation backends in this repository do not accept shell sources or
bash test files. This runner keeps each mutation off the checked-out tree and
requires a green control for every selected test before assigning verdicts.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parents[2]
SKIP = {".git", ".pytest_cache", ".stryker-tmp", "node_modules", "reports", "tf-artifacts", "zuvo"}
LAUNCHED = 0
REAPED = 0


def digest(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def execute(command: list[str], cwd: Path, timeout: int) -> tuple[str, int | None, str]:
    global LAUNCHED, REAPED
    process = subprocess.Popen(
        command, cwd=cwd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, start_new_session=True,
    )
    LAUNCHED += 1
    try:
        output, _ = process.communicate(timeout=timeout)
        REAPED += 1
        return "finished", process.returncode, output
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGTERM)
        try:
            output, _ = process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            output, _ = process.communicate()
        REAPED += 1
        return "timeout", None, output


def test_result(specs: list[str], sandbox: Path, timeout: int) -> tuple[str, str]:
    for spec in specs:
        state, code, output = execute(["bash", spec], sandbox, timeout)
        if state == "timeout":
            return "Timeout", f"{spec}: timed out; {output[-500:]}"
        if code != 0:
            # A failed assertion is a kill. A script that died before printing
            # its own verdict gives no evidence about assertion strength.
            if not re.search(r"(?:✗|FAILED|FAILURES PRESENT|RESULT: PASS=\d+ FAIL=[1-9])", output):
                return "RuntimeError", f"{spec}: exit {code} without a test verdict; {output[-500:]}"
            return "Killed", f"{spec}: exit {code}; {output[-500:]}"
        if not ("ALL PASS" in output or re.search(r"RESULT: PASS=\d+ FAIL=0", output)):
            return "RuntimeError", f"{spec}: exit 0 without a test summary; {output[-500:]}"
    return "Survived", "all mapped tests passed"


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("plan", type=Path)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--timeout", type=int, default=120)
    parser.add_argument("--only-survived", type=Path)
    parser.add_argument("--full", action="store_true", help="run all declared shell suites per survivor")
    args = parser.parse_args()
    plan = json.loads(args.plan.read_text())
    if not isinstance(plan, list) or not plan:
        raise ValueError("plan must be a nonempty JSON array")
    prior = None
    if args.only_survived:
        prior = json.loads(args.only_survived.read_text())
        surviving = {row["id"] for row in prior["mutants"] if row["status"] == "Survived"}
        plan = [row for row in plan if row["id"] in surviving]
        if not plan:
            print("No survivors to re-probe")
            return 0

    all_specs = sorted({spec for row in plan for spec in row["specs"]})
    original = {}
    for row in plan:
        rel = row["file"]
        if Path(rel).is_absolute() or ".." in Path(rel).parts:
            raise ValueError(f"unsafe path: {rel}")
        raw = (ROOT / rel).read_bytes()
        if row.get("file_sha") != digest(raw):
            raise ValueError(f"source changed since plan: {rel}")
        original[rel] = raw
        before = row["original"].encode()
        if raw.count(before) != 1:
            raise ValueError(f"anchor must occur exactly once: {row['id']} ({raw.count(before)})")
        if before == row["replacement"].encode():
            raise ValueError(f"equivalent text in {row['id']}")
        for spec in row["specs"]:
            if Path(spec).is_absolute() or ".." in Path(spec).parts or not (ROOT / spec).is_file():
                raise ValueError(f"invalid test path: {spec}")

    started = time.monotonic()
    results = []
    with tempfile.TemporaryDirectory(prefix="zuvo-shell-mutation-") as temp:
        sandbox = Path(temp) / "repo"
        shutil.copytree(ROOT, sandbox, ignore=lambda _, names: set(names) & SKIP)
        # A few bash suites ask git for the repository root; none require the
        # caller's real object store. This repository is disposable.
        subprocess.run(["git", "init", "-q"], cwd=sandbox, check=True)
        for spec in all_specs:
            verdict, reason = test_result([spec], sandbox, args.timeout)
            if verdict != "Survived":
                print(f"CONTROL RED {spec}: {verdict}: {reason}", flush=True)
                return 2
        print(f"CONTROL GREEN {len(all_specs)} shell suites", flush=True)

        for number, row in enumerate(plan, 1):
            path = sandbox / row["file"]
            pristine = original[row["file"]]
            before = row["original"].encode()
            after = row["replacement"].encode()
            # Re-check the anchor before each mutation. A previous test must
            # never be allowed to move the source silently.
            if path.read_bytes() != pristine:
                raise RuntimeError(f"source drift before {row['id']}")
            mutated = pristine.replace(before, after, 1)
            try:
                path.write_bytes(mutated)
                if path.suffix == ".py":
                    compile(mutated, str(path), "exec")
                elif path.suffix == ".sh":
                    # Some shell fixtures use Bash arrays and process substitution.
                    state, code, detail = execute(["bash", "-n", row["file"]], sandbox, 10)
                    if state != "finished" or code != 0:
                        raise SyntaxError(detail)
                specs = all_specs if args.full else row["specs"]
                status, reason = test_result(specs, sandbox, args.timeout)
            except SyntaxError as exc:
                status, reason = "CompileError", str(exc)
            finally:
                path.write_bytes(pristine)
                if digest(path.read_bytes()) != digest(pristine):
                    raise RuntimeError(f"restore failed after {row['id']}")
            result = {"id": row["id"], "file": row["file"], "category": row["category"],
                      "status": status, "reason": reason}
            results.append(result)
            print(f"{number}/{len(plan)} {row['id']} {status}: {reason[:140]}", flush=True)

        for rel, raw in original.items():
            if (sandbox / rel).read_bytes() != raw:
                raise RuntimeError(f"final restore mismatch: {rel}")
    # A syntax-invalid mutant does not prove an assertion detects bad behavior.
    scoreable = [r for r in results if r["status"] in ("Killed", "Survived", "Timeout")]
    killed = sum(r["status"] != "Survived" for r in scoreable)
    report = {"engine": "zuvo:mutation-test shell-ablation", "plan_completed": len(results) == len(plan),
              "scope": sorted(original), "mode": "full-related" if args.full else "mapped",
              "mutations_planned": len(plan), "mutations_executed": len(results),
              "controls": {"passed": len(all_specs), "failed": 0},
              "restored": True, "runners": {"launched": LAUNCHED, "reaped": REAPED},
              "score_raw": round(100 * killed / len(scoreable), 2) if scoreable else None,
              "elapsed_s": round(time.monotonic() - started, 2), "mutants": results}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(report, indent=2) + "\n")
    print(f"RESULT: measured={len(scoreable)}/{len(plan)} killed={killed} "
          f"survived={sum(r['status'] == 'Survived' for r in scoreable)} "
          f"score={report['score_raw']}% restored=true", flush=True)
    return 0 if len(scoreable) == len(plan) else 2


if __name__ == "__main__":
    sys.exit(main())
