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
#   WARNINGS — a RATCHET against the count below. It started at 102 and the debt is now PAID: the
#              ratchet reads 0, so this gate has become a hard zero on warnings too. Getting there
#              turned up four real defects that lint had been carrying as noise — a `((TOTAL_FAIL++))`
#              whose 0 -> 1 step exits 1 under `set -e` and aborted the geo suite before it could
#              report a failure; 34 unchecked `cd`s in fixture setup, several followed by `git init`
#              and file writes that would have landed in the caller's directory; a `mkdir -m 700`
#              whose mode never reached a cache dir surviving from a pre-0700 release; and three
#              tests that computed a result and never asserted on it.
#
# The count is stated here, in the open, rather than hidden in a baseline file nobody reads. It is
# 0 now, so the rule is simply: do not add a warning. If a construct is deliberate, annotate it
# with `# shellcheck disable=SCxxxx` AND the reason — never raise this number.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
MAX_WARNINGS=0

PASS=0; FAIL=0
# A misspelled helper is not caught by `set -u`: bash prints "command not found", returns 127, and
# the counters never move — so a file full of broken assertions summarises as FAIL=0. That happened
# in this repo (11 assertions calling a helper the file did not define). This makes it a real failure.
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
t_ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
t_no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

if ! command -v shellcheck >/dev/null 2>&1; then
  # `SKIP:` at column 0 on the FIRST non-empty line — that exact shape is what tests/run-all.sh
  # sniffs to classify a child as SKIP. Indented (`  SKIP:`) or printed after any other line, the
  # harness classifies exit 0 as PASS, so a machine with no shellcheck reported a GREEN lint gate
  # that never ran. Flagged by the adversarial pass; the message was already loud, the CLASSIFICATION
  # was the bug.
  echo "SKIP: shellcheck is not installed — the shell lint gate did NOT run."
  echo "      Install it (brew install shellcheck) so this check is real on this machine."
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
