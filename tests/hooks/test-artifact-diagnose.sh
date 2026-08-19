#!/usr/bin/env bash
# Tests pg_explain_uncovered (hooks/lib/pipeline-gate-lib.sh) and
# scripts/review-artifact-sync.sh.
#
# Contract under test: when the gate blocks, every uncovered file gets a
# distinguishable reason (proof-missing vs stale-content vs marker-missing vs
# space-separated files vs no-artifact) — because collapsing them into "no
# covering review" mis-diagnosed a real incident (2026-07-31: six data-lab
# refactor PRs read as "never reviewed" while their reviews existed with the
# proof in another checkout). The sync helper must move artifact+proof PAIRS
# and its --check must reject exactly the malformed headers the gate skips.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
SYNC="$ROOT/scripts/review-artifact-sync.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/src" "$TMP/r/memory/reviews" "$TMP/r/zuvo/proofs"; cd "$TMP/r" || exit 1
  git init -q; git config user.email t@t; git config user.name t
  echo "export const a=1" > src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm base >/dev/null
  echo "export const b=2" >> src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm work >/dev/null
  BASE=$(git rev-parse HEAD~1); HEAD=$(git rev-parse HEAD); }
proof(){ : > zuvo/proofs/adv.txt; i=0; while [ $i -lt "$1" ]; do printf '###   REVIEW BY: P%s\n' "$i" >> zuvo/proofs/adv.txt; i=$((i+1)); done; }
# shellcheck source=/dev/null
. "$LIB"
explain(){ PG_REVIEW_PROOF_CUTOFF=1 pg_explain_uncovered "${BASE}..${HEAD}"; }

echo "=== reason: proof file missing in THIS checkout (the data-lab incident) ==="
newrepo
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/GONE.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q "proof 'zuvo/proofs/GONE.txt' is NOT in this checkout" \
   && printf '%s' "$out" | grep -q 'review-artifact-sync.sh'; then
  ok "missing proof names the exact path and points at the PAIR sync, not a re-review"
else
  bad "missing proof reason: $out"
fi

echo "=== reason: stale content (file edited after review) ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q 'reviewed DIFFERENT content'; then
  ok "blob mismatch reported as stale content needing a FRESH review"
else
  bad "stale-content reason: $out"
fi

echo "=== reason: artifact lists the file but lacks the marker ==="
newrepo; proof 2
printf 'range: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q "lacks the '<!-- zuvo-review -->' marker"; then
  ok "marker-less artifact surfaced as a malformed header, not as 'never reviewed'"
else
  bad "marker-missing reason: $out"
fi

echo "=== reason: space-separated files list (comma parser can never match) ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts src/other.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if printf '%s' "$out" | grep -q 'SPACE-separated'; then
  ok "space-separated files: list diagnosed by name"
else
  bad "space-separated reason: $out"
fi

echo "=== reason: nothing lists the file at all ==="
newrepo
out="$(explain)"
if printf '%s' "$out" | grep -q 'no artifact in memory/reviews/ lists this file'; then
  ok "genuinely-unreviewed content says so"
else
  bad "no-artifact reason: $out"
fi

echo "=== covered file prints NOTHING (no noise on the happy path) ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/a.md
touch memory/reviews/a.md
out="$(explain)"
if [ -z "$out" ]; then
  ok "fully covered range produces no explain output"
else
  bad "covered range still printed: $out"
fi

echo "=== sync: artifact + referenced proof travel as a PAIR ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/pair-slug.md
mkdir -p "$TMP/dst"; ( cd "$TMP/dst" && git init -q && git config user.email t@t && git config user.name t \
  && git -c commit.gpgsign=false commit -q --allow-empty -m init )
if bash "$SYNC" --from "$TMP/r" --to "$TMP/dst" --slug pair-slug >/dev/null 2>&1 \
   && [ -f "$TMP/dst/memory/reviews/pair-slug.md" ] && [ -f "$TMP/dst/zuvo/proofs/adv.txt" ]; then
  ok "sync copies both the artifact and its proof"
else
  bad "pair sync failed or left the proof behind"
fi

