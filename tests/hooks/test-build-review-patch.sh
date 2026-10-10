#!/usr/bin/env bash
# test-build-review-patch.sh — Task 1 RED/GREEN for scripts/zuvo-home/build-review-patch.
#
# The helper must emit a scoped review patch on STDOUT (diagnostics on stderr)
# WITHOUT touching the git index: no `git add`, no `git stash`, no index writes.
# That "index untouched" property is the whole point — a review helper that
# stages the user's work would silently rewrite what a later commit captures.
#
# Exit-code contract under test:
#   0  non-empty patch emitted
#   2  usage / not-a-repo / bad --base / unreadable file
#   3  no changes (empty patch)
#
# Standalone dialect (own pass()/bad(), final ALL PASS) — same shape as
# tests/hooks/test-review-artifact.sh. bash 3.2-safe: no mapfile, no `declare -A`.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HELPER="$ROOT/scripts/zuvo-home/build-review-patch"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT INT TERM

# ── fixture helper: a fresh throwaway repo (idiom from test-pre-push-gate.sh) ──
new_repo() {
  local d="$TMP/$1"
  mkdir -p "$d" || return 1
  (
    cd "$d" || exit 1
    git init -q -b main 2>/dev/null || { git init -q; git symbolic-ref HEAD refs/heads/main; }
    git config user.email t@t.t
    git config user.name t
    git config commit.gpgsign false
  ) || return 1
  printf '%s\n' "$d"
}

has() { case "$2" in *"$1"*) return 0 ;; esac; return 1; }

# ═════════════════════════════════════════════════════════════════════════════
# (1) mixed working tree: modified tracked + untracked + user-staged + unrelated
# ═════════════════════════════════════════════════════════════════════════════
R1="$(new_repo r1)" || { bad "fixture init r1"; echo "SOME FAILED"; exit 1; }
(
  cd "$R1" || exit 1
  echo one > mod.txt
  echo two > staged.txt
  echo three > unrelated.txt
  mkdir -p sub && echo four > sub/inner.txt
  printf 'ignored.txt\n' > .gitignore
  git add -A && git commit -qm base
  echo MODLINE >> mod.txt                       # tracked, unstaged
  printf 'NEWFILECONTENT\n' > new.txt           # untracked, not ignored
  echo STAGEDLINE >> staged.txt && git add staged.txt   # user-staged (must survive)
  echo DIRTYLINE >> unrelated.txt               # dirty, unrelated to PATH scope
  echo IGNOREDLINE > ignored.txt                # gitignored — must never appear
) || { bad "fixture populate r1"; echo "SOME FAILED"; exit 1; }

CACHED_BEFORE="$TMP/cached.before"
CACHED_AFTER="$TMP/cached.after"
git -C "$R1" diff --cached > "$CACHED_BEFORE"

OUT1="$(cd "$R1" && "$HELPER" 2>"$TMP/e1")"; RC1=$?
git -C "$R1" diff --cached > "$CACHED_AFTER"

[ "$RC1" -eq 0 ] && pass "(1) exit 0 on a dirty tree" \
  || bad "(1) expected exit 0, got $RC1 (stderr: $(tr '\n' '|' < "$TMP/e1"))"
has NEWFILECONTENT "$OUT1" && pass "(1) untracked file content included by default" \
  || bad "(1) untracked new.txt content missing from patch"
has MODLINE "$OUT1" && pass "(1) modified tracked hunk included" \
  || bad "(1) unstaged mod.txt hunk missing from patch"
has STAGEDLINE "$OUT1" && pass "(1) user-staged hunk included" \
  || bad "(1) staged staged.txt hunk missing from patch"
cmp -s "$CACHED_BEFORE" "$CACHED_AFTER" && pass "(1) git diff --cached byte-identical (index untouched)" \
  || bad "(1) INDEX MUTATED — git diff --cached changed across the run"

# (8) .gitignored file must not leak into the patch
has IGNOREDLINE "$OUT1" && bad "(8) gitignored file leaked into the patch" \
  || pass "(8) gitignored file absent from patch"

# ═════════════════════════════════════════════════════════════════════════════
# (2) PATH scoping — unrelated dirty file excluded
# ═════════════════════════════════════════════════════════════════════════════
OUT2="$(cd "$R1" && "$HELPER" mod.txt new.txt 2>"$TMP/e2")"; RC2=$?
[ "$RC2" -eq 0 ] && pass "(2) exit 0 with PATH args" || bad "(2) expected exit 0, got $RC2"
has MODLINE "$OUT2" && pass "(2) in-scope tracked hunk kept" || bad "(2) mod.txt hunk missing under PATH scope"
has NEWFILECONTENT "$OUT2" && pass "(2) in-scope untracked file kept" || bad "(2) new.txt missing under PATH scope"
has DIRTYLINE "$OUT2" && bad "(2) out-of-scope unrelated.txt leaked into scoped patch" \
  || pass "(2) out-of-scope dirty file excluded"

# ═════════════════════════════════════════════════════════════════════════════
# (6) ZUVO_REVIEW_PATCH_NO_UNTRACKED=1
# ═════════════════════════════════════════════════════════════════════════════
OUT6="$(cd "$R1" && ZUVO_REVIEW_PATCH_NO_UNTRACKED=1 "$HELPER" 2>"$TMP/e6")"; RC6=$?
[ "$RC6" -eq 0 ] && pass "(6) exit 0 with untracked disabled" || bad "(6) expected exit 0, got $RC6"
has NEWFILECONTENT "$OUT6" && bad "(6) ZUVO_REVIEW_PATCH_NO_UNTRACKED=1 still included untracked" \
  || pass "(6) ZUVO_REVIEW_PATCH_NO_UNTRACKED=1 excludes untracked"
has MODLINE "$OUT6" && pass "(6) tracked changes still present with untracked disabled" \
  || bad "(6) tracked hunk lost when untracked disabled"

# ═════════════════════════════════════════════════════════════════════════════
# (3) clean repo → exit 3, empty stdout
# ═════════════════════════════════════════════════════════════════════════════
R2="$(new_repo r2)" || { bad "fixture init r2"; echo "SOME FAILED"; exit 1; }
( cd "$R2" && echo clean > f.txt && git add -A && git commit -qm base ) >/dev/null 2>&1
OUT3="$(cd "$R2" && "$HELPER" 2>"$TMP/e3")"; RC3=$?
[ "$RC3" -eq 3 ] && pass "(3) clean repo exits 3" || bad "(3) expected exit 3 on clean repo, got $RC3"
[ -z "$OUT3" ] && pass "(3) clean repo emits empty stdout" || bad "(3) clean repo emitted stdout: $OUT3"

# ═════════════════════════════════════════════════════════════════════════════
# (4) not a git repo → exit 2
# ═════════════════════════════════════════════════════════════════════════════
NOREPO="$TMP/plain"; mkdir -p "$NOREPO"
OUT4="$(cd "$NOREPO" && "$HELPER" 2>"$TMP/e4")"; RC4=$?
[ "$RC4" -eq 2 ] && pass "(4) not-a-git-repo exits 2" || bad "(4) expected exit 2 outside a repo, got $RC4"
[ -s "$TMP/e4" ] && pass "(4) diagnostic written to stderr" || bad "(4) no stderr diagnostic outside a repo"
[ -z "$OUT4" ] && pass "(4) no stdout outside a repo" || bad "(4) stdout polluted outside a repo"

# ═════════════════════════════════════════════════════════════════════════════
# (5) bad --base / missing --base value / unknown flag → exit 2
# ═════════════════════════════════════════════════════════════════════════════
OUT5="$(cd "$R1" && "$HELPER" --base no-such-ref-xyz 2>"$TMP/e5")"; RC5=$?
[ "$RC5" -eq 2 ] && pass "(5) nonexistent --base ref exits 2" || bad "(5) expected exit 2 for bad --base, got $RC5"
[ -s "$TMP/e5" ] && pass "(5) bad --base writes a stderr diagnostic" || bad "(5) bad --base produced no stderr"
[ -z "$OUT5" ] && pass "(5) bad --base emits no stdout" || bad "(5) bad --base polluted stdout"

( cd "$R1" && "$HELPER" --base >/dev/null 2>&1 ); RC5B=$?
[ "$RC5B" -eq 2 ] && pass "(5) --base with no value exits 2" || bad "(5) expected exit 2 for dangling --base, got $RC5B"

( cd "$R1" && "$HELPER" --bogus-flag >/dev/null 2>&1 ); RC5C=$?
[ "$RC5C" -eq 2 ] && pass "(5) unknown flag exits 2" || bad "(5) expected exit 2 for unknown flag, got $RC5C"

# ═════════════════════════════════════════════════════════════════════════════
# (5b) --base is actually CONSUMED: committed-since-base work is in the patch
# ═════════════════════════════════════════════════════════════════════════════
R3="$(new_repo r3)" || { bad "fixture init r3"; echo "SOME FAILED"; exit 1; }
(
  cd "$R3" || exit 1
  echo base > f.txt && git add -A && git commit -qm base
) >/dev/null 2>&1
BASEREF="$(git -C "$R3" rev-parse HEAD)"
(
  cd "$R3" || exit 1
  # A SEPARATE file, so "AFTERBASE" can never show up as a mere context line of
  # the f.txt hunk — its presence proves the ref was diffed, nothing weaker.
  printf 'AFTERBASE\n' > afterbase.txt && git add afterbase.txt && git commit -qm after
  echo WORKTREEONLY >> f.txt
) >/dev/null 2>&1

OUT5D="$(cd "$R3" && "$HELPER" --base "$BASEREF" 2>"$TMP/e5d")"; RC5D=$?
[ "$RC5D" -eq 0 ] && pass "(5b) --base <ref> exits 0" || bad "(5b) expected exit 0 with --base, got $RC5D"
has "+AFTERBASE" "$OUT5D" && pass "(5b) committed-since-base hunk present with --base" \
  || bad "(5b) --base patch missing the committed-since-base change"
has "+WORKTREEONLY" "$OUT5D" && pass "(5b) --base patch also spans uncommitted work" \
  || bad "(5b) --base patch missing the uncommitted change"

OUT5E="$(cd "$R3" && "$HELPER" 2>/dev/null)"
has AFTERBASE "$OUT5E" && bad "(5b) committed change appears WITHOUT --base (flag not consumed)" \
  || pass "(5b) committed-since-base change absent without --base (flag genuinely consumed)"
has "+WORKTREEONLY" "$OUT5E" && pass "(5b) no-base run still reports the uncommitted change" \
  || bad "(5b) no-base run lost the uncommitted change (negative assertion above would be vacuous)"

# ═════════════════════════════════════════════════════════════════════════════
# (7) awkward filenames: embedded space, leading dash
# ═════════════════════════════════════════════════════════════════════════════
R4="$(new_repo r4)" || { bad "fixture init r4"; echo "SOME FAILED"; exit 1; }
(
  cd "$R4" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  printf 'SPACECONTENT\n' > "with space.txt"
  printf 'DASHCONTENT\n' > -dash.txt
) >/dev/null 2>&1
OUT7="$(cd "$R4" && "$HELPER" 2>"$TMP/e7")"; RC7=$?
[ "$RC7" -eq 0 ] && pass "(7) exit 0 with awkward filenames" || bad "(7) expected exit 0, got $RC7"
has SPACECONTENT "$OUT7" && pass "(7) filename with a space handled" || bad "(7) 'with space.txt' missing from patch"
has DASHCONTENT "$OUT7" && pass "(7) filename with a leading dash handled" || bad "(7) '-dash.txt' missing from patch"

