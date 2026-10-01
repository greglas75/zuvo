#!/usr/bin/env bash
# Run verify-tests' stdlib Python siblings in the repository shell battery.
set -euo pipefail
repo_root="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$repo_root"
python3 -m unittest discover -s tests/hooks -p 'test_verify_tests_*.py' -v
