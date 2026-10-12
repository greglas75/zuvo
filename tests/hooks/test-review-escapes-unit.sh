#!/usr/bin/env bash
# Keep the stdlib unit specs for scripts/zuvo-home/review-escapes and its zuvo_escapes_*.py modules in
# the repository's shell test battery (run-all globs test-*.sh). Exit status is unittest's, and a run
# that collected no tests (a renamed or unimportable file) fails instead of passing empty.
# Arguments, when given, replace the default spec list (one spec file while working on it).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
specs=("$@")
[ "${#specs[@]}" -gt 0 ] || specs=(tests/hooks/test_escapes_blame.py tests/hooks/test_escapes_coverage.py
                                  tests/hooks/test_escapes_classify.py)
rc=0
out="$(python3 -m unittest -v "${specs[@]}" 2>&1)" || rc=$?
printf '%s\n' "$out"
[ "$rc" -eq 0 ] || exit "$rc"
grep -qE '^Ran [1-9][0-9]* tests? in ' <<<"$out" || { echo "FAIL: no tests ran"; exit 1; }
