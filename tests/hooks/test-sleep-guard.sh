#!/usr/bin/env bash
# Contract for hooks/zuvo-sleep-guard.zsh — the enforcement that does NOT depend on a Codex hook.
#
# It exists because no Codex hook has ever been observed to execute on this machine
# (docs/runbook/operating.md §11), while Codex demonstrably shells out through `/bin/zsh -lc`,
# and every zsh reads ~/.zshenv. So the shell can carry the rule the hook could not.
#
# This sits in front of EVERY `sleep` in every zsh on the machine, so the cases that matter most
# are the ones where it must stay silent. Most of this file is about those.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
G="$ROOT/hooks/zuvo-sleep-guard.zsh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v zsh >/dev/null 2>&1 || { echo "SKIP: zsh not available"; exit 0; }
[ -f "$G" ] || { bad "hooks/zuvo-sleep-guard.zsh does not exist"; exit 1; }
zsh -n "$G" 2>/dev/null || { bad "the guard does not parse — it would break every zsh on the machine"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A wrapper whose ARGV contains "codex", standing in for the real parent process.
# NO `exec`: exec replaces argv, so the stub's name vanishes from the process tree and the
# simulation stops resembling the real parent, which is
# `/Applications/ChatGPT.app/Contents/Resources/codex exec …` and stays alive.
printf '#!/bin/zsh\n/bin/zsh "$@"\n' > "$TMP/codex-stub"; chmod +x "$TMP/codex-stub"
run()  { "$TMP/codex-stub" -lc "source '$G'; $1" 2>&1; }   # with a codex ancestor
bare() { zsh -lc "source '$G'; $1" 2>&1; }                  # without one

out=$(run 'sleep 25; echo CONTINUED')
case "$out" in
  *declining*) pass "a bare sleep under a codex ancestor is declined" ;;
  *) bad "the dominant polling shape was allowed: ${out:0:80}" ;;
esac
case "$out" in
  *CONTINUED*) pass "declining the delay does not kill the rest of the command" ;;
  *) bad "the command after the sleep did not run — this must never destroy work" ;;
esac

out=$(run 'i=0; until (( i>0 )); do i=1; sleep 0.1; done; echo LOOPOK')
case "$out" in
  *declining*) bad "a loop was declined — that is the exact shape the message recommends" ;;
  *LOOPOK*)    pass "a sleep inside a loop is untouched" ;;
  *)           bad "loop case produced neither outcome: ${out:0:80}" ;;
esac

out=$(run 'sleep 1; echo SETTLED')
case "$out" in
  *declining*) bad "a 1s settling pause was declined (kill -TERM; sleep 1; ps is not polling)" ;;
  *SETTLED*)   pass "a short settling pause is untouched" ;;
  *)           bad "settle case produced neither outcome: ${out:0:80}" ;;
esac

out=$(bare 'sleep 0.2 && echo NORMAL')
case "$out" in
  *declining*) bad "it fired with NO codex ancestor — it must not touch ordinary shells or scripts" ;;
  *NORMAL*)    pass "no codex ancestor, no interference" ;;
  *)           bad "non-codex case produced neither outcome: ${out:0:80}" ;;
esac

mkdir -p "$HOME/.zuvo"; touch "$HOME/.zuvo/no-sleep-guard"
out=$(run 'sleep 0.2; echo OFF')
rm -f "$HOME/.zuvo/no-sleep-guard"
case "$out" in
  *declining*) bad "the off switch was ignored — a guard that cannot be turned off gets ripped out" ;;
  *OFF*)       pass "~/.zuvo/no-sleep-guard disables it completely" ;;
  *)           bad "off-switch case produced neither outcome: ${out:0:80}" ;;
esac

out=$(run 'sleep abc 2>/dev/null; echo ARGOK')
case "$out" in
  *ARGOK*) pass "a non-numeric argument is passed through, not judged" ;;
  *)       bad "a malformed sleep argument broke the wrapper: ${out:0:80}" ;;
esac

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
