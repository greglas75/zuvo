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
# author is the same model" — a new context alone cannot supply model independence.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

fixture=$(mktemp -d) || exit 1
trap 'rm -rf "$fixture"' EXIT
scan_clean() {
  local output
  if output=$(env ROOT="$1" python3 "$ROOT/tests/hooks/lib/find-codex-dispatch-bans.py"); then
    if [ -z "$output" ]; then pass "$2"; else bad "dispatch bans detected: $output"; fi
  else
    bad "instruction detector failed for $1"
  fi
}
scan_clean "$ROOT" "no skill tells Codex it cannot dispatch"

# Include the actual built package; an empty/missing package is a detector error.
if bash "$ROOT/tests/lib/dist-build.sh" codex >"$fixture/build.log" 2>&1; then
  scan_clean "${ZUVO_DIST_ROOT:-$ROOT/dist}/codex" "built Codex package has no blanket dispatch ban"
else
  bad "Codex build failed"
  tail -20 "$fixture/build.log"
fi

# Independent negative controls: no rule can hide a broken sibling rule.
mkdir -p "$fixture/skills/example"
for phrase in \
  'Spawning agent threads / wait_agent is FORBIDDEN for pipeline stages.' \
  'CODEX SINGLE-AGENT RULE' \
  'An inline fresh-eyes pass SATISFIES an independent audit.' \
  $'An Inline fresh-eyes pass\nSATISFIES an independent audit.'; do
  printf '%s\n' "$phrase" > "$fixture/skills/example/SKILL.md"
  if out=$(env ROOT="$fixture" python3 "$ROOT/tests/hooks/lib/find-codex-dispatch-bans.py"); then
    [ -n "$out" ] && pass "isolated forbidden-policy fixture detected" || bad "detector missed $phrase"
  else
    bad "detector failed instead of identifying the fixture"
  fi
done
rm "$fixture/skills/example/SKILL.md"
if env ROOT="$fixture" python3 "$ROOT/tests/hooks/lib/find-codex-dispatch-bans.py" >/dev/null 2>&1; then
  bad "empty instruction tree falsely passed"
else
  pass "empty instruction tree cannot certify a built package"
fi

# Preserve the distinction between context isolation and model independence.
if grep -q 'same model' "$ROOT/shared/includes/env-compat.md"; then
  pass "env-compat preserves the limit of same-model independence"
else
  bad "env-compat lost the distinction between a new context and model independence"
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
