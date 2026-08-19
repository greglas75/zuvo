#!/usr/bin/env bash
# Python lint gate (B-CQ40-METALINTER, Python half).
#
# Nothing linted this repo's Python: no pyproject.toml, no ruff.toml, no .flake8, no workflow
# calling any of them. CQ40 scores that 0 by design, and the surface roughly doubled when
# check-skill-structure.py and verify-review-claims.py landed. The shell half is .shellcheckrc +
# test-shellcheck.sh; this is the other half, in the same shape:
#
#   mypy — HARD ZERO. It found a real one on the first run (a name bound to two different tuple
#          shapes), and after fixing that it is clean, so a ratchet would be a weaker gate.
#   ruff — RATCHETED at the count below. The remainder is mostly long lines in files this repo
#          keeps deliberately wide.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/../.." && pwd)"
MAX_RUFF=46

PASS=0; FAIL=0
# A misspelled helper prints "command not found", returns 127 and moves no counter — a whole file
# of broken assertions then summarises as FAIL=0 (that happened in test-profile-session-tokens.sh).
command_not_found_handle(){ echo "  FAIL harness: unknown command '$1'"; FAIL=$((FAIL+1)); return 127; }
ok(){ echo "  PASS $1"; PASS=$((PASS+1)); }
no(){ echo "  FAIL $1"; FAIL=$((FAIL+1)); }

# Tool check BEFORE any assertion. tests/run-all.sh classifies a child as SKIP only when `SKIP:`
# is the FIRST non-empty line at column 0; emitted later (or indented) the run exits 0 and counts as
# PASS, so a box without ruff/mypy reported a green Python gate that never ran.
if ! command -v ruff >/dev/null 2>&1 && ! command -v mypy >/dev/null 2>&1; then
  echo "SKIP: neither ruff nor mypy installed — the Python lint gate did NOT run."
  echo "      Install them (brew install ruff mypy) so this check is real on this machine."
  exit 0
fi

[ -f "$ROOT/pyproject.toml" ] && ok "pyproject.toml present (CQ40 wants a config, not just a tool)" \
  || no "no pyproject.toml — CQ40 scores 0 for every Python file"

# --- corpus ------------------------------------------------------------------------------------
# Includes the extensionless POLYGLOT sh/python helpers in scripts/zuvo-home/ — they are most of
# this repo's Python and a `*.py` glob misses every one of them. Excludes the deliberately
# vulnerable security fixtures (linting them is meaningless) and one-off validation scripts.
pyfiles(){
  ( cd "$ROOT" && { git ls-files '*.py'
                    git ls-files | while IFS= read -r f; do
                      head -8 "$f" 2>/dev/null | grep -q 'exec .*python' && printf '%s\n' "$f"
                    done; } ) | sort -u | grep -vE '^(tests/security-corpus|validation)/'
}
FILES="$(pyfiles)"
N="$(printf '%s\n' "$FILES" | grep -c . || true)"
[ "$N" -ge 10 ] && ok "corpus resolved to $N Python files" || no "corpus is only $N files — selector broken"
printf '%s\n' "$FILES" | grep -q 'scripts/zuvo-home/retro-mine.py' \
  && ok "corpus includes .py helpers" || no "corpus missed the .py helpers"
printf '%s\n' "$FILES" | grep -qx 'scripts/zuvo-home/backlog' \
  && ok "corpus includes the EXTENSIONLESS polyglot helpers" \
  || no "corpus misses the polyglot helpers — most of this repo's Python would go unlinted"

# --- ruff: ratchet -------------------------------------------------------------------------------
if command -v ruff >/dev/null 2>&1; then
  RUFF_N="$( cd "$ROOT" && printf '%s\n' "$FILES" | tr '\n' '\0' \
    | xargs -0 ruff check --no-cache --output-format concise 2>/dev/null \
    | grep -cE ': [A-Z]+[0-9]+ ' || true )"
  if [ "$RUFF_N" -le "$MAX_RUFF" ]; then
    ok "ruff at $RUFF_N (ratchet: $MAX_RUFF)"
    [ "$RUFF_N" -lt "$MAX_RUFF" ] && echo "      ↓ lower MAX_RUFF in this file to $RUFF_N so it cannot come back."
  else
    no "ruff rose to $RUFF_N (ratchet: $MAX_RUFF) — new lint debt; fix it rather than raising the number"
    ( cd "$ROOT" && printf '%s\n' "$FILES" | tr '\n' '\0' \
      | xargs -0 ruff check --no-cache --output-format concise 2>/dev/null ) | head -15 | sed 's/^/      /'
  fi
else
  echo "  SKIP: ruff absent — the Python lint ratchet did NOT run (brew install ruff)."
fi

# --- mypy: hard zero -----------------------------------------------------------------------------
# Scoped to *.py: mypy resolves module names from paths and cannot handle the extensionless
# polyglots, which is a tooling limit rather than a reason to skip the files it CAN check.
if command -v mypy >/dev/null 2>&1; then
  PYONLY="$( cd "$ROOT" && git ls-files '*.py' | grep -vE '^(tests/security-corpus|validation)/' )"
  MYPY_OUT="$( cd "$ROOT" && printf '%s\n' "$PYONLY" | tr '\n' '\0' | xargs -0 mypy 2>&1 )"
  MYPY_N="$(printf '%s\n' "$MYPY_OUT" | grep -c ': error: ' || true)"
  if [ "$MYPY_N" -eq 0 ]; then
    ok "mypy reports 0 errors"
  else
    no "mypy reports $MYPY_N error(s):"
    printf '%s\n' "$MYPY_OUT" | grep ': error: ' | head -12 | sed 's/^/      /'
  fi
else
  echo "  SKIP: mypy absent — the type gate did NOT run (brew install mypy)."
fi

echo "  --- python lint: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
