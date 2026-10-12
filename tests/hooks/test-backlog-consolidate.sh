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

# $out is the script's output, $rc its exit code. run() also records a FAIL for a non-zero exit, so a
# crash fails the suite even where the byte-identical checks after it pass; run_rc() expects a failure.
run_rc() { out="$(python3 "$SCRIPT" "$@" 2>&1)"; rc=$?; }
run() { run_rc "$@"; [ "$rc" -eq 0 ] || fail "script exited $rc: $(printf '%s\n' "$out" | tail -1)"; }
bak_count() { find "$@" -maxdepth 1 -name '*.bak-*' | wc -l | tr -d ' '; }
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
wt_jl_before="$(sha "$DEV/tracked-wt/knowledge/facts.jsonl")"
run
check "main backlog.md byte-identical" '[ "$(sha "$DEV/tracked/memory/backlog.md")" = "$main_md_before" ]'
check "main knowledge jsonl byte-identical" '[ "$(sha "$DEV/tracked/knowledge/facts.jsonl")" = "$main_jl_before" ]'
check "main checkout clean (git status)" '[ -z "$(git -C "$DEV/tracked" status --porcelain)" ]'
check "no backup written in main" '[ "$(bak_count "$DEV/tracked/memory" "$DEV/tracked/knowledge")" = 0 ]'
check "worktree copies kept, not stubbed" \
  '[ "$(sha "$DEV/tracked-wt/memory/backlog.md")" = "$wt_md_before" ] && [ "$(sha "$DEV/tracked-wt/knowledge/facts.jsonl")" = "$wt_jl_before" ]'
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
run
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
run
check "main byte-identical and clean" \
  '[ "$(sha "$DEV/mainonly/memory/backlog.md")" = "$main_before" ] && [ -z "$(git -C "$DEV/mainonly" status --porcelain)" ]'
check "worktree copy with B-2 kept" '[ "$(sha "$DEV/mainonly-wt/memory/backlog.md")" = "$wt_before" ]'
check "report asks for a hand merge of 1 entry" \
  'has_line "  HAND MERGE: mainonly-wt/memory/backlog.md: +1 lines mainonly/memory/backlog.md lacks"'
check "a copy main already holds is stubbed, and named" \
  'grep -q "MOVED — canonical" "$DEV/mainonly-wt2/memory/backlog.md" && has_line "  STUBBED: mainonly-wt2/memory/backlog.md"'
git -C "$DEV/mainonly" worktree add -q "$DEV/mainonly-wt3" -b feat3
git -C "$DEV/mainonly-wt3" rm -q --cached memory/backlog.md && git -C "$DEV/mainonly-wt3" commit -qm untrack
printf '| B-1 | one, edited |\n' > "$DEV/mainonly-wt3/memory/backlog.md"
cp "$DEV/mainonly-wt3/memory/backlog.md" "$T/mainonly-wt3.md"
run
check "a copy holding only an edit is kept and named for the hand merge" \
  'cmp -s "$T/mainonly-wt3.md" "$DEV/mainonly-wt3/memory/backlog.md" && has_line "  HAND MERGE: mainonly-wt3/memory/backlog.md: +0 lines mainonly/memory/backlog.md lacks; edited: B-1"'

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
## Merged from worktree notes
MD
cp "$DEV/plain-wt/memory/backlog.md" "$T/wt-content.md"
plain_main_before="$(sha "$DEV/plain/memory/backlog.md")"
run
main="$DEV/plain/memory/backlog.md"
check "report: +8 unique" 'has_line "  plain-wt/memory/backlog.md: +8 unique -> plain/memory/backlog.md"'
check "new row B-13 appended once" '[ "$(count "$main" "| B-13 |")" = 1 ]'
check "new sized entry B-17 appended once" '[ "$(count "$main" "B-17")" = 1 ]'
check "new numbered entry B-21 appended once" '[ "$(count "$main" "B-21")" = 1 ]'
check "indented body line appended (not keyed as B-31)" '[ "$(count "$main" "in another body line")" = 1 ]'
check "new headings appended once" '[ "$(count "$main" "## A new section")" = 1 ] && [ "$(count "$main" "# A new top-level section")" = 1 ]'
check "free-text line appended once" '[ "$(count "$main" "a free-text note")" = 1 ]'
check "edited B-12/B-14/B-15/B-18/B-19/B-20 not duplicated" \
  '(for id in B-12 B-14 B-15 B-18 B-19 B-20; do [ "$(count "$main" "$id")" = 1 ] || exit 1; done)'
