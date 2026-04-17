#!/usr/bin/env bash
# leads-agent-contact-extractor-structure.sh
set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AGENT="$REPO_ROOT/skills/leads/agents/contact-extractor.md"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$AGENT" ] || fail "missing file $AGENT"

# Frontmatter
grep -Fq 'name: contact-extractor' "$AGENT" || fail "frontmatter name missing"
grep -Fq 'model:' "$AGENT" || fail "frontmatter model missing"
grep -q '^tools:' "$AGENT" || fail "frontmatter tools list missing"

# Required sections
grep -Fq '## Mission' "$AGENT" || fail "## Mission section missing"

# Reference obligations (CQ19)
grep -Fq 'agent-preamble.md' "$AGENT" || fail "agent-preamble reference missing"
grep -Fq 'live-probe-protocol.md' "$AGENT" || fail "live-probe-protocol reference missing (SC14 robots.txt)"
grep -Fq 'lead-source-registry.md' "$AGENT" || fail "lead-source-registry reference missing"
grep -Fq 'lead-output-schema.md' "$AGENT" || fail "lead-output-schema reference missing"

# VERBATIM-SOURCE VALIDATION — key invariant
grep -iq 'verbatim' "$AGENT" || fail "verbatim-source validation concept missing"
grep -Fq 'llm-inferred' "$AGENT" || fail "llm-inferred confidence label not documented"
grep -Eiq "(never|NOT) promoted" "$AGENT" || fail "llm-inferred never-promoted rule missing"

# User-Agent override
grep -Fq 'zuvo-leads/1.0' "$AGENT" || fail "User-Agent override to zuvo-leads/1.0 missing"

# CQ21 no-write
grep -Eiq "(do not|NOT|never) write.*file" "$AGENT" || fail "CQ21 no-write rule missing"

# Source attribution — every datapoint must carry its source
grep -Eiq "source.attribution|providers_used|source_urls" "$AGENT" \
  || fail "per-datapoint source attribution not documented"

# Bash guardrails (shared pattern with company-finder for CQ21)
grep -Eiq "(bash.guardrail|redirect.*denied|no.*> .*path|denylist)" "$AGENT" \
  || fail "Bash guardrails (no file redirection) missing"

# Four sources that contact-extractor must use
for src in webfetch theharvester crt.sh whois; do
  grep -Fiq "$src" "$AGENT" || fail "source '$src' not documented in extractor"
done

echo "PASS"
exit 0
