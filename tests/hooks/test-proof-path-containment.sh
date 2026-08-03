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

# --- do_sync end-to-end (the copy actually runs; the reimplementation above does not) ---
#
# The rule lived in THREE places and only two were fixed: review-artifact-sync.sh's
# do_sync() kept `case "$ref"` (unprefixed), so `../x` matched neither `*/../*` nor
# `*/..`, fell to the default branch, and was copied OUTSIDE the destination repo.
# `../../x` still matched, which is why a two-segment case hides it. The contained()
# helper above is a re-implementation — it cannot catch a drift in do_sync's own case
# block, so this exercises the real script.
SYNC="$ROOT/scripts/review-artifact-sync.sh"
if [ -x "$SYNC" ] || [ -f "$SYNC" ]; then
  sbox="$(mktemp -d)" || { bad "mktemp failed"; sbox=""; }
  if [ -n "$sbox" ] && [ -d "$sbox" ]; then
    mkdir -p "$sbox/src/memory/reviews" "$sbox/nested/dst/memory/reviews"
    (cd "$sbox/src" && git init -q . 2>/dev/null) || true
    (cd "$sbox/nested/dst" && git init -q . 2>/dev/null) || true
    printf 'SECRET-CANARY\n' > "$sbox/outside-secret.txt"
    cat > "$sbox/src/memory/reviews/aaaaaaa..bbbbbbb-t.md" <<'ART'
<!-- zuvo-review -->
range: aaaaaaa..bbbbbbb
files: *
adversarial: ../outside-secret.txt
REVIEW BY: a
REVIEW BY: b
ART
    sync_out="$(bash "$SYNC" --from "$sbox/src" --to "$sbox/nested/dst" 2>&1)"
    # POSITIVE control FIRST. Asserting only "the secret was not copied" passes
    # trivially when the sync errored out or did nothing at all — a test that
    # cannot fail, which is the exact class this whole release is about. So first
    # prove the run actually did its job, then prove what it refused.
    if [ ! -f "$sbox/nested/dst/memory/reviews/aaaaaaa..bbbbbbb-t.md" ]; then
      bad "do_sync did not copy the artifact — the traversal assertion below would be vacuous. Output: $sync_out"
    elif [ -e "$sbox/nested/outside-secret.txt" ]; then
      bad "do_sync copied a ../ proof path OUTSIDE the destination repo (traversal reopened)"
    elif ! printf '%s' "$sync_out" | grep -q "escapes the repo"; then
      bad "do_sync neither copied nor reported the escaping proof path — silent drop. Output: $sync_out"
    else
      pass "do_sync copies the artifact, refuses the '../' proof, and says so"
    fi
    rm -rf "$sbox"
  fi
else
  pass "review-artifact-sync.sh absent — do_sync case skipped"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
