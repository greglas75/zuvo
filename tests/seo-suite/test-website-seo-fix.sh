#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
YAML_FILE="$ROOT_DIR/website/skills/seo-fix.yaml"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$YAML_FILE"

assert_contains "$YAML_FILE" 'value: "12"'
assert_contains "$YAML_FILE" 'schema-cleanup'
assert_contains "$YAML_FILE" 'estimated_time'
assert_contains "$YAML_FILE" 'manual_checks'
assert_contains "$YAML_FILE" 'policy_notes'
assert_contains "$YAML_FILE" 'advisory_scaffolds'
assert_contains "$YAML_FILE" 'NEEDS_PARAMS'
assert_contains "$YAML_FILE" 'per-finding rollback'
assert_contains "$YAML_FILE" 'exit `0`'
assert_contains "$YAML_FILE" '/llms-full.txt'
assert_contains "$YAML_FILE" '404'

pass "website seo-fix contract"
