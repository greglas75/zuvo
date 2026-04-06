#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
YAML_FILE="$ROOT_DIR/website/skills/seo-audit.yaml"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$YAML_FILE"

assert_contains "$YAML_FILE" 'value: "66"'
assert_contains "$YAML_FILE" 'user-proxy'
assert_contains "$YAML_FILE" '--profile <marketing|docs|blog|ecommerce|app-shell>'
assert_contains "$YAML_FILE" 'Strengths'
assert_contains "$YAML_FILE" 'Bot Policy Matrix'
assert_contains "$YAML_FILE" 'Source vs Render Diff'
assert_contains "$YAML_FILE" 'Content Table'
assert_contains "$YAML_FILE" 'Fix Coverage Summary'

pass "website seo-audit contract"
