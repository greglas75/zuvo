#!/bin/sh
# Polyglot entrypoint for hosts where Python is named python rather than python3.
''''exec "$(command -v python3 || command -v python || echo python3)" "$0" "$@" # '''
"""Conservative evidence keys: content, command, scope and declared execution environment."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess


def digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def snapshot(root, tests_only=False):
    """Include tracked and nonignored new inputs. Exclude only Zuvo's generated output."""
    root = Path(root).resolve()
    proc = subprocess.run(["git", "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                          cwd=root, capture_output=True, check=True)
    entries = []
    for name in sorted(set(os.fsdecode(proc.stdout).split("\0")) - {""}):
        if name.startswith(("zuvo/", "memory/reviews/")):
            continue
        if tests_only and not (any(part in ("tests", "test", "__tests__") for part in Path(name).parts)
                               or ".test." in name or ".spec." in name):
            continue
        path = root / name
        if path.is_symlink():
            entries.append((name, "symlink", str(path.readlink())))
        elif path.is_file():
            entries.append((name, path.stat().st_mode & 0o777, hashlib.sha256(path.read_bytes()).hexdigest()))
        # Absent paths contribute nothing: staging a deletion must not change the content key.
    return digest(entries)


def evidence_key(root, command, scope, toolchain, environment):
    if not all(str(v).strip() and str(v).lower() not in ("unknown", "pending")
               for v in (command, toolchain, environment)) or not scope:
        raise ValueError("reuse requires command, scope, toolchain and environment identity")
    return digest({"schema": 1, "root": str(Path(root).resolve()), "snapshot": snapshot(root),
                   "command": command, "scope": sorted(set(scope)),
                   "toolchain": toolchain, "environment": environment})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--root", default=".")
    parser.add_argument("--command", required=True)
    parser.add_argument("--scope", nargs="+", required=True)
    parser.add_argument("--toolchain", required=True)
    parser.add_argument("--environment", required=True)
    args = parser.parse_args()
    try:
        print(evidence_key(args.root, args.command, args.scope, args.toolchain, args.environment))
    except (ValueError, OSError, subprocess.CalledProcessError) as exc:
        parser.exit(2, "evidence unavailable: " + str(exc) + "\n")


if __name__ == "__main__":
    main()
