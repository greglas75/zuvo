#!/usr/bin/env bash
# scripts/install.d/retire_review_queue.py — the cleanup of the retired review queue, run for real
# against throwaway HOMEs and throwaway git repositories.
#
# The files it deletes are not described here by hand: each fixture runs the RETIRED generator itself
# (tests/fixtures/review-queue/post-commit-review-backlog.sh, byte-identical to the script that was
# shipped until 2026-10-05) after a real commit, so "the generated format" is whatever that script
# wrote, not whatever the cleanup's own patterns accept. The same file is also "the copy zuvo installed".
#
# Test level: MEDIUM — real git repositories, real files and a real tar archive under $TMP; no network,
# nothing outside the temp dir (global and system git config are isolated, so no real hook runs).
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RETIRE="$ROOT/scripts/install.d/retire_review_queue.py"
GEN="$ROOT/tests/fixtures/review-queue/post-commit-review-backlog.sh"
fail=0; npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
skip() { printf 'SKIP: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }

TMP="$(mktemp -d)" && [ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }
TMP="$(cd "$TMP" && pwd -P)" && [ -n "$TMP" ] || { echo "FAIL: cannot resolve the temp dir"; exit 1; }   # physical: the cleanup prints git's resolved paths
trap 'chmod -R u+w "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"
[ -f "$GEN" ] || { echo "FAIL: the retired generator fixture is missing: $GEN"; exit 1; }

# repo <home> <path> — a git repository with docs/ and one commit, on which the retired generator has
# run with HOME=<home>: it leaves <path>/docs/review-queue.md (untracked) and the memory backlog.
repo() {
  mkdir -p "$2/docs" && git -C "$2" init -q && echo x > "$2/f" && git -C "$2" add f \
    && git -C "$2" -c user.name=t -c user.email=t@example.invalid commit -qm 'feat: first change' \
    && (cd "$2" && HOME="$1" bash "$GEN") && [ -f "$2/docs/review-queue.md" ] \
    || { echo "FAIL: fixture: the retired generator did not run in $2"; exit 1; }
}
# backlog_of <home> <repo> — the memory backlog the generator wrote for <repo> (its own path encoding).
backlog_of() { printf '%s/.claude/projects/%s/memory/review-backlog.md' "$1" "$(git -C "$2" rev-parse --show-toplevel | tr '/' '-')"; }
retire() { LANG=C LC_ALL=C python3 "$RETIRE" "$@" > "$TMP/out" 2>&1; }
archives() { find "$1/.zuvo/archive" -name 'review-queue-retired-*.tar.gz' 2>/dev/null | wc -l | tr -d ' '; }
tree_sum() { (cd "$1" && find . -path ./.zuvo -prune -o -print | LC_ALL=C sort | while IFS= read -r p; do
  if [ -f "$p" ] && [ ! -L "$p" ]; then printf '%s %s\n' "$p" "$(cksum < "$p")"; else printf '%s\n' "$p"; fi; done) | cksum; }

# --- fixture "main": everything the script left, plus each kind of file the cleanup must keep ---
F="$TMP/main"; H="$F/home"; R="$F/repos"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks" "$R"
cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/bash' 'set +e' 'bash "$HOME/.claude/scripts/post-commit-review-backlog.sh" 2>/dev/null' \
  'PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"' 'echo chained' > "$H/.claude/hooks/post-commit"
chmod 750 "$H/.claude/hooks/post-commit"; cp "$H/.claude/hooks/post-commit" "$F/dispatcher.before"
printf '%s\n' '#!/bin/bash' 'set +e' 'PROJECT_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"' 'echo chained' \
  > "$F/dispatcher.want"                                     # the same file without the one call line
repo "$H" "$R/my-repo"                                       # '-' inside a component: the decode must find it
repo "$H" "$R/tracked"; git -C "$R/tracked" add docs/review-queue.md \
  && git -C "$R/tracked" -c user.name=t -c user.email=t@example.invalid commit -qm 'docs: queue'
repo "$H" "$R/edited"; printf '\nmy own note\n' >> "$R/edited/docs/review-queue.md"
repo "$H" "$R/shared-mem"; printf '# memory index\n' > "$(dirname "$(backlog_of "$H" "$R/shared-mem")")/MEMORY.md"
repo "$H" "$R/notes"; printf -- '---\nname: Review backlog\n---\nreal notes\n' > "$(backlog_of "$H" "$R/notes")"
# snap <file> — a copy under $F/before/<its absolute path>, to compare with the archive and the kept files
snap() { mkdir -p "$F/before/$(dirname "${1#/}")" && cp "$1" "$F/before/${1#/}"; }
ARCHIVED=("$H/.claude/scripts/post-commit-review-backlog.sh" "$H/.claude/hooks/post-commit")
for r in my-repo tracked edited shared-mem; do ARCHIVED+=("$(backlog_of "$H" "$R/$r")"); done
for r in my-repo shared-mem notes; do ARCHIVED+=("$R/$r/docs/review-queue.md"); done
for f in "${ARCHIVED[@]}" "$R/edited/docs/review-queue.md" "$(backlog_of "$H" "$R/notes")"; do snap "$f"; done

# (0) the fixture is what the script produced, so the cases below test the cleanup against real output
n_gen=0; for r in my-repo tracked edited shared-mem notes; do [ -f "$R/$r/docs/review-queue.md" ] && n_gen=$((n_gen + 1)); done
[ "$n_gen" -eq 5 ] && head -1 "$(backlog_of "$H" "$R/my-repo")" | grep -qx '# Review Backlog' && head -1 "$R/my-repo/docs/review-queue.md" | grep -qx '# Review Queue' \
  && pass "(0) the retired generator wrote a queue in all 5 fixture repos and the memory backlogs" \
  || bad "(0) fixture: $n_gen/5 queues written; backlog head [$(head -1 "$(backlog_of "$H" "$R/my-repo")" 2>/dev/null)]"

# (1) one run removes exactly the script's own files and keeps the rest, saying why
before_sum="$(tree_sum "$R/tracked")"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && pass "(1a) the installed script is removed (status 0)" || bad "(1a) status $rc, script $([ -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] && echo STILL THERE || echo gone) [$(head -3 "$TMP/out" | tr '\n' '|')]"
mode="$(stat -c %a "$H/.claude/hooks/post-commit" 2>/dev/null || stat -f %Lp "$H/.claude/hooks/post-commit")"
cmp -s "$F/dispatcher.want" "$H/.claude/hooks/post-commit" && [ "$mode" = 750 ] \
  && pass "(1b) ~/.claude/hooks/post-commit loses only the call line; the rest and mode 750 are kept" \
  || bad "(1b) dispatcher mode $mode: $(diff "$F/dispatcher.want" "$H/.claude/hooks/post-commit" | head -4 | tr '\n' '|')"
[ ! -e "$R/my-repo/docs/review-queue.md" ] && [ ! -e "$R/shared-mem/docs/review-queue.md" ] \
  && [ ! -e "$R/notes/docs/review-queue.md" ] \
  && pass "(1c) untracked generated queues are removed — in a repo whose name holds a '-', and where the memory file is kept" \
  || bad "(1c) queues left: $(ls "$R"/{my-repo,shared-mem,notes}/docs/review-queue.md 2>/dev/null | tr '\n' ' ')"
[ "$(tree_sum "$R/tracked")" = "$before_sum" ] && grep -qF "kept $R/tracked/docs/review-queue.md — tracked in git" "$TMP/out" \
  && pass "(1d) a queue tracked by git is kept and named as tracked" || bad "(1d) tracked queue: [$(grep tracked "$TMP/out" | head -2)]"
cmp -s "$F/before/${R#/}/edited/docs/review-queue.md" "$R/edited/docs/review-queue.md" \
  && grep -qF "kept $R/edited/docs/review-queue.md — not the generated format" "$TMP/out" \
  && pass "(1e) a queue someone added to by hand is kept and named" || bad "(1e) edited queue: [$(grep edited "$TMP/out" | head -2)]"
cmp -s "$F/before/$(backlog_of "$H" "$R/notes" | sed 's#^/##')" "$(backlog_of "$H" "$R/notes")" \
  && grep -qF "kept $(backlog_of "$H" "$R/notes") — not the generated format" "$TMP/out" \
  && pass "(1f) a memory file with real notes under the same name is kept and named" || bad "(1f) notes backlog: [$(grep notes "$TMP/out" | head -2)]"
mem_my="$(dirname "$(backlog_of "$H" "$R/my-repo")")"; mem_sh="$(dirname "$(backlog_of "$H" "$R/shared-mem")")"
[ ! -e "$mem_my" ] && [ -f "$mem_sh/MEMORY.md" ] && [ ! -e "$mem_sh/review-backlog.md" ] \
  && pass "(1g) a memory dir the script alone filled is removed; one holding other memories keeps them" \
  || bad "(1g) memory dirs: my-repo $([ -e "$mem_my" ] && echo LEFT || echo gone), shared [$(ls "$mem_sh" 2>/dev/null | tr '\n' ' ')]"
! grep -q 'still runs the retired' "$TMP/out" \
  && pass "(1h) no repository hook calls the script here, and none is reported" \
  || bad "(1h) a hook was reported: [$(grep 'still runs' "$TMP/out" | head -2 | tr '\n' '|')]"
# the archive: one file, every removed file plus the dispatcher as it was, contents intact
A="$(find "$H/.zuvo/archive" -name 'review-queue-retired-*.tar.gz' 2>/dev/null)"
X="$F/unpacked"; mkdir -p "$X"; [ -n "$A" ] && tar -xzf "$A" -C "$X" 2>/dev/null
n_members="$( [ -n "$A" ] && tar -tzf "$A" | wc -l | tr -d ' ')"
# the script; the 4 generated backlogs (all but notes'); the 3 untracked generated queues (all but tracked's
# and edited's); the dispatcher as it was
want_members=$((1 + 4 + 3 + 1))
same=0; for f in "${ARCHIVED[@]}"; do cmp -s "$F/before/${f#/}" "$X/${f#/}" 2>/dev/null && same=$((same + 1)); done
[ "$(archives "$H")" = 1 ] && [ "$n_members" = "$want_members" ] && [ "$same" = "$want_members" ] \
  && cmp -s "$F/dispatcher.before" "$X/${H#/}/.claude/hooks/post-commit" 2>/dev/null \
  && pass "(1i) one archive holds all $want_members originals byte for byte, the dispatcher as it was" \
  || bad "(1i) archives $(archives "$H"), members $n_members/$want_members, identical $same [$(tar -tzf "$A" 2>/dev/null | head -3 | tr '\n' ' ')]"
grep -qxF "  ✓ review queue retired: 4 memory backlog(s), 3 repository queue file(s), the installed script, its call in ~/.claude/hooks/post-commit — archived in $A" "$TMP/out" \
  && pass "(1j) the summary counts what was removed and names the archive" || bad "(1j) summary: [$(grep '✓' "$TMP/out")]"

# (2) a second run finds nothing to do: status 0, no new archive, the dispatcher as the first run left it.
# A kept file is named again only while a memory file still points at its repository: a kept memory file
# is; a kept queue whose generated memory file the first run removed is not.
F="$TMP/rerun"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"
cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' 'echo chained' > "$H/.claude/hooks/post-commit"
repo "$H" "$F/repos/one"; repo "$H" "$F/repos/kept"; printf 'note\n' >> "$F/repos/kept/docs/review-queue.md"
repo "$H" "$F/repos/notes"; printf 'notes\n' > "$(backlog_of "$H" "$F/repos/notes")"
retire "$H"; rc1=$?; cp "$H/.claude/hooks/post-commit" "$F/dispatcher.after1"
retire "$H"; rc=$?
[ "$rc1" -eq 0 ] && [ "$rc" -eq 0 ] && [ "$(archives "$H")" = 1 ] && ! grep -q '✓' "$TMP/out" \
  && cmp -s "$F/dispatcher.after1" "$H/.claude/hooks/post-commit" \
  && [ "$(grep -c '^  ! review queue: kept' "$TMP/out")" -eq 1 ] && grep -qF "kept $(backlog_of "$H" "$F/repos/notes")" "$TMP/out" \
  && pass "(2) a rerun is a no-op: status 0, no new archive, only the kept memory file named again" \
  || bad "(2) rerun: status $rc, archives $(archives "$H"), output [$(head -4 "$TMP/out" | tr '\n' '|')]"

# (3) --dry-run lists what it would do and changes nothing
F="$TMP/dry"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' > "$H/.claude/hooks/post-commit"
repo "$H" "$F/repos/one"
sum_h="$(tree_sum "$H")"; sum_r="$(tree_sum "$F/repos")"
retire "$H" --dry-run; rc=$?
[ "$rc" -eq 0 ] && [ "$(tree_sum "$H")" = "$sum_h" ] && [ "$(tree_sum "$F/repos")" = "$sum_r" ] && [ ! -e "$H/.zuvo" ] \
  && [ "$(grep -c '^  (dry run) would remove ' "$TMP/out")" -eq 3 ] \
  && grep -qxF "  (dry run) would drop the post-commit-review-backlog.sh call from $H/.claude/hooks/post-commit" "$TMP/out" \
  && pass "(3) --dry-run names the 3 removals and the dispatcher call, and touches nothing (no archive either)" \
  || bad "(3) dry run: status $rc, would-remove x$(grep -c 'would remove' "$TMP/out"), ~/.zuvo $([ -e "$H/.zuvo" ] && echo CREATED || echo absent)"

# (4) an archive that cannot be written stops everything: status 2, said, nothing removed
F="$TMP/noarchive"; H="$F/home"; mkdir -p "$H/.claude/scripts"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
repo "$H" "$F/repos/one"; : > "$H/.zuvo"          # a FILE where ~/.zuvo/archive must go
retire "$H"; rc=$?
[ "$rc" -eq 2 ] && grep -q '^  ! review queue: could not write the archive .* — nothing removed' "$TMP/out" \
  && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] && [ -f "$F/repos/one/docs/review-queue.md" ] \
  && [ -f "$(backlog_of "$H" "$F/repos/one")" ] \
  && pass "(4) no archive, no deletion: status 2, the reason said, all 3 files still there" \
  || bad "(4) archive failure: status $rc [$(head -2 "$TMP/out" | tr '\n' '|')]"

# (5a) symlinks are never followed into a deletion: a linked dispatcher is rewritten THROUGH the link (the
# link stays), and a linked queue is kept
F="$TMP/links"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks" "$F/dotfiles"
printf '%s\n' '#!/bin/bash' 'bash ~/.claude/scripts/post-commit-review-backlog.sh 2>/dev/null || true' 'echo chained' > "$F/dotfiles/post-commit"
ln -s ../../../dotfiles/post-commit "$H/.claude/hooks/post-commit"
repo "$H" "$F/repos/one"; mv "$F/repos/one/docs/review-queue.md" "$F/queue-target"; ln -s ../../../queue-target "$F/repos/one/docs/review-queue.md"
retire "$H"; rc=$?
printf '#!/bin/bash\necho chained\n' > "$F/want"
[ "$rc" -eq 0 ] && [ -L "$H/.claude/hooks/post-commit" ] && cmp -s "$F/want" "$F/dotfiles/post-commit" \
  && [ -L "$F/repos/one/docs/review-queue.md" ] && [ -f "$F/queue-target" ] \
  && grep -qF "kept $F/repos/one/docs/review-queue.md — a symlink" "$TMP/out" \
  && pass "(5a) symlinks: the dispatcher is edited through its link; a linked queue is kept and named" \
  || bad "(5a) symlinks: status $rc, dispatcher target [$(tr '\n' '|' < "$F/dotfiles/post-commit")] [$(grep kept "$TMP/out" | head -3 | tr '\n' '|')]"

# (5b) a linked script (a dotfile manager's, even with zuvo's content) is not the copy zuvo installed: it is
# kept, and so is the dispatcher line that runs it
F="$TMP/linkscript"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks" "$F/dotfiles"
cp "$GEN" "$F/dotfiles/gen.sh"; ln -s ../../../dotfiles/gen.sh "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' > "$H/.claude/hooks/post-commit"
cp "$H/.claude/hooks/post-commit" "$F/dispatcher.before"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -L "$H/.claude/scripts/post-commit-review-backlog.sh" ] && cmp -s "$GEN" "$F/dotfiles/gen.sh" \
  && cmp -s "$F/dispatcher.before" "$H/.claude/hooks/post-commit" \
  && grep -qF "kept $H/.claude/scripts/post-commit-review-backlog.sh — not the copy zuvo installed" "$TMP/out" \
  && pass "(5b) a symlinked script is kept with its target, and the dispatcher line that runs it stays" \
  || bad "(5b) linked script: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"

# (6) a same-named script that is not zuvo's, and a dispatcher line that only MENTIONS the script, are kept
F="$TMP/foreign"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"
printf '#!/bin/sh\necho mine\n' > "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' '[ -x ~/.claude/scripts/post-commit-review-backlog.sh ] && ~/.claude/scripts/post-commit-review-backlog.sh' > "$H/.claude/hooks/post-commit"
cp "$H/.claude/hooks/post-commit" "$F/dispatcher.before"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$H/.claude/scripts/post-commit-review-backlog.sh")" = "$(printf '#!/bin/sh\necho mine')" ] \
  && cmp -s "$F/dispatcher.before" "$H/.claude/hooks/post-commit" && [ ! -e "$H/.zuvo" ] \
  && grep -qF 'not the copy zuvo installed' "$TMP/out" && grep -qF 'names the script in a line this cleanup does not recognise' "$TMP/out" \
  && pass "(6) a foreign same-named script and an unrecognised dispatcher line are kept, both named, nothing archived" \
  || bad "(6) foreign files: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"

