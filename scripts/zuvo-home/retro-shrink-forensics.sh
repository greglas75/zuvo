#!/usr/bin/env bash
# retro-shrink-forensics.sh — name the process that truncates ~/.zuvo/retros.log.
#
# WHY THIS EXISTS. The file has been truncated at least twice (2026-08-16/17: 422->100 rows;
# 2026-08-17: 464->112, retros.md both times) and file-level forensics cannot identify the writer:
# by the time anything notices, the only evidence left is the damage. `rotate-retros` is ruled out
# twice over — its own log ends 2026-08-13 and its launchd job runs weekly — and no other ~/.zuvo
# writer appears in either window.
#
# append-retro's guard detects and now auto-recovers, so data stops bleeding. That is treatment,
# not diagnosis. This runs from a launchd WatchPaths trigger, i.e. within moments of the write
# rather than hours later, and captures what a post-hoc look cannot:
#   * every process holding the file open (lsof), which is the writer itself if it is still running;
#   * the full process table filtered to plausible suspects, with start times and argv;
#   * the launchd job state, so a job that fired unexpectedly is visible;
#   * the file's own before/after numbers, so a same-second rewrite is distinguishable from a trim.
#
# WatchPaths fires on ANY change, including the ~100 legitimate appends a day, so the FIRST thing
# this does is decide whether anything is wrong. A forensics job that dumps on every append buries
# the one event worth reading.
#
# Read-only. Never blocks, never writes to retros.*, exits 0 always.
set -u

ZH="${ZUVO_HOME:-$HOME/.zuvo}"
LOG="$ZH/retros.log"
HW="$ZH/.retros-highwater"
OUT="$ZH/retro-shrink-forensics.log"

[ -f "$LOG" ] || exit 0

rows=$(grep -c '^RETRO:' "$LOG" 2>/dev/null) || rows=0
rows=$(printf '%s' "${rows:-0}" | tr -cd '0-9'); [ -n "$rows" ] || rows=0
prev=$(sed -n 's/^rows=//p' "$HW" 2>/dev/null | head -1)
prev=$(printf '%s' "${prev:-0}" | tr -cd '0-9'); [ -n "$prev" ] || prev=0

# Not a shrink -> silence. This is the common case by three orders of magnitude.
[ "$rows" -lt "$prev" ] || exit 0

# Deduplicate per incident, exactly as the guard's marker does: WatchPaths will fire again on the
# auto-recovery write and on every later append, and one incident must not produce N dumps.
SENT="$ZH/.retros-forensics-seen"
[ "$(cat "$SENT" 2>/dev/null)" = "$prev" ] && exit 0
printf '%s' "$prev" > "$SENT" 2>/dev/null

{
  echo "════════════════════════════════════════════════════════════════════"
  echo "SHRINK DETECTED  $(date -u +%Y-%m-%dT%H:%M:%SZ)  ($(date '+%Y-%m-%d %H:%M:%S %Z'))"
  echo "  rows: $prev -> $rows   bytes: $(wc -c < "$LOG" 2>/dev/null | tr -d ' ')"
  echo "  retros.md: $(grep -c '^## ' "$ZH/retros.md" 2>/dev/null || echo '?') sections, $(wc -c < "$ZH/retros.md" 2>/dev/null | tr -d ' ') bytes"
  echo
  echo "── open file handles (the writer, if it is still alive) ──"
  # lsof on the file AND on the directory: a writer using the temp-file + rename pattern holds the
  # temp, not retros.log, so the file alone would show nothing at exactly the interesting moment.
  lsof -- "$LOG" 2>/dev/null || echo "  (nothing holds retros.log)"
  lsof +D "$ZH" 2>/dev/null | grep -vE 'lsof|COMMAND' | head -20 || true
  echo
  echo "── suspects in the process table ──"
  ps -Ao pid,ppid,lstart,command 2>/dev/null \
    | grep -iE 'retro|zuvo|rotate|sanitize|truncat' | grep -viE 'grep|retro-shrink-forensics' | head -20 \
    || echo "  (no matching process)"
  echo
  echo "── launchd jobs (state + last exit) ──"
  launchctl list 2>/dev/null | grep -iE 'zuvo|codesift|retro' || echo "  (none)"
  echo
  echo "── recently modified in \$ZUVO_HOME (last 15 min) ──"
  find "$ZH" -maxdepth 1 -type f -newermt '-15 minutes' 2>/dev/null | head -20 || true
  echo
} >> "$OUT" 2>/dev/null

exit 0
