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
# swallowed by `|| true`, so on Windows install.sh would report success while leaving
# `{plugin_root}` placeholders unsubstituted.
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
