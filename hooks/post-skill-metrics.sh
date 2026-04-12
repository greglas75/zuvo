#!/bin/bash
# PostToolUse/Skill hook — collects context metrics after any zuvo skill completes.
# Fires AUTOMATICALLY via hooks.json — no model action needed.
#
# Input: JSON on stdin from Claude Code PostToolUse event
# Reads: /tmp/zuvo-includes-{session}.txt (written by track-includes.sh)
# Writes: ~/.zuvo/context-metrics.log

set -e

# Read JSON from stdin
input=$(cat)

# Extract skill name and session_id
skill=$(echo "$input" | jq -r '.tool_input.skill // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# Only process zuvo: skills
case "$skill" in
  zuvo:*) skill="${skill#zuvo:}" ;;
  *) exit 0 ;;
esac

# Skip context-audit itself (avoid recursive metrics)
[ "$skill" = "context-audit" ] && exit 0

# Resolve project name
project=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# Resolve log path
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null || ! test -w ~/.zuvo; then
  METRICS_LOG="memory/zuvo-context-metrics.log"
else
  METRICS_LOG="$HOME/.zuvo/context-metrics.log"
fi

# Find all session include logs
INCLUDE_FILES=$(ls /tmp/zuvo-includes-*.txt 2>/dev/null || true)

if [ -z "$INCLUDE_FILES" ]; then
  # No includes tracked — emit minimal line
  DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  [ ! -f "$METRICS_LOG" ] && echo "# v1 DATE SKILL PROJECT INCLUDES_COUNT INCLUDES_BYTES INCLUDES TIER" > "$METRICS_LOG"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DATE" "$skill" "$project" "0" "0" "-" "-" \
    >> "$METRICS_LOG"
  exit 0
fi

# Merge all session files, deduplicate
INCLUDES=$(cat $INCLUDE_FILES 2>/dev/null | sort -u)
INCLUDE_COUNT=$(echo "$INCLUDES" | grep -c . 2>/dev/null || echo 0)

# Calculate total bytes
TOTAL_BYTES=0
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-}"

# Try to find plugin root if not set
if [ -z "$PLUGIN_ROOT" ]; then
  for candidate in "$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"/*/shared/includes; do
    [ -d "$candidate" ] && PLUGIN_ROOT="$(dirname "$(dirname "$candidate")")" && break
  done
fi

if [ -n "$PLUGIN_ROOT" ]; then
  while IFS= read -r basename; do
    [ -z "$basename" ] && continue
    filepath=""
    [ -f "$PLUGIN_ROOT/shared/includes/${basename}.md" ] && filepath="$PLUGIN_ROOT/shared/includes/${basename}.md"
    [ -z "$filepath" ] && [ -f "$PLUGIN_ROOT/rules/${basename}.md" ] && filepath="$PLUGIN_ROOT/rules/${basename}.md"
    if [ -n "$filepath" ]; then
      size=$(stat -f%z "$filepath" 2>/dev/null || stat --printf='%s' "$filepath" 2>/dev/null || echo 0)
      TOTAL_BYTES=$((TOTAL_BYTES + size))
    fi
  done <<< "$INCLUDES"
fi

INCLUDE_LIST=$(echo "$INCLUDES" | paste -sd'|' -)
[ -z "$INCLUDE_LIST" ] && INCLUDE_LIST="-"

# Create header if needed
[ ! -f "$METRICS_LOG" ] && echo "# v1 DATE SKILL PROJECT INCLUDES_COUNT INCLUDES_BYTES INCLUDES TIER" > "$METRICS_LOG"

# Append
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$DATE" "$skill" "$project" "$INCLUDE_COUNT" "$TOTAL_BYTES" "$INCLUDE_LIST" "-" \
  >> "$METRICS_LOG"

# Cleanup session files
rm -f $INCLUDE_FILES 2>/dev/null

# Rotation: keep last 200 data lines
LINE_COUNT=$(wc -l < "$METRICS_LOG" 2>/dev/null || echo 0)
if [ "$LINE_COUNT" -gt 201 ]; then
  head -1 "$METRICS_LOG" > "$METRICS_LOG.tmp.$$"
  tail -n 200 "$METRICS_LOG" >> "$METRICS_LOG.tmp.$$"
  mv "$METRICS_LOG.tmp.$$" "$METRICS_LOG"
fi

exit 0
