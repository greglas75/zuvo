#!/usr/bin/env bash
# leads-source-registry-structure.sh
# Asserts shared/includes/lead-source-registry.md declares every source strategy
# expected by zuvo:leads Phase 1-3 orchestration.
#
# Exit 0 / "PASS" on success; exit 1 / "FAIL: <reason>" on first missing element.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
REG="$REPO_ROOT/shared/includes/lead-source-registry.md"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$REG" ] || fail "missing file $REG"

# Required sections — each source strategy has its own header
REQUIRED_SECTIONS=(
  "WebSearch Templates"
  "theHarvester Invocation"
  "crt.sh Endpoint"
  "GitHub REST API"
  "OSM Overpass Query Shape"
  "SMTP Probe Sequence"
  "Catch-All Detection"
  "WHOIS Lookup"
  "DNS MX Lookup"
)

for s in "${REQUIRED_SECTIONS[@]}"; do
  grep -Fq "$s" "$REG" || fail "section '$s' not declared"
done

# Specific command / URL patterns must appear literally
grep -Fq 'site:linkedin.com/in/' "$REG" || fail "LinkedIn site: query template missing"
grep -Fq 'theHarvester' "$REG" || fail "theHarvester command not documented"
grep -Fq 'crt.sh/?q=' "$REG" || fail "crt.sh endpoint URL not documented"
grep -Fq 'api.github.com' "$REG" || fail "GitHub REST API base not documented"
grep -Fq '/dev/tcp/' "$REG" || fail "bash /dev/tcp SMTP probe not documented (required per plan rev3 gemini-5 fix — NO 'nc')"

# Timeouts must be named for each long-running source
grep -Eq 'theHarvester.{0,200}90' "$REG" || fail "theHarvester 90s timeout not documented"
grep -Eq '(OSM|Overpass).{0,200}30' "$REG" || fail "OSM Overpass 30s timeout not documented"
grep -Eq 'crt\.sh.{0,200}15' "$REG" || fail "crt.sh 15s timeout not documented"
grep -Eq 'SMTP.{0,200}30' "$REG" || fail "SMTP 30s timeout not documented"

# Rate limit references
grep -Fq 'live-probe-protocol.md' "$REG" \
  || fail "live-probe-protocol.md reference missing (rate limits + robots.txt reuse)"

# GitHub rate limit info
grep -Eq 'ZUVO_GITHUB_TOKEN|60/h|5000/h' "$REG" \
  || fail "GitHub rate limit (60/h unauth, 5000/h with ZUVO_GITHUB_TOKEN) not documented"

# Must NOT scrape LinkedIn directly — safety note
grep -Eiq "(never|do not|NOT) scrape.*linkedin" "$REG" \
  || fail "LinkedIn direct-scrape prohibition not documented"

# Catch-all detection probe convention
grep -Eq 'zzz9999|random.?local.?part|known.invalid' "$REG" \
  || fail "catch-all random-local-part probe convention not documented"

echo "PASS"
exit 0
