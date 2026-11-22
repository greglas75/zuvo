#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
REGISTRY="$ROOT_DIR/shared/includes/seo-page-profile-registry.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$REGISTRY"

for profile in marketing docs blog ecommerce app-shell; do
  assert_contains "$REGISTRY" "### \`$profile\`"
done

for field in "Thin-content threshold" "Answer-first expectation" "E-E-A-T expectation" "Freshness sensitivity" "D9 enforcement" "D10 enforcement"; do
  count=$(grep -c -- "- $field:" "$REGISTRY")
  assert_equals "5" "$count" "seo-page-profile-registry must define '$field' for every profile"
done

assert_contains "$REGISTRY" "Profiles may downgrade heuristic checks"
assert_contains "$REGISTRY" "If the content source is inaccessible in the repo"
assert_contains "$REGISTRY" "D9/D10 checks are \`scored\` by default"

# Gate applicability: a profile exempts a gate (N/A), it never weakens one that applies.
assert_contains "$REGISTRY" "## Gate applicability"
for gate in CG1 CG2 CG3 CG4 CG5 CG6; do
  assert_contains "$REGISTRY" "| $gate "
done
assert_contains "$REGISTRY" "only when JSON-LD exists"
cg3_row=$(grep -F "| CG3 HTTPS" "$REGISTRY")
[ -n "$cg3_row" ] || fail "CG3 HTTPS row missing from the gate applicability table"
case "$cg3_row" in *N/A*) fail "CG3 (HTTPS) must apply to every profile, got: $cg3_row" ;; esac

pass "seo-page-profile-registry"
