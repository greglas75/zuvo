#!/usr/bin/env bash
# An external analysis tool is UNAVAILABLE only after it was RUN and failed.
#
# 2026-09-05, architecture review of tgm-survey-platform:
#   | madge / jscpd | UNAVAILABLE | Not installed in this checkout; native substitutes used |
# Both answer immediately in that checkout and the skill's own step names `npx madge`. Neither was
# ever invoked: the agent looked for them in package.json, found nothing, and borrowed
# `UNAVAILABLE` — a status the shared vocabulary defines only for "CodeSift MCP not present in the
# tool list at all". Three dimensions (A1/A3/A4) dropped to a lexical approximation for no reason.
#
# Two things must hold so it cannot repeat: the fetched-on-demand tools carry `--yes` (without it
# npx prompts, and a prompt in a non-interactive shell is indistinguishable from absence), and the
# shared include states that availability is measured by running, not by looking.
#
# Pure file analysis — no git state, no ~/.claude, no ~/.zuvo — so unlike most of this directory
# it is valid on the farm (docs/runbook/testing.md §5).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# Scoped to tools that are NOT project dependencies. `npx vitest` / `npx stryker` resolve from the
# repo's own node_modules and need no fetch, so requiring --yes there would be pure noise.
out=$(env ROOT="$ROOT" python3 - <<'PY'
import os, re
root = os.environ["ROOT"]
FETCHED = r"(madge|jscpd|dependency-cruiser|depcruise|jsinspect)"
bare = re.compile(r"npx\s+(?!--yes\b|-y\b)" + FETCHED)
bad = []
for base in ("skills", "shared", "rules"):
    for dp, _dn, fns in os.walk(os.path.join(root, base)):
        for fn in fns:
            if not fn.endswith(".md"):
                continue
            p = os.path.join(dp, fn)
            for i, line in enumerate(open(p, errors="replace"), 1):
                # A line quoting the historical failure is the fix, not the bug.
                if re.search(r"(returns|returned|2026-09-05|--version)", line):
                    continue
                if bare.search(line):
                    bad.append("%s:%d" % (os.path.relpath(p, root), i))
print("\n".join(bad))
PY
)
if [ -z "$out" ]; then
  pass "every fetched-on-demand CLI is invoked with npx --yes"
else
  bad "bare npx (no --yes) on a tool that must be fetched — it prompts and reads as missing:"
  printf '        %s\n' $out
fi

for phrase in \
  "availability is MEASURED, never assumed" \
  "only after you ran it and it failed" \
  "FETCH-FAILED" \
  "SKIPPED-NO-INSTALL"
do
  if grep -qF "$phrase" "$ROOT/shared/includes/codesift-setup.md"; then
    pass "shared vocabulary carries: $phrase"
  else
    bad "codesift-setup.md lost: $phrase — agents will borrow UNAVAILABLE again"
  fi
done

# The include must keep saying WHY no consent gate applies, or the next reader adds one and the
# tool gets skipped for lack of permission instead of lack of availability.
if grep -q 'writes nothing' "$ROOT/shared/includes/codesift-setup.md"; then
  pass "the include explains why npx needs no install consent"
else
  bad "the no-consent-needed reason is gone — a spurious consent gate will reappear"
fi

# A STALE-ON-ARRIVAL INDEX IS REFRESHED, NOT FOOTNOTED.
#
# The same 2026-09-05 report carried `CodeSift index | OK (16984 files / 264275 symbols) |
# Discovery only; last indexed September 3, older than working tree`. The agent was following the
# "stale index after an edit" rule, which correctly REFUSES index_folder — a full re-index is
# minutes of cost for one file you just touched. But its case was repo-wide staleness before the
# audit began, where those same minutes buy the whole run its evidence, and "verify natively for
# this file only" has no file to point at. The two rules must stay distinguishable or the cheap
# remedy keeps being applied to the expensive problem.
for phrase in \
  "Stale ON ARRIVAL" \
  "the cost argument there does not transfer" \
  "Never present a finding from a knowingly stale index"
do
  if grep -qF "$phrase" "$ROOT/shared/includes/codesift-setup.md"; then
    pass "stale-on-arrival rule carries: $phrase"
  else
    bad "codesift-setup.md lost: $phrase — repo-wide staleness will be footnoted again"
  fi
done

# ...and the after-an-edit rule must SURVIVE. Deleting it to make room would swap one wrong remedy
# for another: a full re-index after every single-file edit.
if grep -q 'minutes of cost for a one-file staleness' "$ROOT/shared/includes/codesift-setup.md"; then
  pass "the after-an-edit rule still refuses a full re-index for one file"
else
  bad "the after-an-edit rule is gone — index_folder will be called on every edit"
fi

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
