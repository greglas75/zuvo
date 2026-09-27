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
# a `timeout` on the PATH on a host that only has `gtimeout`). Nothing found: nothing linked, no error.
# Status: 0, or 1 when <dir> is not a directory (nothing is linked then).
#
# Sourced, never executed; defines this one function and nothing else. bash 3.2-compatible.
hermetic_link_tools() {
  local dir="${1:-}" spec name cands cand real
  [ -n "$dir" ] && [ -d "$dir" ] || { echo "hermetic_link_tools: not a directory: [$dir]" >&2; return 1; }
  shift
  for spec in "$@"; do
    name="${spec%%:*}"; cands="$spec"; real=""
    while [ -n "$cands" ]; do
      cand="${cands%%:*}"
      case "$cands" in *:*) cands="${cands#*:}" ;; *) cands="" ;; esac
      real="$(command -v "$cand" 2>/dev/null || true)"
      [ -z "$real" ] || break
    done
    [ -z "$real" ] || ln -s "$real" "$dir/$name"
  done
  return 0
}
