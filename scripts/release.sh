#!/usr/bin/env bash
# Release script for Zuvo plugin
# Usage: ./scripts/release.sh [patch|minor|major] "commit message"
#
# Automates: commit + push zuvo, update marketplace SHA, push marketplace, git tag

set -euo pipefail

ZUVO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
MARKETPLACE_DIR="${ZUVO_DIR}/../zuvo-marketplace"

# --- Args ---
BUMP="${1:-patch}"
MSG="${2:-release}"

# --- Validate ---
if [[ ! -d "$MARKETPLACE_DIR/.claude-plugin" ]]; then
  echo "ERROR: Marketplace repo not found at $MARKETPLACE_DIR"
  echo "Clone it: git clone https://github.com/greglas75/zuvo-marketplace.git $MARKETPLACE_DIR"
  exit 1
fi

# --- Step 1: Get current version ---
CURRENT_VERSION=$(grep '"version"' "$ZUVO_DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
IFS='.' read -r MAJOR MINOR PATCH <<< "$CURRENT_VERSION"

case "$BUMP" in
  major) MAJOR=$((MAJOR + 1)); MINOR=0; PATCH=0 ;;
  minor) MINOR=$((MINOR + 1)); PATCH=0 ;;
  patch) PATCH=$((PATCH + 1)) ;;
  *) echo "Usage: $0 [patch|minor|major] \"message\""; exit 1 ;;
esac

NEW_VERSION="${MAJOR}.${MINOR}.${PATCH}"
echo "Bumping: ${CURRENT_VERSION} → ${NEW_VERSION}"

# --- Step 2: Update version in plugin files ---
sed -i '' "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" "$ZUVO_DIR/package.json"
sed -i '' "s/\"version\": \"${CURRENT_VERSION}\"/\"version\": \"${NEW_VERSION}\"/" "$ZUVO_DIR/.claude-plugin/plugin.json"

# --- Step 3: Commit + push zuvo ---
cd "$ZUVO_DIR"
git add -A
git commit -m "release: v${NEW_VERSION} — ${MSG}"
git push
git tag "v${NEW_VERSION}"
git push --tags

NEW_SHA=$(git rev-parse HEAD)
echo "New SHA: ${NEW_SHA}"

# --- Step 4: Update marketplace SHA ---
cd "$MARKETPLACE_DIR"
git pull --rebase

# Update SHA in marketplace.json
sed -i '' "s/\"sha\": \"[a-f0-9]*\"/\"sha\": \"${NEW_SHA}\"/" .claude-plugin/marketplace.json

git add -A
git commit -m "bump: zuvo v${NEW_VERSION} (${NEW_SHA:0:7})"
git push

echo ""
echo "Released zuvo v${NEW_VERSION}"
echo "  Plugin:      https://github.com/greglas75/zuvo/releases/tag/v${NEW_VERSION}"
echo "  Marketplace: updated to ${NEW_SHA:0:7}"
echo ""
echo "Users update with: claude plugin update zuvo"