check "table header not duplicated" '[ "$(count "$main" "| ID | Title |")" = 1 ]'
check "a copied \"## Merged from\" heading not appended" '[ "$(count "$main" "Merged from worktree other")" = 0 ]'
check "a user heading that only starts like it is content" '[ "$(count "$main" "## Merged from worktree notes")" = 1 ]'
check "backup of main holds its pre-merge bytes" \
  '[ "$(bak_count "$DEV/plain/memory")" = 1 ] && [ "$(sha "$DEV/plain/memory/"backlog.md.bak-*)" = "$plain_main_before" ]'
# A status word, a ticked box, a rewrite: the same entry (not appended) but an edit all the same —
# the stub would erase it, so the worktree copy stays and the report names each.
check "worktree copy holding the edits kept" 'cmp -s "$T/wt-content.md" "$DEV/plain-wt/memory/backlog.md"'
check "report names the edited entries" 'has_line "  EDITED: plain-wt/memory/backlog.md: B-14, B-15, B-20, B-18, B-19"'

# ── 5. a worktree with nothing new or edited is stubbed; re-runs change nothing ────────────────────
echo "5. stub and re-run"
main_before="$(sha "$main")"
baks_before="$(bak_count "$DEV/plain/memory")"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt2" -b feat2
mkdir -p "$DEV/plain-wt2/memory" && cp "$main" "$DEV/plain-wt2/memory/backlog.md"
run
check "worktree with main's entries: +0 unique" 'has_line "  plain-wt2/memory/backlog.md: +0 unique -> plain/memory/backlog.md"'
check "that worktree copy stubbed" 'grep -q "MOVED — canonical" "$DEV/plain-wt2/memory/backlog.md"'
check "edited worktree: +0 on re-run" 'has_line "  plain-wt/memory/backlog.md: +0 unique -> plain/memory/backlog.md"'
check "main byte-identical after re-run" '[ "$(sha "$main")" = "$main_before" ]'
run
check "third run: main still byte-identical, no new backup" \
  '[ "$(sha "$main")" = "$main_before" ] && [ "$(bak_count "$DEV/plain/memory")" = "$baks_before" ]'

# ── 6. jsonl: a record edited in the worktree is kept, not stubbed away ─────────────────────────────
echo "6. jsonl records"
mkdir -p "$DEV/plain/knowledge" "$DEV/plain-wt2/knowledge"
printf '{"id":"k1","t":"a"}\n' > "$DEV/plain/knowledge/facts.jsonl"
printf '{"t":"a","id":"k1"}\n{"id":"k2","t":"b"}\n' > "$DEV/plain-wt2/knowledge/facts.jsonl"
run
check "new record k2 appended, k1 (same record, keys reordered) not" \
  '[ "$(count "$DEV/plain/knowledge/facts.jsonl" "k2")" = 1 ] && [ "$(count "$DEV/plain/knowledge/facts.jsonl" "k1")" = 1 ]'
check "unchanged jsonl copy stubbed" 'grep -q "MOVED — canonical" "$DEV/plain-wt2/knowledge/facts.jsonl"'
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt3" -b feat3
mkdir -p "$DEV/plain-wt3/knowledge"
printf '{"id":"k1","t":"rewritten"}\n' > "$DEV/plain-wt3/knowledge/facts.jsonl"
run
check "edited record not appended" '! grep -q rewritten "$DEV/plain/knowledge/facts.jsonl"'
check "jsonl copy holding the edit kept" 'grep -q rewritten "$DEV/plain-wt3/knowledge/facts.jsonl"'
check "report names the edited record" "has_line '  EDITED: plain-wt3/knowledge/facts.jsonl: \"k1\"'"

