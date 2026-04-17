#!/usr/bin/env bash
set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
AGENT="$REPO_ROOT/skills/leads/agents/lead-validator.md"
fail() { echo "FAIL: $1"; exit 1; }

[ -f "$AGENT" ] || fail "missing file $AGENT"

# Frontmatter
grep -Fq 'name: lead-validator' "$AGENT" || fail "frontmatter name missing"
grep -q '^tools:' "$AGENT" || fail "frontmatter tools missing"

# Required references (CQ19)
grep -Fq 'agent-preamble.md' "$AGENT" || fail "agent-preamble reference missing"
grep -Fq 'lead-output-schema.md' "$AGENT" || fail "lead-output-schema reference missing"

# BLIND: receives only candidates + rules, no orchestrator state
grep -Eiq 'blind|no orchestrator state|no cross-contamination' "$AGENT" \
  || fail "blind-audit property not documented"

# Core rule: labels dedup keys, does NOT deduplicate
grep -Eiq "LABEL|label.*dedup" "$AGENT" || fail "labeling behavior not documented"
grep -Eiq "does NOT dedup|NOT deduplicate|orchestrator.*dedup" "$AGENT" \
  || fail "explicit 'validator does NOT dedup' rule missing"

# 3 dedup keys from schema
for key in raw_key_email raw_key_linkedin raw_key_name_domain; do
  grep -Fq "$key" "$AGENT" || fail "dedup key field '$key' missing"
done

# Quarantine
grep -Fq 'quarantine_reason' "$AGENT" || fail "quarantine_reason field missing"
grep -Fq 'domain-mismatch' "$AGENT" || fail "domain-mismatch quarantine reason missing"

# gdpr_flag with source (individual vs company-fallback)
grep -Fq 'gdpr_flag' "$AGENT" || fail "gdpr_flag labeling missing"
grep -Fq 'gdpr_flag_source' "$AGENT" || fail "gdpr_flag_source (individual/company-fallback) missing"

# Role-address detection
grep -Eq 'role-address|info@|sales@' "$AGENT" || fail "role-address detection pattern missing"

# CQ21 — does NOT strip phones (orchestrator does)
grep -Eiq "(does not|NOT) strip phones?" "$AGENT" \
  || fail "explicit 'does not strip phones' rule missing"

# CQ21 — does NOT write files
grep -Eiq "(do not|NOT|never) write.*file" "$AGENT" || fail "CQ21 no-write rule missing"

echo "PASS"
exit 0
