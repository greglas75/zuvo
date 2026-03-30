#!/bin/bash
# Dev push: commit + push + sync marketplace SHA + update local installed_plugins.json
# Usage:
#   ./scripts/dev-push.sh "commit message"
#   ./scripts/dev-push.sh                    # auto-message from last change
#
# What it does:
#   1. Stages all changes and commits (if message provided)
#   2. Pushes to origin main
#   3. Updates marketplace SHA → pushes marketplace
#   4. Updates local installed_plugins.json SHA (no reinstall needed!)
#   5. Copies files to Claude Code cache
#   6. Installs to Codex
#
# After running: just restart Claude Code. No uninstall/install needed.

set -euo pipefail

ZUVO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKETPLACE_DIR="${ZUVO_DIR}/../zuvo-marketplace"

GREEN='\033[0;32m'
RED='\033[0;31m'
NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }

# --- Step 1: Commit if message provided ---
MSG="${1:-}"
if [[ -n "$MSG" ]]; then
  cd "$ZUVO_DIR"
  git add -A
  if git diff --cached --quiet 2>/dev/null; then
    echo "  No changes to commit."
  else
    git commit -m "$MSG"
    ok "Committed: $MSG"
  fi
fi

# --- Step 2: Push ---
cd "$ZUVO_DIR"
git push origin main 2>&1 | tail -1
ok "Pushed to origin"

NEW_SHA=$(git rev-parse HEAD)
echo "  SHA: ${NEW_SHA:0:7}"

# --- Step 3: Update marketplace ---
if [[ -d "$MARKETPLACE_DIR/.claude-plugin" ]]; then
  cd "$MARKETPLACE_DIR"
  sed -i '' "s/\"sha\": \"[a-f0-9]*\"/\"sha\": \"${NEW_SHA}\"/" .claude-plugin/marketplace.json
  git add -A
  git commit -m "bump: zuvo (${NEW_SHA:0:7})" --quiet
  git push --quiet
  ok "Marketplace updated (${NEW_SHA:0:7})"
else
  fail "Marketplace not found at $MARKETPLACE_DIR"
fi

# --- Step 4: Update local installed_plugins.json SHA ---
PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"
if [[ -f "$PLUGINS_JSON" ]]; then
  # Update the SHA for zuvo@zuvo-marketplace
  python3 -c "
import json, sys
path = '$PLUGINS_JSON'
sha = '$NEW_SHA'
with open(path) as f:
    data = json.load(f)
for name, entries in data.get('plugins', {}).items():
    if 'zuvo' in name.lower():
        for e in entries:
            e['gitCommitSha'] = sha
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
print('  ✓ installed_plugins.json SHA updated')
" 2>/dev/null || echo "  ! Could not update installed_plugins.json"
else
  echo "  ! installed_plugins.json not found (plugin not installed?)"
fi

# --- Step 5: Copy to Claude Code cache ---
cd "$ZUVO_DIR"
bash scripts/install.sh 2>&1 | grep -E "✓|✗|DONE"

echo ""
echo "══════════════════════════════════════"
echo "  DEV PUSH COMPLETE"
echo "══════════════════════════════════════"
echo "  SHA:    ${NEW_SHA:0:7}"
echo "  Action: restart Claude Code"
echo ""
