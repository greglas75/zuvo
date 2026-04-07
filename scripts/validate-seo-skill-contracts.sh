#!/bin/bash
# Validate cross-file contract drift for the SEO skill suite.
# Coverage includes website claim drift, schema field presence, and enum vocabulary
# consistency across registries, skills, schemas, and website metadata.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

BOT_REG="$ROOT/shared/includes/seo-bot-registry.md"
PROFILE_REG="$ROOT/shared/includes/seo-page-profile-registry.md"
CHECK_REG="$ROOT/shared/includes/seo-check-registry.md"
FIX_REG="$ROOT/shared/includes/seo-fix-registry.md"
AUDIT_SCHEMA="$ROOT/shared/includes/audit-output-schema.md"
FIX_SCHEMA="$ROOT/shared/includes/fix-output-schema.md"
AUDIT_SKILL="$ROOT/skills/seo-audit/SKILL.md"
FIX_SKILL="$ROOT/skills/seo-fix/SKILL.md"
AUDIT_YAML="$ROOT/website/skills/seo-audit.yaml"
FIX_YAML="$ROOT/website/skills/seo-fix.yaml"

ERRORS=0

pass() {
  echo "OK: $1"
}

fail() {
  echo "FAIL: $1"
  ERRORS=$((ERRORS + 1))
}

require_file() {
  if [ -f "$1" ]; then
    pass "Found $(basename "$1")"
  else
    fail "Missing required file: $1"
  fi
}

expect_fixed() {
  local pattern="$1"
  local file="$2"
  local label="$3"
  if grep -Fq -- "$pattern" "$file"; then
    pass "$label"
  else
    fail "$label"
  fi
}

expect_absent() {
  local pattern="$1"
  local file="$2"
  local label="$3"
  if grep -Fq -- "$pattern" "$file"; then
    fail "$label"
  else
    pass "$label"
  fi
}

bot_count() {
  awk '/^\| `/{count++} END{print count+0}' "$BOT_REG"
}

profile_count() {
  rg -N '^### `(marketing|docs|blog|ecommerce|app-shell)`$' "$PROFILE_REG" | wc -l | tr -d ' '
}

check_count() {
  awk -F'|' '
    /^\| `/ && NF >= 10 { count++ }
    END { print count+0 }
  ' "$CHECK_REG"
}

fix_inventory_count() {
  awk -F'|' '
    /^## Fix Inventory/ { in_inventory=1; next }
    /^\*\*Audit agents:\*\*/ { in_inventory=0 }
    in_inventory && /^\| `/ { count++ }
    END { print count+0 }
  ' "$FIX_REG"
}

