#!/usr/bin/env bash
# leads-manifest-counts.sh — verify skill-count strings bumped across manifests.
set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
fail() { echo "FAIL: $1"; exit 1; }

grep -Fq '52 skills and 26' "$REPO_ROOT/package.json" \
  || fail "package.json description should contain '52 skills and 26'"
grep -Fq '53 skills and 26' "$REPO_ROOT/.claude-plugin/plugin.json" \
  || fail ".claude-plugin/plugin.json description should contain '53 skills and 26'"
grep -Fq '53 skills and 26' "$REPO_ROOT/.codex-plugin/plugin.json" \
  || fail ".codex-plugin/plugin.json description should contain '53 skills and 26'"
grep -Fq '52 skills organized into 13 categories' "$REPO_ROOT/docs/skills.md" \
  || fail "docs/skills.md header should read '52 skills organized into 13 categories'"
grep -Fq 'Lead Generation | 1 | leads' "$REPO_ROOT/docs/skills.md" \
  || fail "docs/skills.md missing Lead Generation table row"
grep -Fxq '| **Total** | **52** | |' "$REPO_ROOT/docs/skills.md" \
  || fail "docs/skills.md Total row should show 52"

echo "PASS"
exit 0
