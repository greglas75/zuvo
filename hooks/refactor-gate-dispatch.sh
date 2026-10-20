#!/bin/sh
# Stable entry for installed Git hooks. Resolve on every invocation, never at install time.
# Keep stdin untouched: pre-push receives the ref list on it.
if ! command -v python3 >/dev/null 2>&1; then
  echo 'zuvo refactor-gate: WARNING: Python resolver unavailable -> fail-open; repair: claude plugin install zuvo@zuvo-marketplace' >&2
  exit 0
fi
exec python3 -c '
import json
import os
from pathlib import Path
import re
import sys

home = Path.home()
roots = [home / ".zuvo/current"]
registry = home / ".claude/plugins/installed_plugins.json"
try:
    data = json.loads(registry.read_text())
    plugins = data.get("plugins", {}) if isinstance(data, dict) else {}
    records = plugins.get("zuvo@zuvo-marketplace", []) if isinstance(plugins, dict) else []
    if isinstance(records, dict):
        records = [records]
    if isinstance(records, list):
        roots.extend(Path(rec["installPath"]) for rec in records
                     if isinstance(rec, dict) and isinstance(rec.get("installPath"), str)
                     and Path(rec["installPath"]).is_absolute())
except (OSError, ValueError):
    pass  # A missing/stale registry must not strand the numeric cache fallback.

cache = home / ".claude/plugins/cache/zuvo-marketplace/zuvo"
try:
    versions = [p for p in cache.iterdir() if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", p.name)]
except OSError:
    versions = []
roots.extend(sorted(versions, key=lambda p: tuple(int(n) for n in p.name.split(".")), reverse=True))
gates = [root / "hooks/refactor-safety-gate.sh" for root in roots]
# Source installs and other harnesses need no Claude marketplace cache.
gates.extend(home / relative for relative in (
    ".codex/scripts/refactor-safety-gate.sh", ".cursor/scripts/refactor-safety-gate.sh",
    ".gemini/antigravity/hooks/refactor-safety-gate.sh", ".kimi-code/hooks/refactor-safety-gate.sh",
    ".zuvo-plugin/hooks/refactor-safety-gate.sh",
))
for gate in gates:
    try:
        if not gate.is_file():
            continue
        with gate.open("rb") as stream:
            if b"# Stable entry for installed Git hooks." in stream.read(256):
                print(f"zuvo refactor-gate: WARNING: recursive dispatcher skipped: {gate}", file=sys.stderr)
                continue
        if not os.access(gate, os.X_OK):
            print(f"zuvo refactor-gate: WARNING: non-executable gate skipped: {gate}", file=sys.stderr)
            continue
        os.execv(str(gate), [str(gate), *sys.argv[1:]])
    except OSError as err:
        # Includes unreadable releases and removal between lookup and exec.
        print(f"zuvo refactor-gate: WARNING: unavailable gate skipped: {gate}: {err}", file=sys.stderr)
print("zuvo refactor-gate: WARNING: no usable zuvo install found -> fail-open; "
      "repair: claude plugin install zuvo@zuvo-marketplace", file=sys.stderr)
sys.exit(0)
' "$@"
