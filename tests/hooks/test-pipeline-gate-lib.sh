#!/usr/bin/env bash
# Task 3 — unit tests for hooks/lib/pipeline-gate-lib.sh.
# Builds a throwaway git repo fixture; sources the lib; asserts classification,
# substantiality (file + line thresholds), content-keyed review coverage
# (incl. the no-whitelist case), escape valves, agent-env detection, and
# fail-open behavior on bad range / no repo.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source lib"; exit 1; }
[ "${PG_LIB_LOADED:-}" = "1" ] && pass "lib sourced" || bad "lib not loaded"

# ---------- classification (no git needed) ----------
out="$(printf '%s\n' \
  src/a.ts src/b.js tests/x.test.ts docs/readme.md pkg.json .eslintrc \
  foo.spec.js zuvo/state.md lib/core.sh app/__tests__/y.ts settings.yaml \
  | pg_classify_files | sort | tr '\n' ' ')"
if [ "$out" = "lib/core.sh src/a.ts src/b.js " ]; then
  pass "classify keeps only production (drops test/docs/config/zuvo/__tests__)"
else
  bad "classify wrong: [$out]"
fi

# ---------- git fixture ----------
TMP="$(mktemp -d)"
NOREPO="$(mktemp -d)"
trap 'rm -rf "$TMP" "$NOREPO"' EXIT
(
  cd "$TMP" || exit 1
  git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main; }
  git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > base.txt; git add base.txt; git commit -qm base
) || { bad "fixture init failed"; echo "SOME FAILED"; exit 1; }

cd "$TMP" || { bad "cannot cd fixture"; echo "SOME FAILED"; exit 1; }
BASE=$(git rev-parse HEAD)

# substantial via FILE count (3 prod files)
mkdir -p src; echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
git add src; git commit -qm "feat: three prod files"
HEAD=$(git rev-parse HEAD)
pg_is_substantial "$BASE..$HEAD" && pass "substantial: 3 prod files (file threshold)" || bad "3 files should be substantial"

# NOT substantial: single small prod file
echo tiny > src/tiny.sh; git add src/tiny.sh; git commit -qm tiny
HEAD2=$(git rev-parse HEAD)
pg_is_substantial "$HEAD..$HEAD2" && bad "1 small prod file should NOT be substantial" || pass "not substantial: 1 small prod file"

# NOT substantial: docs-only, even at 200 lines (classifier excludes docs)
mkdir -p docs; for i in $(seq 1 200); do echo "line $i" >> docs/big.md; done
git add docs/big.md; git commit -qm "big docs"
HEAD3=$(git rev-parse HEAD)
pg_is_substantial "$HEAD2..$HEAD3" && bad "docs-only should NOT be substantial" || pass "not substantial: docs-only 200 lines"

# substantial via LINE count: 1 prod file, 200 lines
for i in $(seq 1 200); do echo "x$i" >> src/big.sh; done
git add src/big.sh; git commit -qm "big prod"
HEAD4=$(git rev-parse HEAD)
pg_is_substantial "$HEAD3..$HEAD4" && pass "substantial: 1 file 200 lines (line threshold)" || bad "200 prod lines should be substantial"

# env-override: raise MIN_LINES above 200 → same change not substantial
( ZUVO_GATE_MIN_LINES=9999 ZUVO_GATE_MIN_FILES=99 pg_is_substantial "$HEAD3..$HEAD4" ) \
  && bad "raised thresholds should make it not substantial" \
  || pass "thresholds env-overridable (ZUVO_GATE_MIN_LINES/FILES)"

# ---------- content-keyed review coverage ----------
mkdir -p memory/reviews
cat > memory/reviews/files-cov.md <<'ART'
<!-- zuvo-review -->
range: dead..beef
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
body
ART
pg_range_reviewed "$BASE..$HEAD"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: covered by files-set (a/b/c)" || bad "files coverage should be 0, got $rc"

# no-whitelist: an UNRELATED file change is NOT covered by the a/b/c artifact
echo y > src/unrelated.sh; git add src/unrelated.sh; git commit -qm unrelated
HEAD5=$(git rev-parse HEAD)
pg_range_reviewed "$HEAD4..$HEAD5"; rc=$?
[ "$rc" -eq 1 ] && pass "range_reviewed: unrelated change != coverage (NO whitelist)" || bad "unrelated should be NOT covered (1), got $rc"

# range containment: artifact whose range covers the change commits (files don't match)
rb=$(git rev-parse "$HEAD4"); rh=$(git rev-parse "$HEAD5")
cat > memory/reviews/range-cov.md <<ART
<!-- zuvo-review -->
range: $rb..$rh
files: src/nomatch.sh
verdict: PASS
-->
ART
pg_range_reviewed "$HEAD4..$HEAD5"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: covered by range containment" || bad "range containment should be 0, got $rc"

# files: '*' wildcard grants coverage
cat > memory/reviews/star.md <<'ART'
<!-- zuvo-review -->
range: zz..zz
files: *
verdict: PASS
-->
ART
echo z > src/z.sh; git add src/z.sh; git commit -qm z
HEAD6=$(git rev-parse HEAD)
pg_range_reviewed "$HEAD5..$HEAD6"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: files:'*' wildcard covers" || bad "wildcard should be 0, got $rc"

# ---------- fail-open ----------
pg_is_substantial "zzz..yyy" && bad "bad range should NOT be substantial" || pass "fail-open: bad range not substantial"
pg_range_reviewed "zzz..yyy"; rc=$?
[ "$rc" -eq 2 ] && pass "fail-open: bad range → reviewed unknown(2)" || bad "bad range should be unknown(2), got $rc"

pg_is_substantial "" && bad "empty range should NOT be substantial" || pass "fail-open: empty range not substantial"

# no repo at all
(
  cd "$NOREPO" || exit 3
  unset PG_REPO_ROOT
  pg_is_substantial "a..b"; rs=$?
  pg_range_reviewed "a..b"; rr=$?
  [ "$rs" -eq 1 ] && [ "$rr" -eq 2 ]
) && pass "fail-open: no repo → not-substantial + unknown, no abort" || bad "no-repo fail-open wrong"

# ---------- escape valve ----------
( ZUVO_ALLOW_ADHOC=1 pg_allow_adhoc ) && pass "allow_adhoc honors env=1" || bad "adhoc=1 should be allowed"
( unset ZUVO_ALLOW_ADHOC 2>/dev/null; pg_allow_adhoc ) && bad "adhoc unset should NOT allow" || pass "allow_adhoc off when unset"

# ---------- agent-env detection ----------
( ZUVO_AGENT=1 pg_is_agent_env ) && pass "agent_env: ZUVO_AGENT=1 → agent" || bad "ZUVO_AGENT=1 should be agent"
env -i PATH="$PATH" bash -c ". '$LIB'; pg_is_agent_env" \
  && bad "clean env should be human" \
  || pass "agent_env: clean env → human (pass-through)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
