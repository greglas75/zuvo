#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
SCRIPT_FILE="$ROOT_DIR/scripts/validate-seo-skill-contracts.sh"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$SCRIPT_FILE"
assert_contains "$SCRIPT_FILE" 'shared/includes/seo-bot-registry.md'
assert_contains "$SCRIPT_FILE" 'shared/includes/seo-check-registry.md'
assert_contains "$SCRIPT_FILE" 'shared/includes/seo-fix-registry.md'
assert_contains "$SCRIPT_FILE" 'shared/includes/audit-output-schema.md'
assert_contains "$SCRIPT_FILE" 'shared/includes/fix-output-schema.md'
assert_contains "$SCRIPT_FILE" 'website/skills/seo-audit.yaml'
assert_contains "$SCRIPT_FILE" 'website/skills/seo-fix.yaml'
assert_contains "$SCRIPT_FILE" 'website claim drift'
assert_contains "$SCRIPT_FILE" 'schema field presence'
assert_contains "$SCRIPT_FILE" 'enum vocabulary'

pass "seo suite validator script"
