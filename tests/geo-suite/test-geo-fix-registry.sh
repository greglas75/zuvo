#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/tests/geo-suite/test-helpers.sh"
REGISTRY="$ROOT_DIR/shared/includes/geo-fix-registry.md"

assert_file_exists "$REGISTRY"
assert_contains "$REGISTRY" "robots-ai-allow"
assert_contains "$REGISTRY" "schema-org-add"
assert_contains "$REGISTRY" "schema-id-link"
assert_contains "$REGISTRY" "canonical-add"
assert_contains "$REGISTRY" "llms-txt-generate"
assert_contains "$REGISTRY" "SAFE"
assert_contains "$REGISTRY" "MODERATE"
assert_contains "$REGISTRY" "DANGEROUS"
assert_contains "$REGISTRY" "OUT_OF_SCOPE"
assert_contains "$REGISTRY" "upgrade_eligible"

echo "geo-fix-registry: $PASS passed, $FAIL failed"
exit $FAIL
