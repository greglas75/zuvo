#!/usr/bin/env bash
# tests/lib/installer-sources.sh must hand text-reading tests the WHOLE installer, or refuse.
#
# Since install.sh loads its code from scripts/install.d/, a dozen tests read the installer's text
# through that helper, and several of them assert ABSENCE ("no blanket rm -rf …"). Against a short
# text an absence check passes, so the helper's contract is about what it refuses: a module
# install.sh loads that is missing, a module in install.d/ that install.sh never loads, and a file
# whose missing final newline would glue two files together. Every case runs on a throwaway copy of
# the installer; nothing here reads or writes the real tree beyond copying it.
#
# Test level: SMALL — file copies in a temp dir and bash subprocesses; no network, no install.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }

n=0
# copy_tree — a FRESH copy of install.sh + install.d/ + the helper, its root in $r. Not called as
# $(copy_tree): the counter would advance in a subshell only, and every case would share one tree.
copy_tree() {
  n=$((n + 1))
  r="$TMP/tree$n"
  mkdir -p "$r/scripts" "$r/tests/lib"
  cp "$ROOT/scripts/install.sh" "$r/scripts/"
  if [ -d "$ROOT/scripts/install.d" ]; then cp -R "$ROOT/scripts/install.d" "$r/scripts/"; fi
  cp "$ROOT/tests/lib/installer-sources.sh" "$r/tests/lib/"
}
# helper_in <root> <command…> — source the helper copy inside <root> and run a command in that shell.
helper_in() {
  local r="$1"; shift
  bash -c '. "$1/tests/lib/installer-sources.sh" || exit 3; shift; "$@"' _ "$r" "$@"
}

# (1) the list is install.sh, then exactly the modules install.sh loads, in ITS load order — taken
# here from the `_zi_source` calls by sed, independently of the helper's own parser.
copy_tree
want="$(printf '%s\n' "$r/scripts/install.sh"; sed -n 's/^_zi_source \([a-z -]*\) ||.*/\1/p' "$r/scripts/install.sh" \
        | tr ' ' '\n' | grep . | sed "s|.*|$r/scripts/install.d/&.sh|")"
got="$(helper_in "$r" installer_sources "$r")"
[ -n "$got" ] && [ "$got" = "$want" ] \
  && pass "(1) installer_sources = install.sh + the $(($(printf '%s\n' "$got" | wc -l) - 1)) modules install.sh loads, in load order" \
  || bad "(1) installer_sources differs from install.sh's own _zi_source list:
$(diff <(printf '%s\n' "$want") <(printf '%s\n' "$got") | head -10)"
[ "$(printf '%s\n' "$got" | wc -l)" -ge 2 ] \
  && pass "(1b) the installer loads at least one module (the split is in place)" \
  || bad "(1b) installer_sources found no modules — the absence checks would read install.sh alone"
want_text="$(while IFS= read -r f; do cat "$f"; done <<< "$want")"
[ "$(helper_in "$r" installer_text "$r")" = "$want_text" ] \
  && pass "(1c) installer_text is those files, concatenated in that order" \
  || bad "(1c) installer_text is not the concatenation of installer_sources"

# (2) a module in install.d/ that install.sh never loads is text the installer never runs
copy_tree; cp "$r/scripts/install.d/kimi.sh" "$r/scripts/install.d/orphan.sh"
out="$(helper_in "$r" true 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'orphan.sh is never loaded by install.sh' \
  && pass "(2) an install.d module install.sh never loads stops the test at source time (rc=$rc)" \
  || bad "(2) orphan module accepted (rc=$rc): $out"

# (3) a module install.sh loads but that is not there
copy_tree; rm "$r/scripts/install.d/codex.sh"
out="$(helper_in "$r" true 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "install.sh loads 'codex'" \
  && pass "(3) a missing module stops the test at source time, by name (rc=$rc)" \
  || bad "(3) missing module accepted (rc=$rc): $out"

# (3b) …and installer_text itself reports it when the tree breaks after the helper was loaded,
# because a later call cannot lean on the source-time check.
copy_tree
rc=$(bash -c '. "$1/tests/lib/installer-sources.sh" || exit 3; rm "$1/scripts/install.d/claude.sh"; installer_text "$1" >/dev/null 2>&1; echo $?' _ "$r")
[ "$rc" = 1 ] && pass "(3b) installer_text returns 1 once a loaded module disappears" \
  || bad "(3b) installer_text returned '$rc' for a tree with a missing module"

# (4) a file without a final newline must not run its last line into the next file's first: output.sh
# is followed by copy.sh, so copy.sh's shebang must still start a line.
copy_tree; printf '%s' "$(cat "$r/scripts/install.d/output.sh")" > "$r/scripts/install.d/output.sh"
modules=$(( $(helper_in "$r" installer_sources "$r" | wc -l) - 1 ))
shebangs=$(helper_in "$r" installer_text "$r" | grep -c '^#!/usr/bin/env bash$')
[ "$modules" -ge 1 ] && [ "$shebangs" -eq "$modules" ] \
  && pass "(4) every module still starts on its own line ($shebangs/$modules) when one lacks a final newline" \
  || bad "(4) $shebangs of $modules module shebangs start a line — two files were glued together"

# (5) a single-file installer (the layout before the split) is read as just install.sh
copy_tree; rm -rf "$r/scripts/install.d"
printf '%s\n' '#!/bin/bash' 'echo single-file installer' > "$r/scripts/install.sh"
got="$(helper_in "$r" installer_sources "$r")"
[ "$got" = "$r/scripts/install.sh" ] && pass "(5) without _zi_source calls or install.d/, the installer is install.sh alone" \
  || bad "(5) single-file layout read as: $got"

# (6) an unreadable install.sh is a refusal, not an empty text
copy_tree; rm "$r/scripts/install.sh"
out="$(helper_in "$r" true 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q 'cannot read' \
  && pass "(6) a missing install.sh stops the test at source time (rc=$rc)" || bad "(6) missing install.sh accepted (rc=$rc): $out"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
