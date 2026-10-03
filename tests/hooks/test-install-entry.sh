#!/usr/bin/env bash
# scripts/install.sh as an ENTRY POINT: what it does before any host is installed, and what the copy
# of it that ships into the Claude plugin cache can still do.
#
# install.sh loads its code from scripts/install.d/ (via _zi_source). Two ways that can go wrong
# without any host installer misbehaving: a module that is not there (sourcing a missing file only
# warns, so the first symptom used to be a "command not found" halfway through a host's install),
# and the plugin cache, which receives install.sh with the flat scripts/*.sh copy — a cached
# install.sh without its modules beside it is an installer that cannot start.
#
# Test level: MEDIUM — real install.sh runs and sources, in temp HOMEs and temp copies of the repo;
# nothing is written outside $TMP, no network, no provider CLI.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }
[ -n "${BASH:-}" ] || BASH="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }

# run_sandboxed <home> <command…> — run a command in the isolated environment every case uses.
run_sandboxed() {
  local h="$1"; shift
  # GIT_CEILING_DIRECTORIES: a temp dir that happens to sit inside some git work tree must not lend
  # its history to the copies below, which are git checkouts only when this file makes them one.
  env -i PATH="$PATH" HOME="$h" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$h/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 GIT_CEILING_DIRECTORIES="$TMP" XDG_CONFIG_HOME="$h/.config" ZUVO_DIST_ROOT="$h.dist" "$@"
}
# repo_copy <dir> — the files install.sh needs to start, without the rest of the repo.
repo_copy() {
  mkdir -p "$1/scripts"
  cp "$ROOT/package.json" "$1/"
  cp -R "$ROOT/scripts/install.sh" "$ROOT/scripts/install.d" "$ROOT/scripts/lib" "$1/scripts/"
}

# (1) a missing module, RUN: refused by name, exit 1, before any host banner, nothing in HOME
R="$TMP/missing-run"; repo_copy "$R"; rm "$R/scripts/install.d/codex.sh"
H="$TMP/h1"; mkdir -p "$H"
run_sandboxed "$H" "$BASH" "$R/scripts/install.sh" claude > "$TMP/1.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && grep -q "REFUSING: cannot read .*/scripts/install.d/codex.sh" "$TMP/1.out" \
   && ! grep -q 'CLAUDE CODE' "$TMP/1.out" && [ -z "$(ls -A "$H")" ]; then
  pass "(1) a missing module stops install.sh by name, before any host is touched (exit 1, HOME untouched)"
else
  bad "(1) missing module, run: exit $rc, HOME: [$(ls -A "$H" | tr '\n' ' ')], output: $(tail -3 "$TMP/1.out")"
fi

# (2) the same tree, SOURCED: install.sh returns 1 and the sourcing shell carries on
H="$TMP/h2"; mkdir -p "$H"
out="$(run_sandboxed "$H" "$BASH" -c '. "$1"; echo "after-source rc=$?"' _ "$R/scripts/install.sh" 2>&1)"
if printf '%s\n' "$out" | grep -q '^after-source rc=1$'; then
  pass "(2) sourced with a missing module, install.sh returns 1 instead of killing the caller"
else
  bad "(2) sourced with a missing module: $(printf '%s' "$out" | tail -2)"
fi

# (3) install_claude ships install.d/ beside the cached install.sh, and that copy still loads
H="$TMP/h3"; CB="$H/.claude/plugins/cache/zuvo-marketplace/zuvo"
mkdir -p "$CB/0.0.1/skills/old-skill" "$CB/0.0.1/shared/includes" "$CB/0.0.1/rules" "$CB/0.0.1/scripts"
printf '# seed\n' > "$CB/0.0.1/skills/old-skill/SKILL.md"
run_sandboxed "$H" "$BASH" -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude' _ "$ROOT/scripts/install.sh" > "$TMP/3.out" 2>&1
rc=$?
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/package.json")"
missing=""
for d in 0.0.1 "$VERSION"; do
  cmp -s "$ROOT/scripts/install.sh" "$CB/$d/scripts/install.sh" || missing="$missing $d/install.sh"