# (7) a queue that cannot be removed: status 1, said, and the other removals still happen
if [ "$(id -u)" = 0 ]; then
  skip "(7) not run under root (a 555 directory does not stop root)"
else
  F="$TMP/rodir"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"; repo "$H" "$F/repos/two"
  chmod 555 "$F/repos/one/docs"
  retire "$H"; rc=$?
  chmod 755 "$F/repos/one/docs"
  [ "$rc" -eq 1 ] && grep -qF "could not remove $F/repos/one/docs/review-queue.md" "$TMP/out" && [ "$(archives "$H")" = 1 ] \
    && [ -f "$F/repos/one/docs/review-queue.md" ] && [ ! -e "$F/repos/two/docs/review-queue.md" ] \
    && [ ! -e "$(backlog_of "$H" "$F/repos/one")" ] \
    && [ ! -e "$(backlog_of "$H" "$F/repos/two")" ] \
    && pass "(7) one file that cannot be removed: status 1, named, every other removal done" \
    || bad "(7) unremovable queue: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"
fi

# (8) a HOME with none of it: status 0, silent, nothing created
H="$TMP/empty/home"; mkdir -p "$H"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP/out" ] && [ -z "$(ls -A "$H")" ] \
  && pass "(8) nothing to retire: status 0, no output, nothing created under HOME" || bad "(8) empty HOME: status $rc [$(head -2 "$TMP/out")] created [$(ls -A "$H")]"

