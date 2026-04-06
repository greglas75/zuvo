#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
REGISTRY="$ROOT_DIR/shared/includes/seo-bot-registry.md"

if [ ! -f "$ASSERT_SH" ]; then
  echo "FAIL: missing assert helper at $ASSERT_SH"
  exit 1
fi

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$REGISTRY"
assert_contains "$REGISTRY" "| bot_key | user_agent | provider | tier | default_recommendation | live_probe_required | cloudflare_sensitive | notes |"

row_count=$(grep -c '^| `' "$REGISTRY")
assert_equals "15" "$row_count" "seo-bot-registry must declare exactly 15 bot rows"

invalid_rows=$(awk -F'|' '
/^\| `/ {
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", $5)
  gsub(/^[[:space:]]+|[[:space:]]+$/, "", $6)
  if ($5 !~ /^(training|search|retrieval|user-proxy)$/ || $6 !~ /^(allow|disallow)$/) {
    bad++
  }
}
END {
  print bad + 0
}' "$REGISTRY")
assert_equals "0" "$invalid_rows" "seo-bot-registry rows must declare a valid tier and default_recommendation"

assert_contains "$REGISTRY" "| training |"
assert_contains "$REGISTRY" "| search |"
assert_contains "$REGISTRY" "| retrieval |"
assert_contains "$REGISTRY" "| user-proxy |"
assert_contains "$REGISTRY" '`GPTBot`'
assert_contains "$REGISTRY" '`OAI-SearchBot`'
assert_contains "$REGISTRY" '`ChatGPT-User`'

pass "seo-bot-registry"
