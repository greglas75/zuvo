#!/usr/bin/env bash
# Stable entry point; Python modules own validation, collection and ranking.
# Usage and migration contract: skills/refactor-radar/references/contract.md
set -euo pipefail
RADAR_DIR="$(cd "$(dirname "$0")" && pwd)"
# Python 3 through portable.sh, which ships beside the modules in the checkout and in the installed
# bundle: on Windows `python3` is often the Microsoft Store stub (exits 49) and `py -3` the launcher.
# A farm worker receives only this script and lib/radar_*.py (radar_snapshot.prepare): python3 there.
export PYTHONUTF8="${PYTHONUTF8:-1}" PYTHONIOENCODING="${PYTHONIOENCODING:-utf-8}"
PY=python3
if [ -f "$RADAR_DIR/lib/portable.sh" ]; then
  . "$RADAR_DIR/lib/portable.sh"
  PY="$(zuvo_python </dev/null)" || exit 2
fi
if [ "$PY" = "py -3" ]; then
  exec py -3 -B "$RADAR_DIR/lib/radar_cli.py" "$@"
fi
exec "$PY" -B "$RADAR_DIR/lib/radar_cli.py" "$@"
