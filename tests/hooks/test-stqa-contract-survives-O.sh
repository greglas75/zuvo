#!/usr/bin/env bash
# The survey-translation-qa delivery contract must not depend on `assert`.
#
# Measured 2026-09-18 on the pre-fix tree: `python -O scripts/stqa_selfcheck.py` printed
#   FAIL  prose in Proposed Correction is refused
# because every guard that stands between a malformed workbook and a client deliverable —
# the column contract (stqa_workbook), the font proof (stqa_fonts) and the adversarial
# verdict checks (stqa_adversarial) — was a bare `assert`, and -O removes those. A workbook
# with tofu boxes, a placeholder value or a missing EN gloss would have saved exactly like a
# correct one, with no error and no test failure. The guards now raise ContractError (a
# subclass of AssertionError, so existing `except AssertionError` callers are unaffected).
#
# This test is the regression guard: it re-runs the project's own selfcheck under -O, where
# the old implementation demonstrably failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# Pick an interpreter that can import openpyxl; skip cleanly where none exists (the farm has
# no venv, and a skipped environment check must not read as a passing contract check).
PY=""
for cand in "${ZUVO_STQA_VENV:-$HOME/.zuvo/stqa-venv}/bin/python" python3; do
  [ -x "$cand" ] || cand="$(command -v "$cand" 2>/dev/null)" || continue
  [ -n "$cand" ] || continue
  if "$cand" -c 'import openpyxl' 2>/dev/null; then PY="$cand"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no interpreter with openpyxl (run scripts/stqa.sh selfcheck locally)"; exit 0; }

# 1. No bare `assert` may remain in the three contract modules — the mechanism, checked
# statically, so a new one added later is caught before it can be stripped.
stray=$(grep -nE '^[[:space:]]*assert ' "$ROOT"/scripts/stqa_workbook.py \
        "$ROOT"/scripts/stqa_fonts.py "$ROOT"/scripts/stqa_adversarial.py 2>/dev/null || true)
if [ -z "$stray" ]; then pass "no bare assert left in the contract modules"
else bad "bare assert(s) back in the contract path — stripped under -O:"$'\n'"$stray"; fi

# 2. The behaviour, checked by running it: the selfcheck must hold under -O as well as without.
out_plain=$(cd "$ROOT/scripts" && "$PY" stqa_selfcheck.py 2>&1 | tail -1)
out_opt=$(cd "$ROOT/scripts" && "$PY" -O stqa_selfcheck.py 2>&1 | tail -1)
if [ "$out_plain" = "$out_opt" ] && printf '%s' "$out_plain" | grep -q 'checks held'; then
  pass "selfcheck holds identically with and without -O ($out_opt)"
else bad "selfcheck differs under -O — plain: '$out_plain' · -O: '$out_opt'"; fi

# 3. ContractError must stay an AssertionError subclass: the selfcheck and any caller written
# against the old behaviour catch AssertionError, and breaking that silently turns a refusal
# into a crash.
if (cd "$ROOT/scripts" && "$PY" -c 'import sys; sys.path.insert(0,"."); import stqa_fonts; raise SystemExit(0 if issubclass(stqa_fonts.ContractError, AssertionError) else 1)'); then
  pass "ContractError remains an AssertionError subclass"
else bad "ContractError no longer subclasses AssertionError — existing except-clauses stop catching it"; fi

[ "$fail" -eq 0 ] && echo "ALL PASS" || echo "FAILURES"
exit "$fail"
