#!/usr/bin/env bash
# test-infra-wiring.sh — Task 10 RED: assert atomic wiring for zuvo:infra-audit
# Verifies: router row, banner count, severity-vocabulary row,
#           report-output-location writers list, install.sh cp lines,
#           and that ALL skill-count integers equal `ls skills/ | wc -l`.
set -u

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"

pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; exit 1; }

ROUTER="$REPO_ROOT/skills/using-zuvo/SKILL.md"
SEVVOC="$REPO_ROOT/shared/includes/severity-vocabulary.md"
OUTLOC="$REPO_ROOT/shared/includes/report-output-location.md"
INSTALL="$REPO_ROOT/scripts/install.sh"
CLAUDE_JSON="$REPO_ROOT/.claude-plugin/plugin.json"
CODEX_JSON="$REPO_ROOT/.codex-plugin/plugin.json"
PKG_JSON="$REPO_ROOT/package.json"
SKILLS_MD="$REPO_ROOT/docs/skills.md"

# Ground truth: actual directory count
ACTUAL=$(ls "$REPO_ROOT/skills/" | wc -l | tr -d ' ')
echo "Actual skill dirs: $ACTUAL"

# ── 1. Router: routing row for zuvo:infra-audit ───────────────────────────────
[ -f "$ROUTER" ] || fail "router file missing"
grep -q 'zuvo:infra-audit' "$ROUTER" \
  || fail "skills/using-zuvo/SKILL.md: missing routing row for zuvo:infra-audit"
pass "router has zuvo:infra-audit routing row"

# ── 2. Router: banner contains "54 skills" ───────────────────────────────────
grep -q '54 skills' "$ROUTER" \
  || fail "skills/using-zuvo/SKILL.md: banner does not contain '54 skills'"
pass "router banner contains '54 skills'"

# ── 3. severity-vocabulary: infra-audit row with CRITICAL/HIGH/MEDIUM/LOW→S1/S2/S3/S4 ──
[ -f "$SEVVOC" ] || fail "severity-vocabulary.md missing"
grep -q 'infra-audit' "$SEVVOC" \
  || fail "severity-vocabulary.md: missing infra-audit row"
# Verify CRITICAL/HIGH/MEDIUM/LOW mapping (same shape as security-audit row)
INFRA_ROW=$(grep 'infra-audit' "$SEVVOC" | head -1)
echo "$INFRA_ROW" | grep -q 'CRITICAL' \
  || fail "infra-audit row missing CRITICAL"
echo "$INFRA_ROW" | grep -q 'HIGH' \
  || fail "infra-audit row missing HIGH"
echo "$INFRA_ROW" | grep -q 'MEDIUM' \
  || fail "infra-audit row missing MEDIUM"
echo "$INFRA_ROW" | grep -q 'LOW' \
  || fail "infra-audit row missing LOW"
pass "severity-vocabulary.md has infra-audit row with CRITICAL/HIGH/MEDIUM/LOW mapping"

# ── 4. report-output-location: audits/ writers line contains infra-audit ─────
[ -f "$OUTLOC" ] || fail "report-output-location.md missing"
grep 'audits/' "$OUTLOC" | grep -q 'infra-audit' \
  || fail "report-output-location.md: audits/ writers line missing 'infra-audit'"
pass "report-output-location.md audits/ writers line contains infra-audit"

# ── 5. install.sh: infra-collect.sh in Codex cp block ───────────────────────
[ -f "$INSTALL" ] || fail "install.sh missing"
# The Codex block (around line 558-561) must have infra-collect.sh
# Strategy: check that infra-collect.sh appears in a .codex/scripts/ cp line
grep -q 'infra-collect\.sh.*\.codex.*scripts\|\.codex.*scripts.*infra-collect\.sh' "$INSTALL" \
  || fail "install.sh: infra-collect.sh not found in Codex cp block (.codex/scripts/)"
pass "install.sh has infra-collect.sh in Codex cp block"

# ── 6. install.sh: infra-collect.sh in Cursor cp block ──────────────────────
grep -q 'infra-collect\.sh.*\.cursor.*scripts\|\.cursor.*scripts.*infra-collect\.sh' "$INSTALL" \
  || fail "install.sh: infra-collect.sh not found in Cursor cp block (.cursor/scripts/)"
pass "install.sh has infra-collect.sh in Cursor cp block"

# ── 7-12. Skill count integers — all must equal ACTUAL ───────────────────────

extract_count() {
  # Extract the first integer from a description/count field in a file
  # Usage: extract_count <file> <pattern>
  grep "$1" "$2" | grep -oE '[0-9]+' | head -1
}

PASS_COUNT=0
FAIL_COUNT=0

check_count() {
  local label="$1"
  local got="$2"
  if [ "$got" = "$ACTUAL" ]; then
    echo "PASS: $label = $got (matches actual)"
    PASS_COUNT=$((PASS_COUNT + 1))
  else
    echo "FAIL: $label = $got (expected $ACTUAL)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
  fi
}

# .claude-plugin/plugin.json — first integer in description
CLAUDE_COUNT=$(grep '"description"' "$CLAUDE_JSON" | grep -oE '[0-9]+' | head -1)
check_count ".claude-plugin/plugin.json" "$CLAUDE_COUNT"

# .codex-plugin/plugin.json — first integer in description
CODEX_COUNT=$(grep '"description"' "$CODEX_JSON" | grep -oE '[0-9]+' | head -1)
check_count ".codex-plugin/plugin.json" "$CODEX_COUNT"

# package.json — first integer in description
PKG_COUNT=$(grep '"description"' "$PKG_JSON" | grep -oE '[0-9]+' | head -1)
check_count "package.json" "$PKG_COUNT"

# docs/skills.md — header line (e.g. "Zuvo includes 52 skills organized into 13 categories")
SKILLS_HDR_COUNT=$(grep 'skills organized into' "$SKILLS_MD" | grep -oE '[0-9]+' | head -1)
check_count "docs/skills.md (header line)" "$SKILLS_HDR_COUNT"

# docs/skills.md — Total row (e.g. "| **Total** | **52** | |")
SKILLS_TOT_COUNT=$(grep '^\| \*\*Total\*\*' "$SKILLS_MD" | grep -oE '[0-9]+' | head -1)
check_count "docs/skills.md (Total row)" "$SKILLS_TOT_COUNT"

# using-zuvo banner — extract the integer immediately preceding " skills"
BANNER_COUNT=$(grep -E '[0-9]+ skills' "$ROUTER" | head -1 | grep -oE '[0-9]+ skills' | grep -oE '^[0-9]+')
check_count "using-zuvo banner" "$BANNER_COUNT"

echo ""
echo "counts: $PASS_COUNT/$((PASS_COUNT + FAIL_COUNT)) equal to $ACTUAL"

[ $FAIL_COUNT -eq 0 ] || exit 1

echo ""
echo "ALL PASS"
exit 0
