#!/usr/bin/env bash
# Task 3 — unit tests for hooks/lib/pipeline-gate-lib.sh.
# Builds throwaway git repo fixtures; sources the lib; asserts classification,
# substantiality (file + line thresholds), content-keyed review coverage
# (incl. the no-whitelist case), the proof-of-work layer's PG_PROOF_OPTIONAL
# CI-degrade and proof-path traversal rejection, escape valves, agent-env
# detection, and fail-open behavior on bad range / no repo.
#
# Q9/Q19 (test-quality-audit 2026-09-28-plan-b): ~13 fixtures below used to open-code an
# identical git-init/config/remote-add bootstrap, and the FIRST one grew into a single
# continuously-evolving repo that every later assertion (HEAD2..HEAD6, the multiagent branch)
# depended on in sequence — a failure partway through invalidated everything after it. Fixed by
# extracting new_remote_fixture / new_local_fixture (one helper, one place to fix a fixture bug)
# and splitting that first mega-fixture into three independent ones (SUBT/COVT/DELT), each
# runnable alone, the way R-UNPUSHED/R-MERGE/SENTINEL below already did it.
set -u
# This suite exercises the CONTENT-KEY logic; the adversarial proof-of-work layer (added
# 2026-07-23) is covered by test-review-proof-gate.sh AND, since 2026-09-28, this file's own
# PG_PROOF_OPTIONAL / traversal block below. Grandfather the cutoff off HERE so the fixtures that
# test content-keying test it in isolation, exactly as they did before that layer existed; the
# proof-of-work block explicitly lowers it per-call where it needs the real behavior.
export PG_REVIEW_PROOF_CUTOFF=99999999999

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

# ADV-C97: every fixture below is created via a bare `mktemp -d` (no explicit path), which honors
# $TMPDIR — scope ALL of them under one run-owned temp root so a single EXIT trap reclaims
# everything, not just the first fixture (NOREPO, the only one that previously had its own trap).
# Before this, a fixture-init failure that hit its own `{ bad ...; exit 1; }` handler leaked that
# one already-created temp dir (cosmetic — disk litter on failure, not a correctness bug — but
# free to close by scoping TMPDIR once here rather than touching every mktemp call site).
_PGL_RUN_TMP="$(mktemp -d "${TMPDIR:-/tmp}/pgl-run.XXXXXX")" || { echo "FAIL: cannot create run temp root"; exit 1; }
export TMPDIR="$_PGL_RUN_TMP"
trap 'rm -rf "$_PGL_RUN_TMP"' EXIT

# shellcheck source=/dev/null
. "$LIB" || { echo "FAIL: cannot source lib"; exit 1; }
[ "${PG_LIB_LOADED:-}" = "1" ] && pass "lib sourced" || bad "lib not loaded"

# new_remote_fixture <local-dir> <bare-dir> [default-branch=main] — a throwaway git repo at
# <local-dir> (fixed test identity, gpgsign off) with a bare "origin" at <bare-dir> already
# `git remote add`-ed. Nothing is committed or pushed here — every fixture using this makes its
# OWN first commit and decides for itself when to push, since the unpushed-vs-pushed boundary is
# exactly what most of these fixtures exist to exercise.
new_remote_fixture() {
  local _local="$1" _bare="$2" _branch="${3:-main}"
  ( cd "$_bare" && git init -q --bare ) >/dev/null 2>&1 || return 1
  (
    cd "$_local" || exit 1
    git init -q -b "$_branch" 2>/dev/null || { git init -q; git symbolic-ref HEAD "refs/heads/$_branch"; }
    git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
    git remote add origin "$_bare"
  ) >/dev/null 2>&1
}

# new_local_fixture <dir> [default-branch=main] — a throwaway git repo at <dir>, no remote, with
# one base commit (base.txt) already made, so callers can build production-file history and diff
# from a captured base SHA or HEAD~N. Used by fixtures that never touch push/unpushed semantics.
# ADV-C99 (+dup C105/C106/C116): every derived SHA a caller computes (HEAD~4, main~4, …) assumes
# this helper makes EXACTLY one base commit, with no assertion anywhere pinning that contract — a
# future edit here would silently mis-scope every derived SHA downstream instead of failing loudly.
# Asserted here, at the ONE place that contract is created, rather than at each of the many call
# sites that rely on it.
new_local_fixture() {
  local _dir="$1" _branch="${2:-main}" _n
  (
    cd "$_dir" || exit 1
    git init -q -b "$_branch" 2>/dev/null || { git init -q; git symbolic-ref HEAD "refs/heads/$_branch"; }
    git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
    echo base > base.txt; git add base.txt; git commit -qm base
  ) >/dev/null 2>&1
  _n="$(git -C "$_dir" rev-list --count HEAD 2>/dev/null)" || _n=""
  [ "$_n" = "1" ] || return 1
}

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

# Generated proofs live under `.zuvo/` (leading dot) and must not count as production —
# `zuvo/*` alone missed them, so every proof regeneration demanded an adversarial review of
# machine-written text. The generator that writes them stays production.
out="$(printf '%s\n' .zuvo/proofs/T3A-org-scope-procedure-scan.txt pkg/.zuvo/proofs/a.txt \
  scripts/t3a/generate-all.ts \
  | pg_classify_files | tr '\n' ' ')"
if [ "$out" = "scripts/t3a/generate-all.ts " ]; then
  pass "classify drops generated .zuvo/ proofs but keeps their generator"
else
  bad ".zuvo/ proofs wrongly classified: [$out]"
fi

# Extensionless repo-metadata files must NOT count as production: otherwise a pure
# release commit (VERSION bump; every other file in it already excluded as *.md/*.json)
# reads as production work and demands its own review artifact.
out="$(printf '%s\n' \
  VERSION pkg/VERSION CHANGELOG LICENSE LICENCE NOTICE AUTHORS CONTRIBUTORS \
  | pg_classify_files | tr '\n' ' ')"
if [ -z "$out" ]; then
  pass "classify drops extensionless repo-metadata (VERSION/CHANGELOG/LICENSE/...)"
else
  bad "metadata wrongly classified production: [$out]"
fi

# ...but build logic with no extension is STILL production — the exclusion above must not
# turn into "anything without a dot is metadata".
out="$(printf '%s\n' Makefile Dockerfile scripts/release.sh src/app.ts CODEOWNERS .github/CODEOWNERS \
  | pg_classify_files | sort | tr '\n' ' ')"
if [ "$out" = ".github/CODEOWNERS CODEOWNERS Dockerfile Makefile scripts/release.sh src/app.ts " ]; then
  pass "classify keeps build logic + CODEOWNERS (governance) as production"
else
  bad "build logic wrongly dropped: [$out]"
fi

# ---------- pg_files_covered: pure string function, no fixture needed at all ----------
# ADV-4 (gemini): a reviewed filename containing SPACES must stay intact (comma-split only)
out="$(pg_files_covered "src/api specs.sh" "src/api specs.sh, src/b.sh")" ; rc=$?
[ "$rc" -eq 0 ] && pass "pg_files_covered: filename-with-spaces preserved (ADV-4)" || bad "ADV-4: spaced filename should be covered (rc=$rc)"
# B-12: a path containing a COMMA must never be covered by two unrelated neighbours. The old
# implementation re-joined the artifact's entries into ",a,b,c," and substring-matched ",$f," —
# so an artifact listing `src/a` and `b.js` produced ",src/a,b.js," and a query for the
# NEVER-REVIEWED file `src/a,b.js` matched across the boundary and read as COVERED. Coverage is
# what decides whether a push is gated, so this was a real hole, demonstrated by probe.
pg_files_covered "src/a,b.js" "src/a, b.js,src/other.js" ; rc=$?
[ "$rc" -eq 1 ] && pass "B-12: comma-in-path is NOT covered by two unrelated neighbours" \
  || bad "B-12: comma-in-path falsely covered (rc=$rc) — entry-boundary hole is back"
# The safe half of the residue: such a path is simply never covered, which demands a fresh review
# rather than granting a false one. Pinned so a future 'improvement' cannot flip the direction.
# ADV-C93 (MUST-FIX, confidence-rescored): both branches used to call `pass`, so this assertion
# could never fail no matter what pg_files_covered returned — it masked the documented B-12
# contract (prod comment, hooks/lib/pipeline-gate-lib.sh:260-263) that such a path must ALWAYS
# read as uncovered (rc=1). Pinned to `bad` on the other branch, per that contract.
pg_files_covered "src/a,b.js" "src/a,b.js" ; rc=$?
[ "$rc" -eq 1 ] && pass "B-12: comma path stays uncovered even when listed (files: cannot express it)" \
  || bad "B-12: comma path must stay uncovered per the documented contract, got rc=$rc"
out="$(pg_files_covered "src/other.sh" "src/api specs.sh, src/b.sh")" ; rc=$?
[ "$rc" -eq 1 ] && pass "pg_files_covered: spaced-list still rejects unrelated file (ADV-4)" || bad "ADV-4: unrelated should not be covered (rc=$rc)"

# ---------- no-repo fixture, used by several fail-open checks below ----------
# (cleanup: the run-wide EXIT trap above now covers this, not a dedicated trap here)
NOREPO="$(mktemp -d)"

# ---------- FIXTURE SUBT: substantiality thresholds (file / line count, docs exclusion) ----------
SUBT="$(mktemp -d)"
new_local_fixture "$SUBT" || { bad "SUBT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$SUBT" || exit 1
  mkdir -p src; echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
  git add src; git commit -qm "feat: three prod files"
  echo tiny > src/tiny.sh; git add src/tiny.sh; git commit -qm tiny
  mkdir -p docs; for i in $(seq 1 200); do echo "line $i" >> docs/big.md; done
  git add docs/big.md; git commit -qm "big docs"
  for i in $(seq 1 200); do echo "x$i" >> src/big.sh; done
  git add src/big.sh; git commit -qm "big prod"
) >/dev/null 2>&1
SBASE="$(git -C "$SUBT" rev-parse HEAD~4)"
SHEAD="$(git -C "$SUBT" rev-parse HEAD~3)"
SHEAD2="$(git -C "$SUBT" rev-parse HEAD~2)"
SHEAD3="$(git -C "$SUBT" rev-parse HEAD~1)"
SHEAD4="$(git -C "$SUBT" rev-parse HEAD)"

# substantial via FILE count (3 prod files)
PG_REPO_ROOT="$SUBT" pg_is_substantial "$SBASE..$SHEAD" && pass "substantial: 3 prod files (file threshold)" || bad "3 files should be substantial"
# NOT substantial: single small prod file
PG_REPO_ROOT="$SUBT" pg_is_substantial "$SHEAD..$SHEAD2" && bad "1 small prod file should NOT be substantial" || pass "not substantial: 1 small prod file"
# NOT substantial: docs-only, even at 200 lines (classifier excludes docs)
PG_REPO_ROOT="$SUBT" pg_is_substantial "$SHEAD2..$SHEAD3" && bad "docs-only should NOT be substantial" || pass "not substantial: docs-only 200 lines"
# substantial via LINE count: 1 prod file, 200 lines
PG_REPO_ROOT="$SUBT" pg_is_substantial "$SHEAD3..$SHEAD4" && pass "substantial: 1 file 200 lines (line threshold)" || bad "200 prod lines should be substantial"
# env-override: raise MIN_LINES above 200 → same change not substantial
( PG_REPO_ROOT="$SUBT" ZUVO_GATE_MIN_LINES=9999 ZUVO_GATE_MIN_FILES=99 pg_is_substantial "$SHEAD3..$SHEAD4" ) \
  && bad "raised thresholds should make it not substantial" \
  || pass "thresholds env-overridable (ZUVO_GATE_MIN_LINES/FILES)"
rm -rf "$SUBT"

