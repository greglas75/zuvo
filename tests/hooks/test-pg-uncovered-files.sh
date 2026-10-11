#!/usr/bin/env bash
# Tests scripts/zuvo-home/pg-uncovered-files, the "Full list" hint pg_explain_uncovered prints, and
# the installed ~/.zuvo layout both need (the gate lib and path-contain.sh beside the helpers).
#
# Every case names the defect it catches. Nothing here reads the real ~/.zuvo or ~/.claude: HOME is
# a sandbox, and install.sh runs only inside tests/lib/install-manifest.sh's sandbox HOME.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/hooks/lib/pipeline-gate-lib.sh"
PUF="$ROOT/scripts/zuvo-home/pg-uncovered-files"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null PG_REVIEW_PROOF_CUTOFF=1 HOME="$TMP/emptyhome"
mkdir -p "$HOME"
unset PG_REPO_ROOT PG_PROOF_OPTIONAL
fails=0; ok(){ echo "  ✓ $1"; }; bad(){ echo "  ✗ $1"; fails=$((fails+1)); }

commit() { git -c commit.gpgsign=false commit -qm "$1" >/dev/null; }
newrepo() { mkdir -p "$1" && cd "$1" && git init -q && git config user.email t@t && git config user.name t; }
good_proof() { mkdir -p "$(dirname "$1")"; printf 'REVIEW BY: P1\nREVIEW BY: P2\n' > "$1"; }

# Fixture: base, then a commit changing only src/a.ts (reviewed: the artifact covers it), then one
# changing src/b.ts (never reviewed), then a docs-only commit.
FX="$TMP/fx"
newrepo "$FX"
mkdir -p src docs memory/reviews
echo "export const a=1" > src/a.ts; echo "export const b=1" > src/b.ts; echo "# d" > docs/d.md
git add -A; commit base
echo "export const a=2" >> src/a.ts; git add src; commit a-only
echo "export const b=2" >> src/b.ts; git add src; commit b-only
echo "more" >> docs/d.md; git add docs; commit docs
B0=$(git rev-parse HEAD~3); BA=$(git rev-parse HEAD~2); BB=$(git rev-parse HEAD~1); BD=$(git rev-parse HEAD)
good_proof "$FX/zuvo/proofs/good.txt"
printf '<!-- zuvo-review -->\nrange: %s..%s\nfiles: src/a.ts\nadversarial: zuvo/proofs/good.txt\n' "$B0" "$BA" \
  > memory/reviews/good.md
cd "$TMP" || exit 1

