#!/usr/bin/env bash
# Task 14 — whole-feature smoke. Drives the REAL pipeline-entry gates end-to-end
# on a throwaway repo with an overridable $HOME (never touches real ~/.claude or
# ~/.codex). Reproduces the root-cause incident (substantial feature, no review)
# and verifies every invariant G1–G12. Prints SMOKE PASS / SMOKE FAIL.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PREPUSH="$ROOT/hooks/pre-push-gate.sh"
CI="$ROOT/scripts/zuvo-pipeline-entry-ci.sh"
COMMIT="$ROOT/hooks/pre-commit-adversarial-gate.sh"
STOP="$ROOT/hooks/zuvo-stop-pipeline-gate.sh"
BLOCK="$ROOT/hooks/block-no-verify.sh"
SHIM="$ROOT/scripts/git-noverify-shim.sh"

fail=0
ok()  { printf '  ✓ %s\n' "$1"; }
no()  { printf '  ✗ %s\n' "$1"; fail=1; }

# overridable HOME — keep real ~/.claude / ~/.codex untouched
SMOKE_HOME="$(mktemp -d)"
export HOME="$SMOKE_HOME"
export ZUVO_HOME="$SMOKE_HOME/.zuvo"

TMP="$(mktemp -d)"
NOREPO="$(mktemp -d)"
REALBIN="$(mktemp -d)"
trap 'rm -rf "$SMOKE_HOME" "$TMP" "$NOREPO" "$REALBIN"' EXIT

# --- build a throwaway repo: main + feature(3 prod) + small(1) + docs(200) ---
(
  cd "$TMP" || exit 1
  git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main; }
  git config user.email s@s.s; git config user.name s; git config commit.gpgsign false
  echo base > base.txt; git add -A; git commit -qm base
  git checkout -q -b feature
  mkdir -p src; echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
  git add -A; git commit -qm feat
  echo tiny > src/tiny.sh; git add -A; git commit -qm tiny
  mkdir -p docs; for i in $(seq 1 200); do echo "l$i" >> docs/big.md; done
  git add -A; git commit -qm docs
) || { echo "SMOKE FAIL (fixture)"; exit 1; }
cd "$TMP" || { echo "SMOKE FAIL (cd)"; exit 1; }

MAIN=$(git rev-parse main)
git checkout -q feature
git reset -q --hard HEAD~2   # feature HEAD = the 3-prod-file commit
FHEAD=$(git rev-parse HEAD)
# rebuild small + docs commits on top for range tests
echo tiny > src/tiny.sh; git add -A; git commit -qm tiny; SMALL=$(git rev-parse HEAD)
mkdir -p docs; for i in $(seq 1 200); do echo "l$i" >> docs/big.md; done
git add -A; git commit -qm docs; DOCS=$(git rev-parse HEAD)
git checkout -q "$FHEAD" 2>/dev/null; git checkout -q -B feature "$FHEAD"

ZEROS=0000000000000000000000000000000000000000
prepush_native() { printf 'refs/heads/feature %s refs/heads/feature %s\n' "$1" "$2"; }

echo "── SMOKE: pipeline-entry end-to-end (HOME=$SMOKE_HOME) ──"

# === (1) substantial unreviewed → pre-push exit 1 AND CI exit 1 (the incident) ===
prepush_native "$FHEAD" "$MAIN" | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "G1 pre-push blocks substantial unreviewed push (exit 1)" || no "G1 pre-push should block"
ZUVO_CI_RANGE="$MAIN..$FHEAD" PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "G2 CI fails substantial unreviewed change (exit 1)" || no "G2 CI should fail"

