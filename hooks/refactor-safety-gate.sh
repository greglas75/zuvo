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

# --no-renames: a renamed scope-fence file must still surface its OLD path (else the
#   contract never matches the new name -> bypass). core.quotePath=false: don't C-quote
#   non-ASCII paths (a quoted "..." path would never match the fence -> bypass).
ZERO=0000000000000000000000000000000000000000
case "$MODE" in
  pre-commit)
    files=$(git -c core.quotePath=false diff --cached --name-only --no-renames 2>/dev/null) || exit 0
    ;;
  pre-push)
    # stdin: <local ref> <local sha> <remote ref> <remote sha>
    files=""
    while read -r _lref lsha _rref rsha; do
      [ -n "$lsha" ] && [ -n "$rsha" ] || continue        # malformed line -> skip
      case "$lsha" in *[!0]*) : ;; *) continue ;; esac     # all-zero local sha = delete -> skip
      if [ "$rsha" = "$ZERO" ]; then
        # NEW branch: gate EVERY commit being introduced (not just the tip)
        diffargs=""
        for c in $(git rev-list "$lsha" --not --remotes 2>/dev/null); do
          diffargs="$diffargs
$(git -c core.quotePath=false show --name-only --no-renames --pretty=format: "$c" 2>/dev/null)"
        done
        # conservative fallback: if enumeration produced nothing (git error / odd object
        # state), still gate the tip commit rather than silently passing an empty list
        [ -n "$(printf '%s' "$diffargs" | tr -d '[:space:]')" ] || \
          diffargs="$(git -c core.quotePath=false show --name-only --no-renames --pretty=format: "$lsha" 2>/dev/null)"
      else
        # EXISTING branch: the full pushed range rsha..lsha (NOT just the tip)
        diffargs="$(git -c core.quotePath=false diff --name-only --no-renames "$rsha" "$lsha" 2>/dev/null)"
      fi
      files="$files
$diffargs"
    done
    ;;
  *) exit 0 ;;
esac

# Run BOTH gate checks (each prints its own BLOCK: line + returns non-zero on block).
blk=0
refactor_gate_check "$files" || blk=1
refactor_scope_gate_check "$files" || blk=1
plan_execute_gate_check "$files" || blk=1
if [ "$blk" != 0 ]; then
  echo "" >&2
  echo "zuvo work-gate: $MODE BLOCKED (see the BLOCK line above)." >&2
  echo "  refactor → complete the CONTRACT Prove step (blind-audit + adversarial)." >&2
  echo "  scope    → run \`zuvo:refactor <file>\` for off-contract files (reloads the protocol)." >&2
  echo "  plan     → run \`zuvo:execute\` (do not hand-roll the implementation)." >&2
  echo "  human / abandoned runs auto-bypass. Override (logged): ZUVO_ALLOW_ADHOC=1." >&2
  [ "${ZUVO_ALLOW_ADHOC:-}" = "1" ] && { echo "zuvo work-gate: ZUVO_ALLOW_ADHOC=1 -> escape (logged)" >&2; exit 0; }
  exit 1
fi
exit 0