done
for m in "$ROOT"/scripts/install.d/*.sh; do
  for d in 0.0.1 "$VERSION"; do
    cmp -s "$m" "$CB/$d/scripts/install.d/${m##*/}" || missing="$missing $d/${m##*/}"
  done
done
[ "$rc" -eq 0 ] && [ -z "$missing" ] \
  && pass "(3) install.sh and every install.d module reach both cache dirs (seed + current), byte-identical" \
  || bad "(3) install_claude exit $rc; modules missing or different in the cache:$missing [$(tail -2 "$TMP/3.out")]"
H4="$TMP/h4"; mkdir -p "$H4"
want_fns="$(run_sandboxed "$H4" "$BASH" -c '. "$1" >/dev/null 2>&1; declare -F | grep -c " install_"' _ "$ROOT/scripts/install.sh" 2>&1)"
out="$(run_sandboxed "$H4" "$BASH" -c '. "$1" >/dev/null 2>&1; echo "rc=$?"; declare -F | grep -c " install_"' _ "$CB/$VERSION/scripts/install.sh" 2>&1)"
[ "$want_fns" -ge 10 ] && [ "$(printf '%s\n' "$out" | tr '\n' ' ')" = "rc=0 $want_fns " ] \
  && pass "(3b) the cached install.sh sources cleanly and defines all $want_fns install_* functions" \
  || bad "(3b) the cached install.sh does not load: $(printf '%s' "$out" | tr '\n' ' ')"

# --- the entry point's own behaviour around the install ------------------------------------------

# (4) the provider list survives `set -e` when one provider is missing. print_providers is all
# `cond && echo` lines; it used to return the LAST test's status — 1 without the claude CLI — and
# the bare call then ended the install right after its DONE banner, summary and sleep guard skipped.
STUB="$TMP/stubbin"; mkdir -p "$STUB"; printf '#!/bin/sh\nexit 0\n' > "$STUB/codex"; chmod +x "$STUB/codex"
# (Its nested print_providers closes with an INDENTED brace, so the first column-0 `}` is its own.)
FN="$(sed -n '/^check_cross_providers() {/,/^}/p' "$ROOT/scripts/install.sh")"
# PATH is the stub dir ALONE (check_cross_providers needs only builtins), so "claude is absent" is
# established, not assumed of the host's /usr/bin.
claude_on_path="$(env -i PATH="$STUB" "$BASH" -c 'command -v claude' 2>/dev/null)"
out="$(env -i PATH="$STUB" HOME="$TMP" FN="$FN" "$BASH" -c 'set -euo pipefail; eval "$FN"; check_cross_providers; echo SURVIVED' 2>&1)"
[ -z "$claude_on_path" ] && printf '%s' "$FN" | grep -q 'print_providers() {' \
  && printf '%s\n' "$out" | grep -q '✓ codex (OpenAI)' && [ "$(printf '%s\n' "$out" | tail -1)" = SURVIVED ] \
  && pass "(4) with codex present and claude absent, the provider list prints and the set -e shell carries on" \
  || bad "(4) provider list under set -e (codex only; claude on the stub PATH: '${claude_on_path:-none}'): [$(printf '%s' "$out" | tail -3 | tr '\n' '|')]"

# (5) a downgrade refusal while SOURCED returns 1 — it used to `exit`, killing the sourcing shell
G="$TMP/gitrepo"; repo_copy "$G"
git -C "$G" init -q && git -C "$G" add -A \
  && git -C "$G" -c user.email=t@example.invalid -c user.name=t commit -qm init \
  || bad "(5) could not build the throwaway git repo"
H="$TMP/h5"; mkdir -p "$H/.zuvo"
printf '0123456789abcdef0123456789abcdef01234567\nmain\n' > "$H/.zuvo/.installed-from"
out="$(run_sandboxed "$H" "$BASH" -c '. "$1" 2>&1; echo "alive rc=$?"' _ "$G/scripts/install.sh" 2>&1)"
printf '%s\n' "$out" | grep -q 'REFUSING: the installed commit 0123456 is not in this repository' \
  && [ "$(printf '%s\n' "$out" | tail -1)" = "alive rc=1" ] \
  && pass "(5) sourced with a stamp this repo cannot resolve, install.sh refuses (by name) with status 1 and the caller survives" \
  || bad "(5) downgrade refusal while sourced: [$(printf '%s' "$out" | tail -2 | tr '\n' '|')] — want the refusal, then 'alive rc=1'"

# (6) sourcing writes NOTHING into HOME: the sleep guard runs only when install.sh is executed
H="$TMP/h6"; mkdir -p "$H"
out="$(run_sandboxed "$H" "$BASH" -c '. "$1" >/dev/null 2>&1; echo "rc=$?"; declare -F install_claude_home >/dev/null && echo loaded' _ "$ROOT/scripts/install.sh")"
[ "$(printf '%s\n' "$out" | tr '\n' ' ')" = "rc=0 loaded " ] && [ -z "$(ls -A "$H")" ] \
  && pass "(6) sourcing install.sh succeeds, defines the installer, and leaves HOME empty (no ~/.zshenv, no ~/.zuvo)" \
  || bad "(6) sourcing: [$(printf '%s' "$out" | tr '\n' ' ')], HOME: $(cd "$H" && find . -mindepth 1 | head -5 | tr '\n' ' ')"

# The stamp cases need a checkout WITH history (the stamp records a commit) and must mean the same
# thing on a machine whose checkout has .git and on the farm, whose mirror does not: so they run from
# a throwaway git copy of the tracked tree, and (10) from a copy without .git.
FULL="$TMP/full"; mkdir -p "$FULL"
tar -C "$ROOT" --exclude=./.git --exclude=./dist --exclude=./zuvo --exclude=./node_modules -cf - . | tar -C "$FULL" -xf -
GITFULL="$TMP/gitfull"; cp -R "$FULL" "$GITFULL"
git -C "$GITFULL" init -q && git -C "$GITFULL" add -A \
  && git -C "$GITFULL" -c user.email=t@example.invalid -c user.name=t commit -qm init \
  || bad "(7) could not build the throwaway git copy of the repo"
GITSHA="$(git -C "$GITFULL" rev-parse HEAD 2>/dev/null)"

# (7) executed, a clean install still records its stamp and wires the sleep guard — the move of both
# into the main-run guard must not lose them
H="$TMP/h7"; mkdir -p "$H"
run_sandboxed "$H" "$BASH" "$GITFULL/scripts/install.sh" codex > "$TMP/7.out" 2>&1; rc=$?
stamp_ok=$(awk -v sha="$GITSHA" 'NR==1 && $0==sha {a=1} NR==2 && length($0) {b=1} NR==3 && /^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$/ {c=1} END {print (a && b && c && NR == 3) ? "yes" : "no"}' "$H/.zuvo/.installed-from" 2>/dev/null)
[ "$rc" -eq 0 ] && [ -n "$GITSHA" ] && [ "$stamp_ok" = yes ] \
  && grep -q 'zuvo sleep guard' "$H/.zshenv" 2>/dev/null \
  && pass "(7) a clean run from git exits 0, stamps the installed commit and wires the sleep guard into ~/.zshenv" \
  || bad "(7) clean run: exit $rc, stamp $([ -f "$H/.zuvo/.installed-from" ] && echo yes || echo NO), sleep guard $(grep -c 'zuvo sleep guard' "$H/.zshenv" 2>/dev/null || echo 0) [$(tail -2 "$TMP/7.out" | tr '\n' '|')]"

# (8) an INCOMPLETE install records no stamp: the stamp is what the next run's downgrade guard
# trusts, and it used to be written before the INSTALL INCOMPLETE check, under the DONE banner
H="$TMP/h8"; mkdir -p "$H/.zuvo/model-subprocess.sh"      # a directory where a file must land
run_sandboxed "$H" "$BASH" "$GITFULL/scripts/install.sh" codex > "$TMP/8.out" 2>&1; rc=$?
[ "$rc" -ne 0 ] && grep -q 'INSTALL INCOMPLETE' "$TMP/8.out" && [ ! -e "$H/.zuvo/.installed-from" ] && [ ! -e "$H/.zshenv" ] \
  && pass "(8) an INCOMPLETE install exits $rc, writes no stamp and wires no sleep guard" \
  || bad "(8) INCOMPLETE install: exit $rc, stamp $([ -e "$H/.zuvo/.installed-from" ] && echo WRITTEN || echo absent)"

# (9) a stamp that cannot be written is reported, not swallowed
H="$TMP/h9"; mkdir -p "$H/.zuvo/.installed-from"           # a directory where the stamp file goes
run_sandboxed "$H" "$BASH" "$GITFULL/scripts/install.sh" codex > "$TMP/9.out" 2>&1; rc=$?
left="$(cd "$H/.zuvo" && for f in .installed-from.new.* ..installed-from.*; do [ -e "$f" ] && printf '%s ' "$f"; done)"
[ "$rc" -eq 0 ] && grep -q 'could not write ~/.zuvo/.installed-from' "$TMP/9.out" && [ -d "$H/.zuvo/.installed-from" ] && [ -z "$left" ] \
  && pass "(9) an unwritable stamp is reported, the install still succeeds, what was there is left alone, no temp files" \
  || bad "(9) unwritable stamp: exit $rc, temp files left [$left] [$(tail -2 "$TMP/9.out" | tr '\n' '|')]"

# (10) from a tree WITHOUT git history no stamp is written: its first line used to be the date, and
# the next install from a git checkout read that as an unknown commit and refused
H="$TMP/h10"; mkdir -p "$H"
run_sandboxed "$H" "$BASH" "$FULL/scripts/install.sh" codex > "$TMP/10.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.zuvo/.installed-from" ] \
  && pass "(10) an install from a tree without git history writes no stamp" \
  || bad "(10) non-git install: exit $rc, stamp [$(head -1 "$H/.zuvo/.installed-from" 2>/dev/null)]"
