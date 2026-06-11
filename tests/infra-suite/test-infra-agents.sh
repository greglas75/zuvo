#!/usr/bin/env bash
# tests/infra-suite/test-infra-agents.sh
# Task 8 RED/GREEN contract test for the 4 analyst agent markdown files.
# Pure file asserts — no docker, no LLM invocation.
# Sources: tests/seo-suite/assert.sh (hard-exit style)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../seo-suite/assert.sh
source "$SCRIPT_DIR/../seo-suite/assert.sh"

HOST_ANALYST="$ROOT_DIR/skills/infra-audit/agents/host-analyst.md"
NETWORK_ANALYST="$ROOT_DIR/skills/infra-audit/agents/network-analyst.md"
CONTAINER_ANALYST="$ROOT_DIR/skills/infra-audit/agents/container-analyst.md"
DATA_ANALYST="$ROOT_DIR/skills/infra-audit/agents/data-analyst.md"

# ─── Helper: assert frontmatter field present ────────────────────────────────
assert_frontmatter_field() {
  local file="$1"
  local field="$2"
  if ! awk '/^---/{c++} c==1 || c>=2{print} c>=2{exit}' "$file" \
       | grep -qE "^${field}[[:space:]]*:"; then
    fail "frontmatter field '${field}:' missing in $(basename "$file")"
  fi
}

# ─── Helper: assert frontmatter contains a string value ─────────────────────
assert_frontmatter_contains() {
  local file="$1"
  local needle="$2"
  if ! awk '/^---/{c++} c==1 || c>=2{print} c>=2{exit}' "$file" \
       | grep -qFe "$needle"; then
    fail "frontmatter missing '$needle' in $(basename "$file")"
  fi
}

# ─── Helper: assert body (non-frontmatter) contains text ────────────────────
assert_body_contains() {
  local file="$1"
  local needle="$2"
  # Skip everything up to and including the closing --- of frontmatter
  if ! awk 'BEGIN{fm=0} /^---/{fm++; next} fm>=2{print}' "$file" \
       | grep -qF "$needle"; then
    fail "body missing '$needle' in $(basename "$file")"
  fi
}

# ─── Helper: assert body contains a regex pattern ───────────────────────────
assert_body_grep() {
  local file="$1"
  local pattern="$2"
  if ! awk 'BEGIN{fm=0} /^---/{fm++; next} fm>=2{print}' "$file" \
       | grep -qE "$pattern"; then
    fail "body missing pattern '$pattern' in $(basename "$file")"
  fi
}

# ─── Helper: assert body does NOT contain a string ──────────────────────────
assert_body_not_contains() {
  local file="$1"
  local needle="$2"
  local label="${3:-$needle}"
  if awk 'BEGIN{fm=0} /^---/{fm++; next} fm>=2{print}' "$file" \
       | grep -qF "$needle"; then
    fail "body must NOT mention '$label' in $(basename "$file")"
  fi
}

# ─── Helper: assert body does NOT match regex ───────────────────────────────
assert_body_not_grep() {
  local file="$1"
  local pattern="$2"
  local label="${3:-$pattern}"
  if awk 'BEGIN{fm=0} /^---/{fm++; next} fm>=2{print}' "$file" \
       | grep -qE "$pattern"; then
    fail "body must NOT match pattern '$label' in $(basename "$file")"
  fi
}

echo "=== test-infra-agents.sh ==="

# ══════════════════════════════════════════════════════════════════════════════
# 1. FILE EXISTS
# ══════════════════════════════════════════════════════════════════════════════

assert_file_exists "$HOST_ANALYST"
pass "host-analyst.md exists"

assert_file_exists "$NETWORK_ANALYST"
pass "network-analyst.md exists"

assert_file_exists "$CONTAINER_ANALYST"
pass "container-analyst.md exists"

assert_file_exists "$DATA_ANALYST"
pass "data-analyst.md exists"

# ══════════════════════════════════════════════════════════════════════════════
# 2. FRONTMATTER FIELDS: name, model: sonnet, tools: containing Read and Bash
# ══════════════════════════════════════════════════════════════════════════════