# ── 7. bytes that are not UTF-8 reach main unchanged ────────────────────────────────────────────────
echo "7. non-UTF-8 bytes"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt4" -b feat4
mkdir -p "$DEV/plain-wt4/memory"
printf '| B-50 | caf\351 \342\200\224 latin-1 and utf-8 |\n' > "$DEV/plain-wt4/memory/backlog.md"
pre7="$(sha "$main")"
LC_ALL=C run
holds_backup() { for b in "$DEV/plain/memory/"backlog.md.bak-*; do [ "$(sha "$b")" = "$1" ] && return 0; done; return 1; }
check "a second append the same day keeps its own backup of main, and the day's first one too" \
  'holds_backup "$pre7" && holds_backup "$plain_main_before"'
check "latin-1 byte and utf-8 dash appended byte-exact" \
  'python3 -c "import sys; sys.exit(b\"caf\\xe9 \\xe2\\x80\\x94 latin-1\" not in open(sys.argv[1],\"rb\").read())" "$main"'

# ── 8. --dry-run writes nothing ─────────────────────────────────────────────────────────────────────
echo "8. --dry-run"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt5" -b feat5
mkdir -p "$DEV/plain-wt5/memory"
printf '| B-40 | new |\n' > "$DEV/plain-wt5/memory/backlog.md"
main_before="$(sha "$main")"
wt5_before="$(sha "$DEV/plain-wt5/memory/backlog.md")"
baks_dry_before="$(bak_count "$DEV/plain/memory")"
run --dry-run
check "dry-run reports +1" 'has_line "  plain-wt5/memory/backlog.md: +1 unique -> plain/memory/backlog.md"'
check "dry-run leaves main untouched, no backup" \
  '[ "$(sha "$main")" = "$main_before" ] && [ "$(bak_count "$DEV/plain/memory")" = "$baks_dry_before" ]'
check "dry-run leaves worktree untouched" '[ "$(sha "$DEV/plain-wt5/memory/backlog.md")" = "$wt5_before" ]'

# ── 9. a file name with glob characters is looked up literally ─────────────────────────────────────
echo "9. literal lookup"
# As a pathspec, knowledge/f*.jsonl matches the tracked knowledge/facts.jsonl: read as "tracked", the
# untracked copy would be left behind instead of merged.
printf '{"id":"g1"}\n' > "$DEV/tracked-wt/knowledge/f*.jsonl"
facts_before="$(sha "$DEV/tracked/knowledge/facts.jsonl")"
run
check "untracked f*.jsonl merged, not reported TRACKED" \
  'has_line "  tracked-wt/knowledge/f*.jsonl: +1 unique -> tracked/knowledge/f*.jsonl"'
check "the record landed in f*.jsonl, facts.jsonl untouched" \
  'grep -q g1 "$DEV/tracked/knowledge/f*.jsonl" && [ "$(sha "$DEV/tracked/knowledge/facts.jsonl")" = "$facts_before" ]'

# ── 10. a symlinked copy is someone's canonical file: never written through ────────────────────────
echo "10. symlinked worktree copies"
init_repo link 'memory/
'
mkdir -p "$DEV/link/memory" "$T/shared"
printf '| B-1 | shared |\n' > "$T/shared/backlog.md"
ln -s "$T/shared/backlog.md" "$DEV/link/memory/backlog.md"
git -C "$DEV/link" worktree add -q "$DEV/link-wt" -b feat
mkdir -p "$DEV/link-wt/memory" && ln -s "$T/shared/backlog.md" "$DEV/link-wt/memory/backlog.md"
git -C "$DEV/link" worktree add -q "$DEV/link-wt2" -b feat2
ln -s "$DEV/link/memory" "$DEV/link-wt2/memory"
git -C "$DEV/link" worktree add -q "$DEV/link-wt3" -b feat3
mkdir -p "$DEV/link-wt3/memory" && ln -s "$T/no-such-file.md" "$DEV/link-wt3/memory/backlog.md"
git -C "$DEV/link" worktree add -q "$DEV/link-wt4" -b feat4
mkdir -p "$T/elsewhere" && printf '| B-1 | another file |\n' > "$T/elsewhere/backlog.md"
ln -s "$T/elsewhere" "$DEV/link-wt4/memory"
elsewhere_before="$(sha "$T/elsewhere/backlog.md")"
shared_before="$(sha "$T/shared/backlog.md")"
run
check "shared canonical file not overwritten by a stub" '[ "$(sha "$T/shared/backlog.md")" = "$shared_before" ]'
check "the worktree links are still links" '[ -L "$DEV/link-wt/memory/backlog.md" ] && [ -L "$DEV/link-wt2/memory" ]'
check "a memory/ linked to another directory is not written there" \
  '[ "$(sha "$T/elsewhere/backlog.md")" = "$elsewhere_before" ] && has_line "  SYMLINK: link-wt4/memory/backlog.md"'