OUT7B="$(cd "$R4" && "$HELPER" -- -dash.txt 2>"$TMP/e7b")"; RC7B=$?
[ "$RC7B" -eq 0 ] && pass "(7) leading-dash pathspec after -- exits 0" || bad "(7) expected exit 0 for '-- -dash.txt', got $RC7B"
has DASHCONTENT "$OUT7B" && pass "(7) leading-dash pathspec scoped in" || bad "(7) '-dash.txt' missing when passed after --"
has SPACECONTENT "$OUT7B" && bad "(7) leading-dash scope leaked the other file" || pass "(7) leading-dash pathspec excludes the rest"

OUT7C="$(cd "$R4" && "$HELPER" "with space.txt" 2>/dev/null)"
has SPACECONTENT "$OUT7C" && pass "(7) spaced pathspec scoped in" || bad "(7) 'with space.txt' missing when passed as a pathspec"

# ═════════════════════════════════════════════════════════════════════════════
# (9) binary untracked file: skipped, with a stderr note
# ═════════════════════════════════════════════════════════════════════════════
R5="$(new_repo r5)" || { bad "fixture init r5"; echo "SOME FAILED"; exit 1; }
(
  cd "$R5" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  printf '\0\1\2' > blob.bin
  printf 'TEXTUNTRACKED\n' > text.txt
) >/dev/null 2>&1
OUT9="$(cd "$R5" && "$HELPER" 2>"$TMP/e9")"; RC9=$?
E9="$(cat "$TMP/e9")"
[ "$RC9" -eq 0 ] && pass "(9) binary untracked does not break the run" || bad "(9) expected exit 0, got $RC9"
has TEXTUNTRACKED "$OUT9" && pass "(9) text untracked still included alongside a binary" || bad "(9) text.txt missing"
has "Binary files" "$OUT9" && bad "(9) binary diff leaked into stdout" || pass "(9) binary untracked skipped from stdout"
has blob.bin "$E9" && pass "(9) stderr notes the skipped binary file" || bad "(9) no stderr note naming blob.bin"

# ═════════════════════════════════════════════════════════════════════════════
# (10) unreadable untracked file → exit 2 (never a silent partial patch)
# ═════════════════════════════════════════════════════════════════════════════
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: (10) unreadable-file case skipped (running as root)\n'
else
  R6="$(new_repo r6)" || { bad "fixture init r6"; echo "SOME FAILED"; exit 1; }
  (
    cd "$R6" || exit 1
    echo seed > seed.txt && git add -A && git commit -qm base
    printf 'secret\n' > noread.txt && chmod 000 noread.txt
  ) >/dev/null 2>&1
  ( cd "$R6" && "$HELPER" >/dev/null 2>"$TMP/e10" ); RC10=$?
  [ "$RC10" -eq 2 ] && pass "(10) unreadable untracked file exits 2" \
    || bad "(10) expected exit 2 for unreadable file, got $RC10"
  [ -s "$TMP/e10" ] && pass "(10) unreadable file writes a stderr diagnostic" || bad "(10) no stderr for unreadable file"
  chmod 644 "$R6/noread.txt" 2>/dev/null
fi

# ═════════════════════════════════════════════════════════════════════════════
# (11) linked worktree: from its root AND from a subdirectory (relative PATH)
# ═════════════════════════════════════════════════════════════════════════════
WT="$TMP/wt"
if git -C "$R1" worktree add -q "$WT" -b wtbranch >/dev/null 2>&1; then
  (
    cd "$WT" || exit 1
    echo WTMOD >> mod.txt
    mkdir -p sub && printf 'WCONTENT\n' > sub/wfile.txt
  ) || bad "(11) worktree populate failed"

  OUT11="$(cd "$WT" && "$HELPER" 2>"$TMP/e11")"; RC11=$?
  [ "$RC11" -eq 0 ] && pass "(11) worktree root run exits 0" || bad "(11) expected exit 0 in worktree, got $RC11"
  has WTMOD "$OUT11" && pass "(11) worktree tracked hunk included" || bad "(11) worktree mod.txt hunk missing"
  has "b/sub/wfile.txt" "$OUT11" && pass "(11) worktree patch paths are worktree-root-relative" \
    || bad "(11) expected 'b/sub/wfile.txt' header in worktree patch"

  OUT11B="$(cd "$WT/sub" && "$HELPER" wfile.txt 2>"$TMP/e11b")"; RC11B=$?
  [ "$RC11B" -eq 0 ] && pass "(11) worktree subdir run with relative PATH exits 0" \
    || bad "(11) expected exit 0 from worktree subdir, got $RC11B (stderr: $(tr '\n' '|' < "$TMP/e11b"))"
  has WCONTENT "$OUT11B" && pass "(11) relative PATH from a subdir resolves correctly" \
    || bad "(11) subdir-relative pathspec did not match sub/wfile.txt"
  has "b/sub/wfile.txt" "$OUT11B" && pass "(11) subdir run still emits worktree-root-relative paths" \
    || bad "(11) subdir run emitted non-root-relative paths"
  has WTMOD "$OUT11B" && bad "(11) subdir PATH scope leaked out-of-scope mod.txt" \
    || pass "(11) subdir PATH scope excludes out-of-scope changes"
else
  bad "(11) git worktree add failed — cannot verify worktree behaviour"
fi

# ═════════════════════════════════════════════════════════════════════════════
# (12) install outcome + distribution invariant
# ═════════════════════════════════════════════════════════════════════════════
I="$ROOT/scripts/install.sh"
if [ -f "$HELPER" ] && [ -x "$HELPER" ]; then
  pass "(12) in-tree scripts/zuvo-home/build-review-patch present + executable"
else
  bad "(12) scripts/zuvo-home/build-review-patch missing or not +x in-repo"
fi

_T="$TMP/fakehome"; mkdir -p "$_T"
_LOG="$(HOME="$_T" bash -c '
  set -eo pipefail
  # Use the sourceable installer with its real helper dependencies and counters.
  # Extracting one function silently omitted newly composed helpers.
  source "$1"
  install_zuvo_home
' fixture "$I" 2>&1)"; _RC=$?
if [ "$_RC" -eq 0 ] && [ -f "$_T/.zuvo/build-review-patch" ] && [ -x "$_T/.zuvo/build-review-patch" ]; then
  pass "(12) install_zuvo_home lands build-review-patch +x in \$HOME/.zuvo"
else
  bad "(12) install rc=$_RC file=$([ -f "$_T/.zuvo/build-review-patch" ] && echo yes || echo NO) exec=$([ -x "$_T/.zuvo/build-review-patch" ] && echo yes || echo NO) log=$(printf '%s' "$_LOG" | tail -3 | tr '\n' '|')"
fi
has "build-review-patch installed" "$_LOG" && pass "(12) install log names build-review-patch" \
  || bad "(12) install log does not name build-review-patch"

# Distribution invariant: the per-platform build scripts must NOT copy zuvo-home
# helpers — they reach every platform via the shared ~/.zuvo dir only.
# Existence-gated (a bare `! grep` would PASS on a read error, exit 2 != 1).
BCX="$ROOT/scripts/build-codex-skills.sh"
BCU="$ROOT/scripts/build-cursor-skills.sh"
BAG="$ROOT/scripts/build-antigravity-skills.sh"
BKI="$ROOT/scripts/build-kimi-skills.sh"
if [ ! -f "$BCX" ] || [ ! -f "$BCU" ] || [ ! -f "$BAG" ] || [ ! -f "$BKI" ]; then
  bad "(12) expected all four build scripts present (codex=$([ -f "$BCX" ] && echo yes || echo NO) cursor=$([ -f "$BCU" ] && echo yes || echo NO) antigravity=$([ -f "$BAG" ] && echo yes || echo NO) kimi=$([ -f "$BKI" ] && echo yes || echo NO))"
elif grep -q 'build-review-patch' "$BCX" "$BCU" "$BAG" "$BKI"; then
  bad "(12) a per-platform build script references build-review-patch — distribution model violated"
else
  pass "(12) build scripts do NOT reference build-review-patch (shared ~/.zuvo invariant holds)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# (13) --base=<ref> equals-form is consumed exactly like the two-token form
# ═════════════════════════════════════════════════════════════════════════════
OUT13="$(cd "$R3" && "$HELPER" --base="$BASEREF" 2>"$TMP/e13")"; RC13=$?
[ "$RC13" -eq 0 ] && pass "(13) --base=<ref> equals-form exits 0" \
  || bad "(13) expected exit 0 for --base=<ref>, got $RC13 (stderr: $(tr '\n' '|' < "$TMP/e13"))"
has "+AFTERBASE" "$OUT13" && pass "(13) --base=<ref> spans committed-since-base work" \
  || bad "(13) --base=<ref> patch missing the committed-since-base change"
has "+WORKTREEONLY" "$OUT13" && pass "(13) --base=<ref> also spans uncommitted work" \
  || bad "(13) --base=<ref> patch missing the uncommitted change"

# (14) --base= with an EMPTY value must not degrade into a base-less diff
OUT14="$(cd "$R3" && "$HELPER" --base= 2>"$TMP/e14")"; RC14=$?
[ "$RC14" -eq 2 ] && pass "(14) --base= (empty value) exits 2" \
  || bad "(14) expected exit 2 for empty --base=, got $RC14"
[ -s "$TMP/e14" ] && pass "(14) empty --base= writes a stderr diagnostic" || bad "(14) empty --base= produced no stderr"
[ -z "$OUT14" ] && pass "(14) empty --base= emits no stdout" || bad "(14) empty --base= polluted stdout"

# ═════════════════════════════════════════════════════════════════════════════
# (15) PATH outside the repository root → exit 2 (never diff someone else's tree)
# ═════════════════════════════════════════════════════════════════════════════
OUT15="$(cd "$R1" && "$HELPER" ../../../../../etc 2>"$TMP/e15")"; RC15=$?
E15="$(cat "$TMP/e15")"
[ "$RC15" -eq 2 ] && pass "(15) PATH outside the repo root exits 2" \
  || bad "(15) expected exit 2 for an outside-root PATH, got $RC15"
has "outside the repository root" "$E15" && pass "(15) outside-root error names the violation on stderr" \
  || bad "(15) no 'outside the repository root' diagnostic (stderr: $(printf '%s' "$E15" | tr '\n' '|'))"
[ -z "$OUT15" ] && pass "(15) outside-root PATH emits no stdout" || bad "(15) outside-root PATH polluted stdout"

# ═════════════════════════════════════════════════════════════════════════════
# (16) -h / --help → exit 0 with the help text on STDOUT (an explicit request is
#      not a diagnostic), and no stray stderr noise
# ═════════════════════════════════════════════════════════════════════════════
OUT16="$(cd "$R1" && "$HELPER" -h 2>"$TMP/e16")"; RC16=$?
[ "$RC16" -eq 0 ] && pass "(16) -h exits 0" || bad "(16) expected exit 0 for -h, got $RC16"
has "Usage: build-review-patch" "$OUT16" && pass "(16) -h prints the help text on stdout" \
  || bad "(16) -h did not print help to stdout"

OUT16B="$(cd "$R1" && "$HELPER" --help 2>"$TMP/e16b")"; RC16B=$?
[ "$RC16B" -eq 0 ] && pass "(16) --help exits 0" || bad "(16) expected exit 0 for --help, got $RC16B"
has "Usage: build-review-patch" "$OUT16B" && pass "(16) --help prints the help text on stdout" \
  || bad "(16) --help did not print help to stdout"
has "ZUVO_REVIEW_PATCH_NO_UNTRACKED" "$OUT16B" && pass "(16) help documents the untracked env switch" \
  || bad "(16) help text omits ZUVO_REVIEW_PATCH_NO_UNTRACKED"

