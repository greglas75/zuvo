#!/usr/bin/env bash
# retro-mine-weekly.sh — weekly retro-miner: deterministic digest + headless Claude triage agent.
# REPORT-ONLY by contract: the agent analyzes and ranks, never edits skills or releases unattended.
set -u
# Portable Python resolution — `python3` is not a command on Windows (python.org installs
# `python` and `py`; Git Bash ships neither). portable.sh is installed alongside these helpers.
. "$(dirname "$0")/portable.sh" 2>/dev/null || true
PY_BIN="$(command -v zuvo_python >/dev/null 2>&1 && zuvo_python || echo python3)"

export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
# Repo path is configurable — the miner must not be tied to one developer's checkout.
ZUVO_REPO="${ZUVO_REPO:-$HOME/DEV/zuvo-plugin}"
cd "$ZUVO_REPO" || { echo "ZUVO_REPO not found: $ZUVO_REPO" >&2; exit 1; }
D=$(date +%F)
mkdir -p "$HOME/.zuvo/mining"
"$PY_BIN" "$HOME/.zuvo/retro-mine.py" --days 7 > "$HOME/.zuvo/mining/collect-$D.log" 2>&1 || exit 1
DIGEST=$(ls -t "$HOME"/.zuvo/mining/digest-*.md | head -1)
claude -p "You are the weekly zuvo retro-miner (report-only; NEVER edit skills, commit, or release in this run).
1. Read the digest: $DIGEST (window stats, friction histogram, ALL change proposals from Mac + fleet bots, new ideas).
2. Triage the change proposals against the CURRENT sources in this repo (skills/, shared/includes/, scripts/): verdict each as already-fixed (cite what), valid (draft the minimal anchored edit), rejected (would re-create measured pathologies: per-item gates, thread dispatch, retry machinery), or wrong-target. Merge overlapping proposals. Check every drafted edit against the WHOLE target file for new contradictions.
3. Compare fleet-bot frictions vs Mac frictions — call out divergences.
4. Write the report to zuvo/reports/retro-mine-$D.md: (a) week stats, (b) TOP-5 fixes worth implementing (file, exact anchor, drafted edit, evidence), (c) rejected/already-fixed counts, (d) BACKLOG HEALTH: projects with runaway open-count growth or ancient oldest-date, cross-project duplicate debt patterns worth one shared fix, and any bot-repo backlog nobody is consuming, (e) ideas worth promoting, (f) one-paragraph verdict. Under 250 lines.
5. Print the TOP-5 list as your final output." \
  --dangerously-skip-permissions \
  > "$HOME/.zuvo/mining/agent-$D.log" 2>&1
rc=$?
# Do NOT report success when the agent failed — a swallowed non-zero here is how a week of
# triage silently goes missing while the log says DONE.
if [ "$rc" -ne 0 ]; then
  echo "WEEKLY MINE FAILED $D (claude rc=$rc): see ~/.zuvo/mining/agent-$D.log" >&2
  exit "$rc"
fi
echo "WEEKLY MINE DONE $D: report=zuvo/reports/retro-mine-$D.md log=~/.zuvo/mining/agent-$D.log"
