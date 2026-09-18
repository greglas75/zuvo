#!/usr/bin/env bash
#
# test-adversarial-no-material.sh — a review that judged NOTHING must not exit 0.
#
# The class, found 2026-09-18 across three unrelated files, each reported exactly once (so the
# recurrence threshold that gates retro proposals never surfaced any of them):
#
#   * skills/review/SKILL.md:774,779 builds pass 2/3 as `echo "PRIOR FINDINGS: …"` + `git diff`.
#     When the diff resolves to nothing, the payload is still a non-empty sentence, so the
#     whitespace guard passes it, providers answer "0 findings", and `REVIEW BY:` lands in the
#     proof the push gate reads — a clean review of zero lines of code.
#   * skills/plan/SKILL.md:454-461 mandates a tail pass; a tail under 3 `### Task` headings hit
#     "plan too short" and exited 0, so the Review Trail recorded coverage nobody produced.
#   * shared/includes/test-quality-gate.md:45 produces a short re-audit report; under the
#     500-word minimum it exited 0 while test-audit ticked "adversarial review ran".
#
# All three are one shape: a gate returning success because it had nothing to judge. The fix is
# exit 5, and what this file pins is the DISTINCTION — 0 means looked-at-and-clean, 5 means not
# looked at. Conflating them is what produced push-gate proofs no provider ever made.
#
# No provider is ever called here: every assertion is about input handling, which happens before
# dispatch. That is deliberate — the test must be free and deterministic.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="$ROOT/scripts/adversarial-review.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

[ -x "$AR" ] || { echo "  ✗ $AR missing or not executable"; exit 1; }

# run_ar <mode> <payload> [env assignments…] → prints rc
run_ar() {
  local mode="$1" payload="$2"; shift 2
  local rc=0
  printf '%s' "$payload" | env "$@" bash "$AR" --mode "$mode" --multi >"$TMP/out" 2>"$TMP/err" || rc=$?
  echo "$rc"
}

echo "=== preamble-only payload (the pass-2 foot-gun) ==="
rc=$(run_ar code 'PRIOR FINDINGS: ADV-1 [x], ADV-2 [y] — find NEW issues only
')
[ "$rc" = "5" ] && ok "preamble-only code payload exits 5, not 0 (got $rc)" \
                || bad "preamble-only payload exited $rc — a review of nothing must not look like success"
grep -q 'NO REVIEWABLE MATERIAL' "$TMP/err" \
  && ok "stderr names the condition" || bad "stderr does not say NO REVIEWABLE MATERIAL"
grep -q 'do not record coverage' "$TMP/err" \
  && ok "stderr tells the caller not to record coverage" || bad "stderr gives the caller no instruction"

echo "=== a real diff is NOT blocked ==="
# The guard must not cost a genuine review. --list-providers stops before dispatch, so this
# asserts the payload got PAST the material check without calling anyone.
rc=0
printf 'diff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-const a=1\n+const a=2\n' \
  | bash "$AR" --mode code --list-providers >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" != "5" ] && ok "a real diff passes the material check (rc=$rc)" \
                 || bad "a genuine diff was rejected as no-material — the guard is too strict"

echo "=== a diff carrying a PRIOR FINDINGS line still passes ==="
# The realistic pass-2 payload: preamble AND a diff. Material is judged over the whole payload,
# so the preamble must not matter when actual hunks are present.
rc=0
printf 'PRIOR FINDINGS: ADV-1 [x]\ndiff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-const a=1\n+const a=2\n' \
  | bash "$AR" --mode code --list-providers >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" != "5" ] && ok "preamble + real diff passes (rc=$rc)" \
                 || bad "the normal pass-2 shape was rejected — this would break every rotation"

echo "=== document modes: short == not reviewed, not 'reviewed clean' ==="
rc=$(run_ar plan '### Task 1
do the thing
')
[ "$rc" = "5" ] && ok "a 1-task plan exits 5 (was 0: 'plan too short')" || bad "short plan exited $rc"

rc=$(run_ar audit 'Short audit report with far fewer than five hundred words.
')
[ "$rc" = "5" ] && ok "a short audit report exits 5 (was 0: 'report too short')" || bad "short report exited $rc"

rc=$(run_ar spec 'A spec of barely a dozen words, well under the two hundred minimum.
')
[ "$rc" = "5" ] && ok "a short spec exits 5" || bad "short spec exited $rc"

echo "=== a CHUNK of a long document is exempt from the per-mode minimum ==="
# The tail of a split plan is not a short plan: the parent validated the whole document before
# splitting it. Applying the minimum to parts is exactly how plan tails went unreviewed while
# being recorded as covered — so the exemption is load-bearing, not a convenience.
rc=0
printf '### Task 9\nthe last task of a long plan\n' \
  | ZUVO_ADV_CHUNK=3/3 bash "$AR" --mode plan --list-providers >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" != "5" ] && ok "a plan tail sent as chunk 3/3 is not rejected as short (rc=$rc)" \
                 || bad "the chunk exemption is missing — long-plan tails will go unreviewed again"

echo "=== the contract is documented where callers read it ==="
grep -q 'no reviewable material' "$AR" && ok "--help lists exit 5" || bad "--help does not document exit 5"
LOOP="$ROOT/shared/includes/adversarial-loop.md"
grep -q '`no_material` | \*\*5\*\*' "$LOOP" && ok "adversarial-loop.md has the exit-5 row" \
  || bad "adversarial-loop.md (the include callers load) does not document exit 5"
for f in skills/review/SKILL.md skills/plan/SKILL.md shared/includes/test-quality-gate.md; do
  grep -q 'exit[s]* \*\*5\*\*\|exit 5\|`5`' "$ROOT/$f" \
    && ok "$f handles exit 5" || bad "$f still treats a no-material pass as reviewed"
done

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