check "report names every symlinked copy, a dangling one too" \
  'has_line "  SYMLINK: link-wt/memory/backlog.md" && has_line "  SYMLINK: link-wt2/memory/backlog.md" && has_line "  SYMLINK: link-wt3/memory/backlog.md"'
# Main's copy linked to a worktree's own file: both names are one file, and a stub would erase it.
init_repo back 'memory/
'
git -C "$DEV/back" worktree add -q "$DEV/back-wt" -b feat
mkdir -p "$DEV/back/memory" "$DEV/back-wt/memory"
printf '| B-1 | lives in the worktree |\n' > "$DEV/back-wt/memory/backlog.md"
ln -s "$DEV/back-wt/memory/backlog.md" "$DEV/back/memory/backlog.md"
back_before="$(sha "$DEV/back-wt/memory/backlog.md")"
run
check "a worktree file main links to is not stubbed" \
  '[ "$(sha "$DEV/back-wt/memory/backlog.md")" = "$back_before" ] && has_line "  SYMLINK: back-wt/memory/backlog.md"'

# ── 11. a '## B-id' heading entry edited in a worktree is the same entry ───────────────────────────
echo "11. heading entries"
init_repo head 'memory/
'
git -C "$DEV/head" worktree add -q "$DEV/head-wt" -b feat
mkdir -p "$DEV/head/memory" "$DEV/head-wt/memory"
printf '# Backlog\n\n## B-hd-one\n\nbody of one\n' > "$DEV/head/memory/backlog.md"
printf '# Backlog\n\n## B-hd-one — DONE\n\nbody of one\n\n## B-hd-two\n' > "$DEV/head-wt/memory/backlog.md"
cp "$DEV/head-wt/memory/backlog.md" "$T/head-wt.md"
run
check "closed heading entry not appended again" '[ "$(count "$DEV/head/memory/backlog.md" "B-hd-one")" = 1 ]'
check "new heading entry appended" '[ "$(count "$DEV/head/memory/backlog.md" "## B-hd-two")" = 1 ]'
check "worktree holding the closure kept, reported EDITED" \
  'cmp -s "$T/head-wt.md" "$DEV/head-wt/memory/backlog.md" && has_line "  EDITED: head-wt/memory/backlog.md: B-hd-one"'

# ── 12. a new entry keeps body lines that repeat a line main already has ───────────────────────────
echo "12. repeated body lines"
init_repo body 'memory/
'
git -C "$DEV/body" worktree add -q "$DEV/body-wt" -b feat
mkdir -p "$DEV/body/memory" "$DEV/body-wt/memory"
printf -- '- [ ] B-old first\n**Severity:** low\n**Fix:** old fix\n' > "$DEV/body/memory/backlog.md"
printf -- '- [ ] B-old first\n**Severity:** low\n**Fix:** old fix\n- [ ] B-new second\n**Severity:** low\n**Fix:** new fix\n' \
  > "$DEV/body-wt/memory/backlog.md"
run
check "the new entry arrives whole, in order" \
  'python3 -c "import sys; sys.exit(b\"B-new second\n**Severity:** low\n**Fix:** new fix\n\" not in open(sys.argv[1],\"rb\").read())" "$DEV/body/memory/backlog.md"'
body_before="$(sha "$DEV/body/memory/backlog.md")"
git -C "$DEV/body" worktree add -q "$DEV/body-wt2" -b feat2
mkdir -p "$DEV/body-wt2/memory" && cp "$DEV/body/memory/backlog.md" "$DEV/body-wt2/memory/backlog.md"
run
check "a copy of main adds nothing (repeats are counted, not re-added)" \
  '[ "$(sha "$DEV/body/memory/backlog.md")" = "$body_before" ] && has_line "  body-wt2/memory/backlog.md: +0 unique -> body/memory/backlog.md"'

