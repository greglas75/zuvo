#!/usr/bin/env bash
#
# test-verify-review-claims.sh — the transcript-vs-claims verifier must ACCUSE a fabricated
# Validity Gate and must NEVER accuse an honest one.
#
# The second property is the load-bearing one: the first version of this verifier picked the
# newest transcript by mtime and immediately false-accused a real review (two sessions in one
# repo shared an mtime). A checker that cries wolf gets ignored, which is strictly worse than
# having no checker. These tests lock both directions.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
V="$ROOT/scripts/verify-review-claims.py"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail=0
pass() { echo "PASS: $1"; }
bad()  { echo "FAIL: $1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: verify-review-claims (no python3)"; exit 0; }
[ -f "$V" ] || { bad "scripts/verify-review-claims.py missing"; echo "=== RESULT ==="; echo "SOME FAILED"; exit 1; }

# ── fixtures ────────────────────────────────────────────────────────────────
# empty transcript: a session where nothing at all was dispatched
printf '{"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]}}\n' > "$TMP/empty.jsonl"

# honest transcript: two real Agent dispatches + one --multi adversarial Bash call
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"behavior audit"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"cq audit"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff | adversarial-review --multi --mode code"}}]}}'
} > "$TMP/honest.jsonl"

CLAIMS_2='tier2_subagents:
  behavior_auditor: DISPATCHED(m1)
  cq_auditor: DISPATCHED(m2)
adversarial:
  passes_run: 1
  self_review_flag: yes — used --multi'

# ── 1. fabricated claims vs an empty transcript MUST be accused ─────────────
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/empty.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "DISAGREEMENT"; then
  pass "fabricated DISPATCHED/passes_run claims are accused (exit 1)"
else
  bad "fabrication NOT accused (rc=$rc): $out"
fi

# ── 2. honest claims vs a matching transcript MUST pass clean ──────────────
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/honest.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "consistent with the transcript"; then
  pass "honest claims backed by real tool calls are NOT accused (exit 0)"
else
  bad "FALSE ACCUSATION against an honest review (rc=$rc): $out"
fi

# ── 3. the self-review --multi rule is actually checked ────────────────────
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"a"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff | adversarial-review --rotate --mode code"}}]}}'
} > "$TMP/norotate.jsonl"
out="$(printf 'tier2_subagents:\n  a: DISPATCHED(m)\nadversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/norotate.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q -- "--multi"; then
  pass "claiming self-review --multi without a --multi invocation is accused"
else
  bad "self-review --multi claim not checked (rc=$rc): $out"
fi

# ── 4. a missing transcript must SKIP cleanly, never accuse ────────────────
# NOTE: do NOT test this with a "surely absent" anchor string — the transcript contains the
# conversation, so an anchor merely MENTIONED in the session matches itself (this tool's own
# first run of this test proved it). Exercise the no-evidence path from a cwd that has no
# transcript directory at all instead.
out="$(cd "$TMP" && printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SKIP"; then
  pass "absent evidence SKIPs (never accuses on missing data)"
else
  bad "missing-transcript path did not SKIP cleanly (rc=$rc): $out"
fi

# ── 5. the skill must actually tell agents to run it ───────────────────────
if grep -q 'verify-review-claims.py' "$ROOT/skills/review/SKILL.md"; then
  pass "review/SKILL.md wires the verifier into the Validity Gate"
else
  bad "review/SKILL.md no longer references verify-review-claims.py — the check is orphaned"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
