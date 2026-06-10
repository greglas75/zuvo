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
  # column 3 = cwe, column 4 = probe_template_id; assert both non-empty + CWE shape
  echo "$row" | grep -qE "CWE-[0-9]+" || fail "$cls: missing/invalid CWE"
  echo "$row" | grep -qE "\| \`probe-[a-z0-9-]+\`|\`static-only\`" || fail "$cls: missing probe_template_id"
done

echo "REGISTRY-PASS(find): all 11 new finding_types present with CWE + probe_template_id"

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