# ═════════════════════════════════════════════════════════════════════════════
# (17) deleted-file PATH arg: the path no longer resolves on disk (its whole
#      parent directory is gone), so canon_abs fails and the lexical fallback
#      must carry it — the deletion hunk still has to reach the patch.
# ═════════════════════════════════════════════════════════════════════════════
R7="$(new_repo r7)" || { bad "fixture init r7"; echo "SOME FAILED"; exit 1; }
(
  cd "$R7" || exit 1
  echo seed > seed.txt
  mkdir -p gone && printf 'DEADCONTENT\n' > gone/dead.txt
  git add -A && git commit -qm base
  rm -rf gone                                   # file AND its directory vanish
  echo SURVIVOR >> seed.txt                     # out-of-scope dirty file
) >/dev/null 2>&1
OUT17="$(cd "$R7" && "$HELPER" gone/dead.txt 2>"$TMP/e17")"; RC17=$?
[ "$RC17" -eq 0 ] && pass "(17) deleted-file PATH arg exits 0 (lexical fallback)" \
  || bad "(17) expected exit 0 for a deleted-file PATH, got $RC17 (stderr: $(tr '\n' '|' < "$TMP/e17"))"
has "-DEADCONTENT" "$OUT17" && pass "(17) deleted file's hunk present in the patch" \
  || bad "(17) deletion hunk for gone/dead.txt missing from patch"
has SURVIVOR "$OUT17" && bad "(17) deleted-file scope leaked the out-of-scope dirty file" \
  || pass "(17) deleted-file PATH still scopes the patch"

# ═════════════════════════════════════════════════════════════════════════════
# (18) empty-string PATH arg → exit 2 (regression: it used to canonicalise to
#      the repo root and silently WIDEN the review scope)
# ═════════════════════════════════════════════════════════════════════════════
EMPTY_SCOPE=""
OUT18="$(cd "$R1" && "$HELPER" "$EMPTY_SCOPE" 2>"$TMP/e18")"; RC18=$?
[ "$RC18" -eq 2 ] && pass "(18) empty-string PATH arg exits 2" \
  || bad "(18) expected exit 2 for an empty PATH arg, got $RC18"
[ -s "$TMP/e18" ] && pass "(18) empty PATH arg writes a stderr diagnostic" || bad "(18) empty PATH arg produced no stderr"
[ -z "$OUT18" ] && pass "(18) empty PATH arg emits no stdout (scope not widened)" \
  || bad "(18) empty PATH arg emitted a patch — scope silently widened"

( cd "$R1" && "$HELPER" -- "$EMPTY_SCOPE" ) >/dev/null 2>&1; RC18B=$?
[ "$RC18B" -eq 2 ] && pass "(18) empty PATH arg after -- also exits 2" \
  || bad "(18) expected exit 2 for an empty PATH after --, got $RC18B"

# ═════════════════════════════════════════════════════════════════════════════
# (19) unknown SINGLE-dash flag → exit 2 (regression: `-x` used to fall through
#      to the PATH branch and be treated as a filename)
# ═════════════════════════════════════════════════════════════════════════════
OUT19="$(cd "$R1" && "$HELPER" -x 2>"$TMP/e19")"; RC19=$?
E19="$(cat "$TMP/e19")"
[ "$RC19" -eq 2 ] && pass "(19) unknown single-dash flag -x exits 2" \
  || bad "(19) expected exit 2 for -x, got $RC19"
has "unknown flag" "$E19" && pass "(19) -x reports 'unknown flag' on stderr" \
  || bad "(19) -x did not produce an unknown-flag diagnostic"
[ -z "$OUT19" ] && pass "(19) unknown single-dash flag emits no stdout" || bad "(19) -x polluted stdout"

( cd "$R1" && "$HELPER" - >/dev/null 2>&1 ); RC19B=$?
[ "$RC19B" -eq 2 ] && pass "(19) bare '-' exits 2" || bad "(19) expected exit 2 for bare '-', got $RC19B"

# ═════════════════════════════════════════════════════════════════════════════
# (20) directory as a PATH arg: scopes the patch to that subtree
# ═════════════════════════════════════════════════════════════════════════════
R8="$(new_repo r8)" || { bad "fixture init r8"; echo "SOME FAILED"; exit 1; }
(
  cd "$R8" || exit 1
  mkdir -p pkg && echo a > pkg/in.txt && echo b > out.txt
  git add -A && git commit -qm base
  echo INDIRLINE >> pkg/in.txt                  # tracked change inside the dir
  printf 'INDIRNEW\n' > pkg/fresh.txt           # untracked inside the dir
  echo OUTDIRLINE >> out.txt                    # tracked change outside the dir
) >/dev/null 2>&1
OUT20="$(cd "$R8" && "$HELPER" pkg 2>"$TMP/e20")"; RC20=$?
[ "$RC20" -eq 0 ] && pass "(20) directory PATH arg exits 0" \
  || bad "(20) expected exit 0 for a directory PATH, got $RC20 (stderr: $(tr '\n' '|' < "$TMP/e20"))"
has INDIRLINE "$OUT20" && pass "(20) tracked change inside the directory included" \
  || bad "(20) pkg/in.txt hunk missing under directory scope"
has INDIRNEW "$OUT20" && pass "(20) untracked file inside the directory included" \
  || bad "(20) pkg/fresh.txt missing under directory scope"
has OUTDIRLINE "$OUT20" && bad "(20) directory scope leaked a change from outside the directory" \
  || pass "(20) directory scope excludes changes outside it"

# ═════════════════════════════════════════════════════════════════════════════
# (21) pathspec magic: a filename is a NAME, not a glob. A file literally named
#      `star*.txt` must scope to ITSELF — git's default pathspec matching is
#      wildcard-aware, so without --literal-pathspecs it would silently widen
#      the review to every star*.txt in the tree.
# ═════════════════════════════════════════════════════════════════════════════
R9="$(new_repo r9)" || { bad "fixture init r9"; echo "SOME FAILED"; exit 1; }
(
  cd "$R9" || exit 1
  echo seed > seed.txt
  printf 'lit\n' > 'star*.txt'
  printf 'decoy\n' > starDECOY.txt
  git add -A && git commit -qm base
  echo LITERALLINE >> 'star*.txt'
  echo GLOBBEDLINE >> starDECOY.txt
) >/dev/null 2>&1
OUT21="$(cd "$R9" && "$HELPER" 'star*.txt' 2>"$TMP/e21")"; RC21=$?
[ "$RC21" -eq 0 ] && pass "(21) literal-asterisk filename as PATH exits 0" \
  || bad "(21) expected exit 0 for 'star*.txt' PATH, got $RC21 (stderr: $(tr '\n' '|' < "$TMP/e21"))"
has LITERALLINE "$OUT21" && pass "(21) literal-asterisk filename scoped in" \
  || bad "(21) 'star*.txt' hunk missing — literal pathspec not matched"
has GLOBBEDLINE "$OUT21" && bad "(21) PATHSPEC GLOBBED — 'star*.txt' pulled in starDECOY.txt (scope silently widened)" \
  || pass "(21) 'star*.txt' did NOT glob-match starDECOY.txt"

# ═════════════════════════════════════════════════════════════════════════════
# (22) partially-staged file: ONE coherent set of hunks, not two overlapping
#      ones. `git diff` + `git diff --cached` describe the same region from two
#      different pre-images — the file would appear twice and the patch would
#      not apply. The single worktree-vs-HEAD snapshot must show the WORKTREE
#      content (v3), which is what a reviewer would actually be reviewing.
# ═════════════════════════════════════════════════════════════════════════════
R10="$(new_repo r10)" || { bad "fixture init r10"; echo "SOME FAILED"; exit 1; }
(
  cd "$R10" || exit 1
  printf 'VERSIONONE\n' > partial.txt && git add -A && git commit -qm base
  printf 'VERSIONTWO\n' > partial.txt && git add partial.txt   # staged v2
  printf 'VERSIONTHREE\n' > partial.txt                        # worktree v3
) >/dev/null 2>&1
OUT22="$(cd "$R10" && "$HELPER" 2>"$TMP/e22")"; RC22=$?
N22="$(printf '%s\n' "$OUT22" | grep -c '^diff --git a/partial\.txt b/partial\.txt' || true)"
[ "$RC22" -eq 0 ] && pass "(22) partially-staged file exits 0" \
  || bad "(22) expected exit 0 for a partially-staged file, got $RC22 (stderr: $(tr '\n' '|' < "$TMP/e22"))"
[ "$N22" -eq 1 ] && pass "(22) partially-staged file appears ONCE (single coherent hunk set)" \
  || bad "(22) partial.txt has $N22 'diff --git' headers — overlapping/duplicate hunks"
has "+VERSIONTHREE" "$OUT22" && pass "(22) patch carries the WORKTREE content (v3)" \
  || bad "(22) worktree content VERSIONTHREE missing from the patch"
has "-VERSIONONE" "$OUT22" && pass "(22) pre-image is HEAD (v1), i.e. staged+unstaged spanned coherently" \
  || bad "(22) expected the HEAD pre-image VERSIONONE as the removed side"

# ═════════════════════════════════════════════════════════════════════════════
# (23) UNBORN HEAD (git init, nothing committed): a first commit in progress is
#      still reviewable — the empty tree stands in for HEAD.
# ═════════════════════════════════════════════════════════════════════════════
R11="$(new_repo r11)" || { bad "fixture init r11"; echo "SOME FAILED"; exit 1; }
(
  cd "$R11" || exit 1
  printf 'STAGEDNEWFILE\n' > s.txt && git add s.txt
  printf 'UNTRACKEDNEWFILE\n' > u.txt
) >/dev/null 2>&1
OUT23="$(cd "$R11" && "$HELPER" 2>"$TMP/e23")"; RC23=$?
[ "$RC23" -eq 0 ] && pass "(23) unborn HEAD exits 0 (not an error, not 'no changes')" \
  || bad "(23) expected exit 0 on an unborn HEAD, got $RC23 (stderr: $(tr '\n' '|' < "$TMP/e23"))"
has STAGEDNEWFILE "$OUT23" && pass "(23) unborn HEAD: staged file present in the patch" \
  || bad "(23) unborn HEAD lost the staged file"
has UNTRACKEDNEWFILE "$OUT23" && pass "(23) unborn HEAD: untracked file present in the patch" \
  || bad "(23) unborn HEAD lost the untracked file"

# ═════════════════════════════════════════════════════════════════════════════
# (24) binary untracked file is the ONLY change → must NOT exit 3. Exiting 3
#      tells the caller "nothing to review" and a brand-new binary asset ships
#      completely unreviewed. A marker naming the path keeps it visible.
# ═════════════════════════════════════════════════════════════════════════════
R12="$(new_repo r12)" || { bad "fixture init r12"; echo "SOME FAILED"; exit 1; }
(
  cd "$R12" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  printf '\0\1\2\3' > only.bin
) >/dev/null 2>&1
OUT24="$(cd "$R12" && "$HELPER" 2>"$TMP/e24")"; RC24=$?
[ "$RC24" -eq 0 ] && pass "(24) binary-only change exits 0 (not 3 'no changes')" \
  || bad "(24) expected exit 0 when a binary untracked file is the only change, got $RC24"
has only.bin "$OUT24" && pass "(24) binary-only change names the path on stdout" \
  || bad "(24) only.bin absent from stdout — the file is invisible to the reviewer"
has "Binary files" "$OUT24" && bad "(24) raw binary diff leaked into stdout" \
  || pass "(24) binary marker used instead of a raw binary diff"

# ═════════════════════════════════════════════════════════════════════════════
# (25) empty untracked file is the ONLY change → same rule as (24). --no-index
#      renders nothing at all for an empty file, so it used to vanish silently.
# ═════════════════════════════════════════════════════════════════════════════
R13="$(new_repo r13)" || { bad "fixture init r13"; echo "SOME FAILED"; exit 1; }
(
  cd "$R13" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  : > placeholder.empty
) >/dev/null 2>&1
OUT25="$(cd "$R13" && "$HELPER" 2>"$TMP/e25")"; RC25=$?
[ "$RC25" -eq 0 ] && pass "(25) empty-file-only change exits 0 (not 3 'no changes')" \
  || bad "(25) expected exit 0 when an empty untracked file is the only change, got $RC25"
