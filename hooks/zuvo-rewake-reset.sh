#!/usr/bin/env bash
# zuvo-rewake-reset.sh — Stop hook (clean turn end).
#
# Clears the per-session rewake counter written by zuvo-rewake-on-failure.sh, so
# the auto-resume cap counts CONSECUTIVE failures, not lifetime: one successful
# turn resets it. Fires on every clean turn end (including a turn that stops to
# ask the user a question — also a clean end, correctly resetting the counter).
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
rm -f "${ZUVO_HOME:-$HOME/.zuvo}/rewake/$sid.count" 2>/dev/null || true
exit 0
