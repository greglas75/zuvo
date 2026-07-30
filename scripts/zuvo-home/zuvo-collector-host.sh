#!/usr/bin/env bash
# zuvo-collector-host.sh — resolve the telemetry collector's SSH target, WITHOUT hardcoding it.
#
# Why this exists: three helpers (backlog, runlog-sync.sh, sync-popebot.sh) each carried a private
# tailnet address as a literal default. That made them unversionable — shipping them would point
# every installing machine at one private collector — so they lived only in ~/.zuvo, one disk
# failure from being lost. This resolver is the seam: the CODE is versioned, the ADDRESS is not.
#
# Resolution order (first non-empty wins):
#   1. $ZUVO_COLLECTOR_SSH in the environment      — for one-off overrides and CI
#   2. ZUVO_COLLECTOR_SSH= in ~/.zuvo/collector.conf — the normal per-machine setting (chmod 600)
#
# There is deliberately NO fallback default. A wrong default is worse than none: it would send a
# machine's telemetry to somebody else's host, or fail with a confusing timeout instead of saying
# what to configure.
#
# Usage:
#   . "$(dirname "$0")/zuvo-collector-host.sh"   # then use $ZUVO_COLLECTOR_SSH
#   zuvo_collector_host || exit 0                # soft-skip in cron-driven callers

zuvo_collector_host() {
  local conf="${ZUVO_HOME:-$HOME/.zuvo}/collector.conf"
  if [ -z "${ZUVO_COLLECTOR_SSH:-}" ] && [ -r "$conf" ]; then
    # Parse, do NOT source: collector.conf is user-edited config, not a script to execute.
    # Strip an inline `# comment`, then surrounding quotes/whitespace — but NOT interior spaces.
    # `tr -d ' '` mangled any target carrying options, and without comment-stripping
    # `ZUVO_COLLECTOR_SSH=host  # prod` resolved to the literal `host#prod`.
    ZUVO_COLLECTOR_SSH="$(sed -n 's/^[[:space:]]*ZUVO_COLLECTOR_SSH[[:space:]]*=[[:space:]]*//p' "$conf" \
      | tail -1 | tr -d '\r' \
      | sed -e 's/[[:space:]]*#.*$//' \
            -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' \
            -e 's/^["'"'"']//' -e 's/["'"'"']$//' \
            -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi
  if [ -z "${ZUVO_COLLECTOR_SSH:-}" ]; then
    echo "zuvo: no collector host configured — set ZUVO_COLLECTOR_SSH in $conf (or the environment)." >&2
    echo "zuvo: telemetry/backlog sync is OPTIONAL; everything else works without it." >&2
    return 1
  fi
  export ZUVO_COLLECTOR_SSH
  return 0
}
