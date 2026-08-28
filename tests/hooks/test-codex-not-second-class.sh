#!/usr/bin/env bash
# Codex has native sub-agents. A skill that dispatches a MECHANICAL worker on Claude Code and
# hands the work back to the human everywhere else is treating "not Claude Code" as "cannot
# dispatch" — which is false for Codex and turns an automatic step into a manual one.
#
# Found 2026-08-28: zuvo:refactor froze its plan after 24m and printed a HANDOFF telling the user
# to open a new window and type the continue command by hand, on a harness that could have
# dispatched the executor. env-compat.md had ALREADY permitted mechanical-worker dispatch on
# codex >= 0.128; the two skills that hand off never implemented it.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

out=$(python3 - "$ROOT" <<'PY'
import os, re, sys
root = sys.argv[1]
bad = []
for dp, dn, fn in os.walk(os.path.join(root, "skills")):
    for f in fn:
        if f != "SKILL.md":
            continue
        p = os.path.join(dp, f)
        lines = open(p, errors="replace").readlines()
        for i, line in enumerate(lines, 1):
            if "[HANDOFF]" not in line:
                continue
            # Judge the whole surrounding instruction, not one line: it wraps.
            window = re.sub(r"\s+", " ", "".join(lines[max(0, i - 14):i + 3]))
            # A handoff is fine when the same instruction ALSO routes Codex to a dispatch first.
            if re.search(r"codex[^.]{0,120}dispatch", window, re.I):
                continue
            bad.append("%s:%d" % (os.path.relpath(p, root), i))
print("\n".join(bad))
PY
)
if [ -z "$out" ]; then
  pass "no skill hands work back to the human on Codex without offering dispatch first"
else
  bad "HANDOFF with no Codex dispatch path in the same instruction:"
  printf '        %s\n' $out
fi

# And the capability table must not still call Codex single-agent for everything.
if grep -q 'MECHANICAL WORKERS' "$ROOT/shared/includes/env-compat.md" 2>/dev/null; then
  pass "env-compat still distinguishes review stages from mechanical workers on Codex"
else
  bad "env-compat lost the mechanical-worker carve-out — Codex would go back to handing off"
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