echo "=== sync: refuses to clobber a DIFFERENT existing file ==="
printf 'other content\n' > "$TMP/dst/memory/reviews/pair-slug.md"
if bash "$SYNC" --from "$TMP/r" --to "$TMP/dst" --slug pair-slug >/dev/null 2>&1; then
  bad "sync overwrote (or ignored) a conflicting destination artifact"
else
  grep -q 'other content' "$TMP/dst/memory/reviews/pair-slug.md" \
    && ok "conflicting destination file left untouched, non-zero exit" \
    || bad "conflicting file was clobbered"
fi

echo "=== check: lints the malformed headers the gate silently skips ==="
newrepo; proof 2
printf 'range: %s..%s\nfiles: src/mod.ts\n' "$BASE" "$HEAD" > memory/reviews/nomarker.md
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts src/x.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/spaces.md
out="$(bash "$SYNC" --check "$TMP/r" 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'nomarker.md: missing' \
   && printf '%s' "$out" | grep -q 'spaces.md: files: is SPACE-separated'; then
  ok "--check fails loudly on marker-less and space-separated artifacts"
else
  bad "--check lint (rc=$rc): $out"
fi

echo "=== check --slug: lints only the matching artifact; empty match FAILs ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/current-run.md
printf 'range: broken\n' > memory/reviews/old-broken.md
out="$(bash "$SYNC" --check "$TMP/r" --slug current-run 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'current-run.md' \
   && ! printf '%s' "$out" | grep -q 'old-broken.md'; then
  ok "--slug scopes the lint to the current run's artifact (historical FAILs invisible)"
else
  bad "--check --slug scoping (rc=$rc): $out"
fi
out="$(bash "$SYNC" --check "$TMP/r" --slug no-such-slug 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "no artifact matching"; then
  ok "a slug matching nothing FAILs loudly (typo'd slug is never a silent pass)"
else
  bad "empty-slug-match FAIL (rc=$rc): $out"
fi

echo "=== check: a healthy pair passes ==="
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/good.md
out="$(bash "$SYNC" --check "$TMP/r" 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'OK   memory/reviews/good.md'; then
  ok "--check passes a complete artifact+proof pair"
else
  bad "--check healthy pair (rc=$rc): $out"
fi

echo "=== PRECEDENCE: a malformed FRESH artifact must not be masked by a stale OLD one ==="
# The field failure (2026-08-06, reported after three wasted cycles): the operator
# was told "a fresh review is needed" for a review that had JUST been written. Every
# reason was already distinguishable in isolation — which is why the existing cases
# above all passed — but the RANKING preferred stale over malformed. memory/reviews/
# accumulates, so any previously-reviewed file has an older artifact listing it with
# different content; that stale reason masked the malformed header on the artifact
# the run had just produced. Re-reviewing wrote another malformed artifact and
# reproduced the identical message, forever.
#
# The rule this pins: a reason RE-REVIEWING REPAIRS (stale) must never outrank one
# it reproduces (missing marker, space-separated files:). Both artifacts present is
# the normal state, not a corner case, so isolation tests cannot catch this.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/old.md
printf 'range: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/fresh.md
out="$(explain)"
if printf '%s' "$out" | grep -q "lacks the '<!-- zuvo-review -->' marker"; then
  ok "marker-missing on the fresh artifact wins over stale-content on the old one"
else
  bad "stale masked the actionable marker reason: $out"
fi

newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/old.md
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts other.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$HEAD" > memory/reviews/fresh.md
out="$(explain)"
if printf '%s' "$out" | grep -q "SPACE-separated"; then
  ok "space-separated on the fresh artifact wins over stale-content on the old one"
else
  bad "stale masked the actionable separator reason: $out"
fi

# The inverse must still hold: with no malformed artifact, stale is the right answer.
newrepo; proof 2
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/mod.ts\nadversarial: zuvo/proofs/adv.txt\n' "$BASE" "$BASE" > memory/reviews/old.md
out="$(explain)"
if printf '%s' "$out" | grep -q "a fresh review is needed"; then
  ok "stale-content still reported when nothing is malformed (no regression)"
else
  bad "stale-content lost: $out"
fi

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
