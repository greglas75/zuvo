#!/bin/bash
# PostToolUse hook — tracks which shared/includes/*.md and rules/*.md files
# were Read during a Claude Code session. Writes basenames to a session-specific
# temp file that run-logger.md reads at skill completion.
#
# Input: JSON on stdin from Claude Code PostToolUse event
# Output: none (side-effect only — appends to temp file)

set -e

# Read JSON from stdin
input=$(cat)

# Extract file_path and session_id
file_path=$(echo "$input" | jq -r '.tool_input.file_path // empty')
session_id=$(echo "$input" | jq -r '.session_id // empty')

# Skip if no file_path or session_id
[ -z "$file_path" ] && exit 0
[ -z "$session_id" ] && exit 0

# Only track shared/includes/ and rules/ files
case "$file_path" in
  *shared/includes/*.md|*rules/*.md) ;;
  *) exit 0 ;;
esac

# Get basename without .md and file size
basename="${file_path##*/}"
basename="${basename%.md}"
size=$(stat -f%z "$file_path" 2>/dev/null || stat --printf='%s' "$file_path" 2>/dev/null || echo 0)

# Session-specific include log
include_log="/tmp/zuvo-includes-${session_id}.txt"

# Append as name:bytes (deduplicated at read time, not write time — faster)
echo "${basename}:${size}" >> "$include_log"

exit 0
