#!/usr/bin/env bash
# Task 3 — unit tests for hooks/lib/pipeline-gate-lib.sh.
# Builds a throwaway git repo fixture; sources the lib; asserts classification,
# substantiality (file + line thresholds), content-keyed review coverage
# (incl. the no-whitelist case), escape valves, agent-env detection, and
# fail-open behavior on bad range / no repo.
set -u

# Isolate every fixture from THIS machine's global git config + hooks. Without this, a fixture's
# own `git push` is intercepted by the real global zuvo pre-push gate (core.hooksPath=~/.claude/
# hooks) and blocked as "substantial unreviewed work" — which corrupts the fixture's remote state
# (the pushed ref never advances) and makes a correct gate look broken. Fixtures must be hermetic.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_CONFIG_NOSYSTEM=1

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

# ---------- R-DEL: deleted-file coverage (pg_file_blob --verify) ----------
# absent path → EMPTY blob (not the literal "ref:path" that made every deleted file an
# un-matchable "blob" and so permanently "uncovered" — the 360/409 false-block report).
[ -z "$(pg_file_blob "$TMP" HEAD "src/does-not-exist.sh")" ] \
  && pass "R-DEL: pg_file_blob absent path → empty (not literal 'ref:path')" \
  || bad "R-DEL: absent path should be empty (deleted-file literal-string bug)"

echo d1 > src/todelete.sh; git add src/todelete.sh; git commit -qm "add todelete"
DELB=$(git rev-parse HEAD)
git rm -q src/todelete.sh; git commit -qm "delete todelete (reviewed)"
DELH=$(git rev-parse HEAD)
cat > memory/reviews/del-cov.md <<ART
<!-- zuvo-review -->
range: $DELB..$DELH
files: src/todelete.sh
verdict: PASS
-->
ART
pg_range_reviewed "$DELB..$DELH"; rc=$?
[ "$rc" -eq 0 ] && pass "R-DEL: reviewed deletion COVERED (was falsely blocked)" || bad "R-DEL: reviewed deletion should be covered (got $rc)"
rm -f memory/reviews/del-cov.md

# UNreviewed deletion still blocks — even with a broad files:'*' artifact from an unrelated
# range where the file never existed ('*' must NOT silently cover a deletion).
echo d2 > src/todelete2.sh; git add src/todelete2.sh; git commit -qm "add todelete2"
D2B=$(git rev-parse HEAD)
git rm -q src/todelete2.sh; git commit -qm "delete todelete2 (UNreviewed)"
D2H=$(git rev-parse HEAD)
cat > memory/reviews/wild.md <<ART
<!-- zuvo-review -->
range: $BASE..$HEAD
files: *
verdict: PASS
-->
ART
pg_range_reviewed "$D2B..$D2H"; rc=$?
[ "$rc" -eq 1 ] && pass "R-DEL: unreviewed deletion NOT covered by unrelated files:'*' (no hole)" || bad "R-DEL: '*' must not cover an unreviewed deletion (got $rc)"
rm -f memory/reviews/wild.md

# an artifact that EXPLICITLY lists the file but whose range NEVER contained it (F absent at
# BOTH its base and head) must NOT cover the deletion — the review didn't see this removal.
cat > memory/reviews/explicit-unrelated.md <<ART
<!-- zuvo-review -->
range: $BASE..$HEAD
files: src/todelete2.sh
verdict: PASS
-->
ART
pg_range_reviewed "$D2B..$D2H"; rc=$?
[ "$rc" -eq 1 ] && pass "R-DEL: explicit artifact whose range never had F → does NOT cover deletion" || bad "R-DEL: artifact not removing F must not cover (got $rc)"
rm -f memory/reviews/explicit-unrelated.md

# range-containment: an artifact reviewing a DIFFERENT deletion of the SAME path (its range
# does NOT contain THIS deletion commit) must NOT cover it — coverage is tied to the commit.
cat > memory/reviews/other-del.md <<ART
<!-- zuvo-review -->
range: $DELB..$DELH
files: src/todelete2.sh
verdict: PASS
-->
ART
pg_range_reviewed "$D2B..$D2H"; rc=$?
[ "$rc" -eq 1 ] && pass "R-DEL: artifact for a DIFFERENT deletion of same path → NOT covered (range-containment)" || bad "R-DEL: cross-range same-path deletion must not cover (got $rc)"
rm -f memory/reviews/other-del.md

