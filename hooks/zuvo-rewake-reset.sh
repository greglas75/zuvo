#!/usr/bin/env bash
# zuvo-rewake-reset.sh — Stop hook (clean turn end).
#
# Clears the CONSECUTIVE rewake counter written by zuvo-rewake-on-failure.sh, so
# that cap counts consecutive failures rather than lifetime: one clean turn
# resets it.
#
# It deliberately does NOT clear `$sid.total` or `$sid.window`.
# Why (2026-09-18): a turn killed by a usage limit still ends the turn CLEANLY,
# so this hook ran between every failure and wiped the counter before it could
# reach its cap — the 20-resume ceiling had never once bound (all 363 counter
# files on this machine held a single digit, max 6). `$sid.total` is the ceiling
# that actually holds, and `$sid.window` is what keeps a single reset window to a
# single wake; both survive a clean stop by design. Both are swept after 7 days
# by the failure hook.
input=$(cat 2>/dev/null) || exit 0
command -v jq >/dev/null 2>&1 || exit 0
sid=$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null)
[ -n "$sid" ] || exit 0
rm -f "${ZUVO_HOME:-$HOME/.zuvo}/rewake/$sid.count" 2>/dev/null || true
exit 0
