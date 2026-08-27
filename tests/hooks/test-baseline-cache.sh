#!/usr/bin/env bash
# Contract for baseline-cache — one green baseline shared by every worktree of one commit.
#
# The saving is real (12 worktrees branched from one commit in a single 12-hour window, each
# running the same full suite over identical code), but a cache that returns a stale or foreign
# GREEN is worse than no cache at all: it would let a refactor start on a tree whose baseline was
# never actually verified. So the negative cases below are the point of this file, not the
# positive one.
#
# bash 3.2-compatible (macOS default).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
BIN="$ROOT/scripts/zuvo-home/baseline-cache"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

command -v python3 >/dev/null 2>&1 || { echo "SKIP: python3 not available"; exit 0; }
command -v git     >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 0; }
[ -f "$BIN" ] || { bad "scripts/zuvo-home/baseline-cache does not exist"; exit 1; }

TMP="$(mktemp -d)"
export ZUVO_HOME="$TMP/zuvo"          # never touch the real ~/.zuvo from a test
trap 'rm -rf "$TMP"' EXIT

R="$TMP/repo"; mkdir -p "$R"
( cd "$R" && git init -q -b main && git config user.email t@t && git config user.name t \
  && printf '{"lockfileVersion":3}\n' > package-lock.json \
  && printf 'x\n' > a.txt && git add -A && git commit -qm one ) >/dev/null 2>&1

run() { python3 "$BIN" "$@" 2>"$TMP/err"; }

# ── 1. nothing recorded → check must MISS ────────────────────────────────────
run check "$R" >/dev/null
[ "$?" != 0 ] && pass "an empty cache reports a miss, not a hit" \
  || bad "an empty cache reported a hit"

# ── 1b. a MISSING result flag records nothing ────────────────────────────────
# The worst bug this file exists to prevent, and it shipped: `--green` defaulted to True, so
# `record --result "3 failed"` with no flag stored a GREEN entry that every other worktree then
# reused. The guarantee "only a green result is reused" rested on a caller remembering to type
# `--red` — an LLM reading prose. The safety-critical path must fail CLOSED.
run record "$R" --result "3 failed | 2 passed" >/dev/null
[ "$?" != 0 ] && pass "record refuses without an explicit --green/--red" \
  || bad "record accepted a result with no verdict flag"
run check "$R" >/dev/null
[ "$?" != 0 ] && pass "the refused record left nothing behind to reuse" \
  || bad "a flagless record still produced a reusable entry"
run record "$R" --result "x" --green --red >/dev/null
[ "$?" != 0 ] && pass "record refuses both flags at once" \
  || bad "record accepted --green and --red together"

# ── 2. a recorded green is reused, and its text comes back for quoting ───────
run record "$R" --result "42 passed (42)" --green >/dev/null
out=$(run check "$R")
[ "$?" = 0 ] && [ "$out" = "42 passed (42)" ] \
  && pass "a green baseline is reused and returns its own result text" \
  || bad "green not reused (exit/text: '$out')"

# ── 3. a NEW COMMIT invalidates it — the baseline is the commit ──────────────
( cd "$R" && printf 'y\n' > a.txt && git add -A && git commit -qm two ) >/dev/null 2>&1
run check "$R" >/dev/null
[ "$?" != 0 ] && pass "a new commit invalidates the baseline" \
  || bad "the cache answered for a commit it never verified"

# ── 4. CHANGED DEPENDENCIES invalidate it, at the same commit ────────────────
# Same source, different node_modules is not the same baseline — the reason worktree Step 4.5
# exists. A cache that ignored the lockfile would smuggle a mismatched install past that gate.
run record "$R" --result "7 passed (7)" --green >/dev/null
run check "$R" >/dev/null || bad "setup: the just-recorded entry should hit"
( cd "$R" && printf '{"lockfileVersion":3,"changed":true}\n' > package-lock.json ) 
run check "$R" >/dev/null
[ "$?" != 0 ] && pass "a changed lockfile invalidates the baseline at the same commit" \
  || bad "the cache reused a baseline across a dependency change"

# ── 5. a RED result is never reusable ────────────────────────────────────────
( cd "$R" && git checkout -q -- package-lock.json )
run record "$R" --result "1 failed | 6 passed" --red >/dev/null
run check "$R" >/dev/null
[ "$?" != 0 ] && pass "a red baseline is recorded but never satisfies a check" \
  || bad "a RED baseline was reused as if green"
grep -q "recorded RED" "$TMP/err" \
  && pass "the red case says so, instead of failing silently" \
  || bad "no diagnostic when the base is known-red"

# ── 6. age expires it ────────────────────────────────────────────────────────
run record "$R" --result "9 passed (9)" --green >/dev/null
run check "$R" --max-age-hours 0 >/dev/null
[ "$?" != 0 ] && pass "an entry older than the window is not reused" \
  || bad "an expired entry was reused"

