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

echo "=== the guard must not eat a REAL review (the regression this nearly shipped) ==="
# `printf … | grep -q` under `set -o pipefail` returns 141 on a large payload: grep -q exits at the
# first match, printf dies of SIGPIPE, and the `!` test then declares a genuine diff empty.
# Reproduced on a 200k-line diff during the adversarial pass on this very commit — the guard
# against "reviewing nothing" would have blocked precisely the largest reviews.
python3 - > "$TMP/big.diff" <<'PYEOF'
print("diff --git a/x.ts b/x.ts"); print("@@ -1 +1 @@")
for i in range(200000): print("+line %d of a large but entirely real diff" % i)
PYEOF
rc=0
bash "$AR" --mode code --list-providers < "$TMP/big.diff" >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" != "5" ] && ok "a 200k-line real diff is NOT rejected as no-material (rc=$rc)" || bad "SIGPIPE regression is back: a real diff was declared empty"

echo "=== prose is not code (the false negative that mirrors it) ==="
rc=$(run_ar code '- first bullet of a document
- second bullet, no code anywhere in sight
')
[ "$rc" = "5" ] && ok "markdown prose exits 5 in code mode (bullets are not hunks)" || bad "prose still counts as code material (rc=$rc)"

echo "=== the exemption must not be forgeable by typing an env var ==="
# The first cut gated the WHOLE material check on ZUVO_ADV_CHUNK, an ordinary environment
# variable — so `ZUVO_ADV_CHUNK=1/1` turned the correctness gate off for any caller that typed it.
rc=0
printf 'PRIOR FINDINGS: ADV-1 — nothing else here\n' | ZUVO_ADV_CHUNK=1/1 bash "$AR" --mode code --multi >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" = "5" ] && ok "a forged 1/1 chunk marker cannot bypass the code-material check" || bad "ZUVO_ADV_CHUNK=1/1 still bypasses the material gate (rc=$rc)"
rc=0
printf '### Task 9\nthe last task of a long plan\n' | ZUVO_ADV_CHUNK=3/3 bash "$AR" --mode plan --list-providers >"$TMP/out" 2>"$TMP/err" || rc=$?
[ "$rc" != "5" ] && ok "a genuine k/n chunk (n>=2) is still exempt from the length minimum" || bad "the legitimate chunk exemption broke"

echo "=== the rejection message must not echo the payload ==="
# The first cut printed 120 raw bytes of the rejected input. A misrouted .env is exactly what gets
# piped by accident, and this message is kept on disk.
rc=$(run_ar code 'PRIOR FINDINGS: AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY
')
grep -q 'wJalrXUtnFEMIK' "$TMP/err" && bad "the no-material message echoes the payload back (leak channel)" || ok "the rejection names the shape, never the content"

echo "=== the contract is documented where callers read it ==="
grep -q 'no reviewable material' "$AR" && ok "--help lists exit 5" || bad "--help does not document exit 5"
LOOP="$ROOT/shared/includes/adversarial-loop.md"
grep -q '`no_material` | \*\*5\*\*' "$LOOP" && ok "adversarial-loop.md has the exit-5 row" \
  || bad "adversarial-loop.md (the include callers load) does not document exit 5"
for f in skills/review/SKILL.md skills/plan/SKILL.md shared/includes/test-quality-gate.md; do
  grep -q 'exit[s]* \*\*5\*\*\|exit 5\|`5`' "$ROOT/$f" \
    && ok "$f handles exit 5" || bad "$f still treats a no-material pass as reviewed"
done

echo "=== tree tamper-check around the full-access reviewer lanes ==="
# The codex lane pins sandbox_mode="danger-full-access" + approval_policy="never" and the claude
# lane passes --dangerously-skip-permissions, so a provider CAN write to the tree it is reviewing.
# That is deliberate (a sandboxed headless lane returned no output at all — field report
# 2026-07-12), so what must exist is DETECTION, not a revoked permission. These assertions are on
# the functions and their wiring: exercising a real provider would cost money and be flaky.
grep -q '_tamper_capture' "$AR" && ok "a pre-review tree snapshot is taken"   || bad "nothing snapshots the tree before the providers run"
grep -q '_tamper_verify' "$AR" && ok "a post-review comparison exists" || bad "no post-review comparison"
# Idempotent AND unconditional: most runs pass no --artifact, and those are the ad-hoc ones a
# person watches live. A check that only fires on the artifact path would miss them.
awk '/^_tamper_verify\(\)/,/^}/' "$AR" | grep -q '_TAMPER_DONE'   && ok "the check is idempotent (cannot print twice)" || bad "no idempotency guard"
grep -q 'tree_modified_during_review=' "$AR"   && ok "tampering is recorded IN the artifact, beside the REVIEW BY: lines a gate reads"   || bad "tampering would only reach stderr"
# It must never block: a bug in the tamper-check must not cost a real review.
awk '/^_tamper_verify\(\)/,/^}/' "$AR" | grep -q 'exit '   && bad "the tamper-check can exit — detection must never fail a review"   || ok "the tamper-check never exits (detection only)"

# Behaviour of the comparison itself, driven directly in a throwaway repo.
REPO="$TMP/repo"; mkdir -p "$REPO"
( cd "$REPO" && git init -q . && git config user.email t@t && git config user.name t   && echo one > a.txt && git add a.txt && git commit -qm init ) >/dev/null 2>&1
# Source just the two functions by extracting them — the script itself needs a full argv to run.
awk '/^_TAMPER_BEFORE=""/,/^_tamper_capture$/' "$AR" | sed 's/^_tamper_capture$//' > "$TMP/tamper.sh"
(
  cd "$REPO"
  TAMPER_NOTE=""
  # shellcheck source=/dev/null
  . "$TMP/tamper.sh"
  _tamper_capture
  echo "a reviewer wrote this" >> a.txt          # simulate a provider mutating the tree
  _tamper_verify 2>"$TMP/tamper.err"
  printf '%s' "$TAMPER_NOTE" > "$TMP/tamper.note"
) >/dev/null 2>&1
grep -q 'working tree changed during the review' "$TMP/tamper.err"   && ok "a file modified between capture and verify is detected"   || bad "a tree modified under the reviewer went unnoticed"
[ -s "$TMP/tamper.note" ] && ok "TAMPER_NOTE is set for the artifact" || bad "TAMPER_NOTE stayed empty"

# And the opposite: an untouched tree must stay silent, or the warning becomes noise nobody reads.
(
  cd "$REPO"
  # shellcheck source=/dev/null
  . "$TMP/tamper.sh"
  _tamper_capture
  _tamper_verify 2>"$TMP/clean.err"
) >/dev/null 2>&1
[ -s "$TMP/clean.err" ] && bad "an untouched tree produced a warning (false positive)"                         || ok "an untouched tree produces no warning"

echo "=== ship: the merge gate reads the rollup, not --watch's exit code ==="
SHIP="$ROOT/skills/ship/SKILL.md"
grep -q 'statusCheckRollup' "$SHIP"   && ok "ship decides from the check rollup" || bad "ship still merges on --watch alone"
grep -q 'gh pr list --head "\$BRANCH" --state open' "$SHIP"   && ok "ship resolves only OPEN prs for the head (a reused branch name cannot match a merged PR)"   || bad "ship still uses gh pr view <branch>, which can resolve to a historical merged PR"
grep -q 'merging UNVERIFIED' "$SHIP"   && ok "zero-checks is stated, not silently treated as green" || bad "zero-checks case is not surfaced"
# Three fail-open paths the first cut left open: no jq, a failed `gh pr view`, and classic
# Status-API entries. Each one ended at `gh pr merge` with the gate reporting "none failed".
grep -q 'command -v jq' "$SHIP" && ok "ship refuses to run the merge gate without jq" || bad "an absent jq still falls through to merge"
grep -q 'refusing to merge blind' "$SHIP" && ok "a failed rollup read blocks the merge instead of reading as zero checks" || bad "a gh failure is still indistinguishable from 'no checks configured'"
grep -q '[.]state' "$SHIP" && ok "the rollup filters read .state too (classic Status-API entries)" || bad "a red classic commit status is still invisible to the gate"
grep -q 'actions/workflows' "$SHIP" && ok "an empty rollup is distinguished from a repo that truly has no CI" || bad "'no checks yet' and 'no CI' are still the same branch"

echo "=== RESULT ==="
[ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
