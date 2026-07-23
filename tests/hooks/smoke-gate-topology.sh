#!/usr/bin/env bash
# Phase Final whole-feature smoke: the topology-complete gate, INSTALLED into a hermetic throwaway
# repo exactly as a real project wires it, scopes a merge / multi-merge branch to feature-only
# end-to-end. SMOKE1 = single-merge (the reported bug); SMOKE2 = multi-merge (previously over-scoped).
set -u
# Content-key / topology suite: the 2026-07-23 adversarial proof-of-work layer is covered
# by test-review-proof-gate.sh; grandfather it off here so these fixtures test their own
# concern in isolation.
export PG_REVIEW_PROOF_CUTOFF=99999999999
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/hooks/pre-push-gate.sh"; LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

# install the built pre-push gate into a repo's .git/hooks, sourcing the current lib
install_gate(){ local d="$1"; mkdir -p "$d/.git/hooks" "$d/hooks/lib"
  cp "$GATE" "$d/hooks/pre-push-gate.sh"; cp "$LIB" "$d/hooks/lib/pipeline-gate-lib.sh"
  printf '#!/bin/sh\nexec "%s/hooks/pre-push-gate.sh"\n' "$d" > "$d/.git/hooks/pre-push"
  chmod +x "$d/.git/hooks/pre-push" "$d/hooks/pre-push-gate.sh"; }

# write a covering content-keyed review artifact for exactly the listed files
cover(){ local d="$1" files="$2"; mkdir -p "$d/memory/reviews"
  { echo "<!-- zuvo-review -->"; echo "range: @unpushed..HEAD"; echo "files: $files"; echo "verdict: PASS"; } \
    > "$d/memory/reviews/cover.md"; }

echo "=== SMOKE1: single-merge branch push scoped feature-only via the INSTALLED gate ==="
D=$(mktemp -d); R=$(mktemp -d); git -C "$R" init -q --bare
git -C "$D" init -q -b main; git -C "$D" config user.email t@t; git -C "$D" config user.name t; git -C "$D" config commit.gpgsign false
git -C "$D" remote add origin "$R"
install_gate "$D"
for i in 1 2 3 4; do echo "b$i" > "$D/base$i.js"; done; git -C "$D" add -A; git -C "$D" commit -qm base
ZUVO_ALLOW_ADHOC=1 git -C "$D" push -q origin main
git -C "$D" checkout -q -b feat
# 3 unreviewed feature files (crosses the ≥3 substantial threshold)
for i in 1 2 3; do echo "f$i" > "$D/feat$i.js"; done; git -C "$D" add -A; git -C "$D" commit -qm feat
# main advances a big surface + gets pushed; feat merges it in
git -C "$D" checkout -q main; for i in 1 2 3 4 5; do echo "M$i" > "$D/mainbig$i.js"; done; git -C "$D" add -A; git -C "$D" commit -qm "main advance"
ZUVO_ALLOW_ADHOC=1 git -C "$D" push -q origin main
git -C "$D" checkout -q feat; git -C "$D" merge -q main -m "merge main" >/dev/null 2>&1
# push feat as an AGENT (ZUVO_AGENT=1) with NO coverage → must BLOCK, naming feature files only
err=$(cd "$D" && ZUVO_AGENT=1 git push origin feat 2>&1); rc=$?
{ [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qi BLOCKED; } && ok "unreviewed merge-branch push BLOCKED" || bad "SMOKE1: expected BLOCK (rc=$rc)"
printf '%s' "$err" | grep -qE 'mainbig' && bad "SMOKE1: block names merged-in main files (over-scope!)" || ok "block does NOT name any merged-in main file (feature-only scope)"
# cover exactly the feature files → push now ALLOWED
cover "$D" "feat1.js, feat2.js, feat3.js"
out=$(cd "$D" && ZUVO_AGENT=1 git push origin feat 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "after covering ONLY the feature files → push ALLOWED" || bad "SMOKE1: covered push still blocked (rc=$rc): $out"
rm -rf "$D" "$R"

echo "=== SMOKE2: multi-merge branch not over-scoped end-to-end ==="
D=$(mktemp -d); R=$(mktemp -d); git -C "$R" init -q --bare
git -C "$D" init -q -b main; git -C "$D" config user.email t@t; git -C "$D" config user.name t; git -C "$D" config commit.gpgsign false
git -C "$D" remote add origin "$R"; install_gate "$D"
echo base > "$D/base.js"; git -C "$D" add -A; git -C "$D" commit -qm base; git -C "$D" tag basepoint
ZUVO_ALLOW_ADHOC=1 git -C "$D" push -q origin main
git -C "$D" checkout -q -b other basepoint; for i in 1 2 3; do echo "o$i" > "$D/other$i.js"; done; git -C "$D" add -A; git -C "$D" commit -qm other
ZUVO_ALLOW_ADHOC=1 git -C "$D" push -q origin other
git -C "$D" checkout -q main; for i in 1 2 3; do echo "m$i" > "$D/main$i.js"; done; git -C "$D" add -A; git -C "$D" commit -qm main
ZUVO_ALLOW_ADHOC=1 git -C "$D" push -q origin main
git -C "$D" checkout -q -b feat basepoint; for i in 1 2 3; do echo "f$i" > "$D/feat$i.js"; done; git -C "$D" add -A; git -C "$D" commit -qm feat
git -C "$D" merge -q origin/main -m "merge main" >/dev/null 2>&1; git -C "$D" merge -q origin/other -m "merge other" >/dev/null 2>&1
# cover ONLY the feature files; with correct scoping the multi-merge push is ALLOWED
cover "$D" "feat1.js, feat2.js, feat3.js"
out=$(cd "$D" && ZUVO_AGENT=1 git push origin feat 2>&1); rc=$?
[ "$rc" -eq 0 ] && ok "multi-merge push ALLOWED with only feature files covered (was over-scoped)" || bad "SMOKE2: multi-merge over-scoped (rc=$rc): $out"
rm -rf "$D" "$R"

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL SMOKE PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
