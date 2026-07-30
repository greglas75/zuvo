#!/usr/bin/env bash
# Regression contract for the production-to-test evidence gate in write-tests.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/write-tests/SKILL.md"
EVALS="$ROOT/evals/write-tests.evals.json"
fail=0

pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

require_text() {
  needle="$1"
  label="$2"
  if grep -qF -- "$needle" "$SKILL"; then
    pass "$label"
  else
    bad "$label"
  fi
}

require_text "LOCAL COVERAGE GATE" "skill defines the local coverage gate"
require_text "every public entry point" "gate inventories every public entry point"
require_text "test-file:line" "gate requires line-level test evidence"
require_text "Uncovered owned rows: 0" "gate has a deterministic zero-gap condition"
require_text "Q7=1 and Q11=1" "critical error and branch gates are fail-closed"
require_text "BLOCKED_INCOMPLETE" "incomplete local evidence has a non-success state"
require_text "BLOCKED_INFRA" "reviewer infrastructure failure has a non-success state"
require_text "WRITE-TESTS COMPLETE" "completion report remains explicitly gated"

if python3 - "$EVALS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

matching = [case for case in data["evals"] if case["id"] == 3]
if len(matching) != 1:
    raise SystemExit(1)

case = matching[0]
joined = " ".join(case["assertions"]).lower()
required = (
    "every public controller method",
    "test-file:line",
    "outputs no write-tests complete",
)
if not all(term in joined for term in required):
    raise SystemExit(1)
PY
then
  pass "eval corpus contains the multi-method controller regression"
else
  bad "eval corpus contains the multi-method controller regression"
fi

exit "$fail"
