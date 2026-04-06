#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$ROOT_DIR/tests/seo-suite/assert.sh"

VALIDATOR="$ROOT_DIR/scripts/validate-seo-skill-contracts.sh"
BOT_REGISTRY="$ROOT_DIR/shared/includes/seo-bot-registry.md"
PAGE_PROFILES="$ROOT_DIR/shared/includes/seo-page-profile-registry.md"
CHECK_REGISTRY="$ROOT_DIR/shared/includes/seo-check-registry.md"
FIX_REGISTRY="$ROOT_DIR/shared/includes/seo-fix-registry.md"
AUDIT_SCHEMA="$ROOT_DIR/shared/includes/audit-output-schema.md"
FIX_SCHEMA="$ROOT_DIR/shared/includes/fix-output-schema.md"

echo "=== SEO Suite Shared Contract Smoke Test ==="

require_file "$ROOT_DIR/tests/seo-suite/assert.sh"
require_file "$BOT_REGISTRY"
require_file "$PAGE_PROFILES"
require_file "$CHECK_REGISTRY"
require_file "$FIX_REGISTRY"
require_file "$AUDIT_SCHEMA"
require_file "$FIX_SCHEMA"

bot_count="$(
  awk '
    /^\\| bot_key / { in_table=1; next }
    /^## Policy Notes/ { in_table=0 }
    in_table && /^\\| `/ { count++ }
    END { print count + 0 }
  ' "$BOT_REGISTRY"
)"
profile_count="$(grep -Ec '^### `[^`]+`$' "$PAGE_PROFILES")"

require_eq "$bot_count" "15" "bot registry row count"
require_eq "$profile_count" "5" "page profile count"

require_grep 'owner_agent' "$CHECK_REGISTRY"
require_grep 'enforcement' "$CHECK_REGISTRY"
require_grep 'evidence_mode' "$CHECK_REGISTRY"
require_grep 'llms-spec-compliance' "$CHECK_REGISTRY"
require_grep 'llms-best-practice' "$CHECK_REGISTRY"

pass "shared audit registries"
require_grep 'schema-cleanup' "$FIX_REGISTRY"
require_grep 'Manual checks:' "$FIX_REGISTRY"
require_grep 'network_override_risk' "$FIX_REGISTRY"
require_grep 'eta_minutes' "$FIX_REGISTRY"
require_grep 'bot_matrix' "$AUDIT_SCHEMA"
require_grep 'confidence_reason' "$AUDIT_SCHEMA"
require_grep 'manual_checks' "$FIX_SCHEMA"
require_grep 'network_override_risk' "$FIX_SCHEMA"
pass "shared fix and schema contracts"

require_file "$VALIDATOR"

pass "shared contract smoke test"