# …and leaves a stamp an earlier git install wrote exactly as it was
H="$TMP/h10b"; mkdir -p "$H/.zuvo"; printf '%s\nmain\n2026-01-01T00:00:00Z\n' "$GITSHA" > "$H/.zuvo/.installed-from"
cp "$H/.zuvo/.installed-from" "$TMP/10b.before"
run_sandboxed "$H" "$BASH" "$FULL/scripts/install.sh" codex > "$TMP/10b.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$TMP/10b.before" "$H/.zuvo/.installed-from" \
  && pass "(10b) a non-git install leaves an existing stamp byte-identical" \
  || bad "(10b) non-git install over an existing stamp: exit $rc, stamp $(cmp -s "$TMP/10b.before" "$H/.zuvo/.installed-from" && echo kept || echo CHANGED)"
# …and a copy that merely sits INSIDE some other git repository is not a git checkout of zuvo: it must
# not stamp that repository's commit (`rev-parse` walks up to the enclosing work tree)
NESTED="$GITFULL/vendored-copy"; cp -R "$FULL" "$NESTED"
H="$TMP/h10c"; mkdir -p "$H"
run_sandboxed "$H" "$BASH" "$NESTED/scripts/install.sh" codex > "$TMP/10c.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.zuvo/.installed-from" ] \
  && pass "(10c) a copy nested inside another git repository writes no stamp" \
  || bad "(10c) nested copy: exit $rc, stamp [$(head -1 "$H/.zuvo/.installed-from" 2>/dev/null)] (the enclosing repo is $GITSHA)"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
