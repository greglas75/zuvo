#!/usr/bin/env bash
# scripts/install.d/copy.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Copy primitives every host installer uses: verify_copied, install_file_atomic, install_runner_lib
# and the hooks/lib vs scripts/lib name-collision guards.

# verify_copied <label> <src_dir> <dst_dir> <name> [<name>…]
verify_copied() {
  local label="$1" src="$2" dst="$3"; shift 3
  local n miss=0
  for n in "$@"; do
    [ -f "$src/$n" ] || continue          # never attempted — not a failure
    if [ ! -s "$dst/$n" ]; then           # -s, not -e: a 0-byte file is a failed copy too
      miss=$((miss + 1))
      INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      $label: $dst/$n"
    fi
  done
  if [ "$miss" -gt 0 ]; then
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + miss))
    fail "$label: $miss file(s) did NOT install — see the summary below"
    return 1
  fi
  return 0
}

# install_file_atomic <src> <dst> — put ONE file at <dst>, atomically, every step checked. Status 0
# and no output when <dst> ends up a regular file byte-identical to <src>; otherwise status 1 and the
# reason on stdout (for the caller's INSTALL_VERIFY_DETAIL). In order:
#   - refuse a <dst> that exists and is not a regular file: `mv -f tmp <a directory>` moves the temp
#     INTO the directory and returns 0 — the file never lands and the directory gains a stray;
#   - mktemp the temp IN <dst>'s directory (same filesystem, so mv is a rename — a reader never sees
#     a half-written file). mktemp creates it exclusively under an unpredictable name; a fixed
#     `.name.tmp.$$` can be pre-planted as a symlink that `cp` follows and `mv` then installs;
#   - cp into it, and cmp the TEMP against <src> — BEFORE anything replaces <dst>. A copy that
#     "succeeds" with the wrong bytes (truncated, disk full mid-write) is caught while <dst> still
#     holds whatever it held; the first version checked only after the mv, when a corrupted copy had
#     already replaced a good file;
#   - chmod it (mktemp makes it 0600; the exec bit follows the source), mv it over <dst>;
#   - cmp <src> <dst> once more: what a reader now opens at <dst> is what was checked.
# The verdict is the steps, not a final cmp alone: a cmp against a destination that ALREADY held the
# right bytes from an earlier install passed while every step had failed. A failure after mktemp
# removes the temp. Safe under the caller's `set -e` (call it in an `if`).
install_file_atomic() {
  local src="$1" dst="$2" tmp mode=644
  if [ ! -f "$src" ]; then printf 'source missing: %s' "$src"; return 1; fi
  if [ -e "$dst" ] && [ ! -f "$dst" ]; then printf 'refused: the destination exists and is not a regular file'; return 1; fi
  if ! tmp="$(mktemp "${dst%/*}/.${dst##*/}.XXXXXX" 2>/dev/null)"; then printf 'mktemp failed (in %s)' "${dst%/*}"; return 1; fi
  if ! cp "$src" "$tmp" 2>/dev/null; then rm -f "$tmp"; printf 'cp failed'; return 1; fi
  if ! cmp -s "$src" "$tmp"; then rm -f "$tmp"; printf 'content check failed (the copy differs from the source; the destination was left as it was)'; return 1; fi
  if [ -x "$src" ]; then mode=755; fi
  if ! chmod "$mode" "$tmp" 2>/dev/null; then rm -f "$tmp"; printf 'chmod failed'; return 1; fi
  if ! mv -f "$tmp" "$dst" 2>/dev/null; then rm -f "$tmp"; printf 'mv failed'; return 1; fi
  if ! cmp -s "$src" "$dst"; then printf 'content check failed after the move (the installed bytes differ from the source)'; return 1; fi
  return 0
}

