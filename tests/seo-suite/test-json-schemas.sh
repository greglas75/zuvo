#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
AUDIT_SCHEMA="$ROOT_DIR/shared/includes/audit-output-schema.md"
FIX_SCHEMA="$ROOT_DIR/shared/includes/fix-output-schema.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$AUDIT_SCHEMA"
assert_file_exists "$FIX_SCHEMA"

assert_contains "$AUDIT_SCHEMA" '# Audit Output Schema (v1.1)'
assert_contains "$AUDIT_SCHEMA" '`site_profile`'
assert_contains "$AUDIT_SCHEMA" '`strengths`'
assert_contains "$AUDIT_SCHEMA" '`render_diff`'
assert_contains "$AUDIT_SCHEMA" '`coverage.fixable_ratio`'
assert_contains "$AUDIT_SCHEMA" '`manual_checks`'

assert_contains "$FIX_SCHEMA" '# Fix Output Schema (v1.1)'
assert_contains "$FIX_SCHEMA" '`estimated_time`'
assert_contains "$FIX_SCHEMA" '`manual_checks`'
assert_contains "$FIX_SCHEMA" '`advisory_scaffolds`'
assert_contains "$FIX_SCHEMA" '`policy_notes`'

pass "seo schema docs v1.1"
