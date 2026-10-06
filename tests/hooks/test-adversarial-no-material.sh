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
# No real provider is ever called here: every driver run is under the test harness, with lanes the suite
# writes itself. That is deliberate — the test must be free and deterministic. A payload the check must
# REFUSE runs against `mock-spy`, a lane that logs each call: a refusal is then also proven to have sent
# nothing (the spy's log stays absent), and a regression that let the payload through reaches the spy,
# never a paid model. A payload that must get PAST the check is run with --dry-run (mock-success named,
# never dispatched): it exits 0 only after the material check, names the lane it would have used, and
# prints the prompt it built. The tamper section dispatches its lanes for real: a spy, and one that edits
# the tree it is reviewing.
#
# Test level: large (process-level). Most cases spawn the whole driver end to end; the tamper section also
# calls the two tamper functions directly (module level, cut out of the program text), and the contract
# section reads source and skill text. Every case has its own scratch directory (`scratch <tag>`): its
# stdout/stderr, its spy log, its ZUVO_HOME and its git repository — no case reads another's state.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AR="$ROOT/scripts/adversarial-review.sh"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A ZUVO_HOME per CASE (scratch below sets it), never the real ~/.zuvo, whose plan-budget would trip the --mode
# plan circuit-breaker (exit 7) on this suite and on the owner's real plan reviews; no case spends another's
# budget. Until the first case this suite-level home stands in, created here, not left to the driver.
export ZUVO_HOME="$TMP/zuvo-home"
mkdir -p "$ZUVO_HOME" || { echo "  ✗ cannot create the suite's ZUVO_HOME ($ZUVO_HOME)"; exit 1; }
# The source assertions below read the program as one text — the driver and its modules
# (scripts/lib/adversarial-*.sh): the help text and the tamper-check live in modules now.
. "$ROOT/tests/lib/adversarial-driver.sh"
SRC="$TMP/driver-source.sh"; adv_driver_source "$AR" > "$SRC" || { echo "  ✗ the program text could not be assembled"; exit 1; }

fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

[ -x "$AR" ] || { echo "  ✗ $AR missing or not executable"; exit 1; }

# The suite's own lanes (the harness dispatches a mock-* lane by its name on PATH — dispatch.sh run_mock).
#   mock-spy    — answers a clean review and appends one line per call to $MOCK_SPY_LOG.
#   mock-tamper — the same, and first appends a line to $MOCK_TAMPER_FILE: a reviewer editing the tree.
#   mock-probe  — echoes the doctor's probe token (run.sh: WORKING needs PROVIDER-OK in the reply).
LANES="$TMP/lanes"; mkdir -p "$LANES" || { echo "  ✗ cannot create $LANES"; exit 1; }
cat > "$LANES/mock-spy" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo called >> "${MOCK_SPY_LOG:?}"
printf '{"findings":[]}\n'
EOF
cat > "$LANES/mock-tamper" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo called >> "${MOCK_SPY_LOG:?}"
echo "a reviewer wrote this" >> "${MOCK_TAMPER_FILE:?}"
printf '{"findings":[]}\n'
EOF
cat > "$LANES/mock-probe" <<'EOF'
#!/usr/bin/env bash
cat >/dev/null
echo called >> "${MOCK_SPY_LOG:?}"
echo PROVIDER-OK
EOF
chmod +x "$LANES/mock-spy" "$LANES/mock-tamper" "$LANES/mock-probe"

# scratch <tag> — the case's own state: $S (its directory), $OUT/$ERR (the driver's stdout/stderr),
# $SPY_LOG (the lanes' call log, absent until a lane is called) and its own ZUVO_HOME. Called in the
# suite's shell (never inside $(…)), before the case's first driver run.
scratch() {
  S="$TMP/case-$1"; OUT="$S/out"; ERR="$S/err"; SPY_LOG="$S/spy.log"
  export ZUVO_HOME="$S/zuvo-home"
  mkdir -p "$ZUVO_HOME" || bad "cannot create the scratch directory of case $1 ($S)"
}

