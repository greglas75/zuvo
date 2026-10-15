#!/usr/bin/env bash
# Keep the stdlib unit specs of the `backlog-add` write path in the repository's shell test battery
# (run-all globs test-*.sh only). The spec set is an explicit REQUIRED list, not "whatever exists": a
# renamed or deleted spec would otherwise drop out silently and the remaining ones would still read as
# a green suite. A missing one is a FAIL that names it. Any further `test_backlog_add*.py` (a later
# split of the CLI spec) runs too; a spec under any other name must be added to REQUIRED by hand.
# Exit status is unittest's otherwise.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
REQUIRED=(
  tests/hooks/test_backlog_admit.py
  tests/hooks/test_backlog_findings.py
  tests/hooks/test_backlog_vcs.py
  tests/hooks/test_backlog_entry.py
  tests/hooks/test_backlog_lookup.py
  tests/hooks/test_backlog_add.py
  tests/hooks/test_backlog_dedup.py
  tests/hooks/test_backlog_dedup_signature.py
)
missing=()
for f in "${REQUIRED[@]}"; do
  [ -f "$f" ] || missing+=("$f")
done
if [ "${#missing[@]}" -gt 0 ]; then
  for f in "${missing[@]}"; do echo "FAIL: required backlog-add spec missing: $f" >&2; done
  exit 1
fi
specs=("${REQUIRED[@]}")
for f in tests/hooks/test_backlog_add*.py; do
  [ -f "$f" ] || continue
  case " ${specs[*]} " in *" $f "*) ;; *) specs+=("$f") ;; esac
done
echo "backlog-add specs: ${specs[*]}"
python3 -m unittest -v "${specs[@]}"
