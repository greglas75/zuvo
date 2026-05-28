#!/usr/bin/env bash
# ~/.claude/hooks/zuvo-stop-retro-sweep.sh
#
# Claude Code Stop hook: when a session ends, sweep for orphan run-markers
# (skill invocations that wrote a runs.log entry but no matching full retro)
# and warn loudly so the user knows their telemetry is degraded.
#
# Why this exists: 2026-05-29 retro audit showed runs.log has 819 lifetime
# entries but retros.log has 32. In the last 7 days alone: write-tests had
# 21 runs / 0 retros, content-expand 77/0, plan 27/7. Skills correctly tell
# agents to call ~/.zuvo/append-runlog after writing a retro, but agents
# print "done" without executing the bash — the markdown retro section
# never becomes a real file write. This hook is the safety net.
#
# Behavior:
#   1. Call `~/.zuvo/retro-stub --sweep` — for each orphan run-marker, emits
#      a DEGRADED but enum-valid retro stub (status=ABANDONED) so telemetry
#      survives the incomplete run.
#   2. If sweep emitted any stubs, print a forceful warning to stderr with
#      counts + the affected skill+project pairs so the user can either
#      accept the degraded entries or backfill a full retro before the next
#      session.
#   3. Non-blocking: this hook NEVER prevents session end. The warning is
#      informational. Blocking session-end would frustrate legitimate
#      quick-exits and is the wrong tradeoff.
#
# Exit: always 0 (non-blocking).

set -u  # not -e: we don't want a failed sweep to abort the session-end path

STUB="${HOME}/.zuvo/retro-stub"
RUN_MARKERS_DIR="${HOME}/.zuvo/run-markers"

# Fast no-op paths
[ -x "$STUB" ] || exit 0
[ -d "$RUN_MARKERS_DIR" ] || exit 0

# Snapshot orphan count BEFORE sweep so we can tell whether the sweep
# actually did anything (rather than relying on stub stdout, which varies).
ORPHANS_BEFORE=$(find "$RUN_MARKERS_DIR" -maxdepth 1 -name '*.marker' 2>/dev/null | wc -l | tr -d ' ')
[ "$ORPHANS_BEFORE" -eq 0 ] && exit 0  # nothing to do, silent exit

# Run the sweep. Suppress its stdout but capture stderr (the stub emits useful
# diagnostics there). Bound runtime: if sweep takes >10s something is wrong.
SWEEP_STDERR=$(timeout 10 "$STUB" --sweep 2>&1 >/dev/null) || true

ORPHANS_AFTER=$(find "$RUN_MARKERS_DIR" -maxdepth 1 -name '*.marker' 2>/dev/null | wc -l | tr -d ' ')
STUBS_EMITTED=$(( ORPHANS_BEFORE - ORPHANS_AFTER ))

# Always-emit summary line to stderr (Claude Code surfaces this to the user
# in the session-end summary). Distinguish three cases:
if [ "$STUBS_EMITTED" -gt 0 ]; then
  printf '\n' >&2
  printf '⚠ zuvo session-stop: %d orphan run-marker(s) swept into ABANDONED retro stubs.\n' "$STUBS_EMITTED" >&2
  printf '  The skill(s) wrote a runs.log entry but never executed the retrospective bash.\n' >&2
  printf '  Stubs preserve telemetry but lose the change_proposals / friction analysis.\n' >&2
  printf '  Backfill a full retro before next session if you want the lost feedback recovered.\n' >&2
  printf '  Recent stubs: tail -%d ~/.zuvo/retros.log\n' "$STUBS_EMITTED" >&2
elif [ "$ORPHANS_AFTER" -gt 0 ]; then
  printf '\n' >&2
  printf '⚠ zuvo session-stop: %d orphan run-marker(s) remain after sweep (stub failure?).\n' "$ORPHANS_AFTER" >&2
  printf '  Investigate: ls -la ~/.zuvo/run-markers/\n' >&2
  [ -n "$SWEEP_STDERR" ] && printf '  Sweep stderr: %s\n' "$SWEEP_STDERR" >&2
fi

exit 0
