#!/usr/bin/env bash
# Keep the stdlib unit specs of the `backlog-add` write path in the repository's shell test battery
# (run-all globs test-*.sh only). Every spec that EXISTS runs, so a later task adds its file without
# touching this wrapper. NONE existing is a failure: a renamed or deleted spec set must not read as a
# green, empty suite. Exit status is unittest's.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
specs=()
for f in tests/hooks/test_backlog_admit.py tests/hooks/test_backlog_findings.py \
         tests/hooks/test_backlog_vcs.py tests/hooks/test_backlog_entry.py tests/hooks/test_backlog_lookup.py \
         tests/hooks/test_backlog_add*.py; do
  if [ -f "$f" ]; then specs+=("$f"); fi
done
if [ "${#specs[@]}" -eq 0 ]; then
  echo "FAIL: no backlog-add spec (tests/hooks/test_backlog_{admit,findings,vcs,entry,lookup,add*}.py) found" >&2
  exit 1
fi
echo "backlog-add specs: ${specs[*]}"
python3 -m unittest -v "${specs[@]}"
