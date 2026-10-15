#!/usr/bin/env bash
# The pre-commit WARNING for a backlog entry that did not go through `backlog-add`.
#
# The rule it carries: `backlog-add` is the one write path for a finding (backlog-protocol.md) —
# under one lock it checks the cited code, dedupes against both files and the findings ledger, and
# writes. The dedup check used to live only in the backlog SKILL's `add` mode, while the practice
# is an append followed by a commit, which never enters that mode and so never calls the lookup
# (B-20261009-DEDUP-ADD-MODE-ONLY). Nothing enforced it: no hook in this repo so much as mentions
# memory/backlog.md (measured 2026-10-15).
#
# The two properties worth a test are the ones a reviewer cannot read off the script: that it never
# fails a commit, and that the hand edits the PROTOCOL MANDATES (closing an entry, re-opening a
# REGRESSION) do not trip it. A warning that fires on every close would be turned off within a day.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
HOOK="$ROOT/hooks/backlog-hand-append-warn.sh"
DISPATCH="$ROOT/hooks/git-dispatch/pre-commit"

PASS=0; FAIL=0
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

echo "== backlog hand-append warning =="
[ -x "$HOOK" ] || { no "(W0) $HOOK missing or not executable"; echo "RESULT: PASS=$PASS FAIL=$FAIL"; exit 1; }
ok "(W0) the hook is present and executable"

FIX="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-handwarn.XXXXXX")"
trap 'rm -rf "$FIX"' EXIT
repo(){            # a fresh git repo with a backlog, nothing staged
  rm -rf "$FIX/r"; mkdir -p "$FIX/r/memory"; git -C "$FIX/r" init -q .
  printf '# Backlog\n\n' > "$FIX/r/memory/backlog.md"
  git -C "$FIX/r" add -A >/dev/null 2>&1
  git -C "$FIX/r" -c user.email=t@t -c user.name=t commit -qm init >/dev/null 2>&1
}
stage(){ printf '%s\n' "$1" >> "$FIX/r/memory/backlog.md"; git -C "$FIX/r" add memory/backlog.md; }
run(){ ( cd "$FIX/r" && "$HOOK" 2>"$FIX/err" ); echo $?; }

HAND='- [ ] B-20261015-SOMETHING src/x.ts the thing is wrong | severity: low | conf: 70'
ADDED='- [ ] B-x-BUG-37093f54 src/cart.js:2 — [BUG] accepts a total equal to the limit | conf: 85 | seen: 1 | ledger: F-37093f54ed17 | 2026-10-15'

# --- W1 a hand-written entry warns, and says what to run instead ------------------------------
repo; stage "$HAND"; rc=$(run)
[ "$rc" = 0 ] && ok "(W1) exit 0 — a warning never fails the commit" \
  || no "(W1) exit was $rc: this script can block a commit over a backlog line"
grep -q "appended by hand" "$FIX/err" && ok "(W1) it warns" || no "(W1) no warning: $(cat "$FIX/err")"
grep -q "backlog-add" "$FIX/err" && ok "(W1) it names the command to use instead" \
  || no "(W1) the warning does not say what to run instead"
grep -q "warning, not a gate" "$FIX/err" && ok "(W1) it says a deliberate hand entry is fine" \
  || no "(W1) nothing tells the reader a hand entry is allowed — this reads as a blocker"

# --- W2 what backlog-add wrote is silent -------------------------------------------------------
# The LEDGER LINK is the discriminator, so an entry carrying one must produce no output at all.
repo; stage "$ADDED"; rc=$(run)
[ "$rc" = 0 ] && [ ! -s "$FIX/err" ] && ok "(W2) an entry with a ledger link is silent" \
  || no "(W2) backlog-add's own entry warns (rc=$rc): $(cat "$FIX/err")"

# --- W3 the hand edits the protocol MANDATES do not trip it ------------------------------------
for case in "closing:- [x] B-old [FIXED abc1234] src/x.ts the thing was wrong" \
            "regression:- [ ] B-old [REGRESSION 2026-10-15 — closed FIXED abc1234, archived] src/x.ts back again"; do
  lbl="${case%%:*}"; line="${case#*:}"
  repo; stage "$line"; rc=$(run)
  [ "$rc" = 0 ] && [ ! -s "$FIX/err" ] && ok "(W3) $lbl is silent — the protocol mandates that hand edit" \
    || no "(W3) $lbl warns (rc=$rc): $(cat "$FIX/err")"
done

# --- W4 it is about memory/backlog.md, not every file ------------------------------------------
repo; mkdir -p "$FIX/r/docs"; printf '%s\n' "$HAND" > "$FIX/r/docs/notes.md"
git -C "$FIX/r" add docs/notes.md; rc=$(run)
[ "$rc" = 0 ] && [ ! -s "$FIX/err" ] && ok "(W4) the same line in another file is not the backlog" \
  || no "(W4) it warns about a file that is not memory/backlog.md: $(cat "$FIX/err")"

# --- W5 it counts, and it does not print the whole batch ---------------------------------------
repo; for i in 1 2 3 4 5; do stage "- [ ] B-2026101${i}-X src/x${i}.ts thing ${i} | conf: 70"; done
rc=$(run)
[ "$rc" = 0 ] && ok "(W5) five hand entries still exit 0" || no "(W5) exit was $rc"
grep -qE "^zuvo backlog: 5 new entries" "$FIX/err" && ok "(W5) it reports the count (5)" \
  || no "(W5) wrong or missing count: $(head -1 "$FIX/err")"
grep -q "and 2 more" "$FIX/err" && ok "(W5) it quotes three and says how many it did not" \
  || no "(W5) the overflow line is missing — a 40-entry commit would dump 40 lines: $(cat "$FIX/err")"

# --- W6 an unborn HEAD (a repo's first commit) must not error ----------------------------------
# `git diff --cached HEAD` fails outright before the first commit, which would make this script
# print a git error on the one commit every new repo makes.
rm -rf "$FIX/u"; mkdir -p "$FIX/u/memory"; git -C "$FIX/u" init -q .
printf '%s\n' "$HAND" > "$FIX/u/memory/backlog.md"; git -C "$FIX/u" add memory/backlog.md
( cd "$FIX/u" && "$HOOK" 2>"$FIX/uerr" ); rc=$?
[ "$rc" = 0 ] && ok "(W6) unborn HEAD: exit 0" || no "(W6) unborn HEAD: exit $rc"
grep -qi "fatal\|ambiguous argument" "$FIX/uerr" \
  && no "(W6) it printed a git error on an unborn HEAD: $(cat "$FIX/uerr")" \
  || ok "(W6) unborn HEAD: no git error leaked to the user"
grep -q "appended by hand" "$FIX/uerr" && ok "(W6) unborn HEAD: the warning still works" \
  || no "(W6) unborn HEAD: the check silently did nothing"

# --- W7 the dispatcher chains it, and cannot be made to fail a commit by it --------------------
grep -q "backlog-hand-append-warn.sh" "$DISPATCH" \
  && ok "(W7) the global pre-commit dispatcher chains the script" \
  || no "(W7) the script is installed but nothing runs it"
grep -qE 'backlog-hand-append-warn\.sh" </dev/null \|\| true' "$DISPATCH" \
  && ok "(W7) its exit status is discarded in the dispatcher (|| true), so it cannot set rc" \
  || no "(W7) the dispatcher does not discard its status — a future non-zero would block commits"

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ] || exit 1
