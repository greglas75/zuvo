#!/usr/bin/env bash
# Task 6 — commit-gate best-effort nudge. The nudge NEVER blocks (exit 0 in all
# nudge cases); the pre-existing execute-run adversarial block is preserved.
set -u
# The 2026-07-23 adversarial proof-of-work layer is covered by test-review-proof-gate.sh;
# this nudge test grandfathers it off so its proofless coverage fixture behaves as before.
export PG_REVIEW_PROOF_CUTOFF=99999999999

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/pre-commit-adversarial-gate.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
NOREPO="$(mktemp -d)"
trap 'rm -rf "$TMP" "$NOREPO"' EXIT
(
  cd "$TMP" || exit 1
  git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main; }
  git config user.email t@t.t; git config user.name t; git config commit.gpgsign false
  echo base > base.txt; git add -A; git commit -qm base
  git checkout -q -b feature
  mkdir -p src; echo a > src/a.sh; echo b > src/b.sh; echo c > src/c.sh
  git add -A; git commit -qm feat   # merge-base..HEAD = 3 prod files (substantial)
) || { bad "fixture init"; echo "SOME FAILED"; exit 1; }

# run the hook with given stdin + extra env; capture combined output + rc
run() { # $1=cwd  $2=stdin  $3..=env assignments
  local cwd="$1"; shift; local stdin="$1"; shift
  ( cd "$cwd" && printf '%s' "$stdin" | env ZUVO_HOME="$TMP/.zh" "$@" bash "$HOOK" 2>&1 )
}

# (a) substantial + unreviewed → nudge text, exit 0
out=$(run "$TMP" "git commit -m x" ZUVO_AGENT=1 PG_REPO_ROOT="$TMP"); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'not review-covered'; then
  pass "(a) substantial unreviewed → NUDGE printed, exit 0"
else
  bad "(a) expected nudge + exit 0 (rc=$rc, out=$out)"
fi

# (b) reviewed → silent, exit 0  (artifact must cover the REAL merge-base..HEAD range)
mkdir -p "$TMP/memory/reviews"
MB=$(git -C "$TMP" merge-base HEAD main 2>/dev/null || git -C "$TMP" rev-parse main)
FH=$(git -C "$TMP" rev-parse HEAD)
cat > "$TMP/memory/reviews/cov.md" <<ART
<!-- zuvo-review -->
range: $MB..$FH
files: src/a.sh, src/b.sh, src/c.sh
verdict: PASS
-->
ART
out=$(run "$TMP" "git commit -m x" ZUVO_AGENT=1 PG_REPO_ROOT="$TMP"); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'not review-covered'; then
  pass "(b) reviewed → silent, exit 0"
else
  bad "(b) expected silent + exit 0 (rc=$rc, out=$out)"
fi
rm -rf "$TMP/memory/reviews"

# (c) ZUVO_ALLOW_ADHOC=1 → silent, exit 0
out=$(run "$TMP" "git commit -m x" ZUVO_AGENT=1 ZUVO_ALLOW_ADHOC=1 PG_REPO_ROOT="$TMP"); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'not review-covered'; then
  pass "(c) ZUVO_ALLOW_ADHOC=1 → silent, exit 0"
else
  bad "(c) expected silent + exit 0 (rc=$rc)"
fi

# (c2) human (no agent env) → no nudge, exit 0
out=$(cd "$TMP" && printf 'git commit -m x' | env -i PATH="$PATH" ZUVO_HOME="$TMP/.zh" PG_REPO_ROOT="$TMP" bash "$HOOK" 2>&1); rc=$?
if [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'not review-covered'; then
  pass "(c2) human commit → no nudge, exit 0"
else
  bad "(c2) human should not be nudged (rc=$rc)"
fi

# (d1) non-commit input → exit 0 immediately
out=$(run "$TMP" "git status" ZUVO_AGENT=1 PG_REPO_ROOT="$TMP"); rc=$?
[ "$rc" -eq 0 ] && pass "(d1) non-commit input → exit 0 (guard)" || bad "(d1) non-commit should exit 0"

# (d2) active execute run, in-progress, missing adversarial artifact → BLOCK (exit 1) preserved
mkdir -p "$TMP/zuvo/context"
cat > "$TMP/zuvo/context/execution-state.md" <<'ST'
# Execution State
<!-- status: in-progress -->
next-task: 9
ST
out=$(run "$TMP" "git commit -m x" ZUVO_AGENT=1 PG_REPO_ROOT="$TMP"); rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q 'BLOCKED'; then
  pass "(d2) active-execute, missing adversarial artifact → BLOCK (exit 1) preserved"
else
  bad "(d2) execute block path regressed (rc=$rc, out=$out)"
fi
rm -rf "$TMP/zuvo"

# (e) fail-open: no repo → exit 0
out=$(cd "$NOREPO" && printf 'git commit -m x' | env ZUVO_HOME="$TMP/.zh" ZUVO_AGENT=1 bash "$HOOK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "(e) no repo → fail-open exit 0" || bad "(e) no-repo should fail-open (rc=$rc)"

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