# (9) a bad call says so on one '  ! ' line, status 64, no traceback
n_ok=0
for call in none missing-home extra-arg; do
  case "$call" in
    none)         python3 "$RETIRE" > "$TMP/out" 2>&1; rc=$? ;;
    missing-home) python3 "$RETIRE" "$TMP/no-such-dir" > "$TMP/out" 2>&1; rc=$? ;;
    extra-arg)    python3 "$RETIRE" "$TMP" "$TMP" > "$TMP/out" 2>&1; rc=$? ;;
  esac
  [ "$rc" -eq 64 ] && [ "$(wc -l < "$TMP/out" | tr -d ' ')" -eq 1 ] && grep -q '^  ! retire_review_queue.py: bad arguments .* usage: retire_review_queue.py <home>' "$TMP/out" \
    && ! grep -q Traceback "$TMP/out" && n_ok=$((n_ok + 1)) || printf '  (9) %s: status %s [%s]\n' "$call" "$rc" "$(head -2 "$TMP/out" | tr '\n' '|')"
done
[ "$n_ok" -eq 3 ] && pass "(9) no home, a missing home and an extra argument: each one '  ! ' line with the usage, status 64" \
  || bad "(9) bad calls: $n_ok/3 refused as a bad call"

# (10) the races, driven through the functions themselves: a dispatcher something rewrote after it was
# read is left exactly as it is (and said), with no temp file beside it; a file a concurrent install
# already removed is not a failure.
F="$TMP/race"; mkdir -p "$F/hooks"; printf 'theirs\n' > "$F/hooks/post-commit"
race_out="$(python3 - "$RETIRE" "$F" <<'PY'
import contextlib, importlib.util, io, os, sys
spec = importlib.util.spec_from_file_location('retire', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
f = sys.argv[2]; d = os.path.join(f, 'hooks', 'post-commit')
out = io.StringIO()
with contextlib.redirect_stdout(out):
    done = m.drop_call((d, 'as read\n', 'rewritten\n'))
print('changed', done, open(d).read() == 'theirs\n', sorted(os.listdir(os.path.dirname(d))),
      'changed while it was being cleaned' in out.getvalue())
out = io.StringIO()
with contextlib.redirect_stdout(out):
    removed, n = m.remove_all([(os.path.join(f, 'already-gone.md'), lambda: None)], {})
print('gone', removed, n, repr(out.getvalue()))
PY
)"
[ "$(printf '%s\n' "$race_out" | sed -n 1p)" = "changed False True ['post-commit'] True" ] \
  && [ "$(printf '%s\n' "$race_out" | sed -n 2p)" = "gone [] 0 ''" ] \
  && pass "(10) a dispatcher changed since it was read is left untouched and said (not done, no temp left); an already-removed file is no failure" \
  || bad "(10) races: [$(printf '%s' "$race_out" | tr '\n' '|')]"

