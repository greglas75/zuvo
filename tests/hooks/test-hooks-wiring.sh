#!/usr/bin/env bash
# Task 10 — assert block-no-verify + single-site Stop nudge wired across all
# harness configs, correct shapes, no existing hook dropped, valid JSON.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CLAUDE="$ROOT/hooks/hooks.json"
CODEX="$ROOT/hooks/hooks.codex.json"
ANTIG="$ROOT/hooks/hooks.antigravity.json"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v jq >/dev/null 2>&1 || { echo "FAIL: jq required for this test"; exit 1; }

# all valid JSON
for f in "$CLAUDE" "$CODEX" "$ANTIG"; do
  jq -e . "$f" >/dev/null 2>&1 && pass "valid JSON: ${f##*/}" || bad "invalid JSON: ${f##*/}"
done

cmds() { jq -r '.. | .command? // empty' "$1" 2>/dev/null; }
has()  { cmds "$1" | grep -q "$2"; }
countall() { cat "$CLAUDE" "$CODEX" "$ANTIG" | jq -rs '.[] | .. | .command? // empty' 2>/dev/null | grep -c "$1"; }

# block-no-verify present in all three
has "$CLAUDE" 'block-no-verify.sh' && pass "Claude: block-no-verify wired" || bad "Claude: block-no-verify missing"
has "$CODEX"  'block-no-verify.sh' && pass "Codex: block-no-verify wired"  || bad "Codex: block-no-verify missing"
has "$ANTIG"  'block-no-verify.sh' && pass "Antigravity: block-no-verify wired" || bad "Antigravity: block-no-verify missing"

# correct shape: Claude PreToolUse Bash, Codex PreToolUse Bash, Antigravity BeforeTool run_shell_command
jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command|test("block-no-verify"))' "$CLAUDE" >/dev/null 2>&1 \
  && pass "Claude: block-no-verify under PreToolUse/Bash" || bad "Claude: block-no-verify wrong matcher"
jq -e '.hooks.PreToolUse[] | select(.matcher=="Bash") | .hooks[] | select(.command|test("block-no-verify"))' "$CODEX" >/dev/null 2>&1 \
  && pass "Codex: block-no-verify under PreToolUse/Bash" || bad "Codex: block-no-verify wrong matcher"
jq -e '.hooks.BeforeTool[] | select(.matcher=="run_shell_command") | .hooks[] | select(.command|test("block-no-verify"))' "$ANTIG" >/dev/null 2>&1 \
  && pass "Antigravity: block-no-verify under BeforeTool/run_shell_command" || bad "Antigravity: block-no-verify wrong matcher"

# existing gates still present (not dropped)
for f in "$CLAUDE" "$CODEX" "$ANTIG"; do
  has "$f" 'pre-push-gate.sh' && pass "${f##*/}: pre-push-gate preserved" || bad "${f##*/}: pre-push-gate dropped"
  has "$f" 'pre-commit-adversarial-gate.sh' && pass "${f##*/}: commit-gate preserved" || bad "${f##*/}: commit-gate dropped"
done
# Claude session-start + rewake hooks not dropped
has "$CLAUDE" 'run-hook.cmd' && pass "Claude: session-start preserved" || bad "Claude: session-start dropped"
has "$CLAUDE" 'zuvo-rewake-reset.sh' && pass "Claude: rewake-reset preserved" || bad "Claude: rewake-reset dropped"
has "$CLAUDE" 'zuvo-rewake-on-failure.sh' && pass "Claude: rewake-on-failure preserved" || bad "Claude: rewake-on-failure dropped"

# Stop nudge: present in Claude Stop, absent in Codex/Antigravity, EXACTLY one site total
jq -e '.hooks.Stop[] | .hooks[] | select(.command|test("zuvo-stop-pipeline-gate"))' "$CLAUDE" >/dev/null 2>&1 \
  && pass "Claude: Stop nudge in Stop array" || bad "Claude: Stop nudge missing from Stop"
# Claude Stop nudge must be async:false so exit 2 is honored
jq -e '.hooks.Stop[] | .hooks[] | select(.command|test("zuvo-stop-pipeline-gate")) | select(.async==false)' "$CLAUDE" >/dev/null 2>&1 \
  && pass "Claude: Stop nudge async:false (exit 2 honored)" || bad "Claude: Stop nudge not async:false"
has "$CODEX" 'zuvo-stop-pipeline-gate' && bad "Codex: Stop nudge should be ABSENT (no Stop support)" || pass "Codex: Stop nudge correctly absent [STOP-UNSUPPORTED:codex]"
has "$ANTIG" 'zuvo-stop-pipeline-gate' && bad "Antigravity: Stop nudge should be ABSENT (no Stop support)" || pass "Antigravity: Stop nudge correctly absent [STOP-UNSUPPORTED:antigravity]"

n=$(countall 'zuvo-stop-pipeline-gate')
[ "$n" -eq 1 ] && pass "single Stop registration across all configs (count=1)" || bad "Stop nudge registered $n times (must be exactly 1)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
