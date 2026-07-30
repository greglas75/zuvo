#!/usr/bin/env bash
# Regression contract for the production-to-test evidence gate in write-tests.
#
# Architecture under contract (post inventory-first rework):
#   - the inventory is frozen BEFORE any test is written (Step 1.6/1.7)
#   - the coverage gate is EXECUTABLE (scripts/test-coverage-gate.py), not prose
#   - reviewer infrastructure is preflighted in Phase 0 (scripts/reviewer-preflight.sh)
#   - the eval corpus carries BOTH the small controller regression (id 3) and a
#     realistic 22-method controller with disk-artifact assertions (id 4)
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

# ── prose contract (strings the pipeline and other suites key on) ─────────────
require_text "LOCAL COVERAGE GATE" "skill defines the local coverage gate"
require_text "every public entry point" "gate inventories every public entry point"
require_text "test-file:line" "gate requires line-level test evidence"
require_text "Uncovered owned rows: 0" "gate has a deterministic zero-gap condition"
require_text "Q7=1 and Q11=1" "critical error and branch gates are fail-closed"
require_text "BLOCKED_INCOMPLETE" "incomplete local evidence has a non-success state"
require_text "BLOCKED_INFRA" "reviewer infrastructure failure has a non-success state"
require_text "WRITE-TESTS COMPLETE" "completion report remains explicitly gated"

# ── executable-gate contract ──────────────────────────────────────────────────
require_text "test-coverage-gate.py" "skill invokes the executable validator"
require_text "reviewer-preflight.sh" "skill preflights reviewer infrastructure in Phase 0"
require_text "Production Surface Inventory" "skill has an inventory step"
require_text "INVENTORY FROZEN" "inventory is frozen with printed metrics"

if [ -f "$ROOT/scripts/test-coverage-gate.py" ] && [ -x "$ROOT/scripts/test-coverage-gate.py" ]; then
  pass "scripts/test-coverage-gate.py exists and is executable"
else
  bad "scripts/test-coverage-gate.py exists and is executable"
fi

if [ -f "$ROOT/scripts/reviewer-preflight.sh" ] && [ -x "$ROOT/scripts/reviewer-preflight.sh" ]; then
  pass "scripts/reviewer-preflight.sh exists and is executable"
else
  bad "scripts/reviewer-preflight.sh exists and is executable"
fi

for inc in test-inventory-protocol coverage-manifest-schema test-reviewer-routing test-bugfix-protocol test-mutation-probes; do
  if [ -f "$ROOT/shared/includes/$inc.md" ]; then
    pass "shared/includes/$inc.md exists"
  else
    bad "shared/includes/$inc.md exists"
  fi
done

# ── ordering: the inventory step must precede the write step ──────────────────
inv_line="$(grep -nF 'Step 1.6: Production Surface Inventory' "$SKILL" | head -1 | cut -d: -f1)"
write_line="$(grep -nF '### Step 2: Write' "$SKILL" | head -1 | cut -d: -f1)"
if [ -n "$inv_line" ] && [ -n "$write_line" ] && [ "$inv_line" -lt "$write_line" ]; then
  pass "inventory (Step 1.6) precedes writing (Step 2) in the pipeline"
else
  bad "inventory (Step 1.6) precedes writing (Step 2) in the pipeline (inv=$inv_line write=$write_line)"
fi

# ── eval corpus: small controller regression (id 3) ───────────────────────────
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

# ── eval corpus: realistic 22-method controller with artifact assertions (id 4)
if python3 - "$EVALS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)

matching = [case for case in data["evals"] if case["id"] == 4]
if len(matching) != 1:
    raise SystemExit(1)

case = matching[0]

# The fixture must be the realistic surface: 20+ public methods including the
# indirectly-called and the easy-to-miss ones, fire-and-forget, catch-fallback.
fixtures = case.get("fixtures", [])
if len(fixtures) != 1:
    raise SystemExit(1)
content = fixtures[0]["content"]
for marker in ("buildExportRow", "verifyWebhookSignature", "healthcheck",
               "void this.audit.record", "syncProfile", "syncProfiles",
               "summary", "summarize"):
    if marker not in content:
        raise SystemExit(1)
import re
methods = re.findall(r"^  (?:async \*?|)([a-zA-Z]\w*)\(", content, re.M)
public_methods = [m for m in methods if m != "constructor"]
if len(public_methods) < 20:
    raise SystemExit(1)

# Assertions must grade disk artifacts, not only transcript vibes.
joined = " ".join(case["assertions"]).lower()
required = (
    "uncovered owned rows: 0",
    "coverage.json",
    "before creating any test file",
    "sibling spec",
    "mutation probes",
    "outputs no write-tests complete",
)
if not all(term in joined for term in required):
    raise SystemExit(1)
PY
then
  pass "eval corpus contains the realistic large-controller eval with artifact assertions"
else
  bad "eval corpus contains the realistic large-controller eval with artifact assertions"
fi

exit "$fail"