# (11) a ~/.claude/projects that cannot be listed is named, not a traceback, and the rest still runs
if [ "$(id -u)" = 0 ]; then
  skip "(11) not run under root (a 000 directory does not stop root)"
else
  F="$TMP/noproj"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/projects"
  cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"; chmod 000 "$H/.claude/projects"
  retire "$H"; rc=$?
  chmod 755 "$H/.claude/projects"
  [ "$rc" -eq 0 ] && grep -qF "kept $H/.claude/projects — could not be listed" "$TMP/out" && ! grep -q Traceback "$TMP/out" \
    && [ ! -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
    && pass "(11) an unlistable ~/.claude/projects is named, no traceback, the installed script still retired" \
    || bad "(11) unlistable projects: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"
fi


# (12) a memory backlog whose repository is gone: removed, no error; the summary names neither the script
# nor a dispatcher call it did not touch, and the archive it names is the one on disk
F="$TMP/gone"; H="$F/home"; mkdir -p "$H/.claude"
repo "$H" "$F/repos/old"; B="$(backlog_of "$H" "$F/repos/old")"; rm -rf "$F/repos/old"
retire "$H"; rc=$?
A="$(find "$H/.zuvo/archive" -name 'review-queue-retired-*.tar.gz' 2>/dev/null)"
[ "$rc" -eq 0 ] && [ ! -e "$B" ] && [ -n "$A" ] \
  && grep -qxF "  ✓ review queue retired: 1 memory backlog(s), 0 repository queue file(s) — archived in $A" "$TMP/out" \
  && pass "(12) a backlog for a repository that no longer exists is removed; the summary claims nothing else and names the real archive" \
  || bad "(12) repo gone: status $rc, backlog $([ -e "$B" ] && echo LEFT || echo gone) [$(head -2 "$TMP/out" | tr '\n' '|')]"

# (13) a queue that is not UTF-8 text is kept, byte for byte, and the reason says so
F="$TMP/binary"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"
printf '# Review Queue\n\377\376 raw\n' > "$F/repos/one/docs/review-queue.md"; cp "$F/repos/one/docs/review-queue.md" "$F/queue.before"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$F/queue.before" "$F/repos/one/docs/review-queue.md" \
  && grep -qF "kept $F/repos/one/docs/review-queue.md — unreadable or not UTF-8 text" "$TMP/out" \
  && pass "(13) a queue that is not UTF-8 text is kept unchanged and named as such" \
  || bad "(13) non-UTF-8 queue: status $rc [$(grep binary "$TMP/out" | head -2 | tr '\n' '|')]"

# (14) a directory the name decodes to that is INSIDE a repository but not its root: the queue there is
# kept (git is asked about the wrong tree), while the root's own queue goes
F="$TMP/subdir"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/parent"
mkdir -p "$F/repos/parent/sub/docs"; cp "$F/repos/parent/docs/review-queue.md" "$F/repos/parent/sub/docs/review-queue.md"
SUBMEM="$H/.claude/projects/$(printf '%s' "$F/repos/parent/sub" | tr '/' '-')/memory"; mkdir -p "$SUBMEM"
cp "$(backlog_of "$H" "$F/repos/parent")" "$SUBMEM/review-backlog.md"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$F/repos/parent/sub/docs/review-queue.md" ] && [ ! -e "$F/repos/parent/docs/review-queue.md" ] \
  && grep -qF "kept $F/repos/parent/sub/docs/review-queue.md — not at the root of a git work tree" "$TMP/out" \
  && pass "(14) a queue in a subdirectory of a repository is kept as 'not at the root'; the root's queue is removed" \
  || bad "(14) subdir queue: status $rc [$(grep -E 'parent' "$TMP/out" | head -2 | tr '\n' '|')]"

# (15) git that cannot be run, and a repository git cannot answer for (a corrupt index): the queue is kept
F="$TMP/nogit"; H="$F/home"; mkdir -p "$H/.claude" "$F/emptybin"; repo "$H" "$F/repos/one"
env -i HOME="$H" PATH="$F/emptybin" LANG=C LC_ALL=C "$(command -v python3)" "$RETIRE" "$H" > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ -f "$F/repos/one/docs/review-queue.md" ] \
  && grep -qF "kept $F/repos/one/docs/review-queue.md — git could not be run to tell whether it is tracked" "$TMP/out" \
  && pass "(15a) without git on PATH a queue is kept and the reason says git could not be run" \
  || bad "(15a) no git: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"
F="$TMP/badindex"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"; printf 'not an index' > "$F/repos/one/.git/index"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$F/repos/one/docs/review-queue.md" ] \
  && grep -qF "kept $F/repos/one/docs/review-queue.md — git could not tell whether it is tracked" "$TMP/out" \
  && pass "(15b) a repository whose index git cannot read: the queue is kept, 'could not tell'" \
  || bad "(15b) corrupt index: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"

# (16) a memory backlog that is a symlink is kept (and so is what it points at); its repository is still
# reached through its name, so the queue there goes
F="$TMP/memlink"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"
B="$(backlog_of "$H" "$F/repos/one")"; mv "$B" "$F/real-backlog.md"; ln -s "$F/real-backlog.md" "$B"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -L "$B" ] && [ -f "$F/real-backlog.md" ] && [ ! -e "$F/repos/one/docs/review-queue.md" ] \
  && grep -qF "kept $B — a symlink or not a regular file" "$TMP/out" \
  && pass "(16) a symlinked memory backlog is kept with its target and named; its repository's queue is removed" \
  || bad "(16) symlinked backlog: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"