# ---------- FIXTURE COVT: content-keyed review coverage (RANGE-bound: range AND files) ----------
COVT="$(mktemp -d)"
new_local_fixture "$COVT" || { bad "COVT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$COVT" || exit 1
  mkdir -p src memory/reviews
  echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
  git add src; git commit -qm "feat: three prod files"
  # no-whitelist (file): an UNRELATED file change is NOT covered by the a/b/c artifact
  echo y > src/unrelated.sh; git add src/unrelated.sh; git commit -qm unrelated
  # *** R3-1 regression: NO PERMANENT WHITELIST *** — re-edit a PREVIOUSLY-REVIEWED file
  # (src/a.sh) with a NEW commit.
  echo "changed again" >> src/a.sh; git add src/a.sh; git commit -qm "re-edit a.sh"
  # files: '*' wildcard grants coverage WITHIN its reviewed range
  echo z > src/z.sh; git add src/z.sh; git commit -qm z
  # *** content coverage across a MULTI-AGENT / contaminated range (the key fix) ***
  git checkout -q -b multiagent
  echo "agent1 work" > src/foo.sh; git add src/foo.sh; git commit -qm "agent1 foo"
  echo "agent2 work" > src/bar.sh; git add src/bar.sh; git commit -qm "agent2 bar"
  # one FREELANCE file (no artifact) in the range → whole push NOT covered
  echo "freelance" > src/baz.sh; git add src/baz.sh; git commit -qm "freelance baz"
  # re-edit a reviewed file to NEW content → its old artifact no longer covers it
  echo "tampered" >> src/foo.sh; git add src/foo.sh; git commit -qm "tamper foo after review"
) >/dev/null 2>&1
CBASE="$(git -C "$COVT" rev-parse main~4)"
CHEAD="$(git -C "$COVT" rev-parse main~3)"
CHEAD2="$(git -C "$COVT" rev-parse main~2)"
CHEAD3="$(git -C "$COVT" rev-parse main~1)"
CHEAD4="$(git -C "$COVT" rev-parse main)"
A1="$(git -C "$COVT" rev-parse multiagent~3)"
A2="$(git -C "$COVT" rev-parse multiagent~2)"
A3="$(git -C "$COVT" rev-parse multiagent~1)"
A4="$(git -C "$COVT" rev-parse multiagent)"

# covering artifact MUST record the REAL reviewed range (range-containment) + files.
cat > "$COVT/memory/reviews/files-cov.md" <<ART
<!-- zuvo-review -->
range: $CBASE..$CHEAD
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
body
ART
PG_REPO_ROOT="$COVT" pg_range_reviewed "$CBASE..$CHEAD"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: covered (range contains commits AND files a/b/c)" || bad "coverage should be 0, got $rc"

PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD..$CHEAD2"; rc=$?
[ "$rc" -eq 1 ] && pass "range_reviewed: unrelated change != coverage (NO file whitelist)" || bad "unrelated should be NOT covered (1), got $rc"

PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD2..$CHEAD3"; rc=$?
[ "$rc" -eq 1 ] && pass "R3-1: re-edit of reviewed file w/ NEW commit NOT covered (no permanent whitelist)" || bad "R3-1: permanent-whitelist hole — re-edit should NOT be covered (got $rc)"

# range+files BOTH required: artifact whose range covers but files DON'T → NOT covered
cat > "$COVT/memory/reviews/range-only.md" <<ART
<!-- zuvo-review -->
range: $CHEAD..$CHEAD2
files: src/nomatch.sh
verdict: PASS
-->
ART
PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD..$CHEAD2"; rc=$?
[ "$rc" -eq 1 ] && pass "range_reviewed: range covers but files don't → NOT covered (AND, not OR)" || bad "range-only (no file match) should NOT cover, got $rc"
# same range but files:* → covered (within range)
cat > "$COVT/memory/reviews/range-only.md" <<ART
<!-- zuvo-review -->
range: $CHEAD..$CHEAD2
files: *
verdict: PASS
-->
ART
PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD..$CHEAD2"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: range covers AND files:* → covered (within range)" || bad "range + files:* should cover, got $rc"
rm -f "$COVT/memory/reviews/range-only.md"

# files: '*' wildcard grants coverage WITHIN its reviewed range
cat > "$COVT/memory/reviews/star.md" <<ART
<!-- zuvo-review -->
range: $CHEAD3..$CHEAD4
files: *
verdict: PASS
-->
ART
PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD3..$CHEAD4"; rc=$?
[ "$rc" -eq 0 ] && pass "range_reviewed: files:'*' covers within its range" || bad "wildcard should be 0, got $rc"

# Two "agents" each review only their own file; a push spanning BOTH commits is covered
# per-FILE-CONTENT even though no single artifact covers the whole range and the range mixes
# both agents' commits. "Review already ran in the pipeline" → no redundant standalone review.
cat > "$COVT/memory/reviews/agent1.md" <<ART
<!-- zuvo-review -->
range: $CHEAD4..$A1
files: src/foo.sh
verdict: PASS
-->
ART
cat > "$COVT/memory/reviews/agent2.md" <<ART
<!-- zuvo-review -->
range: $A1..$A2
files: src/bar.sh
verdict: PASS
-->
ART
PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD4..$A2"; rc=$?
[ "$rc" -eq 0 ] && pass "content-coverage: multi-agent range covered per-file (foo↔A1, bar↔A2)" || bad "multi-agent per-file content should cover, got $rc"

PG_REPO_ROOT="$COVT" pg_range_reviewed "$CHEAD4..$A3"; rc=$?
[ "$rc" -eq 1 ] && pass "content-coverage: one freelance file → whole push NOT covered (incident still caught)" || bad "freelance file should block, got $rc"

PG_REPO_ROOT="$COVT" pg_range_reviewed "$A3..$A4"; rc=$?   # range = just the tampered-foo commit
[ "$rc" -eq 1 ] && pass "content-coverage: tampered (re-edited) reviewed file → NOT covered" || bad "tampered file should not be covered, got $rc"
rm -rf "$COVT"

# ---------- FIXTURE DELT: R-DEL deleted-file coverage (pg_file_blob --verify) ----------
DELT="$(mktemp -d)"
new_local_fixture "$DELT" || { bad "DELT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$DELT" || exit 1
  mkdir -p src memory/reviews
  echo d1 > src/todelete.sh; git add src/todelete.sh; git commit -qm "add todelete"
  git rm -q src/todelete.sh; git commit -qm "delete todelete (reviewed)"
  mkdir -p src   # git rm removed src/ entirely once it emptied out — recreate before todelete2
  echo d2 > src/todelete2.sh; git add src/todelete2.sh; git commit -qm "add todelete2"
  git rm -q src/todelete2.sh; git commit -qm "delete todelete2 (UNreviewed)"
) >/dev/null 2>&1
DBASE="$(git -C "$DELT" rev-parse HEAD~4)"
DELB="$(git -C "$DELT" rev-parse HEAD~3)"
DELH="$(git -C "$DELT" rev-parse HEAD~2)"
D2B="$(git -C "$DELT" rev-parse HEAD~1)"
D2H="$(git -C "$DELT" rev-parse HEAD)"

# absent path → EMPTY blob (not the literal "ref:path" that made every deleted file an
# un-matchable "blob" and so permanently "uncovered" — the 360/409 false-block report).
[ -z "$(pg_file_blob "$DELT" HEAD "src/does-not-exist.sh")" ] \
  && pass "R-DEL: pg_file_blob absent path → empty (not literal 'ref:path')" \
  || bad "R-DEL: absent path should be empty (deleted-file literal-string bug)"

cat > "$DELT/memory/reviews/del-cov.md" <<ART
<!-- zuvo-review -->
range: $DELB..$DELH
files: src/todelete.sh
verdict: PASS
-->
ART
PG_REPO_ROOT="$DELT" pg_range_reviewed "$DELB..$DELH"; rc=$?
[ "$rc" -eq 0 ] && pass "R-DEL: reviewed deletion COVERED (was falsely blocked)" || bad "R-DEL: reviewed deletion should be covered (got $rc)"
rm -f "$DELT/memory/reviews/del-cov.md"

# UNreviewed deletion still blocks — even with a broad files:'*' artifact from an unrelated
# range where the file never existed ('*' must NOT silently cover a deletion).
cat > "$DELT/memory/reviews/wild.md" <<ART
<!-- zuvo-review -->
range: $DBASE..$DELH
files: *
verdict: PASS
-->
ART
PG_REPO_ROOT="$DELT" pg_range_reviewed "$D2B..$D2H"; rc=$?
[ "$rc" -eq 1 ] && pass "R-DEL: unreviewed deletion NOT covered by unrelated files:'*' (no hole)" || bad "R-DEL: '*' must not cover an unreviewed deletion (got $rc)"
rm -f "$DELT/memory/reviews/wild.md"

# an artifact that EXPLICITLY lists the file but whose range NEVER contained it (F absent at
# BOTH its base and head) must NOT cover the deletion — the review didn't see this removal.
cat > "$DELT/memory/reviews/explicit-unrelated.md" <<ART
<!-- zuvo-review -->
range: $DBASE..$DELH
files: src/todelete2.sh
verdict: PASS
-->
ART
PG_REPO_ROOT="$DELT" pg_range_reviewed "$D2B..$D2H"; rc=$?
[ "$rc" -eq 1 ] && pass "R-DEL: explicit artifact whose range never had F → does NOT cover deletion" || bad "R-DEL: artifact not removing F must not cover (got $rc)"
rm -f "$DELT/memory/reviews/explicit-unrelated.md"

# range-containment: an artifact reviewing a DIFFERENT deletion of the SAME path (its range
# does NOT contain THIS deletion commit) must NOT cover it — coverage is tied to the commit.
cat > "$DELT/memory/reviews/other-del.md" <<ART
<!-- zuvo-review -->
range: $DELB..$DELH
files: src/todelete2.sh
verdict: PASS
-->
ART
PG_REPO_ROOT="$DELT" pg_range_reviewed "$D2B..$D2H"; rc=$?
[ "$rc" -eq 1 ] && pass "R-DEL: artifact for a DIFFERENT deletion of same path → NOT covered (range-containment)" || bad "R-DEL: cross-range same-path deletion must not cover (got $rc)"
rm -f "$DELT/memory/reviews/other-del.md"
rm -rf "$DELT"

