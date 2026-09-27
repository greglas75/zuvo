#!/usr/bin/env bash
# portable.sh — the two cross-platform primitives this repo kept getting wrong.
#
# Source it: . "$(dirname "$0")/lib/portable.sh"
#
# Windows is a supported target (users run Claude Code with Git Bash), so "works on macOS" is not
# the bar. Both helpers below were verified on BSD sed (macOS), GNU sed (debian) and busybox sed
# (alpine) before being written down.

# ── sed_i: in-place edit that works everywhere ────────────────────────────────
#
# `sed -i '' 's/a/b/' f` is BSD-only. On GNU and busybox the empty string is consumed as the
# SCRIPT, the real script becomes a filename, and the command dies with:
#     sed: s/a/b/: No such file or directory   (exit 1)
# This repo had 15 of those in install.sh / dev-push.sh / the three build scripts — two of them
# swallowed by `|| true`, so on Windows install.sh would report success while leaving the braced
# plugin_root placeholders unsubstituted. (Named without its braces on purpose: this file ships
# verbatim in every build's scripts/lib/, and the Antigravity/Kimi builds fail on any literal
# placeholder left in their output — the check that catches a real unsubstituted one.)
#
# `sed -i.<suffix>` takes the suffix ATTACHED on all three implementations, so it is the portable
# form. The backup is removed on success; on failure it is left behind and the original is
# restored, so a half-applied edit cannot survive.
#
#   sed_i 's/a/b/' file
#   sed_i -e 's/a/b/' -e 's/c/d/' file
sed_i() {
  if [ "$#" -lt 2 ]; then
    echo "sed_i: need at least a script and a file" >&2
    return 2
  fi
  local _f="${!#}"
  if [ ! -f "$_f" ]; then
    echo "sed_i: not a file: $_f" >&2
    return 2
  fi
  if sed -i.zbak "$@"; then
    rm -f "$_f.zbak"
    return 0
  fi
  # Restore rather than leave a partially-rewritten file behind.
  [ -f "$_f.zbak" ] && mv -f "$_f.zbak" "$_f"
  return 1
}

# ── zuvo_ship_runner_lib: a build's scripts/lib/ ──────────────────────────────
#
# zuvo_ship_runner_lib <plugin_dir> <dist_dir> <label> — put EVERY regular file of
# <plugin_dir>/scripts/lib/ into <dist_dir>/scripts/lib/, where the adversarial-review.sh a build ships
# looks for its codex/claude runner (model-subprocess.sh) first. The whole directory, not one name: the
# installer ships that dir through install_runner_lib, and a library added to scripts/lib/ later must
# reach the host without a build change. model-subprocess.sh is checked by name: a driver shipped
# without it loses its codex and claude lanes, so its absence fails the build (status 1, <label> in the
# message) rather than shipping a half-working driver. The destination is CLEARED first — regenerated,
# never merged into — so a library removed upstream cannot linger there (test-install-wiring.sh (14f),
# test-kimi-build.sh (11b)). Every step's failure is the function's status, so a build under `set -e`
# stops on it. The Antigravity and Kimi builds call this; it used to be the same 17 lines in each.
# An EMPTY <plugin_dir> or <dist_dir> is refused (status 1, nothing removed): an empty <dist_dir> made
# the clearing step `rm -rf /scripts/lib`, a path at the filesystem root.
zuvo_ship_runner_lib() {
  local plugin="${1:-}" dist="${2:-}" label="${3:-}" lib
  if [ -z "$plugin" ] || [ -z "$dist" ]; then
    echo "ERROR: zuvo_ship_runner_lib: empty <plugin_dir> [$plugin] or <dist_dir> [$dist] — refusing to clear or ship ${label:-a} scripts/lib/" >&2
    return 1
  fi
  if [ ! -f "$plugin/scripts/lib/model-subprocess.sh" ]; then
    echo "ERROR: scripts/lib/model-subprocess.sh is missing — the $label adversarial-review.sh cannot run its codex and claude lanes without it" >&2
    return 1
  fi
  rm -rf -- "$dist/scripts/lib" || return 1
  mkdir -p "$dist/scripts/lib" || return 1
  for lib in "$plugin"/scripts/lib/*; do
    [ -f "$lib" ] || continue
    cp "$lib" "$dist/scripts/lib/" || return 1
  done
}

# ── zuvo_python: resolve a Python 3 interpreter ───────────────────────────────
#
# `python3` is not a command on Windows. Python from python.org installs `python` and the `py`
# launcher; Git Bash ships neither. This repo had 83 bare `python3` calls and zero fallbacks —
# including on the runtime path, since skills invoke ~/.zuvo helpers that are Python.
#
# Prints the interpreter to stdout and returns 0, or returns 1 with a message on stderr. Callers
# that can degrade should do so; callers that cannot should exit.
#
#   PY="$(zuvo_python)" || exit 1
#   "$PY" script.py
zuvo_python() {
  if [ -n "${ZUVO_PYTHON:-}" ] && command -v "$ZUVO_PYTHON" >/dev/null 2>&1; then
    printf '%s\n' "$ZUVO_PYTHON"; return 0
  fi
  local c
  for c in python3 python; do
    # `python` may be a Python 2 (old Linux) or the Windows Store stub that prints a message and
    # exits non-zero — check the major version rather than trusting the name.
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0]==3 else 1)' 2>/dev/null; then
      printf '%s\n' "$c"; return 0
    fi
  done
  # Windows py launcher, last: it is a shim, so prefer a direct interpreter when one exists.
  if command -v py >/dev/null 2>&1 && py -3 -c 'import sys' >/dev/null 2>&1; then
    printf '%s\n' "py -3"; return 0
  fi
  echo "zuvo: no Python 3 found (tried python3, python, py -3). Set ZUVO_PYTHON=<path>." >&2
  return 1
}