# (17) the dispatcher cannot be rewritten: status 1, said, and the installed script is KEPT — the call is
# still there, and a missing file would fail every commit
if [ "$(id -u)" = 0 ]; then
  skip "(17) not run under root (a 555 directory does not stop root)"
else
  F="$TMP/rohooks"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"
  cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
  printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh 2>/dev/null' > "$H/.claude/hooks/post-commit"
  cp "$H/.claude/hooks/post-commit" "$F/dispatcher.before"; chmod 555 "$H/.claude/hooks"
  retire "$H"; rc=$?
  chmod 755 "$H/.claude/hooks"
  [ "$rc" -eq 1 ] && cmp -s "$F/dispatcher.before" "$H/.claude/hooks/post-commit" && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
    && grep -qF "could not rewrite $H/.claude/hooks/post-commit (" "$TMP/out" \
    && grep -qF "kept $H/.claude/scripts/post-commit-review-backlog.sh — the dispatcher still calls it" "$TMP/out" \
    && grep -q '^  ✓ review queue retired: 0 memory backlog(s), 0 repository queue file(s) — archived in ' "$TMP/out" \
    && pass "(17) a dispatcher that cannot be rewritten: status 1, said, the script it calls is kept, the summary claims neither" \
    || bad "(17) unwritable hooks dir: status $rc [$(head -4 "$TMP/out" | tr '\n' '|')]"
fi

# (18) the call is the only body of an if: dropping the line would leave `then` with nothing before `fi`,
# so it becomes the no-op ':' and the dispatcher still parses; a call bash does not need is simply dropped
F="$TMP/block"; H="$F/home"; mkdir -p "$H/.claude/hooks"
printf '%s\n' '#!/bin/bash' 'if [ -d "$HOME" ]; then' '  bash "$HOME/.claude/scripts/post-commit-review-backlog.sh" 2>/dev/null' 'fi' 'echo chained' \
  > "$H/.claude/hooks/post-commit"
printf '%s\n' '#!/bin/bash' 'if [ -d "$HOME" ]; then' '  :  # zuvo: the retired review-queue call was here (2026-10-05)' 'fi' 'echo chained' > "$F/want"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$F/want" "$H/.claude/hooks/post-commit" && bash -n "$H/.claude/hooks/post-commit" \
  && ! grep -q 'post-commit-review-backlog' "$H/.claude/hooks/post-commit" \
  && pass "(18) a call that is an if's only body becomes ':' (the dispatcher still parses and no longer names the script)" \
  || bad "(18) block: status $rc [$(tr '\n' '|' < "$H/.claude/hooks/post-commit")]"

# (19) a dispatcher line that calls the script in a form this cleanup does not rewrite keeps zuvo's own
# script in place (the line would run a missing file); an unreadable dispatcher does the same
F="$TMP/unrecognised"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' '[ -x ~/.claude/scripts/post-commit-review-backlog.sh ] && ~/.claude/scripts/post-commit-review-backlog.sh' > "$H/.claude/hooks/post-commit"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] && [ ! -e "$H/.zuvo" ] \
  && grep -qF "kept $H/.claude/scripts/post-commit-review-backlog.sh — the dispatcher may still call it" "$TMP/out" \
  && pass "(19a) zuvo's script is kept while a dispatcher line this cleanup does not rewrite still calls it" \
  || bad "(19a) unrecognised call: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"
F="$TMP/binhook"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '#!/bin/sh\n\377\376\n' > "$H/.claude/hooks/post-commit"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && grep -qF "kept $H/.claude/hooks/post-commit — unreadable or not UTF-8 text" "$TMP/out" \
  && grep -qF "kept $H/.claude/scripts/post-commit-review-backlog.sh — the dispatcher may still call it" "$TMP/out" \
  && pass "(19b) an unreadable dispatcher is named, and zuvo's script is kept beside it" \
  || bad "(19b) unreadable dispatcher: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"

# (20) only the dispatcher call, and only the script: each summary names exactly what went, and the archive
# holds exactly that one file
F="$TMP/onlycall"; H="$F/home"; mkdir -p "$H/.claude/hooks"
printf '%s\n' '#!/bin/sh' 'sh ${HOME}/.claude/scripts/post-commit-review-backlog.sh || :' 'echo chained' > "$H/.claude/hooks/post-commit"
retire "$H"; rc=$?
A="$(find "$H/.zuvo/archive" -name 'review-queue-retired-*.tar.gz' 2>/dev/null | head -1)"
[ "$rc" -eq 0 ] && [ "$(archives "$H")" = 1 ] && [ "$(tar -tzf "$A" 2>/dev/null)" = "${H#/}/.claude/hooks/post-commit" ] \
  && cmp -s <(printf '#!/bin/sh\necho chained\n') "$H/.claude/hooks/post-commit" \
  && grep -qxF "  ✓ review queue retired: 0 memory backlog(s), 0 repository queue file(s), its call in ~/.claude/hooks/post-commit — archived in $A" "$TMP/out" \
  && pass "(20a) only a dispatcher call: the summary names just the call; the archive holds just the dispatcher" \
  || bad "(20a) call only: status $rc [$(grep '✓' "$TMP/out")]"
F="$TMP/onlyscript"; H="$F/home"; mkdir -p "$H/.claude/scripts"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
retire "$H"; rc=$?
A="$(find "$H/.zuvo/archive" -name 'review-queue-retired-*.tar.gz' 2>/dev/null | head -1)"
[ "$rc" -eq 0 ] && [ "$(archives "$H")" = 1 ] && [ "$(tar -tzf "$A" 2>/dev/null)" = "${H#/}/.claude/scripts/post-commit-review-backlog.sh" ] \
  && grep -qxF "  ✓ review queue retired: 0 memory backlog(s), 0 repository queue file(s), the installed script — archived in $A" "$TMP/out" \
  && pass "(20b) only the installed script: the summary names just the script; the archive holds just it" \
  || bad "(20b) script only: status $rc [$(grep '✓' "$TMP/out")]"

# (21) repository hooks: only an EXECUTABLE post-commit that names the script is reported — not one that
# does something else, not one that is not executable (git would not run it). A linked worktree shares its
# main checkout's hook, and the shared hook is named once, at its real path.
F="$TMP/hooks"; H="$F/home"; mkdir -p "$H/.claude/scripts"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
repo "$H" "$F/repos/other"; printf '#!/bin/sh\necho mine\n' > "$F/repos/other/.git/hooks/post-commit"; chmod +x "$F/repos/other/.git/hooks/post-commit"
repo "$H" "$F/repos/noexec"; printf '#!/bin/sh\nbash ~/.claude/scripts/post-commit-review-backlog.sh\n' > "$F/repos/noexec/.git/hooks/post-commit"
repo "$H" "$F/repos/main"
git -C "$F/repos/main" worktree add -q "$F/repos/main-wt" -b wt 2>/dev/null && echo y > "$F/repos/main-wt/g" && git -C "$F/repos/main-wt" add g \
  && git -C "$F/repos/main-wt" -c user.name=t -c user.email=t@example.invalid commit -qm 'feat: wt change' && mkdir -p "$F/repos/main-wt/docs" \
  && (cd "$F/repos/main-wt" && HOME="$H" bash "$GEN")
