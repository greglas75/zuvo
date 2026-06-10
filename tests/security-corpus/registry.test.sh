#!/usr/bin/env bash
# RED/regression test for the shared vuln-class registries (Tasks 2-4).
# Asserts every new finding_type exists in pentest-finding-registry.md with a
# non-null CWE and a probe_template_id, has >=1 source/sink seed (Task 3), and
# its safe_pattern ids resolve (Task 4). Tasks 3/4 extend the later assertions.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
FIND="$ROOT/shared/includes/pentest-finding-registry.md"
SINK="$ROOT/shared/includes/pentest-source-sink-registry.md"
SAFE="$ROOT/shared/includes/pentest-safe-pattern-registry.md"
fail() { echo "REGISTRY-FAIL: $1" >&2; exit 1; }

NEW_CLASSES="xxe prototype_pollution redos graphql_introspection graphql_depth_unbounded ldap_injection insecure_deserialization mass_assignment ssji jwt_weak xss_dom"

[ -f "$FIND" ] || fail "finding registry missing"

for cls in $NEW_CLASSES; do
  row="$(grep -E "^\| \`$cls\` " "$FIND" || true)"
  [ -n "$row" ] || fail "finding_type '$cls' not in finding-registry"
  # CWE must be in the CWE COLUMN (3rd), not anywhere on the row (B-seccorpus-2: column-scoped)
  cwe_col="$(printf '%s' "$row" | awk -F'|' '{print $4}')"
  printf '%s' "$cwe_col" | grep -qE "CWE-[0-9]+" || fail "$cls: missing/invalid CWE in column 3"
  echo "$row" | grep -qE "\| \`probe-[a-z0-9-]+\`|\`static-only\`" || fail "$cls: missing probe_template_id"
  # no duplicate finding_type rows (B-seccorpus-2)
  dup="$(grep -cE "^\| \`$cls\` " "$FIND")"
  [ "$dup" = 1 ] || fail "$cls: duplicate finding_type row (found $dup)"
done

# Registry lint: seed regexes must be grep -E / ERE compatible — NO PCRE-only
# negative/positive lookarounds (the recurring bug: yaml Task 3, JWT review F3).
if grep -nE '\(\?[!=]' "$SINK" "$SAFE" "$FIND" 2>/dev/null; then
  fail "PCRE-only lookaround (?!/(?=) in a seed regex — breaks grep -E/ERE. Use a lookaround-free seed + safe-pattern."
fi

echo "REGISTRY-PASS(find): all 11 new finding_types present, column-scoped CWE, no dups, no PCRE lookarounds"

# --- Task 3 seeds (skipped until source-sink rows land) ---
if [ "${REGISTRY_TEST_SEEDS:-0}" = 1 ]; then
  for cls in $NEW_CLASSES; do
    grep -q "$cls" "$SINK" || fail "$cls: no source/sink seed in source-sink-registry"
  done
  echo "REGISTRY-PASS(seeds): every new class has a sink seed"
fi

# --- Task 4 safe-patterns (skipped until safe-pattern rows land) ---
if [ "${REGISTRY_TEST_SAFE:-0}" = 1 ]; then
  for sp in SP-XML-DISABLE-DTD SP-JS-NULL-PROTO SP-RE2 SP-GQL-INTROSPECT-OFF SP-GQL-DEPTH-LIMIT SP-LDAP-ESCAPE SP-DESER-ALLOWLIST SP-DTO-ALLOWLIST SP-NO-DYNAMIC-EVAL SP-JWT-VERIFY-ALG SP-DOM-SAFE-SINK; do
    grep -q "$sp" "$SAFE" || fail "safe-pattern '$sp' not resolved in safe-pattern-registry"
  done
  echo "REGISTRY-PASS(safe): all new-class safe-pattern ids resolve"
fi
