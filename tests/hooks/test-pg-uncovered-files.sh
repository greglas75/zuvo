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
HH="$TMP/hinthome"; mkdir -p "$HH/.zuvo"
cp "$PUF" "$LIB" "$ROOT/hooks/lib/path-contain.sh" "$HH/.zuvo/" 2>/dev/null
chmod +x "$HH/.zuvo/pg-uncovered-files" 2>/dev/null
# A ref name may legally hold quotes, $( ) and braces; the printed command must keep it inert.
HB='q'\''"$(touch${IFS}PWNED)'
git branch "$HB" HEAD
HRX="$(git rev-parse HEAD~1)..$HB"

# hint_cmd <home> <range> — the command line after "Full list:", as pg_explain_uncovered prints it.
hint_cmd() {
  ( cd "$HX" && HOME="$1" bash -c '. "$1"; pg_explain_uncovered "$2"' _ "$LIB" "$2" ) 2>/dev/null \
    | awk 'found { sub(/^[[:space:]]+/, ""); print; exit } /Full list:/ { found = 1 }'
}
run_hint() { ( cd "$HX" && HOME="$HH" bash -c "$1" ) 2>/dev/null | sort | tr '\n' ' '; }
# hint_runs <label> <range> — the printed command lists every uncovered file and executes nothing else.
hint_runs() {
  local cmd got; cmd="$(hint_cmd "$HH" "$2")"; got="$(run_hint "$cmd")"
  if [ -n "$cmd" ] && [ "$got" = "$want" ] && [ ! -e "$HX/PWNED" ]; then ok "$1"
  else bad "$1 — hint [$cmd] printed [$got], want [$want]; PWNED exists: $([ -e "$HX/PWNED" ] && echo yes || echo no)"; fi
}

cmd="$(hint_cmd "$HH" "$HR")"
case "$cmd" in
  "'$HH/.zuvo/pg-uncovered-files' '$HR'")
    ok "with an executable ~/.zuvo/pg-uncovered-files the hint is its absolute path, single-quoted" ;;
  *) bad "hint is [$cmd], want the single-quoted absolute \$HOME/.zuvo path — ~/.zuvo is not on PATH" ;;
esac
hint_runs "running the absolute-path hint lists every uncovered file" "$HR"
hint_runs "a ref holding a quote and \$( ) stays inert in the absolute-path hint" "$HRX"

chmod -x "$HH/.zuvo/pg-uncovered-files" 2>/dev/null
cmd="$(hint_cmd "$HH" "$HR")"
case "$cmd" in
  "bash -c '. \"\$1\" && pg_uncovered_files \"\$2\"' _ '"*"/pipeline-gate-lib.sh' '$HR'")
    ok "with no executable helper the hint falls back to the bash -c form, arguments single-quoted" ;;
  *) bad "hint is [$cmd], want the bash -c form — a non-executable path was named as a command" ;;
esac
hint_runs "running the bash -c fallback lists every uncovered file" "$HR"
hint_runs "a ref holding a quote and \$( ) stays inert in the bash -c fallback" "$HRX"

HP="$TMP/partialhome"; mkdir -p "$HP/.zuvo"; cp "$PUF" "$HP/.zuvo/" 2>/dev/null; chmod +x "$HP/.zuvo/pg-uncovered-files" 2>/dev/null
case "$(hint_cmd "$HP" "$HR")" in
  "bash -c "*) ok "a helper without its sibling gate lib is not named as the command" ;;
  *) bad "a partial ~/.zuvo install (no pipeline-gate-lib.sh) was named as the command — it exits 2" ;;
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
  # A stale or failed copy of a flat gate dependency must be counted, not just warned about.
  printf 'out="$( . %q probe >/dev/null 2>&1; cp() { case "$1" in */hooks/lib/path-contain.sh) printf "stale\\n" > "$2" ;; *) command cp "$@" ;; esac; }; INSTALL_VERIFY_MISSING=0; install_zuvo_home >/dev/null 2>&1; echo "$INSTALL_VERIFY_MISSING|$INSTALL_VERIFY_DETAIL" )"\n' "$ROOT/scripts/install.sh"
  printf 'echo "LEG stale missing=${out%%%%|*} detail=[${out#*|}]"\n'
  printf 'exit "$rc"\n'
} > "$WRAP"
MAN="$TMP/manifest.out"
ZUVO_MANIFEST_INSTALL="$WRAP" bash "$ROOT/tests/lib/install-manifest.sh" nosettings > "$MAN" 2>&1
leg() { awk -v k="LEG $1 " 'index($0, k) == 1 { print; exit }' "$MAN"; }
l_inst="$(leg install)"; l_puf="$(leg puf)"; l_chk="$(leg check)"; l_stale="$(leg stale)"; l_rep="$(leg reprobe)"
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

case "$l_stale" in
  "LEG stale missing=0 "*|"") bad "a stale ~/.zuvo/path-contain.sh copy went uncounted: [$l_stale] — the fresh-machine exit-2 bug would recur silently" ;;
  *"path-contain.sh"*) ok "a stale ~/.zuvo/path-contain.sh copy is counted as INSTALL INCOMPLETE and named" ;;
  *) bad "stale path-contain.sh counted but not named: [$l_stale]" ;;
esac

echo "=== RESULT ==="; [ "$fails" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "$fails FAILED"; exit 1; }