echo "=== exit-status table: the classifier's status passes through ==="
# Script copied alone, two levels deep so ../../hooks/lib is not the repo: no lib reachable.
mkdir -p "$TMP/x/y/alone" "$TMP/notrepo"
cp "$PUF" "$TMP/x/y/alone/pg-uncovered-files" 2>/dev/null
# A git whose diff fails (lock, corrupt object, diff driver) while every other call works.
SHIM="$TMP/shim"; mkdir -p "$SHIM"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = diff ] && exit 128; done\nexec %s "$@"\n' "$(command -v git)" > "$SHIM/git"
chmod +x "$SHIM/git"
# row <id> <cwd> <want_rc> <want_stdout> <bug> -- <command...>
row() {
  local id="$1" cwd="$2" want_rc="$3" want="$4" bug="$5" got rc; shift 6
  got="$(cd "$cwd" && "$@" 2>/dev/null)"; rc=$?
  got="$(printf '%s' "$got" | tr '\n' ' ')"
  if [ "$rc" = "$want_rc" ] && [ "$got" = "$want" ]; then
    ok "$id: rc=$rc [$got] — $bug"
  else
    bad "$id: want rc=$want_rc [$want], got rc=$rc [$got] — $bug"
  fi
}
row uncovered "$FX" 0 "src/b.ts" "the uncovered file is missing, or the covered one listed" -- bash "$PUF" "$B0..$BB"
row covered "$FX" 0 "" "a fully covered range does not answer 0 with an empty list" -- bash "$PUF" "$B0..$BA"
row docs-only "$FX" 3 "" "no-production-files collapsed into 0" -- bash "$PUF" "$BB..$BD"
row bad-range "$FX" 2 "" "an unresolvable range reads as nothing uncovered" -- bash "$PUF" "nosuch..alsonot"
row not-a-repo "$TMP/notrepo" 2 "" "outside a repo the wrapper swallows the status" -- bash "$PUF" "$B0..$BB"
row no-arg "$FX" 2 "" "no argument is not a usage error" -- bash "$PUF"
row two-args "$FX" 2 "" "a second argument is silently ignored" -- bash "$PUF" "$B0..$BB" extra
row not-a-range "$FX" 2 "" "an argument without .. is passed on as a range" -- bash "$PUF" "$BB"
row bad-base "$FX" 2 "" "an unresolvable base with a valid head reads as no production files" -- bash "$PUF" "nosuch..$BB"
row three-dot "$FX" 2 "" "a three-dot range diffs from the merge-base, not from <base>" -- bash "$PUF" "$B0...$BB"
row option-range "$FX" 2 "" "an option-shaped range reaches git diff" -- bash "$PUF" "--output=$TMP/leak..$BB"
row diff-fails "$FX" 2 "" "a failing git diff on a valid range reads as no production files" -- env PATH="$SHIM:$PATH" bash "$PUF" "$B0..$BB"
row no-lib "$FX" 2 "" "no reachable gate lib reads as nothing uncovered" -- bash "$TMP/x/y/alone/pg-uncovered-files" "$B0..$BB"
row repo-root-env "$TMP/notrepo" 0 "src/b.ts" "PG_REPO_ROOT is ignored" -- env PG_REPO_ROOT="$FX" bash "$PUF" "$B0..$BB"
[ ! -e "$TMP/leak..$BB" ] \
  && ok "the option-shaped range wrote no file" || bad "the option-shaped range was handed to git as --output"

# GX: src/c.ts changed, cited by an artifact whose proof is absent — only the local proof rule leaves it uncovered.
GX="$TMP/gx"
newrepo "$GX"
mkdir -p src memory/reviews; echo "export const c=1" > src/c.ts; git add -A; commit base
echo "export const c=2" >> src/c.ts; git add src; commit c-only
GR="$(git rev-parse HEAD~1)..$(git rev-parse HEAD)"
printf '<!-- zuvo-review -->\nrange: %s\nfiles: src/c.ts\nadversarial: zuvo/proofs/GONE.txt\n' "$GR" > memory/reviews/gone.md
cd "$TMP" || exit 1
row env-proof-optional "$GX" 0 "src/c.ts" "an exported PG_PROOF_OPTIONAL=1 waived the missing proof and read as covered" \
  -- env PG_PROOF_OPTIONAL=1 bash "$PUF" "$GR"
row env-proof-cutoff "$GX" 0 "src/c.ts" "an exported PG_REVIEW_PROOF_CUTOFF grandfathered the proofless artifact into covered" \
  -- env PG_REVIEW_PROOF_CUTOFF=99999999999 bash "$PUF" "$GR"

echo "=== the @unpushed sentinel: a failing rev-list is an error, an empty one is nothing to review ==="
# UX: every commit already on a remote-tracking ref, so nothing is un-pushed.
UX="$TMP/ux"
newrepo "$UX"
mkdir -p src; echo "export const u=1" > src/u.ts; git add -A; commit base
git update-ref refs/remotes/origin/main HEAD
cd "$TMP" || exit 1
RLSHIM="$TMP/rlshim"; mkdir -p "$RLSHIM"
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = rev-list ] && exit 128; done\nexec %s "$@"\n' "$(command -v git)" > "$RLSHIM/git"
chmod +x "$RLSHIM/git"
row unpushed "$FX" 0 "src/b.ts" "the @unpushed walk lost the un-pushed uncovered file" \
  -- bash -c '. "$1"; pg_uncovered_files "$2"' _ "$LIB" "@unpushed..HEAD"
row unpushed-revlist-fails "$FX" 2 "" "a failing rev-list on @unpushed read as no production files (rc 3)" \
  -- env PATH="$RLSHIM:$PATH" bash -c '. "$1"; pg_uncovered_files "$2"' _ "$LIB" "@unpushed..HEAD"
row unpushed-none "$UX" 3 "" "nothing un-pushed must stay rc 3, not become an error" \
  -- bash -c '. "$1"; pg_uncovered_files "$2"' _ "$LIB" "@unpushed..HEAD"

