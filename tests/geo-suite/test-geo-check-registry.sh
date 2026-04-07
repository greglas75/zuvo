#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/tests/geo-suite/test-helpers.sh"
REGISTRY="$ROOT_DIR/shared/includes/geo-check-registry.md"

assert_file_exists "$REGISTRY"
assert_contains "$REGISTRY" "## G1"
assert_contains "$REGISTRY" "## G12"
assert_contains "$REGISTRY" "geo-crawl-access"
assert_contains "$REGISTRY" "geo-schema-render"
assert_contains "$REGISTRY" "geo-content-signals"
assert_contains "$REGISTRY" "GCG1"
assert_contains "$REGISTRY" "GCG2"
assert_contains "$REGISTRY" "GCG3"
assert_contains "$REGISTRY" "GCG4"
assert_contains "$REGISTRY" "blocking"
assert_contains "$REGISTRY" "advisory"

echo "geo-check-registry: $PASS passed, $FAIL failed"
exit $FAIL
