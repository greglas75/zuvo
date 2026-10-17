#!/usr/bin/env bash
# Keep the stdlib unit specs for scripts/zuvo-home/release-autoinstall and key-sync in the repository's
# shell test battery (run-all globs test-*.sh). Fails when no test ran: a module that stops importing
# makes unittest report "Ran 0 tests" — that must never read as green.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
OUT="$(python3 -m unittest -v tests/hooks/test_auto_ops.py 2>&1)" && rc=0 || rc=$?
printf '%s\n' "$OUT"
if [ "$rc" -eq 0 ] && printf '%s\n' "$OUT" | grep -qE '^Ran 0 tests'; then
  echo "FAIL: no auto-ops unit test ran"
  exit 1
fi
exit "$rc"
