#!/usr/bin/env bash
# Quick installer for zuvo plugin
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/greglas75/zuvo/main/scripts/quick-install.sh | bash
#
# What it does:
#   1. Clones/updates zuvo to ~/.zuvo-plugin
#   2. Removes old claude-code-toolkit leftovers
#   3. Installs zuvo to Claude Code / Codex / Cursor
#
# Uninstall:
#   rm -rf ~/.zuvo-plugin && claude plugin uninstall zuvo@zuvo-marketplace 2>/dev/null

set -euo pipefail

ZUVO_DIR="$HOME/.zuvo-plugin"
REPO="https://github.com/greglas75/zuvo.git"
TARGET="all"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║     zuvo plugin — quick install      ║"
echo "╚══════════════════════════════════════╝"
echo ""

# ─── Clone or update ────────────────────────────────────────────

if [[ -d "$ZUVO_DIR/.git" ]]; then
  echo "Updating existing install at $ZUVO_DIR..."
  git -C "$ZUVO_DIR" pull --ff-only 2>/dev/null || {
    echo "WARN: git pull failed, doing fresh clone"
    rm -rf "$ZUVO_DIR"
    git clone "$REPO" "$ZUVO_DIR"
  }
else
  echo "Cloning zuvo to $ZUVO_DIR..."
  rm -rf "$ZUVO_DIR"
  git clone "$REPO" "$ZUVO_DIR"
fi

VERSION=$(grep '"version"' "$ZUVO_DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
echo "Version: v${VERSION}"
echo ""

# ─── Remove old claude-code-toolkit ─────────────────────────────

echo "Cleaning old claude-code-toolkit..."

OLD_FILES=(
  CLAUDE.md skill-workflows.md review-protocol.md
  refactoring-protocol.md agent-instructions.md
  test-patterns.md test-patterns-catalog.md
  test-patterns-nestjs.md test-patterns-redux.md
  test-patterns-yii2.md
)
OLD_DIRS=(conditional-rules refactoring-examples)

cleaned=0
for base_dir in "$HOME/.cursor" "$HOME/.codex"; do
  [[ -d "$base_dir" ]] || continue
  for f in "${OLD_FILES[@]}"; do
    [[ -e "$base_dir/$f" || -L "$base_dir/$f" ]] && rm -f "$base_dir/$f" && cleaned=$((cleaned + 1))
  done
  for d in "${OLD_DIRS[@]}"; do
    [[ -e "$base_dir/$d" || -L "$base_dir/$d" ]] && rm -rf "$base_dir/$d" && cleaned=$((cleaned + 1))
  done
done

# Claude Code plugin
if command -v claude &>/dev/null; then
  claude plugin uninstall claude-code-toolkit 2>/dev/null && cleaned=$((cleaned + 1)) || true
fi

[[ $cleaned -gt 0 ]] && echo "  Removed $cleaned old toolkit items" || echo "  No old toolkit found"
echo ""

# ─── Install to all available platforms ──────────────────────────

bash "$ZUVO_DIR/scripts/install.sh"

echo ""
echo "╔══════════════════════════════════════╗"
echo "║           Install complete           ║"
echo "╠══════════════════════════════════════╣"
echo "║  Restart Claude / Codex / Cursor /   ║"
echo "║  Antigravity to pick up changes.     ║"
echo "║                                      ║"
echo "║  Update later:                       ║"
echo "║  cd ~/.zuvo-plugin && git pull \\     ║"
echo "║    && ./scripts/install.sh           ║"
echo "║                                      ║"
echo "║  Or re-run this installer:           ║"
echo "║  curl -fsSL <url> | bash             ║"
echo "╚══════════════════════════════════════╝"
echo ""
