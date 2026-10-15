#!/bin/sh
# zuvo pre-commit WARNING: a new backlog entry that did not go through `backlog-add`.
#
# `shared/includes/backlog-protocol.md` makes `~/.zuvo/backlog-add` the one write path for a
# finding: under one lock it checks the cited code, dedupes against both backlog files and the
# findings ledger, and writes. A hand append skips all three. Nothing noticed — the dedup check
# lived in the backlog SKILL's `add` mode, while the actual practice is an append followed by a
# commit, which never enters that mode (B-20261009-DEDUP-ADD-MODE-ONLY).
#
# WARNS, NEVER BLOCKS, and that is the whole design. A near-duplicate is sometimes deliberate, a
# process note has no cited code to check, and a backlog this repo writes by hand several times a
# day must not become uncommittable. Blocking would also put this script on the critical path of
# every commit in every repo, which is how a fail-open gate becomes an outage.
#
# The signal is the LEDGER LINK, not a re-run of the lookup. An entry `backlog-add` wrote carries
# `ledger: F-<12 hex>`; a hand-written one cannot have it. That makes the check a substring test on
# the staged lines — no python, no repo read, no lock — where re-running `lookup` per added entry
# would cost one process each and would still miss the duplicates the lookup itself cannot see.
#
# What it deliberately ignores: `- [x]` (closing an entry is a hand edit the protocol MANDATES),
# `[REGRESSION` (re-opening under the same id is also mandated and hand-written), and every file
# but `memory/backlog.md`.
set -u

# `--diff-filter=d`: a deleted backlog file has no added lines to judge, and `git diff --cached`
# against an unborn HEAD needs the empty-tree fallback or the first commit in a repo errors here.
if git rev-parse --verify -q HEAD >/dev/null 2>&1; then _base=HEAD; else
  _base=$(git hash-object -t tree /dev/null 2>/dev/null) || exit 0; fi
added=$(git diff --cached --unified=0 --diff-filter=d "$_base" -- '*memory/backlog.md' 2>/dev/null \
        | sed -n 's/^+\([^+].*\)$/\1/p') || exit 0
[ -n "$added" ] || exit 0

hand=$(printf '%s\n' "$added" \
       | grep -E '^[[:space:]]*(- \[ \]|## B-)' \
       | grep -v -- '[[]REGRESSION' \
       | grep -v 'ledger: F-') || hand=""
[ -n "$hand" ] || exit 0

n=$(printf '%s\n' "$hand" | grep -c '')
printf 'zuvo backlog: %s new entr%s appended by hand — not through `backlog-add`, so the cited code\n' \
  "$n" "$([ "$n" = 1 ] && echo y || echo ies)" >&2
printf '  was not checked, nothing was deduped against the findings ledger, and no lock was held.\n' >&2
printf '%s\n' "$hand" | head -3 | cut -c1-96 | sed 's/^/  | /' >&2
[ "$n" -gt 3 ] && printf '  | … and %s more\n' "$((n - 3))" >&2
printf '  A finding goes in with: ~/.zuvo/backlog-add --repo "$PWD" --class BUG --conf N --source <skill> \\\n' >&2
printf '    --file F --line N --anchor "<text from that line>" --title "..."   (see backlog-protocol.md)\n' >&2
printf '  Deliberate hand entries (process notes, re-scopes) are fine — this is a warning, not a gate.\n' >&2
exit 0