# ---------- R-UNPUSHED: pg_unpushed_range excludes already-pushed history ----------
UPT="$(mktemp -d)"; UPR="$(mktemp -d)"
(
  cd "$UPR" && git init -q --bare
  cd "$UPT" && git init -q -b main
  git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$UPR"
  echo r1 > f1.sh; git add -A; git commit -qm c1
  for i in 1 2 3; do echo "x$i" > "d$i.sh"; git add -A; git commit -qm "d$i"; done  # "develop-ahead" delta
  git push -q origin main
  git checkout -q -b feature
  echo local > local.sh; git add -A; git commit -qm "local unpushed work"
) >/dev/null 2>&1
# pg_unpushed_range now emits the @unpushed sentinel; assert the RESOLVED file set (the real
# signal) is the 1 local file, excluding the pushed develop-ahead delta.
r="$(cd "$UPT" && PG_REPO_ROOT="$UPT" bash -c '. "'"$LIB"'"; pg_unpushed_range' 2>/dev/null)"; urc=$?
uf="$(cd "$UPT" && PG_REPO_ROOT="$UPT" bash -c '. "'"$LIB"'"; pg_changed_production "@unpushed..HEAD"' 2>/dev/null | tr '\n' ' ')"
{ [ "$urc" -eq 0 ] && [ "$uf" = "local.sh " ]; } \
  && pass "R-UNPUSHED: range = only the 1 local file (excludes pushed 'develop-ahead' delta)" \
  || bad "R-UNPUSHED: should scope to local.sh only (rc=$urc files=[$uf] range=$r)"
( cd "$UPT" && git push -q origin feature >/dev/null 2>&1
  PG_REPO_ROOT="$UPT" bash -c '. "'"$LIB"'"; pg_unpushed_range' >/dev/null 2>&1; [ "$?" -eq 3 ] ) \
  && pass "R-UNPUSHED: everything pushed → exit 3 (nothing to gate)" \
  || bad "R-UNPUSHED: all-pushed should be exit 3"
rm -rf "$UPT" "$UPR"

# R-MERGE: a branch that MERGED a remote branch in (not rebased) must scope to FEATURE-ONLY.
# The merged-in remote commits live in the branch's tree, so a fork-point two-dot diff wrongly
# dragged their whole surface in and demanded coverage for it (2026-07-07 over-scope report).
MGT="$(mktemp -d)"; MGR="$(mktemp -d)"
(
  cd "$MGR" && git init -q --bare
  cd "$MGT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$MGR"
  echo base > base.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; echo feat > feature.js; git add -A; git commit -qm feat
  git checkout -q main; for i in 1 2 3; do echo "m$i" > "mainbig$i.js"; git add -A; git commit -qm "main $i"; done; git push -q origin main
  git checkout -q feat; git merge -q main -m "merge main"; echo more > feature2.js; git add -A; git commit -qm feat2
) >/dev/null 2>&1
mfiles="$(cd "$MGT" && PG_REPO_ROOT="$MGT" bash -c '. "'"$LIB"'"; r=$(pg_unpushed_range); pg_changed_production "$r"' 2>/dev/null | sort | tr '\n' ' ')"
[ "$mfiles" = "feature.js feature2.js " ] \
  && pass "R-MERGE: merged-in remote commits excluded — scope is feature-only" \
  || bad "R-MERGE: merge branch over-scoped (got: [$mfiles])"
rm -rf "$MGT" "$MGR"

# ---------- SENTINEL: pg_changed_* recognise @unpushed → git log -c --not --remotes (Task 2) ----------
STT="$(mktemp -d)"; STR="$(mktemp -d)"
(
  cd "$STR" && git init -q --bare
  cd "$STT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$STR"
  echo base > base.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; echo feat > feature.js; git add -A; git commit -qm feat
  git checkout -q main; for i in 1 2 3; do echo "m$i" > "mainbig$i.js"; git add -A; git commit -qm "main $i"; done; git push -q origin main
  git checkout -q feat; git merge -q main -m "merge main"; printf 'l1\nl2\nl3\n' > feature2.js; git add -A; git commit -qm feat2
) >/dev/null 2>&1
sf="$(cd "$STT" && PG_REPO_ROOT="$STT" bash -c '. "'"$LIB"'"; pg_changed_production "@unpushed..HEAD"' 2>/dev/null | sort | tr '\n' ' ')"
[ "$sf" = "feature.js feature2.js " ] \
  && pass "SENTINEL: pg_changed_production @unpushed → feature-only (merged main excluded)" \
  || bad "SENTINEL: pg_changed_production @unpushed got [$sf]"