echo "=== the library itself never hands an option-shaped range to git ==="
# optrow <id> <want_rc> <want_stdout> <leak-name> <bug> -- <function> <range>: the lib called directly, as the
# bash -c hint does; the range's --output= value must never become a file.
optrow() {
  local id="$1" wrc="$2" want="$3" leak="$TMP/$4" bug="$5" got rc; shift 6
  got="$(cd "$FX" && bash -c '. "$1"; shift; "$@"' _ "$LIB" "$@" 2>/dev/null)"; rc=$?
  if [ "$rc" = "$wrc" ] && [ "$got" = "$want" ] && [ ! -e "$leak" ]; then ok "$id: rc=$rc [$got], no file written — $bug"
  else bad "$id: want rc=$wrc [$want] and no $leak, got rc=$rc [$got], file written: $([ -e "$leak" ] && echo yes || echo no) — $bug"; fi
}
optrow changed-base 1 "" "leakA..$BB" "a dash-led base reached git diff as --output" -- pg_changed_production "--output=$TMP/leakA..$BB"
optrow changed-tip 1 "" "leakB" "a dash-led @unpushed tip reached git rev-list as an option" -- pg_changed_production "@unpushed..--output=$TMP/leakB"
optrow lines-base 0 "0" "leakC..$BB" "a dash-led base reached git diff --numstat as --output" -- pg_changed_lines "--output=$TMP/leakC..$BB"
optrow uncovered-base 2 "" "leakD..$BB" "a dash-led base was not refused as could-not-compute" -- pg_uncovered_files "--output=$TMP/leakD..$BB"

# Bug: a range holding whitespace reached the library, which refuses it silently (rc 2, no text), so a
# typo'd range read the same as an unresolvable one.
err="$(cd "$FX" && bash "$PUF" "$B0..$BB extra" 2>&1 >/dev/null)"; rc=$?
[ "$rc" = 2 ] && [ "$err" = "pg-uncovered-files: not a range: $B0..$BB extra" ] \
  && ok "ws-range: rc=2 and the wrapper names the whitespace range" \
  || bad "ws-range: want rc=2 [pg-uncovered-files: not a range: $B0..$BB extra], got rc=$rc [$err]"

# exact_run <label> <want_rc> <want_stdout> <want_stderr> -- <command...> — run from $FX, compare all three.
exact_run() {
  local id="$1" wrc="$2" wout="$3" werr="$4" out err rc; shift 5
  out="$(cd "$FX" && "$@" 2>"$TMP/exact.err")"; rc=$?; err="$(cat "$TMP/exact.err")"
  if [ "$rc" = "$wrc" ] && [ "$out" = "$wout" ] && [ "$err" = "$werr" ]; then ok "$id"
  else bad "$id — want rc=$wrc out=[$wout] err=[$werr], got rc=$rc out=[$out] err=[$err]"; fi
}
# Bug: a resolvable base let an unresolvable head through, so the diff ran against a guess or read as rc 0/3.
exact_run "bad-head with a valid base: rc=2, no list, a reason on stderr" 2 "" \
  "pg-uncovered-files: cannot compute $B0..nosuchhead: a base or head that does not resolve, or git failed" \
  -- bash "$PUF" "$B0..nosuchhead"
# Bug: -h/--help parsed as a range (rc 2) or the usage went to stderr, so --help looked like a failure.
exact_run "-h prints the usage on stdout and exits 0" 0 "usage: pg-uncovered-files <base>..<head>" "" -- bash "$PUF" -h
exact_run "--help prints the usage on stdout and exits 0" 0 "usage: pg-uncovered-files <base>..<head>" "" -- bash "$PUF" --help

# Bug: the documented ~/.claude/hooks/lib fallback was unreachable, so a hooks-only install always exited 2.
mkdir -p "$TMP/fb/a/b" "$TMP/fbhome/.claude/hooks/lib"
cp "$PUF" "$TMP/fb/a/b/pg-uncovered-files"
cp "$LIB" "$ROOT/hooks/lib/path-contain.sh" "$TMP/fbhome/.claude/hooks/lib/"
exact_run "a wrapper with no sibling or repo lib computes from ~/.claude/hooks/lib" 0 "src/b.ts" "" \
  -- env HOME="$TMP/fbhome" bash "$TMP/fb/a/b/pg-uncovered-files" "$B0..$BB"

