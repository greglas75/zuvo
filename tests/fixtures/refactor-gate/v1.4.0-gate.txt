#!/bin/sh
# refactor-safety-gate.sh — zuvo:refactor commit-boundary gate ENTRY.
# Lives in the zuvo install (e.g. ~/.claude/hooks/); the target repo's
# .git/hooks/{pre-commit,pre-push} call this by ABSOLUTE path (baked at self-install).
#
# Modes:  pre-commit  -> gate the STAGED files
#         pre-push    -> backstop: gate the files in the push range (catches --no-verify)
#
# FAIL-OPEN everywhere: a missing lib or any internal error exits 0, so this gate can
# never brick `git commit`/`git push`. The block path is the ONLY non-zero exit.

MODE=${1:-pre-commit}
LIB="$(dirname "$0")/lib/refactor-gate-lib.sh"
[ -f "$LIB" ] || { echo "zuvo refactor-gate: lib not found ($LIB) -> fail-open" >&2; exit 0; }
. "$LIB" || exit 0

case "$MODE" in
  pre-commit)
    files=$(git diff --cached --name-only 2>/dev/null) || exit 0
    ;;
  pre-push)
    # stdin: <local ref> <local sha> <remote ref> <remote sha>
    files=""
    while read -r _lref lsha _rref rsha; do
      [ -n "$lsha" ] || continue
      case "$lsha" in *[!0]*) : ;; *) continue ;; esac   # skip deletes (all-zero local sha)
      if [ -z "${rsha##*[!0]*}" ] || [ "$rsha" = "0000000000000000000000000000000000000000" ]; then
        rng="$lsha"                                       # new branch: inspect the tip commit
        diffargs="$(git diff --name-only "${lsha}^" "$lsha" 2>/dev/null || git show --name-only --pretty=format: "$lsha" 2>/dev/null)"
      else
        diffargs="$(git diff --name-only "$rsha" "$lsha" 2>/dev/null)"
      fi
      files="$files
$diffargs"
    done
    ;;
  *) exit 0 ;;
esac

refactor_gate_check "$files" || {
  echo "" >&2
  echo "zuvo refactor-gate: $MODE BLOCKED — a refactor CONTRACT's Prove step is not complete." >&2
  echo "  Run the blind-audit + adversarial review and record them in the CONTRACT's prove fields," >&2
  echo "  or (human/abandoned run) the gate auto-bypasses. Override (logged): ZUVO_ALLOW_ADHOC=1." >&2
  [ "${ZUVO_ALLOW_ADHOC:-}" = "1" ] && { echo "zuvo refactor-gate: ZUVO_ALLOW_ADHOC=1 -> escape (logged)" >&2; exit 0; }
  exit 1
}
exit 0
