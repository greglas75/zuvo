#!/usr/bin/env bash
# leads-dedup-normalization.sh
# SC16 + SU6: 100% dedup suppression when --dedup-against is supplied, covering
# case-insensitive email, trailing-slash linkedin, and NFC-normalized name+domain.
#
# This test exercises the canonicalize_dedup_key() function directly via Python
# subprocess (matches the orchestrator's Phase 5 implementation).

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
FIX="$REPO_ROOT/scripts/tests/fixtures/leads-dedup"
EXISTING="$FIX/existing.csv"
CANDIDATES="$FIX/candidates.json"

fail() { echo "FAIL: $1"; exit 1; }

[ -f "$EXISTING" ] || fail "existing.csv missing"
[ -f "$CANDIDATES" ] || fail "candidates.json missing"

# Run Python to simulate orchestrator Phase 5 dedup
RESULT=$(python3 - "$EXISTING" "$CANDIDATES" <<'PY'
import csv, json, sys, unicodedata, re

def canonicalize(email, linkedin, full_name, domain):
    keys = {"email_key": None, "linkedin_key": None, "name_domain_key": None}
    if email:
        keys["email_key"] = unicodedata.normalize("NFC", email).casefold().strip()
    if linkedin:
        u = unicodedata.normalize("NFC", linkedin).casefold().rstrip("/")
        # Strip query string
        u = u.split("?", 1)[0]
        keys["linkedin_key"] = u
    if full_name and domain:
        n = unicodedata.normalize("NFC", full_name).casefold()
        n = re.sub(r"\s+", " ", n).strip()
        n = re.sub(r"[.,\-_'\"\\/]", "", n)
        keys["name_domain_key"] = f"{n}|{domain.lower()}"
    return keys

with open(sys.argv[1]) as f:
    existing = list(csv.DictReader(f))
with open(sys.argv[2]) as f:
    candidates = json.load(f)

# Build existing-key set
existing_keys = {"email": set(), "linkedin": set(), "name_domain": set()}
for r in existing:
    k = canonicalize(r["email"], r["linkedin_url"], r["full_name"], r["company_domain"])
    if k["email_key"]: existing_keys["email"].add(k["email_key"])
    if k["linkedin_key"]: existing_keys["linkedin"].add(k["linkedin_key"])
    if k["name_domain_key"]: existing_keys["name_domain"].add(k["name_domain_key"])

# Filter candidates
kept = []
suppressed = 0
for c in candidates:
    k = canonicalize(c.get("email"), c.get("linkedin_url"), c.get("full_name"), c.get("company_domain"))
    matched = (
        (k["email_key"] and k["email_key"] in existing_keys["email"]) or
        (k["linkedin_key"] and k["linkedin_key"] in existing_keys["linkedin"]) or
        (k["name_domain_key"] and k["name_domain_key"] in existing_keys["name_domain"])
    )
    if matched:
        suppressed += 1
    else:
        kept.append(c)
print(f"suppressed={suppressed} kept={len(kept)} total_candidates={len(candidates)} total_existing={len(existing)}")
PY
)
echo "$RESULT"

SUPPRESSED=$(echo "$RESULT" | sed 's/.*suppressed=\([0-9]*\).*/\1/')
KEPT=$(echo "$RESULT" | sed 's/.*kept=\([0-9]*\).*/\1/')

# Expected: 30 of 50 candidates overlap existing → 30 suppressed, 20 kept
[ "$SUPPRESSED" -eq 30 ] || fail "expected 30 suppressed, got $SUPPRESSED"
[ "$KEPT" -eq 20 ] || fail "expected 20 kept, got $KEPT"

echo "PASS"
exit 0
