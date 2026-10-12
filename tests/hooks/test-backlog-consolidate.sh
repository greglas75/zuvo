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
count() { python3 -c 'import sys; print(open(sys.argv[1],"rb").read().count(sys.argv[2].encode()))' "$1" "$2"; }
has_line() { printf '%s\n' "$out" | grep -qxF -- "$1"; }

# A repo whose first commit holds only a .gitignore with $2.
init_repo() {
  git init -q -b main "$DEV/$1"
  printf '%s' "${2:-}" > "$DEV/$1/.gitignore"
  git -C "$DEV/$1" add .gitignore && git -C "$DEV/$1" commit -qm init
}

# ── 1. tracked on both sides: git's to merge — main never written ───────────────────────────────────
echo "1. tracked in main and in the worktree"
git init -q -b main "$DEV/tracked"
mkdir -p "$DEV/tracked/memory" "$DEV/tracked/knowledge"
printf '# Backlog\n\n| ID | Title |\n|----|-------|\n| B-12 | old |\n' > "$DEV/tracked/memory/backlog.md"
printf '{"id":"k1","t":"a"}\n' > "$DEV/tracked/knowledge/facts.jsonl"
git -C "$DEV/tracked" add -A && git -C "$DEV/tracked" commit -qm init
git -C "$DEV/tracked" worktree add -q "$DEV/tracked-wt" -b feat
printf '# Backlog\n\n| ID | Title |\n|----|-------|\n| B-12 | changed |\n| B-13 | new |\n' > "$DEV/tracked-wt/memory/backlog.md"
printf '{"id":"k1","t":"a"}\n{"id":"k2","t":"b"}\n' > "$DEV/tracked-wt/knowledge/facts.jsonl"
main_md_before="$(sha "$DEV/tracked/memory/backlog.md")"
main_jl_before="$(sha "$DEV/tracked/knowledge/facts.jsonl")"
wt_md_before="$(sha "$DEV/tracked-wt/memory/backlog.md")"
out="$(consolidate)"
check "main backlog.md byte-identical" '[ "$(sha "$DEV/tracked/memory/backlog.md")" = "$main_md_before" ]'
check "main knowledge jsonl byte-identical" '[ "$(sha "$DEV/tracked/knowledge/facts.jsonl")" = "$main_jl_before" ]'
check "main checkout clean (git status)" '[ -z "$(git -C "$DEV/tracked" status --porcelain)" ]'
check "no backup written in main" '! ls "$DEV/tracked/memory" "$DEV/tracked/knowledge" | grep -q "\.bak-"'
check "worktree copy kept, not stubbed" '[ "$(sha "$DEV/tracked-wt/memory/backlog.md")" = "$wt_md_before" ]'
check "report names both files TRACKED" \
  'has_line "  TRACKED: tracked-wt/memory/backlog.md" && has_line "  TRACKED: tracked-wt/knowledge/facts.jsonl"'
git -C "$DEV/tracked-wt" commit -qam wt
check "main still fast-forwards to the worktree branch" 'git -C "$DEV/tracked" merge -q --ff-only feat'

# ── 2. tracked only in the worktree (the branch adds it): main must not grow an untracked copy ─────
echo "2. tracked only in the worktree"
init_repo wtonly
git -C "$DEV/wtonly" worktree add -q "$DEV/wtonly-wt" -b feat
mkdir -p "$DEV/wtonly-wt/memory" && printf '| B-1 | new |\n' > "$DEV/wtonly-wt/memory/backlog.md"
git -C "$DEV/wtonly-wt" add memory/backlog.md && git -C "$DEV/wtonly-wt" commit -qm backlog
out="$(consolidate)"
check "no main copy created" '[ ! -e "$DEV/wtonly/memory/backlog.md" ]'
check "report names it TRACKED" 'has_line "  TRACKED: wtonly-wt/memory/backlog.md"'
check "main fast-forwards to the branch that adds it" 'git -C "$DEV/wtonly" merge -q --ff-only feat'

