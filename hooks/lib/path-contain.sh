#!/usr/bin/env bash
# path-contain.sh — ONE implementation of "is this ref safe to read/copy relative to the repo root".
#
# WHY THIS FILE EXISTS (B-PATH-CONTAIN-SHARED-FN). The rule lived in three copies:
# pipeline-gate-lib.sh::pg_artifact_proven, review-artifact-sync.sh::lint_artifact, and ::do_sync.
# Commit d568825 fixed two of them and missed the third, which REOPENED a real traversal; 9df7c06
# fixed the instance. Fixing an instance does not fix the shape — three copies means the next fix
# has three chances to miss one, and the miss is silent.
#
# Sourced by both trees, so it is installed next to each consumer (hooks/lib/ and each host's
# scripts/ dir). NOT `set -e`, no `exit`, no output on the success path: pipeline-gate-lib.sh is
# sourced by hooks that must not be killed by a helper.

# path_contained <root> <ref> → 0 = safe, 1 = reject
#
# THREE checks, in cost order, and each one catches something the others do not:
path_contained() {
  local _pc_root="${1:-}" _pc_ref="${2:-}" _pc_real_root _pc_target _pc_real_target
  [ -n "$_pc_ref" ] || return 1

  # 1. ABSOLUTE. Nothing relative to the root about it.
  case "$_pc_ref" in
    /*) return 1 ;;
  esac

  # 2. A path SEGMENT that is exactly `..`.
  #
  # Testing for the SUBSTRING `..` instead is the bug this rule keeps attracting: it denied
  # coverage to every proof named with the `<base7>..<head7>` convention the review skill
  # prescribes for its own artifacts (`zuvo/proofs/fd57e11..fc0c83e-adversarial.txt` is one
  # filename segment containing dots, not a traversal). Fail-closed in the wrong place is still
  # wrong — it blocked real reviews while stopping nothing a segment check does not.
  #
  # The leading `/` in `"/$_pc_ref"` is LOAD-BEARING: without it `../x` and a bare `..` match
  # NEITHER `*/../*` (which needs a slash before the dots) NOR `*/..`, fall through, and get read
  # or copied outside the checkout. `../../x` happens to still match, which is exactly why a
  # two-segment test case hides the bug.
  case "/$_pc_ref" in
    */../*|*/..) return 1 ;;
  esac

  # 3. CANONICAL containment. Checks 1-2 are lexical, and a lexical check cannot see a SYMLINK: a
  # ref with no `..` in it at all — `zuvo/proofs/innocent.txt` where `zuvo/proofs` is a symlink to
  # /etc — passes both and still resolves outside the repo. Only meaningful when the target
  # EXISTS, which is also the only time it gets read or copied, so a missing target legitimately
  # falls back to the lexical verdict rather than being rejected for not being there.
  if [ -n "$_pc_root" ] && [ -e "$_pc_root/$_pc_ref" ]; then
    _pc_real_root="$(_pc_canon "$_pc_root")" || return 1
    _pc_real_target="$(_pc_canon "$_pc_root/$_pc_ref")" || return 1
    [ -n "$_pc_real_root" ] && [ -n "$_pc_real_target" ] || return 1
    case "$_pc_real_target" in
      "$_pc_real_root"/*) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

# Canonicalize an EXISTING path. `realpath` is not universal (older macOS, minimal images) and
# `readlink -f` is GNU-only, so python3 is the fallback — this repo already depends on it
# everywhere. A canonicalizer that silently returns nothing would make check 3 reject everything,
# so each branch either prints an absolute path or fails.
_pc_canon() {
  local _p="$1"
  if command -v realpath >/dev/null 2>&1; then
    realpath -- "$_p" 2>/dev/null && return 0
  fi
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$_p" 2>/dev/null && return 0
  fi
  # Last resort: cd into it (or its parent) and let the shell resolve symlinks.
  if [ -d "$_p" ]; then
    ( cd "$_p" 2>/dev/null && pwd -P ) && return 0
  else
    ( cd "$(dirname "$_p")" 2>/dev/null && printf '%s/%s\n' "$(pwd -P)" "$(basename "$_p")" ) && return 0
  fi
  return 1
}
