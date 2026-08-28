#!/usr/bin/env bash
# An unscoped mutation run must not mean "mutate the entire repository".
#
# Measured 2026-08-28 on the local fleet: median mutation run 1 minute, normal scoped runs up to
# 31 minutes — but 32 runs exceeded an hour and the longest was 258 minutes, every one of them
# unscoped, mutating a 2,784-file suite to answer a question about a single module. The default
# was `full`. That is a defect in the default, not in the machine that ran it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SKILL="$ROOT/skills/mutation-test/SKILL.md"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$SKILL" ] || { bad "skills/mutation-test/SKILL.md is missing"; exit 1; }

line=$(grep -n 'Default (no arguments)' "$SKILL" | head -1 | cut -d: -f1)
if [ -z "$line" ]; then
  bad "the skill no longer states what an unscoped run does — that is how it drifted back to full before"
else
  window=$(sed -n "${line},$((line + 6))p" "$SKILL" | tr '\n' ' ')
  case "$window" in
    *CHANGED*) pass "an unscoped run defaults to the changed files" ;;
    *)         bad "unscoped default is not the changed set: ${window:0:110}" ;;
  esac
  case "$window" in
    *"equivalent to \`full"*) bad "the default is still the whole project" ;;
    *)                        pass "the default is not the whole project" ;;
  esac
fi

# `full` must remain reachable — narrowing the default is not the same as removing the capability.
if grep -q '`full`' "$SKILL"; then
  pass "an explicit full run is still available"
else
  bad "the full-project run disappeared entirely — that is a different bug, not the fix"
fi

# The per-file probes callers use must stay scoped.
PROBES="$ROOT/shared/includes/test-mutation-probes.md"
if [ -f "$PROBES" ] && grep -q -- '--mutate <file>' "$PROBES"; then
  pass "caller probes still name a single file"
else
  bad "test-mutation-probes no longer scopes to one file — callers would mutate everything"
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