# ── 3. tracked only in main: main not written, entries reported for a hand merge ────────────────────
echo "3. tracked only in main"
git init -q -b main "$DEV/mainonly"
mkdir -p "$DEV/mainonly/memory"
printf '| B-1 | one |\n' > "$DEV/mainonly/memory/backlog.md"
git -C "$DEV/mainonly" add -A && git -C "$DEV/mainonly" commit -qm init
git -C "$DEV/mainonly" worktree add -q "$DEV/mainonly-wt" -b feat
git -C "$DEV/mainonly-wt" rm -q --cached memory/backlog.md && git -C "$DEV/mainonly-wt" commit -qm untrack
printf '| B-1 | one |\n| B-2 | two |\n' > "$DEV/mainonly-wt/memory/backlog.md"
git -C "$DEV/mainonly" worktree add -q "$DEV/mainonly-wt2" -b feat2
git -C "$DEV/mainonly-wt2" rm -q --cached memory/backlog.md && git -C "$DEV/mainonly-wt2" commit -qm untrack
main_before="$(sha "$DEV/mainonly/memory/backlog.md")"
wt_before="$(sha "$DEV/mainonly-wt/memory/backlog.md")"
out="$(consolidate)"
check "main byte-identical and clean" \
  '[ "$(sha "$DEV/mainonly/memory/backlog.md")" = "$main_before" ] && [ -z "$(git -C "$DEV/mainonly" status --porcelain)" ]'
check "worktree copy with B-2 kept" '[ "$(sha "$DEV/mainonly-wt/memory/backlog.md")" = "$wt_before" ]'
check "report asks for a hand merge of 1 entry" \
  'has_line "  HAND MERGE: mainonly-wt/memory/backlog.md: +1 entries mainonly/memory/backlog.md lacks"'
check "a copy main already holds is stubbed" 'grep -q "MOVED — canonical" "$DEV/mainonly-wt2/memory/backlog.md"'

# ── 4. untracked copies: merged by entry ID ─────────────────────────────────────────────────────────
echo "4. untracked copies, merged by entry ID"
init_repo plain 'memory/
knowledge/
'
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt" -b feat
mkdir -p "$DEV/plain/memory" "$DEV/plain-wt/memory"
cat > "$DEV/plain/memory/backlog.md" <<'MD'
# Backlog

