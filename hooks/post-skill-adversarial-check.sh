#!/usr/bin/env bash
# PostToolUse hook for Skill calls.
# After skills that REQUIRE adversarial review, injects a mandatory
# reminder if adversarial-review was not run during the skill.
#
# This catches the "rush to finish" pattern where the agent skips
# Phase 4.5 (adversarial) and jumps straight to completion report.

set -euo pipefail

INPUT=$(cat 2>/dev/null || true)

# Extract skill name — only trigger on skills that require adversarial
SKILL_NAME=""
REVIEW_MODE="code"
for s in write-tests fix-tests write-e2e; do
  if echo "$INPUT" | grep -qi "zuvo:${s}"; then
    SKILL_NAME="$s"
    REVIEW_MODE="test"
    break
  fi
done
if [ -z "$SKILL_NAME" ]; then
  for s in build execute refactor debug receive-review seo-fix; do
    if echo "$INPUT" | grep -qi "zuvo:${s}"; then
      SKILL_NAME="$s"
      REVIEW_MODE="code"
      break
    fi
  done
fi

# Not a relevant skill — exit silently
[ -z "$SKILL_NAME" ] && exit 0

# Check if adversarial-review was called during this skill's execution.
# We check the shell history file for recent adversarial-review invocations.
# Since we can't access session tool history from a hook, we check runs.log
# for an adversarial entry in the last 15 minutes for this project.
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")
LOG="$HOME/.zuvo/runs.log"
FOUND=false

if [ -f "$LOG" ]; then
  CUTOFF=$(date -v-15M +%Y-%m-%dT%H:%M 2>/dev/null || date -d '15 minutes ago' +%Y-%m-%dT%H:%M 2>/dev/null || echo "")
  if [ -n "$CUTOFF" ]; then
    if grep -q "adversarial" "$LOG" 2>/dev/null && \
       awk -F'\t' -v proj="$PROJECT" -v cutoff="$CUTOFF" \
         '$1 >= cutoff && $3 == proj && /adversarial/ { found=1 } END { exit !found }' "$LOG" 2>/dev/null; then
      FOUND=true
    fi
  fi
fi

[ "$FOUND" = "true" ] && exit 0

# Inject mandatory reminder
cat <<HOOKEOF
{
  "hookSpecificOutput": {
    "hookEventName": "PostToolUse",
    "additionalContext": "MANDATORY: zuvo:${SKILL_NAME} requires adversarial review but none was detected. Run NOW: git add -u && git diff --staged | adversarial-review --json --mode ${REVIEW_MODE}. This is Phase 4.5 — it is NOT optional. Do NOT deliver results to the user without running adversarial review first."
  }
}
HOOKEOF

exit 0
