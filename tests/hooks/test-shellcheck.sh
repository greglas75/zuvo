#!/usr/bin/env bash
# Shell lint gate (B-SHELLCHECK).
#
# (The first word of this line is not the linter's name on purpose: a comment starting with it is
# parsed as a DIRECTIVE, and an unparseable one is a hard SC1073 that stops analysis of the file.
# The first draft of THIS file tripped exactly that, and the gate caught its own source — but only
# after the commit, because the corpus reads `git ls-files` and an untracked file is invisible to
# it. Run this gate again after committing anything it lints.)
#
# This repo is almost entirely shell and nothing linted it: no .shellcheckrc, no CI job, and by
# CQ40's own wording ("No config present = 0 — that is the point of the gate") every bash file
# scored 0. It stayed unfixed because shellcheck was not installed on the dev machine, and shipping
# rules nobody could run locally is a config that only ever speaks through CI.
#
# TWO gates, because they are different promises:
#   ERRORS   — hard zero. These are parse failures and real bugs; there were 3 and they are fixed.
#   WARNINGS — a RATCHET against the count below. 102 exist today (SC2086 unquoted expansion,
#              SC2164 unchecked cd, SC2034 unused). Fixing them all at once would be a huge
#              untested diff across 273 files; a ratchet stops the debt GROWING while it is paid
#              down, which is the only honest way to adopt a linter on an existing codebase.
#
# The count is stated here, in the open, rather than hidden in a baseline file nobody reads. When
# you fix warnings, LOWER it — the test tells you the new number.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
MAX_WARNINGS=102

PASS=0; FAIL=0
t_ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
t_no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

if ! command -v shellcheck >/dev/null 2>&1; then
  # Loud, not silent. A gate that vanishes without saying so is how this repo went months
  # believing its shell was linted-adjacent when nothing ran at all.
  echo "  SKIP: shellcheck is not installed — the shell lint gate did NOT run."
  echo "        Install it (brew install shellcheck) so this check is real on this machine."
  echo "  --- shellcheck: SKIPPED"
  exit 0
fi

[ -f "$ROOT/.shellcheckrc" ] && t_ok ".shellcheckrc is present (CQ40 requires a config, not just a linter)" \
  || t_no "no .shellcheckrc — CQ40 scores 0 for every shell file in the repo"

# --- corpus selection ---------------------------------------------------------------------------
# Getting this wrong is not academic: a first pass that keyed only on a bash/sh shebang pulled in
# the POLYGLOT sh/python helpers in scripts/zuvo-home/ (they start `#!/bin/sh` and re-exec python3
# on line 8). shellcheck then linted Python as shell and reported 52 "errors" — every one a false
# positive, and enough noise to make the real 3 invisible.
shfiles(){
  ( cd "$ROOT" && git ls-files ) | while IFS= read -r f; do
    [ -f "$ROOT/$f" ] || continue
    case "$f" in *.py|*.md|*.json|*.yml|*.yaml) continue ;; esac
    head -1 "$ROOT/$f" 2>/dev/null | grep -qE '^#!.*(bash|[^a-z]sh)' || continue
    head -12 "$ROOT/$f" 2>/dev/null | grep -q 'exec .*python' && continue   # polyglot sh/python
    printf '%s\n' "$ROOT/$f"
  done
}

FILES="$(shfiles)"
N="$(printf '%s\n' "$FILES" | grep -c . || true)"
[ "$N" -ge 100 ] && t_ok "corpus resolved to $N shell files" \
  || { t_no "corpus is only $N files — the selector is broken and this gate would be vacuous"; }

count_at(){ # <severity>
  printf '%s\n' "$FILES" | tr '\n' '\0' \
    | ( cd "$ROOT" && xargs -0 shellcheck -S "$1" -f gcc 2>/dev/null ) \
    | grep -c '\[SC' || true
}

# --- gate 1: zero errors ------------------------------------------------------------------------
ERRS="$(count_at error)"
if [ "$ERRS" -eq 0 ]; then
  t_ok "shellcheck reports 0 errors"
else
  t_no "shellcheck reports $ERRS error(s) — these are parse failures or real bugs, fix them:"
  printf '%s\n' "$FILES" | tr '\n' '\0' \
    | ( cd "$ROOT" && xargs -0 shellcheck -S error -f gcc 2>/dev/null ) | head -20 | sed 's/^/      /'
fi

# --- gate 2: warnings must not grow -------------------------------------------------------------
WARNS="$(count_at warning)"
WARN_ONLY=$(( WARNS - ERRS ))
if [ "$WARN_ONLY" -le "$MAX_WARNINGS" ]; then
  t_ok "warnings at $WARN_ONLY (ratchet: $MAX_WARNINGS)"
  if [ "$WARN_ONLY" -lt "$MAX_WARNINGS" ]; then
    echo "      ↓ debt went DOWN. Lower MAX_WARNINGS in this file to $WARN_ONLY so it cannot come back."
  fi
else
  t_no "warnings rose to $WARN_ONLY (ratchet: $MAX_WARNINGS) — new lint debt, fix it rather than raising the number"
  printf '%s\n' "$FILES" | tr '\n' '\0' \
    | ( cd "$ROOT" && xargs -0 shellcheck -S warning -f gcc 2>/dev/null ) | head -20 | sed 's/^/      /'
fi

echo "  --- shellcheck: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
