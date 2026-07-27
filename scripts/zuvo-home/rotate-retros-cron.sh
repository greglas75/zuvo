#!/bin/bash
# Age-based archival for BOTH retro files (append-only at the write path; this is the ONLY
# retention). 90-day default; quiet unless something actually archives.
ZH="${ZUVO_HOME:-$HOME/.zuvo}"
# Self-heal any key=value drift before rotating (agents occasionally hand-write).
[ -x "$ZH/sanitize-retros" ] && python3 "$ZH/sanitize-retros" --apply --target "$ZH/retros.log"
for f in retros.md retros.log; do
  [ -f "$ZH/$f" ] && "$ZH/rotate-retros" --apply --target "$ZH/$f"
done

# Surface the retro-mine change proposals so the learning loop is not a dead-end.
mkdir -p "$ZH/mining"   # first run on a fresh machine has no mining/ yet
[ -x "$ZH/digest-proposals" ] && python3 "$ZH/digest-proposals" > "$ZH/mining/proposals-latest.md" 2>/dev/null
