#!/bin/bash
# Collects context metrics after a skill run.
# Called by the model at the end of run-logger flow (after appending Run: line).
#
# Reads the session include log (written by track-includes.sh hook),
# calculates cumulative file sizes, and appends a metrics line to
# ~/.zuvo/context-metrics.log.
#
# Usage: bash hooks/collect-context-metrics.sh <SKILL> <PROJECT> <TIER>
# Or via plugin root: bash "${CLAUDE_PLUGIN_ROOT}/hooks/collect-context-metrics.sh" <SKILL> <PROJECT> <TIER>
#
# Output: one TSV line appended to ~/.zuvo/context-metrics.log

set -e

SKILL="${1:-unknown}"
PROJECT="${2:-unknown}"
TIER="${3:--}"

# Resolve log paths
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null || ! test -w ~/.zuvo; then
  METRICS_LOG="memory/zuvo-context-metrics.log"
else
  METRICS_LOG="$HOME/.zuvo/context-metrics.log"
fi

# Find all session include logs and merge
INCLUDE_FILES=$(ls /tmp/zuvo-includes-*.txt 2>/dev/null)

# If no include logs exist, emit minimal metrics line
if [ -z "$INCLUDE_FILES" ]; then
  DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$DATE" "$SKILL" "$PROJECT" "0" "0" "-" "$TIER" \
    >> "$METRICS_LOG"
  exit 0
fi

# Merge all session files, deduplicate
INCLUDES=$(cat $INCLUDE_FILES 2>/dev/null | sort -u)
INCLUDE_COUNT=$(echo "$INCLUDES" | grep -c . || echo 0)

# Cleanup session files after collection
rm -f $INCLUDE_FILES 2>/dev/null

# Calculate total bytes of loaded includes
TOTAL_BYTES=0

# Find plugin root for resolving include paths
PLUGIN_ROOT=""
if [ -n "$CLAUDE_PLUGIN_ROOT" ]; then
  PLUGIN_ROOT="$CLAUDE_PLUGIN_ROOT"
else
  # Try common locations
  for candidate in \
    "$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"/*/shared/includes \
    "$HOME/.codex/shared/includes" \
    "$HOME/.cursor/shared/includes"; do
    if [ -d "$candidate" ]; then
      PLUGIN_ROOT="$(dirname "$(dirname "$candidate")")"
      break
    fi
  done
fi

if [ -n "$PLUGIN_ROOT" ]; then
  while IFS= read -r basename; do
    [ -z "$basename" ] && continue
    # Check shared/includes first, then rules
    filepath=""
    if [ -f "$PLUGIN_ROOT/shared/includes/${basename}.md" ]; then
      filepath="$PLUGIN_ROOT/shared/includes/${basename}.md"
    elif [ -f "$PLUGIN_ROOT/rules/${basename}.md" ]; then
      filepath="$PLUGIN_ROOT/rules/${basename}.md"
    fi
    if [ -n "$filepath" ]; then
      size=$(stat -f%z "$filepath" 2>/dev/null || stat --printf='%s' "$filepath" 2>/dev/null || echo 0)
      TOTAL_BYTES=$((TOTAL_BYTES + size))
    fi
  done <<< "$INCLUDES"
fi

# Pipe-separated include list
INCLUDE_LIST=$(echo "$INCLUDES" | paste -sd'|' -)
[ -z "$INCLUDE_LIST" ] && INCLUDE_LIST="-"

# Create header if file doesn't exist
if [ ! -f "$METRICS_LOG" ]; then
  echo "# v1 DATE SKILL PROJECT INCLUDES_COUNT INCLUDES_BYTES INCLUDES TIER" > "$METRICS_LOG"
fi

# Append metrics line
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
  "$DATE" "$SKILL" "$PROJECT" "$INCLUDE_COUNT" "$TOTAL_BYTES" "$INCLUDE_LIST" "$TIER" \
  >> "$METRICS_LOG"

# Rotation: keep last 200 data lines
LINE_COUNT=$(wc -l < "$METRICS_LOG")
if [ "$LINE_COUNT" -gt 201 ]; then
  head -1 "$METRICS_LOG" > "$METRICS_LOG.tmp.$$"
  tail -n 200 "$METRICS_LOG" >> "$METRICS_LOG.tmp.$$"
  mv "$METRICS_LOG.tmp.$$" "$METRICS_LOG"
fi

exit 0
