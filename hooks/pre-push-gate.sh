#!/usr/bin/env bash
# Pre-push gate: blocks git push / gh pr create if zuvo:review
# has not been logged for the current project+branch.
#
# Enforcement layer for Claude Code only (hooks don't exist on
# Codex/Cursor/Antigravity — those platforms use skill chaining).
#
# Called by PreToolUse hook on Bash tool calls. Reads tool input
# from stdin to filter for push commands only.

set -euo pipefail

# Read tool input from stdin (Claude Code passes tool input as JSON)
INPUT=$(cat 2>/dev/null || true)

# Only gate push commands — allow everything else through
case "$INPUT" in
  *"git push"*|*"gh pr create"*) ;;
  *) exit 0 ;;
esac

PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
BRANCH=$(git branch --show-current 2>/dev/null || echo "unknown")
LOG="$HOME/.zuvo/runs.log"

# No log file → warn but allow (fresh install, no skills run yet)
if [ ! -f "$LOG" ]; then
  echo "WARNING: No ~/.zuvo/runs.log found. Run zuvo:review before pushing for full enforcement."
  exit 0
fi

# Check for a review entry matching this project AND branch
# runs.log format: DATE\tSKILL\tPROJECT\t...\tBRANCH\tSHA7
# Uses awk with -v for safe variable interpolation (no regex injection)
if awk -F'\t' -v proj="$PROJECT" -v branch="$BRANCH" \
  '$2 == "review" && $3 == proj && $10 == branch { found=1 } END { exit !found }' "$LOG"; then
  exit 0
fi

echo "BLOCKED: zuvo:review not found in runs.log for ${PROJECT}/${BRANCH}."
echo "Run /review or zuvo:review before pushing."
exit 1
