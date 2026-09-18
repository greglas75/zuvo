#!/usr/bin/env bash
# Contract for the zuvo:review → zuvo:mutation-test chain (Phase 4 step 4).
#
# Why a test for prose: the step exists because the user was typing the follow-up by hand and
# sometimes forgot. A chain that is only a paragraph gets dropped in a long session exactly the
# way the manual step did — so the three things that make it non-droppable (the invocation, the
# scope derivation, and a Validity-Gate field that makes a skip visible) are asserted here.
#
# What this test can and cannot do: it checks the CONTRACT is present and coherent in the skill
# file. It cannot prove an agent obeys it — that is what the mutation_chain field in the Validity
# Gate and the skill-eval corpus are for. Do not read a pass here as "the chain ran".
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/review/SKILL.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$SKILL" ] || { bad "skills/review/SKILL.md missing"; exit 1; }

# 1. It must INVOKE the skill, not describe it. A "consider running zuvo:mutation-test" line is
# the failure mode auto-chain-after-audit was written about.
if grep -q 'Skill(skill="zuvo:mutation-test"' "$SKILL"; then
  pass "the chain is a real Skill() invocation, not a suggestion"
else bad "no Skill(skill=\"zuvo:mutation-test\") call — a printed suggestion is what the user already forgets"; fi

# 2. The scope must be the TESTS covering the changed files, derived from the reviewed range —
# not the production files, and not a bare directory (which re-mutates twenty commits of history).
if grep -q 'REVIEWED_FROM}\.\.HEAD' "$SKILL" && grep -q 'PROD_CHANGED' "$SKILL" && grep -q 'TESTS_TOUCHED' "$SKILL"; then
  pass "scope is derived from the reviewed range, splitting tests from production files"
else bad "scope derivation missing — the step has to compute which tests cover the changed files"; fi

if grep -q 'never a bare directory' "$SKILL"; then
  pass "passing a bare directory is explicitly ruled out"
else bad "nothing stops the scope being a directory, which makes the run disproportionate to the review"; fi

# 3. A production file with no covering test must become a finding, not vanish from the scope.
# Dropping it silently is how "nothing to mutate" reads as a clean result.
if grep -q 'untested: <file>' "$SKILL" || grep -q 'untested_files' "$SKILL"; then
  pass "an uncovered production file is recorded as a finding, not dropped from scope"
else bad "a changed production file with no test can silently leave the scope"; fi

# 4. The skip must be visible. `mutation_chain:` in the Validity Gate, and a skip that names which
# trigger was false — the same rule the adversarial gate already carries.
if grep -q 'mutation_chain:' "$SKILL"; then
  pass "the Validity Gate carries a mutation_chain field"
else bad "no mutation_chain field — a skipped chain would be invisible in the gate"; fi

if grep -q 'NOT_RUN — VIOLATES_PHASE4' "$SKILL"; then
  pass "not running it where the trigger held is a named violation"
else bad "skipping the chain has no violation value, so it costs nothing to skip"; fi

# 5. The Completion Gate must list it, or the checklist can be printed complete without it.
if grep -q 'zuvo:mutation-test chained' "$SKILL"; then
  pass "the Completion Gate checklist includes the chain"
else bad "the Completion Gate can report complete while the chain never ran"; fi

# 6. The grade-over-a-tiny-denominator trap must be written down where the verdict is read.
# Measured: 129 of 712 passing runs sit on a round plan total.
if grep -q 'sampled(' "$SKILL"; then
  pass "a grade over a round plan total is read as sampled, not clean"
else bad "nothing warns that a grade over a capped plan describes a budget, not the file"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
