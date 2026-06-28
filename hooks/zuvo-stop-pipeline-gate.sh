#!/usr/bin/env bash
# Stop-gate pipeline nudge (Claude Code Stop hook).
#
# When the agent tries to FINISH with substantial committed work that has no
# review coverage (merge-base..HEAD), surface a loud "run zuvo:review before
# finishing" nudge. Per the spike (notes verdict g), a Claude Code Stop hook
# returning exit 2 BLOCKS the stop and feeds stderr back to the agent, and
# `stop_hook_active` guards the loop — so this exits 2 to actively force review.
#
# Best-effort, NOT the guarantee: Codex + Antigravity have no Stop hook (the
# pre-push + CI gates cover them). If exit-2 ever stops blocking, set
# ZUVO_STOP_NUDGE_EXIT=0 to degrade to a non-blocking warning.
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

range="$(pg_mergebase_range 2>/dev/null)" || exit 0
[ -n "$range" ] || exit 0
pg_is_substantial "$range" || exit 0          # small/docs/test-only → silent

pg_range_reviewed "$range"; rr=$?
[ "$rr" -eq 0 ] && exit 0                       # reviewed → fine

# substantial + not-reviewed → nudge before finishing
{
  echo ""
  echo "⚠ zuvo: you are finishing with SUBSTANTIAL unreviewed work ($range)."
  echo "  Run  zuvo:review  (or zuvo:build) before finishing — it writes the covering"
  echo "  memory/reviews/ artifact. Otherwise the pre-push gate and CI gate WILL block"
  echo "  this work from being pushed/merged."
  echo "  Escape (logged): ZUVO_ALLOW_ADHOC=1"
  echo ""
} >&2

exit "${ZUVO_STOP_NUDGE_EXIT:-2}"
