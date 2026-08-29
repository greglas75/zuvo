#!/usr/bin/env bash
# Nothing runs the suite on the workstation. Not probes, not a Tier-1 mutant loop, not a native
# mutation runner — the farm takes all of it.
#
# Measured 2026-08-29, while three skill sections actively instructed otherwise: 109 local test
# processes at 421% CPU, load 34, macOS suspending the machine with `Dark Wake Thermal Emergency`,
# and a 730-mutant Stryker run dying ten minutes in because a concurrent worktree pulled shared
# node_modules out from under it. The farm was idle with ~18 free slots throughout.
#
# The measurement those sections were built on is still true — a wrapped single run costs 103.4 s
# against 1.4 s local, ~50-75x. The ERROR was the conclusion. That charge is PER INVOCATION, so
# the fix is to wrap the LOOP once, not to move the work home.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

out=$(ROOT="$ROOT" python3 "$ROOT/tests/hooks/lib/find-local-run-instructions.py" 2>/dev/null)
if [ -z "$out" ]; then
  pass "no skill instructs an agent to run a suite on the workstation"
else
  bad "instructions to run tests locally:"
  printf '        %s\n' $out
fi

# The rule must live in the include EVERY skill loads, not only in the two files that had the
# bug. refactor/write-tests/execute accept "the command that runs the suite" as an INPUT, so
# nothing in those files mentions a runner at all — a scan for bad advice finds them clean while
# the work still lands on the workstation.
if grep -q 'Where work runs: the farm, not the workstation' "$ROOT/shared/includes/env-compat.md"; then
  pass "env-compat carries the farm rule for every skill that takes a suite command"
else
  bad "env-compat lost the farm rule — skills taking a suite command have nothing to bind them"
fi

# Deleting the bad advice is not enough — the farm route must be shown where the loops live,
# or the next author re-derives "wrap each call" and lands back on 50x.
for f in "shared/includes/test-mutation-probes.md" "skills/mutation-test/SKILL.md"; do
  if grep -q 'rt --light bash -c' "$ROOT/$f" 2>/dev/null; then
    pass "$(basename "$f") shows the ONE-invocation farm form"
  else
    bad "$f no longer shows how to send the loop to the farm in one call"
  fi
done

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
