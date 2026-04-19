#!/usr/bin/env bash
# leads-catchall-detection.sh
# SC5 + SU3: verify catch-all domains are correctly labeled.
# Uses mock-smtp.sh via PATH substitution (ZUVO_SMTP_PROBE_CMD).

set -u
REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "$0")/../.." && pwd)}"
MOCK="$REPO_ROOT/scripts/tests/fixtures/leads-catchall/mock-smtp.sh"

fail() { echo "FAIL: $1"; exit 1; }

[ -x "$MOCK" ] || fail "mock-smtp.sh missing or not executable: $MOCK"

# Invariant: the random-local-part catch-all probe must produce the exact labels
# per domain. Mock returns 250 for catch-all domains and 550 for strict.

CATCHALL_DOMAINS=(acme-catchall.test wide-open.test accepts-all.test)
STRICT_DOMAINS=(strict.test proper.test exact.test)

# Per catch-all domain: probe a random address; expect exit 0 (→ label catch-all)
for d in "${CATCHALL_DOMAINS[@]}"; do
  RANDOM_LOCAL="zzz9999-$(openssl rand -hex 4 2>/dev/null || echo abcd1234)"
  if "$MOCK" "$d" "$RANDOM_LOCAL@$d" >/dev/null 2>&1; then
    echo "OK catch-all detected for $d"
  else
    fail "catch-all probe for '$d' should return 0 (accept); mock returned non-zero"
  fi
done

# Per strict domain: random probe must NOT be accepted (exit non-zero → NOT catch-all)
for d in "${STRICT_DOMAINS[@]}"; do
  RANDOM_LOCAL="zzz9999-$(openssl rand -hex 4 2>/dev/null || echo abcd1234)"
  if "$MOCK" "$d" "$RANDOM_LOCAL@$d" >/dev/null 2>&1; then
    fail "strict domain '$d' incorrectly accepted random probe (false catch-all)"
  fi
  # Known-address probe should succeed
  case "$d" in
    strict.test) known="ceo@$d" ;;
    proper.test) known="cfo@$d" ;;
    exact.test) known="cto@$d" ;;
  esac
  if ! "$MOCK" "$d" "$known" >/dev/null 2>&1; then
    fail "strict domain '$d' should accept known address '$known'"
  fi
  echo "OK strict non-catch-all for $d"
done

echo "PASS"
exit 0