has placeholder.empty "$OUT25" && pass "(25) empty-file-only change names the path on stdout" \
  || bad "(25) placeholder.empty absent from stdout — the file is invisible to the reviewer"

# ═════════════════════════════════════════════════════════════════════════════
# (26) untracked NESTED REPOSITORY: ls-files reports it as a single `dir/`
#      entry, which `--no-index` cannot diff. It must not abort the run with a
#      git fatal — AND it must not vanish either: if it is the only change, a
#      stderr-only note leaves the patch empty, so the helper would exit 3
#      "no changes" and the caller would skip the review entirely.
# ═════════════════════════════════════════════════════════════════════════════
R14="$(new_repo r14)" || { bad "fixture init r14"; echo "SOME FAILED"; exit 1; }
(
  cd "$R14" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  # A REAL nested repo — that is what makes ls-files collapse the whole subtree
  # into one `nested/` entry. A bare `gitdir:` file is NOT enough: git then
  # still lists the inner files individually and the bug never triggers.
  mkdir -p nested && ( cd nested && git init -q . && printf 'nested payload\n' > inner.txt )
) >/dev/null 2>&1
# Guard against a silently vacuous fixture: if ls-files does not report `nested/`
# as a single entry, this test is not exercising the code path it claims to.
NESTED_ENTRY="$(git -C "$R14" ls-files --others --exclude-standard | grep -c '^nested/$' || true)"
[ "$NESTED_ENTRY" -eq 1 ] && pass "(26) fixture really produces a single 'nested/' ls-files entry" \
  || bad "(26) fixture is vacuous — ls-files did not collapse the nested repo into 'nested/'"
OUT26="$(cd "$R14" && "$HELPER" 2>"$TMP/e26")"; RC26=$?
E26="$(cat "$TMP/e26")"
[ "$RC26" -eq 0 ] && pass "(26) nested-repo-only change exits 0 (not 3 'no changes')" \
  || bad "(26) untracked nested repository gave rc=$RC26 (expected 0) — stderr: $(printf '%s' "$E26" | tr '\n' '|')"
has "fatal:" "$E26" && bad "(26) git fatal leaked from the untracked nested repository" \
  || pass "(26) no git fatal from the untracked nested repository"
has "b/nested/" "$OUT26" && pass "(26) nested-repo entry is VISIBLE on stdout as a marker" \
  || bad "(26) nested/ absent from stdout — the entry is invisible to the reviewer"
# The marker must not claim it is a reviewable new FILE — the reviewer has to be
# able to tell "content withheld because it is not a regular file" from
# "content withheld because it is binary/empty".
has "not a regular file" "$OUT26" && pass "(26) marker states WHY the contents are withheld" \
  || bad "(26) nested-repo marker does not distinguish itself from the binary/empty marker"
# Must also be reported as SKIPPED on stderr. The pre-fix helper listed `nested/`
# under "untracked files included in the patch" while contributing zero bytes —
# a false claim of coverage, exactly the silent-omission class this tool exists
# to prevent.
if has "nested/" "$E26" && has "skipping" "$E26"; then
  pass "(26) stderr reports the nested-repo entry as SKIPPED (no false claim of coverage)"
else
  bad "(26) nested repo not reported as skipped (stderr: $(printf '%s' "$E26" | tr '\n' '|'))"
fi

# ═════════════════════════════════════════════════════════════════════════════
# (27) flag-shaped --base value → exit 2 before it ever reaches git (otherwise
#      `--base --output=/tmp/x` is parsed by git as an OPTION, not a revision)
# ═════════════════════════════════════════════════════════════════════════════
OUT27="$(cd "$R1" && "$HELPER" --base -foo 2>"$TMP/e27")"; RC27=$?
E27="$(cat "$TMP/e27")"
[ "$RC27" -eq 2 ] && pass "(27) --base -foo exits 2" \
  || bad "(27) expected exit 2 for a flag-shaped --base, got $RC27"
[ -z "$OUT27" ] && pass "(27) flag-shaped --base emits no stdout" || bad "(27) flag-shaped --base polluted stdout"
has "must not start with" "$E27" && pass "(27) flag-shaped --base names the violation on stderr" \
  || bad "(27) no flag-shaped-ref diagnostic (stderr: $(printf '%s' "$E27" | tr '\n' '|'))"

( cd "$R1" && "$HELPER" --base=-foo >/dev/null 2>&1 ); RC27B=$?
[ "$RC27B" -eq 2 ] && pass "(27) --base=-foo equals-form also exits 2" \
  || bad "(27) expected exit 2 for --base=-foo, got $RC27B"

# ═════════════════════════════════════════════════════════════════════════════
# (28) marker header injection: a fabricated `diff --git` line that interpolates
#      the RAW filename can be forged/corrupted by a name containing a quote or
#      a newline. Real git C-quotes such paths; the marker must too.
# ═════════════════════════════════════════════════════════════════════════════
R15="$(new_repo r15)" || { bad "fixture init r15"; echo "SOME FAILED"; exit 1; }
WEIRD='od d"q.bin'
# A filename cannot contain '/', so the forgeable payload is a HUNK header —
# equally damaging: it corrupts the record boundaries of the surrounding patch.
NLNAME="$(printf 'inj\n@@ -1 +1 @@')"
(
  cd "$R15" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  printf '\0\1\2' > "$WEIRD"
  printf '\0\1\2' > "$NLNAME" 2>/dev/null || true
) >/dev/null 2>&1
OUT28="$(cd "$R15" && "$HELPER" 2>"$TMP/e28")"; RC28=$?
[ "$RC28" -eq 0 ] && pass "(28) awkward binary filenames exit 0" \
  || bad "(28) expected exit 0 with quote/newline binary filenames, got $RC28"
# A name containing `"` must appear C-quoted, exactly as git renders such paths.
has 'a/"od d\"q.bin"' "$OUT28" && pass "(28) quote-bearing name is C-quoted in the marker header" \
  || bad "(28) marker header interpolated the raw quote-bearing name (stdout: $(printf '%s' "$OUT28" | tr '\n' '|' | cut -c1-160))"
if [ -e "$R15/$NLNAME" ]; then
  # The forged record must NOT materialise as its own line in the patch stream.
  N28="$(printf '%s\n' "$OUT28" | grep -c '^@@ -1 +1 @@$' || true)"
  [ "$N28" -eq 0 ] && pass "(28) newline in a filename cannot forge a patch record" \
    || bad "(28) HEADER INJECTION — a filename newline produced $N28 forged '@@' line(s)"
  has '\n@@ -1 +1 @@' "$OUT28" && pass "(28) the newline is escaped inside the quoted path" \
    || bad "(28) newline-bearing name not escaped in the marker header (stdout: $(printf '%s' "$OUT28" | tr '\n' '|' | cut -c1-200))"
else
  printf 'SKIP: (28) newline-in-filename case skipped (filesystem rejected the name)\n'
fi

# ═════════════════════════════════════════════════════════════════════════════
# (29) untracked SYMLINK: `-f`/`-r`/`--no-index` all FOLLOW links, so a symlink
#      pointing outside the repo would embed the target's contents in the patch
#      — a scoping tool leaking files from outside its own scope. Skip it, but
#      keep the entry VISIBLE.
# ═════════════════════════════════════════════════════════════════════════════
R16="$(new_repo r16)" || { bad "fixture init r16"; echo "SOME FAILED"; exit 1; }
printf 'OUTSIDESECRET\n' > "$TMP/outside-secret.txt"
(
  cd "$R16" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  ln -s "$TMP/outside-secret.txt" escape.link
) >/dev/null 2>&1
OUT29="$(cd "$R16" && "$HELPER" 2>"$TMP/e29")"; RC29=$?
E29="$(cat "$TMP/e29")"
[ "$RC29" -eq 0 ] && pass "(29) symlink-only change exits 0 (not 3 'no changes')" \
  || bad "(29) expected exit 0 when an untracked symlink is the only change, got $RC29"
has OUTSIDESECRET "$OUT29" && bad "(29) SCOPE LEAK — symlink target's contents embedded in the patch" \
  || pass "(29) symlink target contents NOT embedded in the patch"
# Even where git renders a symlink as a mode-120000 blob (target PATH, not target
# CONTENTS), that absolute path is still filesystem information from outside the
# reviewed scope. A scoping tool must not emit it.
has "$TMP/outside-secret.txt" "$OUT29" && bad "(29) SCOPE LEAK — absolute out-of-repo target path emitted in the patch" \
  || pass "(29) out-of-repo symlink target path NOT emitted in the patch"
has escape.link "$OUT29" && pass "(29) symlink entry still visible on stdout as a marker" \
  || bad "(29) escape.link absent from stdout — the entry is invisible to the reviewer"
has symlink "$E29" && pass "(29) stderr explains the symlink was not followed" \
  || bad "(29) no stderr note about the skipped symlink"

# ═════════════════════════════════════════════════════════════════════════════
# (30) `--base ""` must be rejected exactly like `--base=` — an empty ref
#      reaches git as `^{commit}`, which quietly resolves to HEAD, so the caller
#      asks for a range review and silently gets a working-tree review.
# ═════════════════════════════════════════════════════════════════════════════
EMPTY_BASE=""
OUT30="$(cd "$R3" && "$HELPER" --base "$EMPTY_BASE" 2>"$TMP/e30")"; RC30=$?
[ "$RC30" -eq 2 ] && pass "(30) two-token --base \"\" exits 2" \
  || bad "(30) expected exit 2 for an empty two-token --base, got $RC30"
[ -z "$OUT30" ] && pass "(30) empty two-token --base emits no stdout" \
  || bad "(30) empty two-token --base emitted a patch — it silently degraded to a HEAD diff"
E30="$(cat "$TMP/e30")"
# The diagnostic must name the ACTUAL problem. Falling through to ref validation
# reports "not a commit-ish in this repository: " with an empty ref, which sends
# the caller hunting for a bad branch name instead of the unset variable.
has "requires a non-empty" "$E30" && pass "(30) empty two-token --base reports the empty value, not a bogus bad-ref" \
  || bad "(30) misleading diagnostic for an empty two-token --base (stderr: $(printf '%s' "$E30" | tr '\n' '|'))"

# ═════════════════════════════════════════════════════════════════════════════
# (31) patch-buffer write failures must be LOUD. An unchecked `>>` turns a full
#      disk into a SHORT patch emitted with exit 0 — the reviewer reviews a
#      partial diff believing it complete. Simulated by making the scratch dir
#      read-only via a tiny TMPDIR harness.
# ═════════════════════════════════════════════════════════════════════════════
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: (31) write-failure case skipped (running as root)\n'
else
  # Every append to the patch buffer is guarded; assert the guard exists on each
  # one rather than only on the first (a half-guarded buffer is still silent).
  UNGUARDED="$(grep -n '>> "\$OUTF"' "$HELPER" | grep -vc '||' || true)"
  [ "$UNGUARDED" -eq 0 ] && pass "(31) every '>> \$OUTF' append is failure-checked" \
    || bad "(31) $UNGUARDED unguarded '>> \$OUTF' append(s) — a write error would truncate the patch silently"
  has 'cat "$OUTF" ||' "$(cat "$HELPER")" && pass "(31) the final patch write to stdout is failure-checked" \
    || bad "(31) final 'cat \$OUTF' to stdout is unchecked"

  # Behavioural: an unwritable patch buffer must exit 2 with a diagnostic, never
  # exit 0 with a truncated patch.
  R17="$(new_repo r17)" || { bad "fixture init r17"; echo "SOME FAILED"; exit 1; }
  (
    cd "$R17" || exit 1
    echo seed > seed.txt && git add -A && git commit -qm base
    printf 'BIGCONTENT\n' > untracked-a.txt
    printf 'MORECONTENT\n' > untracked-b.txt
  ) >/dev/null 2>&1
  # BSD mktemp ignores TMPDIR unless -t is used, so the scratch dir is forced via
  # a PATH shim instead — portable across macOS and GNU coreutils.
  SHIMDIR="$TMP/shim"; mkdir -p "$SHIMDIR"
  RODIR="$TMP/rodir"; mkdir -p "$RODIR"; chmod 500 "$RODIR"
  printf '#!/bin/sh\nprintf %%s\\\\n "%s"\n' "$RODIR" > "$SHIMDIR/mktemp"
  chmod +x "$SHIMDIR/mktemp"
  OUT31="$(cd "$R17" && PATH="$SHIMDIR:$PATH" "$HELPER" 2>"$TMP/e31")"; RC31=$?
  chmod 700 "$RODIR" 2>/dev/null
  [ "$RC31" -eq 2 ] && pass "(31) unwritable scratch dir exits 2 (never a silent short patch)" \
    || bad "(31) expected exit 2 with an unwritable scratch dir, got $RC31"
  [ -z "$OUT31" ] && pass "(31) unwritable scratch dir emits no stdout" \
    || bad "(31) unwritable scratch dir still emitted a (necessarily partial) patch"
  [ -s "$TMP/e31" ] && pass "(31) unwritable scratch dir writes a stderr diagnostic" \
    || bad "(31) unwritable scratch dir produced no stderr"
