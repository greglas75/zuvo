#!/usr/bin/env bash
# Pre-commit gate for zuvo:execute + best-effort pipeline-entry NUDGE.
#
# TWO responsibilities:
#   1. adversarial_gate (UNCHANGED, BLOCKING): during an active zuvo:execute run,
#      block git commit when the current task has no captured adversarial artifact,
#      or the artifact is older than staged edits.
#   2. pipeline_nudge (NEW, NON-BLOCKING): when an agent is committing substantial
#      unreviewed work (merge-base..HEAD + staged), print a loud stderr nudge to
#      run zuvo:build/review — but ALWAYS exit 0. This is a best-effort early
#      warning; the guarantee is the pre-push gate + CI (which DO block). Staging
#      tricks bypass this by design — acceptable because it is not the guarantee.
#
# FAIL-OPEN throughout (no repo / bad input / missing lib → exit 0). NOT set -e.

set -uo pipefail

INPUT=$(cat 2>/dev/null || true)

case "$INPUT" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# Source the shared lib for the nudge (fail-open if absent).
_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
if [ -r "$_self_dir/lib/pipeline-gate-lib.sh" ]; then
  # shellcheck source=/dev/null
  . "$_self_dir/lib/pipeline-gate-lib.sh"
fi

# ===========================================================================
# 1. adversarial_gate — preserved execute-run blocking logic. Returns 0|1.
# ===========================================================================
adversarial_gate() {
  local ZUVO_DIR CTX_DIR STATE_FILE REPO_ROOT MARKER_DIR GATE_GRACE active_exec_marker
  ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")/zuvo}"
  CTX_DIR="$ZUVO_DIR/context"
  [ -d "$CTX_DIR" ] || CTX_DIR="$PWD/.zuvo/context"
  STATE_FILE="$CTX_DIR/execution-state.md"

  REPO_ROOT=$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")
  MARKER_DIR="${ZUVO_HOME:-$HOME/.zuvo}/run-markers"
  GATE_GRACE="${ZUVO_GATE_GRACE:-21600}"   # 6h; matches retro-stub sweep grace
  active_exec_marker=""
  if [ -d "$MARKER_DIR" ]; then
    for _m in "$MARKER_DIR"/execute-*.marker; do
      [ -e "$_m" ] || continue
      _mrepo=$(sed -n 's/^repo_root=//p' "$_m" 2>/dev/null | head -1)
      if [ -n "$_mrepo" ]; then
        [ "$_mrepo" = "$REPO_ROOT" ] || continue
      else
        case "$(basename "$_m")" in *"$(basename "$REPO_ROOT")"*) ;; *) continue ;; esac
      fi
      _mts=$(sed -n 's/^start_ts=//p' "$_m" 2>/dev/null | head -1)
      _se=$(date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$_mts" +%s 2>/dev/null || date -u -d "$_mts" +%s 2>/dev/null || echo "")
      if [ -n "$_se" ] && [ "$(( $(date +%s) - _se ))" -le "$GATE_GRACE" ]; then
        active_exec_marker="$_m"; break
      fi
    done
  fi

  if [ ! -f "$STATE_FILE" ]; then
    if [ -n "$active_exec_marker" ] && ! ls "$CTX_DIR"/adversarial-task-*.txt >/dev/null 2>&1; then
      echo "BLOCKED: active zuvo:execute run-marker for this repo, but no execution-state.md" >&2
      echo "and no adversarial artifact in $CTX_DIR — execute state-drift (gate would be bypassed)." >&2
      echo "  Marker: $active_exec_marker" >&2
      echo "Fix: run Step 7b adversarial review before committing." >&2
      echo "     If this marker is stale (run already finished/abandoned), clear it:" >&2
      echo "       rm \"$active_exec_marker\"" >&2
      return 1
    fi
    return 0
  fi

  if ! grep -q '<!-- status: in-progress -->' "$STATE_FILE" 2>/dev/null; then
    if [ -n "$active_exec_marker" ] && ! ls "$CTX_DIR"/adversarial-task-*.txt >/dev/null 2>&1; then
      echo "BLOCKED: young zuvo:execute run-marker for this repo, but execution-state.md is" >&2
      echo "not in-progress and no adversarial artifact exists — execute state-drift." >&2
      echo "  Marker: $active_exec_marker" >&2
      echo "Fix: run Step 7b adversarial review, or clear a stale marker: rm \"$active_exec_marker\"" >&2
      return 1
    fi
    return 0
  fi

  local task_id artifact_path artifact_rel artifact_mtime latest_staged_mtime path path_mtime
  task_id=$(awk -F': ' '/^next-task:/ {print $2; exit}' "$STATE_FILE" | tr -d '[:space:]')
  if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
    echo "BLOCKED: active zuvo:execute session has malformed next-task in $STATE_FILE." >&2
    echo "Fix the state file before committing." >&2
    return 1
  fi

  artifact_path="$CTX_DIR/adversarial-task-${task_id}.txt"
  artifact_rel="${artifact_path#"$PWD"/}"

  if [[ ! -s "$artifact_path" ]]; then
    echo "BLOCKED: missing adversarial artifact for execute task ${task_id}." >&2
    echo "Expected: $artifact_rel" >&2
    echo "Run Step 7b before commit." >&2
    echo "Example: git add -u && git diff --staged | adversarial-review --mode code --artifact \"$artifact_rel\"" >&2
    echo "Use --mode security or --mode migrate when the diff is high-risk." >&2
    return 1
  fi

  if ! grep -q '^artifact_kind=adversarial-review$' "$artifact_path" 2>/dev/null; then
    echo "BLOCKED: adversarial artifact for task ${task_id} is malformed." >&2
    echo "Re-run adversarial review and overwrite $artifact_rel." >&2
    return 1
  fi

  file_mtime() {
    local path="$1"
    if stat -f %m "$path" >/dev/null 2>&1; then stat -f %m "$path"; else stat -c %Y "$path"; fi
  }

  artifact_mtime=$(file_mtime "$artifact_path")
  latest_staged_mtime=0
  while IFS= read -r path; do
    [[ -z "$path" ]] && continue
    if [[ -e "$PWD/$path" ]]; then
      path_mtime=$(file_mtime "$PWD/$path")
      if [[ "$path_mtime" -gt "$latest_staged_mtime" ]]; then latest_staged_mtime="$path_mtime"; fi
    fi
  done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)

  if [[ "$latest_staged_mtime" -gt 0 && "$artifact_mtime" -lt "$latest_staged_mtime" ]]; then
    echo "BLOCKED: adversarial artifact for task ${task_id} is stale." >&2
    echo "Re-run adversarial review after the latest staged edits and overwrite $artifact_rel." >&2
    return 1
  fi

  return 0
}

