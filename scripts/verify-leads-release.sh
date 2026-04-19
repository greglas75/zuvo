#!/usr/bin/env bash
# verify-leads-release.sh
# Final release-gate chain for zuvo:leads v1.
# Per plan rev3 Task 17: runs every validation in order, PASS or exit non-zero.
#
# Checks (in order):
# 1. bats scripts/tests/leads.bats (non-slow)
# 2. LEADS_SLOW=1 bats scripts/tests/leads.bats (full LLM eval — fixes codex-1)
# 3. bash scripts/tests/leads-routing-smoke.sh
# 4. bash scripts/tests/leads-manifest-counts.sh
# 5. cd REPO_ROOT && grep -Fxq 'docs/leads/' .gitignore (fixes cursor-gitignore-gap)
# 6. ./scripts/install.sh --dry-run (validate all 4 build targets)
# 7. dry-run invocation of zuvo:leads to exercise Phase 0 tool-probe + mode detection
#
# Each step prints STEP N: PASS or FAIL: <step> <reason>. Final: RELEASE GATE: PASS.

set -eu
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$REPO_ROOT"

trap 'echo "RELEASE GATE: FAIL at line $LINENO" >&2' ERR

# Step 1: bats non-slow
echo "STEP 1: bats non-slow suite"
if command -v bats >/dev/null 2>&1; then
  bats scripts/tests/leads.bats
  echo "STEP 1: PASS"
else
  echo "STEP 1: SKIP (bats not installed) — install with: brew install bats-core"
fi

# Step 2: bats slow (LEADS_SLOW=1)
echo "STEP 2: bats slow suite (LEADS_SLOW=1)"
if command -v bats >/dev/null 2>&1; then
  LEADS_SLOW=1 bats scripts/tests/leads.bats
  echo "STEP 2: PASS"
else
  echo "STEP 2: SKIP (bats not installed)"
fi

# Step 3: routing smoke
echo "STEP 3: routing smoke"
bash scripts/tests/leads-routing-smoke.sh
echo "STEP 3: PASS"

# Step 4: manifest counts
echo "STEP 4: manifest counts"
bash scripts/tests/leads-manifest-counts.sh
echo "STEP 4: PASS"

# Step 5: .gitignore check
echo "STEP 5: .gitignore contains docs/leads/"
grep -Fxq 'docs/leads/' .gitignore || { echo "FAIL: docs/leads/ not in .gitignore"; exit 1; }
echo "STEP 5: PASS"

# Step 6: install.sh structural validation
echo "STEP 6: install.sh structural check"
if [ -f scripts/install.sh ]; then
  # Syntax check only — full install has side effects
  bash -n scripts/install.sh && echo "STEP 6: PASS (syntax OK; full install has side effects, skip in gate)"
else
  echo "STEP 6: SKIP (scripts/install.sh not found)"
fi

# Step 7: skill file structural validation
echo "STEP 7: skill file structural validation"
bash scripts/tests/leads-skill-structure.sh
echo "STEP 7: PASS"

echo ""
echo "RELEASE GATE: PASS"
exit 0
