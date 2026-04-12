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

STATE_FILE="$PWD/.zuvo/context/execution-state.md"
[ -f "$STATE_FILE" ] || exit 0

if ! grep -q '<!-- status: in-progress -->' "$STATE_FILE" 2>/dev/null; then
  exit 0
fi

task_id=$(awk -F': ' '/^next-task:/ {print $2; exit}' "$STATE_FILE" | tr -d '[:space:]')
if ! [[ "$task_id" =~ ^[0-9]+$ ]]; then
  echo "BLOCKED: active zuvo:execute session has malformed next-task in .zuvo/context/execution-state.md."
  echo "Fix the state file before committing."
  exit 1
fi

artifact_path="$PWD/.zuvo/context/adversarial-task-${task_id}.txt"

if [[ ! -s "$artifact_path" ]]; then
  echo "BLOCKED: missing adversarial artifact for execute task ${task_id}."
  echo "Expected: .zuvo/context/adversarial-task-${task_id}.txt"
  echo "Run Step 7b before commit."
  echo "Example: git add -u && git diff --staged | adversarial-review --mode code --artifact \".zuvo/context/adversarial-task-${task_id}.txt\""
  echo "Use --mode security or --mode migrate when the diff is high-risk."
  exit 1
fi

if ! grep -q '^artifact_kind=adversarial-review$' "$artifact_path" 2>/dev/null; then
  echo "BLOCKED: adversarial artifact for task ${task_id} is malformed."
  echo "Re-run adversarial review and overwrite .zuvo/context/adversarial-task-${task_id}.txt."
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
  echo "Re-run adversarial review after the latest staged edits and overwrite .zuvo/context/adversarial-task-${task_id}.txt."
  exit 1
fi

exit 0
