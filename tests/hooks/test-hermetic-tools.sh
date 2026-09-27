#!/usr/bin/env bash
# tests/lib/hermetic-tools.sh — hermetic_link_tools, the one copy of the tool-linking loop five reviewer
# suites used to carry. Those suites only check that a tool ended up linked; these cases pin what the
# helper does when the lookup answers with something that is NOT a file (a function shadowing the tool),
# when a link cannot be made, and on a malformed spec — each of which used to link a dangling name or
# report success.
#
# Synthetic: every "tool" is a stub in a temp dir on a PATH this file builds, so nothing depends on
# what the host has installed. bash 3.2-compatible.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
LIB="$ROOT/tests/lib/hermetic-tools.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

[ -f "$LIB" ] || { bad "tests/lib/hermetic-tools.sh missing"; echo "SOME FAILED"; exit 1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/other"
for t in alpha beta; do printf '#!/bin/sh\necho %s\n' "$t" > "$T/bin/$t"; chmod +x "$T/bin/$t"; done
printf '#!/bin/sh\necho other\n' > "$T/other/alpha"; chmod +x "$T/other/alpha"

# link <dest dir> <shell prelude> <spec>... — run the helper in a fresh bash on PATH=$T/bin:/usr/bin:/bin
# after <prelude>; prints "rc=<status>" then the helper's stderr.
link() {
  local d="$1" pre="$2"; shift 2
  env -i PATH="$T/bin:/usr/bin:/bin" bash -c '. "$1"; eval "$2"; shift 2; hermetic_link_tools "$@" 2>&1; echo "rc=$?"' \
    _ "$LIB" "$pre" "$d" "$@"
}

# (1) a plain name found on PATH is linked to that file
mkdir -p "$T/d1"
out="$(link "$T/d1" : alpha)"
if [ "$(readlink "$T/d1/alpha")" = "$T/bin/alpha" ] && [ "${out##*rc=}" = 0 ]; then
  pass "(1) a tool found on PATH is linked to its file, status 0"
else
  bad "(1) alpha -> [$(readlink "$T/d1/alpha" 2>/dev/null)] out=[$out] (want $T/bin/alpha, rc=0)"
fi

# (2) a FUNCTION of the tool's name answers `command -v` with its bare name — never a link target:
#     the lookup falls through to the fallback file
mkdir -p "$T/d2"
out="$(link "$T/d2" 'alpha() { :; }' alpha:beta)"
if [ "$(readlink "$T/d2/alpha")" = "$T/bin/beta" ] && [ "${out##*rc=}" = 0 ]; then
  pass "(2) a function shadowing the tool is skipped; the fallback file is linked under the tool's name"
else
  bad "(2) alpha -> [$(readlink "$T/d2/alpha" 2>/dev/null)] out=[$out] (want $T/bin/beta — a link to the bare name dangles)"
fi

# (3) nothing on disk at all: nothing linked, no error (what a missing tool means is the caller's verdict)
mkdir -p "$T/d3"
out="$(link "$T/d3" 'gamma() { :; }' gamma)"
if [ ! -e "$T/d3/gamma" ] && [ ! -L "$T/d3/gamma" ] && [ "$out" = "rc=0" ]; then
  pass "(3) a tool that is only a function (no file) links nothing and is not an error"
else
  bad "(3) gamma linked [$(readlink "$T/d3/gamma" 2>/dev/null)] out=[$out] (want nothing, rc=0)"
fi

# (4) the same link again is not a failure; a DIFFERENT entry already under the name is, and is said
out="$(link "$T/d1" : alpha)"
if [ "$out" = "rc=0" ]; then pass "(4a) re-linking to the same file is status 0, silent"
else bad "(4a) re-link out=[$out] (want rc=0, no message)"; fi
mkdir -p "$T/d4"; ln -s "$T/other/alpha" "$T/d4/alpha"
out="$(link "$T/d4" : alpha)"
case "$out" in
  *"could not link alpha -> $T/bin/alpha"*"rc=1") pass "(4b) a different entry under the name: status 1, named on stderr" ;;
  *) bad "(4b) out=[$out] (want the could-not-link message and rc=1 — a stale link would pass as linked)" ;;
esac

# (5) a spec with no tool name (a leading colon) is refused; the other specs are still linked
mkdir -p "$T/d5"
out="$(link "$T/d5" : :beta alpha)"
case "$out" in
  *"[:beta] names no tool"*"rc=1")
    if [ "$(readlink "$T/d5/alpha")" = "$T/bin/alpha" ]; then pass "(5) an empty tool name is refused (status 1, said) and the rest are linked"
    else bad "(5) refused, but alpha was not linked after it"; fi ;;
  *) bad "(5) out=[$out] (want the names-no-tool message and rc=1)" ;;
esac

# (6) <dir> that is not a directory: status 1, nothing linked
out="$(link "$T/nope" : alpha)"
case "$out" in
  *"not a directory"*"rc=1") pass "(6) a missing <dir> is status 1, named" ;;
  *) bad "(6) out=[$out] (want not-a-directory and rc=1)" ;;
esac

echo "=== RESULT ==="
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; } || { echo "SOME FAILED"; exit 1; }
