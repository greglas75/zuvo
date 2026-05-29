#!/bin/bash
# Logs every skill invocation to ~/.claude/skill-usage.jsonl
# Hook: PostToolUse, matcher: Skill
#
# 2026-05-29 fix: the previous version hand-built the JSON record by shell
# string-interpolation — `echo "{...\"args\":\"$ARGS\"...}"` — splicing raw
# $ARGS/$SKILL/$PROJECT/$SESSION (which can carry double-quotes, newlines,
# tabs, backslashes from multi-line skill prompts) into a JSON literal with
# ZERO escaping. Result: 1845 of 2518 lines (73%) were unparseable, and a
# single control-char line aborted any downstream `jq` reader globally.
#
# This version reads every field INSIDE jq from the raw hook payload, so a
# value never touches the shell as a string and jq -c owns all escaping —
# one valid, escaped JSON object per line, always. jq is already required.

INPUT=$(cat)
TIMESTAMP=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
LOG_FILE="$HOME/.claude/skill-usage.jsonl"

printf '%s' "$INPUT" | jq -c --arg ts "$TIMESTAMP" '{
  ts: $ts,
  skill: (.tool_input.skill // "unknown"),
  args: (.tool_input.args // ""),
  project: ((.cwd // "unknown") | sub(".*/"; "")),
  session: (.session_id // "unknown")
}' >> "$LOG_FILE" 2>/dev/null || true

# Non-blocking: a malformed payload or jq failure must never break the Skill
# tool call. Worst case is one un-logged invocation, never a corrupt record.
exit 0
