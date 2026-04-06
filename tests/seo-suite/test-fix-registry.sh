#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
REGISTRY="$ROOT_DIR/shared/includes/seo-fix-registry.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$REGISTRY"

assert_contains "$REGISTRY" '| `schema-cleanup` |'
assert_contains "$REGISTRY" '| `robots-fix` | `framework`, `issue`, `strategy`, `bot_policy_profile` |'
assert_contains "$REGISTRY" '`sub_issues`'
assert_contains "$REGISTRY" '`platform_overrides`'
assert_contains "$REGISTRY" 'network_override_risk=true'
assert_contains "$REGISTRY" 'Cloudflare Dashboard'
assert_contains "$REGISTRY" 'Strict-Transport-Security: max-age=31536000; includeSubDomains'
assert_contains "$REGISTRY" 'Content-Security-Policy-Report-Only'
assert_contains "$REGISTRY" 'route to `schema-cleanup`'
assert_contains "$REGISTRY" 'og:type=website'
assert_contains "$REGISTRY" 'og:type=article'
assert_contains "$REGISTRY" 'older than `180` days'
assert_contains "$REGISTRY" 'route handler fallback'
assert_contains "$REGISTRY" 'exit code 0'
assert_contains "$REGISTRY" '/llms-full.txt'
assert_contains "$REGISTRY" 'resolve as `404`'
assert_contains "$REGISTRY" '## Estimated Time Bands'
assert_contains "$REGISTRY" '| EASY | <30 minutes |'
assert_contains "$REGISTRY" '| MEDIUM | 1-4 hours |'
assert_contains "$REGISTRY" '| HARD | 1+ day |'

pass "seo-fix-registry"