for AGENT_FILE in "$HOST_ANALYST" "$NETWORK_ANALYST" "$CONTAINER_ANALYST" "$DATA_ANALYST"; do
  LABEL="$(basename "$AGENT_FILE")"

  assert_frontmatter_field "$AGENT_FILE" "name"
  pass "$LABEL: frontmatter has 'name:'"

  assert_frontmatter_field "$AGENT_FILE" "description"
  pass "$LABEL: frontmatter has 'description:'"

  assert_frontmatter_contains "$AGENT_FILE" "model: sonnet"
  pass "$LABEL: frontmatter has 'model: sonnet'"

  assert_frontmatter_contains "$AGENT_FILE" "- Read"
  pass "$LABEL: frontmatter tools contains 'Read'"

  assert_frontmatter_contains "$AGENT_FILE" "- Bash"
  pass "$LABEL: frontmatter tools contains 'Bash'"
done

# ══════════════════════════════════════════════════════════════════════════════
# 3. BODY REFERENCES: infra-check-registry.md and agent-preamble.md
# ══════════════════════════════════════════════════════════════════════════════

for AGENT_FILE in "$HOST_ANALYST" "$NETWORK_ANALYST" "$CONTAINER_ANALYST" "$DATA_ANALYST"; do
  LABEL="$(basename "$AGENT_FILE")"

  assert_body_contains "$AGENT_FILE" "infra-check-registry.md"
  pass "$LABEL: body references infra-check-registry.md"

  assert_body_contains "$AGENT_FILE" "agent-preamble.md"
  pass "$LABEL: body references agent-preamble.md"
done

# ══════════════════════════════════════════════════════════════════════════════
# 4. DIMENSION ASSIGNMENT: each agent declares EXACTLY its assigned dimensions
#    and NONE of another agent's dimensions
#
#    host-analyst:      IS1,IS2,IS5,IS6,IS7,IS11
#    network-analyst:   IS3,IS4,IS8
#    container-analyst: IS9
#    data-analyst:      IS10,IS12
# ══════════════════════════════════════════════════════════════════════════════

_dim_declares=0

# 4a. host-analyst: must mention IS1/IS2/IS5/IS6/IS7/IS11; must NOT mention IS3/IS4/IS8/IS9/IS10/IS12
for DIM in IS1 IS2 IS5 IS6 IS7 IS11; do
  assert_body_grep "$HOST_ANALYST" "\b${DIM}\b"
  pass "host-analyst: declares dimension $DIM"
  (( _dim_declares++ )) || true
done
for DIM in IS3 IS4 IS8 IS9 IS10 IS12; do
  assert_body_not_grep "$HOST_ANALYST" "\b${DIM}\b" "$DIM (another agent's dimension)"
  pass "host-analyst: does NOT mention $DIM"
done

# 4b. network-analyst: must mention IS3/IS4/IS8; must NOT mention IS1/IS2/IS5/IS6/IS7/IS9/IS10/IS11/IS12
for DIM in IS3 IS4 IS8; do
  assert_body_grep "$NETWORK_ANALYST" "\b${DIM}\b"
  pass "network-analyst: declares dimension $DIM"
  (( _dim_declares++ )) || true
done
for DIM in IS1 IS2 IS5 IS6 IS7 IS9 IS10 IS11 IS12; do
  assert_body_not_grep "$NETWORK_ANALYST" "\b${DIM}\b" "$DIM (another agent's dimension)"
  pass "network-analyst: does NOT mention $DIM"
done

# 4c. container-analyst: must mention IS9; must NOT mention IS1/IS2/IS3/IS4/IS5/IS6/IS7/IS8/IS10/IS11/IS12
for DIM in IS9; do
  assert_body_grep "$CONTAINER_ANALYST" "\b${DIM}\b"
  pass "container-analyst: declares dimension $DIM"
  (( _dim_declares++ )) || true
done
for DIM in IS1 IS2 IS3 IS4 IS5 IS6 IS7 IS8 IS10 IS11 IS12; do
  assert_body_not_grep "$CONTAINER_ANALYST" "\b${DIM}\b" "$DIM (another agent's dimension)"
  pass "container-analyst: does NOT mention $DIM"
done

# 4d. data-analyst: must mention IS10/IS12; must NOT mention IS1/IS2/IS3/IS4/IS5/IS6/IS7/IS8/IS9/IS11
for DIM in IS10 IS12; do
  assert_body_grep "$DATA_ANALYST" "\b${DIM}\b"
  pass "data-analyst: declares dimension $DIM"
  (( _dim_declares++ )) || true
