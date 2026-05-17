#!/usr/bin/env bash
# run.sh — Test runner for tests/adversarial/
# Usage:
#   bash tests/adversarial/run.sh              # run all test-*.sh
#   bash tests/adversarial/run.sh --self-test  # harness sanity check (no tests)
#   bash tests/adversarial/run.sh test-foo     # run specific test(s) by name (without .sh)
#   bash tests/adversarial/run.sh --list       # list discovered tests

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"

# Ensure empty fixture exists — used as no-op input by downstream tests.
# Scoped under tests/ to avoid /tmp symlink races and parallel-job collisions.
mkdir -p "$HERE/.tmp"
chmod 700 "$HERE/.tmp" 2>/dev/null || true
: > "$HERE/.tmp/empty.txt"
export ADV_TEST_EMPTY="$HERE/.tmp/empty.txt"
export ADV_TEST_HOME="$HERE/.tmp"

if [[ "${1:-}" == "--self-test" ]]; then
  echo "harness: ok"
  echo "root: $ROOT"
  echo "mocks: $HERE/mocks"
  ls "$HERE/mocks" >/dev/null 2>&1 && echo "mocks-dir: present" || echo "mocks-dir: missing"
  exit 0
fi

if [[ "${1:-}" == "--list" ]]; then
  for t in "$HERE"/test-*.sh; do
    [[ -e "$t" ]] && echo "$(basename "${t%.sh}")"
  done
  exit 0
fi

# Discover tests
declare -a TESTS=()
if [[ $# -gt 0 ]]; then
  for name in "$@"; do
    if [[ -f "$HERE/${name}.sh" ]]; then
      TESTS+=("$HERE/${name}.sh")
    else
      echo "[run.sh] unknown test: $name" >&2
      exit 2
    fi
  done
else
  for t in "$HERE"/test-*.sh; do
    [[ -e "$t" ]] && TESTS+=("$t")
  done
fi

if [[ ${#TESTS[@]} -eq 0 ]]; then
  echo "harness: ok"
  echo "tests: 0 discovered (run --self-test to verify harness)"
  exit 0
fi

TOTAL_RUN=0
TOTAL_FAIL=0
declare -a FAILED_FILES=()

for t in "${TESTS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════════════"
  echo "→ $(basename "$t")"
  echo "════════════════════════════════════════════════════════"
  # Run test in subshell so TESTS_RUN/FAILED can be captured. Pass paths via env,
  # not -c interpolation, so workspace paths containing apostrophes work correctly.
  out=$(
    ROOT="$ROOT" HERE="$HERE" ADV_TEST_FILE="$t" \
    ADV_TEST_EMPTY="$ADV_TEST_EMPTY" ADV_TEST_HOME="$ADV_TEST_HOME" \
    bash -c '
      source "$HERE/assert.sh"
      source "$ADV_TEST_FILE"
      echo "__SUMMARY__ $TESTS_RUN $TESTS_FAILED"
    '
  )
  printf '%s\n' "$out"
  summary=$(printf '%s\n' "$out" | grep '^__SUMMARY__' | tail -1)
  run=$(echo "$summary" | awk '{print $2}')
  fail=$(echo "$summary" | awk '{print $3}')
  TOTAL_RUN=$((TOTAL_RUN + ${run:-0}))
  TOTAL_FAIL=$((TOTAL_FAIL + ${fail:-0}))
  if [[ "${fail:-0}" -gt 0 ]]; then
    FAILED_FILES+=("$(basename "$t")")
  fi
done

echo ""
echo "════════════════════════════════════════════════════════"
echo "SUMMARY: $TOTAL_RUN run, $((TOTAL_RUN - TOTAL_FAIL)) passed, $TOTAL_FAIL failed"
if [[ "$TOTAL_FAIL" -gt 0 ]]; then
  echo "Failed test files:"
  for f in "${FAILED_FILES[@]}"; do echo "  - $f"; done
  exit 1
fi
exit 0
