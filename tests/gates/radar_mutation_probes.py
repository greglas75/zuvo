"""Five planned mutation probes, not a native/exhaustive mutation score.

Run the WHOLE loop through rt. Only a disposable copy is mutated; production and tests
in the user's worktree are never rewritten. Baseline and byte-restored controls must pass.
"""

from __future__ import annotations

import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

ROOT = Path(__file__).resolve().parents[2]
PROBES = [
    (
        "dirty-source",
        "radar_git.py",
        'contents[path] = body.decode("utf-8")',
        'contents[path] = (root / path).read_text(encoding="utf-8")',
        "RadarCLI.test_explicit_head_reads_committed_blobs_even_when_dirty",
    ),
    (
        "provider-failure",
        "radar_remote.py",
        'evidence["errors"].append(f"{provider}: PR census incomplete',
        'evidence["complete"] = True\n        evidence["errors"].append(f"{provider}: PR census incomplete',
        "RemoteEvidence.test_provider_failure_is_unknown_without_leaking_credentials",
    ),
    (
        "scope-boundary",
        "radar_metrics.py",
        'path.startswith(scope.rstrip("/") + "/")',
        'path.startswith(scope.rstrip("/"))',
        "RadarCLI.test_scope_does_not_include_prefix_neighbour",
    ),
    (
        "dry-run-write",
        "radar_cli.py",
        "if args.dry_run:\n        return",
        "if False:\n        return",
        "RadarCLI.test_dry_run_does_not_create_queue_history_or_json",
    ),
    (
        "independent-nesting",
        "radar_metrics.py",
        'nesting = max((f["nest"] for f in functions), default=0)',
        'nesting = worst["nest"]',
        "RadarCLI.test_nested_maximum_is_not_taken_from_only_the_max_cc_function",
    ),
]


def run_tests(sandbox: Path, names: list[str]) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, "-B", "tests/gates/test_refactor_radar.py", *names],
        cwd=sandbox,
        capture_output=True,
        text=True,
        timeout=90,
    )


def main() -> int:
    results = []
    with tempfile.TemporaryDirectory(prefix="radar-probes-") as directory:
        sandbox = Path(directory)
        files = ["scripts/refactor-radar.sh", "tests/gates/test_refactor_radar.py"]
        files += [str(path.relative_to(ROOT)) for path in sorted((ROOT / "scripts/lib").glob("radar_*.py"))]
        for name in files:
            target = sandbox / name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(ROOT / name, target)
        tests = [probe[4] for probe in PROBES]
        baseline = run_tests(sandbox, tests)
        if baseline.returncode:
            print("PROBE_ERROR: baseline failed\n" + baseline.stdout + baseline.stderr)
            return 2
        for label, filename, before, after, test in PROBES:
            path = sandbox / "scripts/lib" / filename
            original = path.read_bytes()
            source = original.decode("utf-8")
            if source.count(before) != 1:
                raise ValueError("Probe anchor must be unique: " + label)
            mutated = source.replace(before, after, 1)
            compile(mutated, str(path), "exec")
            try:
                path.write_text(mutated, encoding="utf-8")
                outcome = run_tests(sandbox, [test])
            finally:
                path.write_bytes(original)
            restored = hashlib.sha256(path.read_bytes()).hexdigest() == hashlib.sha256(original).hexdigest()
            killed = outcome.returncode == 1 and "FAIL: " + test.split(".")[1] in outcome.stderr
            status = "Killed" if killed else "Survived" if outcome.returncode == 0 else "ProbeError"
            results.append(
                {
                    "probe": label,
                    "status": status,
                    "killed_by": test if killed else None,
                    "byte_restored": restored,
                }
            )
            if not killed:
                print(outcome.stdout + outcome.stderr)
        control = run_tests(sandbox, tests)
        print(
            json.dumps(
                {
                    "engine": "planned-probes",
                    "native": "none configured",
                    "results": results,
                    "post_restore_exit": control.returncode,
                },
                indent=2,
            )
        )
        return (
            0
            if control.returncode == 0
            and all(r["status"] == "Killed" and r["byte_restored"] for r in results)
            else 1
        )


if __name__ == "__main__":
    sys.exit(main())
