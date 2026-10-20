#!/bin/sh
# zuvo:refactor-runtime-dispatcher
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

try:
    home = Path.home()
except RuntimeError as err:
    print(f"zuvo refactor-gate: WARNING: HOME unavailable: {err} -> fail-open; "
          "repair: claude plugin install zuvo@zuvo-marketplace", file=sys.stderr)
    sys.exit(0)
cache = home / ".claude/plugins/cache/zuvo-marketplace/zuvo"
roots = [(home / ".zuvo/current", False)]
registry = home / ".claude/plugins/installed_plugins.json"
try:
    data = json.loads(registry.read_text())
    plugins = data.get("plugins", {}) if isinstance(data, dict) else {}
    records = plugins.get("zuvo@zuvo-marketplace", []) if isinstance(plugins, dict) else []
    if isinstance(records, dict):
        records = [records]
    if isinstance(records, list):
        roots.extend((Path(rec["installPath"]), True) for rec in records
                     if isinstance(rec, dict) and isinstance(rec.get("installPath"), str)
                     and Path(rec["installPath"]).is_absolute())
except (OSError, ValueError):
    pass  # A missing/stale registry must not strand the numeric cache fallback.

try:
    versions = [p for p in cache.iterdir() if re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", p.name)]
except OSError:
    versions = []
roots.extend((root, True) for root in sorted(
    versions, key=lambda p: tuple(int(n) for n in p.name.split(".")), reverse=True))
gates = [(root, root / "hooks/refactor-safety-gate.sh", cached) for root, cached in roots]
# Source installs and other harnesses need no Claude marketplace cache.
gates.extend(((home / relative).parent, home / relative, False) for relative in (
    ".codex/scripts/refactor-safety-gate.sh", ".cursor/scripts/refactor-safety-gate.sh",
    ".gemini/antigravity/hooks/refactor-safety-gate.sh", ".kimi-code/hooks/refactor-safety-gate.sh",
    ".zuvo-plugin/hooks/refactor-safety-gate.sh",
))

def identity(status):
    return (status.st_dev, status.st_ino, status.st_size, status.st_mtime_ns,
            status.st_ctime_ns, status.st_mode)


dispatch_headers = {
    b"# zuvo:refactor-runtime-dispatcher",
    b"# Stable entry for installed Git hooks. Resolve on every invocation, never at install time.",
}
for root, gate, cached in gates:
    try:
        resolved_root = root.resolve()
        if cached and len(resolved_root.relative_to(cache.resolve()).parts) != 1:
            raise ValueError("registry/cache root is outside a zuvo cache install")
        # A gate symlink must not escape its selected install. The explicit
        # current pointer may name a source install outside the marketplace.
        if gate.resolve().relative_to(resolved_root) != gate.relative_to(root):
            raise ValueError("gate is outside its zuvo install")
        if not gate.is_file():
            continue
        if not os.access(gate, os.X_OK):
            print(f"zuvo refactor-gate: WARNING: non-executable gate skipped: {gate}", file=sys.stderr)
            continue
        with gate.open("rb") as stream:
            inspected = identity(os.fstat(stream.fileno()))
            if dispatch_headers.intersection(line.strip() for line in stream.read().splitlines()):
                print(f"zuvo refactor-gate: WARNING: recursive dispatcher skipped: {gate}", file=sys.stderr)
                continue
            if inspected != identity(os.fstat(stream.fileno())) or inspected != identity(gate.lstat()):
                raise OSError("concurrent gate change; candidate skipped")
            os.execv(str(gate), [str(gate), *sys.argv[1:]])
    except (OSError, ValueError, RuntimeError) as err:
        # Includes unreadable releases and removal between lookup and exec.
        print(f"zuvo refactor-gate: WARNING: unavailable gate skipped: {gate}: {err}", file=sys.stderr)
print("zuvo refactor-gate: WARNING: no usable zuvo install found -> fail-open; "
      "repair: claude plugin install zuvo@zuvo-marketplace", file=sys.stderr)
sys.exit(0)
' "$@"
