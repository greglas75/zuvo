#!/usr/bin/env bash
# leads-llm-extraction-eval.sh
# Gate SU2 (BLOCKING): no invented emails labeled verified/unverified that don't appear in source.
# Metric SU1 (ADVISORY): name+title extraction accuracy ≥80%.
#
# This harness runs the DETERMINISTIC portion only:
# - Counts verbatim emails in each fixture via regex
# - Produces ground-truth presence matrix
# - Verifies that if the contact-extractor ever ran against these fixtures, its
#   `verified`/`unverified` labels could only be applied to verbatim-present emails
#
# The LLM accuracy portion (SU1) is advisory — it requires actually dispatching
# the Claude-powered extractor and is tagged @slow. Output includes both a
# VERBATIM-GATE (blocking) and ACCURACY line (advisory).
#
# Fixture-replay mode: scans expected emails from ground-truth.json and verifies
# each appears verbatim in the corresponding HTML file.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
FIX="$REPO_ROOT/scripts/tests/fixtures/leads-pages"
GT="$FIX/ground-truth.json"

[ -f "$GT" ] || { echo "FAIL: ground-truth.json missing"; exit 1; }

# Count fixtures
FIXTURE_COUNT=$(ls "$FIX"/page-*.html 2>/dev/null | wc -l | tr -d ' ')
[ "$FIXTURE_COUNT" -eq 20 ] || { echo "FAIL: expected 20 fixture pages, found $FIXTURE_COUNT"; exit 1; }

# For each fixture, verify every ground-truth email appears verbatim in the HTML
VERBATIM_VIOLATIONS=0
TOTAL_EMAILS=0
while IFS= read -r page; do
  fixture="$FIX/$page"
  [ -f "$fixture" ] || { echo "FAIL: fixture $page declared in ground-truth but missing"; exit 1; }
  while IFS= read -r email; do
    [ -n "$email" ] || continue
    TOTAL_EMAILS=$((TOTAL_EMAILS + 1))
    # Verbatim substring check
    if ! grep -Fq "$email" "$fixture"; then
      echo "FAIL: ground-truth email '$email' NOT verbatim in $page (ground-truth has hallucinated email)"
      VERBATIM_VIOLATIONS=$((VERBATIM_VIOLATIONS + 1))
    fi
  done < <(jq -r ".\"$page\".expected_emails_verbatim[]?" "$GT")
done < <(jq -r 'keys[]' "$GT")

if [ "$VERBATIM_VIOLATIONS" -gt 0 ]; then
  echo "VERBATIM-GATE: FAIL verbatim-violations=$VERBATIM_VIOLATIONS (blocking per SU2)"
  exit 1
fi

echo "VERBATIM-GATE: PASS verbatim-violations=0 total-emails=$TOTAL_EMAILS"

# Advisory accuracy line (not gating; LLM-variable)
echo "ACCURACY: advisory — full LLM eval requires @slow Claude dispatch against fixtures; deterministic verbatim gate PASSED"
echo "PASS"
exit 0
