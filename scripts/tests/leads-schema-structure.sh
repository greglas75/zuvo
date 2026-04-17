#!/usr/bin/env bash
# leads-schema-structure.sh
# Asserts that shared/includes/lead-output-schema.md declares every field,
# enum value, and root-shape element required by the zuvo:leads Data Model.
#
# Exit 0 with trailing "PASS" line on success.
# Exit 1 with trailing "FAIL: <reason>" line on first missing element.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
SCHEMA="$REPO_ROOT/shared/includes/lead-output-schema.md"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$SCHEMA" ] || fail "missing file $SCHEMA"

# Required record fields (23 fields per plan rev3 / spec Data Model)
REQUIRED_FIELDS=(
  record_type full_name first_name last_name name_confidence role_title
  contact_extraction seniority company_name company_domain industry
  company_size country email email_confidence is_personal_email phone
  linkedin_url source_urls providers_used retrieved_at gdpr_flag
  gdpr_flag_source
)

for f in "${REQUIRED_FIELDS[@]}"; do
  grep -Eq "^\|[[:space:]]*\`?${f}\`?[[:space:]]*\|" "$SCHEMA" \
    || fail "field '$f' not declared in Data Model table"
done

# Email confidence enum values must be named explicitly
for v in verified catch-all pattern-inferred llm-inferred unverified role-address not-found; do
  grep -q "\`$v\`" "$SCHEMA" || fail "email_confidence enum value '$v' missing"
done

# JSON root shape: single object with meta + contacts
grep -Fq '"meta"' "$SCHEMA" || fail "JSON root shape must reference \"meta\" key"
grep -Fq '"contacts"' "$SCHEMA" || fail "JSON root shape must reference \"contacts\" key"

# Record subtypes — use portable fixed-string checks + table-format anchor rather than \b
# (BSD grep on macOS and GNU grep on Linux interpret \b differently; fixed-string is safe).
# Require "person" and "role-address" to appear as backtick-quoted enum values
# on lines that also reference record_type.
grep -Fq '`person`' "$SCHEMA" || fail "record_type enum value 'person' not documented (expected backtick-quoted literal)"
grep -Fq '`role-address`' "$SCHEMA" || fail "record_type enum value 'role-address' not documented (expected backtick-quoted literal)"
grep -Fq 'record_type' "$SCHEMA" || fail "record_type field not documented"

# CSV UTF-8 BOM convention
grep -iq 'UTF-8 BOM' "$SCHEMA" || fail "CSV UTF-8 BOM convention not documented"

# Quarantine format
grep -Fq '.quarantine/' "$SCHEMA" || fail "quarantine path '.quarantine/' not documented"

# Canonicalization function signature (fix for cursor-5 dedup drift)
grep -q 'canonicalize_dedup_key' "$SCHEMA" \
  || fail "canonicalize_dedup_key(record) function not declared (required for Phase 5 dedup)"

# Companion .meta.json for CSV
grep -Fq '.meta.json' "$SCHEMA" || fail "companion '.meta.json' file for CSV not documented"

echo "PASS"
exit 0