# ===========================================================================
# 2. pipeline_nudge — best-effort, NON-BLOCKING. Always returns 0.
# ===========================================================================
staged_substantial() {
  # substantial in the STAGED diff alone (the commit crossing the threshold)
  local root f a d p nfiles=0 lines=0
  root="$(pg_repo_root)" || return 1
  while IFS= read -r f; do
    [ -n "$f" ] || continue; pg_is_production "$f" && nfiles=$((nfiles+1))
  done < <(git -C "$root" diff --cached --name-only --diff-filter=ACMR 2>/dev/null)
  [ "$nfiles" -ge "$(pg_min_files)" ] && return 0
  while IFS=$'\t' read -r a d p; do
    [ -n "$p" ] || continue; pg_is_production "$p" || continue
    [ "$a" = "-" ] && a=0; [ "$d" = "-" ] && d=0
    case "$a$d" in *[!0-9]*) continue ;; esac
    lines=$((lines+a+d))
  done < <(git -C "$root" diff --cached --numstat 2>/dev/null)
  [ "$lines" -ge "$(pg_min_lines)" ] && return 0
  return 1
}

pipeline_nudge() {
  [ "${PG_LIB_LOADED:-}" = "1" ] || return 0      # no lib → no nudge
  pg_is_agent_env || return 0                      # humans commit freely
  pg_allow_adhoc && return 0                       # escape → silent

  local range substantial=1 reviewed
  range="$(pg_mergebase_range 2>/dev/null)" || range=""

  # substantial if committed-since-merge-base OR the staged diff is substantial
  if [ -n "$range" ] && pg_is_substantial "$range"; then
    substantial=0
  elif staged_substantial; then
    substantial=0
  fi
  [ "$substantial" -eq 0 ] || return 0             # nothing substantial → silent

  # reviewed coverage over the committed range (best-effort signal)
  reviewed=2
  if [ -n "$range" ]; then pg_range_reviewed "$range"; reviewed=$?; fi
  [ "$reviewed" -eq 0 ] && return 0                # already covered → silent

  {
    echo ""
    echo "⚠ zuvo: you are committing SUBSTANTIAL work that is not review-covered."
    [ -n "$range" ] && echo "  range: $range (+ staged)"
    echo "  This is a NUDGE, not a block — the commit proceeds. But the pre-push"
    echo "  gate and the CI gate WILL block this until it is reviewed."
    echo "  Do now:  run  zuvo:build  or  zuvo:review  on this work (writes the"
    echo "           covering memory/reviews/ artifact that unlocks push + CI)."
    echo "  Escape (logged): ZUVO_ALLOW_ADHOC=1"
    echo ""
  } >&2
  return 0
}

# ===========================================================================
# dispatch
# ===========================================================================
if ! adversarial_gate; then
  exit 1            # execute-run block preserved exactly
fi
pipeline_nudge
exit 0
