#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
REGISTRY="$ROOT_DIR/shared/includes/seo-check-registry.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$REGISTRY"

assert_contains "$REGISTRY" '| `bot-policy-matrix` |'
assert_contains "$REGISTRY" '| `cloudflare-override-risk` |'
assert_contains "$REGISTRY" '| `robots-js-block` |'
assert_contains "$REGISTRY" '| `robots-pdf-block` |'
assert_contains "$REGISTRY" '| `robots-feed-block` |'
assert_contains "$REGISTRY" '| `source-render-parity` |'
assert_contains "$REGISTRY" '| `sitemap-lastmod` |'
assert_contains "$REGISTRY" '| `json-ld-duplicate-types` |'
assert_contains "$REGISTRY" '| `og-type` |'
assert_contains "$REGISTRY" "llms-spec-compliance"
assert_contains "$REGISTRY" "llms-best-practice"
assert_contains "$REGISTRY" "| D5 | 11 |"
assert_contains "$REGISTRY" "| D11 | 7 |"
assert_contains "$REGISTRY" "| **Total** | **66** |"

pass "seo-check-registry"
