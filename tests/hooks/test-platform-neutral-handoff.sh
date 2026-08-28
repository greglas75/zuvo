#!/usr/bin/env bash
# A handoff line printed to the USER must name a gesture the user's platform actually has.
#
# Found 2026-08-28 by a Codex user: `zuvo:write-tests` froze its contract and printed
# "Clean continue: /clear, then …". Codex has no `/clear`, so the instruction was a dead end at the
# exact point the run depends on the human doing something. The Codex build ships skill prose
# verbatim, so a Claude-Code-only command in the source reaches every other platform unchanged.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# Lines the skill PRINTS to the user (a [HANDOFF]/[CONTEXT] marker) must not tell them to type a
# bare `/clear` without naming the non-Claude equivalent alongside it.
offenders=$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for base in ("skills", "shared"):
    for dp, dn, fn in os.walk(os.path.join(root, base)):
        for f in fn:
            if not f.endswith(".md"):
                continue
            p = os.path.join(dp, f)
            lines = open(p, errors="replace").readlines()
            for i, line in enumerate(lines, 1):
                if not re.search(r"\[(HANDOFF|CONTEXT)\]", line):
                    continue
                # An instruction can wrap, so judge the whole instruction: this line plus the next
                # two. Judging one line at a time failed the very fix it was written to protect.
                # Collapse whitespace: the phrase can wrap mid-way ("NEW\n   CONVERSATION"), and
                # matching the raw text then misses an instruction that is perfectly correct.
                window = re.sub(r"\s+", " ", "".join(lines[i - 1:i + 2]))
                if not re.search(r"(?<![\w/])/clear\b", window):
                    continue
                if re.search(r"new conversation", window, re.I):
                    continue
                bad.append("%s:%d" % (os.path.relpath(p, root), i))
print("\n".join(bad))
PY
)
if [ -z "$offenders" ]; then
  pass "no user-facing handoff tells a non-Claude user to type /clear"
else
  bad "handoff lines naming /clear with no portable alternative:"
  printf '        %s\n' $offenders
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