sl="$(cd "$STT" && PG_REPO_ROOT="$STT" bash -c '. "'"$LIB"'"; pg_changed_lines "@unpushed..HEAD"' 2>/dev/null)"
{ [ "${sl:-0}" -ge 1 ] 2>/dev/null && [ "${sl:-0}" -lt 10 ]; } \
  && pass "SENTINEL: pg_changed_lines @unpushed counts feature lines only (=$sl, merged main excluded)" \
  || bad "SENTINEL: pg_changed_lines @unpushed got [$sl] (expected small feature-only count)"
nf="$(cd "$STT" && git checkout -q main 2>/dev/null; PG_REPO_ROOT="$STT" bash -c '. "'"$LIB"'"; pg_changed_production "HEAD~1..HEAD"' 2>/dev/null | tr '\n' ' ')"
case " $nf " in *mainbig3.js*) pass "SENTINEL/G7: non-sentinel range still uses git diff (HEAD~1..HEAD → mainbig3.js)";; *) bad "SENTINEL/G7: non-sentinel git-diff path broke (got [$nf])";; esac
rm -rf "$STT" "$STR"

# SENTINEL line-count is SAFE OVER-COUNT (churn ≥ final delta): edit-then-revert across un-pushed
# commits sums churn, so the count is ≥ the net delta — never under (adversarial-noted, by design).
CVT="$(mktemp -d)"; CVR="$(mktemp -d)"
(
  cd "$CVR" && git init -q --bare
  cd "$CVT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$CVR"
  printf 'x\n' > f.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat
  printf 'a\nb\nc\nd\ne\n' > f.js; git add -A; git commit -qm add5   # +5 churn
  printf 'x\n' > f.js; git add -A; git commit -qm revert            # -5 churn (net delta = 0)
) >/dev/null 2>&1
cl="$(cd "$CVT" && PG_REPO_ROOT="$CVT" bash -c '. "'"$LIB"'"; pg_changed_lines "@unpushed..HEAD"' 2>/dev/null)"
{ [ "${cl:-0}" -ge 10 ] 2>/dev/null; } \
  && pass "SENTINEL: line-count is safe over-count (churn=$cl ≥ net delta 0, never under-scopes)" \
  || bad "SENTINEL: expected churn≥10, got [$cl]"
rm -rf "$CVT" "$CVR"

# SENTINEL: a MERGE's conflict-resolution lines are COUNTED (combined-numstat first-pair parse),
# not silently dropped — the merge-only line under-count the aggregate review flagged.
MLT="$(mktemp -d)"; MLR="$(mktemp -d)"
(
  cd "$MLR" && git init -q --bare
  cd "$MLT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$MLR"
  printf 'l1\nl2\n' > s.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; printf 'feat1\nfeat2\nfeat3\n' > s.js; git add -A; git commit -qm "feat edits"
  git checkout -q main; printf 'main1\nmain2\nmain3\n' > s.js; git add -A; git commit -qm "main edits"; git push -q origin main
  git checkout -q feat; git merge origin/main >/dev/null 2>&1 || true
  printf 'r1\nr2\nr3\nr4\nr5\n' > s.js; git add s.js; git commit -qm "resolve"   # conflict-resolution churn
) >/dev/null 2>&1
ml="$(cd "$MLT" && PG_REPO_ROOT="$MLT" bash -c '. "'"$LIB"'"; pg_changed_lines "@unpushed..HEAD"' 2>/dev/null)"
{ [ "${ml:-0}" -ge 1 ] 2>/dev/null; } \
  && pass "SENTINEL: merge conflict-resolution lines COUNTED (=$ml, not dropped — no line under-count)" \
  || bad "SENTINEL: merge line-count dropped to [$ml] (combined-numstat under-count bug)"
rm -rf "$MLT" "$MLR"
fo="$(cd "$NOREPO" && PG_REPO_ROOT="$NOREPO" bash -c '. "'"$LIB"'"; pg_changed_production "@unpushed..HEAD"' 2>/dev/null)"
[ -z "$fo" ] && pass "SENTINEL/G8: @unpushed in non-repo → empty (fail-open)" || bad "SENTINEL/G8: expected empty, got [$fo]"