# ── 6b. a FUTURE timestamp cannot outlive expiry ─────────────────────────────
# `age = now - recorded_at` goes NEGATIVE when the entry is stamped ahead, and negative is never
# greater than any threshold — so such an entry survived every expiry, including --max-age-hours 0.
# ~/.zuvo is written by more than one machine here; clock drift and resumed snapshots produce this.
run record "$R" --result "5 passed (5)" --green >/dev/null
ENTRY=$(ls "$ZUVO_HOME/baselines/"*.json 2>/dev/null | head -1)
if [ -n "$ENTRY" ]; then
  python3 - "$ENTRY" <<'PYF'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["recorded_at"] = time.time() + 999999      # stamped far in the future
json.dump(d, open(p, "w"))
PYF
  run check "$R" --max-age-hours 0 >/dev/null
  [ "$?" != 0 ] && pass "an entry stamped in the future is rejected, not reused forever" \
    || bad "a future timestamp defeated expiry"
  rm -f "$ENTRY"
else
  bad "could not locate the recorded entry to age-tamper"
fi

# ── 7. a DIFFERENT repository never collides ─────────────────────────────────
# Keyed on the common git dir, so linked worktrees of ONE repo share a key and a separate clone
# does not. A path-keyed cache would fail the first half; a URL-keyed one the second.
R2="$TMP/other"; mkdir -p "$R2"
( cd "$R2" && git init -q -b main && git config user.email t@t && git config user.name t \
  && printf '{"lockfileVersion":3}\n' > package-lock.json \
  && printf 'x\n' > a.txt && git add -A && git commit -qm one ) >/dev/null 2>&1
run check "$R2" >/dev/null
[ "$?" != 0 ] && pass "a different repository does not read this one's baseline" \
  || bad "cache collided across repositories"

# ── 8. a linked WORKTREE of the same repo DOES share it ──────────────────────
# The whole purpose: ten worktrees off one commit, one verification.
run record "$R" --result "11 passed (11)" --green >/dev/null
WT="$TMP/wt"
( cd "$R" && git worktree add -q --detach "$WT" HEAD ) >/dev/null 2>&1
if [ -d "$WT" ]; then
  out=$(run check "$WT")
  [ "$?" = 0 ] && [ "$out" = "11 passed (11)" ] \
    && pass "a linked worktree at the same commit reuses the baseline" \
    || bad "the worktree did not share its repository's baseline (got '$out')"
  ( cd "$R" && git worktree remove --force "$WT" ) >/dev/null 2>&1
else
  echo "SKIP: could not create a worktree here"
fi

# ── 9. the FAIL-OPEN branches, which are this tool's entire risk surface ─────
# Every one of these is a path between "cache miss, run the suite" and "trust something nobody
# verified". They all behaved correctly when probed by hand — but a suite that does not exercise
# them cannot say so, and that is the difference between working and being known to work.

# 9a. not a git repository at all
NG="$TMP/notgit"; mkdir -p "$NG"
run check "$NG" >/dev/null
[ "$?" != 0 ] && pass "a non-git directory is a miss, not a hit" \
  || bad "check returned a hit outside a git repository"
run record "$NG" --result "x" --green >/dev/null
[ "$?" != 0 ] && pass "record refuses outside a git repository" \
  || bad "record wrote an entry for a non-repository"

# 9b. a corrupted entry must read as a miss, never as a hit
run record "$R" --result "13 passed (13)" --green >/dev/null
BAD_ENTRY=$(ls "$ZUVO_HOME/baselines/"*.json 2>/dev/null | head -1)
if [ -n "$BAD_ENTRY" ]; then
  printf '{ this is not json' > "$BAD_ENTRY"
  run check "$R" >/dev/null
  [ "$?" != 0 ] && pass "a corrupted cache entry is a miss, not a crash and not a hit" \
    || bad "a corrupted entry satisfied the check"
  rm -f "$BAD_ENTRY"
else
  bad "could not locate an entry to corrupt"
fi

# 9c. a tree whose dependency state cannot be fingerprinted must never share
# No lockfile and no completed install: nothing on disk identifies the dependency set, so two
# unrelated trees would otherwise collide on one sentinel key.
NL="$TMP/nolock"; mkdir -p "$NL"
( cd "$NL" && git init -q -b main && git config user.email t@t && git config user.name t \
  && printf 'x\n' > a.txt && git add -A && git commit -qm one ) >/dev/null 2>&1
run record "$NL" --result "1 passed" --green >/dev/null
[ "$?" != 0 ] && pass "record refuses a tree with no fingerprintable dependency state" \
  || bad "recorded a baseline for an unfingerprintable tree"
run check "$NL" >/dev/null
[ "$?" != 0 ] && pass "check refuses an unfingerprintable tree" \
  || bad "an unfingerprintable tree was allowed to share a baseline"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
