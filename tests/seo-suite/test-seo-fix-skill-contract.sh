#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
SKILL_FILE="$ROOT_DIR/skills/seo-fix/SKILL.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$SKILL_FILE"

assert_contains "$SKILL_FILE" 'schema-cleanup'
assert_contains "$SKILL_FILE" 'network_override_risk=true'
assert_contains "$SKILL_FILE" 'estimated_time'
assert_contains "$SKILL_FILE" 'manual_checks'
assert_contains "$SKILL_FILE" 'policy_notes'
assert_contains "$SKILL_FILE" 'advisory_scaffolds'
assert_contains "$SKILL_FILE" 'native agent dispatch is unavailable'
assert_contains "$SKILL_FILE" 'workflow sequentially'
assert_contains "$SKILL_FILE" 'user-proxy'

pass "seo-fix skill contract"