# install_runner_lib <label> <src_lib_dir> <dst_scripts_dir> — ship the shared script libraries, EVERY
# regular file of <src_lib_dir> (scripts/lib/, or a build's dist/<platform>/scripts/lib/), into
# <dst_scripts_dir>/lib/: the first place the adversarial driver copied into <dst_scripts_dir> looks
# for its runner, model-subprocess.sh (<dir>/lib/ → <dir>/ → ~/.zuvo/). Every host that gets its own
# copy of the driver (~/.codex/scripts, ~/.cursor/scripts, ~/.gemini/antigravity/scripts,
# ~/.kimi-code/scripts) gets its libraries through here, and so does ~/.zuvo/lib/ (install_zuvo_home),
# so a driver and its libraries always come from the same install. ~/.zuvo alone is not enough:
# `install.sh claude` refreshes ~/.zuvo and leaves ~/.codex/scripts as it was, and a host driver that
# could only reach ~/.zuvo would run against a library from a different install. Every Claude cache
# dir gets its scripts/lib/ through here too.
#
# The whole directory, not a list of names: a library added to scripts/lib/ later (Plan B's
# blind-audit-panel.sh) must reach every host with no installer change, not go silently missing.
#
# Every file goes through install_file_atomic (a review starting mid-install must never source a
# half-written file), and every miss is counted and named for the INSTALL INCOMPLETE summary with the
# step that failed — never swallowed. One miss does not stop the other files. model-subprocess.sh is
# REQUIRED: a source dir without it is a miss (the driver cannot work without it; a driver that
# lacks it still starts, warns once, and loses its codex and claude lanes). Status 0 all installed,
# 1 not.
install_runner_lib() {
  local label="$1" src="$2" dst="$3/lib" f reason rc=0 mkdir_err=""
  if ! mkdir -p "$dst" 2>/dev/null; then mkdir_err="mkdir failed: $dst"; fi
  if [ ! -f "$src/model-subprocess.sh" ]; then
    _runner_lib_miss "$label" "$dst/model-subprocess.sh" "source missing: $src/model-subprocess.sh"
    rc=1
  fi
  for f in "$src"/*; do
    [ -f "$f" ] || continue
    if [ -n "$mkdir_err" ]; then
      reason="$mkdir_err"
    elif reason="$(install_file_atomic "$f" "$dst/${f##*/}")"; then
      continue
    fi
    _runner_lib_miss "$label" "$dst/${f##*/}" "$reason"
    rc=1
  done
  return "$rc"
}

# lib_name_collisions <hooks_lib_dir> <scripts_lib_dir> — every file name (space-separated, empty when
# none) that BOTH would put into one <host>/scripts/lib/: the Codex and Cursor installs copy
# hooks/lib/*.sh|*.py into the same directory install_runner_lib fills from scripts/lib/, so a shared
# name silently replaces a runner library with a hook helper (or the other way round).
lib_name_collisions() {
  local f out=""
  for f in "$1"/*.sh "$1"/*.py; do
    [ -f "$f" ] || continue
    if [ -e "$2/${f##*/}" ]; then out="$out ${f##*/}"; fi
  done
  printf '%s' "${out# }"
}

# guard_lib_collisions <label> <hooks_lib_dir> <scripts_lib_dir> <dst_lib_dir> — fail LOUDLY on any
# collision lib_name_collisions finds: each name is an install miss (INSTALL INCOMPLETE), named with
# the destination it corrupts. Status 0 none, 1 some. Cheap: two directory listings, no copy.
guard_lib_collisions() {
  local label="$1" c n
  c="$(lib_name_collisions "$2" "$3")"
  [ -z "$c" ] && return 0
  for n in $c; do
    INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
    INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      $label: $4/$n — hooks/lib/$n and scripts/lib/$n share a name, and one copy replaces the other"
  done
  fail "$label: hooks/lib/ and scripts/lib/ both ship [$c] into $4 — one silently replaces the other (rename one of them)"
  return 1
}

# _runner_lib_miss <label> <dst_path> <reason> — count and name one library that did not install.
_runner_lib_miss() {
  local lanes=""
  case "$2" in */model-subprocess.sh) lanes=" — the driver beside it loses its codex and claude review lanes" ;; esac
  INSTALL_VERIFY_MISSING=$((INSTALL_VERIFY_MISSING + 1))
  INSTALL_VERIFY_DETAIL="${INSTALL_VERIFY_DETAIL}
      $1: $2 — $3"
  fail "$1: ${2##*/} did NOT install ($3)$lanes"
}
