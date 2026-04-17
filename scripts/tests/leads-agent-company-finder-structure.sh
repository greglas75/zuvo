#!/usr/bin/env bash
# leads-agent-company-finder-structure.sh
# Asserts skills/leads/agents/company-finder.md has all structural elements
# required by plan rev3 Task 3.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AGENT="$REPO_ROOT/skills/leads/agents/company-finder.md"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$AGENT" ] || fail "missing file $AGENT"

# Frontmatter requirements
grep -Fq 'name: company-finder' "$AGENT" || fail "frontmatter 'name: company-finder' missing"
grep -Fq 'model: sonnet' "$AGENT" || fail "frontmatter 'model: sonnet' missing"
grep -q '^tools:' "$AGENT" || fail "frontmatter 'tools:' list missing"

# Required prose sections
grep -Fq '## Mission' "$AGENT" || fail "## Mission section missing"

# Reads agent-preamble per convention
grep -Fq 'agent-preamble.md' "$AGENT" || fail "reference to shared/includes/agent-preamble.md missing"

# References to shared registries (CQ19 — don't inline)
grep -Fq 'lead-source-registry.md' "$AGENT" \
  || fail "reference to shared/includes/lead-source-registry.md missing (CQ19 violation risk)"
grep -Fq 'live-probe-protocol.md' "$AGENT" \
  || fail "reference to shared/includes/live-probe-protocol.md missing (SC14: robots.txt for any WebFetch)"

# Output contract fields for candidate_companies.json
for field in company_name domain country industry_tag role_context source_url; do
  grep -Fq "$field" "$AGENT" || fail "output field '$field' not declared in agent contract"
done

# CQ21 — agent MUST NOT write files; must return to orchestrator
grep -Eiq "(do not|NOT|never) write.*file" "$AGENT" \
  || fail "CQ21 rule (agent does not write files, returns to orchestrator) not documented"

# LinkedIn: search-engine indexed only, never direct scrape
grep -Fq 'site:linkedin.com/in/' "$AGENT" \
  || fail "site:linkedin.com/in/ search-only pattern not documented"

# Role passthrough (fix for gemini adversarial on plan)
grep -Fq 'role_context' "$AGENT" \
  || fail "role_context passthrough field not documented (downstream GitHub enrichment depends on it)"

echo "PASS"
exit 0
