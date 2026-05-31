#!/bin/bash
# One command to rule them all: version bump + commit + push + tag + marketplace + install
#
# Usage:
#   ./scripts/dev-push.sh "description"           # patch bump (default)
#   ./scripts/dev-push.sh "description" minor      # minor bump
#   ./scripts/dev-push.sh                          # patch bump, auto-message
#
# What it does (in order):
#   1. Bump version in package.json, plugin.json files, using-zuvo banner
#   2. Stage all + commit
#   3. Push to origin + tag
#   4. Update marketplace SHA + push marketplace
#   5. Update local installed_plugins.json SHA
#   6. Install to Claude Code + Codex + Cursor + Antigravity
#
# After running: just restart Claude Code.

set -euo pipefail

ZUVO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKETPLACE_DIR="${ZUVO_DIR}/../zuvo-marketplace"

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'
ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; exit 1; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }

# --- Args ---
MSG="${1:-}"
BUMP="${2:-patch}"

# Validate marketplace exists
if [[ ! -d "$MARKETPLACE_DIR/.claude-plugin" ]]; then
  fail "Marketplace repo not found at $MARKETPLACE_DIR"
fi

# ═══════════════════════════════════════
# Step 1: Version bump
# ═══════════════════════════════════════
cd "$ZUVO_DIR"
CURRENT_VERSION=$(grep '"version"' package.json | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  *) echo "Usage: $0 \"message\" [patch|minor|major]"; exit 1 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo ""
echo "══════════════════════════════════════"
echo "  zuvo v${CURRENT_VERSION} → v${NEW_VERSION} (${BUMP})"
echo "══════════════════════════════════════"
echo ""

# Update version in all files
sed -i '' "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" package.json
sed -i '' "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" .claude-plugin/plugin.json
sed -i '' "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" .codex-plugin/plugin.json
# Update version banner in skill router
sed -i '' "s/Zuvo v${CURRENT_VERSION}/Zuvo v${NEW_VERSION}/" skills/using-zuvo/SKILL.md 2>/dev/null || true
ok "Version bumped: v${NEW_VERSION}"

# ═══════════════════════════════════════
# Step 2: Commit
# ═══════════════════════════════════════
if [[ -z "$MSG" ]]; then
  MSG="release v${NEW_VERSION}"
fi

git add -A
if git diff --cached --quiet 2>/dev/null; then
  echo "  No changes to commit."
else
  git commit -m "release: v${NEW_VERSION} — ${MSG}"
  ok "Committed: v${NEW_VERSION} — ${MSG}"
fi

# ═══════════════════════════════════════
# Step 3: Push + tag
# ═══════════════════════════════════════
git push origin main 2>&1 | tail -1
git tag "v${NEW_VERSION}" 2>/dev/null || true
git push --tags 2>/dev/null || true

NEW_SHA=$(git rev-parse HEAD)
ok "Pushed + tagged v${NEW_VERSION} (${NEW_SHA:0:7})"

# ═══════════════════════════════════════
# Step 4: Update marketplace
# ═══════════════════════════════════════
cd "$MARKETPLACE_DIR"
git pull --rebase --quiet 2>/dev/null || true
sed -i '' "s/\"sha\": \"[a-f0-9]*\"/\"sha\": \"${NEW_SHA}\"/" .claude-plugin/marketplace.json
git add -A
git commit -m "bump: zuvo v${NEW_VERSION} (${NEW_SHA:0:7})" --quiet
git push --quiet
ok "Marketplace updated → v${NEW_VERSION} (${NEW_SHA:0:7})"

# ═══════════════════════════════════════
# Step 5: Update local installed_plugins.json
# ═══════════════════════════════════════
cd "$ZUVO_DIR"
PLUGINS_JSON="$HOME/.claude/plugins/installed_plugins.json"
NEW_INSTALL_PATH="$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo/${NEW_VERSION}"
if [[ -f "$PLUGINS_JSON" ]]; then
  # CRITICAL: update installPath + version, NOT just gitCommitSha. Claude Code
  # loads hooks/skills from `installPath` — if only the SHA moves, the running
  # plugin stays frozen at the OLD version dir (the 2026-05-31 bug where three
  # watchdog releases never took effect because installPath stayed at 1.3.107
  # while only gitCommitSha advanced). install.sh has already populated the new
  # version dir by this point, so pointing installPath at it is safe.
  python3 -c "
import json
path = '$PLUGINS_JSON'
sha = '$NEW_SHA'
ver = '$NEW_VERSION'
ipath = '$NEW_INSTALL_PATH'
with open(path) as f:
    data = json.load(f)
for name, entries in data.get('plugins', {}).items():
    if 'zuvo' in name.lower():
        for e in entries:
            e['gitCommitSha'] = sha
            e['version'] = ver
            e['installPath'] = ipath
with open(path, 'w') as f:
    json.dump(data, f, indent=2)
" 2>/dev/null && ok "installed_plugins.json updated → installPath+version+sha = v${NEW_VERSION}" || warn "Could not update installed_plugins.json"
else
  warn "installed_plugins.json not found"
fi

# ═══════════════════════════════════════
# Step 6: Install to all platforms
# ═══════════════════════════════════════
bash scripts/install.sh 2>&1 | grep -E "✓|✗|DONE|======" | grep -v "^$"

echo ""
echo "══════════════════════════════════════"
echo "  RELEASE COMPLETE"
echo "══════════════════════════════════════"
echo "  Version: v${NEW_VERSION}"
echo "  SHA:     ${NEW_SHA:0:7}"
echo "  Action:  restart Claude Code"
echo ""
