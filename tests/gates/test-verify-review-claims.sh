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

# ── 5. a `--help` probe is NOT a review pass ───────────────────────────────
# review/SKILL.md itself recommends `adversarial-review --help | grep -- --multi` to check for the
# flag. A substring match counted that probe as a completed --multi pass, so the tool CLEARED the
# exact fabricated claim it exists to catch. Command-position + --help exclusion closes it.
{
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"adversarial-review --help | grep -- --multi"}}]}}'
  printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"grep -rn adversarial-review scripts/"}}]}}'
} > "$TMP/probe-only.jsonl"
out="$(printf 'adversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/probe-only.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "ZERO"; then
  pass "a --help probe / grep mention does NOT count as an adversarial pass"
else
  bad "mention-only commands were counted as real passes (rc=$rc): $out"
fi

# ── 6. a real invocation behind env vars and a pipe IS counted ─────────────
# guards the opposite direction of check 5: the anchored regex must still match the real shape
# the skills use (`git diff | ZUVO_REVIEW_TIMEOUT=240 adversarial-review --multi ...`).
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff a..b | ZUVO_REVIEW_TIMEOUT=240 adversarial-review --multi --mode code"}}]}}' > "$TMP/real-invoke.jsonl"
out="$(printf 'adversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/real-invoke.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "(--multi: 1)"; then
  bad_multi=0
else
  bad_multi=1
fi
[ "$bad_multi" -eq 0 ] \
  && pass "a real piped invocation with env prefix is counted (no false accusation)" \
  || bad "real invocation behind a pipe/env prefix was NOT counted (rc=$rc): $out"

# ── 6b. a backslash-continued invocation keeps its flags ───────────────────
# The `args` capture used to stop at the newline, so `adversarial-review \<NL>  --multi …`
# captured only `\` — a REAL --multi pass scored 0 and the verifier ACCUSED an honest reviewer of
# DID_NOT_USE_--multi (Validity Gate -> FAIL, verdict -> INCOMPLETE). An undercount is the one
# failure mode this tool's design forbids: it is trusted precisely BECAUSE it never under-counts.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"git diff a..b | adversarial-review \\\n  --multi --mode code"}}]}}' > "$TMP/cont-invoke.jsonl"
out="$(printf 'adversarial:\n  passes_run: 1\n  self_review_flag: yes — used --multi\n' \
  | python3 "$V" --claims - --transcript "$TMP/cont-invoke.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "(--multi: 1)"; then
  pass "a backslash-continued invocation keeps --multi (no false accusation)"
else
  bad "backslash-continued --multi was lost -> false accusation (rc=$rc): $out"
fi

# ── 7. partial mismatch (some evidence, not enough) is accused ─────────────
# the elif branches: observed > 0 but fewer than claimed. Previously untested — a bug here would
# only surface as a silent clear on a half-done review.
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Agent","input":{"description":"one only"}}]}}' > "$TMP/partial.jsonl"
out="$(printf 'tier2_subagents:\n  a: DISPATCHED(m1)\n  b: DISPATCHED(m2)\n  c: DISPATCHED(m3)\n' \
  | python3 "$V" --claims - --transcript "$TMP/partial.jsonl" --strict 2>&1)"; rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "transcript holds 1"; then
  pass "partial dispatch evidence (3 claimed, 1 observed) is accused"
else
  bad "partial-mismatch branch not exercised/working (rc=$rc): $out"
fi

# ── 8. exit code 2 is a real, distinct contract ────────────────────────────
# the docstring promises 0/1/2; exit 1 means "disagreement", so a usage error MUST NOT reuse it.
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/nope.jsonl" 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && pass "missing --transcript exits 2 (usage), not 1" \
                || bad "missing --transcript did not exit 2 (rc=$rc): $out"
out="$(python3 "$V" --claims "$TMP/no-such-claims.md" --transcript "$TMP/honest.jsonl" 2>&1)"; rc=$?
if [ "$rc" -eq 2 ] && ! printf '%s' "$out" | grep -q "Traceback"; then
  pass "missing --claims exits 2 with a message, not a traceback"
else
  bad "missing --claims crashed or used the wrong exit code (rc=$rc): $out"
fi

# ── 9. --anchor filtering actually filters ─────────────────────────────────
# the mechanism the docstring calls the tie-to-THIS-review; never exercised before.
ANCHDIR="$TMP/proj"; mkdir -p "$ANCHDIR"
out="$(cd "$ANCHDIR" && printf '%s' "$CLAIMS_2" | python3 "$V" --claims - \
        --anchor 'anchor-that-no-transcript-holds-9f3a2b' 2>&1)"; rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "SKIP"; then
  pass "--anchor with no matching transcript SKIPs (never accuses)"
else
  bad "--anchor no-match path did not SKIP (rc=$rc): $out"
fi

# ── 10. a malformed tool_use.input must not crash the verifier ─────────────
printf '%s\n' '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":"not-a-dict"}]}}' > "$TMP/malformed.jsonl"
out="$(printf '%s' "$CLAIMS_2" | python3 "$V" --claims - --transcript "$TMP/malformed.jsonl" 2>&1)"; rc=$?
if [ "$rc" -ne 2 ] && ! printf '%s' "$out" | grep -q "Traceback"; then
  pass "a non-dict tool_use.input is skipped, not a crash"
else
  bad "malformed transcript record crashed the verifier (rc=$rc): $out"
fi

# ── 11. the skill must actually tell agents to run it ──────────────────────
if grep -q 'verify-review-claims.py' "$ROOT/skills/review/SKILL.md"; then
  pass "review/SKILL.md wires the verifier into the Validity Gate"
else
  bad "review/SKILL.md no longer references verify-review-claims.py — the check is orphaned"
fi

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