fi

# ═════════════════════════════════════════════════════════════════════════════
# (32) the ZUVO_REVIEW_PATCH_NO_UNTRACKED footgun is DISCOVERABLE: only the
#      exact value "1" disables untracked files, so the help must say so.
# ═════════════════════════════════════════════════════════════════════════════
OUT32="$(cd "$R1" && "$HELPER" --help 2>/dev/null)"
has 'exact value "1"' "$OUT32" && pass "(32) help states that ONLY \"1\" disables untracked files" \
  || bad "(32) help does not document the exact accepted value for ZUVO_REVIEW_PATCH_NO_UNTRACKED"
OUT32B="$(cd "$R1" && ZUVO_REVIEW_PATCH_NO_UNTRACKED=true "$HELPER" 2>/dev/null)"
has NEWFILECONTENT "$OUT32B" && pass "(32) a non-\"1\" value fails OPEN (untracked still reviewed)" \
  || bad "(32) ZUVO_REVIEW_PATCH_NO_UNTRACKED=true silently shrank the reviewed surface"

# ═════════════════════════════════════════════════════════════════════════════
# (33) exit 3 must mean "the paths resolved and nothing changed" — NEVER "your
#      paths matched nothing". Conflating the two turns a caller typo, a renamed
#      file, or a space-joined argument list into a silently skipped review,
#      which is the one failure mode this whole helper exists to eliminate.
# ═════════════════════════════════════════════════════════════════════════════
R18="$(new_repo r18)" || { bad "fixture init r18"; echo "SOME FAILED"; exit 1; }
(
  cd "$R18" || exit 1
  echo a > a.txt && echo b > b.txt && echo c > c.txt
  git add -A && git commit -qm base
  echo CHANGEDLINE >> c.txt                     # the ONLY change in the repo
) >/dev/null 2>&1

# (33a) a single nonexistent path is a BAD REQUEST, not a clean scope
OUT33A="$(cd "$R18" && "$HELPER" nosuch.txt 2>"$TMP/e33a")"; RC33A=$?
E33A="$(cat "$TMP/e33a")"
[ "$RC33A" -eq 2 ] && pass "(33a) nonexistent PATH exits 2, not 3" \
  || bad "(33a) expected exit 2 for a nonexistent PATH, got $RC33A — a typo is being reported as 'nothing to review'"
has nosuch.txt "$E33A" && pass "(33a) the unmatched path is NAMED on stderr" \
  || bad "(33a) stderr does not name the unmatched path (stderr: $(printf '%s' "$E33A" | tr '\n' '|'))"
[ -z "$OUT33A" ] && pass "(33a) nonexistent PATH emits no stdout" || bad "(33a) nonexistent PATH polluted stdout"

# (33b) THE zsh case: two real paths collapsed into ONE space-joined argument.
#       "a.txt b.txt" is a legal (nonexistent) filename, so this used to look
#       exactly like a clean tree while `git status` showed changes.
JOINED="a.txt b.txt"
OUT33B="$(cd "$R18" && "$HELPER" "$JOINED" 2>"$TMP/e33b")"; RC33B=$?
E33B="$(cat "$TMP/e33b")"
[ "$RC33B" -eq 2 ] && pass "(33b) space-joined path list exits 2, not 3" \
  || bad "(33b) expected exit 2 for a space-joined list, got $RC33B — the zsh joined-list case still looks clean"
has "SEPARATE arguments" "$E33B" && pass "(33b) stderr explains the joined-list cause" \
  || bad "(33b) stderr does not mention the space-joined-argument cause (stderr: $(printf '%s' "$E33B" | tr '\n' '|'))"
[ -z "$OUT33B" ] && pass "(33b) space-joined path list emits no stdout" || bad "(33b) space-joined list polluted stdout"

# (33c) a REAL path that genuinely has no changes → exit 3 is still correct
OUT33C="$(cd "$R18" && "$HELPER" a.txt 2>"$TMP/e33c")"; RC33C=$?
[ "$RC33C" -eq 3 ] && pass "(33c) resolvable-but-unchanged PATH still exits 3" \
  || bad "(33c) expected exit 3 for a real unchanged PATH, got $RC33C — exit 3 must still mean 'clean'"
[ -z "$OUT33C" ] && pass "(33c) unchanged PATH emits empty stdout" || bad "(33c) unchanged PATH emitted stdout"

# (33d) one real + one nonexistent → fail LOUD rather than silently reviewing
#       the subset the caller did not ask for
( cd "$R18" && "$HELPER" a.txt nosuch.txt ) >/dev/null 2>"$TMP/e33d"; RC33D=$?
E33D="$(cat "$TMP/e33d")"
[ "$RC33D" -eq 2 ] && pass "(33d) mixed real + nonexistent PATHs exit 2" \
  || bad "(33d) expected exit 2 for a partially-unmatched path list, got $RC33D — the bad path was silently dropped"
has nosuch.txt "$E33D" && pass "(33d) stderr names only the offending path" \
  || bad "(33d) stderr does not name the offending path in a mixed list"

# (33e) no-PATH mode is unaffected: a clean tree is legitimately exit 3
( cd "$R2" && "$HELPER" ) >/dev/null 2>"$TMP/e33e"; RC33E=$?
[ "$RC33E" -eq 3 ] && pass "(33e) no-PATH mode on a clean tree still exits 3" \
  || bad "(33e) expected exit 3 for no-PATH mode on a clean tree, got $RC33E"

# (33f) the check must not over-block: a resolvable path WITH changes still 0
OUT33F="$(cd "$R18" && "$HELPER" c.txt 2>"$TMP/e33f")"; RC33F=$?
[ "$RC33F" -eq 0 ] && pass "(33f) resolvable PATH with changes still exits 0" \
  || bad "(33f) expected exit 0 for a changed in-scope PATH, got $RC33F (stderr: $(tr '\n' '|' < "$TMP/e33f"))"
has CHANGEDLINE "$OUT33F" && pass "(33f) the in-scope change is still emitted" \
  || bad "(33f) resolvability check swallowed a real change"

# (33g) --base mode: a path that exists ONLY in the base ref (deleted and
#       committed since) must still resolve — its deletion is the review target
R19="$(new_repo r19)" || { bad "fixture init r19"; echo "SOME FAILED"; exit 1; }
(
  cd "$R19" || exit 1
  echo keep > keep.txt && printf 'GONECONTENT\n' > goner.txt
  git add -A && git commit -qm base
) >/dev/null 2>&1
BASEREF19="$(git -C "$R19" rev-parse HEAD)"
( cd "$R19" && git rm -q goner.txt && git commit -qm drop ) >/dev/null 2>&1
OUT33G="$(cd "$R19" && "$HELPER" --base "$BASEREF19" goner.txt 2>"$TMP/e33g")"; RC33G=$?
[ "$RC33G" -eq 0 ] && pass "(33g) --base: base-only path resolves (deletion is reviewable)" \
  || bad "(33g) expected exit 0 for a base-only path, got $RC33G (stderr: $(tr '\n' '|' < "$TMP/e33g"))"
has "-GONECONTENT" "$OUT33G" && pass "(33g) --base: the deletion hunk is emitted" \
  || bad "(33g) --base: deletion hunk for goner.txt missing"

# (33h) the help text documents the disambiguated contract
OUT33H="$(cd "$R18" && "$HELPER" --help 2>/dev/null)"
has "matches nothing" "$OUT33H" && pass "(33h) help documents 'matches nothing' as exit 2" \
  || bad "(33h) help does not document unmatched paths as exit 2"
has "Never means" "$OUT33H" && pass "(33h) help states exit 3 never means 'matched nothing'" \
  || bad "(33h) help does not disambiguate exit 3"

# ═════════════════════════════════════════════════════════════════════════════
# (34) DELETIONS are known paths. `git rm` removes the index entry outright, so
#      an ls-files-only resolvability probe rejects a staged deletion — refusing
#      to review a commit that removes a file, which is completely ordinary.
#      The rule: exit 2 means "git knows nothing about this path", NOT "this
#      path is gone from disk".
# ═════════════════════════════════════════════════════════════════════════════
R20="$(new_repo r20)" || { bad "fixture init r20"; echo "SOME FAILED"; exit 1; }
(
  cd "$R20" || exit 1
  printf 'STAGEDGONE\n' > sgone.txt
  printf 'WORKTREEGONE\n' > wgone.txt
  printf 'untouched\n' > steady.txt
  git add -A && git commit -qm base
  git rm -q sgone.txt            # staged deletion — index entry REMOVED
  rm wgone.txt                   # worktree-only deletion — index entry survives
) >/dev/null 2>&1

# Fixture guard: assert the two deletions really differ in index state, so the
# test cannot pass vacuously if `git rm` semantics ever change.
[ -z "$(git -C "$R20" ls-files -- sgone.txt)" ] && pass "(34) fixture: 'git rm' really removed the index entry" \
  || bad "(34) fixture vacuous — sgone.txt still has an index entry, the regression path is untested"
[ -n "$(git -C "$R20" ls-files -- wgone.txt)" ] && pass "(34) fixture: plain 'rm' really left the index entry" \
  || bad "(34) fixture unexpected — wgone.txt lost its index entry"

# (34a) staged deletion → reviewable, not a bad request
OUT34A="$(cd "$R20" && "$HELPER" sgone.txt 2>"$TMP/e34a")"; RC34A=$?
[ "$RC34A" -eq 0 ] && pass "(34a) staged deletion (git rm) exits 0, not 2" \
  || bad "(34a) expected exit 0 for a staged deletion, got $RC34A (stderr: $(tr '\n' '|' < "$TMP/e34a"))"
has "-STAGEDGONE" "$OUT34A" && pass "(34a) staged deletion hunk present in the patch" \
  || bad "(34a) staged deletion hunk for sgone.txt missing from the patch"

# (34b) worktree-only deletion → reviewable
OUT34B="$(cd "$R20" && "$HELPER" wgone.txt 2>"$TMP/e34b")"; RC34B=$?
[ "$RC34B" -eq 0 ] && pass "(34b) worktree-only deletion (plain rm) exits 0" \
  || bad "(34b) expected exit 0 for a worktree-only deletion, got $RC34B (stderr: $(tr '\n' '|' < "$TMP/e34b"))"
has "-WORKTREEGONE" "$OUT34B" && pass "(34b) worktree-only deletion hunk present in the patch" \
  || bad "(34b) worktree deletion hunk for wgone.txt missing from the patch"

