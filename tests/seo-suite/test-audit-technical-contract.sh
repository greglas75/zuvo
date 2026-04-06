#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
AGENT_FILE="$ROOT_DIR/skills/seo-audit/agents/seo-technical.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$AGENT_FILE"

assert_contains "$AGENT_FILE" '`bot-policy-matrix`'
assert_contains "$AGENT_FILE" '`cloudflare-override-risk`'
assert_contains "$AGENT_FILE" '`robots-js-block`'
assert_contains "$AGENT_FILE" '`robots-pdf-block`'
assert_contains "$AGENT_FILE" '`robots-feed-block`'
assert_contains "$AGENT_FILE" 'user-proxy'
assert_contains "$AGENT_FILE" 'Cloudflare, WAF, CDN, or similar controls'
assert_contains "$AGENT_FILE" 'Each row must include:'
assert_contains "$AGENT_FILE" '- `tier`'
assert_contains "$AGENT_FILE" 'NEEDS_LIVE_CHECK'

pass "seo-audit technical contract"
