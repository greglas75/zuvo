#!/usr/bin/env bash
# Task 3 — infra-check-registry.md contract test.
# TDD: written RED first (no registry file), then registry authored to turn it GREEN.
#
# Pure file-assertion test — no Docker, no SSH, no network.
# Verifies that shared/includes/infra-check-registry.md conforms to every
# normative contract element required by the infra-audit spec (DD-7, IC-3).
#
# Assertions:
#   1. file exists
#   2. header row exactly matches spec column order
#   3. ≥1 row for every dimension IS1..IS12
#   4. every check_id matches ^IS([1-9]|1[0-2])-[a-z0-9-]+$
#   5. every default_severity ∈ {CRITICAL,HIGH,MEDIUM,LOW}
#   6. no duplicate check_ids
#   7. contains the lynis default mapping note (WARNING→MEDIUM, SUGGESTION→LOW)
#   8. contains the spec's example row (IS1-sshd-permitrootlogin / CRITICAL / SSH-7408)
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
REGISTRY="$ROOT_DIR/shared/includes/infra-check-registry.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

# ---------------------------------------------------------------------------
# 1. File exists
# ---------------------------------------------------------------------------
assert_file_exists "$REGISTRY"
pass "file exists: shared/includes/infra-check-registry.md"

# ---------------------------------------------------------------------------
# 2. Header row matches NORMATIVE column order (spec §infra-check-registry row schema)
# ---------------------------------------------------------------------------
EXPECTED_HEADER="| check_id | dimension | default_severity | lynis_test_id | remediation_template | cis_ref |"
require_text "$EXPECTED_HEADER" "$REGISTRY"
pass "header row EXACTLY matches normative column order"

# ---------------------------------------------------------------------------
# 3. ≥1 data row for every dimension IS1..IS12
# ---------------------------------------------------------------------------
DIMS_COVERED=0
DIMS_MISSING=()
for n in $(seq 1 12); do
  DIM="IS${n}"
  # A data row for ISn: check_id starts with ISn- and the dimension column is ISn
  # Row format: | IS<n>-<slug> | IS<n> | ...
  if grep -Eq "^\| IS${n}-[a-z0-9-]+ +\| IS${n} " "$REGISTRY"; then
    DIMS_COVERED=$(( DIMS_COVERED + 1 ))
  else
    DIMS_MISSING+=("$DIM")
  fi
done

# Print the count line BEFORE the check so it's visible even on failure
echo "  Dimensions covered: ${DIMS_COVERED}/12"
if [ "${#DIMS_MISSING[@]}" -gt 0 ]; then
  fail "missing rows for dimensions: ${DIMS_MISSING[*]}"
fi
pass "12/12 dimensions covered (IS1..IS12 each have ≥1 row)"

# ---------------------------------------------------------------------------
# 4. Every check_id (col 1 of data rows) matches ^IS([1-9]|1[0-2])-[a-z0-9-]+$
# ---------------------------------------------------------------------------
INVALID_IDS=()
# Extract check_ids from data rows (lines starting with | IS)
while IFS= read -r line; do
  # Trim leading pipe and whitespace to get the first column value
  check_id="$(echo "$line" | sed 's/^|[[:space:]]*//' | cut -d'|' -f1 | tr -d ' ')"
  if [[ -z "$check_id" ]]; then
    continue
  fi
  # Validate against the spec pattern
  if ! echo "$check_id" | grep -Eq '^IS([1-9]|1[0-2])-[a-z0-9-]+$'; then
    INVALID_IDS+=("$check_id")
  fi
done < <(grep -E '^\| IS[0-9]' "$REGISTRY")

echo "  Invalid check_ids: ${#INVALID_IDS[@]}"
if [ "${#INVALID_IDS[@]}" -gt 0 ]; then
  fail "check_ids with invalid format: ${INVALID_IDS[*]}"
fi
pass "all check_ids match ^IS([1-9]|1[0-2])-[a-z0-9-]+\$"

# ---------------------------------------------------------------------------
# 5. Every default_severity ∈ {CRITICAL,HIGH,MEDIUM,LOW}
# ---------------------------------------------------------------------------
INVALID_SEVS=()
while IFS= read -r line; do
  # Third column (after check_id | dimension |) is default_severity
  severity="$(echo "$line" | cut -d'|' -f4 | tr -d ' ')"
  if [[ -z "$severity" ]]; then
    continue
  fi
  case "$severity" in
    CRITICAL|HIGH|MEDIUM|LOW) ;;
    *) INVALID_SEVS+=("$severity") ;;
  esac
done < <(grep -E '^\| IS[0-9]' "$REGISTRY")

echo "  Invalid severities: ${#INVALID_SEVS[@]}"
if [ "${#INVALID_SEVS[@]}" -gt 0 ]; then
  fail "invalid default_severity values: ${INVALID_SEVS[*]}"
fi
pass "all default_severity values ∈ {CRITICAL,HIGH,MEDIUM,LOW}"

# ---------------------------------------------------------------------------
# 6. No duplicate check_ids
# ---------------------------------------------------------------------------
DUPE_COUNT=0
DUPES=""
DUPES="$(grep -E '^\| IS[0-9]' "$REGISTRY" \
  | sed 's/^|[[:space:]]*//' | cut -d'|' -f1 | tr -d ' ' \
  | sort | uniq -d)"
if [[ -n "$DUPES" ]]; then
  DUPE_COUNT="$(echo "$DUPES" | wc -l | tr -d ' ')"
fi

echo "  Duplicate check_ids: ${DUPE_COUNT}"
if [[ -n "$DUPES" ]]; then
  fail "duplicate check_ids found: $DUPES"
fi
pass "0 duplicate check_ids"

# ---------------------------------------------------------------------------
# 7. Lynis default mapping note: WARNING→MEDIUM and SUGGESTION→LOW
# ---------------------------------------------------------------------------
require_text "WARNING" "$REGISTRY"
require_text "SUGGESTION" "$REGISTRY"
# Both mapping arrows must appear (spec DD-7)
require_grep "WARNING.*MEDIUM|WARNING.MEDIUM" "$REGISTRY"
pass "lynis mapping note present: WARNING→MEDIUM"
require_grep "SUGGESTION.*LOW|SUGGESTION.LOW" "$REGISTRY"
pass "lynis mapping note present: SUGGESTION→LOW"

# ---------------------------------------------------------------------------
# 8. Spec example row: IS1-sshd-permitrootlogin with CRITICAL and SSH-7408
# ---------------------------------------------------------------------------
require_text "IS1-sshd-permitrootlogin" "$REGISTRY"
pass "spec example check_id IS1-sshd-permitrootlogin present"

require_grep "IS1-sshd-permitrootlogin.*CRITICAL" "$REGISTRY"
pass "IS1-sshd-permitrootlogin has severity CRITICAL"

require_grep "IS1-sshd-permitrootlogin.*SSH-7408|SSH-7408.*IS1-sshd-permitrootlogin" "$REGISTRY"
pass "IS1-sshd-permitrootlogin references lynis test SSH-7408"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
TOTAL_ROWS="$(grep -c -E '^\| IS[0-9]' "$REGISTRY" || true)"
echo ""
echo "  12/12 dimensions covered"
echo "  0 duplicate check_ids"
echo "  0 invalid severities"
echo "  Total data rows: ${TOTAL_ROWS}"
echo ""
echo "ALL INFRA-REGISTRY ASSERTIONS PASSED"
