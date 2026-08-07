#!/usr/bin/env bash
# test-gate-runnable-without-dispatch.sh — a mandatory gate must have a path that
# RUNS on a harness that forbids sub-agent dispatch.
#
# Field report (2026-08-07): a /refactor run recorded Phase 3.6 as N/A-degraded and
# asked the user for permission, because zuvo:test-audit fans out sub-agents and the
# session carried "do not use the Agent tool unless the user asked". The agent was
# right to refuse to self-score — the gate explicitly forbids inline Q-rescoring as a
# substituted gate — but that left only two outcomes: fake a PASS, or no coverage.
#
# skills/review/SKILL.md had already solved exactly this with INLINE-SINGLE-AGENT-LOCK:
# run the role inline, label it, and CAP the verdict at degraded:same-model. The test
# gate never adopted it. This pins that a mandatory gate offers a third path, and that
# the third path stays honestly weaker than dispatch.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G="$ROOT/shared/includes/test-quality-gate.md"
R="$ROOT/skills/review/SKILL.md"

fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# ─── (a) the gate has an inline path at all ─────────────────────────────────
if [ ! -f "$G" ]; then
  bad "(a) shared/includes/test-quality-gate.md not found"
elif grep -qi 'session instruction' "$G" && grep -qi 'does NOT block this' "$G"; then
  pass "(a) a session-level no-Agent instruction is explicitly ruled out as a blocker"
else
  bad "(a) nothing rules out the session no-Agent instruction — the gate stalls and the user gets asked per-run"
fi

# The inline path must be the EXCEPTION, not an offered alternative. If the text
# presents it as a convenience, agents take it: it is strictly less work than
# dispatching, and it still prints a gate marker.
if [ -f "$G" ] && grep -qi 'no "degraded" convenience path' "$G" && grep -qi 'single exception' "$G"; then
  pass "(a2) the inline path is framed as a structural exception, not a fallback"
else
  bad "(a2) the inline path reads as an available option — it will become the default"
fi

# ─── (b) the inline path is CAPPED, not equivalent to dispatch ──────────────
# Without this the carve-out becomes a licence: run it inline, call it PASS, done.
if [ -f "$G" ] && grep -q 'degraded:same-model' "$G"; then
  pass "(b) the inline verdict is capped at degraded:same-model"
else
  bad "(b) the inline path is not capped — it would read as equivalent to an independent audit"
fi

# ─── (c) the substituted-gate prohibition SURVIVES the carve-out ────────────
# The carve-out must narrow to harness-forbidden, not delete the rule. If this
# assertion fails, the escape hatch swallowed the thing it was carved out of.
if [ -f "$G" ] && grep -q 'substituted gate' "$G" && grep -qi 'drift' "$G"; then
  pass "(c) the substituted-gate prohibition is retained and scoped to drift"
else
  bad "(c) the carve-out removed the prohibition instead of narrowing it"
fi

# ─── (d) invoking the skill authorizes the dispatch it mandates ─────────────
# The user typed /refactor; they did not separately request a fan-out and should
# not be asked per-run for a step the pipeline already requires.
if [ -f "$G" ] && grep -qi 'IS the authorization' "$G"; then
  pass "(d) invoking the calling skill is stated to authorize its mandated dispatch"
else
  bad "(d) nothing says the skill invocation authorizes its own gates — the per-run permission ask recurs"
fi

# ─── (e) review still has the pattern this was copied from ─────────────────
# If review ever loses it, the two diverge silently and this file is the tell.
if [ -f "$R" ] && grep -q 'INLINE-SINGLE-AGENT-LOCK' "$R"; then
  pass "(e) review still carries the pattern (the two stay consistent)"
else
  bad "(e) review lost INLINE-SINGLE-AGENT-LOCK — the gates now disagree on the same conflict"
fi

echo "----"
if [ "$fail" -eq 0 ]; then echo "ALL PASSED"; exit 0; else echo "SOME FAILED"; exit 1; fi