echo "=== a library that loads incompletely is refused, not trusted ==="
# stub_dir <name> <lib body> — the wrapper copied beside a stub pipeline-gate-lib.sh whose
# pg_uncovered_files answers "all covered" (rc 0, no output), so only the wrapper's guard can say 2.
stub_dir() {
  mkdir -p "$TMP/stub-$1" && cp "$PUF" "$TMP/stub-$1/pg-uncovered-files" \
    && printf '%s\n' "$2" 'pg_uncovered_files() { return 0; }' > "$TMP/stub-$1/pipeline-gate-lib.sh"
}
stub_dir noflag 'path_contained() { return 0; }'
stub_dir nocontain 'PG_LIB_LOADED=1'
row stub-no-flag "$FX" 2 "" "a lib cut short before PG_LIB_LOADED=1 answered all covered" \
  -- env -u PG_LIB_LOADED bash "$TMP/stub-noflag/pg-uncovered-files" "$B0..$BB"
row stub-no-contain "$FX" 2 "" "a lib loaded without path-contain.sh refused every proof and listed every file" \
  -- env -u PG_LIB_LOADED bash "$TMP/stub-nocontain/pg-uncovered-files" "$B0..$BB"
row stub-env-flag "$FX" 2 "" "an inherited PG_LIB_LOADED=1 vouched for a lib that never set it" \
  -- env PG_LIB_LOADED=1 bash "$TMP/stub-noflag/pg-uncovered-files" "$B0..$BB"

echo "=== the push hint names a command that runs ==="
# > 10 uncovered files, so pg_explain_uncovered prints its "Full list:" hint.
HX="$TMP/hx"
newrepo "$HX"
mkdir -p src memory/reviews; echo base > src/f0.ts; git add -A; commit base
want=""; i=1
while [ "$i" -le 11 ]; do echo "export const v$i=1" > "src/f$i.ts"; want="$want src/f$i.ts"; i=$((i + 1)); done
git add -A; commit work
HR="$(git rev-parse HEAD~1)..$(git rev-parse HEAD)"
want="$(printf '%s\n' $want | sort | tr '\n' ' ')"
# hint_home <dir> <+x|-x> — a HOME whose ~/.zuvo holds the helper (with or without its exec bit)
# beside the gate lib and path-contain.sh; each scenario gets its own, so none depends on another.
hint_home() {
  mkdir -p "$1/.zuvo" && cp "$PUF" "$LIB" "$ROOT/hooks/lib/path-contain.sh" "$1/.zuvo/" \
    && chmod "$2" "$1/.zuvo/pg-uncovered-files"
}
HH="$TMP/hinthome"; hint_home "$HH" +x
# A ref name may legally hold quotes, $( ) and braces; the printed command must keep it inert.
HB='q'\''"$(touch${IFS}PWNED)'
git branch "$HB" HEAD
HRX="$(git rev-parse HEAD~1)..$HB"

# hint_cmd <home> <range> — the command line after "Full list:", as pg_explain_uncovered prints it.
hint_cmd() {
  ( cd "$HX" && HOME="$1" bash -c '. "$1"; pg_explain_uncovered "$2"' _ "$LIB" "$2" ) 2>/dev/null \
    | awk 'found { sub(/^[[:space:]]+/, ""); print; exit } /Full list:/ { found = 1 }'
}
run_hint() { ( cd "$HX" && HOME="$1" bash -c "$2" ) 2>/dev/null | sort | tr '\n' ' '; }
# hint_runs <label> <home> <range> — the printed command lists every uncovered file and executes nothing else.
hint_runs() {
  local cmd got; cmd="$(hint_cmd "$2" "$3")"; got="$(run_hint "$2" "$cmd")"
  if [ -n "$cmd" ] && [ "$got" = "$want" ] && [ ! -e "$HX/PWNED" ]; then ok "$1"
  else bad "$1 — hint [$cmd] printed [$got], want [$want]; PWNED exists: $([ -e "$HX/PWNED" ] && echo yes || echo no)"; fi
}

