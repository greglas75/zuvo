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
skip() { printf 'SKIP: %s\n' "$1"; }
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

# (1) the list is install.sh, then exactly the modules install.sh loads, in ITS load order. The expected
# list is written out here, not derived: re-deriving it with the parser's own rule would agree with any
# mistake the parser makes. A module added to install.sh changes this list on purpose.
copy_tree
want="$(printf '%s\n' "$r/scripts/install.sh"; for m in output copy hooks claude zuvo-home claude-home codex cursor antigravity kimi; do
          printf '%s\n' "$r/scripts/install.d/$m.sh"; done)"
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
out="$(bash -c '. "$1/tests/lib/installer-sources.sh" || exit 3; rm "$1/scripts/install.d/claude.sh"; installer_text "$1" 2>/dev/null; echo "rc=$?"' _ "$r")"
[ "$out" = "rc=1" ] && pass "(3b) installer_text returns 1 once a loaded module disappears — and prints no partial text" \
  || bad "(3b) installer_text for a tree with a missing module: [$(printf '%s' "$out" | tail -c 120)]"

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

# (7) a module that exists but cannot be READ is refused like a missing one (the installer refuses it too)
if [ "$(id -u)" = 0 ]; then
  skip "(7) not run under root (a mode-000 file is readable by root)"
else
  copy_tree; chmod 000 "$r/scripts/install.d/kimi.sh"
  out="$(helper_in "$r" true 2>&1)"; rc=$?
  chmod 644 "$r/scripts/install.d/kimi.sh"
  [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -q "install.sh loads 'kimi' but .*kimi.sh cannot be read" \
    && pass "(7) an unreadable module stops the test at source time, by name (rc=$rc)" \
    || bad "(7) unreadable module accepted (rc=$rc): $out"
fi

# (8) the parser reads what install.sh RUNS: an indented call counts, a commented-out one does not, and a
# last line with no newline still counts — each checked against a hand-written installer.
copy_tree
printf '%s\n' '#!/bin/bash' '# _zi_source cursor || exit 1' '  _zi_source output copy || { return 1; }' > "$r/scripts/install.sh"
printf '%s' '_zi_source hooks || exit 1' >> "$r/scripts/install.sh"
for m in "$r"/scripts/install.d/*.sh; do case "${m##*/}" in output.sh|copy.sh|hooks.sh) ;; *) rm "$m" ;; esac; done
got="$(helper_in "$r" installer_modules "$r" | tr '\n' ' ')"
[ "$got" = "output copy hooks " ] && pass "(8) indented calls count, commented-out ones do not, a final unterminated line counts" \
  || bad "(8) parser read [$got], want [output copy hooks ]"

# (9) a module that passes the readability check but cannot be read as a FILE (a directory under the
# module's name): the helper refuses at source time — status 1, naming the incomplete text — and the
# test it was sourced into never gets to run
copy_tree; rm "$r/scripts/install.d/kimi.sh"; mkdir "$r/scripts/install.d/kimi.sh"
out="$(helper_in "$r" echo reached 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && printf '%s' "$out" | grep -q "the installer's text is incomplete" && ! printf '%s' "$out" | grep -q '^reached$' \
  && pass "(9) a module that is a directory: the helper refuses at source time with status 1, and nothing after it runs" \
  || bad "(9) a directory as a module: status $rc [$(printf '%s' "$out" | tail -2 | tr '\n' '|')]"

echo
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
