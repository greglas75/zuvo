#!/usr/bin/env bash
# tests/lib/hermetic-tools.sh — the real tools a hermetic suite links onto its narrowed PATH.
#
# The reviewer suites run the adversarial driver, the router, the preflight or the shared runner under
# `env -i … PATH=<spy dir>:/usr/bin:/bin`: spies instead of model CLIs, nothing inherited. GNU timeout
# and jq usually live somewhere else (Homebrew), and without timeout the driver exits before any client
# runs — so every suite resolved them on the CALLER's PATH, BEFORE narrowing it, and symlinked them into
# its spy dir. Five suites carried that loop (test-model-subprocess, test-adversarial-lane-golden,
# test-adversarial-claude-lane-bench, test-install-wiring, test-reviewer-preflight-isolation); this is
# the one copy.
#
# Linking only. What a MISSING tool means stays each suite's own verdict — an exit, a counted FAIL, or a
# FAIL further down where the tool is needed — so every caller still checks `[ -e <dir>/<name> ]` itself.
#
# Usage:
#   . "$ROOT/tests/lib/hermetic-tools.sh"
#   hermetic_link_tools <dir> <spec>...
# <spec> is a tool name — linked when `command -v` finds it — or <name>:<fallback>[:<fallback>…], which
# links <name> to the first of <name>, <fallback>… that `command -v` finds (e.g. `timeout:gtimeout` puts
# a `timeout` on the PATH on a host that only has `gtimeout`). Only a file on disk counts: `command -v`
# also answers with the bare name of a function, alias or builtin, and a link to that name would dangle
# on the narrowed PATH. Nothing found: nothing linked, no error.
# Status: 0; 1 when <dir> is not a directory (nothing is linked then), a <spec> names no tool, or a link
# could not be made (each said on stderr; the other specs are still linked). A link already there to the
# same file is not a failure.
#
# Sourced, never executed; defines this one function and nothing else. bash 3.2-compatible.
hermetic_link_tools() {
  local dir="${1:-}" spec name cands cand real st=0
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "hermetic_link_tools: not a directory: [$dir]" >&2; return 1; }
  shift
  for spec in "$@"; do
    name="${spec%%:*}"; cands="$spec"; real=""
    if [ -z "$name" ]; then echo "hermetic_link_tools: [$spec] names no tool" >&2; st=1; continue; fi
    while [ -n "$cands" ]; do
      cand="${cands%%:*}"
      case "$cands" in *:*) cands="${cands#*:}" ;; *) cands="" ;; esac
      real="$(command -v "$cand" 2>/dev/null || true)"
      case "$real" in /*) break ;; *) real="" ;; esac
    done
    [ -n "$real" ] || continue
    if ! ln -s "$real" "$dir/$name" 2>/dev/null && [ "$(readlink "$dir/$name" 2>/dev/null)" != "$real" ]; then
      echo "hermetic_link_tools: could not link $name -> $real in $dir" >&2; st=1
    fi
  done
  return "$st"
}
