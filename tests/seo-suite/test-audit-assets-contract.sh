#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
AGENT_FILE="$ROOT_DIR/skills/seo-audit/agents/seo-assets.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$AGENT_FILE"

assert_contains "$AGENT_FILE" 'schema-cleanup'
assert_contains "$AGENT_FILE" 'template source is the source of truth'
assert_contains "$AGENT_FILE" 'description fields longer than `500` characters'
assert_contains "$AGENT_FILE" 'Homepage / index / landing pages -> `website`'
assert_contains "$AGENT_FILE" 'Blog posts / articles / news routes -> `article`'
assert_contains "$AGENT_FILE" '### Source vs Render Diff'
assert_contains "$AGENT_FILE" 'compare raw response vs rendered DOM for JSON-LD and key meta tags'

pass "seo-audit assets contract"
