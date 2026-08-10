#!/usr/bin/env bash
# test-gate-dispatch-authorization.sh — a skill that MANDATES the test-quality
# gate must also LOAD the include and carry the dispatch-authorization rule at
# its own call site.
#
# Field failures under contract (2026-08-07 and 2026-08-08, two different
# sessions, two different skills):
#
#   "zuvo:test-audit was not dispatched. This session prohibits the Agent tool,
#    and the skill says inline Q-rescoring is an invalid substitute — so Phase
#    3.6 is recorded WARN:substituted-inline, not PASS."
#
# The authorization text ("invoking this skill IS the request, so a session-level
# 'do not spawn agents unless asked' does not apply") lived ONLY in
# shared/includes/test-quality-gate.md. Every skill that mandates the gate merely
# POINTED at that file without listing it in Mandatory File Loading — so an agent
# reached the gate having never read the paragraph that authorizes it, applied
# the session's generic no-subagents rule, and self-scored instead. It then
# invented `WARN:substituted-inline`, a value no vocabulary defines: the gate was
# reported as satisfied by the very substitution it forbids.
#
# Fixing the include alone does not fix this — that was the first (failed)
# attempt. An include nobody loads changes nothing. Hence BOTH halves are
# asserted, for EVERY skill that mandates the gate, so skill #7 cannot be added
# with the same hole.
#
# STANDALONE: run-all.sh globs this directory and runs each file directly.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INCLUDE="shared/includes/test-quality-gate.md"
# The load-line grammar accepted by any of the three block styles in use:
# numbered "-- READ/MISSING", numbered "-- [READ | MISSING -> WARN]", or a
# prose list of backticked paths.
# A load DECLARATION, in any of the block styles in use: numbered
# "-- READ/MISSING", numbered "-- [READ | MISSING -> WARN]", or a lazy entry
# that binds the include to a phase ("Phase 4.5 -- `...test-quality-gate.md`:").
# A bare "see test-quality-gate.md" in prose is NOT a declaration and must not
# satisfy (b) -- that non-declaration is exactly what shipped the field failure.
LOAD_RE='shared/includes/test-quality-gate\.md`?[[:space:]]*(--|\(|:)'
# A lazy entry whose line also names the phase means the include is read AT the
# point of use, so the local repetition in (c) is redundant there.
LAZY_RE='Phase[[:space:]]*[0-9.]+[^\n]*shared/includes/test-quality-gate\.md'
RULE='Dispatch is already authorized'

fail=0
pass=0
check() { # check <label> <condition-rc>
  if [ "$2" -eq 0 ]; then pass=$((pass+1)); echo "  PASS  $1"
  else fail=$((fail+1)); echo "  FAIL  $1"; fi
}

echo "== gate dispatch-authorization contract =="

# EVERY skill that mandates ANY delegation — a sub-agent, a fan-out, another
# zuvo skill, the adversarial gate — must carry the authorization rule. Scoping
# this to the test-quality gate alone was the 2026-08-09 miss: that fix landed,
# and the very next day `zuvo:plan` skipped its Architect/Tech-Lead/QA fan-out
# AND its dedicated plan-reviewer, citing the same session policy, because
# `plan` was never in scope. One instance was fixed; the class was not.
DELEGATES='DISPATCH [A-Za-z]|dispatch (a |an |the |[0-9]+ )?[a-z]*[[:space:]]*(sub-)?agents?|fan-out|Agent tool|subagent_type|agents/[a-z-]+\.md|Skill\((zuvo:)?[a-z-]+\)|adversarial-review|cross-model'

# Derived from the tree, never hardcoded — a new skill is covered the moment it
# is added, which is the only way this stops recurring.
mandating=""
for f in "$ROOT"/skills/*/SKILL.md; do
  grep -Eiq "$DELEGATES" "$f" || continue
  mandating="$mandating $(basename "$(dirname "$f")")"
done

# (a) the premise — if the tree scan finds almost nothing, every per-skill
#     assertion below passes vacuously and this file becomes a decoration.
n=$(printf '%s\n' $mandating | tr ' ' '\n' | grep -c . || true)
[ "${n:-0}" -ge 30 ]
check "(a) at least 30 skills mandate delegation (found ${n:-0}) — premise not stale" $?

# (b) THE CLASS: every delegating skill carries the rule in its own text. Counted
#     rather than printed per-skill so the output stays readable at ~47 skills;
#     the failure message names every offender, which is what a fix needs.
missing=""
for s in $mandating; do
  grep -q "$RULE" "$ROOT/skills/$s/SKILL.md" || missing="$missing $s"
done
[ -z "$missing" ]
check "(b) all $n delegating skills carry the dispatch-authorization rule —${missing:- none missing}" $?

# (c) the test-quality gate keeps its stricter, older contract: the include must
#     be a LOAD DECLARATION, not a prose mention, in every skill that mandates it.
for f in "$ROOT"/skills/*/SKILL.md; do
  grep -q 'test-quality-gate\.md' "$f" || continue
  s="$(basename "$(dirname "$f")")"
  grep -Eq "$LOAD_RE" "$f"
  check "(c) $s declares $INCLUDE in its file-loading block" $?
done

# (d) the include remains the single source of truth the local copies point at —
#     if it ever loses the rule, the local repetitions become unbacked claims.
# The include's own heading uses its own wording; pin THAT, not the skills' phrasing.
grep -q 'Dispatch is authorized' "$ROOT/$INCLUDE"
check "(d) $INCLUDE itself still carries the rule" $?

# (e) the fabricated verdict stays fabricated. Every mention of it in a skill is
#     supposed to be the PROHIBITION; a naive "does the string appear" check would
#     match that prohibition and be permanently red. So assert the framing instead:
#     each mention must sit on a line that also names it as undefined. A future
#     edit that legitimizes the value drops that clause and goes red here.
bad=$(grep -rhn 'substituted-inline' "$ROOT"/skills/*/SKILL.md "$ROOT/$INCLUDE" 2>/dev/null \
        | grep -vc 'no vocabulary defines' || true)
[ "${bad:-0}" -eq 0 ]
check "(e) every 'substituted-inline' mention is a prohibition, not a permitted value (${bad:-0} stray)" $?

echo "  ---- $pass passed, $fail failed"
[ "$fail" -eq 0 ] || exit 1
