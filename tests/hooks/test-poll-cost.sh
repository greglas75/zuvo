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

# ── Codex: a blocking command must be COUNTED, not invisible ─────────────────
# The first version classified only `wait`, so the blocking and event columns were structurally
# zero for Codex — and a baseline was published saying "in Codex every wait is a poll", which
# described the scanner, not Codex. Zero has to be a measurement before it can be a finding.
cx2="$TMP/.codex/sessions/2026/08/26/rollout-2026-08-26T11-00-00-y.jsonl"
{
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"until [ -f done ]; do sleep 30; done\"}"}}'
  printf '%s\n' '{"payload":{"type":"custom_tool_call","name":"exec","arguments":"{\"cmd\":\"rt --wait 12345\"}"}}'
} > "$cx2"
out4="$(python3 "$BIN" 2>&1)"
cxline=$(echo "$out4" | awk '/^=== Codex/{f=1} f&&/^TOTAL/{print; exit}')
set -- $cxline
[ "${3:-0}" -ge 2 ] 2>/dev/null \
  && pass "Codex blocking commands are counted as blocking, not silently dropped" \
  || bad "Codex blocking column was '${3:-}' with 2 blocking commands present: $cxline"

# ── --since must actually exclude ────────────────────────────────────────────
out3="$(python3 "$BIN" --since 2299-01-01 2>&1)"
echo "$out3" | grep -q "nothing recorded" \
  && pass "--since excludes sessions older than the cutoff" \
  || bad "--since did not filter: $(echo "$out3" | head -4)"

# ── --since dates a session by ITS OWN timestamp, not the file's mtime ───────
# A session left open across the cutoff has an mtime weeks after it began; dating it that way
# files its whole pre-change history into the "after" bucket — corrupting the one comparison this
# tool exists to produce. Verified on real data: a transcript starting 2026-07-28 with an mtime of
# 2026-08-24, 27 days out.
old_sess="$TMP/.claude/projects/probe/old.jsonl"
printf '%s\n' '{"type":"user","timestamp":"2020-01-01T00:00:00.000Z","message":{"role":"user","content":"x"}}' > "$old_sess"
printf '%s\n' '{"message":{"content":[{"type":"tool_use","name":"BashOutput","input":{}}]}}' >> "$old_sess"
touch "$old_sess"                       # mtime = now, session start = 2020
out5="$(python3 "$BIN" --since 2026-01-01 2>&1)"
echo "$out5" | grep -q "probe\|BashOutput" && true
before=$(echo "$out5" | awk '/^=== Claude Code/{f=1} f&&/^TOTAL/{print $2; exit}')
rm -f "$old_sess"
after_removed=$(python3 "$BIN" --since 2026-01-01 2>&1 | awk '/^=== Claude Code/{f=1} f&&/^TOTAL/{print $2; exit}')
[ "${before:-0}" = "${after_removed:-0}" ] \
  && pass "a freshly-touched session that STARTED before the cutoff is excluded" \
  || bad "mtime leaked a pre-cutoff session into the filtered run ($before vs $after_removed)"

export HOME="$HOME_ORIG"
echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
