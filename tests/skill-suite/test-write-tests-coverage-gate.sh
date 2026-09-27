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
ROUTING="$ROOT/shared/includes/test-reviewer-routing.md"
BLIND="$ROOT/shared/includes/blind-coverage-audit.md"
RETRO="$ROOT/shared/includes/retrospective.md"
MODELREG="$ROOT/shared/includes/model-registry.sh"
fail=0

pass() { printf 'PASS: %s\n' "$1"; }
bad() { printf 'FAIL: %s\n' "$1"; fail=1; }

require_text_in() {
  file="$1"
  needle="$2"
  label="$3"
  if grep -qF -- "$needle" "$file"; then
    pass "$label"
  else
    bad "$label"
  fi
}

require_absent_in() {
  file="$1"
  needle="$2"
  label="$3"
  if grep -qF -- "$needle" "$file"; then
    bad "$label"
  else
    pass "$label"
  fi
}

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
# The step used to be headed "LOCAL COVERAGE GATE" and to spell out four separate
# fix-and-rerun loops. It is now one command with one verdict, so the contract is the
# command and its terminal states -- a heading is a name, and naming it here again would
# just re-break this test the next time the step is renamed.
require_text "~/.zuvo/verify-tests" "skill runs verification through the single-verdict helper"
require_text "BUDGET EXHAUSTED" "the helper owns the stop condition, not the agent's judgement"
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
require_text "zuvo:test-audit" "final quality audit dispatches the real test-audit skill"
require_text "Tier A" "final audit targets tier A with fix-in-run"
require_text "Do not run \`tsc\` yourself" "skill forbids the ad-hoc project-wide typecheck"

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

# ── Plan B Task 9: Step 3.5 runs the blind-audit panel, no routing condition ──

# skills/write-tests/SKILL.md — outcome table keys off the panel's own line,
# not off routing; the Bash call is given enough headroom to outlive the driver.
require_text_in "$SKILL" '`Audit panel: strict` + `CLEAN`' \
  "SKILL.md Step 3.5 table: strict panel + CLEAN -> clean:strict"
require_text_in "$SKILL" '`Audit panel: degraded` + `CLEAN`' \
  "SKILL.md Step 3.5 table: degraded panel + CLEAN -> clean:degraded"
require_absent_in "$SKILL" "routing ok" \
  "SKILL.md Step 3.5 table no longer says 'routing ok'"
require_absent_in "$SKILL" "degraded routing" \
  "SKILL.md Step 3.5 table no longer says 'degraded routing'"
require_text_in "$SKILL" "timeout: 600000" \
  "SKILL.md Step 3.5 Bash call carries timeout: 600000"
require_text_in "$SKILL" "wait for the completion notification and read the output file" \
  "SKILL.md Step 3.5: a background move is wait-and-read, never BLOCKED_INFRA"

# shared/includes/test-reviewer-routing.md — panel invocation replaces the
# lane-agent table and the fresh-subprocess wrapper.
require_text_in "$ROUTING" "--mode blind-audit" \
  "test-reviewer-routing.md names adversarial-review --mode blind-audit"
require_text_in "$ROUTING" '--production "<absolute-path-to-production-file>"' \
  "test-reviewer-routing.md invocation passes --production"
require_text_in "$ROUTING" '--test "<absolute-path-to-test-file>"' \
  "test-reviewer-routing.md invocation passes --test"
require_text_in "$ROUTING" "strict — ≥ 2 valid panel answers" \
  "test-reviewer-routing.md exit table covers exit 0 (strict)"
require_text_in "$ROUTING" "degraded — exactly 1 valid panel answer" \
  "test-reviewer-routing.md exit table covers exit 3 (degraded)"
require_text_in "$ROUTING" "no valid panel answer" \
  "test-reviewer-routing.md exit table covers exit 2"
require_text_in "$ROUTING" "no provider lane after exclusion" \
  "test-reviewer-routing.md exit table covers exit 1"
require_text_in "$ROUTING" "empty or unauditable production/test file" \
  "test-reviewer-routing.md exit table covers exit 5"
require_text_in "$ROUTING" "input over the byte cap" \
  "test-reviewer-routing.md exit table covers exit 6"
require_text_in "$ROUTING" "per-provider or whole-run timeout" \
  "test-reviewer-routing.md exit table covers exit 124"
require_absent_in "$ROUTING" "reviewer_lane=review-primary" \
  "test-reviewer-routing.md: old lane->agent table (reviewer_lane=review-primary) is gone"
require_absent_in "$ROUTING" "Canonical fresh-subprocess fallback" \
  "test-reviewer-routing.md: Canonical fresh-subprocess fallback section is gone"
require_absent_in "$ROUTING" "Known client health" \
  "test-reviewer-routing.md: Known client health table is gone"
require_absent_in "$ROUTING" "Gemini 3.1 Pro (High)" \
  "test-reviewer-routing.md: stale Gemini 3.1 Pro (High) default is gone"
require_absent_in "$ROUTING" '-p "$(cat /tmp/blind-in.txt)"' \
  "test-reviewer-routing.md: hand-rolled agy -p \"\$(cat /tmp/blind-in.txt)\" block is gone"
require_text_in "$ROUTING" 'ZUVO_BASE="$(~/.zuvo/zuvo-base)"' \
  "test-reviewer-routing.md resolves \$ZUVO_BASE via ~/.zuvo/zuvo-base"

# shared/includes/blind-coverage-audit.md — documents the merged block's second
# line without disturbing the anti-echo template markers.
require_text_in "$BLIND" "Audit panel: strict|degraded valid=<k>/<m>" \
  "blind-coverage-audit.md documents the panel-merge Audit panel: line"
require_text_in "$BLIND" "Audit mode: strict" \
  "blind-coverage-audit.md Required Output template markers are intact"
require_text_in "$BLIND" '| B1 | branch | 18-24 | owned | FULL | file.test.ts:42-58 | verifies empty guard |' \
  "blind-coverage-audit.md anti-echo template row is intact"

# shared/includes/retrospective.md — blind_audit telemetry line reports the
# panel outcome, not a single provider name.
require_text_in "$RETRO" \
  'blind_audit: <clean:strict|clean:degraded|fix:N|rewrite|skipped|blocked_infra> | panel=<strict|degraded> valid=<k>/<m> providers=<a,b,c> | exit=<code> | rows=<INVENTORY N> | uncovered=<n>' \
  "retrospective.md blind_audit telemetry line uses the panel format"
require_absent_in "$RETRO" "FULL=<N> PARTIAL=<N> NONE=<N>" \
  "retrospective.md blind_audit line no longer carries the per-file FULL/PARTIAL/NONE tally"

# shared/includes/model-registry.sh — "Sourced by" comment must not claim the
# now-thin blind-audit-codex.sh wrapper still sources this file directly.
require_absent_in "$MODELREG" \
  "Sourced by: adversarial-review.sh, benchmark.sh, blind-audit-codex.sh, and scripts/lib/model-subprocess.sh" \
  "model-registry.sh 'Sourced by' comment no longer lists blind-audit-codex.sh as a direct sourcer"

exit "$fail"