# A new entry whose body repeats a line main holds elsewhere, in a worktree that lacks main's copy of it.
git -C "$DEV/body" worktree add -q "$DEV/body-wt4" -b feat4
mkdir -p "$DEV/body-wt4/memory"
printf -- '- [ ] B-fork entry from an old fork\n**Severity:** low\n' > "$DEV/body-wt4/memory/backlog.md"
run
check "a new entry's body line arrives although main holds that text elsewhere" \
  'python3 -c "import sys; sys.exit(b\"B-fork entry from an old fork\n**Severity:** low\n\" not in open(sys.argv[1],\"rb\").read())" "$DEV/body/memory/backlog.md"'

# An indented table row naming a known ID inside a new entry does not end that entry's body.
git -C "$DEV/body" worktree add -q "$DEV/body-wt7" -b feat7
mkdir -p "$DEV/body-wt7/memory"
printf -- '- [ ] B-tab entry with a table\n  | B-old | see above |\n**Fix:** old fix\n' > "$DEV/body-wt7/memory/backlog.md"
run
check "a new entry arrives whole, its indented row with a known ID included" \
  'python3 -c "import sys; sys.exit(b\"B-tab entry with a table\n  | B-old | see above |\n**Fix:** old fix\n\" not in open(sys.argv[1],\"rb\").read())" "$DEV/body/memory/backlog.md" && grep -q "MOVED — canonical" "$DEV/body-wt7/memory/backlog.md"'

# A new item without an ID keeps its sub-bullets, though main holds that text under another entry.
git -C "$DEV/body" worktree add -q "$DEV/body-wt9" -b feat9
mkdir -p "$DEV/body-wt9/memory"
printf -- '- [ ] tidy docs\n  **Fix:** old fix\n' > "$DEV/body-wt9/memory/backlog.md"
run
check "an ID-less new item's indented body arrives with it" \
  'python3 -c "import sys; sys.exit(b\"- [ ] tidy docs\n  **Fix:** old fix\n\" not in open(sys.argv[1],\"rb\").read())" "$DEV/body/memory/backlog.md"'

# Lines written below an existing stub are merged, and the stub is rewritten clean.
git -C "$DEV/body" worktree add -q "$DEV/body-wt8" -b feat8
mkdir -p "$DEV/body-wt8/memory"
{ printf '# MOVED — canonical copy lives in the MAIN checkout\n\nCanonical: x\n'
  printf 'One state file per repository (zuvo backlog-protocol, worktree rule). Do not write here.\n'
  printf -- '- [ ] B-77 written after the stub\nCanonical: a user note that only starts like the stub\n'; } > "$DEV/body-wt8/memory/backlog.md"
run
check "lines written below a stub reach main, the stub's own lines do not" \
  '[ "$(count "$DEV/body/memory/backlog.md" "B-77 written after the stub")" = 1 ] && [ "$(count "$DEV/body/memory/backlog.md" "a user note that only starts like the stub")" = 1 ] && [ "$(count "$DEV/body/memory/backlog.md" "Canonical: x")" = 0 ]'
check "the worktree copy is a clean stub again" \
  'grep -q "MOVED — canonical" "$DEV/body-wt8/memory/backlog.md" && [ "$(count "$DEV/body-wt8/memory/backlog.md" "B-77")" = 0 ]'

# A body line added under an existing entry, its text held once by main and twice by the worktree.
git -C "$DEV/body" worktree add -q "$DEV/body-wt10" -b feat10
mkdir -p "$DEV/body-wt10/memory"
cp "$DEV/body/memory/backlog.md" "$DEV/body-wt10/memory/backlog.md"
printf '%s\n' "- [ ] B-tidy-late existing entry" >> "$DEV/body/memory/backlog.md"
printf '%s\n' "- [ ] B-tidy-late existing entry" "**Severity:** extra copy" >> "$DEV/body-wt10/memory/backlog.md"
printf '%s\n' "**Severity:** extra copy" >> "$DEV/body/memory/backlog.md"
printf '%s\n' "**Severity:** extra copy" >> "$DEV/body-wt10/memory/backlog.md"
run
check "the worktree's extra copy of a repeated line reaches main" \
  '[ "$(count "$DEV/body/memory/backlog.md" "**Severity:** extra copy")" = 2 ]'