# run_ar <mode> <payload> [env assignments…] → prints rc. A real (non-dry) run whose only lane is mock-spy.
run_ar() {
  local mode="$1" payload="$2"; shift 2
  local rc=0
  printf '%s' "$payload" | env ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-spy \
    MOCK_SPY_LOG="$SPY_LOG" PATH="$LANES:$PATH" "$@" \
    bash "$AR" --mode "$mode" --multi >"$OUT" 2>"$ERR" || rc=$?
  echo "$rc"
}
# dry_ar <mode> [env assignments…] < payload → prints rc. A --dry-run under the test harness: the payload goes
# through the material check, the prompt is built and printed (stdout), and the driver exits 0 before any
# dispatch — the mock lane is named, never run. (--list-providers could not tell: it replaces the input and
# skips the material check, so a case built on it passed whatever the check did.)
dry_ar() {
  local mode="$1"; shift
  local rc=0
  env ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-success "$@" \
    bash "$AR" --mode "$mode" --dry-run >"$OUT" 2>"$ERR" || rc=$?
  echo "$rc"
}
# passed_check <label> <rc> <text the prompt must carry> — rc 0 and the payload in the prompt on stdout; and
# the dry run's own report names the harness lane it resolved (run.sh ar_dry_run: `Providers: $PROVIDERS`),
# so the run went through provider resolution after the check, rather than stopping anywhere before it.
passed_check() {
  if [ "$2" = "0" ] && grep -qF -- "$3" "$OUT"; then ok "$1"
  elif [ "$2" = "5" ]; then bad "$1 — rejected as no-material (exit 5)"
  else bad "$1 — exit $2, prompt carries [$3]: $(grep -cF -- "$3" "$OUT") line(s); $(head -c 200 "$ERR")"; fi
  grep -qxF 'Providers: mock-success' "$ERR" && ok "$1 — the dry run resolved the harness lane (Providers: mock-success)" \
    || bad "$1 — the dry run's report does not name mock-success: $(grep -F 'Providers:' "$ERR" | head -c 200)"
}
# not_sent <label> — no lane was called (the spy's log was never created): _no_material's own promise,
# "Nothing was sent to any provider" (input.sh _no_material).
not_sent() {
  if [ -e "$SPY_LOG" ]; then bad "$1 — a lane was called $(grep -c . "$SPY_LOG") time(s) although the input was refused"
  else ok "$1 — nothing was sent to the lane"; fi
}
# refused <label> <rc> <reason> — exit 5, the exact reason line _no_material prints (input.sh _no_material:
# "Adversarial review: NO REVIEWABLE MATERIAL — <reason>."), and no lane called.
refused() {
  [ "$2" = "5" ] && ok "$1 — exit 5" || bad "$1 — exit $2, want 5 (no reviewable material)"
  grep -qxF -- "Adversarial review: NO REVIEWABLE MATERIAL — $3." "$ERR" && ok "$1 — reason: $3" \
    || bad "$1 — stderr lacks the exact reason [$3]; it says: $(grep -F 'NO REVIEWABLE' "$ERR" | head -c 300)"
  not_sent "$1"
}
# pb_count <tag> — the plan-budget entries in case <tag>'s own ZUVO_HOME: one per non-dry plan run (cli.sh
# ar_check_plan_budget skips --dry-run). Each plan case checks its OWN home right after its run, so the real
# ~/.zuvo is shown unwritten and the case runs alone.
pb_count() { cat "$TMP/case-$1/zuvo-home"/plan-budget/* 2>/dev/null | grep -c .; }
# words <n> — n words: w1 … w(n-1) and a last word, tail<n>, that occurs nowhere else.
words() { local i; for ((i = 1; i < $1; i++)); do printf 'w%d ' "$i"; done; printf 'tail%d\n' "$1"; }
# tasks <n> — a plan of n `### Task` headings.
tasks() { local i; for ((i = 1; i <= $1; i++)); do printf '### Task %d\nstep %d of the plan\n' "$i" "$i"; done; }
# mkrepo <dir> [unborn] — a throwaway repository with a.txt committed (or, with `unborn`, only written).
mkrepo() {
  mkdir -p "$1" || { bad "cannot create the repository $1"; return 1; }
  ( cd "$1" && git init -q . && git config user.email t@t && git config user.name t && echo one > a.txt \
    && { [ "${2:-}" = unborn ] || { git add a.txt && git commit -qm init; }; } ) >/dev/null 2>&1 \
    || bad "the repository $1 could not be set up"
}

echo "=== preamble-only payload (the pass-2 foot-gun) ==="
scratch preamble
rc=$(run_ar code 'PRIOR FINDINGS: ADV-1 [x], ADV-2 [y] — find NEW issues only
')
[ "$rc" = "5" ] && ok "preamble-only code payload exits 5, not 0 (got $rc)" \
                || bad "preamble-only payload exited $rc — a review of nothing must not look like success"
grep -q 'NO REVIEWABLE MATERIAL' "$ERR" \
  && ok "stderr names the condition" || bad "stderr does not say NO REVIEWABLE MATERIAL"
grep -q 'do not record coverage' "$ERR" \
  && ok "stderr tells the caller not to record coverage" || bad "stderr gives the caller no instruction"
not_sent "preamble-only payload"

echo "=== a real diff is NOT blocked ==="
# The guard must not cost a genuine review: the payload gets PAST the material check (dry run, no
# provider called) and into the prompt.
scratch real-diff
rc=$(printf 'diff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-const a=1\n+const a=2\n' | dry_ar code)
passed_check "a real diff passes the material check and reaches the prompt" "$rc" "+const a=2"

echo "=== a diff carrying a PRIOR FINDINGS line still passes ==="
# The realistic pass-2 payload: preamble AND a diff. Material is judged over the whole payload,
# so the preamble must not matter when actual hunks are present.
scratch preamble-diff
rc=$(printf 'PRIOR FINDINGS: ADV-1 [x]\ndiff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-const a=1\n+const a=2\n' | dry_ar code)
passed_check "preamble + real diff passes (the normal pass-2 shape; rejecting it would break every rotation)" "$rc" "+const a=2"

echo "=== code material: each of the three shapes is enough on its own, a near miss is not ==="
# input.sh ar_check_material, the code-ish branch: `grep -qE '^(diff --git |@@ |=== FILE: )'`. The diff
# cases above carry all of a diff header and a hunk; these pin the other two alternatives alone, and the
# anchor and the space each one ends with.
scratch hunk-only
rc=$(printf '@@ -1 +1 @@\n-const a=1\n+const only_hunk=1\n' | dry_ar code)
passed_check "a bare hunk (@@, no diff --git header) is material" "$rc" "+const only_hunk=1"
scratch file-only
rc=$(printf '=== FILE: src/x.ts ===\nconst file_only=1\n' | dry_ar code)
passed_check "a '=== FILE:' section alone (the --files shape) is material" "$rc" "const file_only=1"
scratch near-miss
# An indented diff header, a hunk with no space after @@, and a heading with four '='. 43 chars once the
# trailing newline is gone (the reason reports ${#INPUT}).
rc=$(run_ar code ' diff --git a/x b/x
@@-1 +1 @@
==== FILE: y
')
refused "near misses of all three shapes" "$rc" "no diff hunks and no '=== FILE:' sections — pipe a diff or use --files (payload was 43 chars)"

echo "=== every code-ish mode refuses a payload with no code ==="
# Every mode that is not a document mode falls to the code branch (input.sh: the final `else`). The payload
# is ASCII so its length (48 chars) does not depend on the locale's idea of a character.
for m in code test security migrate; do
  scratch "codeish-$m"
  rc=$(run_ar "$m" 'PRIOR FINDINGS: ADV-1 [x] - find NEW issues only
')
  refused "--mode $m, no hunks" "$rc" "no diff hunks and no '=== FILE:' sections — pipe a diff or use --files (payload was 48 chars)"
done

echo "=== document modes: short == not reviewed, not 'reviewed clean' ==="
scratch plan-short
rc=$(run_ar plan '### Task 1
do the thing
')
[ "$rc" = "5" ] && ok "a 1-task plan exits 5 (was 0: 'plan too short')" || bad "short plan exited $rc"
not_sent "a 1-task plan"
pb_n="$(pb_count plan-short)"
[ "$pb_n" -ge 1 ] && [ "$pb_n" -lt 8 ] && ok "the suite's plan-mode runs counted in its own home: $pb_n of the budget's 8" \
  || bad "plan-budget entries in the short-plan case's ZUVO_HOME: $pb_n (want 1-7: 0 means they went elsewhere)"
[ "$pb_n" = "1" ] && ok "the short-plan case's home holds exactly its one plan run" || bad "the short-plan case's home holds $pb_n plan-budget entries, want exactly 1"

scratch audit-short
rc=$(run_ar audit 'Short audit report with far fewer than five hundred words.
')
[ "$rc" = "5" ] && ok "a short audit report exits 5 (was 0: 'report too short')" || bad "short report exited $rc"
not_sent "a short audit report"

scratch spec-short
rc=$(run_ar spec 'A spec of barely a dozen words, well under the two hundred minimum.
')
[ "$rc" = "5" ] && ok "a short spec exits 5" || bad "short spec exited $rc"
not_sent "a short spec"

echo "=== document minimums at the exact boundary: the minimum passes, one less is refused ==="
# input.sh: MIN_DOC_WORDS=200 (spec, article), MIN_PLAN_TASKS=3 (plan), MIN_REPORT_WORDS=500 (audit, tests),
# each compared with `-lt` in its branch of ar_check_material. A `-le` there, or a changed constant, moves
# one of these by one.
for m in spec article; do
  scratch "min-$m-199"
  rc=$(run_ar "$m" "$(words 199)")
  refused "--mode $m at 199 words" "$rc" "$m too short (199 words, minimum 200)"
  scratch "min-$m-200"
  rc=$(words 200 | dry_ar "$m")
  passed_check "--mode $m at exactly 200 words passes" "$rc" "tail200"
done
scratch min-plan-2
rc=$(run_ar plan "$(tasks 2)")
refused "--mode plan with 2 tasks" "$rc" "plan too short (2 tasks, minimum 3)"
[ "$(pb_count min-plan-2)" = "1" ] && ok "the 2-task case's home holds exactly its one plan run" || bad "the 2-task case's home holds $(pb_count min-plan-2) plan-budget entries, want 1"
scratch min-plan-3
rc=$(tasks 3 | dry_ar plan)
passed_check "--mode plan with exactly 3 tasks passes" "$rc" "### Task 3"
[ "$(pb_count min-plan-3)" = "0" ] && ok "the 3-task dry run recorded no plan round" || bad "the 3-task dry run recorded $(pb_count min-plan-3) plan-budget entries, want 0"
for m in audit tests; do
  scratch "min-$m-499"
  rc=$(run_ar "$m" "$(words 499)")
  refused "--mode $m at 499 words" "$rc" "report too short (499 words, minimum 500)"
  scratch "min-$m-500"
  rc=$(words 500 | dry_ar "$m")
  passed_check "--mode $m at exactly 500 words passes" "$rc" "tail500"
done

echo "=== a CHUNK of a long document is exempt from the per-mode minimum ==="
# The tail of a split plan is not a short plan: the parent validated the whole document before
# splitting it. Applying the minimum to parts is exactly how plan tails went unreviewed while
# being recorded as covered — so the exemption is load-bearing, not a convenience.
scratch chunk-tail
rc=$(printf '### Task 9\nthe last task of a long plan\n' | dry_ar plan ZUVO_ADV_CHUNK=3/3)
passed_check "a plan tail sent as chunk 3/3 is not rejected as short (the chunk exemption)" "$rc" "the last task of a long plan"

echo "=== the chunk exemption at its edges ==="
# input.sh ar_check_material: a chunk child is `^[0-9]+/([0-9]+)$` with n `-ge 2`. n=2 is the smallest
# genuine split; n=1 is the forgery the comment there names. The exemption is in all three length branches
# (spec/article words, plan tasks, audit/tests words) and in none of the code branch.
scratch chunk-n2
rc=$(printf '### Task 9\nthe last task of a two-part plan\n' | dry_ar plan ZUVO_ADV_CHUNK=2/2)
passed_check "a plan part sent as chunk 2/2 (n=2, the smallest split) is exempt" "$rc" "the last task of a two-part plan"
scratch chunk-n1-plan
rc=$(run_ar plan '### Task 9
the only task
' ZUVO_ADV_CHUNK=1/1)
refused "a 1-task plan marked chunk 1/1 (n=1 is not a split)" "$rc" "plan too short (1 tasks, minimum 3)"
scratch chunk-spec
rc=$(words 199 | dry_ar spec ZUVO_ADV_CHUNK=2/2)
passed_check "a 199-word spec part sent as chunk 2/2 is exempt (the word branch)" "$rc" "tail199"
scratch chunk-tests
rc=$(words 499 | dry_ar tests ZUVO_ADV_CHUNK=2/2)
passed_check "a 499-word tests-report part sent as chunk 2/2 is exempt (the report branch)" "$rc" "tail499"
scratch chunk-code
# 17 chars: "PRIOR FINDINGS: x".
rc=$(run_ar code 'PRIOR FINDINGS: x
' ZUVO_ADV_CHUNK=2/2)
refused "a code part with no hunks, even as a genuine chunk 2/2" "$rc" "no diff hunks and no '=== FILE:' sections — pipe a diff or use --files (payload was 17 chars)"

echo "=== a MALFORMED chunk marker is no chunk: the ordinary minimum applies ==="
# input.sh ar_check_material (:442): the exemption needs ZUVO_ADV_CHUNK to match `^[0-9]+/([0-9]+)$` WHOLE —
# anything else leaves _is_chunk_child=false (:441), so a short document is refused exactly as with no marker
# at all, and nothing is sent. Each marker breaks the shape one way: a non-digit or missing part, an extra
# field, another separator, a sign, and a blank or a newline the anchors must not let through.
_mi=0
for mk in 3/x 3/ /3 x/3 3/3/3 3:3 3/-3 ' 3/3' '3/3 ' $'3/3\n'; do
  _mi=$((_mi + 1)); scratch "chunk-malformed-$_mi"
  rc=$(run_ar plan '### Task 9
the only task
' ZUVO_ADV_CHUNK="$mk")
  refused "a 1-task plan with the malformed marker $(printf '%q' "$mk")" "$rc" "plan too short (1 tasks, minimum 3)"
done
# …in the two word branches as well (the marker is read once, before the branches).
scratch chunk-malformed-spec
rc=$(run_ar spec "$(words 199)" ZUVO_ADV_CHUNK=2/two)
refused "a 199-word spec with the malformed marker 2/two" "$rc" "spec too short (199 words, minimum 200)"
scratch chunk-malformed-tests
rc=$(run_ar tests "$(words 499)" ZUVO_ADV_CHUNK='2/2 ')
refused "a 499-word tests report with the malformed marker '2/2 '" "$rc" "report too short (499 words, minimum 500)"

echo "=== the guard must not eat a REAL review (the regression this nearly shipped) ==="
# `printf … | grep -q` under `set -o pipefail` returns 141 on a large payload: grep -q exits at the
# first match, printf dies of SIGPIPE, and the `!` test then declares a genuine diff empty.
# Reproduced on a 200k-line diff during the adversarial pass on this very commit — the guard
# against "reviewing nothing" would have blocked precisely the largest reviews.
scratch big-diff
python3 - > "$S/big.diff" <<'PYEOF'
print("diff --git a/x.ts b/x.ts"); print("@@ -1 +1 @@")
for i in range(200000): print("+line %d of a large but entirely real diff" % i)
PYEOF
# The diff is over the driver's default input ceiling (ZUVO_ADV_MAX_INPUT_BYTES), which
# would refuse it with exit 2 before the material check ran. This case is about that check on a large
# input, not about the ceiling (hardening F28 drives the refusal), so it raises the ceiling for itself.
rc=$(dry_ar code ZUVO_ADV_MAX_INPUT_BYTES=16777216 < "$S/big.diff")
passed_check "a 200k-line real diff is NOT rejected as no-material (the SIGPIPE regression)" "$rc" "+line 0 of a large but entirely real diff"

echo "=== prose is not code (the false negative that mirrors it) ==="
scratch prose
rc=$(run_ar code '- first bullet of a document
- second bullet, no code anywhere in sight
')
[ "$rc" = "5" ] && ok "markdown prose exits 5 in code mode (bullets are not hunks)" || bad "prose still counts as code material (rc=$rc)"
not_sent "markdown prose in code mode"

echo "=== the exemption must not be forgeable by typing an env var ==="
# The first cut gated the WHOLE material check on ZUVO_ADV_CHUNK, an ordinary environment
# variable — so `ZUVO_ADV_CHUNK=1/1` turned the correctness gate off for any caller that typed it.
scratch forged-chunk
rc=$(run_ar code 'PRIOR FINDINGS: ADV-1 — nothing else here
' ZUVO_ADV_CHUNK=1/1)
[ "$rc" = "5" ] && ok "a forged 1/1 chunk marker cannot bypass the code-material check" || bad "ZUVO_ADV_CHUNK=1/1 still bypasses the material gate (rc=$rc)"
not_sent "a forged 1/1 chunk marker"
scratch genuine-chunk
rc=$(printf '### Task 9\nthe last task of a long plan\n' | dry_ar plan ZUVO_ADV_CHUNK=3/3)
passed_check "a genuine k/n chunk (n>=2) is still exempt from the length minimum" "$rc" "the last task of a long plan"

echo "=== the commands that review nothing skip the check ==="
# input.sh ar_check_material: `--doctor` and `--list-providers` replace the input with a placeholder and
# never review it; the check is skipped for them (`$DOCTOR != true && $LIST_PROVIDERS != true`). Without
# that skip a plan-mode placeholder has 0 tasks and both commands exit 5 — the two commands that
# diagnose the reviewer. Empty stdin, so nothing here could pass the check on its own.
scratch list-providers
rc=0
env ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-spy MOCK_SPY_LOG="$SPY_LOG" PATH="$LANES:$PATH" \
  bash "$AR" --mode plan --list-providers </dev/null >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] && ok "--list-providers in plan mode with no input exits 0" || bad "--list-providers in plan mode exited $rc (5 = the material check ran on it)"
[ "$(cat "$OUT")" = "mock-spy" ] && ok "--list-providers prints exactly the lane list (mock-spy)" || bad "--list-providers printed: $(head -c 200 "$OUT")"
grep -qF 'NO REVIEWABLE MATERIAL' "$ERR" && bad "--list-providers ran into the material check" || ok "--list-providers never reaches the material refusal"
not_sent "--list-providers"
scratch doctor
rc=0
env ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS=mock-probe MOCK_SPY_LOG="$SPY_LOG" PATH="$LANES:$PATH" \
  bash "$AR" --mode plan --doctor </dev/null >"$OUT" 2>"$ERR" || rc=$?
[ "$rc" = "0" ] && ok "--doctor in plan mode with no input exits 0 (one working lane)" || bad "--doctor in plan mode exited $rc (5 = the material check ran on it)"
grep -qxF '  usable providers: 1 / 1' "$OUT" && ok "--doctor probed its lane and reported it usable" || bad "--doctor's report: $(head -c 300 "$OUT")"
[ "$(grep -c . "$SPY_LOG" 2>/dev/null)" = "1" ] && ok "--doctor called the lane exactly once (the probe)" || bad "--doctor called the lane $(grep -c . "$SPY_LOG" 2>/dev/null || echo 0) time(s), want 1"
grep -qF 'NO REVIEWABLE MATERIAL' "$ERR" && bad "--doctor ran into the material check" || ok "--doctor never reaches the material refusal"

echo "=== the rejection message must not echo the payload ==="
# The first cut printed 120 raw bytes of the rejected input. A misrouted .env is exactly what gets
# piped by accident, and this message is kept on disk.
scratch no-echo
rc=$(run_ar code 'PRIOR FINDINGS: AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMIK7MDENGbPxRfiCYEXAMPLEKEY
')
grep -q 'wJalrXUtnFEMIK' "$ERR" && bad "the no-material message echoes the payload back (leak channel)" || ok "the rejection names the shape, never the content"
[ "$rc" = "5" ] && ok "the secret-bearing payload is refused (exit 5), so the message above is the refusal's" || bad "the secret-bearing payload exited $rc, want 5"

echo "=== the contract is documented where callers read it ==="
grep -q 'no reviewable material' "$SRC" && ok "--help lists exit 5" || bad "--help does not document exit 5"
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
grep -q '_tamper_capture' "$SRC" && ok "a pre-review tree snapshot is taken"   || bad "nothing snapshots the tree before the providers run"
grep -q '_tamper_verify' "$SRC" && ok "a post-review comparison exists" || bad "no post-review comparison"
# Idempotent AND unconditional: most runs pass no --artifact, and those are the ad-hoc ones a
# person watches live. A check that only fires on the artifact path would miss them.
awk '/^_tamper_verify\(\)/,/^}/' "$SRC" | grep -q '_TAMPER_DONE'   && ok "the check is idempotent (cannot print twice)" || bad "no idempotency guard"
grep -q 'tree_modified_during_review=' "$SRC"   && ok "tampering is recorded IN the artifact, beside the REVIEW BY: lines a gate reads"   || bad "tampering would only reach stderr"
# It must never block: a bug in the tamper-check must not cost a real review.
awk '/^_tamper_verify\(\)/,/^}/' "$SRC" | grep -q 'exit '   && bad "the tamper-check can exit — detection must never fail a review"   || ok "the tamper-check never exits (detection only)"

# Behaviour of the comparison itself, driven directly in a throwaway repo.
# cut_tamper — the two functions, cut out of the program into the CASE's own $S/tamper.sh (each case cuts its
# own copy: none sources a file an earlier case made) — the script itself needs a full argv to run.
# From the state they share to the end of _tamper_verify (Main, which calls _tamper_capture, is elsewhere).
# Status 1 unless the cut really ended at _tamper_verify's closing brace: an anchor that moved would
# otherwise hand the subshell below the rest of the program — Main included — to source.
cut_tamper() {
  awk '/^_TAMPER_BEFORE=""/ { f = 1 } f { print } f && /^_tamper_verify\(\)/ { v = 1 } v && /^}$/ { done = 1; exit }
       END { exit !done }' "$SRC" > "$S/tamper.sh" \
    || { bad "the tamper functions could not be cut out of the program (from _TAMPER_BEFORE=\"\" to _tamper_verify's end) — this case runs on nothing"; : > "$S/tamper.sh"; }
}
scratch tamper-unit
REPO="$S/repo"; mkrepo "$REPO"; cut_tamper
(
  cd "$REPO" || exit 1
  TAMPER_NOTE=""
  # shellcheck source=/dev/null
  . "$S/tamper.sh"
  _tamper_capture
  echo "a reviewer wrote this" >> a.txt          # simulate a provider mutating the tree
  _tamper_verify 2>"$S/tamper.err"
  printf '%s' "$TAMPER_NOTE" > "$S/tamper.note"
) >/dev/null 2>&1
grep -q 'working tree changed during the review' "$S/tamper.err"   && ok "a file modified between capture and verify is detected"   || bad "a tree modified under the reviewer went unnoticed"
[ -s "$S/tamper.note" ] && ok "TAMPER_NOTE is set for the artifact" || bad "TAMPER_NOTE stayed empty"

# And the opposite: an untouched tree must stay silent, or the warning becomes noise nobody reads. Its own
# repository: the one above was modified by the case before.
scratch tamper-unit-clean
CREPO="$S/repo"; mkrepo "$CREPO"; cut_tamper
(
  cd "$CREPO" || exit 1
  # shellcheck source=/dev/null
  . "$S/tamper.sh"
  _tamper_capture
  _tamper_verify 2>"$S/clean.err"
) >/dev/null 2>&1
[ -e "$S/clean.err" ] || bad "the untouched-tree case did not run (no stderr file)"
[ -s "$S/clean.err" ] && bad "an untouched tree produced a warning (false positive)"                         || ok "an untouched tree produces no warning"

# An UNBORN repository (no commit yet): "edit, then commit" during the review moves HEAD from nothing to
# a sha. HEAD is read with --verify, so the baseline is empty — and that move must still be reported.
scratch tamper-unit-unborn
UREPO="$S/unborn"; mkrepo "$UREPO" unborn; cut_tamper
(
  cd "$UREPO" || exit 1
  TAMPER_NOTE=""
  # shellcheck source=/dev/null
  . "$S/tamper.sh"
  _tamper_capture
  git add a.txt && git commit -qm "made during the review"
  _tamper_verify 2>"$S/unborn.err"
) >/dev/null 2>&1
grep -q 'HEAD moved during the review: (unborn) -> ' "$S/unborn.err" \
  && ok "an unborn repo committed into during the review is reported as a HEAD move" \
  || bad "a first commit made during the review in an unborn repo went unnoticed: $(cat "$S/unborn.err" 2>/dev/null)"

echo "=== the tamper-check through the driver's own wiring ==="
# The same detection, reached the way a review reaches it: Main calls _tamper_capture after the input is
# collected (adversarial-review.sh Main), the lane runs, then write_artifact (report.sh, before composing the
# artifact) and ar_emit_output (report.sh, unconditionally) both call _tamper_verify, which prints once.
# The driver runs from inside the repository it reviews — the tamper-check reads the cwd's tree — and
# everything else it writes (artifact, ZUVO_HOME, spy log) is outside that repository.
# Each repository starts with an untracked file, so the expected count is exactly one changed path.
# tamper_drive <artifact path or ''> <lane> — one --single run of <lane> over a real diff, from $S/repo.
tamper_drive() {
  local art="$1" lane="$2" rc=0
  local -a art_args=()
  [ -n "$art" ] && art_args=(--artifact "$art")
  ( cd "$S/repo" && printf 'diff --git a/x.ts b/x.ts\n@@ -1 +1 @@\n-const a=1\n+const a=2\n' \
      | env ZUVO_ADVERSARIAL_TEST_HARNESS=1 ZUVO_REVIEW_TEST_PROVIDERS="$lane" MOCK_SPY_LOG="$SPY_LOG" \
          MOCK_TAMPER_FILE="$S/repo/a.txt" PATH="$LANES:$PATH" \
          bash "$AR" --mode code --single ${art_args[@]+"${art_args[@]}"} ) >"$OUT" 2>"$ERR" || rc=$?
  echo "$rc"
}
TAMPER_MSG='working tree changed during the review (1 path(s) differ from the pre-review snapshot)'

scratch tamper-driver-artifact
mkrepo "$S/repo"; echo untracked > "$S/repo/b.txt"
rc=$(tamper_drive "$S/art.txt" mock-tamper)
[ "$rc" = "0" ] && ok "a review whose lane edited the tree still completes (exit 0: detection never blocks)" || bad "the tampering run exited $rc, want 0: $(head -c 300 "$ERR")"
[ "$(grep -c . "$SPY_LOG" 2>/dev/null)" = "1" ] && ok "the tampering lane was dispatched exactly once" || bad "the tampering lane ran $(grep -c . "$SPY_LOG" 2>/dev/null || echo 0) time(s), want 1"
[ "$(grep -cxF "WARNING: $TAMPER_MSG" "$ERR")" = "1" ] \
  && ok "stderr reports the edited tree exactly once, though write_artifact and ar_emit_output both verify" \
  || bad "stderr carries the tamper warning $(grep -cF 'WARNING: working tree changed' "$ERR") time(s), want exactly 1 of [$TAMPER_MSG]: $(grep -F 'WARNING' "$ERR" | head -c 300)"
grep -qxF "tree_modified_during_review=$TAMPER_MSG" "$S/art.txt" \
  && ok "the artifact records it: tree_modified_during_review=<the same note>" \
  || bad "the artifact has no tree_modified_during_review line: $(grep -F tree_modified "$S/art.txt" 2>/dev/null | head -c 200)"
grep -qxF 'REVIEW BY: MOCK-TAMPER' "$S/art.txt" && ok "…beside the REVIEW BY: line a gate reads" || bad "the artifact has no REVIEW BY: MOCK-TAMPER line"

scratch tamper-driver-noartifact
mkrepo "$S/repo"; echo untracked > "$S/repo/b.txt"
rc=$(tamper_drive '' mock-tamper)
[ "$rc" = "0" ] && ok "without --artifact the tampering run completes (exit 0)" || bad "the tampering run without --artifact exited $rc, want 0"
[ "$(grep -cxF "WARNING: $TAMPER_MSG" "$ERR")" = "1" ] \
  && ok "without --artifact the edited tree is still reported, once (ar_emit_output's unconditional verify)" \
  || bad "without --artifact the tamper warning appears $(grep -cF 'WARNING: working tree changed' "$ERR") time(s), want 1"

scratch tamper-driver-clean
mkrepo "$S/repo"; echo untracked > "$S/repo/b.txt"
rc=$(tamper_drive "$S/art.txt" mock-spy)
[ "$rc" = "0" ] && ok "a lane that only reads completes (exit 0)" || bad "the read-only lane's run exited $rc, want 0: $(head -c 300 "$ERR")"
[ "$(grep -c . "$SPY_LOG" 2>/dev/null)" = "1" ] && ok "the read-only lane was dispatched exactly once" || bad "the read-only lane ran $(grep -c . "$SPY_LOG" 2>/dev/null || echo 0) time(s), want 1"
grep -qF 'during the review' "$ERR" && bad "an untouched tree drew a tamper warning through the driver: $(grep -F 'during the review' "$ERR" | head -c 200)" \
  || ok "an untouched tree draws no tamper warning through the driver"
[ -s "$S/art.txt" ] || bad "the read-only lane's run wrote no artifact"
grep -qF 'tree_modified_during_review=' "$S/art.txt" && bad "the artifact of an untouched tree says it was modified" \
  || ok "the artifact of an untouched tree has no tree_modified_during_review line"

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