done
for DIM in IS1 IS2 IS3 IS4 IS5 IS6 IS7 IS8 IS9 IS11; do
  assert_body_not_grep "$DATA_ANALYST" "\b${DIM}\b" "$DIM (another agent's dimension)"
  pass "data-analyst: does NOT mention $DIM"
done

echo "dimension assignment disjoint and complete (${_dim_declares}/12)"

# ══════════════════════════════════════════════════════════════════════════════
# 5. GROUNDING RULE: every finding cites bundle.checks[].id; ungrounded → rejected
#    (Look for the grounding rule language in each agent)
# ══════════════════════════════════════════════════════════════════════════════

_grounding_pass=0
for AGENT_FILE in "$HOST_ANALYST" "$NETWORK_ANALYST" "$CONTAINER_ANALYST" "$DATA_ANALYST"; do
  LABEL="$(basename "$AGENT_FILE")"

  # Must reference bundle.checks[].id as grounding requirement
  assert_body_grep "$AGENT_FILE" "bundle\.checks\[\]\.id|bundle\.checks\["
  pass "$LABEL: grounding rule references bundle.checks[].id"

  # Must reference UNGROUNDED-FINDING rejection
  assert_body_contains "$AGENT_FILE" "UNGROUNDED-FINDING"
  pass "$LABEL: grounding rule references UNGROUNDED-FINDING rejection"

  (( _grounding_pass++ )) || true
done
echo "grounding rule: ${_grounding_pass}/4"

# ══════════════════════════════════════════════════════════════════════════════
# 6. IC-6 RULE: no CVE identifier unless verbatim in raw tool output
#    (trivy/grype/debsecan/apt)
# ══════════════════════════════════════════════════════════════════════════════

_ic6_pass=0
for AGENT_FILE in "$HOST_ANALYST" "$NETWORK_ANALYST" "$CONTAINER_ANALYST" "$DATA_ANALYST"; do
  LABEL="$(basename "$AGENT_FILE")"

  # Must reference the IC-6 CVE evidence rule
  assert_body_grep "$AGENT_FILE" "CVE.*verbatim|verbatim.*CVE|IC-6"
  pass "$LABEL: IC-6 CVE evidence rule present"

  # 'verbatim' is the key word the test checks for (cross-referenced by plan AC6)
  assert_body_contains "$AGENT_FILE" "verbatim"
  pass "$LABEL: IC-6 rule uses 'verbatim'"

  (( _ic6_pass++ )) || true
done
echo "IC-6 rule: ${_ic6_pass}/4"

# ══════════════════════════════════════════════════════════════════════════════
# 7. DATA-ANALYST: E14 pgdsat dual-consent note
# ══════════════════════════════════════════════════════════════════════════════

assert_body_contains "$DATA_ANALYST" "pgdsat"
pass "data-analyst: references pgdsat"

# Dual consent: install consent AND query consent
assert_body_grep "$DATA_ANALYST" "dual.consent|install.*consent.*query|query.*consent"
pass "data-analyst: E14 pgdsat dual-consent note present"

assert_body_grep "$DATA_ANALYST" "DEGRADED.*pgdsat|pgdsat.*DEGRADED|pgdsat.*declined"
pass "data-analyst: E14 pgdsat declined → DEGRADED present"

# ══════════════════════════════════════════════════════════════════════════════
# 8. NETWORK-ANALYST: internal/external diff + external.vantage semantics
#    (all 4 enum values: proxy/direct/none/failed)
# ══════════════════════════════════════════════════════════════════════════════

assert_body_contains "$NETWORK_ANALYST" "external.vantage"
pass "network-analyst: references external.vantage"

for VANTAGE_VAL in proxy direct none failed; do
  assert_body_contains "$NETWORK_ANALYST" "$VANTAGE_VAL"
  pass "network-analyst: external.vantage enum value '$VANTAGE_VAL' present"
done

assert_body_grep "$NETWORK_ANALYST" "internal.*external|external.*internal"
pass "network-analyst: internal/external diff logic present"

# external arrays may be empty when vantage != proxy/direct — "external data absent"
assert_body_grep "$NETWORK_ANALYST" "external.*absent|absent.*external|vantage.*proxy.*direct|proxy.*direct.*real"
pass "network-analyst: empty external arrays / vantage semantics documented"

echo ""
echo "=== SUMMARY ==="
echo "4/4 agents present"
echo "All assertions passed"