# SENTINEL deletion coverage: pg_range_reviewed must resolve the deleting commit over the @unpushed
# walk (git log "@unpushed..HEAD" is a BAD REVISION — the aggregate-review bug). A reviewed deletion
# in an un-pushed commit must be COVERED (rc 0), not falsely blocked.
DST="$(mktemp -d)"; DSR="$(mktemp -d)"
(
  cd "$DSR" && git init -q --bare
  cd "$DST" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$DSR"
  echo keep > keep.js; echo doomed > doomed.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; git rm -q doomed.js; git commit -qm "delete doomed"
  mkdir -p memory/reviews
  printf '<!-- zuvo-review -->\nrange: @unpushed..HEAD\nfiles: doomed.js\nverdict: PASS\n' > memory/reviews/cov.md
) >/dev/null 2>&1
( cd "$DST" && PG_REPO_ROOT="$DST" bash -c '. "'"$LIB"'"; pg_range_reviewed "@unpushed..HEAD"'; [ "$?" -eq 0 ] ) \
  && pass "SENTINEL: reviewed deletion in un-pushed commit is COVERED (delc resolved via --not --remotes)" \
  || bad "SENTINEL: reviewed deletion falsely blocked (git log @unpushed..HEAD bad-revision bug)"
rm -rf "$DST" "$DSR"

# ---------- Task 3: pg_unpushed_range emits @unpushed, NO merge-base loop ----------
# G5: no merge-base call inside pg_unpushed_range (O(N) loop deleted)
# count only merge-base INVOCATIONS — strip trailing '# ...' comments first so a comment that
# merely mentions "merge-base fallback" on a for-each-ref line is not miscounted as a call.
mbloop="$(awk '/^pg_unpushed_range\(\)/{f=1} f{line=$0; sub(/#.*/,"",line); if(line ~ /git .*merge-base/) c++} f&&/^}/{exit} END{print c+0}' "$LIB")"
[ "$mbloop" = "0" ] && pass "T3/G5: pg_unpushed_range has NO merge-base call (O(N) loop deleted)" || bad "T3/G5: $mbloop merge-base calls remain in pg_unpushed_range"
# emits the sentinel when remotes exist + un-pushed work
SRT="$(mktemp -d)"; SRR="$(mktemp -d)"
(
  cd "$SRR" && git init -q --bare
  cd "$SRT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$SRR"
  echo b > b.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; echo f > f.js; git add -A; git commit -qm feat
) >/dev/null 2>&1
r3="$(cd "$SRT" && PG_REPO_ROOT="$SRT" bash -c '. "'"$LIB"'"; pg_unpushed_range')"
[ "$r3" = "@unpushed..HEAD" ] && pass "T3: pg_unpushed_range emits @unpushed..HEAD (un-pushed work)" || bad "T3: expected @unpushed..HEAD got [$r3]"
( cd "$SRT" && git push -q origin feat >/dev/null 2>&1; PG_REPO_ROOT="$SRT" bash -c '. "'"$LIB"'"; pg_unpushed_range' >/dev/null 2>&1; [ "$?" -eq 3 ] ) \
  && pass "T3: everything pushed → exit 3" || bad "T3: all-pushed should exit 3"
# G6: remote-less repo → exit 1 (merge-base fallback), NOT the sentinel
NRT="$(mktemp -d)"
( cd "$NRT" && git init -q -b main; git config user.email t@t; git config user.name t; echo x>x.js; git add -A; git commit -qm x ) >/dev/null 2>&1
( cd "$NRT" && PG_REPO_ROOT="$NRT" bash -c '. "'"$LIB"'"; pg_unpushed_range' >/dev/null 2>&1; [ "$?" -eq 1 ] ) \
  && pass "T3/G6: remote-less repo → exit 1 (merge-base fallback, not sentinel)" || bad "T3/G6: remote-less should exit 1"
rm -rf "$SRT" "$SRR" "$NRT"

