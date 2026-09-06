#!/usr/bin/env bash
# Medium tests: real git/CLI fixtures; external providers are mocked, never live.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
bash -n "$ROOT/scripts/refactor-radar.sh"
exec python3 -B -m unittest discover -s "$ROOT/tests/gates" -p 'test*radar*.py' -v
