#!/usr/bin/env bash
# Wall-clock budget for scripts/zuvo-home/zuvo_comment_rules.py on the inputs most likely to go quadratic: a
# regex backtracking over one long token, an incident pattern over long filler lines, and thousands of comment
# blocks above brackets that never close. Call counts cannot see regex backtracking, so this times it.
# Two shapes are also timed at k and 4k: the import pattern on a `const` line of spaces, and the scanner's ruby
# operand lookback on a line of divisions. Linear work allows 4k to take 8x k plus 0.05 s; quadratic takes 16x.
# A benchmark, not a unit test: run-all globs only test-*.sh, so a slow host never fails a release. Run it after
# changing a rules regex or the construct scan: rt --light bash tests/hooks/bench-comment-audit-rules.sh
# Level: benchmark — wall-clock timing of in-process calls; no git, no network.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)" || { echo "FAIL: cannot resolve the repo root"; echo "RESULT: PASS=0 FAIL=1"; exit 1; }
HELPERS="$ROOT/scripts/zuvo-home"
BUDGET_SECONDS="${ZUVO_RULES_BENCH_SECONDS:-5}"
fail=0
npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }

command -v python3 >/dev/null 2>&1 || { bad "python3 not available"; printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"; exit 1; }
export PYTHONDONTWRITEBYTECODE=1 PYTHONIOENCODING=utf-8 PYTHONUTF8=1 PYTHONUNBUFFERED=1

out="$(python3 - "$HELPERS" "$BUDGET_SECONDS" <<'PY' 2>&1
import sys
import time

sys.path.insert(0, sys.argv[1])
import zuvo_comment_rules as r

BUDGET = float(sys.argv[2])
J4 = "// a\n// b\n// c\n// d\n"
SHAPES = (("a 120 000-char comment token without '/'", "x = 0\n# " + "a" * 120000 + "\ny = 1\n", "python"),
          ("400 'incident' lines of 500 words", "x = 0\n" + ("# incident " + "b " * 500 + "\n") * 400 + "y = 1\n",
           "python"),
          ("3000 blocks over brackets that never close", "x();\n" + (J4 + "x = f(\n") * 3000, "js"))
SCALING = (("a 'const' line of spaces with no '=' (the import pattern)", lambda k: "const" + " " * k + "x\n", "js",
            4000),
           ("a ruby line of divisions (the scanner's operand lookback)", lambda k: "x = a" + " / b" * k + "\n", "ruby",
            2000))


def timed(src, lang):
    rows = frozenset(range(src.count("\n") + 1))
    view = r.FileView(path="bench.py", lang=lang, text=src, added=rows, carried=frozenset())
    start = time.perf_counter()
    r.evaluate(view, r.load_thresholds({}))
    return time.perf_counter() - start


for name, src, lang in SHAPES:
    took = timed(src, lang)
    print("%s %s: %.2f s of %.0f s" % ("OK" if took < BUDGET else "NO", name, took, BUDGET))
for name, make, lang, k in SCALING:
    small, large = (min(timed(make(k * m), lang) for _ in range(3)) for m in (1, 4))
    allowed = min(8 * small + 0.05, BUDGET)
    print("%s %s: %.3f s at k=%d, %.3f s at 4k, allowed %.3f s" % ("OK" if large <= allowed else "NO", name, small, k,
                                                                  large, allowed))
PY
)"; rc=$?

[ "$rc" -eq 0 ] && pass "the benchmark driver exited 0" || bad "the benchmark driver exited $rc"
seen=0
while IFS= read -r line; do
  case "$line" in
    "OK "*) pass "${line#OK }"; seen=$((seen + 1)) ;;
    "NO "*) bad "${line#NO }"; seen=$((seen + 1)) ;;
    *) printf '  %s\n' "$line" ;;
  esac
done < <(printf '%s\n' "$out")
[ "$seen" -eq 5 ] && pass "all 5 shapes were timed" || bad "timed $seen of 5 shapes"

printf 'RESULT: PASS=%d FAIL=%d\n' "$npass" "$nfail"
exit "$fail"
