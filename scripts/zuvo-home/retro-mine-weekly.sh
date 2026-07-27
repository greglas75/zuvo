#!/usr/bin/env bash
# retro-mine-weekly.sh — weekly retro-miner: deterministic digest + headless Claude triage agent.
# REPORT-ONLY by contract: the agent analyzes and ranks, never edits skills or releases unattended.
set -u
export PATH="$HOME/.local/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
cd "$HOME/DEV/zuvo-plugin" || exit 1
D=$(date +%F)
python3 "$HOME/.zuvo/retro-mine.py" --days 7 > "$HOME/.zuvo/mining/collect-$D.log" 2>&1 || exit 1
DIGEST=$(ls -t "$HOME"/.zuvo/mining/digest-*.md | head -1)
claude -p "You are the weekly zuvo retro-miner (report-only; NEVER edit skills, commit, or release in this run).
1. Read the digest: $DIGEST (window stats, friction histogram, ALL change proposals from Mac + fleet bots, new ideas).
2. Triage the change proposals against the CURRENT sources in this repo (skills/, shared/includes/, scripts/): verdict each as already-fixed (cite what), valid (draft the minimal anchored edit), rejected (would re-create measured pathologies: per-item gates, thread dispatch, retry machinery), or wrong-target. Merge overlapping proposals. Check every drafted edit against the WHOLE target file for new contradictions.
3. Compare fleet-bot frictions vs Mac frictions — call out divergences.
4. Write the report to zuvo/reports/retro-mine-$D.md: (a) week stats, (b) TOP-5 fixes worth implementing (file, exact anchor, drafted edit, evidence), (c) rejected/already-fixed counts, (d) BACKLOG HEALTH: projects with runaway open-count growth or ancient oldest-date, cross-project duplicate debt patterns worth one shared fix, and any bot-repo backlog nobody is consuming, (e) ideas worth promoting, (f) one-paragraph verdict. Under 250 lines.
5. Print the TOP-5 list as your final output." \
  --dangerously-skip-permissions \
  > "$HOME/.zuvo/mining/agent-$D.log" 2>&1
echo "WEEKLY MINE DONE $D: report=zuvo/reports/retro-mine-$D.md log=~/.zuvo/mining/agent-$D.log"