cmd="$(hint_cmd "$HH" "$HR")"
case "$cmd" in
  "'$HH/.zuvo/pg-uncovered-files' '$HR'")
    ok "with an executable ~/.zuvo/pg-uncovered-files the hint is its absolute path, single-quoted" ;;
  *) bad "hint is [$cmd], want the single-quoted absolute \$HOME/.zuvo path — ~/.zuvo is not on PATH" ;;
esac
hint_runs "running the absolute-path hint lists every uncovered file" "$HH" "$HR"
hint_runs "a ref holding a quote and \$( ) stays inert in the absolute-path hint" "$HH" "$HRX"

HN="$TMP/noexechome"; hint_home "$HN" -x
cmd="$(hint_cmd "$HN" "$HR")"
case "$cmd" in
  "bash -c '. \"\$1\" && pg_uncovered_files \"\$2\"' _ '"*"/pipeline-gate-lib.sh' '$HR'")
    ok "with no executable helper the hint falls back to the bash -c form, arguments single-quoted" ;;
  *) bad "hint is [$cmd], want the bash -c form — a non-executable path was named as a command" ;;
esac
hint_runs "running the bash -c fallback lists every uncovered file" "$HN" "$HR"
hint_runs "a ref holding a quote and \$( ) stays inert in the bash -c fallback" "$HN" "$HRX"

HP="$TMP/partialhome"; mkdir -p "$HP/.zuvo"; cp "$PUF" "$HP/.zuvo/" 2>/dev/null; chmod +x "$HP/.zuvo/pg-uncovered-files" 2>/dev/null
case "$(hint_cmd "$HP" "$HR")" in
  "bash -c "*) ok "a helper without its sibling gate lib is not named as the command" ;;
  *) bad "a partial ~/.zuvo install (no pipeline-gate-lib.sh) was named as the command — it exits 2" ;;
esac
HC="$TMP/nocontainhome"; mkdir -p "$HC/.zuvo"; cp "$PUF" "$LIB" "$HC/.zuvo/"; chmod +x "$HC/.zuvo/pg-uncovered-files"
case "$(hint_cmd "$HC" "$HR")" in
  "bash -c "*) ok "a helper without path-contain.sh beside it is not named as the command" ;;
  *) bad "a ~/.zuvo install missing path-contain.sh was named as the command — it exits 2" ;;
esac
HD="$TMP/dirhome"; mkdir -p "$HD/.zuvo/pg-uncovered-files"
case "$(hint_cmd "$HD" "$HR")" in
  "bash -c "*) ok "a directory named pg-uncovered-files is not named as the command" ;;
  *) bad "an executable DIRECTORY at ~/.zuvo/pg-uncovered-files was printed as the command" ;;
esac

echo "=== installed layout: the ~/.zuvo helpers run on a fresh machine ==="
# install.sh runs ONLY inside install-manifest.sh's sandbox HOME. Its installer is replaced by a
# wrapper that runs the real install.sh, then the installed helpers, and prints LEG lines into the
# scenario's output. HOME for pg-uncovered-files is an empty dir, so only the flat sibling lib counts
# (the claude target also installs ~/.claude/hooks/lib, which would mask a missing ~/.zuvo copy).
# stale-leg <install.sh> <hooks/lib name>: install_zuvo_home again with that file's copy corrupted, so the
# installed copy differs from the source the way a failed or interrupted copy leaves it.
STALE_LEG="$TMP/stale-leg.sh"
cat > "$STALE_LEG" <<'LEG'
. "$1" probe >/dev/null 2>&1
STALE_NAME="$2"
cp() { case "$1" in */hooks/lib/"$STALE_NAME") printf 'stale\n' > "$2" ;; *) command cp "$@" ;; esac; }
INSTALL_VERIFY_MISSING=0
install_zuvo_home >/dev/null 2>&1 || :
kept=no; if [ -e "$HOME/.zuvo/$STALE_NAME" ]; then kept=yes; fi
printf 'LEG stale-%s missing=%s kept=%s detail=[%s]\n' "$STALE_NAME" "$INSTALL_VERIFY_MISSING" "$kept" \
  "$(printf '%s' "$INSTALL_VERIFY_DETAIL" | tr '\n' ' ')"
