#!/usr/bin/env bash
# test-coverage-gate.py boundaries — derive boundary obligations from the SOURCE.
#
# The rig measured, across 39 suites for one file, that the mutants separating an 88% suite from
# a 91% one are all boundaries the tests never sat exactly on: `value < 0` surviving a change to
# `<=` (27 of 39), a literal 0 bumped to 1 (27 of 39), a `throw` deleted outright (34 of 39),
# `normalized[0]` shifted to `[1]` (15 of 39). The existing guidance covers this — but keyed on
# code TYPE, so a bare comparison in a pure function never triggers it.
#
# So the property under test is that the obligations come from the code, not from a
# classification: every relational operator, every logical operator, every throw and every
# literal index in the file must appear, whatever the file is "about".
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
GATE="$ROOT/scripts/test-coverage-gate.py"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── Python fixture: parser is built in, so this path always runs ─────────────────────────
cat > "$TMP/scoring.py" <<'PY'
def band(score: int) -> str:
    if score < 0:
        raise ValueError("negative score")
    if score >= 90:
        return "high"
    return "low"


def pick(rows):
    if len(rows) == 0 or rows is None:
        raise ValueError("empty")
    return rows[0]


def noop():
    return 1
PY

out=$(python3 "$GATE" boundaries --production "$TMP/scoring.py" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "python file exits 0" || bad "python exit $rc: $out"

grep -q "L2 *COMPARISON *score < 0" <<<"$out" \
  && pass "a bare relational operator is an obligation regardless of code type" \
  || bad "comparison not reported: $(grep COMPARISON <<<"$out")"
grep -q "L4 *COMPARISON *score >= 90" <<<"$out" \
  && pass "both comparisons in the file are reported" || bad "second comparison missing"
grep -q "L3 *THROW" <<<"$out" && pass "a raise is an obligation" || bad "raise not reported"
grep -q "L10 *LOGIC" <<<"$out" \
  && pass "a boolean operator is an obligation (|| vs && is a mutated operator)" \
  || bad "BoolOp not reported"
grep -q "L12 *INDEX *rows\[0\]" <<<"$out" \
  && pass "a literal index is an obligation" || bad "index not reported"

# The advice is what makes the row actionable; assert the specific instruction, not its presence.
grep -q "two sides are EQUAL" <<<"$out" \
  && pass "COMPARISON advice names the equal-sides case that separates < from <=" \
  || bad "comparison advice missing the decisive case"
grep -q "FAILS when this throw is DELETED" <<<"$out" \
  && pass "THROW advice demands a test that fails on deletion, not just any throw" \
  || bad "throw advice too weak"
grep -q "LEFT side alone decides" <<<"$out" \
  && pass "LOGIC advice names the operand-decides case that separates || from &&" \
  || bad "logic advice missing"

# ── advice appears ONCE per kind, not once per obligation ────────────────────────────────
n=$(grep -c "FAILS when this throw is DELETED" <<<"$out")
[ "$n" -eq 1 ] \
  && pass "advice is stated once per kind, not repeated under every row" \
  || bad "throw advice repeated $n times — a work list becomes a wall of text"

# ── a file with nothing to bound says so, and does not fail ──────────────────────────────
cat > "$TMP/plain.py" <<'PY'
def greet(name):
    return "hello " + name
PY
out2=$(python3 "$GATE" boundaries --production "$TMP/plain.py" 2>&1); rc2=$?
[ "$rc2" -eq 0 ] && pass "a file with no boundaries exits 0" || bad "plain file exit $rc2"
grep -q "none found" <<<"$out2" \
  && pass "no boundaries is stated explicitly, not left as empty output" \
  || bad "empty result not explained: $out2"

# ── an unparseable language is DEGRADED, never silently 'no boundaries' ──────────────────
printf 'SELECT 1;\n' > "$TMP/thing.sql"
out3=$(python3 "$GATE" boundaries --production "$TMP/thing.sql" 2>&1); rc3=$?
[ "$rc3" -eq 3 ] && pass "an unsupported language exits 3" || bad "unsupported exit $rc3 (want 3)"
grep -q "BLOCKED_DEGRADED" <<<"$out3" \
  && pass "unsupported names the evidence state, so absence is not read as coverage" \
  || bad "degraded state not named: $out3"

# ── TS/JS path, only where a classic typescript module is reachable ──────────────────────
TSLIB=""
for cand in "$ROOT/node_modules/typescript/lib/typescript.js" \
            "$HOME/DEV/tgm-survey-platform/node_modules/typescript/lib/typescript.js"; do
  [ -f "$cand" ] && { TSLIB="$cand"; break; }
done
if [ -n "$TSLIB" ] && command -v node >/dev/null 2>&1; then
  cat > "$TMP/scoring.ts" <<'TS'
export function band(score: number): string {
  if (score < 0 || !Number.isFinite(score)) {
    throw new RangeError('bad score');
  }
  return score >= 90 ? 'high' : 'low';
}
export const first = (rows: string[]) => rows[0];
TS
  out4=$(ZUVO_TSC_PATH="$TSLIB" python3 "$GATE" boundaries --production "$TMP/scoring.ts" 2>&1)
  grep -q "COMPARISON *score < 0" <<<"$out4" \
    && pass "TS comparison reported via the compiler API" || bad "TS comparison missing: $out4"
  grep -q "LOGIC" <<<"$out4" && pass "TS logical operator reported" || bad "TS logic missing"
  grep -q "THROW" <<<"$out4" && pass "TS throw reported" || bad "TS throw missing"
  grep -q "INDEX *rows\[0\]" <<<"$out4" && pass "TS literal index reported" || bad "TS index missing"
else
  echo "SKIP: no classic typescript module reachable — TS path not exercised on this machine"
fi

# ── (15) string concatenation is not an arithmetic obligation ────────────────────────────
cat > "$TMP/concat.py" <<'PY'
def greet(name):
    return "hello " + name


def total(a, b):
    return a + b
PY
out5=$(python3 "$GATE" boundaries --production "$TMP/concat.py" 2>&1)
grep -q "L6 *ARITHMETIC" <<<"$out5" \
  && pass "a numeric + is an obligation" || bad "numeric arithmetic missing: $out5"
grep -q "hello" <<<"$out5" \
  && bad "string concatenation reported — swapping its operator throws on ANY input, so the mutant dies for free" \
  || pass "string concatenation is excluded: its mutant dies on the first test regardless"

# ── (16) a long list is prioritised by measured risk and never silently truncated ────────
python3 - "$TMP/big.py" <<'PY'
import sys
with open(sys.argv[1], "w") as fh:
    fh.write("def f(a, b):\n")
    for i in range(80):
        fh.write("    if a == %d:\n        b = b + %d\n" % (i, i + 1))
    fh.write("    if a < 5:\n        raise ValueError('low')\n    return b\n")
PY
out6=$(python3 "$GATE" boundaries --production "$TMP/big.py" 2>&1)
first=$(grep -A1 "^OBLIGATIONS" <<<"$out6" | tail -1)
grep -q "THROW" <<<"$first" \
  && pass "the highest-risk kind (a deleted throw, 34 of 39 suites) is listed first" \
  || bad "obligations not risk-ordered, first row was: $first"
grep -q "more, all lower-risk kinds" <<<"$out6" \
  && pass "truncation is announced with what was dropped, not silent" \
  || bad "long list truncated without saying so"
n_all=$(python3 "$GATE" boundaries --production "$TMP/big.py" --all 2>&1 | grep -c "^  L[0-9]")
n_cap=$(grep -c "^  L[0-9]" <<<"$out6")
[ "$n_all" -gt "$n_cap" ] && pass "--all lists everything the capped view hides" \
  || bad "--all showed $n_all rows, capped showed $n_cap"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