# the hook goes in only now: written earlier, the worktree commit above would have run it with the real HOME
printf '#!/bin/sh\nbash ~/.claude/scripts/post-commit-review-backlog.sh\n' > "$F/repos/main/.git/hooks/post-commit"
chmod +x "$F/repos/main/.git/hooks/post-commit"; cp "$F/repos/main/.git/hooks/post-commit" "$F/hook.before"
if [ ! -f "$F/repos/main-wt/docs/review-queue.md" ]; then
  bad "(21) setup: the linked worktree or its generated queue was not created — case not judged"
else
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c 'still runs the retired' "$TMP/out")" -eq 1 ] \
  && grep -qxF "  ! review queue: $F/repos/main/.git/hooks/post-commit still runs the retired post-commit-review-backlog.sh — delete that line by hand" "$TMP/out" \
  && [ ! -e "$F/repos/main-wt/docs/review-queue.md" ] && cmp -s "$F/hook.before" "$F/repos/main/.git/hooks/post-commit" \
  && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && grep -qF "kept $H/.claude/scripts/post-commit-review-backlog.sh — a repository post-commit hook (below) may still call it" "$TMP/out" \
  && pass "(21) only the executable hook naming the script is reported, once, at its real path, untouched; the installed script it calls is kept" \
  || bad "(21) repo hooks: status $rc [$(grep 'still runs' "$TMP/out" | tr '\n' '|')] wt queue $([ -e "$F/repos/main-wt/docs/review-queue.md" ] && echo LEFT || echo gone)"
fi

# (22) two directories whose paths encode alike (a/b-c and a-b/c) share one memory file; each one's queue is
# judged on its own — the untracked one goes, the tracked one stays
F="$TMP/amb"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/r/amb/b-c"; repo "$H" "$F/r/amb-b/c"
git -C "$F/r/amb-b/c" add docs/review-queue.md && git -C "$F/r/amb-b/c" -c user.name=t -c user.email=t@example.invalid commit -qm 'docs: queue'
same_name=$([ "$(backlog_of "$H" "$F/r/amb/b-c")" = "$(backlog_of "$H" "$F/r/amb-b/c")" ] && echo yes || echo no)
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ "$same_name" = yes ] && [ ! -e "$(backlog_of "$H" "$F/r/amb/b-c")" ] && [ ! -e "$F/r/amb/b-c/docs/review-queue.md" ] && [ -f "$F/r/amb-b/c/docs/review-queue.md" ] \
  && grep -qF "kept $F/r/amb-b/c/docs/review-queue.md — tracked in git" "$TMP/out" \
  && pass "(22) two repositories behind one encoded name: each queue judged alone (untracked removed, tracked kept)" \
  || bad "(22) ambiguous name ($same_name): status $rc [$(grep amb "$TMP/out" | head -2 | tr '\n' '|')]"

# (23) the patterns and the decode, as tables: every call spelling the dispatcher may hold is recognised and
# nothing else is; a hand-written checklist is not "generated"; malformed names decode to nothing
table_out="$(python3 - "$RETIRE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('retire', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
match = [('/home/u', 'bash "$HOME/.claude/scripts/post-commit-review-backlog.sh" 2>/dev/null'),
         ('/home/u', 'sh ~/.claude/scripts/post-commit-review-backlog.sh'),
         ('/home/u', 'bash ${HOME}/.claude/scripts/post-commit-review-backlog.sh || :'),
         ('/home/u', "  bash '/home/u/.claude/scripts/post-commit-review-backlog.sh' 2>/dev/null || true  "),
         ('/home/u', 'bash /home/u/.claude/scripts/post-commit-review-backlog.sh'),
         ('/Users/A B', 'bash "/Users/A B/.claude/scripts/post-commit-review-backlog.sh" 2>/dev/null'),
         ('/home/a b', "sh '/home/a b/.claude/scripts/post-commit-review-backlog.sh'")]
nomatch = [('/home/u', 'bash "$HOME/.claude/scripts/post-commit-review-backlog.sh\' 2>/dev/null'),
           ('/home/u', 'bash ~/.claude/scripts/post-commit-review-backlog.sh --flag'),
           ('/home/u', 'bash ~/.claude/scripts/post-commit-review-backlog.sh && echo x'),
           ('/home/u', '# bash ~/.claude/scripts/post-commit-review-backlog.sh'),
           ('/home/u', 'bash ~/.claude/scripts/other.sh'),
           ('/home/u', 'python3 ~/.claude/scripts/post-commit-review-backlog.sh'),
           ('/Users/A B', 'bash /Users/A B/.claude/scripts/post-commit-review-backlog.sh'),
           ('/home/u', 'bash /home/other/.claude/scripts/post-commit-review-backlog.sh'),
           ('/home/u', 'bash /home/u2/.claude/scripts/post-commit-review-backlog.sh')]
print('match', [ln for h, ln in match if not m.call_re(h).match(ln)])
print('nomatch', [ln for h, ln in nomatch if m.call_re(h).match(ln)])
head = '# Review Backlog\n\n## Unreviewed\n\n'
print('backlog', m.generated(head + '- [ ] abc1234 fix: a\n- [x] 0f9e8d7 feat: b\n', '# Review Backlog', m.BACKLOG_FIXED, m.BACKLOG_LINE),
      m.generated(head + '- [ ] buy milk\n', '# Review Backlog', m.BACKLOG_FIXED, m.BACKLOG_LINE),
      m.generated('# Review backlog\n', '# Review Backlog', m.BACKLOG_FIXED, m.BACKLOG_LINE))
print('roots', m.repo_roots('tmp-x'), m.repo_roots('-' + '-'.join(['a'] * 70)), m.repo_roots('-'), m.repo_roots('-tmp-'),
      m.repo_roots('-tmp-..-tmp'), m.repo_roots('-tmp-.'))
PY
)"; table_rc=$?
[ "$table_rc" -eq 0 ] && [ "$(printf '%s\n' "$table_out" | sed -n 1p)" = "match []" ] && [ "$(printf '%s\n' "$table_out" | sed -n 2p)" = "nomatch []" ] \
  && [ "$(printf '%s\n' "$table_out" | sed -n 3p)" = "backlog True False False" ] \
  && [ "$(printf '%s\n' "$table_out" | sed -n 4p)" = "roots [] [] [] [] [] []" ] \
  && pass "(23) call spellings: 7 recognised (quoted paths with spaces too), 9 near-misses not (another home's copy among them); a checklist without commit hashes is not generated; malformed names (and '.'/'..' parts) decode to nothing" \
  || bad "(23) tables: [$(printf '%s' "$table_out" | tr '\n' '|')]"

