#!/usr/bin/env bash
# shellcheck disable=SC2034  # the *_before snapshots and $out are read inside check's eval strings
# scripts/zuvo-home/backlog-consolidate.py against real git repos and linked worktrees in a sandbox
# HOME (the script scans $HOME/DEV/*/). Regression for S-66: the merge deduplicated whole lines, so a
# table row edited in a worktree (`| B-12 | old |` → `| B-12 | changed |`) was appended to main as a
# second B-12; and it appended to a main copy git tracks, leaving the main checkout dirty so that
# `git merge --ff-only` there stopped working.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/zuvo-home/backlog-consolidate.py"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); echo "  PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "  FAIL: $1"; }
check() { if eval "$2"; then pass "$1"; else fail "$1"; fi; }

T="$(mktemp -d)"
T="$(cd "$T" && pwd -P)"
trap 'rm -rf "$T"' EXIT
export HOME="$T/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
DEV="$HOME/DEV"
mkdir -p "$DEV"

consolidate() { python3 "$SCRIPT" "$@" 2>&1; }
sha() { python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$1"; }
count() { python3 -c 'import sys; print(open(sys.argv[1]).read().count(sys.argv[2]))' "$1" "$2"; }

# ── 1. main copy tracked by git: never written, worktree copy kept ──────────────────────────────────
echo "1. tracked main copy"
git init -q -b main "$DEV/tracked"
mkdir -p "$DEV/tracked/memory" "$DEV/tracked/knowledge"
printf '# Backlog\n\n| ID | Title |\n|----|-------|\n| B-12 | old |\n' > "$DEV/tracked/memory/backlog.md"
printf '{"id":"k1","t":"a"}\n' > "$DEV/tracked/knowledge/facts.jsonl"
git -C "$DEV/tracked" add -A && git -C "$DEV/tracked" commit -qm init
git -C "$DEV/tracked" worktree add -q "$DEV/tracked-wt" -b feat
sed -i.orig 's/| B-12 | old |/| B-12 | changed |/' "$DEV/tracked-wt/memory/backlog.md" && rm "$DEV/tracked-wt/memory/backlog.md.orig"
printf '| B-13 | new |\n' >> "$DEV/tracked-wt/memory/backlog.md"
printf '{"id":"k2","t":"b"}\n' >> "$DEV/tracked-wt/knowledge/facts.jsonl"
main_md_before="$(sha "$DEV/tracked/memory/backlog.md")"
main_jl_before="$(sha "$DEV/tracked/knowledge/facts.jsonl")"
wt_md_before="$(sha "$DEV/tracked-wt/memory/backlog.md")"
out="$(consolidate)"
check "main backlog.md byte-identical" '[ "$(sha "$DEV/tracked/memory/backlog.md")" = "$main_md_before" ]'
check "main knowledge jsonl byte-identical" '[ "$(sha "$DEV/tracked/knowledge/facts.jsonl")" = "$main_jl_before" ]'
check "main checkout clean (git status)" '[ -z "$(git -C "$DEV/tracked" status --porcelain)" ]'
check "no backup written in main" '! ls "$DEV/tracked/memory" "$DEV/tracked/knowledge" | grep -q "\.bak-"'
check "worktree copy kept, not stubbed" '[ "$(sha "$DEV/tracked-wt/memory/backlog.md")" = "$wt_md_before" ]'
check "report names both files MAIN TRACKED" \
  '[ "$(printf "%s\n" "$out" | grep -c "MAIN TRACKED: tracked/")" = 2 ]'
git -C "$DEV/tracked-wt" commit -qam wt
check "main still fast-forwards to the worktree branch" 'git -C "$DEV/tracked" merge -q --ff-only feat'

# ── 2. untracked copies: merged by entry ID ─────────────────────────────────────────────────────────
echo "2. untracked copies, merged by entry ID"
git init -q -b main "$DEV/plain"
printf 'memory/\n' > "$DEV/plain/.gitignore"
git -C "$DEV/plain" add .gitignore && git -C "$DEV/plain" commit -qm init
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt" -b feat
mkdir -p "$DEV/plain/memory" "$DEV/plain-wt/memory"
cat > "$DEV/plain/memory/backlog.md" <<'MD'
# Backlog

| ID | Title |
|----|-------|
| B-12 | old text |
| DONE B-14 | closed in main |
- [ ] **B-20** list entry
MD
cat > "$DEV/plain-wt/memory/backlog.md" <<'MD'
# Backlog

| ID | Title |
|----|-------|
| B-12 | old text |
| B-14 | closed in main |
| B-13 | new row |
- [x] **B-20** list entry
- [ ] B-21 new list entry
a free-text note
MD
cp "$DEV/plain-wt/memory/backlog.md" "$T/wt-content.md"
out="$(consolidate)"
main="$DEV/plain/memory/backlog.md"
check "report: +3 unique" 'printf "%s\n" "$out" | grep -q "plain-wt/memory/backlog.md: +3 unique"'
check "new row B-13 appended once" '[ "$(count "$main" "| B-13 |")" = 1 ]'
check "new list entry B-21 appended once" '[ "$(count "$main" "B-21")" = 1 ]'
check "free-text line appended once" '[ "$(count "$main" "a free-text note")" = 1 ]'
check "B-12 not duplicated" '[ "$(count "$main" "B-12")" = 1 ]'
check "B-14 (status word in main) not duplicated" '[ "$(count "$main" "B-14")" = 1 ]'
check "B-20 (checkbox ticked) not duplicated" '[ "$(count "$main" "B-20")" = 1 ]'
check "table header not duplicated" '[ "$(count "$main" "| ID | Title |")" = 1 ]'
check "backup of main written" 'ls "$DEV/plain/memory" | grep -q "^backlog.md.bak-"'
# B-14 differs by its status word: still the same entry (not appended), but an edit all the same —
# the stub would erase it, so the worktree copy stays and the report names it.
check "worktree copy with a differing B-14 kept" 'cmp -s "$T/wt-content.md" "$DEV/plain-wt/memory/backlog.md"'
check "report names B-14 as EDITED" 'printf "%s\n" "$out" | grep -q "EDITED: plain-wt/memory/backlog.md: B-14$"'

# ── 3. nothing new and nothing edited: stubbed; re-runs change nothing ──────────────────────────────
echo "3. stub and re-run"
main_before="$(sha "$main")"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt2" -b feat2
mkdir -p "$DEV/plain-wt2/memory" && cp "$main" "$DEV/plain-wt2/memory/backlog.md"
out="$(consolidate)"
check "worktree with main's entries: +0 unique" 'printf "%s\n" "$out" | grep -q "plain-wt2/memory/backlog.md: +0 unique"'
check "that worktree copy stubbed" 'grep -q "MOVED — canonical" "$DEV/plain-wt2/memory/backlog.md"'
check "first worktree (B-14 edit): +0 on re-run" 'printf "%s\n" "$out" | grep -q "plain-wt/memory/backlog.md: +0 unique"'
check "main byte-identical after re-run" '[ "$(sha "$main")" = "$main_before" ]'
out="$(consolidate)"
check "third run: main still byte-identical" '[ "$(sha "$main")" = "$main_before" ]'

# ── 4. an entry edited in the worktree: not appended, and the worktree copy is kept ─────────────────
echo "4. entry edited in the worktree"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt3" -b feat3
mkdir -p "$DEV/plain-wt3/memory"
printf '# Backlog\n\n| B-12 | changed in the worktree |\n| B-30 | new |\n' > "$DEV/plain-wt3/memory/backlog.md"
wt3_before="$(sha "$DEV/plain-wt3/memory/backlog.md")"
out="$(consolidate)"
check "edited B-12 not appended" '[ "$(count "$main" "B-12")" = 1 ] && ! grep -q "changed in the worktree" "$main"'
check "new B-30 appended" '[ "$(count "$main" "| B-30 |")" = 1 ]'
check "worktree copy holding the edit kept" '[ "$(sha "$DEV/plain-wt3/memory/backlog.md")" = "$wt3_before" ]'
check "report names the edited ID" 'printf "%s\n" "$out" | grep -q "EDITED: plain-wt3/memory/backlog.md: B-12"'

# ── 5. --dry-run writes nothing ─────────────────────────────────────────────────────────────────────
echo "5. --dry-run"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt4" -b feat4
mkdir -p "$DEV/plain-wt4/memory"
printf '| B-40 | new |\n' > "$DEV/plain-wt4/memory/backlog.md"
main_before="$(sha "$main")"
wt4_before="$(sha "$DEV/plain-wt4/memory/backlog.md")"
out="$(consolidate --dry-run)"
check "dry-run reports +1" 'printf "%s\n" "$out" | grep -q "plain-wt4/memory/backlog.md: +1 unique"'
check "dry-run leaves main untouched" '[ "$(sha "$main")" = "$main_before" ]'
check "dry-run leaves worktree untouched" '[ "$(sha "$DEV/plain-wt4/memory/backlog.md")" = "$wt4_before" ]'

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
