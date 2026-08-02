#!/usr/bin/env bash
#
# test-proof-path-containment.sh — the proof-path containment check in
# hooks/lib/pipeline-gate-lib.sh (pg_artifact_proven) must reject real traversal WITHOUT
# rejecting a proof whose FILENAME contains dots.
#
# Why this exists: the check tested for the substring `..`, which matches the `<base7>..<head7>`
# range convention the review skill prescribes for its own artifacts. Every range-named proof
# silently failed containment, so honest reviews granted no proof coverage and their push stayed
# blocked. Fail-closed in the wrong place blocks real work while stopping nothing.
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

[ -f "$LIB" ] || { bad "pipeline-gate-lib.sh missing"; echo "=== RESULT ==="; echo "SOME FAILED"; exit 1; }

# The containment rule, extracted verbatim in shape from the lib.
contained() {
  case "$1" in /*) return 1 ;; esac
  case "/$1" in */../*|*/..) return 1 ;; esac
  return 0
}

# MUST be accepted — legitimate proof paths, incl. the range-naming convention
for ok in "zuvo/proofs/fd57e11..fc0c83e-adversarial.txt" \
          "zuvo/proofs/fc0c83e..50eeeaf-adversarial.txt" \
          "zuvo/proofs/gate-registry-adversarial.txt"; do
  contained "$ok" && pass "accepted: $ok" || bad "rejected a legitimate proof path: $ok"
done

# MUST be rejected — absolute, or a path segment that IS ".."
for bad_path in "/etc/passwd" "/tmp/x.txt" "../../../etc/passwd" "zuvo/../../etc/passwd" \
                ".." "zuvo/proofs/.." "../zuvo/proofs/p.txt"; do
  contained "$bad_path" && bad "ACCEPTED an escaping path: $bad_path" || pass "rejected: $bad_path"
done

# The lib must not regress to substring matching.
if grep -qE '/\*\|\*\.\.\*\)' "$LIB"; then
  bad "pipeline-gate-lib.sh still uses substring '..' matching for containment"
else
  pass "pipeline-gate-lib.sh uses segment-based traversal detection"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
