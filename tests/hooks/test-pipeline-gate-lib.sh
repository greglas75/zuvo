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

# ---------- content-keyed review coverage (RANGE-bound: range AND files) ----------
mkdir -p memory/reviews
# covering artifact MUST record the REAL reviewed range (range-containment) + files.
cat > memory/reviews/files-cov.md <<ART
<!-- zuvo-review -->
range: $BASE..$HEAD
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
body
ART
pg_range_reviewed "$BASE..$HEAD"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: covered (range contains commits AND files a/b/c)" || bad "coverage should be 0, got $rc"

# no-whitelist (file): an UNRELATED file change is NOT covered by the a/b/c artifact
echo y > src/unrelated.sh; git add src/unrelated.sh; git commit -qm unrelated
HEAD5=$(git rev-parse HEAD)
pg_range_reviewed "$HEAD4..$HEAD5"; rc=$?
[ "$rc" -eq 1 ] && pass "range_reviewed: unrelated change != coverage (NO file whitelist)" || bad "unrelated should be NOT covered (1), got $rc"

# *** R3-1 regression: NO PERMANENT WHITELIST ***
# Re-edit a PREVIOUSLY-REVIEWED file (src/a.sh) with a NEW commit. The old
# files-cov artifact lists src/a.sh AND has files:* siblings, but its RANGE does
# not contain the new commit → must be NOT covered (a new review is required).
echo "changed again" >> src/a.sh; git add src/a.sh; git commit -qm "re-edit a.sh"
HEAD_A2=$(git rev-parse HEAD)
pg_range_reviewed "$HEAD5..$HEAD_A2"; rc=$?
[ "$rc" -eq 1 ] && pass "R3-1: re-edit of reviewed file w/ NEW commit NOT covered (no permanent whitelist)" || bad "R3-1: permanent-whitelist hole — re-edit should NOT be covered (got $rc)"

# range+files BOTH required: artifact whose range covers but files DON'T → NOT covered
rb=$(git rev-parse "$HEAD4"); rh=$(git rev-parse "$HEAD5")
cat > memory/reviews/range-only.md <<ART
<!-- zuvo-review -->
range: $rb..$rh
files: src/nomatch.sh
verdict: PASS
-->
ART
pg_range_reviewed "$HEAD4..$HEAD5"; rc=$?
[ "$rc" -eq 1 ] && pass "range_reviewed: range covers but files don't → NOT covered (AND, not OR)" || bad "range-only (no file match) should NOT cover, got $rc"
# same range but files:* → covered (within range)
cat > memory/reviews/range-only.md <<ART
<!-- zuvo-review -->
range: $rb..$rh
files: *
verdict: PASS
-->
ART
pg_range_reviewed "$HEAD4..$HEAD5"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: range covers AND files:* → covered (within range)" || bad "range + files:* should cover, got $rc"
rm -f memory/reviews/range-only.md

# ADV-4 (gemini): a reviewed filename containing SPACES must stay intact (comma-split only)
out="$(pg_files_covered "src/api specs.sh" "src/api specs.sh, src/b.sh")" ; rc=$?
[ "$rc" -eq 0 ] && pass "pg_files_covered: filename-with-spaces preserved (ADV-4)" || bad "ADV-4: spaced filename should be covered (rc=$rc)"
out="$(pg_files_covered "src/other.sh" "src/api specs.sh, src/b.sh")" ; rc=$?
[ "$rc" -eq 1 ] && pass "pg_files_covered: spaced-list still rejects unrelated file (ADV-4)" || bad "ADV-4: unrelated should not be covered (rc=$rc)"

# files: '*' wildcard grants coverage WITHIN its reviewed range
echo z > src/z.sh; git add src/z.sh; git commit -qm z
HEAD6=$(git rev-parse HEAD)
zb=$(git rev-parse "$HEAD_A2"); zh=$(git rev-parse "$HEAD6")
cat > memory/reviews/star.md <<ART
<!-- zuvo-review -->
range: $zb..$zh
files: *
verdict: PASS
-->
ART
pg_range_reviewed "$HEAD_A2..$HEAD6"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: files:'*' covers within its range" || bad "wildcard should be 0, got $rc"

# *** content coverage across a MULTI-AGENT / contaminated range (the key fix) ***
# Two "agents" each review only their own file; a push spanning BOTH commits is
# covered per-FILE-CONTENT even though no single artifact covers the whole range
# and the range mixes both agents' commits. "Review already ran in the pipeline"
# → no redundant standalone review.
git checkout -q -b multiagent "$HEAD6" 2>/dev/null || git checkout -q multiagent
echo "agent1 work" > src/foo.sh; git add src/foo.sh; git commit -qm "agent1 foo"
A1=$(git rev-parse HEAD); A1B=$(git rev-parse "$HEAD6")
cat > memory/reviews/agent1.md <<ART
<!-- zuvo-review -->
range: $A1B..$A1
files: src/foo.sh
verdict: PASS
-->
ART
echo "agent2 work" > src/bar.sh; git add src/bar.sh; git commit -qm "agent2 bar"
A2=$(git rev-parse HEAD)
cat > memory/reviews/agent2.md <<ART
<!-- zuvo-review -->
range: $A1..$A2
files: src/bar.sh
verdict: PASS
-->
ART
pg_range_reviewed "$HEAD6..$A2"; rc=$?
[ "$rc" -eq 0 ] && pass "content-coverage: multi-agent range covered per-file (foo↔A1, bar↔A2)" || bad "multi-agent per-file content should cover, got $rc"

# one FREELANCE file (no artifact) in the range → whole push NOT covered
echo "freelance" > src/baz.sh; git add src/baz.sh; git commit -qm "freelance baz"
A3=$(git rev-parse HEAD)
pg_range_reviewed "$HEAD6..$A3"; rc=$?
[ "$rc" -eq 1 ] && pass "content-coverage: one freelance file → whole push NOT covered (incident still caught)" || bad "freelance file should block, got $rc"

# re-edit a reviewed file to NEW content → its old artifact no longer covers it
echo "tampered" >> src/foo.sh; git add src/foo.sh; git commit -qm "tamper foo after review"
A4=$(git rev-parse HEAD)
pg_range_reviewed "$A3..$A4"; rc=$?   # range = just the tampered-foo commit
[ "$rc" -eq 1 ] && pass "content-coverage: tampered (re-edited) reviewed file → NOT covered" || bad "tampered file should not be covered, got $rc"
git checkout -q feature 2>/dev/null || true

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
