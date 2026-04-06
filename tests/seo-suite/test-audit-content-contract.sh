#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
AGENT_FILE="$ROOT_DIR/skills/seo-audit/agents/seo-content.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$AGENT_FILE"

assert_contains "$AGENT_FILE" 'seo-page-profile-registry.md'
assert_contains "$AGENT_FILE" '`llms-best-practice`'
assert_contains "$AGENT_FILE" '`llms-spec-compliance`'
assert_contains "$AGENT_FILE" 'content_profile = app-shell'
assert_contains "$AGENT_FILE" 'most D10 checks should resolve to'
assert_contains "$AGENT_FILE" 'content_format = database'
assert_contains "$AGENT_FILE" 'downgrade D10'
assert_contains "$AGENT_FILE" 'report N/A for this check (do not FAIL -- presence is D5'
assert_contains "$AGENT_FILE" 'content scaffold advisory'
assert_contains "$AGENT_FILE" 'suggested H2/H3 outline'
assert_contains "$AGENT_FILE" 'answer-first opener pattern'

pass "seo-audit content contract"