# A stub an editor saved with a byte-order mark is still a stub, not new content.
git -C "$DEV/body" worktree add -q "$DEV/body-wt5" -b feat5
mkdir -p "$DEV/body-wt5/memory"
printf '\357\273\277# MOVED — canonical copy lives in the MAIN checkout\n\nCanonical: x\n' > "$DEV/body-wt5/memory/backlog.md"
body_before="$(sha "$DEV/body/memory/backlog.md")"
run
check "a BOM-prefixed stub is skipped" '[ "$(sha "$DEV/body/memory/backlog.md")" = "$body_before" ]'

# A note written above a stub is merged; the stub's own lines below it are not.
git -C "$DEV/body" worktree add -q "$DEV/body-wt11" -b feat11
mkdir -p "$DEV/body-wt11/memory"
{ printf -- '- [ ] B-78 written above the stub\n# MOVED — canonical copy lives in the MAIN checkout\n\nCanonical: x\n'
  printf 'One state file per repository (zuvo backlog-protocol, worktree rule). Do not write here.\n'; } > "$DEV/body-wt11/memory/backlog.md"
run
check "a note above a stub reaches main, the stub's lines do not" \
  '[ "$(count "$DEV/body/memory/backlog.md" "B-78 written above the stub")" = 1 ] && [ "$(count "$DEV/body/memory/backlog.md" "MOVED")" = 0 ] && [ "$(count "$DEV/body/memory/backlog.md" "Canonical: x")" = 0 ]'

# ── 13. a main jsonl without a final newline stays one record per line ─────────────────────────────
echo "13. unterminated jsonl"
mkdir -p "$DEV/body/knowledge"
git -C "$DEV/body" worktree add -q "$DEV/body-wt3" -b feat3
mkdir -p "$DEV/body-wt3/knowledge"
printf '{"id":"k1","t":"a"}' > "$DEV/body/knowledge/f.jsonl"
printf '{"id":"k1","t":"a"}\n{"id":"k2","t":"b"}\n' > "$DEV/body-wt3/knowledge/f.jsonl"
run
check "main parses as jsonl and holds k1 and k2" \
  'python3 -c "import json,sys; ids=[json.loads(l)[\"id\"] for l in open(sys.argv[1]) if l.strip()]; sys.exit(ids != [\"k1\",\"k2\"])" "$DEV/body/knowledge/f.jsonl"'

# A pathologically nested line is kept as an opaque line, not a crash that aborts the whole run.
git -C "$DEV/body" worktree add -q "$DEV/body-wt6" -b feat6
mkdir -p "$DEV/body-wt6/knowledge"
python3 -c 'print("[" * 100000 + "]" * 100000); print("{\"id\": \"k9\"}")' > "$DEV/body-wt6/knowledge/deep.jsonl"
run
check "a deeply nested jsonl line does not abort the run" \
  '[ "$rc" = 0 ] && grep -q "k9" "$DEV/body/knowledge/deep.jsonl" && has_line "  body-wt6/knowledge/deep.jsonl: +2 unique -> body/knowledge/deep.jsonl"'

# ── 14. an id ends before sentence punctuation ────────────────────────────────────────────────────
echo "14. trailing dot"
init_repo dot 'memory/
'
git -C "$DEV/dot" worktree add -q "$DEV/dot-wt" -b feat
mkdir -p "$DEV/dot/memory" "$DEV/dot-wt/memory"
printf -- '- [ ] B-12. first title\n' > "$DEV/dot/memory/backlog.md"
printf -- '- [ ] B-12 first title, rewritten\n' > "$DEV/dot-wt/memory/backlog.md"
git -C "$DEV/dot" worktree add -q "$DEV/dot-wtd" -b featd
mkdir -p "$DEV/dot-wtd/memory" && printf -- '- [ ] B-12- first title, dashed\n' > "$DEV/dot-wtd/memory/backlog.md"
dot_before="$(sha "$DEV/dot/memory/backlog.md")"
run
check "B-12., B-12- and B-12 are one entry: reported EDITED, not appended" \
  '[ "$(sha "$DEV/dot/memory/backlog.md")" = "$dot_before" ] && has_line "  EDITED: dot-wt/memory/backlog.md: B-12" && has_line "  EDITED: dot-wtd/memory/backlog.md: B-12"'