# ---------- Task 4: topology regression — close the whole class (G2 multi-merge, G3 conflict) ----------
# R-MULTIMERGE: a branch that merged TWO divergent remote branches → feature-only, NEITHER dragged
# in (the case the newest-remote-ancestor patch still over-scoped — now closed base-free).
MMT="$(mktemp -d)"; MMR="$(mktemp -d)"
(
  cd "$MMR" && git init -q --bare
  cd "$MMT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$MMR"
  echo base > base.js; git add -A; git commit -qm base; git push -q origin main
  git tag basepoint                                     # fork point BEFORE main advances
  git checkout -q -b other basepoint; echo o > other1.js; git add -A; git commit -qm other; git push -q origin other
  git checkout -q main; echo m > main1.js; git add -A; git commit -qm main; git push -q origin main
  # feat forks from BASEPOINT (before main1) so BOTH merges bring real new commits (not no-ops)
  git checkout -q -b feat basepoint; echo f > feature.js; git add -A; git commit -qm feat
  git merge -q origin/main -m "merge main"; git merge -q origin/other -m "merge other"
  echo f2 > feature2.js; git add -A; git commit -qm feat2
) >/dev/null 2>&1
# fixture fidelity: origin/main and origin/other must be DIVERGENT (neither an ancestor of the
# other) — else the test would not exercise the multi-merge case it claims.
( cd "$MMT" && ! git merge-base --is-ancestor origin/other origin/main 2>/dev/null && ! git merge-base --is-ancestor origin/main origin/other 2>/dev/null ) \
  && pass "R-MULTIMERGE fixture: origin/main and origin/other are genuinely divergent" \
  || bad "R-MULTIMERGE fixture: branches are NOT divergent — test would be vacuous"
mmf="$(cd "$MMT" && PG_REPO_ROOT="$MMT" bash -c '. "'"$LIB"'"; pg_changed_production "@unpushed..HEAD"' 2>/dev/null | sort | tr '\n' ' ')"
[ "$mmf" = "feature.js feature2.js " ] \
  && pass "R-MULTIMERGE/G2: two merged remote branches → feature-only (neither dragged in; old fork-point base leaked other1.js)" \
  || bad "R-MULTIMERGE/G2: got [$mmf] (expected feature.js feature2.js)"
rm -rf "$MMT" "$MMR"

# R-CONFLICT: a merge with a hand-resolved conflict → the resolved file IS in scope (no under-scope
# hole — the reviewer must see conflict-resolution changes). Uses the -c combined-diff retention.
CFT="$(mktemp -d)"; CFR="$(mktemp -d)"
(
  cd "$CFR" && git init -q --bare
  cd "$CFT" && git init -q -b main; git config user.email t@t; git config user.name t; git config commit.gpgsign false
  git remote add origin "$CFR"
  echo base > base.js; printf 'line-A\n' > shared.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; printf 'feat-version\n' > shared.js; git add -A; git commit -qm "feat edits shared"
  git checkout -q main; printf 'main-version\n' > shared.js; git add -A; git commit -qm "main edits shared"; git push -q origin main
  git checkout -q feat; git merge origin/main >/tmp/cf-merge.out 2>&1   # WILL conflict; capture, do not mask
  printf 'resolved-both\n' > shared.js; git add shared.js; git commit -qm "resolve conflict"
) >/dev/null 2>&1
# prove the merge actually CONFLICTed (else the -c conflict-retention path is not exercised)
grep -qi 'conflict' /tmp/cf-merge.out 2>/dev/null \
  && pass "R-CONFLICT fixture: merge genuinely conflicted on shared.js (exercises -c retention)" \
  || bad "R-CONFLICT fixture: merge did NOT conflict — test would not exercise conflict retention"
cff="$(cd "$CFT" && PG_REPO_ROOT="$CFT" bash -c '. "'"$LIB"'"; pg_changed_production "@unpushed..HEAD"' 2>/dev/null | tr '\n' ' ')"
case " $cff " in *" shared.js "*) pass "R-CONFLICT/G3: conflict-resolved file IS in scope (no under-scope hole)";; *) bad "R-CONFLICT/G3: conflict file dropped (got [$cff])";; esac
# and the merge-branch is SUBSTANTIAL/reviewable via the full sentinel flow (pg_is_substantial delegates)
( cd "$CFT" && PG_REPO_ROOT="$CFT" ZUVO_GATE_MIN_FILES=1 bash -c '. "'"$LIB"'"; pg_is_substantial "@unpushed..HEAD"' ) \
  && pass "R-CONFLICT: sentinel flows through pg_is_substantial (min-files=1 → substantial)" \
  || bad "R-CONFLICT: pg_is_substantial did not see the sentinel scope"
rm -rf "$CFT" "$CFR"

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
