#!/usr/bin/env bash
# Stable entry point; Python modules own validation, collection and ranking.
# Usage and migration contract: skills/refactor-radar/references/contract.md
set -euo pipefail
RADAR_DIR="$(cd "$(dirname "$0")" && pwd)"
exec python3 -B "$RADAR_DIR/lib/radar_cli.py" "$@"