# (24) the archive: a file missing when the archive is written (gone since the plan) fails the whole
# archive and leaves no temporary file; a file that changed AFTER it was archived is kept, not deleted
F="$TMP/archive"; mkdir -p "$F/home"; printf 'one\n' > "$F/one.md"
arch_out="$(python3 - "$RETIRE" "$F" <<'PY'
import contextlib, importlib.util, io, os, sys, tarfile
spec = importlib.util.spec_from_file_location('retire', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
f = sys.argv[2]; home = os.path.join(f, 'home'); one = os.path.join(f, 'one.md')
try:
    m.write_archive(home, [one, os.path.join(f, 'vanished.md')])
    print('missing no-error')
except (OSError, tarfile.TarError):
    print('missing error', sorted(os.listdir(os.path.join(home, '.zuvo', 'archive'))))
archive, digests = m.write_archive(home, [one])
with open(one, 'a') as fh:
    fh.write('changed\n')
out = io.StringIO()
with contextlib.redirect_stdout(out):
    removed, failed = m.remove_all([(one, lambda: None)], digests)
print('changed', removed, failed, os.path.exists(one), 'it changed after it was archived' in out.getvalue())
PY
)"; arch_rc=$?
[ "$arch_rc" -eq 0 ] && [ "$(printf '%s\n' "$arch_out" | sed -n 1p)" = "missing error []" ] \
  && [ "$(printf '%s\n' "$arch_out" | sed -n 2p)" = "changed [] 0 True True" ] \
  && pass "(24) a file missing when the archive is written fails it with no temp left; a file changed after archiving is kept and said" \
  || bad "(24) archive edges: [$(printf '%s' "$arch_out" | tr '\n' '|')]"

# (25) a relative <home> is the same home; --dry-run alone is a bad call
F="$TMP/rel"; H="$F/home"; mkdir -p "$H/.claude/scripts"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
(cd "$F" && LANG=C LC_ALL=C python3 "$RETIRE" home) > "$TMP/out" 2>&1; rc=$?
python3 "$RETIRE" --dry-run > "$TMP/out2" 2>&1; rc2=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] && [ "$(archives "$H")" = 1 ] \
  && grep -qF "archived in $H/.zuvo/archive/" "$TMP/out" && [ "$rc2" -eq 64 ] && grep -q 'bad arguments' "$TMP/out2" \
  && pass "(25) a relative home resolves to the same absolute home; --dry-run without a home is a bad call (64)" \
  || bad "(25) relative home: status $rc [$(head -2 "$TMP/out" | tr '\n' '|')], dry-run alone: $rc2"


# (26) a dispatcher that is nothing but the call (no shebang, no chain): dropping the line would leave an
# empty file, so the line becomes ':' — the file stays a runnable script that no longer names the script
F="$TMP/onlyline"; H="$F/home"; mkdir -p "$H/.claude/hooks"
printf 'bash ~/.claude/scripts/post-commit-review-backlog.sh\n' > "$H/.claude/hooks/post-commit"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$H/.claude/hooks/post-commit")" = ':  # zuvo: the retired review-queue call was here (2026-10-05)' ] \
  && pass "(26) a dispatcher holding only the call is not emptied: the line becomes ':'" \
  || bad "(26) only the call: status $rc [$(tr '\n' '|' < "$H/.claude/hooks/post-commit")]"

# (27) a matching line after a `\` continuation is not a command of its own — it is the tail of
# `echo before`, whose arguments it supplies — so neither dropping it nor ':' would keep what the file does:
# the dispatcher is left alone and named, and zuvo's script beside it stays (the line still runs it)
F="$TMP/continued"; H="$F/home"; mkdir -p "$H/.claude/hooks" "$H/.claude/scripts"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' 'echo before \' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' 'echo after' > "$H/.claude/hooks/post-commit"
cp "$H/.claude/hooks/post-commit" "$F/want"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$F/want" "$H/.claude/hooks/post-commit" && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && grep -qF "kept $H/.claude/hooks/post-commit — names the script in a line this cleanup does not recognise" "$TMP/out" \
  && pass "(27) a matching line that continues the one before it is left alone (named), and the script it runs is kept" \
  || bad "(27) continuation: status $rc [$(tr '\n' '|' < "$H/.claude/hooks/post-commit")]"

# (28) a dispatcher with CRLF line endings keeps them: only the call line goes, every other byte stays
F="$TMP/crlf"; H="$F/home"; mkdir -p "$H/.claude/hooks"
printf '#!/bin/sh\r\nbash ~/.claude/scripts/post-commit-review-backlog.sh\r\necho chained\r\n' > "$H/.claude/hooks/post-commit"
printf '#!/bin/sh\r\necho chained\r\n' > "$F/want"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$F/want" "$H/.claude/hooks/post-commit" \
  && pass "(28) a CRLF dispatcher loses the call line only; its CRLF line endings are kept byte for byte" \
  || bad "(28) CRLF: status $rc [$(od -c "$H/.claude/hooks/post-commit" | head -3 | tr '\n' '|')]"

# (29) a file is judged again just before it is deleted: one that gained a hand-written line after the
# plan was made is kept, even though the archive already holds it — driven through the functions so the
# edit lands exactly between the plan and the removal
F="$TMP/recheck"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"
recheck_out="$(LANG=C LC_ALL=C python3 - "$RETIRE" "$H" "$F/repos/one/docs/review-queue.md" <<'PY'
import contextlib, importlib.util, io, os, sys
spec = importlib.util.spec_from_file_location('retire', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home, queue = sys.argv[2], sys.argv[3]
delete, rewrite, kept, hooks = m.plan(home)
paths = [p for p, _ in delete]
archive, digests = m.write_archive(home, paths)
with open(queue, 'a') as fh:
    fh.write('my own note\n')
out = io.StringIO()
with contextlib.redirect_stdout(out):
    removed, failed = m.remove_all(delete, digests)
print(len(paths), [os.path.basename(p) for p in removed], failed, os.path.exists(queue),
      'not the generated format' in out.getvalue())
PY
)"; recheck_rc=$?
[ "$recheck_rc" -eq 0 ] && [ "$recheck_out" = "2 ['review-backlog.md'] 0 True True" ] \
  && pass "(29) a queue edited between the plan and the removal is judged again and kept; the untouched backlog goes" \
  || bad "(29) recheck: status $recheck_rc [$recheck_out]"

# (30) a file above MAX_BYTES is not read and is kept, named with the reason
F="$TMP/big"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"
big_out="$(python3 - "$RETIRE" "$(backlog_of "$H" "$F/repos/one")" "$H" <<'PY'
import importlib.util, os, sys
spec = importlib.util.spec_from_file_location('retire', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.backlog_verdict(sys.argv[2]))
m.MAX_BYTES = 10
print(m.backlog_verdict(sys.argv[2]))
home = sys.argv[3]
try:
    m.write_archive(home, [sys.argv[2]])
    print('archive no-error')
except (OSError, m.tarfile.TarError) as e:
    print('archive error', 'grew past 10 bytes' in str(e), sorted(os.listdir(os.path.join(home, '.zuvo', 'archive'))))
