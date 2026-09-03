#!/usr/bin/env bash
# Codex has sub-agents. No skill may tell it otherwise.
#
# This is the THIRD time the same wording has been removed. It keeps coming back because the
# measurement behind it was real — a 28-session forensics run in July 2026 recorded ~88 h of
# 30 s busy-polls and 19.5 h of orchestrator dead-air on the pre-v2 `wait_agent` architecture —
# and a real measurement written as a blanket ban outlives the thing it measured.
#
# What the ban costs, observed 2026-09-03 in a live Codex session: "nie będę używał subagentów,
# bo oba skille nakazują tryb single-agent". The agent was reading `execute`'s
# "🔒 CODEX HARD OVERRIDE — SINGLE-AGENT ONLY (read this FIRST, it wins over everything below)"
# and doing exactly what it said, while `~/.codex/agents/` held the profiles this repo's own
# Codex build had generated for it.
#
# The line that survives is not "Codex cannot dispatch" but "a codex thread reviewing a codex
# author is the same model" — which is why REVIEW roles run inline and MECHANICAL workers do not.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

out=$(env ROOT="$ROOT" python3 "$ROOT/tests/hooks/lib/find-codex-dispatch-bans.py" 2>/dev/null)
if [ -z "$out" ]; then
  pass "no skill tells Codex it cannot dispatch"
else
  bad "blanket single-agent bans still present:"
  printf '        %s\n' $out
fi

# The carve-out that must SURVIVE: review stages are same-model and stay inline. Deleting the ban
# without keeping this turns a correct rule into an absent one.
if grep -q 'same model' "$ROOT/shared/includes/env-compat.md"; then
  pass "env-compat still says why review stages stay sequential on Codex"
else
  bad "env-compat lost the same-model reason — review independence would silently become a thread"
fi

# And the capability table must not contradict the section below it. That contradiction is what an
# agent resolves in favour of the table, because the table is what it reads first.
if grep -q 'Single-agent sequential' "$ROOT/shared/includes/env-compat.md"; then
  bad "the capability table still calls Codex single-agent, contradicting its own Codex section"
else
  pass "the capability table agrees with the Codex section"
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
