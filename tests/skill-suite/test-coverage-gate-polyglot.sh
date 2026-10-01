#!/usr/bin/env bash
# Keep the stdlib regression suite in the repository's shell test battery.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
python3 -m unittest -v tests/skill-suite/test_coverage_gate_polyglot.py