PY
)"; big_rc=$?
[ "$big_rc" -eq 0 ] && [ "$(printf '%s\n' "$big_out" | sed -n 1p)" = None ] \
  && [ "$(printf '%s\n' "$big_out" | sed -n 2p)" = 'larger than 10 bytes — not read' ] \
  && [ "$(printf '%s\n' "$big_out" | sed -n 3p)" = 'archive error True []' ] \
  && pass "(30) a generated backlog under the size cap may go; over it, it is kept unread, and the archive refuses it (no temp left)" \
  || bad "(30) size cap: status $big_rc [$(printf '%s' "$big_out" | tr '\n' '|')]"

# (31) the dispatcher calls a same-named script that is NOT zuvo's: the user's file stays hooked — neither
# the call line nor the script is touched, and both are named
F="$TMP/foreigncall"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"
printf '#!/bin/sh\necho mine\n' > "$H/.claude/scripts/post-commit-review-backlog.sh"
printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' > "$H/.claude/hooks/post-commit"
cp "$H/.claude/hooks/post-commit" "$F/dispatcher.before"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$F/dispatcher.before" "$H/.claude/hooks/post-commit" && [ ! -e "$H/.zuvo" ] \
  && grep -qF "kept $H/.claude/hooks/post-commit — calls a same-named script that is not zuvo's" "$TMP/out" \
  && grep -qF "kept $H/.claude/scripts/post-commit-review-backlog.sh — not the copy zuvo installed" "$TMP/out" \
  && pass "(31) a call to a same-named script that is not zuvo's is left hooked: dispatcher and script untouched, both named" \
  || bad "(31) foreign call: status $rc [$(head -3 "$TMP/out" | tr '\n' '|')]"

# (32) a repository with its own core.hooksPath (Husky and the like) whose post-commit still calls the script:
# found there and reported, untouched, and zuvo's installed script is kept because of it
F="$TMP/husky"; H="$F/home"; mkdir -p "$H/.claude/scripts"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
repo "$H" "$F/repos/one"; mkdir -p "$F/repos/one/.husky"; git -C "$F/repos/one" config core.hooksPath .husky
printf '#!/bin/sh\nbash ~/.claude/scripts/post-commit-review-backlog.sh\n' > "$F/repos/one/.husky/post-commit"; chmod +x "$F/repos/one/.husky/post-commit"
cp "$F/repos/one/.husky/post-commit" "$F/hook.before"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && grep -qxF "  ! review queue: $F/repos/one/.husky/post-commit still runs the retired post-commit-review-backlog.sh — delete that line by hand" "$TMP/out" \
  && cmp -s "$F/hook.before" "$F/repos/one/.husky/post-commit" && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && pass "(32) a post-commit under the repository's own core.hooksPath is found, reported, untouched; the script it runs is kept" \
  || bad "(32) local hooksPath: status $rc [$(grep -E 'still runs|kept' "$TMP/out" | head -3 | tr '\n' '|')]"

# (33) a repository post-commit that is a FIFO is not read (the read would block the install forever): the
# run finishes, and the repository's queue still goes
F="$TMP/fifo"; H="$F/home"; mkdir -p "$H/.claude"; repo "$H" "$F/repos/one"; mkfifo "$F/repos/one/.git/hooks/post-commit"
LANG=C LC_ALL=C timeout 60 python3 "$RETIRE" "$H" > "$TMP/out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$F/repos/one/docs/review-queue.md" ] && [ -p "$F/repos/one/.git/hooks/post-commit" ] \
  && pass "(33) a FIFO where a repository hook would be is skipped, not read; the run finishes and the queue goes" \
  || bad "(33) FIFO hook: status $rc (124 = hung) [$(head -2 "$TMP/out" | tr '\n' '|')]"

# (34) a child that cannot be run, or does not finish in time, is (None, '') — never a traceback: git or bash
# missing, and a hung one cut off at TIMEOUT (driven through run() with the bound lowered for the test)
run_out="$(python3 - "$RETIRE" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location('retire', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print('missing', m.run(['/nonexistent/no-such-binary']))
m.TIMEOUT = 0.2
print('hung', m.run(['sleep', '5']))
print('ok', m.run(['sh', '-c', 'printf hi; exit 3']))
PY
)"; run_rc=$?
[ "$run_rc" -eq 0 ] && [ "$(printf '%s\n' "$run_out" | sed -n 1p)" = "missing (None, '')" ] \
  && [ "$(printf '%s\n' "$run_out" | sed -n 2p)" = "hung (None, '')" ] && [ "$(printf '%s\n' "$run_out" | sed -n 3p)" = "ok (3, 'hi')" ] \
  && pass "(34) a missing or hung child is (None, ''), a finished one its status and output" \
  || bad "(34) run(): status $run_rc [$(printf '%s' "$run_out" | tr '\n' '|')]"

# (35) a repository whose own core.hooksPath IS the shared dispatcher's directory: that hook is the dispatcher,
# handled as such (its call dropped), never reported as a repository hook — and so it does not keep the script
F="$TMP/sharedpath"; H="$F/home"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"; cp "$GEN" "$H/.claude/scripts/post-commit-review-backlog.sh"
repo "$H" "$F/repos/one"; git -C "$F/repos/one" config core.hooksPath "$H/.claude/hooks"
printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' 'echo chained' > "$H/.claude/hooks/post-commit"; chmod +x "$H/.claude/hooks/post-commit"
retire "$H"; rc=$?
[ "$rc" -eq 0 ] && ! grep -q 'still runs the retired' "$TMP/out" && [ ! -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && cmp -s <(printf '#!/bin/sh\necho chained\n') "$H/.claude/hooks/post-commit" \
  && pass "(35) a repository hooksPath that is the shared dispatcher's own dir is not reported as a repo hook; the call goes and so does the script" \
  || bad "(35) shared hooksPath: status $rc [$(grep -E 'still runs|kept' "$TMP/out" | head -2 | tr '\n' '|')]"

# (36) --dry-run with nothing to delete but the dispatcher call: says it would drop the call, removes nothing,
# changes nothing, writes no archive
F="$TMP/dryonlycall"; H="$F/home"; mkdir -p "$H/.claude/hooks"
printf '%s\n' '#!/bin/sh' 'bash ~/.claude/scripts/post-commit-review-backlog.sh' > "$H/.claude/hooks/post-commit"
cp "$H/.claude/hooks/post-commit" "$F/before"
retire "$H" --dry-run; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$F/before" "$H/.claude/hooks/post-commit" && [ ! -e "$H/.zuvo" ] \
  && grep -qxF "  (dry run) would drop the post-commit-review-backlog.sh call from $H/.claude/hooks/post-commit" "$TMP/out" \
  && ! grep -q 'would remove' "$TMP/out" \
  && pass "(36) --dry-run with only a dispatcher call: names the call, removes and changes nothing, no archive" \
  || bad "(36) dry run, call only: status $rc [$(head -2 "$TMP/out" | tr '\n' '|')]"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
