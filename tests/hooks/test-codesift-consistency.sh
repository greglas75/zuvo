#!/usr/bin/env bash
# test-codesift-consistency.sh — a SKILL.md may not contradict the CodeSift include it loads.
#
# Why this exists, and why it asserts on a CLASS rather than on one skill:
# `shared/includes/codesift-setup.md` is a Phase-0 `MISSING -> STOP` include for the orchestrator
# skills. Twice now a skill's own prose drifted into saying the opposite of the include it had just
# been told to obey, and the lenient/wrong copy is the one the runtime actually followed:
#
#   1. `skills/refactor/SKILL.md` said "Do not index a secondary worktree" while
#      `codesift-setup.md` step 2 says to index it exactly once and explicitly retracts the ban
#      ("If those two ever disagree again, step 2 wins"). Cost on record: a run that fell back to
#      grep/cat burned 21.8M tokens (13.2% of the run), and a wrong-tree index put a CQ14 clone at
#      line 564 of a 212-line facade — i.e. the error reached a gate's output.
#   2. The same file mandated `list_repos()` while `codesift-setup.md:19` says to skip it, the
#      global rule file has it under NEVER, and refactor's own three sub-agents each say
#      "Do NOT call list_repos() — the orchestrator already did".
#
# Fixing one instance leaves the class open (memory: fix-the-class-not-the-instance), so this test
# asserts over EVERY skill, not over refactor.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INC="$ROOT/shared/includes/codesift-setup.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$INC" ] || { bad "missing include: shared/includes/codesift-setup.md"; echo "SOME FAILED"; exit 1; }

# ── 0. the include still says what this test enforces ────────────────────────
# If the include's own position ever flips, this test must fail loudly rather than keep policing a
# rule that no longer exists.
grep -q 'skip `list_repos`' "$INC" \
  && pass "include still says to skip list_repos" \
  || bad "codesift-setup.md no longer says 'skip \`list_repos\`' — re-derive this test before trusting it"
grep -q 'step 2 wins' "$INC" \
  && pass "include still carries the worktree-index retraction ('step 2 wins')" \
  || bad "codesift-setup.md lost the 'step 2 wins' retraction — re-derive this test"

# ── 1. no skill may MANDATE list_repos() ─────────────────────────────────────
# A mention is fine — "do NOT call list_repos()" is the correct thing to say. Only an unnegated
# instruction is a violation, so lines carrying a negation are excluded before judging.
offenders=""
for f in "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md; do
  [ -f "$f" ] || continue
  # strip markdown emphasis before judging: "Do **NOT** call list_repos()" is a negation, and a
  # matcher that misses it flags the very sentence that fixes the defect.
  hits=$(grep -n 'list_repos' "$f" 2>/dev/null | tr -d '*_' \
         | grep -viE "do ?n[o']?t|don't|never|skip|unless|avoid|no need|already did|owns (that|the)" || true)
  [ -n "$hits" ] && offenders="$offenders
${f#$ROOT/}: $hits"
done
if [ -z "$offenders" ]; then
  pass "no skill or agent mandates list_repos() (mentions negated everywhere)"
else
  bad "a skill/agent mandates list_repos(), contradicting codesift-setup.md:19:$offenders"
fi

# ── 2. no skill may carry the retracted worktree-index ban ───────────────────
# Matches the ban as an instruction. The include itself quotes the retracted sentence while
# retracting it, so the include is deliberately not scanned here.
banned=""
for f in "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/skills/*/references/*.md; do
  [ -f "$f" ] || continue
  hits=$(grep -niE '(do not|don.t|never) index (a |the )?(secondary |linked )?worktree' "$f" 2>/dev/null \
         | grep -viE 'used to say|retracted|no longer|step 2 wins|carried the pre-|this paragraph|which is exactly the drift' || true)
  [ -n "$hits" ] && banned="$banned
${f#$ROOT/}: $hits"
done
if [ -z "$banned" ]; then
  pass "no skill carries the retracted 'do not index a worktree' ban"
else
  bad "a skill still forbids indexing a worktree — codesift-setup.md retracted that:$banned"
fi

# ── 3. refactor resolves repo identity BEFORE the pre-scan, not after commit ─
REF="$ROOT/skills/refactor/SKILL.md"
if [ -f "$REF" ]; then
  setup_ln=$(grep -n '^### CodeSift Setup' "$REF" | head -1 | cut -d: -f1)
  prescan_ln=$(grep -n '^### Pre-Scan' "$REF" | head -1 | cut -d: -f1)
  if [ -n "${setup_ln:-}" ] && [ -n "${prescan_ln:-}" ]; then
    if sed -n "${setup_ln},${prescan_ln}p" "$REF" | grep -q 'rev-parse --show-toplevel'; then
      pass "refactor resolves TARGET_REPO in CodeSift Setup, before Pre-Scan"
    else
      bad "refactor's CodeSift Setup does not resolve repo identity before Pre-Scan (every pre-scan call is repo-scoped)"
    fi
  else
    bad "refactor SKILL.md lost its '### CodeSift Setup' / '### Pre-Scan' headings — anchor this test again"
  fi
  # the one enforcement artifact in the rewritten block must survive
  grep -q 'degraded:<the exact restriction>' "$REF" \
    && pass "refactor keeps the degraded:<restriction> telemetry string" \
    || bad "refactor lost 'degraded:<the exact restriction>' — the only machine-readable artifact in that block"
  # and it must cover the measured failure modes, not just a failed call
  grep -qiE 'slow/wedged/timed-out|slow, wedged, or times out' "$REF" \
    && pass "refactor's degraded string covers slow/wedged/timeout, not only failure" \
    || bad "refactor's degraded:<restriction> still covers only 'index_folder failed' (125s and 300s-wedge runs are on record)"
else
  bad "missing skills/refactor/SKILL.md"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
