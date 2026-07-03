#!/usr/bin/env bash
# Task 7 — Stop-gate nudge. Feeds synthetic Stop JSON payloads; asserts exit
# codes. exit 2 = block-and-nudge (Claude honors it); 0 = allow finish.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HOOK="$ROOT/hooks/zuvo-stop-pipeline-gate.sh"
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
  git add -A; git commit -qm feat       # substantial vs merge-base(main)
) || { bad "fixture init"; echo "SOME FAILED"; exit 1; }

stop() { # $1=json $2..=env ; runs under PG_REPO_ROOT=$TMP unless overridden
  printf '%s' "$1" | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" "${@:2}" bash "$HOOK" 2>&1
}

# (a) not-active + substantial + unreviewed → nudge + exit 2
out=$(stop '{"stop_hook_active": false}'); rc=$?
if [ "$rc" -eq 2 ] && printf '%s' "$out" | grep -q 'unreviewed work'; then
  pass "(a) substantial unreviewed at Stop → nudge + exit 2 (blocks on Claude)"
else
  bad "(a) expected nudge + exit 2 (rc=$rc, out=$out)"
fi

# (b) stop_hook_active:true → loop guard → exit 0
out=$(stop '{"stop_hook_active": true}'); rc=$?
[ "$rc" -eq 0 ] && pass "(b) stop_hook_active:true → loop guard exit 0" || bad "(b) loop guard failed (rc=$rc)"

# (c) reviewed → exit 0  (artifact must cover the REAL merge-base..HEAD range)
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
out=$(stop '{"stop_hook_active": false}'); rc=$?
[ "$rc" -eq 0 ] && pass "(c) reviewed → exit 0" || bad "(c) reviewed should exit 0 (rc=$rc)"
rm -rf "$TMP/memory/reviews"

# (d) ZUVO_ALLOW_ADHOC=1 → exit 0
out=$(stop '{"stop_hook_active": false}' ZUVO_ALLOW_ADHOC=1); rc=$?
[ "$rc" -eq 0 ] && pass "(d) ZUVO_ALLOW_ADHOC=1 → exit 0" || bad "(d) adhoc should exit 0 (rc=$rc)"

# (e) docs/test-only (not substantial) → exit 0
(
  cd "$TMP" && git checkout -q -b docsonly main
  mkdir -p docs; for i in $(seq 1 200); do echo "l$i" >> docs/big.md; done
  git add -A; git commit -qm docs
) >/dev/null 2>&1
out=$(printf '%s' '{"stop_hook_active": false}' | env ZUVO_AGENT=1 PG_REPO_ROOT="$TMP" bash "$HOOK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "(e) docs-only HEAD → not substantial → exit 0" || bad "(e) docs-only should exit 0 (rc=$rc)"
( cd "$TMP" && git checkout -q feature ) >/dev/null 2>&1

# (e2) human (no agent env) → exit 0
out=$(printf '%s' '{"stop_hook_active": false}' | env -i PATH="$PATH" PG_REPO_ROOT="$TMP" bash "$HOOK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "(e2) human session → exit 0 (no nudge)" || bad "(e2) human should exit 0 (rc=$rc)"

# (f) fail-open: bad JSON + no repo → exit 0  (PG_REPO_ROOT=$NOREPO: isolate from the
# ambient repo, which may legitimately have un-pushed unreviewed work that would nudge)
out=$(printf 'not json at all' | env ZUVO_AGENT=1 PG_REPO_ROOT="$NOREPO" bash "$HOOK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "(f1) bad JSON + no repo → fail-open exit 0" || bad "(f1) should fail-open (rc=$rc)"
# (f2) empty stdin + no repo → exit 0
out=$(printf '' | env ZUVO_AGENT=1 PG_REPO_ROOT="$NOREPO" bash "$HOOK" 2>&1); rc=$?
[ "$rc" -eq 0 ] && pass "(f2) empty stdin + non-repo → fail-open exit 0" || bad "(f2) should fail-open (rc=$rc)"

# (g) ZUVO_STOP_NUDGE_EXIT=0 degrade → nudge but exit 0
out=$(stop '{"stop_hook_active": false}' ZUVO_STOP_NUDGE_EXIT=0); rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q 'unreviewed work'; then
  pass "(g) ZUVO_STOP_NUDGE_EXIT=0 → nudge but exit 0 (degrade)"
else
  bad "(g) degrade override failed (rc=$rc)"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