# ---------- R-UNPUSHED: pg_unpushed_range excludes already-pushed history ----------
UPT="$(mktemp -d)"; UPR="$(mktemp -d)"
new_remote_fixture "$UPT" "$UPR" || { bad "UPT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$UPT" || exit 1
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
new_remote_fixture "$MGT" "$MGR" || { bad "MGT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$MGT" || exit 1
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
new_remote_fixture "$STT" "$STR" || { bad "STT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$STT" || exit 1
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
new_remote_fixture "$CVT" "$CVR" || { bad "CVT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$CVT" || exit 1
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
new_remote_fixture "$MLT" "$MLR" || { bad "MLT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$MLT" || exit 1
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
new_remote_fixture "$DST" "$DSR" || { bad "DST fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$DST" || exit 1
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
new_remote_fixture "$SRT" "$SRR" || { bad "SRT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$SRT" || exit 1
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
new_remote_fixture "$MMT" "$MMR" || { bad "MMT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$MMT" || exit 1
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
# CF_MERGE_OUT is mktemp'd, NOT the fixed /tmp/cf-merge.out it used to be: two concurrent runs of
# this file (two sessions, or a farm running the suite in parallel) raced on that shared path, and
# one process's merge output could be overwritten between the `git merge` and the `grep` below —
# producing a spurious "merge did NOT conflict" failure in the one suite that verifies the coverage
# functions. Reproduced under 4 concurrent invocations; serial runs never showed it.
CFT="$(mktemp -d)"; CFR="$(mktemp -d)"; CF_MERGE_OUT="$(mktemp -t cf-merge.XXXXXX)"
new_remote_fixture "$CFT" "$CFR" || { bad "CFT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$CFT" || exit 1
  echo base > base.js; printf 'line-A\n' > shared.js; git add -A; git commit -qm base; git push -q origin main
  git checkout -q -b feat; printf 'feat-version\n' > shared.js; git add -A; git commit -qm "feat edits shared"
  git checkout -q main; printf 'main-version\n' > shared.js; git add -A; git commit -qm "main edits shared"; git push -q origin main
  git checkout -q feat; git merge origin/main >"$CF_MERGE_OUT" 2>&1   # WILL conflict; capture, do not mask
  printf 'resolved-both\n' > shared.js; git add shared.js; git commit -qm "resolve conflict"
) >/dev/null 2>&1
# prove the merge actually CONFLICTed (else the -c conflict-retention path is not exercised)
grep -qi 'conflict' "$CF_MERGE_OUT" 2>/dev/null \
  && pass "R-CONFLICT fixture: merge genuinely conflicted on shared.js (exercises -c retention)" \
  || bad "R-CONFLICT fixture: merge did NOT conflict — test would not exercise conflict retention"
cff="$(cd "$CFT" && PG_REPO_ROOT="$CFT" bash -c '. "'"$LIB"'"; pg_changed_production "@unpushed..HEAD"' 2>/dev/null | tr '\n' ' ')"
case " $cff " in *" shared.js "*) pass "R-CONFLICT/G3: conflict-resolved file IS in scope (no under-scope hole)";; *) bad "R-CONFLICT/G3: conflict file dropped (got [$cff])";; esac
# and the merge-branch is SUBSTANTIAL/reviewable via the full sentinel flow (pg_is_substantial delegates)
( cd "$CFT" && PG_REPO_ROOT="$CFT" ZUVO_GATE_MIN_FILES=1 bash -c '. "'"$LIB"'"; pg_is_substantial "@unpushed..HEAD"' ) \
  && pass "R-CONFLICT: sentinel flows through pg_is_substantial (min-files=1 → substantial)" \
  || bad "R-CONFLICT: pg_is_substantial did not see the sentinel scope"
rm -rf "$CFT" "$CFR" "$CF_MERGE_OUT"

# ---------- pg_uncovered_files: the ENUMERATION half of content-keyed coverage ----------
# pg_range_reviewed answers "is this range covered?"; pg_uncovered_files answers "which files
# are NOT?" so zuvo:ship can scope review to them instead of re-reviewing the whole range.
# The failure directions are INVERTED relative to the gates: there, a wrong answer blocks a
# push; here, a wrongly-EMPTY answer SKIPS a review. So every assertion below pins one of
# (a) an uncovered file is printed, or (b) an error is distinguishable from "all covered".
UCT="$(mktemp -d)"
new_local_fixture "$UCT" || { bad "UCT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$UCT" || exit 1
  mkdir -p src
  echo one > src/one.sh; echo two > src/two.sh; git add src; git commit -qm "two prod files"
) >/dev/null 2>&1
UCB=$(git -C "$UCT" rev-parse HEAD~1); UCH=$(git -C "$UCT" rev-parse HEAD)
uc() { UC_OUT="$(PG_REPO_ROOT="$UCT" pg_uncovered_files "$1" 2>/dev/null)"; UC_RC=$?; UC_N="$(printf '%s' "$UC_OUT" | grep -c . )"; }

# No memory/reviews/ dir at all → nothing is covered, so BOTH files must be printed (rc 0).
# An empty answer here would tell ship "already reviewed" about a repo with no reviews at all.
uc "$UCB..$UCH"
{ [ "$UC_RC" -eq 0 ] && [ "$(printf '%s' "$UC_OUT" | sort | tr '\n' ' ')" = "src/one.sh src/two.sh " ]; } \
  && pass "uncovered_files: no reviews dir → every production file listed by name (rc 0)" \
  || bad "uncovered_files: no-reviews-dir should list exactly one.sh+two.sh (rc=$UC_RC out=[$UC_OUT])"

# reviews/ EXISTS but holds no artifacts — the `[ -d "$reviews" ]` true-branch must still degrade
# to "nothing is covered". Every other coverage test below has an artifact present, so without
# this one the empty-glob path is never exercised.
mkdir -p "$UCT/memory/reviews"
uc "$UCB..$UCH"
{ [ "$UC_RC" -eq 0 ] && [ "$UC_N" -eq 2 ]; } \
  && pass "uncovered_files: reviews/ present but EMPTY → still lists both (empty-glob path)" \
  || bad "uncovered_files: empty reviews dir should list both (rc=$UC_RC out=[$UC_OUT])"
cat > "$UCT/memory/reviews/all-cov.md" <<ART
<!-- zuvo-review -->
range: $UCB..$UCH
files: src/one.sh, src/two.sh
verdict: PASS
-->
ART
uc "$UCB..$UCH"
{ [ "$UC_RC" -eq 0 ] && [ -z "$UC_OUT" ]; } \
  && pass "uncovered_files: all covered → empty stdout, rc 0 (ship's 'reused' row)" \
  || bad "uncovered_files: fully covered should be empty rc0 (rc=$UC_RC out=[$UC_OUT])"

# Partial: an artifact listing only ONE of the two files must leave the other listed. This is
# the assertion that keeps ship's scoped review honest — a "covered" verdict that swallowed
# src/two.sh would ship it unreviewed.
cat > "$UCT/memory/reviews/all-cov.md" <<ART
<!-- zuvo-review -->
range: $UCB..$UCH
files: src/one.sh
verdict: PASS
-->
ART
uc "$UCB..$UCH"
{ [ "$UC_RC" -eq 0 ] && [ "$UC_OUT" = "src/two.sh" ]; } \
  && pass "uncovered_files: partial coverage → ONLY the uncovered file (src/two.sh)" \
  || bad "uncovered_files: partial should print src/two.sh alone (rc=$UC_RC out=[$UC_OUT])"

# STALE CONTENT: the artifact still lists src/one.sh, but the file was edited after the review,
# so its current blob is not the reviewed one. Content-keying must re-open it.
cat > "$UCT/memory/reviews/all-cov.md" <<ART
<!-- zuvo-review -->
range: $UCB..$UCH
files: src/one.sh, src/two.sh
verdict: PASS
-->
ART
( cd "$UCT" && echo "edited after review" >> src/one.sh && git add src/one.sh && git commit -qm "edit one" ) >/dev/null 2>&1
UCH2=$(git -C "$UCT" rev-parse HEAD)
uc "$UCB..$UCH2"
# EXACT equality, not a substring match: this must also prove src/two.sh did NOT leak into the
# output. A `case *src/one.sh*` would pass just as happily if the function listed everything.
{ [ "$UC_RC" -eq 0 ] && [ "$UC_OUT" = "src/one.sh" ]; } \
  && pass "uncovered_files: file edited after its review → ONLY it is uncovered (stale blob)" \
  || bad "uncovered_files: stale content must be exactly src/one.sh (rc=$UC_RC out=[$UC_OUT])"

# WILDCARD + stale: `files: *` grants coverage to any path, but coverage is still keyed per-file
# on the BLOB. A wildcard artifact whose reviewed head predates the edit must NOT cover the
# edited file — otherwise one `files: *` artifact would be a permanent blanket ship-skips-review.
cat > "$UCT/memory/reviews/all-cov.md" <<ART
<!-- zuvo-review -->
range: $UCB..$UCH
files: *
verdict: PASS
-->
ART
uc "$UCB..$UCH2"
{ [ "$UC_RC" -eq 0 ] && [ "$UC_OUT" = "src/one.sh" ]; } \
  && pass "uncovered_files: files:'*' does NOT cover a file edited after its review (blob still wins)" \
  || bad "uncovered_files: wildcard must not blanket-cover stale content (rc=$UC_RC out=[$UC_OUT])"
cat > "$UCT/memory/reviews/all-cov.md" <<ART
<!-- zuvo-review -->
range: $UCB..$UCH
files: src/one.sh, src/two.sh
verdict: PASS
-->
ART

# PROOF-OF-WORK: this suite grandfathers proofs off globally (PG_REVIEW_PROOF_CUTOFF at the top),
# so lower the cutoff for THIS assertion only. An artifact with no `adversarial:` line grants no
# coverage — otherwise ship would reuse a review that was never proven to have run.
UC_OUT="$(PG_REPO_ROOT="$UCT" PG_REVIEW_PROOF_CUTOFF=0 pg_uncovered_files "$UCB..$UCH" 2>/dev/null)"; UC_RC=$?
{ [ "$UC_RC" -eq 0 ] && [ "$(printf '%s' "$UC_OUT" | grep -c .)" -eq 2 ]; } \
  && pass "uncovered_files: proofless artifact (post-cutoff) grants NO coverage — both files listed" \
  || bad "uncovered_files: proofless artifact must not cover (rc=$UC_RC out=[$UC_OUT])"

# rc 3 — the range changed no PRODUCTION files. Distinct from "all covered": ship keeps its
# normal LOC-band review here, so collapsing 3 into 0 would silently drop review from every
# docs-only release.
( cd "$UCT" && mkdir -p docs && echo hi > docs/x.md && git add docs/x.md && git commit -qm docs ) >/dev/null 2>&1
uc "$UCH2..$(git -C "$UCT" rev-parse HEAD)"
{ [ "$UC_RC" -eq 3 ] && [ -z "$UC_OUT" ]; } \
  && pass "uncovered_files: docs-only range → rc 3 (no production files), NOT rc 0" \
  || bad "uncovered_files: docs-only should be rc 3 (rc=$UC_RC out=[$UC_OUT])"

# rc 2 — could not compute. All three shapes print nothing, exactly like "all covered", which is
# why the CODE is the signal. A caller that read emptiness alone would skip review on a git error.
uc ""
{ [ "$UC_RC" -eq 2 ] && [ -z "$UC_OUT" ]; } \
  && pass "uncovered_files: empty range → rc 2 (unknown), not rc 0" \
  || bad "uncovered_files: empty range should be rc 2 (rc=$UC_RC)"
uc "zzz..yyy"
{ [ "$UC_RC" -eq 2 ] && [ -z "$UC_OUT" ]; } \
  && pass "uncovered_files: unresolvable range → rc 2 (unknown), not rc 0" \
  || bad "uncovered_files: bad range should be rc 2 (rc=$UC_RC out=[$UC_OUT])"
# EMPTY HEAD ("<base>..") is its own short-circuit — `head` is empty before git is ever asked,
# so it is NOT the same branch as the unresolvable-range case above.
uc "$UCB.."
{ [ "$UC_RC" -eq 2 ] && [ -z "$UC_OUT" ]; } \
  && pass "uncovered_files: range with EMPTY head → rc 2 (own short-circuit, not the git path)" \
  || bad "uncovered_files: empty head should be rc 2 (rc=$UC_RC out=[$UC_OUT])"
(
  cd "$NOREPO" || exit 3
  unset PG_REPO_ROOT
  out="$(pg_uncovered_files "a..b" 2>/dev/null)"; rc=$?
  [ "$rc" -eq 2 ] && [ -z "$out" ]
) && pass "uncovered_files: no repo → rc 2 (unknown), no abort" \
  || bad "uncovered_files: no-repo should be rc 2"
rm -rf "$UCT"

# EXPLAIN past 10 files: the per-file explanation shows at most 10 files, so beyond that it must
# say how many it left out and how to list them. A list cut at 10 with no note reads as the whole
# set (2026-09-12: 63 files uncovered, 10 shown, and the next review was scoped to those 10).
EXT="$(mktemp -d)"
new_local_fixture "$EXT" || { bad "EXT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$EXT" || exit 1
  mkdir -p src
  for i in 01 02 03 04 05 06 07 08 09 10 11 12; do echo "f$i" > "src/f$i.sh"; done
  git add src; git commit -qm "twelve prod files"
) >/dev/null 2>&1
EX_BASE="$(git -C "$EXT" rev-parse HEAD~1)"
EX_OUT="$(PG_REPO_ROOT="$EXT" pg_explain_uncovered "$EX_BASE..$(git -C "$EXT" rev-parse HEAD)" 2>/dev/null)"
EX_SHOWN="$(printf '%s\n' "$EX_OUT" | grep -c '^  src/f[0-9]*\.sh: ')"
{ [ "$EX_SHOWN" -eq 10 ] \
  && printf '%s' "$EX_OUT" | grep -q '\.\.\. and 2 more uncovered file(s) not shown' \
  && printf '%s' "$EX_OUT" | grep -q "pg_uncovered_files \"$EX_BASE\.\."; } \
  && pass "explain_uncovered: 12 uncovered → 10 shown + 'and 2 more' with the full-list command" \
  || bad "explain_uncovered: expected 10 shown + 'and 2 more' (shown=$EX_SHOWN out=[$EX_OUT])"
( cd "$EXT" && git rm -q src/f0[4-9].sh src/f1[0-2].sh && git commit -qm trim ) >/dev/null 2>&1
EX_OUT="$(PG_REPO_ROOT="$EXT" pg_explain_uncovered "$EX_BASE..$(git -C "$EXT" rev-parse HEAD)" 2>/dev/null)"
{ [ "$(printf '%s\n' "$EX_OUT" | grep -c '^  src/f[0-9]*\.sh: ')" -eq 3 ] \
  && ! printf '%s' "$EX_OUT" | grep -q 'more uncovered'; } \
  && pass "explain_uncovered: 3 uncovered → all shown, no 'more' line" \
  || bad "explain_uncovered: 3 files should all show with no summary (out=[$EX_OUT])"
rm -rf "$EXT"

# ---------- Task 2: blind-audit must never grant adversarial-review proof (gate integrity) ----
# Plan B adds `adversarial-review.sh --mode blind-audit`, a coverage AUDIT (not a review) that
# can write an --artifact proof shaped exactly like a real review's: REVIEW BY: provider lines
# plus write_artifact()'s `mode=<value>` header line (scripts/adversarial-review.sh). A blind
# audit checking WHETHER something was reviewed is not itself the review, so pg_artifact_proven
# must refuse a proof whose header says mode=blind-audit, regardless of how many REVIEW BY:
# lines it carries. This lands BEFORE that mode exists so the gate is already closed on day one.
BAT="$(mktemp -d)" || { echo "FAIL: mktemp -d failed (BAT)"; exit 1; }   # ADV-C90
mkdir -p "$BAT/memory/reviews" "$BAT/zuvo/proofs"
cat > "$BAT/memory/reviews/blind.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: zuvo/proofs/blind.txt
verdict: PASS
-->
ART
# pgl_hdr <mode> — the FIXED four-line prefix write_artifact() opens every record with
# (scripts/adversarial-review.sh: artifact_kind=, created_at=<UTC ISO-8601>, status=, mode=, in that
# order — pinned against the driver's own source by the "header contract" case below). P2-4: the gate
# honours mode= only inside a record that opens with that exact sequence, so every fixture that must
# be READ as a header carries the whole prefix. Built with printf rather than written out as literal
# lines on purpose: a review of THIS file that quotes a fixture verbatim must not itself hand the gate
# a well-formed header (the self-reference the finding describes), and a printf format string is not
# a header however it is quoted.
pgl_hdr() { printf 'artifact_kind=%s\ncreated_at=%s\nstatus=%s\nmode=%s\n' adversarial-review 2026-09-27T00:00:00Z ok "$1"; }
# Shaped exactly like write_artifact()'s header: the fixed prefix (its `mode=` line anchored), plus 2
# REVIEW BY: lines (real cross-model proof strength — deliberately unrelated to what mode= decides).
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr blind-audit)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
coverage audit body
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: mode=blind-audit proof grants NO review coverage" \
                    || bad "artifact_proven: blind-audit proof must be refused, got rc=$BA_RC"

# Same proof, mode=code → must still be accepted (existing behaviour preserved).
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
real review body
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: mode=code proof still proves (existing behaviour preserved)" \
                    || bad "artifact_proven: mode=code proof should prove, got rc=$BA_RC"

# The refusal must be an ANCHORED line match, not a substring scan: a genuine review whose
# PROSE happens to mention "mode=blind-audit" (e.g. discussing the new flag) must still count.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
finding: watch for callers accidentally passing mode=blind-audit here
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: 'mode=blind-audit' in review PROSE (not the header) is not refused" \
                    || bad "artifact_proven: substring match over-refused a real review, got rc=$BA_RC"

# CROSS-MODEL REVIEW FIX (codex-5.3 + cursor-agent): the anchored check above (`grep -qx`) scans
# the WHOLE proof file, not just write_artifact()'s HEADER block (from `artifact_kind=...` to the
# next literal `---` line). A genuine CODE review whose BODY — the provider's own prose, after
# `---` — contains a STANDALONE line reading exactly "mode=blind-audit" (plausible for a review
# OF this very feature, which is what this task's own proof is) was wrongly refused. mode= is
# only authoritative inside the header it describes.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
the driver validates mode against a fixed enum, e.g. a line quoted verbatim from the diff:
mode=blind-audit
the line above is BODY prose, not a real header
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: a standalone 'mode=blind-audit' line in the BODY (not the header) is not refused" \
                    || bad "artifact_proven: header-scoped match wrongly refused a body-only mode= line, got rc=$BA_RC"

# ADV-A117 (confidence-rescored CONFIRMED): the previous fix scoped mode= to a HEADER block that
# opens on ANY line starting with `artifact_kind=`, even one appearing in the review's own BODY
# prose quoting this exact gate's header shape — self-referentially likely precisely because a
# review OF this feature tends to quote it. A body that quotes BOTH the `artifact_kind=` line
# AND a `mode=blind-audit` line (e.g. explaining the compound header format this gate scans for)
# must re-enter "header" state and wrongly refuse an otherwise-real, multi-provider proof. A real
# header only ever starts at NR==1 or right after an `=== APPENDED PASS ===` marker (the only two
# places write_artifact() ever emits one) — a bare `artifact_kind=` string match mid-body is not
# a genuine start-of-record signal.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
finding: the gate scans a header block shaped like this, quoted here for illustration:
artifact_kind=adversarial-review
mode=blind-audit
that compound quote must not re-open header parsing mid-body
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: a body quoting BOTH artifact_kind= and mode=blind-audit (not preceded by an APPENDED PASS marker) does not re-open header parsing" \
                    || bad "artifact_proven: a body-only artifact_kind=/mode=blind-audit quote wrongly re-entered header state, got rc=$BA_RC"

# P2-4: ADV-A117's fix narrowed re-entry to "an artifact_kind= line right after an APPENDED PASS
# marker" — but a body that quotes the marker TOO (an explanation of --append-artifact, or a review
# of this very gate quoting its own fixtures) still re-opened header state, and a mode=blind-audit
# line before the next `---` refused a genuine multi-provider review. A record is now recognised
# only by write_artifact()'s whole fixed prefix IN SEQUENCE (artifact_kind=, created_at=<UTC
# ISO-8601>, status=, mode=) at a record start: the marker + artifact_kind= pair alone is prose.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
finding: an appended pass starts like this, quoted from the driver for illustration:
=== APPENDED PASS 2026-09-27T00:00:00Z ===
artifact_kind=adversarial-review
mode=blind-audit
---
no created_at=/status= line follows that artifact_kind= line, so it is not a record
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: a body quoting an APPENDED PASS marker + artifact_kind= + mode=blind-audit (no created_at=/status= in sequence) is not read as a header (P2-4)" \
                    || bad "artifact_proven: a quoted marker + artifact_kind= pair re-opened header state and refused a real review, got rc=$BA_RC (P2-4)"

# …and IN ORDER, not merely present: a quote carrying created_at= but no status= between it and
# mode= (a prefix no write_artifact() of the blind-audit era ever wrote) is prose as well.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
=== APPENDED PASS 2026-09-27T00:00:00Z ===
artifact_kind=adversarial-review
created_at=2026-09-27T00:00:00Z
mode=blind-audit
---
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: an out-of-sequence prefix (status= missing before mode=) is not read as a header (P2-4)" \
                    || bad "artifact_proven: an incomplete prefix was read as a header, got rc=$BA_RC (P2-4)"

# ADV-C83: a header block with TWO mode= lines (never emitted by the real write_artifact(), but
# not something the awk's own `found=1` assignment guards against either) must still refuse —
# `found` is set on ANY `mode=blind-audit` line seen while in_header, so a duplicate is already
# handled safely by construction. This case exercises that previously-untested branch directly.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
mode=blind-audit
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
body
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: a header with a DUPLICATE mode= line (one of them blind-audit) still refuses" \
                    || bad "artifact_proven: a duplicate mode= line let a blind-audit header through, got rc=$BA_RC"

# APPENDED proof (--append-artifact): several write_artifact() sections concatenated, each with
# its OWN header/body pair. The check must scan EVERY section's header, not just the first — a
# later blind-audit pass appended onto an earlier code review must still be refused.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
first pass body

=== APPENDED PASS 2026-09-27T00:00:00Z ===
$(pgl_hdr blind-audit)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
second pass body
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: appended SECOND section's mode=blind-audit header still refuses" \
                    || bad "artifact_proven: appended blind-audit section must refuse, got rc=$BA_RC"

# A CRLF-authored proof (every line ends in CR LF) must still be recognized — cheap to tolerate,
# nothing else (no case-folding, no leading-whitespace: the driver's mode enum is fixed). Every
# line, not only mode=: the prefix match now reads created_at='s timestamp to its end, so a CR left
# on ANY prefix line would un-recognize the whole record.
{ pgl_hdr blind-audit; printf 'REVIEW BY: CODEX\nREVIEW BY: GEMINI\n---\nbody\n'; } \
  | awk '{ printf "%s\r\n", $0 }' > "$BAT/zuvo/proofs/blind.txt"
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: a CRLF-authored mode=blind-audit header still refuses" \
                    || bad "artifact_proven: CRLF-authored mode=blind-audit header must still refuse, got rc=$BA_RC"

# The truncation flag is read CR-stripped too. It was the one comparison still made on the raw line (the
# `grep -x` it came from), so a CRLF-authored proof's `input_truncated=true\r` did not refuse and a
# review that never saw part of the change granted full coverage. The CRLF control with the flag false
# proves the refusal comes from the flag, not from the line endings.
{ pgl_hdr code; printf 'REVIEW BY: CODEX\nREVIEW BY: GEMINI\ninput_truncated=false\n---\nbody\n'; } \
  | awk '{ printf "%s\r\n", $0 }' > "$BAT/zuvo/proofs/blind.txt"
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: control — a CRLF-authored 2-provider proof with input_truncated=false is PROVEN" \
                    || bad "artifact_proven: control — a CRLF-authored, untruncated 2-provider proof was refused, got rc=$BA_RC"
{ pgl_hdr code; printf 'REVIEW BY: CODEX\nREVIEW BY: GEMINI\ninput_truncated=true\n---\nbody\n'; } \
  | awk '{ printf "%s\r\n", $0 }' > "$BAT/zuvo/proofs/blind.txt"
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: a CRLF-authored TRUNCATED proof (input_truncated=true\\r) is refused" \
                    || bad "artifact_proven: a CRLF-authored truncated proof granted coverage, got rc=$BA_RC — the flag was matched on the raw line"

# P3C-16: P2-4's whole-prefix rule still refused a genuine review whose BODY quoted the marker AND the
# complete four-line prefix (a review of this gate quoting what it scans for) — five exact lines, but
# deliberate quoting reaches them. write_artifact() writes nothing but key=value / REVIEW BY: lines
# between the prefix and the `---` that closes a header, so a prose line there means the "record" was a
# quote, and its mode= never counts. (The quote is built with pgl_hdr for the reason given at pgl_hdr.)
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
finding: an appended blind-audit pass opens like this, quoted in full from the driver:
=== APPENDED PASS 2026-09-27T00:00:00Z ===
$(pgl_hdr blind-audit)
and a record shaped like that is what the gate refuses — this line is prose, so the above is a quote
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 0 ] && pass "artifact_proven: a body quoting the marker + the WHOLE prefix, then carrying on in prose, is a quote, not a record (P3C-16)" \
                    || bad "artifact_proven: a quoted marker + complete prefix followed by prose refused a genuine 2-provider review, got rc=$BA_RC (P3C-16)"

# …which must not open the door to a REAL appended blind-audit pass after such a quote: the prose line
# that ends the quoted "header" is only a reset, and the real record that follows is still read.
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
finding: quoting the driver's record opening once more:
=== APPENDED PASS 2026-09-27T00:00:00Z ===
$(pgl_hdr code)
prose that ends the quote above

=== APPENDED PASS 2026-09-27T00:00:01Z ===
$(pgl_hdr blind-audit)
REVIEW BY: CODEX
---
coverage audit body
PROOF
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: a real blind-audit pass appended after a quoted header is still refused (P3C-16)" \
                    || bad "artifact_proven: a quoted header before a real appended blind-audit pass let it through, got rc=$BA_RC (P3C-16)"

# The two edges that stay fail-CLOSED by design (pipeline-gate-lib.sh, "A RECORD COUNTS ONLY ONCE ITS
# HEADER CLOSES"): a header still open at end of file (a truncated proof), and a quote that reproduces
# the whole header down to its closing `---`, which no line-based reading can tell from a real one.
{ pgl_hdr code; printf 'REVIEW BY: CODEX\nREVIEW BY: GEMINI\n---\nbody\n\n=== APPENDED PASS 2026-09-27T00:00:00Z ===\n'
  pgl_hdr blind-audit; printf 'REVIEW BY: CODEX\n'; } > "$BAT/zuvo/proofs/blind.txt"
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: a blind-audit header left open at end of file (truncated) still refuses (P3C-16)" \
                    || bad "artifact_proven: an unclosed blind-audit header at EOF granted coverage, got rc=$BA_RC (P3C-16)"
{ pgl_hdr code; printf 'REVIEW BY: CODEX\nREVIEW BY: GEMINI\n---\nquoted in full:\n=== APPENDED PASS 2026-09-27T00:00:00Z ===\n'
  pgl_hdr blind-audit; printf 'REVIEW BY: CODEX\n---\nend of quote\n'; } > "$BAT/zuvo/proofs/blind.txt"
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
[ "$BA_RC" -eq 1 ] && pass "artifact_proven: a quote of the WHOLE blind-audit header down to its --- is still read as a record — the documented fail-closed residue (P3C-16)" \
                    || bad "artifact_proven: a complete quoted blind-audit header was ignored, got rc=$BA_RC — the scan now tells quotes from records by something the lib does not document (P3C-16)"

# P2-1: the header scan's exit status must be captured even when pg_artifact_proven is called as a
# plain statement under `set -e` — not inside an `if` (its one production caller, _pgl_proven, is),
# which is what suspends errexit. A bare `awk …` followed by `rc=$?` aborts such a caller the moment
# the scan answers "not found" for a perfectly valid proof. A fresh process, so `set -e` cannot leak
# into this suite; SOURCED/REACHED tell "the lib would not even load" from "the call aborted".
cat > "$BAT/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr code)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
real review body
PROOF
# shellcheck disable=SC2016  # expanded by the child shell
_se_out="$(env -i PATH="$PATH" PG_REVIEW_PROOF_CUTOFF=0 "$BASH" -c 'set -e
  . "$1"; echo SOURCED
  pg_artifact_proven "$2" "$3"
  echo REACHED' _ "$LIB" "$BAT" "$BAT/memory/reviews/blind.md" 2>/dev/null)"
[ "$_se_out" = "SOURCED
REACHED" ] && pass "artifact_proven: a valid proof under a caller's plain \`set -e\` (no if) returns 0 without aborting the caller (P2-1)" \
           || bad "artifact_proven: under \`set -e\` outside an if, the call aborted the caller — got [$(printf '%s' "$_se_out" | tr '\n' ' ')] (P2-1)"

# P2-4 contract: the prefix the gate requires is only safe while it IS the prefix the driver writes.
# If write_artifact() ever reordered, renamed or dropped one of these lines, every real blind-audit
# proof would stop being recognised and silently grant review coverage — the fail-OPEN direction.
# So pin the gate's assumptions against the driver's own source: the first four `printf '<key>=`
# lines of write_artifact(), created_at= written from `date -u +%Y-%m-%dT%H:%M:%SZ`, the APPENDED
# PASS separator's exact format, and the `---` line that closes a header.
_AR_DRV="$ROOT/scripts/adversarial-review.sh"
# Both functions live in the driver's modules (scripts/lib/adversarial-*.sh): read the program as one text.
. "$ROOT/tests/lib/adversarial-driver.sh"
_AR_SRC="$_PGL_RUN_TMP/driver-source.sh"
adv_driver_source "$_AR_DRV" > "$_AR_SRC" \
  || { bad "the program text could not be assembled (reason above) — the write_artifact pins below cannot hold"; : > "$_AR_SRC"; }
_wa_body="$(awk '/^write_artifact\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$_AR_SRC" 2>/dev/null)"
# In files mode write_artifact records COLLECTED_BLOBS — what collect_files_input put into the review input —
# not FILE_LIST, so the run below drives the driver's own collector too rather than a hand-made blob list.
_cfi_body="$(awk '/^collect_files_input\(\) \{/ { on = 1 } on { print } on && /^}/ { exit }' "$_AR_SRC" 2>/dev/null)"
[ -n "$_cfi_body" ] || bad "write_artifact run: collect_files_input() not found in the program text ($_AR_SRC: the driver and scripts/lib/adversarial-*.sh) — the files-mode cases below cannot run"
# What write_artifact() itself calls: an --append-artifact pass goes in under a lock (_ar_lock, which reads
# _ar_lock_stale; _ar_unlock), a pass that cannot go in is kept beside the artifact (_ar_keep_pass), and the
# lock wait is a knob (ar_env_int → ar_decimal, capped at AR_NUM_CAP). Taken from the same program text: with
# one of them missing every append fails as "being appended to by another run", and the appended-pass cases
# below would judge that, not what the driver writes.
_wa_deps="$(grep '^AR_NUM_CAP=' "$_AR_SRC")"
[ -n "$_wa_deps" ] || bad "write_artifact run: AR_NUM_CAP= not found in the program text ($_AR_SRC) — the appended-pass cases below cannot run"
for _wa_f in _ar_lock _ar_lock_stale _ar_unlock _ar_keep_pass ar_env_int ar_decimal; do
  _wa_b="$(awk -v f="$_wa_f" '$0 ~ "^" f "\\(\\) \\{" { on = 1 } on { print } on && /^}/ { exit }' "$_AR_SRC" 2>/dev/null)"
  [ -n "$_wa_b" ] || bad "write_artifact run: $_wa_f() not found in the program text ($_AR_SRC) — the appended-pass cases below cannot run"
  _wa_deps="$_wa_deps
$_wa_b"
done
_wa_keys="$(printf '%s\n' "$_wa_body" | awk -v q="'" '
  n < 4 && (p = index($0, "printf " q)) {
    rest = substr($0, p + 8); e = index(rest, "=")
    if (e > 1 && substr(rest, 1, e - 1) ~ /^[a-z_]+$/) { keys = keys (n ? " " : "") substr(rest, 1, e - 1); n++ }
  }
  END { print keys }')"
# expect_line_in_wa <line> — write_artifact() holds <line> as one command: leading indentation, a leading
# `&&`/`||` and a trailing line continuation ignored (the APPENDED PASS printf sits in a `&&` chain since the
# locked append). Through ENVIRON, not `awk -v`: -v expands the backslash escapes these driver lines carry
# (`\n`), so the comparison would be against a different string than the one written here.
expect_line_in_wa() { printf '%s\n' "$_wa_body" | WANT="$1" awk '{ sub(/^[ \t]+/, ""); sub(/^(&&|\|\|)[ \t]+/, ""); sub(/[ \t]+\\$/, "") } $0 == ENVIRON["WANT"] { f = 1 } END { exit !f }'; }
# shellcheck disable=SC2016  # literal driver source lines, not expansions
if [ "$_wa_keys" = "artifact_kind created_at status mode" ] \
   && expect_line_in_wa 'printf '"'"'created_at=%s\n'"'"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"' \
   && expect_line_in_wa 'printf '"'"'\n=== APPENDED PASS %s ===\n'"'"' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"' \
   && expect_line_in_wa 'printf -- '"'"'---\n'"'"''; then
  pass "header contract: write_artifact() still opens every record with artifact_kind=/created_at=<UTC>/status=/mode=, separates appended passes with the pinned marker and closes the header with --- (P2-4)"
else
  bad "header contract: write_artifact() in the program text ($_AR_SRC: the driver and scripts/lib/adversarial-*.sh) no longer matches what pg_artifact_proven's header scan requires — first printf keys [$_wa_keys], want [artifact_kind created_at status mode] (or the created_at=/APPENDED PASS/--- lines changed); update the scan WITH the driver, or blind-audit proofs grant coverage (P2-4)"
fi

# P3C-10/P3C-16: the same contract RUN rather than read. write_artifact() itself — extracted from the
# driver, nothing else of it, no provider involved — writes the proofs below, so the scan is judged on
# the driver's REAL output: every header line it writes, reviewed_blob= and a tamper note included, a
# single pass and a --rotate --append-artifact pair (the shape skills/review appends). A header line of
# a shape the scan does not treat as header (P3C-16's rule) would stop real blind-audit headers from
# closing — fail-OPEN — so the grammar is asserted on that real output too.
# wa_write <proof> <mode> <provider> <append:true|false> <body> [tamper-note] [file-list] — ONE write_artifact() call
# in a subshell, from a throwaway git repo holding one dirty file (so reviewed_blob= is really written).
# FILE_LIST is what the driver hands write_artifact in files mode (build_file_list: one resolved path per
# line); FILES alone no longer reaches reviewed_blob=, so a harness setting only FILES writes no blob.
_WA_REPO="$(mktemp -d)" && [ -d "$_WA_REPO" ] || { bad "write_artifact run: mktemp -d failed"; exit 1; }
( cd "$_WA_REPO" && git init -q && printf 'x\n' > a.txt ) >/dev/null 2>&1
wa_write() {
  # shellcheck disable=SC2034,SC2329  # every global below, and _tamper_verify, is read by the eval'd write_artifact()
  ( set +u
    eval "$_wa_deps" || exit 98
    eval "$_wa_body" || exit 97
    _tamper_verify() { :; }
    REVIEW_MODE="$2"; OUTPUT_FORMAT=markdown; PROVIDERS_USED="$3"; PROVIDER_COUNT=1; ATTEMPTED_COUNT=1
    MULTI_MODE=rotate; FINAL_STATUS=ok; PROVIDER_OUTCOMES="$3:ok"; TAMPER_NOTE="${6:-}"
    INPUT_MODE=files; FILES=a.txt; FILE_LIST="${7:-a.txt}"; INPUT="a diff"; ORIG_CHARS=6; INPUT_TRUNCATED=false
    TOTAL_FINDINGS=1; CRITICAL_COUNT=0; WARNING_COUNT=1; INFO_COUNT=0; COUNT_STATUS=complete
    KNOWN_FINDINGS=""; EXCLUDE_PROVIDER=""; CACHED_FAILED=""; APPEND_ARTIFACT="$4"
    cd "$_WA_REPO" || exit 96
    eval "$_cfi_body" || exit 95
    ARTIFACT_PATH="$1"; collect_files_input 2>/dev/null
    INPUT="a diff"
    write_artifact "$1" "$5" )
}
# wa_bad_header_lines <proof> — every line inside a record's header (NR==1 or right after a marker, to
# its `---`) that is neither key=value nor `REVIEW BY: X`; empty = the grammar holds.
wa_bad_header_lines() {
  awk '{ sub(/\r$/, "") }
    NR == 1 || prev ~ /^=== APPENDED PASS / { h = 1 }
    h && $0 == "---" { h = 0; prev = $0; next }
    h && $0 !~ /^[a-z_][a-z0-9_]*=/ && $0 !~ /^REVIEW BY: / { print NR ": " $0 }
    { prev = $0 }' "$1"
}
# An UNREADABLE file on the list gets no reviewed_blob: collect_input skips it, so no provider saw it,
# and a blob for it would claim review coverage for content nobody reviewed.
_WA_U="$BAT/zuvo/proofs/unreadable.txt"; rm -f "$_WA_U"
printf 'secret\n' > "$_WA_REPO/b.txt"; chmod 000 "$_WA_REPO/b.txt"
if [ -r "$_WA_REPO/b.txt" ]; then
  echo "  SKIP write_artifact unreadable-file case: chmod 000 does not lock this user out (root?)"
else
  # b.txt FIRST: `git hash-object` stops at the first unreadable path, so recording it would also lose
  # the blob of every readable file after it — not only claim b.txt, but drop a.txt's real coverage.
  wa_write "$_WA_U" code CODEX-5.3 false "body" "" "$(printf 'b.txt\na.txt')"; _wa_urc=$?
  _wa_ub="$(grep -c '^reviewed_blob=' "$_WA_U" 2>/dev/null)"
  [ "$_wa_urc" -eq 0 ] && [ "$_wa_ub" = "1" ] \
    && pass "write_artifact run: an unreadable file on FILE_LIST gets no reviewed_blob (only a.txt's)" \
    || bad "write_artifact run: unreadable file recorded as reviewed — rc=$_wa_urc, reviewed_blob lines=$_wa_ub (want 1)"
fi
chmod 644 "$_WA_REPO/b.txt" 2>/dev/null; rm -f "$_WA_REPO/b.txt" "$_WA_U"
_WA_P="$BAT/zuvo/proofs/blind.txt"
_wa_tamper="working tree changed during the review (1 path(s) differ from the pre-review snapshot)"
rm -f "$_WA_P"
wa_write "$_WA_P" code CODEX-5.3 false "first pass body"; _wa_rc1=$?
wa_write "$_WA_P" code GEMINI true "second pass body" "$_wa_tamper"; _wa_rc2=$?
if [ "$_wa_rc1" -ne 0 ] || [ "$_wa_rc2" -ne 0 ] || [ ! -s "$_WA_P" ]; then
  bad "write_artifact run: the extracted write_artifact() did not write a proof (rc=$_wa_rc1/$_wa_rc2) — the cases below would test nothing"
else
  _wa_n="$(awk '/^=== APPENDED PASS /{a++} /^reviewed_blob=/{b++} /^tree_modified_during_review=/{t++} /^single_provider_note=/{s++} END{print a+0, b+0, t+0, s+0}' "$_WA_P")"
  [ "$_wa_n" = "1 2 1 2" ] && pass "write_artifact run: premise — the real writer produced 2 records (1 marker), each with reviewed_blob= and single_provider_note=, one with a tamper note" \
    || bad "write_artifact run: premise — want [1 2 1 2] (markers, blobs, tamper notes, single notes), got [$_wa_n]"
  _wa_bad="$(wa_bad_header_lines "$_WA_P")"
  [ -z "$_wa_bad" ] && pass "write_artifact run: every header line the driver writes is key=value or REVIEW BY: — the grammar the scan uses to tell a record from a quote (P3C-16)" \
    || bad "write_artifact run: the driver writes header lines the scan would read as prose [$(printf '%s' "$_wa_bad" | tr '\n' '|')] — a real blind-audit header would never close, and would grant coverage (P3C-16)"
  PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
  [ "$BA_RC" -eq 0 ] && pass "write_artifact run: a real --rotate --append-artifact proof (2 passes x 1 provider) is PROVEN (P3C-10/P3C-16)" \
    || bad "write_artifact run: a real two-pass rotate proof was refused, got rc=$BA_RC (P3C-10/P3C-16)"
  # The same pair, the first pass's BODY quoting a blind-audit record's marker and whole prefix: a real
  # writer, a real append, and a quote — still one genuine review.
  _wa_quote="$(printf 'finding: an appended blind-audit pass opens like this:\n=== APPENDED PASS 2026-09-27T00:00:00Z ===\n'; pgl_hdr blind-audit; printf 'and that record is what the gate refuses.')"
  rm -f "$_WA_P"
  wa_write "$_WA_P" code CODEX-5.3 false "first pass body — $_wa_quote"
  wa_write "$_WA_P" code GEMINI true "second pass body" "$_wa_tamper"
  PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
  [ "$BA_RC" -eq 0 ] && pass "write_artifact run: …and PROVEN when the first pass's body quotes a blind-audit record's marker and whole prefix (P3C-16)" \
    || bad "write_artifact run: a real two-pass proof quoting a blind-audit record in its body was refused, got rc=$BA_RC (P3C-16)"
  wa_write "$_WA_P" blind-audit KIMI true "coverage audit body"
  PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$BAT" "$BAT/memory/reviews/blind.md"; BA_RC=$?
  [ "$BA_RC" -eq 1 ] && pass "write_artifact run: …and a real mode=blind-audit pass appended to it is REFUSED (P3C-16)" \
    || bad "write_artifact run: a real appended mode=blind-audit pass granted coverage, got rc=$BA_RC (P3C-16)"
fi
rm -rf "$_WA_REPO"
rm -rf "$BAT"

# ---------- PG_PROOF_OPTIONAL (CI-degrade) + proof-path traversal rejection ----------
# hooks/lib/pipeline-gate-lib.sh:364-367 (path_contained / its "helper missing -> reject"
# fallback) and :378-379 (PG_PROOF_OPTIONAL) had ZERO coverage in this file (test-quality-audit
# 2026-09-28-plan-b, Q7/Q11). pg_artifact_proven needs no git at all — a root dir and an
# artifact path are its only inputs — so this fixture is a plain directory, not a repo.
# PPARENT holds PPT (the "repo root" pg_artifact_proven is given) AND a SIBLING "outside" dir —
# a real, existing target genuinely reachable by naive `"$root/$ref"` string concatenation once
# the leading `..` is walked up past PPT, so the traversal cases below prove path_contained
# itself rejects them rather than coincidentally failing on "file not found" (a `..`/absolute ref
# that resolves to nothing would return the right verdict for the wrong reason and never catch a
# disabled containment check).
PPARENT="$(mktemp -d)"
PPT="$PPARENT/root"
mkdir -p "$PPT/memory/reviews" "$PPT/zuvo/proofs" "$PPARENT/outside" "$PPT/abs/path"
cat > "$PPT/zuvo/proofs/real.txt" <<PROOF
artifact_kind=adversarial-review
mode=code
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
real review body
PROOF

# Symmetric positive every case below is contrasted against: a normal, EXISTING, in-repo proof
# path is accepted.
cat > "$PPT/memory/reviews/normal.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: zuvo/proofs/real.txt
verdict: PASS
-->
ART
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/normal.md"; PP_RC=$?
[ "$PP_RC" -eq 0 ] && pass "artifact_proven: a normal, existing, in-repo proof path is accepted" \
  || bad "artifact_proven: normal proof path should be accepted, got rc=$PP_RC"

# PG_PROOF_OPTIONAL: the proof referenced does NOT exist in this checkout (the CI shape — proof
# files are commonly gitignored). Unset (the LOCAL default) must stay strict.
cat > "$PPT/memory/reviews/missing-proof.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: zuvo/proofs/does-not-exist.txt
verdict: PASS
-->
ART
( unset PG_PROOF_OPTIONAL; PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/missing-proof.md" ); PP_RC=$?
[ "$PP_RC" -eq 1 ] && pass "artifact_proven: PG_PROOF_OPTIONAL unset + missing proof → strict refusal (rc=1)" \
  || bad "artifact_proven: missing proof with PG_PROOF_OPTIONAL unset should refuse, got rc=$PP_RC"

# PG_PROOF_OPTIONAL=1 degrades the SAME missing-proof artifact to content-key acceptance — the
# documented CI-vs-local split.
( PG_PROOF_OPTIONAL=1 PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/missing-proof.md" ); PP_RC=$?
[ "$PP_RC" -eq 0 ] && pass "artifact_proven: PG_PROOF_OPTIONAL=1 + missing proof → degraded acceptance (rc=0, CI shape)" \
  || bad "artifact_proven: PG_PROOF_OPTIONAL=1 should degrade a missing proof to accepted, got rc=$PP_RC"

# Symmetric negative: PG_PROOF_OPTIONAL=1 must not paper over an EXISTING but genuinely-bad
# proof (e.g. truncated review) — the degrade is only for "proof absent from this checkout",
# never a blanket bypass once the file IS there.
cat > "$PPT/zuvo/proofs/truncated.txt" <<PROOF
artifact_kind=adversarial-review
mode=code
input_truncated=true
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
truncated review body
PROOF
cat > "$PPT/memory/reviews/truncated.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: zuvo/proofs/truncated.txt
verdict: PASS
-->
ART
( PG_PROOF_OPTIONAL=1 PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/truncated.md" ); PP_RC=$?
[ "$PP_RC" -eq 1 ] && pass "artifact_proven: PG_PROOF_OPTIONAL=1 does not excuse an EXISTING but truncated proof" \
  || bad "artifact_proven: PG_PROOF_OPTIONAL=1 must not accept a present-but-truncated proof, got rc=$PP_RC"

# ---- proof-path traversal rejection (path_contained) ----
# A `..`-segment reference must be rejected, never read. The target is a REAL file one level
# above PPT (PPARENT/outside/secret.txt) with a genuine valid-proof shape, so a bypassed
# containment check would actually ACCEPT it (rc 0) — the assertion below only passes for the
# right reason, not because the traversal path happens to resolve to nothing.
cat > "$PPARENT/outside/secret.txt" <<PROOF
artifact_kind=adversarial-review
mode=code
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
this must never be reachable via traversal
PROOF
cat > "$PPT/memory/reviews/traversal-dotdot.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: ../outside/secret.txt
verdict: PASS
-->
ART
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/traversal-dotdot.md"; PP_RC=$?
[ "$PP_RC" -eq 1 ] && pass "artifact_proven: a '..'-segment adversarial: path is rejected" \
  || bad "artifact_proven: traversal path should be rejected, got rc=$PP_RC"

# An ABSOLUTE path reference must also be rejected — check #1 in path_contained, BEFORE any
# concatenation with root. The ref is a plain absolute-looking string ("/abs/path/secret.txt")
# that, if containment were skipped, would resolve via "$root/$ref" to a REAL file this suite
# planted at exactly that nested path ($PPT/abs/path/secret.txt) — again so a bypass would
# genuinely ACCEPT, not coincidentally miss.
cp "$PPARENT/outside/secret.txt" "$PPT/abs/path/secret.txt"
cat > "$PPT/memory/reviews/traversal-abs.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: /abs/path/secret.txt
verdict: PASS
-->
ART
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/traversal-abs.md"; PP_RC=$?
[ "$PP_RC" -eq 1 ] && pass "artifact_proven: an ABSOLUTE adversarial: path is rejected" \
  || bad "artifact_proven: absolute proof path should be rejected, got rc=$PP_RC"

# The base7..head7 filename convention (a filename SEGMENT containing '..', not a traversal)
# must still be accepted — the regression path-contain.sh's own header warns against.
cp "$PPT/zuvo/proofs/real.txt" "$PPT/zuvo/proofs/fd57e11..fc0c83e-adversarial.txt"
cat > "$PPT/memory/reviews/dotdot-filename.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: zuvo/proofs/fd57e11..fc0c83e-adversarial.txt
verdict: PASS
-->
ART
PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPT" "$PPT/memory/reviews/dotdot-filename.md"; PP_RC=$?
[ "$PP_RC" -eq 0 ] && pass "artifact_proven: a base7..head7 FILENAME (dots in a segment, not traversal) is accepted" \
  || bad "artifact_proven: the base7..head7 filename convention must not be rejected, got rc=$PP_RC"

# ---- ADV-A116: an awk I/O-class failure on the header scan must fail closed, never silently
# fall through to the whole-file REVIEW BY: count ----
# A genuinely-unreadable file (chmod 000) is NOT a usable reproduction on this host: the
# subsequent `grep -c 'REVIEW BY:'` fallback fails to read it too (verified — both awk and grep
# return exit 2 on the same permission-denied file), so the function already fails closed for
# the coincidental reason that BOTH reads break together. The finding's actual concern is an awk
# failure that does NOT also break grep (a transient/awk-internal fault) — that combination lets a
# real mode=blind-audit artifact's REVIEW BY: markers be counted and wrongly grant coverage. A
# stubbed `awk` that always exits 2 (the real one-true-awk "can't open file" status) isolates
# exactly that combination without needing an actually-broken filesystem.
# P2-115: an unchecked `mktemp -d` would leave _A116_BIN empty and put a leading EMPTY component
# (= the current directory) on the PATH below, instead of failing loudly.
_A116_BIN="$(mktemp -d)" && [ -n "$_A116_BIN" ] && [ -d "$_A116_BIN" ] \
  || { bad "ADV-A116 setup: mktemp -d failed — the awk stand-in cannot be placed"; exit 1; }
cat > "$_A116_BIN/awk" <<'AWKSTUB'
#!/bin/sh
exit 2
AWKSTUB
chmod +x "$_A116_BIN/awk"
mkdir -p "$PPARENT/a116/memory/reviews" "$PPARENT/a116/zuvo/proofs"
cat > "$PPARENT/a116/zuvo/proofs/blind.txt" <<PROOF
$(pgl_hdr blind-audit)
REVIEW BY: CODEX
REVIEW BY: GEMINI
---
coverage audit body
PROOF
cat > "$PPARENT/a116/memory/reviews/blind.md" <<ART
<!-- zuvo-review -->
range: HEAD~1..HEAD
files: *
adversarial: zuvo/proofs/blind.txt
verdict: PASS
-->
ART
( PATH="$_A116_BIN:$PATH" PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPARENT/a116" "$PPARENT/a116/memory/reviews/blind.md" ); A116_RC=$?
[ "$A116_RC" -eq 1 ] && pass "artifact_proven: an awk I/O failure on the header scan fails closed, not a fall-through to the REVIEW BY: count" \
  || bad "artifact_proven: awk I/O failure should fail closed (rc=1), got rc=$A116_RC — a blind-audit proof's REVIEW BY: markers wrongly granted coverage via the fallback count"

# P2-5: exit 1 is NOT a safe "not found". one-true-awk, gawk and mawk exit 2 on an I/O fault, but a
# busybox-class awk dies with EXIT_FAILURE (1) when it cannot open its input — so an `exit !found`
# scan, whose own "not found" is ALSO 1, read that fault as "no blind-audit header" and handed the
# same file's REVIEW BY: markers to the count below. The scan's "not found" is now a status no awk
# uses for a fault; 1, like 2+, fails closed.
cat > "$_A116_BIN/awk" <<'AWKSTUB'
#!/bin/sh
exit 1
AWKSTUB
( PATH="$_A116_BIN:$PATH" PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPARENT/a116" "$PPARENT/a116/memory/reviews/blind.md" ); A116_RC=$?
[ "$A116_RC" -eq 1 ] && pass "artifact_proven: an awk that exits 1 on an I/O fault (busybox-class) still fails closed, not read as 'no blind-audit header' (P2-5)" \
  || bad "artifact_proven: an awk exiting 1 on a fault was read as 'not found', got rc=$A116_RC — a blind-audit proof's REVIEW BY: markers granted coverage (P2-5)"

# P2-5, the other half — now on a READABLE proof, where these stand-ins are actually reached (P3C-17:
# they used to sit in front of a chmod-000 file, where the -r guard refused before either ran, so the
# setup read as exercised and was not). An awk that SKIPS its input and still runs END (the
# warn-and-continue behaviour some awks have) is modelled by a stand-in running the REAL awk program
# over /dev/null; a grep stand-in "reads" the file anyway (-c answers 2, every other query no-match).
# P3C-13: the verdict must come from ONE read of the proof, so a scan that saw nothing counts zero
# REVIEW BY: lines and refuses — when the count was a second, separate read (the grep stand-in here),
# that read answered 2 and granted coverage to a blind-audit proof the scan had never looked at.
_A116_REAL_AWK="$(command -v awk)"
printf '#!/bin/sh\nexec "%s" "$1" /dev/null\n' "$_A116_REAL_AWK" > "$_A116_BIN/awk"
printf '#!/bin/sh\ncase "$1" in -c) echo 2; exit 0 ;; esac\nexit 1\n' > "$_A116_BIN/grep"
chmod +x "$_A116_BIN/awk" "$_A116_BIN/grep"
( PATH="$_A116_BIN:$PATH" PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPARENT/a116" "$PPARENT/a116/memory/reviews/blind.md" ); A116_RC=$?
[ "$A116_RC" -eq 1 ] && pass "artifact_proven: a scan that read nothing counts no REVIEW BY: lines — one read decides, no second read can grant coverage (P3C-13)" \
  || bad "artifact_proven: a scan that skipped its input got rc=$A116_RC — a separate read counted the blind-audit proof's REVIEW BY: markers and granted coverage (P3C-13)"
rm -f "$_A116_BIN/grep"
# …and an UNREADABLE proof is refused outright, by the -r guard, with no stand-in in the way: the real
# awk on the real (unreadable) file.
chmod 000 "$PPARENT/a116/zuvo/proofs/blind.txt"
if [ -r "$PPARENT/a116/zuvo/proofs/blind.txt" ]; then
  echo "SKIP: artifact_proven unreadable-proof case (P2-5) — chmod 000 leaves the file readable here (running as root?)"
else
  PG_REVIEW_PROOF_CUTOFF=0 pg_artifact_proven "$PPARENT/a116" "$PPARENT/a116/memory/reviews/blind.md"; A116_RC=$?
  [ "$A116_RC" -eq 1 ] && pass "artifact_proven: an UNREADABLE proof is refused (P2-5)" \
    || bad "artifact_proven: an unreadable proof got rc=$A116_RC — coverage granted on a file nothing could read (P2-5)"
fi
chmod 600 "$PPARENT/a116/zuvo/proofs/blind.txt"
# P2-124: the a116 fixture tree goes too, not only the stand-in dir.
rm -rf "$_A116_BIN" "$PPARENT/a116"

# ---- path_contained missing entirely → fail-closed (never fall through to accept) ----
# A fresh PROCESS (env -i bash -c), not a subshell: a subshell inherits this script's own already-
# sourced path_contained, which would make the premise below false no matter what we source next.
_ppt_missing_dir="$(mktemp -d)"
_ppt_missing_lib="$_ppt_missing_dir/pipeline-gate-lib.sh"
cp "$LIB" "$_ppt_missing_lib"      # copied ALONE — no path-contain.sh sibling to auto-source
ppt_missing_out="$(env -i PATH="$PATH" PG_REVIEW_PROOF_CUTOFF=0 bash -c '
  . "$1"
  command -v path_contained >/dev/null 2>&1 && exit 97
  pg_artifact_proven "$2" "$3"
' _ "$_ppt_missing_lib" "$PPT" "$PPT/memory/reviews/normal.md" 2>&1)"
PP_RC=$?
case "$PP_RC" in
  97) bad "artifact_proven: premise failed — path_contained is still defined without its sibling file" ;;
  1)  pass "artifact_proven: path_contained missing entirely → fail-closed (rc=1), even for an otherwise-valid proof" ;;
  *)  bad "artifact_proven: missing path_contained should fail-closed as rc=1, got rc=$PP_RC (out=[$ppt_missing_out])" ;;
esac
rm -rf "$_ppt_missing_dir" "$PPARENT"

# ---------- pg_default_branch / pg_mergebase_range ----------
# These two were the suite's only untested functions (test-audit 2026-08-16, Q11=0 across all
# three files covering this lib). They are not decoration: pg_mergebase_range supplies the range
# the commit- and Stop-nudges gate on, and it asks pg_default_branch which branch to measure
# against — so a wrong answer here mis-scopes every best-effort nudge in the repo.
DBT="$(mktemp -d)"; DBR="$(mktemp -d)"
new_remote_fixture "$DBT" "$DBR" trunk || { bad "DBT fixture init failed"; echo "SOME FAILED"; exit 1; }
(
  cd "$DBT" || exit 1
  echo base > b.txt; git add -A; git commit -qm base; git push -q -u origin trunk
  git remote set-head origin trunk           # creates refs/remotes/origin/HEAD -> origin/trunk
  git checkout -q -b feature
  # THREE commits, and trunk advances too. Both details are load-bearing: with a single feature
  # commit the fork point IS HEAD~1, so an implementation that returned `HEAD~1..HEAD` would pass
  # a merge-base assertion by coincidence (verified — that mutant survived until this fixture grew).
  echo f1 > f1.sh; git add -A; git commit -qm f1
  echo f2 > f2.sh; git add -A; git commit -qm f2
  echo f3 > f3.sh; git add -A; git commit -qm f3
  git checkout -q trunk; echo t2 > t2.sh; git add -A; git commit -qm t2; git push -q origin trunk
  git checkout -q feature
) >/dev/null 2>&1

# Reads the REAL origin/HEAD, not the hardcoded "main". A repo whose trunk is not called main is
# the whole reason this function exists rather than a literal.
db="$(cd "$DBT" && PG_REPO_ROOT="$DBT" bash -c '. "'"$LIB"'"; pg_default_branch')"
[ "$db" = "trunk" ] && pass "default_branch: reads origin/HEAD (trunk), not a hardcoded 'main'" \
  || bad "default_branch should be trunk, got [$db]"

# No origin/HEAD → documented fallback chain: $ZUVO_DEFAULT_BRANCH, else literal main.
( cd "$DBT" && git remote set-head origin -d ) >/dev/null 2>&1
db="$(cd "$DBT" && PG_REPO_ROOT="$DBT" bash -c '. "'"$LIB"'"; pg_default_branch')"
[ "$db" = "main" ] && pass "default_branch: no origin/HEAD → falls back to 'main'" \
  || bad "default_branch fallback should be main, got [$db]"
db="$(cd "$DBT" && PG_REPO_ROOT="$DBT" ZUVO_DEFAULT_BRANCH=develop bash -c '. "'"$LIB"'"; pg_default_branch')"
[ "$db" = "develop" ] && pass "default_branch: ZUVO_DEFAULT_BRANCH overrides the fallback" \
  || bad "default_branch should honor ZUVO_DEFAULT_BRANCH, got [$db]"

# No repo at all: must still ANSWER (rc 0 + a branch name), never abort — this runs inside a
# sourced hook, where a non-zero exit would take the host process with it.
db="$(cd "$NOREPO" && unset PG_REPO_ROOT; bash -c '. "'"$LIB"'"; pg_default_branch')"; rc=$?
{ [ "$rc" -eq 0 ] && [ "$db" = "main" ]; } \
  && pass "default_branch: no repo → still answers 'main' rc 0 (fail-open, no abort)" \
  || bad "default_branch no-repo should be main/rc0 (rc=$rc out=[$db])"

# pg_mergebase_range emits <merge-base>..HEAD, and the base must be the fork point with the
# default branch — NOT HEAD~1 and NOT the branch tip.
( cd "$DBT" && git remote set-head origin trunk ) >/dev/null 2>&1
mb="$(cd "$DBT" && PG_REPO_ROOT="$DBT" bash -c '. "'"$LIB"'"; pg_mergebase_range')"; rc=$?
expect_base=$(git -C "$DBT" merge-base feature trunk)
{ [ "$rc" -eq 0 ] && [ "$mb" = "${expect_base}..HEAD" ]; } \
  && pass "mergebase_range: emits <fork-point-with-default-branch>..HEAD" \
  || bad "mergebase_range wrong (rc=$rc got=[$mb] want=[${expect_base}..HEAD])"

# Unrelated histories → no merge-base exists → rc 1, and NO half-formed range on stdout. A
# caller that read "..HEAD" as a range would gate on the entire repo.
( cd "$DBT" && git checkout -q --orphan orphanb && git rm -rqf . 2>/dev/null; echo o > o.txt
  git add -A; git commit -qm orphan ) >/dev/null 2>&1
mb="$(cd "$DBT" && PG_REPO_ROOT="$DBT" bash -c '. "'"$LIB"'"; pg_mergebase_range' 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$mb" ]; } \
  && pass "mergebase_range: unrelated histories → rc 1, empty stdout (no partial range)" \
  || bad "mergebase_range orphan should be rc1/empty (rc=$rc got=[$mb])"

mb="$(cd "$NOREPO" && unset PG_REPO_ROOT; bash -c '. "'"$LIB"'"; pg_mergebase_range' 2>/dev/null)"; rc=$?
{ [ "$rc" -eq 1 ] && [ -z "$mb" ]; } \
  && pass "mergebase_range: no repo → rc 1, empty stdout (fail-open, no abort)" \
  || bad "mergebase_range no-repo should be rc1/empty (rc=$rc got=[$mb])"
rm -rf "$DBT" "$DBR"

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

# ---------- batched engine + header cache (2026-09-27) ----------
# The coverage rule now runs as one awk pass + one cat-file, and each artifact's parsed headers
# are cached in the git dir keyed on (mtime ns, size, inode). The cache must never change a
# verdict: a rewritten artifact is re-read, a fresh one (< 2 s, racy) is never cached, and
# ZUVO_PG_INDEX_CACHE=0 gives the same answer.
CR="$(mktemp -d)"
new_local_fixture "$CR" || bad "cache fixture init failed"
(
  cd "$CR" || exit 1
  mkdir -p src memory/reviews
  for f in a b c; do echo "$f" > "src/$f.sh"; done
  git add src; git commit -qm three
) >/dev/null 2>&1
CB="$(git -C "$CR" rev-parse HEAD~1)"; CH="$(git -C "$CR" rev-parse HEAD)"
CACHE="$(git -C "$CR" rev-parse --absolute-git-dir)/zuvo-review-index.v1"
cat > "$CR/memory/reviews/cov.md" <<ART
<!-- zuvo-review -->
range: $CB..$CH
files: src/a.sh, src/b.sh, src/c.sh
ART
# 30 unrelated artifacts, so the engine has something to skip past
for i in $(seq 1 30); do
  printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: other/%s.sh\n' "$CB" "$CH" "$i" > "$CR/memory/reviews/other-$i.md"
done
# ADV-C91: aligned to the P1-below `exit 99` convention (out of the functions' own 0/1 result
# range) — these six sites previously used `|| exit 1`, which happened to never coincide with a
# genuine failure verdict only because every one of them asserts `rc -eq 0` as its pass condition,
# never `rc -eq 1`; still the same class of bug P1 closed, so aligned for future-proofing.
touch -t 202601010000 "$CR"/memory/reviews/*.md       # old enough to be cacheable
( cd "$CR" || exit 99; PG_REPO_ROOT="$CR" pg_range_reviewed "$CB..$CH" ); rc=$?
[ "$rc" -eq 0 ] && pass "engine: covered through the batched join (31 artifacts)" || bad "engine: expected covered, got $rc"
if [ -f "$CACHE" ] && [ "$(wc -l < "$CACHE" | tr -d ' ')" -eq 31 ]; then
  pass "cache: header index written to the git dir (31 entries)"
else
  bad "cache: expected 31 entries in $CACHE"
fi
# Rewrite the covering artifact so it no longer lists src/c.sh — still backdated, different size.
cat > "$CR/memory/reviews/cov.md" <<ART
<!-- zuvo-review -->
range: $CB..$CH
files: src/a.sh, src/b.sh
ART
touch -t 202601010000 "$CR/memory/reviews/cov.md"
out="$( cd "$CR" || exit 99; PG_REPO_ROOT="$CR" pg_uncovered_files "$CB..$CH" )"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "src/c.sh" ] \
  && pass "cache: a rewritten artifact is re-read (src/c.sh now uncovered)" \
  || bad "cache: stale header served after rewrite (rc=$rc out=[$out])"
out0="$( cd "$CR" || exit 99; PG_REPO_ROOT="$CR" ZUVO_PG_INDEX_CACHE=0 pg_uncovered_files "$CB..$CH" )"
[ "$out0" = "$out" ] && pass "cache: ZUVO_PG_INDEX_CACHE=0 gives the same answer" || bad "cache on/off disagree: [$out] vs [$out0]"
# A FRESH artifact (mtime now) is parsed but never cached — the racy-clean guard.
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/c.sh\n' "$CB" "$CH" > "$CR/memory/reviews/fresh.md"
( cd "$CR" || exit 99; PG_REPO_ROOT="$CR" pg_range_reviewed "$CB..$CH" ); rc=$?
[ "$rc" -eq 0 ] && pass "engine: fresh artifact covers src/c.sh" || bad "fresh artifact should cover, got $rc"
awk -F"$(printf '\037')" '$2 ~ /fresh\.md$/ {found=1} END {exit found}' "$CACHE" \
  && pass "cache: fresh (<2s) artifact is not cached" || bad "cache: a racy fresh artifact was cached"
# A corrupt cache must not change anything either.
printf 'garbage\n%s\n' "not$(printf '\037')a$(printf '\037')row" > "$CACHE"
( cd "$CR" || exit 99; PG_REPO_ROOT="$CR" pg_range_reviewed "$CB..$CH" ); rc=$?
[ "$rc" -eq 0 ] && pass "cache: a corrupt index is ignored" || bad "corrupt cache changed the verdict ($rc)"
# pg_file_covered_by_any (kept as a wrapper) agrees with the batched verdict, file by file.
# P1: `cd ... || exit 1` inside the subshell used to share status 1 with a genuine "not covered"
# verdict (pg_file_covered_by_any: 0 = covered, 1 = not — see hooks/lib/pipeline-gate-lib.sh:441), so
# a broken $CR made the "should NOT be covered" case pass VACUOUSLY instead of failing loudly. The cd
# failure now uses its OWN code (99, outside the function's 0/1 range) and each case asserts the
# function's EXACT expected status, not merely zero-vs-nonzero.
rc=0; ( cd "$CR" || exit 99; pg_file_covered_by_any "$CR" "$CR/memory/reviews" "$CH" "$CB..$CH" src/a.sh ) || rc=$?
case "$rc" in
  0) pass "wrapper: pg_file_covered_by_any covered file" ;;
  99) bad "wrapper: pg_file_covered_by_any covered file — cd \"\$CR\" failed (setup broken, not a coverage verdict)" ;;
  *) bad "wrapper: src/a.sh should be covered (rc=$rc, expected exactly 0)" ;;
esac
rm -f "$CR/memory/reviews/fresh.md"
rc=0; ( cd "$CR" || exit 99; pg_file_covered_by_any "$CR" "$CR/memory/reviews" "$CH" "$CB..$CH" src/c.sh ) || rc=$?
case "$rc" in
  1) pass "wrapper: pg_file_covered_by_any uncovered file" ;;
  99) bad "wrapper: pg_file_covered_by_any uncovered file — cd \"\$CR\" failed (setup broken, not a coverage verdict)" ;;
  *) bad "wrapper: src/c.sh should NOT be covered (rc=$rc, expected exactly 1)" ;;
esac
# An EMPTY reviews dir under pipefail (how every hook runs): all files listed, rc 0 — not rc 2.
rm -f "$CR"/memory/reviews/*.md
out="$( set -o pipefail; cd "$CR" || exit 99; PG_REPO_ROOT="$CR" pg_uncovered_files "$CB..$CH" )"; rc=$?
[ "$rc" -eq 0 ] && [ "$(printf '%s\n' "$out" | grep -c .)" -eq 3 ] \
  && pass "engine: empty reviews dir under pipefail → every file uncovered, rc 0" \
  || bad "engine: empty reviews dir under pipefail gave rc=$rc out=[$out]"
rm -rf "$CR"

# ---------- escape valve ----------
( ZUVO_ALLOW_ADHOC=1 pg_allow_adhoc ) && pass "allow_adhoc honors env=1" || bad "adhoc=1 should be allowed"
( unset ZUVO_ALLOW_ADHOC 2>/dev/null; pg_allow_adhoc ) && bad "adhoc unset should NOT allow" || pass "allow_adhoc off when unset"

# ---------- agent-env detection ----------
( ZUVO_AGENT=1 pg_is_agent_env ) && pass "agent_env: ZUVO_AGENT=1 → agent" || bad "ZUVO_AGENT=1 should be agent"

# ZUVO_AI_RUN is the repo's OWN agent marker (skills/refactor/SKILL.md, refactor-gate-lib.sh).
# It was missing from pg_is_agent_env while _is_agent_env had it, and pre-push-gate.sh exempts
# whatever this says is human — so a marked agent run skipped the pipeline gate outright.
# env -i is MANDATORY here, not decoration. This suite runs inside an agent harness, so
# CLAUDECODE/CLAUDE_PLUGIN_ROOT are already set in the ambient environment and pg_is_agent_env
# returns 0 through THOSE — a bare `( ZUVO_AI_RUN=1 pg_is_agent_env )` passes whether or not
# ZUVO_AI_RUN is in the list, i.e. it asserts nothing. (Caught by probing the mutant: removing
# ZUVO_AI_RUN from the loop left this assertion green.) Same isolation the clean-env case below
# already uses.
env -i PATH="$PATH" ZUVO_AI_RUN=1 bash -c ". '$LIB'; pg_is_agent_env" \
  && pass "agent_env: ZUVO_AI_RUN=1 → agent (was the pre-push fail-open)" \
  || bad "ZUVO_AI_RUN=1 must be agent — pre-push-gate exempts humans, so this is a gate bypass"
env -i PATH="$PATH" ANTIGRAVITY_SESSION_ID=x bash -c ". '$LIB'; pg_is_agent_env" \
  && pass "agent_env: ANTIGRAVITY_SESSION_ID → agent" \
  || bad "ANTIGRAVITY_SESSION_ID must be agent"

# Exercise both consumers for every marker in the single source, in an otherwise empty env.
_rg_lib="$ROOT/hooks/lib/refactor-gate-lib.sh"
_markers=$(sed -n '/^zuvo_is_agent_env()/,/^}/p' "$ROOT/hooks/lib/agent-env.sh" | grep -oE '\$\{[A-Z][A-Z0-9_]*' | sed 's/^\${//' | sort -u)
if [ -z "$_markers" ]; then
  bad "shared detector marker extraction returned no markers"
fi
for marker in $_markers; do
  if env -i PATH="$PATH" "$marker=1" bash -c '. "$1"; pg_is_agent_env' _ "$LIB" &&
     env -i PATH="$PATH" "$marker=1" sh -c '. "$1"; _is_agent_env' _ "$_rg_lib"; then
    pass "shared detector: $marker arms both gates"
  else
    bad "shared detector: $marker failed in a consumer"
  fi
done
env -i PATH="$PATH" bash -c ". '$LIB'; pg_is_agent_env" \
  && bad "clean env should be human" \
  || pass "agent_env: clean env → human (pass-through)"

# A partial install must not turn a missing shared detector into a human
# classification: that would silently skip the pre-push pipeline gate.
_missing_dir="$(mktemp -d)"
_missing_lib="$_missing_dir/pipeline-gate-lib.sh"
cp "$LIB" "$_missing_lib"
env -i PATH="$PATH" bash -c '. "$1"; pg_is_agent_env' _ "$_missing_lib" >/dev/null 2>&1
_missing_rc=$?
rm -rf "$_missing_dir"
[ "$_missing_rc" -eq 0 ] \
  && pass "agent_env: missing detector → fail-closed agent classification" \
  || bad "missing detector must fail-closed as agent"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