fixable_count() {
  awk -F'|' '
    /^## Fix Inventory/ { in_inventory=1; next }
    /^\*\*Audit agents:\*\*/ { in_inventory=0 }
    in_inventory && /^\| `/ {
      val=$4
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val == "Yes") count++
    }
    END { print count+0 }
  ' "$FIX_REG"
}

yaml_stat_value() {
  local label="$1"
  local file="$2"
  awk -v lbl="$label" '
    $0 ~ "label: " {
      in_block = index($0, lbl) > 0
      next
    }
    in_block && $1 == "value:" {
      gsub(/"/, "", $2)
      print $2
      exit
    }
  ' "$file"
}

echo "=== SEO Skill Contract Validator ==="
echo ""

for file in \
  "$BOT_REG" "$PROFILE_REG" "$CHECK_REG" "$FIX_REG" \
  "$AUDIT_SCHEMA" "$FIX_SCHEMA" "$AUDIT_SKILL" "$FIX_SKILL" \
  "$AUDIT_YAML" "$FIX_YAML"; do
  require_file "$file"
done

echo ""
echo "--- Enum Vocabulary ---"

expect_fixed 'user-proxy' "$BOT_REG" "Bot registry uses user-proxy tier vocabulary"
expect_absent 'user-assisted' "$BOT_REG" "Bot registry no longer uses deprecated user-assisted vocabulary"
expect_fixed 'user-proxy' "$AUDIT_SKILL" "seo-audit uses user-proxy tier vocabulary"
expect_absent 'user-assisted' "$AUDIT_SKILL" "seo-audit no longer uses deprecated user-assisted vocabulary"
expect_fixed 'user-proxy' "$FIX_SKILL" "seo-fix uses user-proxy tier vocabulary"
expect_absent 'user-assisted' "$FIX_SKILL" "seo-fix no longer uses deprecated user-assisted vocabulary"

echo ""
echo "--- Shared Registries ---"

BOT_COUNT="$(bot_count)"
PROFILE_COUNT="$(profile_count)"
CHECK_COUNT="$(check_count)"
FIX_TOTAL_COUNT="$(fix_inventory_count)"
FIXABLE_COUNT="$(fixable_count)"

[ "$BOT_COUNT" = "15" ] && pass "Bot registry contains 15 canonical bots" || fail "Bot registry expected 15 canonical bots, found $BOT_COUNT"
[ "$PROFILE_COUNT" = "5" ] && pass "Page profile registry contains 5 canonical profiles" || fail "Page profile registry expected 5 profiles, found $PROFILE_COUNT"
[ "$CHECK_COUNT" = "66" ] && pass "Check registry exposes 66 checks" || fail "Check registry expected 66 checks, found $CHECK_COUNT"
[ "$FIX_TOTAL_COUNT" = "15" ] && pass "Fix registry exposes 15 total contracts" || fail "Fix registry expected 15 contracts, found $FIX_TOTAL_COUNT"
[ "$FIXABLE_COUNT" = "12" ] && pass "Fix registry exposes 12 executable fix types" || fail "Fix registry expected 12 executable fix types, found $FIXABLE_COUNT"

expect_fixed "owner_agent" "$CHECK_REG" "Check registry documents owner_agent"
expect_fixed "layer" "$CHECK_REG" "Check registry documents layer"
expect_fixed "enforcement" "$CHECK_REG" "Check registry documents enforcement"
expect_fixed "evidence_mode" "$CHECK_REG" "Check registry documents evidence_mode"
expect_fixed "eta_minutes" "$FIX_REG" "Fix registry exposes eta_minutes"
expect_fixed "network_override_risk" "$FIX_REG" "Fix registry exposes network override risk"
expect_fixed "Manual checks:" "$FIX_REG" "Fix registry exposes manual verification hooks"

echo ""
echo "--- Cross-Registry Consistency ---"

CHECK_FIX_TYPES="$(
  awk -F'|' '
    /^\| `/ && NF >= 10 {
      val=$9
      gsub(/`/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val != "" && val != "null" && val != "--") print val
    }
  ' "$CHECK_REG" | sort -u
)"

INVENTORY_FIX_TYPES="$(
  awk -F'|' '
    /^## Fix Inventory/ { in_inventory=1; next }
    /^\*\*Audit agents:\*\*/ { in_inventory=0 }
    in_inventory && /^\| `/ {
      val=$2
      gsub(/`/, "", val)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", val)
      if (val != "") print val
    }
  ' "$FIX_REG" | sort -u
)"

while IFS= read -r fix_type; do
  [ -z "$fix_type" ] && continue
  if printf '%s\n' "$INVENTORY_FIX_TYPES" | grep -qx -- "$fix_type"; then
    pass "Check registry fix_type '$fix_type' exists in fix registry"
  else
    fail "Check registry fix_type '$fix_type' missing from fix registry"
  fi
done <<< "$CHECK_FIX_TYPES"

echo ""
echo "--- Schema Field Presence ---"

expect_fixed "# Audit Output Schema (v1.1)" "$AUDIT_SCHEMA" "Audit schema is v1.1"
expect_fixed "site_profile" "$AUDIT_SCHEMA" "Audit schema documents site_profile"
expect_fixed "strengths" "$AUDIT_SCHEMA" "Audit schema documents strengths"
expect_fixed "findings[].enforcement" "$AUDIT_SCHEMA" "Audit schema documents enforcement"
expect_fixed "findings[].layer" "$AUDIT_SCHEMA" "Audit schema documents layer"
expect_fixed "findings[].confidence_reason" "$AUDIT_SCHEMA" "Audit schema documents confidence_reason"
expect_fixed "findings[].eta_minutes" "$AUDIT_SCHEMA" "Audit schema documents eta_minutes"
expect_fixed "bot_matrix" "$AUDIT_SCHEMA" "Audit schema documents bot_matrix"
expect_fixed "render_diff" "$AUDIT_SCHEMA" "Audit schema documents render_diff"
expect_fixed "coverage.fixable_ratio" "$AUDIT_SCHEMA" "Audit schema documents coverage.fixable_ratio"
expect_fixed "manual_checks" "$AUDIT_SCHEMA" "Audit schema documents manual_checks"

expect_fixed "# Fix Output Schema (v1.2)" "$FIX_SCHEMA" "Fix schema is v1.2"
expect_fixed "estimated_time" "$FIX_SCHEMA" "Fix schema documents estimated_time"
expect_fixed "manual_checks" "$FIX_SCHEMA" "Fix schema documents manual_checks"
expect_fixed "policy_notes" "$FIX_SCHEMA" "Fix schema documents policy_notes"
expect_fixed "advisory_scaffolds" "$FIX_SCHEMA" "Fix schema documents advisory_scaffolds"
expect_fixed "risk_notes" "$FIX_SCHEMA" "Fix schema documents risk_notes"
expect_fixed "network_override_risk" "$FIX_SCHEMA" "Fix schema documents network_override_risk"
expect_fixed "NEEDS_PARAMS" "$FIX_SCHEMA" "Fix schema documents NEEDS_PARAMS"
expect_fixed "string or null" "$FIX_SCHEMA" "Fix schema allows nullable verification"
expect_fixed 'exit `0`' "$FIX_SCHEMA" "Fix schema ties PASS/VERIFIED to build exit 0"
expect_fixed 'artifact/endpoint' "$FIX_SCHEMA" "Fix schema documents artifact/endpoint verification semantics"

echo ""
echo "--- Skill Contracts ---"

expect_fixed '| `--quick` | Technical + Assets |' "$AUDIT_SKILL" "seo-audit routes --quick to Technical + Assets"
expect_fixed '| `--geo` | Technical + Content + Assets |' "$AUDIT_SKILL" "seo-audit routes --geo to all required owners"
expect_fixed '| `--profile <marketing|docs|blog|ecommerce|app-shell>` |' "$AUDIT_SKILL" "seo-audit documents canonical profile flag"
expect_fixed '`--content-profile auto|marketing|docs|blog|ecommerce|app-shell` | Legacy alias' "$AUDIT_SKILL" "seo-audit preserves legacy content-profile alias"
expect_fixed '| `--live-sample-bots <default|all|bot1,bot2>` |' "$AUDIT_SKILL" "seo-audit documents live bot sampling modes"
expect_fixed 'native agent dispatch is unavailable' "$AUDIT_SKILL" "seo-audit documents sequential fallback"
expect_fixed '**Strengths**' "$AUDIT_SKILL" "seo-audit report includes Strengths"
expect_fixed '**Bot Policy Matrix**' "$AUDIT_SKILL" "seo-audit report includes Bot Policy Matrix"
expect_fixed '**Source vs Render Diff**' "$AUDIT_SKILL" "seo-audit report includes Source vs Render Diff"
expect_fixed '**Content Table**' "$AUDIT_SKILL" "seo-audit report includes Content Table"
expect_fixed '**Fix Coverage Summary**' "$AUDIT_SKILL" "seo-audit report includes Fix Coverage Summary"
expect_fixed '"version": "1.1"' "$AUDIT_SKILL" "seo-audit JSON example uses v1.1"

expect_fixed 'schema-cleanup' "$FIX_SKILL" "seo-fix documents schema-cleanup"
expect_fixed 'native agent dispatch is unavailable' "$FIX_SKILL" "seo-fix documents sequential fallback"
expect_fixed 'estimated_time' "$FIX_SKILL" "seo-fix documents estimated_time"
expect_fixed 'network_override_risk' "$FIX_SKILL" "seo-fix documents network_override_risk"
expect_fixed 'manual_checks' "$FIX_SKILL" "seo-fix documents manual_checks"
expect_fixed 'policy_notes' "$FIX_SKILL" "seo-fix documents policy_notes"
expect_fixed 'advisory_scaffolds' "$FIX_SKILL" "seo-fix documents advisory_scaffolds"
expect_fixed 'NEEDS_PARAMS' "$FIX_SKILL" "seo-fix documents NEEDS_PARAMS"
expect_fixed 'Cloudflare' "$FIX_SKILL" "seo-fix documents Cloudflare review handling"
expect_fixed 'og:type' "$FIX_SKILL" "seo-fix documents og:type validation"
expect_fixed 'lastmod' "$FIX_SKILL" "seo-fix documents lastmod review logic"
expect_fixed 'Estimated effort rubric' "$FIX_SKILL" "seo-fix exposes ETA rubric"
expect_fixed 'content scaffold' "$FIX_SKILL" "seo-fix documents advisory content scaffold"
expect_fixed 'exit code != 0' "$FIX_SKILL" "seo-fix treats non-zero build exit as failure"
expect_fixed '/llms-full.txt' "$FIX_SKILL" "seo-fix documents llms-full artifact verification"
expect_fixed 'route file such as' "$FIX_SKILL" "seo-fix forbids route-file fallback when static assets exist"
expect_fixed 'verification="FAILED"' "$FIX_SKILL" "seo-fix documents failed artifact checks"
expect_fixed '"version": "1.1"' "$FIX_SKILL" "seo-fix JSON example uses v1.1"

echo ""
echo "--- Website Claim Drift ---"

[ "$(yaml_stat_value "Checks" "$AUDIT_YAML")" = "66" ] && pass "seo-audit website advertises 66 checks" || fail "seo-audit website check stat drifted from contract"
[ "$(yaml_stat_value "Bot Profiles" "$AUDIT_YAML")" = "15" ] && pass "seo-audit website advertises 15 bot profiles" || fail "seo-audit website bot stat drifted from contract"
expect_fixed '--profile <marketing|docs|blog|ecommerce|app-shell>' "$AUDIT_YAML" "seo-audit website documents canonical profile flag"
expect_fixed '--live-sample-bots <default|all|bot1,bot2>' "$AUDIT_YAML" "seo-audit website documents live bot sampling flag"
expect_fixed 'user-proxy' "$AUDIT_YAML" "seo-audit website uses user-proxy vocabulary"
expect_absent 'user-assisted' "$AUDIT_YAML" "seo-audit website no longer uses deprecated user-assisted vocabulary"
for phrase in Strengths "Bot Policy Matrix" "Source vs Render Diff" "Content Table" "Fix Coverage Summary"; do
  expect_fixed "$phrase" "$AUDIT_YAML" "seo-audit website includes '$phrase'"
done

[ "$(yaml_stat_value "Fix Types" "$FIX_YAML")" = "12" ] && pass "seo-fix website advertises 12 executable fix types" || fail "seo-fix website fix-type stat drifted from contract"
[ "$(yaml_stat_value "Verdicts" "$FIX_YAML")" = "7" ] && pass "seo-fix website advertises 7 verdict statuses" || fail "seo-fix website verdict stat drifted from contract"
expect_fixed 'estimated_time' "$FIX_YAML" "seo-fix website mentions estimated_time"
expect_fixed 'schema-cleanup' "$FIX_YAML" "seo-fix website includes schema-cleanup"
expect_fixed 'Cloudflare' "$FIX_YAML" "seo-fix website mentions Cloudflare review risk"
expect_fixed 'network_override_risk' "$FIX_YAML" "seo-fix website mentions network_override_risk"
expect_fixed 'manual_checks' "$FIX_YAML" "seo-fix website mentions manual_checks"
expect_fixed 'policy_notes' "$FIX_YAML" "seo-fix website mentions policy_notes"
expect_fixed 'advisory_scaffolds' "$FIX_YAML" "seo-fix website mentions advisory_scaffolds"
expect_fixed 'NEEDS_PARAMS' "$FIX_YAML" "seo-fix website mentions NEEDS_PARAMS"
expect_fixed '--fix-type' "$FIX_YAML" "seo-fix website documents --fix-type"
expect_fixed 'per-finding rollback' "$FIX_YAML" "seo-fix website mentions per-finding rollback"
expect_fixed 'exit `0`' "$FIX_YAML" "seo-fix website documents real build exit-code verification"
expect_fixed '/llms-full.txt' "$FIX_YAML" "seo-fix website documents llms-full artifact verification"
expect_fixed '404' "$FIX_YAML" "seo-fix website documents failed endpoint downgrade"
expect_absent '21+' "$FIX_YAML" "seo-fix website no longer overclaims 21+ fix types"
expect_absent '--category' "$FIX_YAML" "seo-fix website no longer documents deprecated --category flag"

echo ""
echo "--- Summary ---"
if [ "$ERRORS" -eq 0 ]; then
  echo "PASS: SEO suite contract is internally consistent"
  exit 0
fi

echo "FAIL: $ERRORS contract drift error(s) found"
exit 1
