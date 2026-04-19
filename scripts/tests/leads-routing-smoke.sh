#!/usr/bin/env bash
# leads-routing-smoke.sh
# Verify skills/using-zuvo/SKILL.md has the zuvo:leads routing entry with trigger
# keywords and no conflicts with existing routes.

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
ROUTER="$REPO_ROOT/skills/using-zuvo/SKILL.md"

fail() { echo "FAIL: $1"; exit 1; }
[ -f "$ROUTER" ] || fail "router file missing"

# Required keywords in the leads route
REQUIRED=("lead" "prospect" "enrich" "contact" "outreach")
# The route must live on one line
ROUTE_LINE=$(grep -F '`zuvo:leads`' "$ROUTER" | head -1)
[ -n "$ROUTE_LINE" ] || fail "no route line references zuvo:leads"
for kw in "${REQUIRED[@]}"; do
  echo "$ROUTE_LINE" | grep -iq "$kw" || fail "route line missing keyword '$kw'"
done

# Banner bumped to 53
grep -Fq '53 skills' "$ROUTER" || fail "banner still shows old skill count (expected 53)"

# No conflicting lead-related keywords on another route
OTHER=$(grep -F 'lead' "$ROUTER" | grep -Fv '`zuvo:leads`' | grep -Ev 'lead time|leadership' || true)
if [ -n "$OTHER" ]; then
  echo "WARN: potential routing keyword conflict with existing lines:" >&2
  echo "$OTHER" >&2
  # Warning only — does not fail
fi

echo "PASS"
exit 0
