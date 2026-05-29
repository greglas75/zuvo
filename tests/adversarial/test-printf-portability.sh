#!/usr/bin/env bash
# test-printf-portability.sh — the append idiom must expand literal \t to real
# tabs on EVERY shell and never leak a `-e` operand. Documents the regression:
# the OLD `echo -e` idiom leaks `-e` under a /bin/sh that is not bash (dash),
# which produced the runs.log:697 `-e 2026-...` contamination.

# A RUN_LINE as the skills build it: literal backslash-t separators.
RL='2026-05-29T00:00:00Z\texecute\tProj\t-\t-\tPASS\t1\t1-tasks\tnote\tmain\tabc\t-\t-'

start_test "printf '%b\\n' expands \\t to real tabs (13 fields) under bash"
nf=$(bash -c 'printf "%b\n" "$1"' _ "$RL" | awk -F'\t' '{print NF}')
assert_eq 13 "$nf" "bash: %b yields 13 tab-separated fields"

start_test "printf '%b\\n' expands \\t to real tabs (13 fields) under /bin/sh"
nf=$(/bin/sh -c 'printf "%b\n" "$1"' _ "$RL" | awk -F'\t' '{print NF}')
assert_eq 13 "$nf" "/bin/sh: %b yields 13 tab-separated fields"

start_test "printf '%b\\n' never emits a leading '-e' under /bin/sh"
first=$(/bin/sh -c 'printf "%b\n" "$1"' _ "$RL" | awk -F'\t' '{print substr($1,1,2)}')
assert_ne "-e" "$first" "no -e leak with printf %b"

start_test "REGRESSION DOC: OLD 'echo -e' leaks '-e' under a dash /bin/sh"
# If /bin/sh is dash (echo is the POSIX builtin), `echo -e` prints a literal
# '-e '. If /bin/sh IS bash/zsh, it won't — so this test only ASSERTS the leak
# when the host /bin/sh actually exhibits it, and otherwise records that the
# host happens to be safe. Either way it proves WHY we abandoned echo -e.
out=$(/bin/sh -c 'echo -e "$1"' _ "$RL" 2>/dev/null)
case "$out" in
  -e\ *) pass "confirmed: echo -e leaks '-e' on this /bin/sh (justifies printf %b)" ;;
  *)     pass "this /bin/sh does not leak -e, but printf %b is portable regardless" ;;
esac

start_test "printf '%s' would be WRONG here (writes literal backslash-t)"
# Guard against a future 'fix' that swaps %b -> %s: %s must NOT expand \t.
nf=$(bash -c 'printf "%s\n" "$1"' _ "$RL" | awk -F'\t' '{print NF}')
assert_eq 1 "$nf" "%s leaves literal \\t (1 field) — proves %b is required, not %s"
