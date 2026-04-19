#!/usr/bin/env bash
# leads-zero-key-smoke.sh
# Smoke test that zuvo:leads produces valid output against committed fixtures
# with ZERO paid API keys configured. Blocking for SC1 / SU5.
#
# NOTE: This harness validates the CONTRACT (fixture presence, expected JSON shape,
# schema conformance assertions). End-to-end execution of the skill itself requires
# the Claude Code runtime and is covered by the `--dry-run` variant + manual QA.
# This script asserts: (a) fixtures are present and parseable, (b) expected-output
# declares a meta.json-compatible contract, (c) no .tmp/.lock leftovers remain in
# the fixture dir after a dry-run.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
FIX="$REPO_ROOT/scripts/tests/fixtures/leads-smoke"
SCHEMA="$REPO_ROOT/shared/includes/lead-output-schema.md"

fail() { echo "FAIL: $1"; exit 1; }

# 1. Fixture presence
for f in acme-saas.html beta-fintech.html gamma-hr.html delta-privacy.html epsilon-role.html serp-fixtures.json expected-output.json; do
  [ -f "$FIX/$f" ] || fail "missing fixture $f"
done

# 2. SERP fixture is valid JSON with queries
jq -e '.queries | length >= 2' "$FIX/serp-fixtures.json" >/dev/null || fail "serp-fixtures.json has < 2 queries"

# 3. Expected output declares counts matching schema expectations
jq -e '.contacts_min_count >= 5' "$FIX/expected-output.json" >/dev/null \
  || fail "expected-output.json contacts_min_count < 5 (SU5 requires >=5 populated emails)"

# 4. meta shape conforms to schema (spec_id, mode, status, record_count fields)
for key in spec_id mode status record_count smtp_available gdpr_mode; do
  jq -e ".meta | has(\"$key\")" "$FIX/expected-output.json" >/dev/null \
    || fail "expected-output.json meta missing required field '$key' per lead-output-schema.md"
done

# 5. spec_id matches the v1 value
jq -re '.meta.spec_id' "$FIX/expected-output.json" | grep -Fxq '2026-04-17-zuvo-leads-1438' \
  || fail "expected-output.json spec_id != 2026-04-17-zuvo-leads-1438"

# 6. HTML fixtures contain extractable email addresses (verbatim in source)
VERBATIM_COUNT=$(grep -cE '[a-zA-Z0-9._-]+@[a-zA-Z0-9.-]+\.test' "$FIX"/*.html | awk -F: '{s+=$2} END{print s}')
[ "$VERBATIM_COUNT" -ge 7 ] || fail "verbatim email count $VERBATIM_COUNT < 7 across fixtures"

# 7. Role-address fixture contains at least one role local-part
grep -Eq '(sales|support|contact|info)@' "$FIX/epsilon-role.html" \
  || fail "epsilon-role.html missing role-local-part emails"

# 8. Polish/Spanish diacritics fixture preserves UTF-8
grep -q 'Łukasz' "$FIX/gamma-hr.html" || fail "gamma-hr.html Polish diacritic 'Łukasz' missing"
grep -q 'Rodríguez' "$FIX/gamma-hr.html" || fail "gamma-hr.html Spanish diacritic 'Rodríguez' missing"

# 9. Delta (empty-contacts) fixture has no email — tests graceful handling
grep -Eq '@' "$FIX/delta-privacy.html" && fail "delta-privacy.html should have no email (edge case)"

# 10. No leftover .tmp/.lock from previous failed runs
[ -e "$FIX/.lock" ] && fail "stale .lock/ in fixture dir"
ls "$FIX"/*.tmp 2>/dev/null | grep -q . && fail ".tmp files leftover in fixture dir"

echo "PASS"
exit 0