# (34c) the guard is not weakened: a genuinely unknown path still exits 2, and a
#       resolvable-but-unchanged path still exits 3, in the SAME repo that has
#       deletions pending (so the new branches cannot be blanket-accepting).
( cd "$R20" && "$HELPER" never-existed.txt >/dev/null 2>&1 ); RC34C=$?
[ "$RC34C" -eq 2 ] && pass "(34c) unknown path still exits 2 alongside pending deletions" \
  || bad "(34c) expected exit 2 for an unknown path, got $RC34C — the deletion probes over-accept"
( cd "$R20" && "$HELPER" "sgone.txt wgone.txt" >/dev/null 2>&1 ); RC34D=$?
[ "$RC34D" -eq 2 ] && pass "(34c) space-joined list of two DELETED paths still exits 2" \
  || bad "(34c) expected exit 2 for a joined list of deleted paths, got $RC34D"
( cd "$R20" && "$HELPER" steady.txt >/dev/null 2>&1 ); RC34E=$?
[ "$RC34E" -eq 3 ] && pass "(34c) resolvable-but-unchanged path still exits 3" \
  || bad "(34c) expected exit 3 for an unchanged path, got $RC34E"

# ═════════════════════════════════════════════════════════════════════════════
# (35) REFUTED CLAIM, pinned so it cannot resurface: "a directory pathspec with a
#      trailing slash never matches because the slash is stripped". Both forms
#      must behave identically — canon_abs resolves a directory to its physical
#      path, which carries no trailing slash either way.
# ═════════════════════════════════════════════════════════════════════════════
R21="$(new_repo r21)" || { bad "fixture init r21"; echo "SOME FAILED"; exit 1; }
(
  cd "$R21" || exit 1
  mkdir -p sub && echo a > sub/in.txt && echo b > out.txt
  git add -A && git commit -qm base
  echo SUBDIRLINE >> sub/in.txt
) >/dev/null 2>&1
OUT35A="$(cd "$R21" && "$HELPER" sub 2>/dev/null)"; RC35A=$?
OUT35B="$(cd "$R21" && "$HELPER" sub/ 2>/dev/null)"; RC35B=$?
if [ "$RC35A" -eq 0 ] && [ "$RC35B" -eq "$RC35A" ] && [ "$OUT35A" = "$OUT35B" ]; then
  pass "(35) 'sub' and 'sub/' are byte-identical (trailing-slash claim refuted, pinned)"
else
  bad "(35) trailing slash changes behaviour: rc 'sub'=$RC35A 'sub/'=$RC35B, output identical=$([ "$OUT35A" = "$OUT35B" ] && echo yes || echo NO)"
fi
has SUBDIRLINE "$OUT35B" && pass "(35) trailing-slash directory pathspec still scopes in the change" \
  || bad "(35) 'sub/' lost the in-scope change"

# ═════════════════════════════════════════════════════════════════════════════
# (36-41) lifecycle context: a changed hunk in a tracked shell script whose
#      post-image defines a trap, a cleanup-named function or a trap handler gets
#      those definitions appended after the file's last hunk, in a block no
#      patch reader can take for diff content.
# ═════════════════════════════════════════════════════════════════════════════
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
LC_BASE_PROLOG='cleanup(){ kill -- -"$pg"; }
trap cleanup EXIT INT TERM'
LC_SIG_PROLOG='on_sig() {
  printf '"'"'caught\n'"'"' >&2
  exit 130
}
trap on_sig INT'
# Any block line starting like this is read as diff content or a section start by git or the adversarial splitter.
LC_FORBIDDEN='^(diff --git |=== FILE: |@@|[-+ \\]|##)'

