#!/usr/bin/env bash
# Pre-commit gate for zuvo:execute.
# Blocks git commit when the current execute task has no captured
# adversarial artifact, or when the artifact is older than staged edits.

set -euo pipefail

INPUT=$(cat 2>/dev/null || true)

case "$INPUT" in
  *"git commit"*) ;;
  *) exit 0 ;;
esac

# Resolve the canonical zuvo context dir (see
# shared/includes/report-output-location.md), falling back to the legacy hidden
# .zuvo/ location for sessions started before the migration.
ZUVO_DIR="${ZUVO_OUTPUT_DIR:-$(git -C "$PWD" rev-parse --show-toplevel 2>/dev/null || echo "$PWD")/zuvo}"
CTX_DIR="$ZUVO_DIR/context"
[ -d "$CTX_DIR" ] || CTX_DIR="$PWD/.zuvo/context"

STATE_FILE="$CTX_DIR/execution-state.md"

# Secondary signal (closes the state-drift no-op): a YOUNG execute run-marker for
# THIS repo means an execute IS in flight even when execution-state.md is missing
# or not in-progress. Without this, a single-agent fallback that never wrote the
# state file lets every commit bypass the adversarial gate (the 2026-06-15
# "ceremony skipped" drift). Scope is tight — only a fresh marker for this exact
# repo engages the secondary path — so unrelated repos/commits are unaffected.
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
  # No state file = normally nothing to gate. But a young execute marker says a
  # run is active — that is the drift. Require SOME fresh adversarial artifact;
  # if there is none, block rather than silently bypass.
  if [ -n "$active_exec_marker" ] && ! ls "$CTX_DIR"/adversarial-task-*.txt >/dev/null 2>&1; then
    echo "BLOCKED: active zuvo:execute run-marker for this repo, but no execution-state.md"
    echo "and no adversarial artifact in $CTX_DIR — execute state-drift (gate would be bypassed)."
    echo "  Marker: $active_exec_marker"
    echo "Fix: run Step 7b adversarial review before committing."
    echo "     If this marker is stale (run already finished/abandoned), clear it:"
    echo "       rm \"$active_exec_marker\""
    exit 1
  fi
  exit 0
fi

if ! grep -q '<!-- status: in-progress -->' "$STATE_FILE" 2>/dev/null; then
  # Not in-progress per the state file. If a young execute marker nonetheless
  # says a run is live and no adversarial artifact exists, that mismatch is the
  # drift — do not silently no-op.
  if [ -n "$active_exec_marker" ] && ! ls "$CTX_DIR"/adversarial-task-*.txt >/dev/null 2>&1; then
    echo "BLOCKED: young zuvo:execute run-marker for this repo, but execution-state.md is"
    echo "not in-progress and no adversarial artifact exists — execute state-drift."
    echo "  Marker: $active_exec_marker"
    echo "Fix: run Step 7b adversarial review, or clear a stale marker: rm \"$active_exec_marker\""
    exit 1
  fi
  exit 0
fi

task_id=$(awk -F': ' '/^next-task:/ {print $2; exit}' "$STATE_FILE" | tr -d '[:space:]')
if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
  echo "BLOCKED: active zuvo:execute session has malformed next-task in $STATE_FILE."
  echo "Fix the state file before committing."
  exit 1
fi

artifact_path="$CTX_DIR/adversarial-task-${task_id}.txt"
artifact_rel="${artifact_path#"$PWD"/}"

if [[ ! -s "$artifact_path" ]]; then
  echo "BLOCKED: missing adversarial artifact for execute task ${task_id}."
  echo "Expected: $artifact_rel"
  echo "Run Step 7b before commit."
  echo "Example: git add -u && git diff --staged | adversarial-review --mode code --artifact \"$artifact_rel\""
  echo "Use --mode security or --mode migrate when the diff is high-risk."
  exit 1
fi

if ! grep -q '^artifact_kind=adversarial-review$' "$artifact_path" 2>/dev/null; then
  echo "BLOCKED: adversarial artifact for task ${task_id} is malformed."
  echo "Re-run adversarial review and overwrite $artifact_rel."
  exit 1
fi

file_mtime() {
  local path="$1"
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
  else
    stat -c %Y "$path"
  fi
}

artifact_mtime=$(file_mtime "$artifact_path")
latest_staged_mtime=0

while IFS= read -r path; do
  [[ -z "$path" ]] && continue
  if [[ -e "$PWD/$path" ]]; then
    path_mtime=$(file_mtime "$PWD/$path")
    if [[ "$path_mtime" -gt "$latest_staged_mtime" ]]; then
      latest_staged_mtime="$path_mtime"
    fi
  fi
done < <(git diff --cached --name-only --diff-filter=ACMR 2>/dev/null || true)

if [[ "$latest_staged_mtime" -gt 0 && "$artifact_mtime" -lt "$latest_staged_mtime" ]]; then
  echo "BLOCKED: adversarial artifact for task ${task_id} is stale."
  echo "Re-run adversarial review after the latest staged edits and overwrite $artifact_rel."
  exit 1
fi

exit 0