LEG
WRAP="$TMP/install-wrapper.sh"
{
  printf '#!/usr/bin/env bash\n'
  printf '"$BASH" %q "$@"; rc=$?\n' "$ROOT/scripts/install.sh"
  printf 'echo "LEG install rc=$rc"\n'
  printf 'out="$(cd %q && env HOME=%q GIT_CONFIG_GLOBAL=/dev/null PG_REVIEW_PROOF_CUTOFF=1 "$HOME/.zuvo/pg-uncovered-files" %q 2>&1)"; prc=$?\n' \
    "$FX" "$TMP/emptyhome" "$B0..$BB"
  printf 'echo "LEG puf rc=$prc out=[$(printf "%%s" "$out" | tr "\\n" " ")]"\n'
  printf 'out="$(cd %q && env GIT_CONFIG_GLOBAL=/dev/null PG_REVIEW_PROOF_CUTOFF=1 "$HOME/.zuvo/review-artifact-sync.sh" --check 2>&1)"; crc=$?\n' "$FX"
  printf 'echo "LEG check rc=$crc out=[$(printf "%%s" "$out" | tr "\\n" " ")]"\n'
  printf '"$HOME/.zuvo/mutation-survivor-reprobe.sh" --help >/dev/null 2>&1; echo "LEG reprobe rc=$?"\n'
  printf 'bash %q %q path-contain.sh\n' "$STALE_LEG" "$ROOT/scripts/install.sh"
  printf 'bash %q %q pipeline-gate-lib.sh\n' "$STALE_LEG" "$ROOT/scripts/install.sh"
  printf 'exit "$rc"\n'
} > "$WRAP"
MAN="$TMP/manifest.out"
ZUVO_MANIFEST_INSTALL="$WRAP" bash "$ROOT/tests/lib/install-manifest.sh" nosettings > "$MAN" 2>&1
leg() { awk -v k="LEG $1 " 'index($0, k) == 1 { print; exit }' "$MAN"; }
l_inst="$(leg install)"; l_puf="$(leg puf)"; l_chk="$(leg check)"; l_rep="$(leg reprobe)"
[ "$l_inst" = "LEG install rc=0" ] && ok "sandbox install.sh claude exits 0" \
  || { bad "sandbox install: [$l_inst]"; tail -20 "$MAN"; }
[ "$l_puf" = "LEG puf rc=0 out=[src/b.ts]" ] \
  && ok "installed ~/.zuvo/pg-uncovered-files computes coverage with only its sibling lib" \
  || bad "installed pg-uncovered-files: [$l_puf] — no gate lib / path-contain.sh beside the ~/.zuvo helpers"
case "$l_chk" in
  "LEG check rc=0 out=[OK   memory/reviews/good.md"*)
    ok "installed ~/.zuvo/review-artifact-sync.sh --check passes a good pair" ;;
  *) bad "installed review-artifact-sync --check: [$l_chk] — path-contain.sh not beside it, every mode exits 2" ;;
esac

# The perTest survivor gap tells the agent to run ~/.zuvo/mutation-survivor-reprobe.sh.
[ "$l_rep" = "LEG reprobe rc=0" ] \
  && ok "installed ~/.zuvo/mutation-survivor-reprobe.sh --help exits 0" \
  || bad "installed reprobe helper: [$l_rep] — the survivor gap names a helper the install never ships"

# stale_outcome <name> — a corrupted copy is counted, named in the summary, and not left in place to be loaded.
stale_outcome() {
  local l; l="$(leg "stale-$1")"
  case "$l" in
    "LEG stale-$1 missing=0 "*|"") bad "a stale ~/.zuvo/$1 copy went uncounted: [$l] — the helpers beside it would load it silently" ;;
    *" kept=yes "*) bad "a stale ~/.zuvo/$1 copy was counted but left in place for the helpers to load: [$l]" ;;
    *" kept=no detail=["*"gate library dependency: "*"/.zuvo/$1"*) ok "a stale ~/.zuvo/$1 copy is counted as INSTALL INCOMPLETE, named, and removed" ;;
    *) bad "stale $1 counted but not named: [$l]" ;;
  esac
}
stale_outcome path-contain.sh
stale_outcome pipeline-gate-lib.sh

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
