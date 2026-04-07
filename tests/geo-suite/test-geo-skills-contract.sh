#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
source "$ROOT_DIR/tests/geo-suite/test-helpers.sh"

# geo-audit SKILL.md
AUDIT="$ROOT_DIR/skills/geo-audit/SKILL.md"
assert_file_exists "$AUDIT"
assert_contains "$AUDIT" "geo-check-registry.md"
assert_contains "$AUDIT" "geo-fix-registry.md"
assert_contains "$AUDIT" "GCG1"
assert_contains "$AUDIT" "GCG4"
assert_contains "$AUDIT" "geo-crawl-access"
assert_contains "$AUDIT" "geo-schema-render"
assert_contains "$AUDIT" "geo-content-signals"
assert_contains "$AUDIT" '"skill": "geo-audit"'
assert_contains "$AUDIT" "Run:"

# geo-fix SKILL.md
FIX="$ROOT_DIR/skills/geo-fix/SKILL.md"
assert_file_exists "$FIX"
assert_contains "$FIX" "geo-fix-registry.md"
assert_contains "$FIX" "SAFE"
assert_contains "$FIX" "MODERATE"
assert_contains "$FIX" "DANGEROUS"
assert_contains "$FIX" "OUT_OF_SCOPE"
assert_contains "$FIX" "adversarial"
assert_contains "$FIX" "rollback"
assert_contains "$FIX" "scaffold"
assert_contains "$FIX" '"skill": "geo-fix"'
assert_contains "$FIX" "Run:"

# Agents exist
assert_file_exists "$ROOT_DIR/skills/geo-audit/agents/geo-crawl-access.md"
assert_file_exists "$ROOT_DIR/skills/geo-audit/agents/geo-schema-render.md"
assert_file_exists "$ROOT_DIR/skills/geo-audit/agents/geo-content-signals.md"

echo "geo-skills-contract: $PASS passed, $FAIL failed"
exit $FAIL
