#!/bin/bash
# Reads the session include log and outputs pipe-separated unique basenames.
# Called by skills at Run: template time to fill <INCLUDES> field.
#
# Usage: INCLUDES=$(~/.claude/hooks/read-includes.sh "$SESSION_ID")
# Falls back to "-" if no data or no session ID.

set -e

session_id="${1:-}"

# Try to get session_id from stdin JSON if not passed as arg
if [ -z "$session_id" ]; then
  echo "-"
  exit 0
fi

include_log="/tmp/zuvo-includes-${session_id}.txt"

if [ ! -f "$include_log" ]; then
  echo "-"
  exit 0
fi

# Deduplicate, sort, pipe-separate
result=$(sort -u "$include_log" | paste -sd'|' -)

if [ -z "$result" ]; then
  echo "-"
else
  echo "$result"
fi
