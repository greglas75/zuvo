#!/usr/bin/env bash
# Preserve the real shell-harness verdict and expose its counts to refactor-contract.
set -uo pipefail

output=$(bash tests/adversarial/run.sh "$@"); rc=$?
printf '%s\n' "$output"
summary=$(printf '%s\n' "$output" | sed -n '/^SUMMARY: /p' | tail -1)
if [[ "$summary" =~ ^SUMMARY:\ ([0-9]+)\ run,\ ([0-9]+)\ passed,\ ([0-9]+)\ failed$ ]]; then
  total="${BASH_REMATCH[1]}"; passed="${BASH_REMATCH[2]}"; failed="${BASH_REMATCH[3]}"
  if (( total > 0 && passed + failed == total )); then
    printf 'RESULT: PASS=%s FAIL=%s\n' "$passed" "$failed"
    exit "$rc"
  fi
fi
printf 'RESULT: PASS=0 FAIL=1\n' >&2
echo 'adversarial-result: no valid executed summary' >&2
exit 1
