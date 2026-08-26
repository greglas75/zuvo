#!/usr/bin/env bash
# Contract for scripts/zuvo-home/poll-cost — the tool that measures what waiting costs.
#
# Why this has a test at all: the tool exists to verify that a guidance change actually moved
# something, so a tool that silently miscounts would validate a no-op. Two failure modes are
# specifically pinned because both already happened while writing it:
#
#   1. Attributing Codex polls by matching `zuvo[:/]<word>` anywhere in a tool call. That matches
#      the helper path `~/.zuvo/append-retro` and the output dir `zuvo/contracts`, producing
#      "skills" that do not exist. A path is not an invocation.
#   2. Counting a blocking wait as a poll. `until ...; do sleep 30; done` is the DESIRED shape —
#      scoring it as waste would push runs away from the fix.
#
# bash 3.2-compatible (macOS default). Accumulate-and-report.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/poll-cost"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
[ -f "$BIN" ] || { bad "scripts/zuvo-home/poll-cost does not exist"; exit 1; }

python3 -c "import ast,sys; ast.parse(open('$BIN').read())" 2>/dev/null \
  && pass "the tool parses" || bad "the tool has a syntax error"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_ORIG="$HOME"
export HOME="$TMP"
mkdir -p "$TMP/.claude/projects/probe" "$TMP/.codex/sessions/2026/08/26"

# ── a Claude Code session: one Skill, then one of each waiting shape ──────────
cc="$TMP/.claude/projects/probe/s.jsonl"
emit() { printf '%s\n' "$1" >> "$cc"; }
emit '{"message":{"content":[{"type":"tool_use","name":"Skill","input":{"skill":"zuvo:refactor"}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"sleep 5; cat out"}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"until [ -f d ]; do sleep 30; done"}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"Monitor","input":{}}]}}'
emit '{"message":{"content":[{"type":"tool_use","name":"BashOutput","input":{}}]}}'

out="$(python3 "$BIN" 2>&1)"

echo "$out" | grep -q "zuvo:refactor" \
  && pass "a Claude Code poll is attributed to the skill that was running" \
  || bad "the running skill was not attributed: $(echo "$out" | head -3)"

# 2 polls (sleep-then-check + BashOutput), 1 blocking, 1 event — the three must not be conflated.
line=$(echo "$out" | awk '/^zuvo:refactor/{print; exit}')
set -- $line
[ "${2:-}" = "2" ] && pass "sleep-then-check and BashOutput both count as polls" \
  || bad "poll count was '${2:-}' (want 2): $line"
[ "${3:-}" = "1" ] && pass "a blocking until-loop is counted as blocking, not as a poll" \
  || bad "blocking count was '${3:-}' (want 1): $line"
[ "${4:-}" = "1" ] && pass "Monitor is counted as event-driven" \
  || bad "event count was '${4:-}' (want 1): $line"

# ── Codex: a helper PATH must not be read as a skill invocation ───────────────
cx="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T10-00-00-x.jsonl"
{
  # A call that merely mentions ~/.zuvo/append-retro and zuvo/contracts. Neither is a skill.
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"~/.zuvo/append-retro; ls zuvo/contracts\"}"}}'
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"wait","arguments":"{\"yield_time_ms\":30000}"}}'
} > "$cx"
out2="$(python3 "$BIN" 2>&1)"
echo "$out2" | grep -qE "zuvo:(append-retro|contracts)" \
  && bad "a helper path was reported as a skill — the invented-skill bug is back" \
  || pass "a helper path is not mistaken for a skill invocation"

# ── --since must actually exclude ────────────────────────────────────────────
out3="$(python3 "$BIN" --since 2299-01-01 2>&1)"
echo "$out3" | grep -q "nothing recorded" \
  && pass "--since excludes sessions older than the cutoff" \
  || bad "--since did not filter: $(echo "$out3" | head -4)"

export HOME="$HOME_ORIG"
echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