# ── 14b. indentation is content; padding inside a line is not ──────────────────────────────────────
echo "14b. indentation"
git -C "$DEV/dot" worktree add -q "$DEV/dot-wt2" -b feat2
git -C "$DEV/dot" worktree add -q "$DEV/dot-wt3" -b feat3
mkdir -p "$DEV/dot-wt2/memory" "$DEV/dot-wt3/memory"
printf -- '- [ ] B-12. first title\n    if x:\n        run()\n' > "$DEV/dot/memory/backlog.md"
printf -- '- [ ] B-12. first title\n    if x:\n    run()\n' > "$DEV/dot-wt2/memory/backlog.md"
printf -- '- [ ] B-12.   first   title\n    if  x:\n        run()\n' > "$DEV/dot-wt3/memory/backlog.md"
cp "$DEV/dot-wt2/memory/backlog.md" "$T/dot-wt2.md"
dot_before="$(sha "$DEV/dot/memory/backlog.md")"
run
check "a re-indented body line keeps its worktree copy, reported EDITED" \
  'cmp -s "$T/dot-wt2.md" "$DEV/dot-wt2/memory/backlog.md" && printf "%s\n" "$out" | grep -q "^  EDITED: dot-wt2/memory/backlog.md: line"'
check "re-padding inside lines is no edit: that copy is stubbed, main unchanged" \
  'grep -q "MOVED — canonical" "$DEV/dot-wt3/memory/backlog.md" && [ "$(sha "$DEV/dot/memory/backlog.md")" = "$dot_before" ]'

# A byte-order mark does not hide the first line's ID.
git -C "$DEV/dot" worktree add -q "$DEV/dot-wt4" -b feat4
mkdir -p "$DEV/dot-wt4/memory"
printf '\357\273\277- [x] B-12. first title\n' > "$DEV/dot-wt4/memory/backlog.md"
run
check "a BOM-led copy ticking B-12 is EDITED, not a second B-12" \
  '[ "$(sha "$DEV/dot/memory/backlog.md")" = "$dot_before" ] && has_line "  EDITED: dot-wt4/memory/backlog.md: B-12"'

# A byte-order mark on main's copy does not hide its first line's ID either.
init_repo bom 'memory/
'
git -C "$DEV/bom" worktree add -q "$DEV/bom-wt" -b feat
mkdir -p "$DEV/bom/memory" "$DEV/bom-wt/memory"
printf '\357\273\277- [ ] B-5 first entry\n' > "$DEV/bom/memory/backlog.md"
printf -- '- [x] B-5 first entry\n' > "$DEV/bom-wt/memory/backlog.md"
bom_before="$(sha "$DEV/bom/memory/backlog.md")"
run
check "ticking B-5 of a BOM-led main is EDITED, not a second B-5" \
  '[ "$(sha "$DEV/bom/memory/backlog.md")" = "$bom_before" ] && has_line "  EDITED: bom-wt/memory/backlog.md: B-5"'

# ── 14c. a checkbox ticked on a '+' or '*' list item is an edit, not a new line ─────────────────────
echo "14c. other list markers"
init_repo plus 'memory/
'
git -C "$DEV/plus" worktree add -q "$DEV/plus-wt" -b feat
mkdir -p "$DEV/plus/memory" "$DEV/plus-wt/memory"
printf -- '+ [ ] plus task\n* [ ] star task\n1. [ ] numbered task\n' > "$DEV/plus/memory/backlog.md"
printf -- '+ [x] plus task\n* [x] star task\n1. [x] numbered task\n' > "$DEV/plus-wt/memory/backlog.md"
plus_before="$(sha "$DEV/plus/memory/backlog.md")"
run
check "ticked '+'/'*'/numbered items reported EDITED, main unchanged" \
  '[ "$(sha "$DEV/plus/memory/backlog.md")" = "$plus_before" ] && printf "%s\n" "$out" | grep -qF "  EDITED: plus-wt/memory/backlog.md: line '"'"'+ [x] plus task'"'"', line '"'"'* [x] star task'"'"', line '"'"'1. [x] numbered task'"'"'"'

