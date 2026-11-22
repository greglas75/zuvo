#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ASSERT_SH="$ROOT_DIR/tests/seo-suite/assert.sh"
SKILL_FILE="$ROOT_DIR/skills/seo-audit/SKILL.md"

# shellcheck source=tests/seo-suite/assert.sh
source "$ASSERT_SH"

assert_file_exists "$SKILL_FILE"

assert_contains "$SKILL_FILE" '| `--profile <marketing|docs|blog|ecommerce|app-shell>` |'
assert_contains "$SKILL_FILE" '| `--quick` | Technical + Assets |'
assert_contains "$SKILL_FILE" '| `--geo` | Technical + Content + Assets |'
assert_contains "$SKILL_FILE" 'Strengths'
assert_contains "$SKILL_FILE" 'Bot Policy Matrix'
assert_contains "$SKILL_FILE" 'Source vs Render Diff'
assert_contains "$SKILL_FILE" 'Content Table'
assert_contains "$SKILL_FILE" 'Fix Coverage Summary'
assert_contains "$SKILL_FILE" 'native agent dispatch is unavailable'
assert_contains "$SKILL_FILE" 'run the three agent analyses'
assert_contains "$SKILL_FILE" 'user-proxy'

# Critical gates are decidable without --live-url and read the page profile (Phase 4.1).
assert_contains "$SKILL_FILE" '`N/A` -- the active page profile exempts the gate'
assert_contains "$SKILL_FILE" 'Gates that need a live response are decided from source when source can decide them'
assert_contains "$SKILL_FILE" 'No `http://` refs is not proof of HTTPS.'
assert_contains "$SKILL_FILE" 'seo-page-profile-registry.md` "Gate applicability"'

pass "seo-audit skill contract"
