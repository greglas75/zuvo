#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/tests/seo-suite/assert.sh"

CONTENT_TARGET="$ROOT_DIR/skills/seo-audit/agents/seo-content.md"
ASSETS_TARGET="$ROOT_DIR/skills/seo-audit/agents/seo-assets.md"

echo "=== SEO Audit Content/Assets Contract Test ==="

require_file "$CONTENT_TARGET"
require_file "$ASSETS_TARGET"

require_text 'seo-page-profile-registry.md' "$CONTENT_TARGET"
require_text 'llms-best-practice' "$CONTENT_TARGET"
require_text 'llms-spec-compliance' "$CONTENT_TARGET"
require_text 'content scaffold advisory' "$CONTENT_TARGET"

require_text 'Source vs Render Diff' "$ASSETS_TARGET"
require_text 'schema-cleanup' "$ASSETS_TARGET"
require_text 'Duplicate JSON-LD and Spam Signals' "$ASSETS_TARGET"
require_text 'og:type' "$ASSETS_TARGET"
require_text 'Homepage / index / landing pages -> `website`' "$ASSETS_TARGET"

pass "seo-audit content/assets contract"
