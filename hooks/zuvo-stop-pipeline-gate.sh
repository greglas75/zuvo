#!/usr/bin/env bash
# Stop-gate pipeline nudge (Claude Code Stop hook).
#
# When the agent tries to FINISH with substantial committed work that has no
# review coverage (@unpushed..HEAD), surface a "run zuvo:review before pushing"
# nudge. A Claude Code Stop hook returning exit 2 BLOCKS the stop and feeds
# stderr back to the agent (which then runs review); exit 0 lets the stop through
# but still prints the heads-up.
#
# DEFAULT = warn-only (exit 0). The scope is the WHOLE un-pushed pile
# (@unpushed..HEAD), not the last edit — so a tiny change on top of accumulated
# un-pushed work would otherwise FORCE a heavy review every stop (2026-07-10: a
# 3-line icon swap dragged the agent into a ~20-min multi-provider adversarial
# review of the whole pile). The real guarantee is still the pre-push + CI gates,
# which block the actual push of unreviewed work — you review ONCE when you push,
# not after every small edit. Set ZUVO_STOP_NUDGE_EXIT=2 to restore the old
# force-review-before-finishing behavior.
#
# FAIL-OPEN: bad JSON / no repo / missing lib / not substantial / reviewed → 0.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

# ---- loop guard: never block twice -----------------------------------------
is_active=false
if command -v jq >/dev/null 2>&1; then
  is_active=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null || echo false)
else
  case "$INPUT" in
    *'"stop_hook_active": true'*|*'"stop_hook_active":true'*) is_active=true ;;
  esac
fi
[ "$is_active" = "true" ] && exit 0

# ---- source lib (fail-open) -------------------------------------------------
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -r "$_self_dir/lib/pipeline-gate-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_dir/lib/pipeline-gate-lib.sh"
fi
[ "${PG_LIB_LOADED:-}" = "1" ] || exit 0

pg_is_agent_env || exit 0          # only nudge agent sessions
pg_allow_adhoc && exit 0           # escape valve → silent

# Prefer the un-pushed-only range so already-pushed history reviewed in other sessions
# (e.g. a long develop far ahead of main) is NOT counted as this session's unreviewed work.
# No remotes → merge-base fallback. Nothing un-pushed → nothing to nudge (clean exit).
range="$(pg_unpushed_range 2>/dev/null)"; _pur=$?
case "$_pur" in
  0) : ;;                                                       # un-pushed local work → use $range
  1) range="$(pg_mergebase_range 2>/dev/null)" || exit 0 ;;     # remote-less repo → merge-base
  *) exit 0 ;;                                                  # all pushed → nothing to review
esac
[ -n "$range" ] || exit 0
pg_is_substantial "$range" || exit 0          # small/docs/test-only → silent

pg_range_reviewed "$range"; rr=$?
[ "$rr" -eq 0 ] && exit 0                       # reviewed → fine

# substantial + not-reviewed → heads-up (warn-only by default; does NOT force a review here)
{
  echo ""
  echo "ℹ zuvo: you have SUBSTANTIAL unreviewed work accumulated ($range)."
  echo "  This is the WHOLE un-pushed pile, not just your last edit. Before you PUSH,"
  echo "  run  zuvo:review  (or zuvo:build) once — it writes the covering memory/reviews/"
  echo "  artifact so the pre-push + CI gates let the push through. No need to review now."
  echo "  Escape (logged): ZUVO_ALLOW_ADHOC=1   ·   Force-review-at-stop: ZUVO_STOP_NUDGE_EXIT=2"
  echo ""
} >&2

exit "${ZUVO_STOP_NUDGE_EXIT:-0}"