# === (2) commit + Stop produce the nudge (G3) ===
out=$( printf 'git commit -m x' | env ZUVO_AGENT=1 ZUVO_HOME="$ZUVO_HOME" PG_REPO_ROOT="$TMP" bash "$COMMIT" 2>&1 ); rc=$?
{ [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not review-covered'; } \
  && ok "G3 commit-gate nudges (exit 0, non-blocking)" || no "G3 commit nudge"
out=$( printf '{"stop_hook_active": false}' | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$STOP" 2>&1 ); rc=$?
{ [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'unreviewed work'; } \
  && ok "G3 Stop-gate nudges + blocks finish (exit 2)" || no "G3 Stop nudge"

# === (6) docs-only → pre-push + CI pass (G7) ===
prepush_native "$DOCS" "$SMALL" | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G7 docs-only push passes (exit 0)" || no "G7 docs-only pre-push"
ZUVO_CI_RANGE="$SMALL..$DOCS" PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G7 docs-only CI passes (exit 0)" || no "G7 docs-only CI"

# === (7) block-no-verify (G5): commit -n → 2, push -n → 0 ===
printf 'git commit -n' | bash "$BLOCK" >/dev/null 2>&1
[ "$?" -eq 2 ] && ok "G5 block-no-verify: commit -n blocked (exit 2)" || no "G5 commit -n should block"
printf 'git push -n' | bash "$BLOCK" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G5 block-no-verify: push -n (dry-run) allowed (exit 0)" || no "G5 push -n should pass"

# === (8) shim (G5/G8): agent --no-verify blocked, human passes through ===
cat > "$REALBIN/git" <<'EOF'
#!/usr/bin/env bash
echo "REAL_GIT_CALLED $*"; exit 0
EOF
chmod +x "$REALBIN/git"
PATH="$REALBIN:$PATH" ZUVO_AGENT=1 bash "$SHIM" commit -m x --no-verify >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "G5 shim: agent --no-verify blocked (exit 1)" || no "G5 shim agent block"
o=$(env -i PATH="$REALBIN:$(dirname "$(command -v bash)"):/usr/bin:/bin" bash "$SHIM" commit -m x --no-verify 2>&1)
printf '%s' "$o" | grep -q REAL_GIT_CALLED && ok "G8 shim: human --no-verify passes through" || no "G8 shim human pass-through"

# === (9) malformed payloads → local gates fail-open (G12) ===
printf 'totally not a pre-push line' | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G12 pre-push fail-open on malformed stdin (exit 0)" || no "G12 pre-push fail-open"
printf 'git commit -m x' | env ZUVO_AGENT=1 ZUVO_HOME="$ZUVO_HOME" bash "$COMMIT" >/dev/null 2>&1   # no repo (cwd=TMP but...)
( cd "$NOREPO" && printf 'git commit -m x' | env ZUVO_AGENT=1 ZUVO_HOME="$ZUVO_HOME" bash "$COMMIT" >/dev/null 2>&1 )
[ "$?" -eq 0 ] && ok "G12 commit-gate fail-open with no repo (exit 0)" || no "G12 commit fail-open"
printf 'garbage' | env ZUVO_AGENT=1 PG_REPO_ROOT="$NOREPO" bash "$STOP" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G12 Stop-gate fail-open on bad JSON/no repo (exit 0)" || no "G12 Stop fail-open"

# === (5) escapes (G6): ZUVO_ALLOW_ADHOC local, adhoc-approved label CI ===
prepush_native "$FHEAD" "$MAIN" | env ZUVO_ALLOW_ADHOC=1 ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G6 ZUVO_ALLOW_ADHOC=1 → pre-push passes" || no "G6 local escape"
ZUVO_CI_RANGE="$MAIN..$FHEAD" ZUVO_CI_LABELS="zuvo:adhoc-approved" PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G6 zuvo:adhoc-approved label → CI passes" || no "G6 CI label escape"

# === (4) NO WHITELIST: an artifact whose RANGE matches but FILES don't (and vice
# versa) does NOT grant coverage — coverage is range-containment AND files (G4) ===
mkdir -p memory/reviews
cat > memory/reviews/unrelated.md <<ART
<!-- zuvo-review -->
range: $MAIN..$FHEAD
files: src/zzz.sh, src/qqq.sh
verdict: PASS
-->
ART
prepush_native "$FHEAD" "$MAIN" | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "G4 range-match but files-mismatch ≠ coverage (still blocked)" || no "G4 no-whitelist (files)"

# === (3) covering artifact (real range AND files) → pre-push + CI both pass (G4) ===
cat > memory/reviews/cov.md <<ART
<!-- zuvo-review -->
range: $MAIN..$FHEAD
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
ART
prepush_native "$FHEAD" "$MAIN" | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G4 covering artifact (range+files) → pre-push passes (exit 0)" || no "G4 covering pre-push"
ZUVO_CI_RANGE="$MAIN..$FHEAD" PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
[ "$?" -eq 0 ] && ok "G4 covering artifact → CI passes (exit 0)" || no "G4 covering CI"

# === (10) R3-1 NO PERMANENT WHITELIST: re-edit a covered file with a NEW commit
# beyond the reviewed range → blocked again (cov.md must not whitelist a.sh forever) ===
echo "new work" >> src/a.sh; git add -A; git commit -qm "re-edit a.sh beyond reviewed range"
NEWHEAD=$(git rev-parse HEAD)
prepush_native "$NEWHEAD" "$MAIN" | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$PREPUSH" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "G4/R3-1 re-edit beyond reviewed range → blocked (no permanent whitelist)" || no "R3-1 permanent-whitelist hole"
ZUVO_CI_RANGE="$MAIN..$NEWHEAD" PG_REPO_ROOT="$TMP" bash "$CI" >/dev/null 2>&1
[ "$?" -eq 1 ] && ok "G4/R3-1 CI also blocks the new range" || no "R3-1 CI permanent-whitelist hole"

echo ""
if [ "$fail" -eq 0 ]; then echo "SMOKE PASS"; else echo "SMOKE FAIL"; exit 1; fi