# lc_repo <name> <path> <shebang|""> <prolog> <changed line> — a committed script: <shebang>, <prolog>, 30 filler
# lines, `: change point`, 10 filler lines; the worktree then has <changed line> in place of `: change point`.
lc_repo() {
  local d
  d="$(new_repo "$1")" || return 1
  (
    cd "$d" || exit 1
    case "$2" in */*) mkdir -p "${2%/*}" ;; esac
    {
      [ -z "$3" ] || printf '%s\n' "$3"
      printf '%s\n' "$4"
      i=1; while [ "$i" -le 30 ]; do printf ': filler %d\n' "$i"; i=$((i + 1)); done
      printf ': change point\n'
      i=31; while [ "$i" -le 40 ]; do printf ': filler %d\n' "$i"; i=$((i + 1)); done
    } > "$2"
    git add -A && git commit -qm base
    awk -v new="$5" '$0 == ": change point" { print new; next } { print }' "$2" > "$2.new" && mv "$2.new" "$2"
  ) >/dev/null 2>&1 || return 1
  printf '%s\n' "$d"
}
# lc_block <patch text> — every context block in it, opening and closing lines included.
lc_block() { printf '%s\n' "$1" | awk '/^=== CONTEXT: /{ f = 1 } f { print } /^=== END CONTEXT ===$/{ f = 0 }'; }
# lc_func_lines <n> <name> <pad> — a function <name> with <n> body lines, each about <pad> characters long.
lc_func_lines() {
  awk -v n="$1" -v name="$2" -v pad="$3" 'BEGIN {
    printf "%s() {\n", name
    for (i = 1; i <= n; i++) { l = sprintf("  : %s body line %d", name, i); while (length(l) < pad) l = l " x"; print l }
    print "}" }'
}

# lc_row_block <label> <repo> <path> <bug> <want>... — the patch carries <path>'s block holding every <want> line.
lc_row_block() {
  local label="$1" repo="$2" path="$3" bug="$4" out blk w miss=""
  shift 4
  out="$(cd "$repo" && "$HELPER" 2>/dev/null)"
  blk="$(lc_block "$out")"
  has "=== CONTEXT: $path - " "$blk" || { bad "$label — no context block for $path; $bug"; return; }
  for w in "$@"; do
    printf '%s\n' "$blk" | grep -qxF -- "$w" || miss="$miss [$w]"
  done
  [ -z "$miss" ] && pass "$label" || bad "$label — the block lacks$miss; $bug"
}
# lc_row_no_block <label> <repo> <want in patch> <bug> — the patch (rc 0, holding <want>) carries no context block.
lc_row_no_block() {
  local out rc
  out="$(cd "$2" && "$HELPER" 2>/dev/null)"; rc=$?
  if [ "$rc" -ne 0 ] || ! has "$3" "$out"; then
    bad "$1 — fixture vacuous: rc=$rc, patch lacks '$3'"
  elif has "=== CONTEXT: " "$out"; then
    bad "$1 — $4"
  else
    pass "$1"
  fi
}

# (36) the block exists, with line numbers, whenever the script defines lifecycle code
R36A="$(lc_repo lc36a dev.sh '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'setsid npm run dev:stack &')"
lc_row_block "(36a) a background job beside a trap: the trap and the cleanup body travel with the hunk" "$R36A" dev.sh \
  "a reviewer cannot tell whether the job is ever reaped" \
  '2: cleanup(){ kill -- -"$pg"; }' '3: trap cleanup EXIT INT TERM'
R36B="$(lc_repo lc36b dev.sh '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_block "(36b) a changed line with no lifecycle token still gets the script's definitions" "$R36B" dev.sh \
  "the trigger is a token heuristic on the changed line, not the script's definitions" \
  '3: trap cleanup EXIT INT TERM'
R36C="$(lc_repo lc36c bin/run-dev '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'setsid npm run dev:stack &')"
lc_row_block "(36c) an extensionless script is recognised by its env-bash shebang" "$R36C" bin/run-dev \
  "shell detection reads only the extension" '3: trap cleanup EXIT INT TERM'
R36D="$(lc_repo lc36d tools/start '#!/bin/sh' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_block "(36d) an extensionless script is recognised by its /bin/sh shebang" "$R36D" tools/start \
  "only an env-style shebang is recognised" '3: trap cleanup EXIT INT TERM'
R36E="$(lc_repo lc36e sig.sh '#!/usr/bin/env bash' "$LC_SIG_PROLOG" 'echo hi')"
lc_row_block "(36e) a trap handler that is not cleanup-named has its whole body included" "$R36E" sig.sh \
  "only cleanup-named functions are collected" \
  '2: on_sig() {' "3:   printf 'caught\\n' >&2" '4:   exit 130' '5: }' '6: trap on_sig INT'

# (37) no block where it adds nothing
R37A="$(lc_repo lc37a app.ts '' "$LC_BASE_PROLOG" 'setsid npm run dev:stack &')"
lc_row_no_block "(37a) a .ts file never gets a block" "$R37A" '+setsid npm run dev:stack &' \
  "a non-shell file was annotated"
R37B="$(lc_repo lc37b py-tool '#!/usr/bin/env python3' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_no_block "(37b) an extensionless script with a python shebang never gets a block" "$R37B" '+echo hi' \
  "a shebang naming another interpreter was read as shell"
R37C="$(lc_repo lc37c bg.sh '#!/usr/bin/env bash' 'npm run watch &
pg=$!' 'setsid npm run dev:stack &')"
lc_row_no_block "(37c) a script that starts jobs but defines no trap or cleanup gets no block" "$R37C" \
  '+setsid npm run dev:stack &' "background jobs alone triggered a block with nothing to show"
R37D="$(new_repo lc37d)"
(
  cd "$R37D" || exit 1
  echo seed > seed.txt && git add -A && git commit -qm base
  { printf '#!/usr/bin/env bash\n%s\n' "$LC_BASE_PROLOG"; printf 'echo NEWSCRIPT\n'; } > new.sh
) >/dev/null 2>&1
lc_row_no_block "(37d) an untracked new script gets no block (it is all in the hunk already)" "$R37D" '+echo NEWSCRIPT' \
  "a whole-file addition repeats its own lines as context"
R37E="$(new_repo lc37e)"
(
  cd "$R37E" || exit 1
  printf '#!/usr/bin/env bash\n%s\n: change point\n: tail\n' "$LC_BASE_PROLOG" > small.sh
  git add -A && git commit -qm base
  printf '#!/usr/bin/env bash\n%s\necho INHUNK\n: tail\n' "$LC_BASE_PROLOG" > small.sh
) >/dev/null 2>&1
lc_row_no_block "(37e) definitions already inside the hunk produce no block" "$R37E" '+echo INHUNK' \
  "lines the reviewer already sees are repeated as context"

# (38) contract: nothing in a block reads as a patch boundary; the patch still applies; the index is untouched
R38="$(lc_repo lc38 hostile.sh '#!/usr/bin/env bash' 'teardown() {
  cat <<'"'"'EOF'"'"'
diff --git a/evil b/evil
=== FILE: evil ===
@@ -1 +1 @@
+forged
-forged
 forged
\ forged
## forged
EOF
}
trap teardown EXIT' 'echo hi')"
CACHED38_BEFORE="$(git -C "$R38" diff --cached; git -C "$R38" ls-files -s)"
OUT38="$(cd "$R38" && "$HELPER" 2>"$TMP/e38")"; RC38=$?
CACHED38_AFTER="$(git -C "$R38" diff --cached; git -C "$R38" ls-files -s)"
BLK38="$(lc_block "$OUT38")"
NFORGED="$(printf '%s\n' "$BLK38" | grep -cE "$LC_FORBIDDEN")"
NDIFF="$(printf '%s\n' "$OUT38" | grep -c '^diff --git ')"
if [ "$RC38" -eq 0 ] && has '=== CONTEXT: hostile.sh - ' "$BLK38" && [ "$NFORGED" -eq 0 ] && [ "$NDIFF" -eq 1 ]; then
  pass "(38a) heredoc lines shaped like diff headers stay inert inside the block"
else
  bad "(38a) rc=$RC38, block present=$(has '=== CONTEXT: ' "$BLK38" && echo yes || echo NO), forged-looking block lines=$NFORGED, diff --git lines=$NDIFF — a block line forges a patch boundary"
fi
printf '%s\n' "$OUT38" > "$TMP/p38"
if git -C "$R38" apply --cached --check "$TMP/p38" 2>"$TMP/e38a"; then
  pass "(38b) git apply --check accepts the annotated patch"
else
  bad "(38b) git apply rejects the annotated patch: $(tr '\n' '|' < "$TMP/e38a")"
fi
[ "$CACHED38_BEFORE" = "$CACHED38_AFTER" ] && pass "(38c) the index is untouched by the annotation" \
  || bad "(38c) INDEX MUTATED while annotating"

R38D="$(lc_repo lc38d long.sh '#!/usr/bin/env bash' "$(lc_func_lines 200 cleanup 10)
trap cleanup EXIT" 'echo hi')"
BLK38D="$(lc_block "$(cd "$R38D" && "$HELPER" 2>/dev/null)")"
N38D="$(printf '%s\n' "$BLK38D" | grep -cE '^[0-9]+: (cleanup[(][)] [{]|  : cleanup body line )')"
if [ "$N38D" -eq 40 ] && printf '%s\n' "$BLK38D" | grep -q '^\.\.\. '; then
  pass "(38d) a 200-line cleanup is cut to exactly 40 lines with an omission line"
else
  bad "(38d) cleanup lines in the block: $N38D (want 40) plus a '... ' omission line — the per-function cap is wrong"
fi
# Short lines: the 80-line cap binds first, and the block fills it exactly.
R38E="$(lc_repo lc38e many.sh '#!/usr/bin/env bash' "$(lc_func_lines 200 cleanup_db 10)
$(lc_func_lines 200 teardown 10)
$(lc_func_lines 200 stop_all 10)
trap cleanup_db EXIT" 'echo hi')"
BLK38E="$(lc_block "$(cd "$R38E" && "$HELPER" 2>/dev/null)")"
L38E="$(printf '%s\n' "$BLK38E" | wc -l | tr -d ' ')"
if [ "$L38E" -eq 80 ] && printf '%s\n' "$BLK38E" | grep -q '^\.\.\. .* more context lines'; then
  pass "(38e) short lines: the block is cut at exactly 80 lines and says what it left out"
else
  bad "(38e) block lines=$L38E (want 80 with a '... N more context lines' line) — the per-file line cap is wrong"
fi
# Long lines: the 4000-character cap binds first; the block ends just under it, not far below.
R38F="$(lc_repo lc38f huge.sh '#!/usr/bin/env bash' "$(lc_func_lines 200 cleanup_db 70)
$(lc_func_lines 200 teardown 70)
$(lc_func_lines 200 stop_all 70)
trap cleanup_db EXIT" 'echo hi')"
BLK38F="$(lc_block "$(cd "$R38F" && "$HELPER" 2>/dev/null)")"
C38F="$(printf '%s\n' "$BLK38F" | wc -c | tr -d ' ')"
if [ "$C38F" -gt 3700 ] && [ "$C38F" -le 4000 ] && printf '%s\n' "$BLK38F" | grep -q '^\.\.\. .* more context lines'; then
  pass "(38f) long lines: the block stops between 3700 and 4000 characters and says what it left out"
else
  bad "(38f) block chars=$C38F (want 3701..4000 with a '... N more context lines' line) — the per-file character cap is wrong"
fi

# (39) opt-out: only the exact value 1 removes the block
OUT39A="$(cd "$R36A" && ZUVO_REVIEW_PATCH_NO_CONTEXT=1 "$HELPER" 2>/dev/null)"
OUT39B="$(cd "$R36A" && ZUVO_REVIEW_PATCH_NO_CONTEXT=yes "$HELPER" 2>/dev/null)"
if has '+setsid npm run dev:stack &' "$OUT39A" && ! has '=== CONTEXT: ' "$OUT39A"; then
  pass "(39a) ZUVO_REVIEW_PATCH_NO_CONTEXT=1 emits the plain patch"
else
  bad "(39a) ZUVO_REVIEW_PATCH_NO_CONTEXT=1 still annotated (or lost the hunk)"
fi
has '=== CONTEXT: dev.sh - ' "$OUT39B" && pass "(39b) ZUVO_REVIEW_PATCH_NO_CONTEXT=yes keeps the block (only 1 opts out)" \
  || bad "(39b) a non-1 value silently dropped the lifecycle context"

# (40) fail-open: the annotation can only ever add; a failure leaves the plain patch, exit 0, a warning
PLAIN36A="$(cd "$R36A" && ZUVO_REVIEW_PATCH_NO_CONTEXT=1 "$HELPER" 2>/dev/null)"
SHIM40="$TMP/lc-awk-shim"; mkdir -p "$SHIM40"
printf '#!/bin/sh\nexit 2\n' > "$SHIM40/awk"; chmod +x "$SHIM40/awk"
OUT40A="$(cd "$R36A" && PATH="$SHIM40:$PATH" "$HELPER" 2>"$TMP/e40a")"; RC40A=$?
if [ "$RC40A" -eq 0 ] && [ "$OUT40A" = "$PLAIN36A" ] && [ -s "$TMP/e40a" ]; then
  pass "(40a) a failing annotation leaves the plain patch, exit 0, with a stderr warning"
else
  bad "(40a) rc=$RC40A, plain patch=$([ "$OUT40A" = "$PLAIN36A" ] && echo yes || echo NO), stderr=$(tr '\n' '|' < "$TMP/e40a") — an annotation failure must not cost the patch or pass silently"
fi
if [ "$(id -u)" -eq 0 ]; then
  printf 'SKIP: (40b) unreadable post-image case skipped (running as root)\n'
else
  # core.trustctime=false + an old mtime keep git's stat check passing after chmod 000, so git still emits a
  # diff for the file (rc 0) while the annotation cannot read the post-image.
  R40="$(new_repo lc40)"
  (
    cd "$R40" || exit 1
    git config core.trustctime false
    printf '#!/usr/bin/env bash\n%s\n' "$LC_BASE_PROLOG" > locked.sh
    i=1; while [ "$i" -le 20 ]; do printf ': filler %d\n' "$i" >> locked.sh; i=$((i + 1)); done
    touch -t 202001010000 locked.sh && git add -A && git commit -qm base
    printf 'echo LOCKEDCHANGE\n' >> locked.sh
    touch -t 202001010100 locked.sh && git add locked.sh
    chmod 000 locked.sh
  ) >/dev/null 2>&1
  OUT40B="$(cd "$R40" && "$HELPER" 2>"$TMP/e40b")"; RC40B=$?
  PLAIN40="$(cd "$R40" && ZUVO_REVIEW_PATCH_NO_CONTEXT=1 "$HELPER" 2>/dev/null)"
  chmod 644 "$R40/locked.sh" 2>/dev/null
  if [ "$RC40B" -eq 0 ] && has '+++ b/locked.sh' "$OUT40B" && [ "$OUT40B" = "$PLAIN40" ] \
     && grep -q 'locked.sh' "$TMP/e40b"; then
    pass "(40b) an unreadable post-image: plain patch, exit 0, a warning naming the file"
  else
    bad "(40b) rc=$RC40B, file in patch=$(has '+++ b/locked.sh' "$OUT40B" && echo yes || echo NO), plain=$([ "$OUT40B" = "$PLAIN40" ] && echo yes || echo NO), stderr=$(tr '\n' '|' < "$TMP/e40b") — want the plain patch and a warning naming locked.sh"
  fi
fi

# (41) cross-check with the adversarial driver: a file split at its hunks carries the block into every part
R41="$(new_repo lc41)"
(
  cd "$R41" || exit 1
  {
    printf '#!/usr/bin/env bash\n%s\n' "$LC_BASE_PROLOG"
    for k in 1 2 3; do
      i=1; while [ "$i" -le 20 ]; do printf ': filler %d.%d\n' "$k" "$i"; i=$((i + 1)); done
      printf ': region %d\n' "$k"
    done
    printf ': tail\n'
  } > big.sh
  git add -A && git commit -qm base
  awk '/^: region [0-9]$/ { for (i = 1; i <= 150; i++) printf "echo \"region %s line %d padding padding padding padding padding padding padding\"\n", $3, i; next } { print }' \
    big.sh > big.sh.new && mv big.sh.new big.sh
) >/dev/null 2>&1
(cd "$R41" && "$HELPER" > "$TMP/p41" 2>/dev/null)
LC_BIN="$TMP/lc-bin"; LC_PARTS="$TMP/lc-parts"; mkdir -p "$LC_BIN" "$LC_PARTS" "$TMP/lc-home/.zuvo"
cat > "$LC_BIN/mock-partlog" <<'MOCK'
#!/usr/bin/env bash
n=1
while ! ( set -C; : > "$LC_PART_DIR/$n.in" ) 2>/dev/null; do
  n=$((n + 1)); [ "$n" -le 999 ] || { echo "mock-partlog: cannot create a part file in $LC_PART_DIR" >&2; exit 1; }
done
cat > "$LC_PART_DIR/$n.in"
echo '{"findings":[]}'
MOCK
chmod +x "$LC_BIN/mock-partlog"
( cd "$R41" && HOME="$TMP/lc-home" ZUVO_HOME="$TMP/lc-home/.zuvo" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
    ZUVO_REVIEW_TEST_PROVIDERS=mock-partlog LC_PART_DIR="$LC_PARTS" PATH="$LC_BIN:$PATH" \
    bash "$ROOT/scripts/adversarial-review.sh" --single --artifact "$TMP/art41" < "$TMP/p41" >/dev/null 2>"$TMP/e41" ); RC41=$?
N41=0; PER41=""
while [ -f "$LC_PARTS/$((N41 + 1)).in" ]; do
  N41=$((N41 + 1))
  PER41="$PER41${PER41:+ }$(grep -c '^=== CONTEXT: big.sh - ' "$LC_PARTS/$N41.in")"
done
WANT41="$(i=0; while [ "$i" -lt "$N41" ]; do printf '%s1' "$([ "$i" -gt 0 ] && echo ' ')"; i=$((i + 1)); done)"
if [ "$RC41" -eq 0 ] && [ "$N41" -ge 2 ] && [ "$PER41" = "$WANT41" ]; then
  pass "(41) the driver splits the annotated file into $N41 parts, each carrying the block exactly once"
else
  bad "(41) rc=$RC41 parts=$N41 block count per part=[$PER41] — want rc 0, >= 2 parts, one block in each (stderr: $(tail -3 "$TMP/e41" | tr '\n' '|'))"
fi

# (42) the user's diff prefix config cannot hide the block: the helper fixes a/ and b/
R42A="$(lc_repo lc42a dev.sh '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'echo hi')"
git -C "$R42A" config diff.noprefix true
lc_row_block "(42a) diff.noprefix=true still gets the block" "$R42A" dev.sh \
  "the post-image path is read from a prefix the user's config removed" '3: trap cleanup EXIT INT TERM'
R42B="$(lc_repo lc42b dev.sh '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'echo hi')"
git -C "$R42B" config diff.mnemonicPrefix true
lc_row_block "(42b) diff.mnemonicPrefix=true still gets the block" "$R42B" dev.sh \
  "the post-image path is read from a prefix the user's config renamed" '3: trap cleanup EXIT INT TERM'

# (43) placement: the block closes its own file's section, right before the next file's header
R43="$(lc_repo lc43 a.sh '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'echo A-CHANGED')"
( cd "$R43" && echo b > b.txt && git add b.txt && git commit -qm b && echo B-CHANGED >> b.txt ) >/dev/null 2>&1
OUT43="$(cd "$R43" && "$HELPER" 2>/dev/null)"
POS43="$(printf '%s\n' "$OUT43" | awk '
  /^=== CONTEXT: a\.sh - / { h = NR; before = prev }
  /^=== END CONTEXT ===$/ { e = NR }
  /^diff --git a\/b\.txt b\/b\.txt$/ { b = NR }
  { prev = $0 }
  END { printf "%s|%s", (h > 0 && before ~ /^[-+ ]/ && e > h && b == e + 1) ? "ok" : "bad", before }')"
printf '%s\n' "$OUT43" > "$TMP/p43"
if [ "${POS43%%|*}" = ok ] && git -C "$R43" apply --cached --check "$TMP/p43" 2>"$TMP/e43"; then
  pass "(43) a.sh's block follows its last hunk line and directly precedes b.txt's diff; the patch applies"
else
  bad "(43) placement=$POS43, apply: $(tr '\n' '|' < "$TMP/e43") — the block is not where the splitter and git expect it"
fi

# (44) budget priority: trap registrations come first, so a full block never drops them
R44="$(lc_repo lc44 prio.sh '#!/usr/bin/env bash' "$(lc_func_lines 40 cleanup_a 70)
$(lc_func_lines 40 cleanup_b 70)
trap 'echo bye' EXIT" 'echo hi')"
BLK44="$(lc_block "$(cd "$R44" && "$HELPER" 2>/dev/null)")"
if printf '%s\n' "$BLK44" | grep -qE "^[0-9]+: trap 'echo bye' EXIT$"; then
  pass "(44) two long cleanup bodies fill the budget, the trap at the bottom still makes it in"
else
  bad "(44) the trap registration was cut by the cap (block lines: $(printf '%s\n' "$BLK44" | wc -l | tr -d ' '))"
fi

# (45) shell detection: a shebang decides when there is one; the extension must end the path
R45A="$(lc_repo lc45a tool.sh '#!/usr/bin/env python3' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_no_block "(45a) a .sh file with a python shebang gets no block" "$R45A" '+echo hi' \
  "the .sh extension overrode the interpreter the file names"
R45B="$(lc_repo lc45b x.sh.bak '' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_no_block "(45b) x.sh.bak without a shebang gets no block" "$R45B" '+echo hi' \
  "an extension in the middle of the name was read as shell"
R45C="$(lc_repo lc45c x.sh.bak '#!/bin/bash' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_block "(45c) a bash-shebang script with any extension gets the block" "$R45C" x.sh.bak \
  "a shebang script with a non-shell extension was skipped" '3: trap cleanup EXIT INT TERM'

# (46) function bodies end at their own closer
R46A="$(lc_repo lc46a arr.sh '#!/usr/bin/env bash' 'cleanup() {
pids=(
1 2
)
kill "${pids[@]}"
}
trap cleanup EXIT' 'echo hi')"
lc_row_block "(46a) a brace function holding a same-indent ')' line is shown up to its '}'" "$R46A" arr.sh \
  "the body was cut at the array's ')' and the kill was hidden" '6: kill "${pids[@]}"' '7: }'
R46B="$(lc_repo lc46b sub.sh '#!/usr/bin/env bash' 'stop_svc() (
cd /
kill -- -"$pg"
)
: after the function' 'echo hi')"
lc_row_block "(46b) a '( … )' subshell function is shown up to its ')'" "$R46B" sub.sh \
  "a subshell body was not closed by its ')'" '2: stop_svc() (' '4: kill -- -"$pg"' '5: )'
BLK46B="$(lc_block "$(cd "$R46B" && "$HELPER" 2>/dev/null)")"
has '6: : after the function' "$BLK46B" && bad "(46b) the line after the subshell function leaked into its body" \
  || pass "(46b) nothing after the closing ')' is shown"

# (47) not a regular file: a tracked script replaced by a symlink to a lifecycle script gets no block
R47="$(new_repo lc47)"
(
  cd "$R47" || exit 1
  printf '#!/usr/bin/env bash\n%s\n: real\n' "$LC_BASE_PROLOG" > real.sh
  printf '#!/usr/bin/env bash\n: plain\n' > link.sh
  git add -A && git commit -qm base
  rm link.sh && ln -s real.sh link.sh
) >/dev/null 2>&1
lc_row_no_block "(47) a script replaced by a symlink gets no block" "$R47" '+++ b/link.sh' \
  "the annotation followed a symlink to another file's definitions"

# (48) a path so long that no block fits the 4000-character cap: plain patch and a warning, never a silent drop
LONG48=""; k=0
while [ "$k" -lt 16 ]; do LONG48="$LONG48$(awk -v k="$k" 'BEGIN { s = sprintf("d%02d", k); while (length(s) < 240) s = s "x"; print s }')/"; k=$((k + 1)); done
R48="$(new_repo lc48)"
# The path exceeds macOS's PATH_MAX (1024); a refused path is a skipped row, never a product verdict.
if ! ( cd "$R48" && mkdir -p "$LONG48" \
       && { printf '#!/usr/bin/env bash\n%s\n' "$LC_BASE_PROLOG"; i=1; while [ "$i" -le 20 ]; do printf ': filler %d\n' "$i"; i=$((i + 1)); done; } > "${LONG48}x.sh" ) 2>/dev/null; then
  printf 'SKIP: (48) long-path case skipped (the filesystem refused a %d-byte path: PATH_MAX is below it)\n' "${#LONG48}"
elif ! ( cd "$R48" && git add -A && git commit -qm base && printf 'echo LONGPATH\n' >> "${LONG48}x.sh" ) >"$TMP/s48" 2>&1; then
  bad "(48) fixture setup failed after the path was created: $(tr '\n' '|' < "$TMP/s48")"
else
  OUT48="$(cd "$R48" && "$HELPER" 2>"$TMP/e48")"; RC48=$?
  if [ "$RC48" -eq 0 ] && has '+echo LONGPATH' "$OUT48" && ! has '=== CONTEXT: ' "$OUT48" && grep -q '/x\.sh' "$TMP/e48"; then
    pass "(48) a block that cannot fit: plain patch, exit 0, a warning naming the file"
  else
    bad "(48) rc=$RC48, hunk=$(has '+echo LONGPATH' "$OUT48" && echo yes || echo NO), block=$(has '=== CONTEXT: ' "$OUT48" && echo yes || echo no), stderr names x.sh=$(grep -q '/x\.sh' "$TMP/e48" && echo yes || echo NO) — a dropped block must be reported"
  fi
fi

# (49) the "+++ b/" name git writes for a path with a space ends in a TAB, which is not part of the path
R49="$(lc_repo lc49 'my dev.sh' '#!/usr/bin/env bash' "$LC_BASE_PROLOG" 'echo hi')"
lc_row_block "(49) a script whose path holds a space gets its block" "$R49" 'my dev.sh' \
  "the TAB git appends after such a name was kept, so the post-image was never found" '3: trap cleanup EXIT INT TERM'

# (50) with diff.context=0 a deletion-only hunk is "+N,0": it shows no post-image line, not line N
R50="$(new_repo lc50)"
(
  cd "$R50" || exit 1
  git config diff.context 0
  { printf '#!/usr/bin/env bash\n%s\n: doomed\n' "$LC_BASE_PROLOG"
    i=1; while [ "$i" -le 20 ]; do printf ': filler %d\n' "$i"; i=$((i + 1)); done; } > del.sh
  git add -A && git commit -qm base
  awk '$0 != ": doomed"' del.sh > del.sh.new && mv del.sh.new del.sh
) >/dev/null 2>&1
OUT50="$(cd "$R50" && "$HELPER" 2>/dev/null)"
if has '@@ -4 +3,0 @@' "$OUT50"; then
  lc_row_block "(50) a deletion-only hunk right after the trap keeps the trap line in the block" "$R50" del.sh \
    "a '+N,0' hunk was read as showing line N, so the trap on that line was left out" \
    '2: cleanup(){ kill -- -"$pg"; }' '3: trap cleanup EXIT INT TERM'
else
  bad "(50) fixture vacuous: the patch has no '@@ -4 +3,0 @@' deletion-only hunk"
fi

# (51) a post-image over the 1 MiB read bound: that file's block is skipped with a warning, the rest is annotated
R51="$(new_repo lc51)"
(
  cd "$R51" || exit 1
  # The change point sits past the hunk's context lines, so the trap and cleanup are outside the hunk.
  { printf '#!/usr/bin/env bash\n%s\n' "$LC_BASE_PROLOG"
    awk 'BEGIN { for (i = 1; i <= 10; i++) printf ": head %d\n", i }'; printf ': change point\n'
    awk 'BEGIN { for (i = 1; i <= 20000; i++) printf ": filler %d padding padding padding padding padding\n", i }'; } > huge.sh
  { printf '#!/usr/bin/env bash\n%s\n' "$LC_BASE_PROLOG"
    awk 'BEGIN { for (i = 1; i <= 10; i++) printf ": head %d\n", i }'; printf ': change point\n: tail\n'; } > small.sh
  git add -A && git commit -qm base
  for f in huge.sh small.sh; do
    awk '$0 == ": change point" { print "echo CHANGED"; next } { print }' "$f" > "$f.new" && mv "$f.new" "$f"
  done
) >/dev/null 2>&1
SZ51="$(wc -c < "$R51/huge.sh" | tr -d ' ')"
OUT51="$(cd "$R51" && "$HELPER" 2>"$TMP/e51")"; RC51=$?
if [ "$SZ51" -le 1048576 ]; then
  bad "(51) fixture vacuous: huge.sh is $SZ51 bytes, not over 1 MiB"
elif [ "$RC51" -eq 0 ] && has '+++ b/huge.sh' "$OUT51" && ! has '=== CONTEXT: huge.sh - ' "$OUT51" \
     && has '=== CONTEXT: small.sh - ' "$OUT51" && grep -q 'huge\.sh' "$TMP/e51"; then
  pass "(51) a post-image over 1 MiB: its hunk is kept, its block skipped with a warning naming it, small.sh still annotated"
else
  bad "(51) rc=$RC51, huge.sh block=$(has '=== CONTEXT: huge.sh - ' "$OUT51" && echo YES || echo no), small.sh block=$(has '=== CONTEXT: small.sh - ' "$OUT51" && echo yes || echo NO), stderr=$(tr '\n' '|' < "$TMP/e51") — a huge script is read whole into memory, unbounded"
fi

# (52) a one-line post-image over 1 MiB: the bound applies to the first line too, not only to later ones
R52="$(new_repo lc52)"
(
  cd "$R52" || exit 1
  awk 'BEGIN { s = "x"; while (length(s) < 600000) s = s s; printf "trap cleanup EXIT; : %s\n", s }' > one.sh
  git add -A && git commit -qm base
  awk '{ sub(/^trap cleanup EXIT;/, "trap cleanup EXIT INT;"); print }' one.sh > one.sh.new && mv one.sh.new one.sh
) >"$TMP/s52" 2>&1 || bad "(52) fixture setup failed: $(tr '\n' '|' < "$TMP/s52")"
SZ52="$(wc -c < "$R52/one.sh" | tr -d ' ')"; NL52="$(wc -l < "$R52/one.sh" | tr -d ' ')"
(cd "$R52" && "$HELPER" >"$TMP/p52" 2>"$TMP/e52"); RC52=$?
if [ "$SZ52" -le 1048576 ] || [ "$NL52" -ne 1 ]; then
  bad "(52) fixture vacuous: one.sh is $SZ52 bytes in $NL52 lines, not one line over 1 MiB"
elif [ "$RC52" -eq 0 ] && grep -q '^+trap cleanup EXIT INT;' "$TMP/p52" && ! grep -q '^=== CONTEXT: ' "$TMP/p52" \
     && grep -q 'one\.sh: its post-image is over 1048576 bytes' "$TMP/e52"; then
  pass "(52) a one-line post-image over 1 MiB: plain patch, exit 0, the size warning names it"
else
  bad "(52) rc=$RC52, hunk=$(grep -q '^+trap cleanup EXIT INT;' "$TMP/p52" && echo yes || echo NO), block=$(grep -q '^=== CONTEXT: ' "$TMP/p52" && echo YES || echo no), stderr=$(tr '\n' '|' < "$TMP/e52") — the first line escaped the 1 MiB bound with no warning"
fi

if [ "$fail" -eq 0 ]; then
  echo "ALL PASS"
  exit 0
fi
echo "SOME FAILED"
exit 1
