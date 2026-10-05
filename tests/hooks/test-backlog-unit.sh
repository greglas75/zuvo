#!/usr/bin/env bash
# Keep the stdlib unit specs for scripts/zuvo-home/backlog in the repository's shell test battery
# (run-all globs test-*.sh). Exit status is unittest's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
python3 -m unittest -v tests/hooks/test_backlog_payload.py tests/hooks/test_backlog_collector.py \
  tests/hooks/test_backlog_views.py
