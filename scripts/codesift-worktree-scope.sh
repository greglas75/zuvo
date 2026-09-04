#!/usr/bin/env bash
#
# codesift-worktree-scope.sh — resolve the CodeSift scope for a path, ONCE, deterministically.
#
# Why this exists as a SCRIPT and not as another paragraph in codesift-setup.md:
# `codesift-setup.md` has carried the correct worktree rules for months, and the retro log
# still shows agents re-deriving them by hand under ~10 different invented names
# ("worktree-safe CodeSift indexing", "worktree-aware CodeSift scan", "codesift-current-worktree",
# "worktree index fallback", "worktree CodeSift alias", ...). A rule nothing executes is a rule
# that gets re-invented per session, and each re-invention is a chance to get it backwards —
# the expensive direction being "index_status says indexed, so I'll skip it", which in a linked
# worktree reports the PARENT checkout and describes files nobody is editing.
#
# One call replaces that whole rediscovery. It touches nothing: no index, no MCP, no network —
# only `git rev-parse`.
#
# Usage:
#   codesift-worktree-scope.sh [<scope-path>]     # default: $PWD
#
# Output — KEY=VALUE lines, one per line, stable contract:
#   scope_path=<abs path given>
#   target_repo=<abs toplevel of the tree that ACTUALLY holds the code>   (- when not a repo)
#   git_common_dir=<abs common dir>   # identical across linked worktrees of one repo; the ONLY
#                                     # stable repository identity — path prefixes do not separate siblings
#   is_linked_worktree=yes|no
#   codesift_scope_arg=path=<target_repo>|-
#   action=index_folder|scope_only|not_a_repo
#   reason=<one line>
#
# `action` is the whole point — it is the instruction, not a diagnosis:
#   index_folder  MUST call index_folder(path=<target_repo>) BEFORE any symbol/pattern query.
#                 A linked worktree resolves to its PARENT until indexed once; "already indexed"
#                 is about the repo the answer comes FROM, not about your tree.
#   scope_only    Main checkout. Pass path=/repo= explicitly anyway; do not rely on CWD resolution.
#   not_a_repo    No git repo at the scope. May be a multi-git-root workspace — detect sub-repos
#                 per directory; a root-level analyze_project reports the largest sub-repo's stack
#                 as if it were the whole workspace.
#
# Exit codes:
#   0  scope resolved (any action, including index_folder — it is an instruction, not a failure)
#   2  usage error / path does not exist
set -uo pipefail

SCOPE="${1:-$PWD}"

emit() {
  # emit <target_repo> <git_common_dir> <is_linked> <action> <reason>
  printf 'scope_path=%s\n' "$SCOPE_ABS"
  printf 'target_repo=%s\n' "$1"
  printf 'git_common_dir=%s\n' "$2"
  printf 'is_linked_worktree=%s\n' "$3"
  if [ "$1" = "-" ]; then
    printf 'codesift_scope_arg=-\n'
  else
    printf 'codesift_scope_arg=path=%s\n' "$1"
  fi
  printf 'action=%s\n' "$4"
  printf 'reason=%s\n' "$5"
}

if [ "$SCOPE" = "-h" ] || [ "$SCOPE" = "--help" ]; then
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
  exit 0
fi

if [ ! -e "$SCOPE" ]; then
  echo "scope path does not exist: $SCOPE" >&2
  exit 2
fi

# A file is a legitimate scope argument ("the file I am about to analyze"), and it is the
# form the include tells callers to pass. Resolve to its directory for the git queries.
if [ -f "$SCOPE" ]; then
  SCOPE_DIR="$(cd "$(dirname "$SCOPE")" && pwd)"
  SCOPE_ABS="$SCOPE_DIR/$(basename "$SCOPE")"
else
  SCOPE_DIR="$(cd "$SCOPE" && pwd)"
  SCOPE_ABS="$SCOPE_DIR"
fi

TOPLEVEL="$(git -C "$SCOPE_DIR" rev-parse --show-toplevel 2>/dev/null)"
if [ -z "$TOPLEVEL" ]; then
  emit "-" "-" "no" "not_a_repo" \
    "no git repo at scope; if this is a workspace root, detect sub-repos per directory"
  exit 0
fi

# --path-format=absolute is required, not cosmetic: bare --git-common-dir returns a RELATIVE
# ".git" from a main checkout and an absolute path from a linked worktree, so the two never
# compare equal and the key silently splits the repo it was meant to unify.
COMMON_DIR="$(git -C "$SCOPE_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
GIT_DIR="$(git -C "$SCOPE_DIR" rev-parse --path-format=absolute --git-dir 2>/dev/null)"
[ -z "$COMMON_DIR" ] && COMMON_DIR="-"
[ -z "$GIT_DIR" ] && GIT_DIR="-"

# A linked worktree is exactly "git-dir differs from git-common-dir". Comparing paths, branch
# names or the presence of a `.git` FILE all have false negatives; this one is definitional.
if [ "$GIT_DIR" != "$COMMON_DIR" ] && [ "$GIT_DIR" != "-" ] && [ "$COMMON_DIR" != "-" ]; then
  emit "$TOPLEVEL" "$COMMON_DIR" "yes" "index_folder" \
    "linked worktree: auto-indexing defers to the parent checkout, so index_status reports the PARENT as healthy while describing files that are not yours"
  exit 0
fi

emit "$TOPLEVEL" "$COMMON_DIR" "no" "scope_only" \
  "main checkout: pass path=/repo= explicitly rather than relying on CWD resolution"
exit 0
