#!/usr/bin/env bash
# A skill must not stop mid-run to ask permission for something it is already authorised to do.
#
# Found 2026-08-28: zuvo:mutation-test refused to start because the tree was dirty, and the dirty
# files were the pipeline's OWN output — the test zuvo:write-tests had just written, plus
# memory/coverage.md — then asked "shall I commit these and continue?". A gate firing on the work
# it was invoked to measure, and a question whose answer is always yes.
#
# Asking is still correct before something IRREVERSIBLE (deleting a worktree that holds
# uncommitted work, merging over it). This test draws that line and nothing narrower.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

out=$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
IRREVERSIBLE = re.compile(r"irreversible|delete|remove the worktree|destroy|merge", re.I)
bad = []
for dp, dn, fn in os.walk(os.path.join(root, "skills")):
    for f in fn:
        if f != "SKILL.md":
            continue
        p = os.path.join(dp, f)
        lines = open(p, errors="replace").readlines()
        for i, line in enumerate(lines, 1):
            # "uncommitted / dirty …" followed closely by "ask the user"
            window = re.sub(r"\s+", " ", "".join(lines[max(0, i - 1):i + 4]))
            if not re.search(r"uncommitted|dirty tree|not clean", window, re.I):
                continue
            if not re.search(r"ask (the )?user|STOP and ask", window, re.I):
                continue
            # A NEGATED instruction is the opposite of the defect: "Do not ask the user" is the
            # behaviour this test wants. Matching the verb without its negation flagged
            # skills/pentest as an offender for saying exactly the right thing.
            if re.search(r"(do not|don't|never|without) (ask|stop)", window, re.I):
                continue
            # Asking before something irreversible is correct — look wide enough to SEE it: the
            # operation is often announced in a heading a few lines below the warning.
            wide = re.sub(r"\s+", " ", "".join(lines[max(0, i - 6):i + 14]))
            if IRREVERSIBLE.search(wide):
                continue
            bad.append("%s:%d" % (os.path.relpath(p, root), i))
print("\n".join(sorted(set(bad))))
PY
)
if [ -z "$out" ]; then
  pass "no skill blocks on a dirty tree and asks permission for a reversible step"
else
  bad "dirty-tree gates that stop to ask, with nothing irreversible at stake:"
  printf '        %s\n' $out
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