| ID | Title |
|----|-------|
| B-12 | old text |
| DONE B-14 | closed in main |
| B-15 | open |
- [ ] **B-20** list entry
- [ ] **[S] B-18 [P3]** sized entry
- [B-19](https://example.test/19) linked entry
- B-30 parent
  - B-31 is mentioned in a body line
MD
cat > "$DEV/plain-wt/memory/backlog.md" <<'MD'
# Backlog

## Merged from worktree other (2026-01-01)
| ID | Title |
|----|-------|
| B-12 | old text |
| B-14 | closed in main |
| WIP B-15 | open |
| B-13 | new row |
- [x] **B-20** list entry
- [ ] **[S] B-18 [P3]** sized entry, rewritten
- [B-19](https://example.test/19) linked entry, rewritten
- [ ] **[M] B-17 [P2]** new sized entry
1. B-21 new numbered entry
- B-30 parent
  - B-31 is mentioned in another body line
## A new section
# A new top-level section
a free-text note
MD
cp "$DEV/plain-wt/memory/backlog.md" "$T/wt-content.md"
out="$(consolidate)"
main="$DEV/plain/memory/backlog.md"
check "report: +7 unique" 'has_line "  plain-wt/memory/backlog.md: +7 unique -> plain/memory/backlog.md"'
check "new row B-13 appended once" '[ "$(count "$main" "| B-13 |")" = 1 ]'
check "new sized entry B-17 appended once" '[ "$(count "$main" "B-17")" = 1 ]'
check "new numbered entry B-21 appended once" '[ "$(count "$main" "B-21")" = 1 ]'
check "indented body line appended (not keyed as B-31)" '[ "$(count "$main" "in another body line")" = 1 ]'
check "new headings appended once" '[ "$(count "$main" "## A new section")" = 1 ] && [ "$(count "$main" "# A new top-level section")" = 1 ]'
check "free-text line appended once" '[ "$(count "$main" "a free-text note")" = 1 ]'
check "edited B-12/B-14/B-15/B-18/B-19/B-20 not duplicated" \
  'for id in B-12 B-14 B-15 B-18 B-19 B-20; do [ "$(count "$main" "$id")" = 1 ] || exit 1; done'
check "table header not duplicated" '[ "$(count "$main" "| ID | Title |")" = 1 ]'
check "a copied \"## Merged from\" heading not appended" '[ "$(count "$main" "Merged from worktree other")" = 0 ]'
check "backup of main written" 'ls "$DEV/plain/memory" | grep -q "^backlog.md.bak-"'
# A status word, a ticked box, a rewrite: the same entry (not appended) but an edit all the same —
# the stub would erase it, so the worktree copy stays and the report names each.
check "worktree copy holding the edits kept" 'cmp -s "$T/wt-content.md" "$DEV/plain-wt/memory/backlog.md"'
check "report names the edited entries" 'has_line "  EDITED: plain-wt/memory/backlog.md: B-14, B-15, B-20, B-18, B-19"'

# ── 5. a worktree with nothing new or edited is stubbed; re-runs change nothing ────────────────────
echo "5. stub and re-run"
main_before="$(sha "$main")"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt2" -b feat2
mkdir -p "$DEV/plain-wt2/memory" && cp "$main" "$DEV/plain-wt2/memory/backlog.md"
out="$(consolidate)"
check "worktree with main's entries: +0 unique" 'has_line "  plain-wt2/memory/backlog.md: +0 unique -> plain/memory/backlog.md"'
check "that worktree copy stubbed" 'grep -q "MOVED — canonical" "$DEV/plain-wt2/memory/backlog.md"'
check "edited worktree: +0 on re-run" 'has_line "  plain-wt/memory/backlog.md: +0 unique -> plain/memory/backlog.md"'
check "main byte-identical after re-run" '[ "$(sha "$main")" = "$main_before" ]'
out="$(consolidate)"
check "third run: main still byte-identical" '[ "$(sha "$main")" = "$main_before" ]'

# ── 6. jsonl: a record edited in the worktree is kept, not stubbed away ─────────────────────────────
echo "6. jsonl records"
mkdir -p "$DEV/plain/knowledge" "$DEV/plain-wt2/knowledge"
printf '{"id":"k1","t":"a"}\n' > "$DEV/plain/knowledge/facts.jsonl"
printf '{"t":"a","id":"k1"}\n{"id":"k2","t":"b"}\n' > "$DEV/plain-wt2/knowledge/facts.jsonl"
out="$(consolidate)"
check "new record k2 appended, k1 (same record, keys reordered) not" \
  '[ "$(count "$DEV/plain/knowledge/facts.jsonl" "k2")" = 1 ] && [ "$(count "$DEV/plain/knowledge/facts.jsonl" "k1")" = 1 ]'
check "unchanged jsonl copy stubbed" 'grep -q "MOVED — canonical" "$DEV/plain-wt2/knowledge/facts.jsonl"'
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt3" -b feat3
mkdir -p "$DEV/plain-wt3/knowledge"
printf '{"id":"k1","t":"rewritten"}\n' > "$DEV/plain-wt3/knowledge/facts.jsonl"
out="$(consolidate)"
check "edited record not appended" '! grep -q rewritten "$DEV/plain/knowledge/facts.jsonl"'
check "jsonl copy holding the edit kept" 'grep -q rewritten "$DEV/plain-wt3/knowledge/facts.jsonl"'
check "report names the edited record" "has_line '  EDITED: plain-wt3/knowledge/facts.jsonl: \"k1\"'"

# ── 7. bytes that are not UTF-8 reach main unchanged ────────────────────────────────────────────────
echo "7. non-UTF-8 bytes"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt4" -b feat4
mkdir -p "$DEV/plain-wt4/memory"
printf '| B-50 | caf\351 \342\200\224 latin-1 and utf-8 |\n' > "$DEV/plain-wt4/memory/backlog.md"
out="$(LC_ALL=C consolidate)"
check "latin-1 byte and utf-8 dash appended byte-exact" \
  'python3 -c "import sys; sys.exit(b\"caf\\xe9 \\xe2\\x80\\x94 latin-1\" not in open(sys.argv[1],\"rb\").read())" "$main"'

# ── 8. --dry-run writes nothing ─────────────────────────────────────────────────────────────────────
echo "8. --dry-run"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt5" -b feat5
mkdir -p "$DEV/plain-wt5/memory"
printf '| B-40 | new |\n' > "$DEV/plain-wt5/memory/backlog.md"
main_before="$(sha "$main")"
wt5_before="$(sha "$DEV/plain-wt5/memory/backlog.md")"
out="$(consolidate --dry-run)"
check "dry-run reports +1" 'has_line "  plain-wt5/memory/backlog.md: +1 unique -> plain/memory/backlog.md"'
check "dry-run leaves main untouched" '[ "$(sha "$main")" = "$main_before" ]'
check "dry-run leaves worktree untouched" '[ "$(sha "$DEV/plain-wt5/memory/backlog.md")" = "$wt5_before" ]'

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