# ── 15. an unknown argument is refused before anything is written ─────────────────────────────────
echo "15. unknown argument"
git -C "$DEV/plain" worktree add -q "$DEV/plain-wt6" -b feat6
mkdir -p "$DEV/plain-wt6/memory" && printf '| B-60 | pending |\n' > "$DEV/plain-wt6/memory/backlog.md"
wt6_before="$(sha "$DEV/plain-wt6/memory/backlog.md")"
main_before="$(sha "$main")"
baks_before="$(bak_count "$DEV/plain/memory")"
run_rc --dryrun
check "a misspelt --dry-run exits 2 with usage and writes nothing" \
  '[ "$rc" = 2 ] && printf "%s\n" "$out" | grep -q "^usage:" && [ "$(sha "$main")" = "$main_before" ] && [ "$(sha "$DEV/plain-wt6/memory/backlog.md")" = "$wt6_before" ] && [ "$(bak_count "$DEV/plain/memory")" = "$baks_before" ]'

# ── 16. a failed git lookup fails closed: nothing written, nothing stubbed ─────────────────────────
echo "16. git failure"
mkdir -p "$T/shim"
printf '#!/bin/sh\ncase " $* " in *" ls-files "*) exit 128;; esac\nexec "%s" "$@"\n' "$(command -v git)" > "$T/shim/git"
chmod +x "$T/shim/git"
PATH="$T/shim:$PATH" run_rc
check "exit 1 and the pending copy reported FAILED" \
  '[ "$rc" = 1 ] && printf "%s\n" "$out" | grep -q "^  FAILED: plain-wt6/memory/backlog.md: git ls-files failed"'
check "pending copy neither merged nor stubbed" \
  '[ "$(sha "$main")" = "$main_before" ] && [ "$(sha "$DEV/plain-wt6/memory/backlog.md")" = "$wt6_before" ]'

# Without git nothing can be told apart, so the run fails loudly instead of skipping every repo.
mkdir -p "$T/nogit" && ln -s "$(command -v python3)" "$T/nogit/python3"
PATH="$T/nogit" run_rc
check "no git: exit 1, each repo FAILED, pending copy untouched" \
  '[ "$rc" = 1 ] && [ "$(printf "%s\n" "$out" | grep -c "^  FAILED: .*/git worktree list: ")" = "$(find "$DEV" -mindepth 2 -maxdepth 2 -name .git | wc -l | tr -d " ")" ] && has_line "  FAILED: plain-wt6/git worktree list: git worktree list failed in $DEV/plain-wt6" && [ "$(sha "$DEV/plain-wt6/memory/backlog.md")" = "$wt6_before" ]'

# ── a main checkout outside HOME is not consolidated, even one whose path starts with HOME's ───────
echo "main outside HOME"
# `$T/home2` starts with the string `$T/home` but is not inside it: a string-prefix test let a
# worktree of a repo living there write into it.
git init -q -b main "$T/home2/outside"
printf 'memory/\n' > "$T/home2/outside/.gitignore"
git -C "$T/home2/outside" add .gitignore && git -C "$T/home2/outside" commit -qm init
git -C "$T/home2/outside" worktree add -q "$DEV/outside-wt" -b feat
mkdir -p "$T/home2/outside/memory" "$DEV/outside-wt/memory"
printf '| B-1 | one |\n' > "$T/home2/outside/memory/backlog.md"
printf '| B-1 | one |\n| B-2 | two |\n' > "$DEV/outside-wt/memory/backlog.md"
outside_before="$(sha "$T/home2/outside/memory/backlog.md")"
run
check "main checkout in a sibling of HOME left untouched" \
  '[ "$(sha "$T/home2/outside/memory/backlog.md")" = "$outside_before" ] && ! printf "%s\n" "$out" | grep -q "outside-wt/"'

echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
