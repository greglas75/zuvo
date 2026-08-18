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

# THE REAL FUNCTION, sourced — not a re-implementation (B-PATH-CONTAIN-SHARED-FN).
#
# This block used to be a local `contained()` "extracted verbatim in shape from the lib". A copy of
# the rule cannot catch the rule drifting: d568825 fixed two of the three production copies and
# missed the third, and this test stayed green through it, because it was asserting against its own
# fourth copy. The rule now lives in hooks/lib/path-contain.sh and is sourced here; the end-to-end
# do_sync case at the bottom stays, because sourcing proves the FUNCTION and only the real script
# proves the CALL SITE.
# shellcheck source=/dev/null
. "$ROOT/hooks/lib/path-contain.sh" 2>/dev/null || {
  bad "hooks/lib/path-contain.sh missing or unreadable"; echo "=== RESULT ==="; echo "SOME FAILED"; exit 1
}
command -v path_contained >/dev/null 2>&1 || {
  bad "path_contained not defined after sourcing path-contain.sh"; echo "=== RESULT ==="; echo "SOME FAILED"; exit 1
}
# Fixture root for the canonical (symlink) cases below; the lexical cases do not need it to exist.
CROOT="$(mktemp -d)"
mkdir -p "$CROOT/zuvo/proofs"
printf 'p\n' > "$CROOT/zuvo/proofs/inside.txt"
ln -s /etc "$CROOT/sneaky"
trap 'rm -rf "$CROOT"' EXIT
contained() { path_contained "$CROOT" "$1"; }

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

# CANONICAL containment: a symlinked directory walks out of the repo with no `..` anywhere in the
# path, so the two lexical checks above cannot see it. This is what step 4 of the recipe was about.
if path_contained "$CROOT" "sneaky/passwd"; then
  bad "ACCEPTED a path that resolves outside the root through a SYMLINK (sneaky/passwd)"
else
  pass "rejected a symlink escape with no .. in the path"
fi
# …and it must not reject a real file that merely lives under the root.
if path_contained "$CROOT" "zuvo/proofs/inside.txt"; then
  pass "accepted an existing proof under the root (canonical check does not over-reject)"
else
  bad "canonical check rejected a legitimate existing proof"
fi
# A path that does not exist yet legitimately falls back to the lexical verdict — it cannot be read
# or copied, and rejecting it for absence would deny coverage to every not-yet-synced proof.
if path_contained "$CROOT" "zuvo/proofs/not-created-yet.txt"; then
  pass "a missing target falls back to the lexical verdict"
else
  bad "a missing (but lexically safe) target was rejected"
fi

# ALL THREE production call sites must use the shared function, not their own copy. This is the
# assertion that would have caught d568825's miss.
for site in hooks/lib/pipeline-gate-lib.sh scripts/review-artifact-sync.sh; do
  if grep -q 'path_contained' "$ROOT/$site"; then
    pass "$site calls the shared path_contained"
  else
    bad "$site does not call path_contained — the rule has been re-implemented"
  fi
done
n_inline="$(grep -c '\*/\.\./\*|\*/\.\.' "$ROOT/scripts/review-artifact-sync.sh" 2>/dev/null || true)"
[ "${n_inline:-0}" -eq 0 ] && pass "review-artifact-sync.sh has no inline containment case block left" \
  || bad "review-artifact-sync.sh still carries $n_inline inline containment case block(s)"

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
