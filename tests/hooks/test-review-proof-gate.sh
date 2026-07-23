#!/usr/bin/env bash
# Tests pg_artifact_proven + its effect on pg_range_reviewed (hooks/lib/pipeline-gate-lib.sh).
#
# The content-key proves an artifact is FRESH, not that a review HAPPENED: a fabricated
# artifact (range: base..HEAD, files: *, marker, zero review) covers trivially because its
# head IS the push head. This gate requires a NEW artifact to cite a real cross-model
# adversarial run. Enforced forward-only (mtime >= cutoff); legacy artifacts grandfathered.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

newrepo(){ rm -rf "$TMP/r"; mkdir -p "$TMP/r/src" "$TMP/r/memory/reviews" "$TMP/r/zuvo/proofs"; cd "$TMP/r"
  git init -q; git config user.email t@t; git config user.name t
  echo "export const a=1" > src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm base >/dev/null
  echo "export const b=2" >> src/mod.ts; git add -A; git -c commit.gpgsign=false commit -qm work >/dev/null
  BASE=$(git rev-parse HEAD~1); HEAD=$(git rev-parse HEAD); }
art(){ printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: *\n%s\n' "$BASE" "$HEAD" "${1:-}" > memory/reviews/a.md; }
proof(){ : > zuvo/proofs/adv.txt; i=0; while [ $i -lt "$1" ]; do printf '###   REVIEW BY: P%s\n' "$i" >> zuvo/proofs/adv.txt; i=$((i+1)); done; }
# shellcheck source=/dev/null
. "$LIB"
cov(){ pg_range_reviewed "${BASE}..${HEAD}"; echo $?; }

echo "=== the fabrication path is now blocked ==="
newrepo; art; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "fabricated files:* artifact (no proof) does NOT cover" || bad "fabrication still covers"

echo "=== a real cross-model run covers ==="
newrepo; proof 2; art "adversarial: zuvo/proofs/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 0 ] && ok "artifact citing a >=2-provider run covers" || bad "real proof rejected"

echo "=== proof strength ==="
newrepo; proof 1; art "adversarial: zuvo/proofs/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "single provider, no honest marker -> not proven" || bad "1-provider file accepted blindly"
newrepo; proof 1; printf 'single provider only\n' >> zuvo/proofs/adv.txt
art "adversarial: zuvo/proofs/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 0 ] && ok "1 provider + honest single-provider note -> proven" || bad "honest degraded rejected"
newrepo; art "adversarial: single_provider_only"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "bare single_provider_only literal (no file) -> NOT proven (no type-the-magic-words bypass)" || bad "bare literal granted coverage"

echo "=== proof reference must resolve ==="
newrepo; art "adversarial: zuvo/proofs/GONE.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "dangling proof path -> not proven" || bad "missing proof file accepted"
newrepo; proof 2; art "adv-proof: zuvo/proofs/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 0 ] && ok "adv-proof: alias accepted" || bad "adv-proof alias not read"

echo "=== grandfather: nothing already on disk is disrupted ==="
newrepo; art; touch -t 202601010000 memory/reviews/a.md
[ "$(cov)" -eq 0 ] && ok "pre-cutoff artifact (default cutoff) still covers, no proof needed" || bad "legacy artifact false-blocked"
newrepo; art; touch memory/reviews/a.md
[ "$(cov)" -eq 1 ] && ok "post-cutoff artifact (default cutoff) needs proof" || bad "post-cutoff proofless covered"

echo "=== path traversal / absolute proof paths rejected ==="
newrepo; proof 2; art "adversarial: ../../../etc/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "../ traversal in proof path rejected" || bad "traversal accepted"
newrepo; proof 2; art "adversarial: /etc/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "absolute proof path rejected" || bad "absolute path accepted"

echo "=== CI degrade: absent proof falls back to content-key ONLY under PG_PROOF_OPTIONAL ==="
# Proof files (zuvo/proofs/) are gitignored, so a CI checkout has the committed artifact but not
# the proof. The CI entry script sets PG_PROOF_OPTIONAL=1 to degrade to content-key; locally an
# absent proof still blocks (that is where fabrication happens and the proof file is present).
newrepo; art "adversarial: zuvo/proofs/GONE.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 1 ] && ok "absent proof, LOCAL -> blocked" || bad "absent proof passed locally"
[ "$(PG_REVIEW_PROOF_CUTOFF=1 PG_PROOF_OPTIONAL=1 cov)" -eq 0 ] && ok "absent proof, CI (PG_PROOF_OPTIONAL=1) -> degrades to content-key" || bad "CI degrade did not pass"

echo "=== path resolution: relative to repo root ==="
newrepo; proof 2; mkdir -p sub; art "adversarial: zuvo/proofs/adv.txt"; touch memory/reviews/a.md
[ "$(PG_REVIEW_PROOF_CUTOFF=1 cov)" -eq 0 ] && ok "repo-relative proof path resolves" || bad "relative path unresolved"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
