#!/bin/bash
# Install zuvo to Claude Code and/or Codex from source.
# Usage:
#   ./scripts/install.sh          # install to both
#   ./scripts/install.sh claude   # Claude Code only
#   ./scripts/install.sh codex    # Codex only
#
# What it does:
#   Claude Code: copies source files to plugin cache
#   Codex:       runs build-codex-skills.sh, then copies dist to ~/.codex/

set -euo pipefail

ZUVO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-both}"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

# ═══════════════════════════════════════════════════════
# CLAUDE CODE
# ═══════════════════════════════════════════════════════
install_claude() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  CLAUDE CODE"
  echo "══════════════════════════════════════"

  # Find the cache directory
  CACHE_BASE="$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"
  if [[ ! -d "$CACHE_BASE" ]]; then
    fail "Plugin cache not found at $CACHE_BASE"
    echo "     Run first: claude plugin install zuvo (from zuvo-marketplace)"
    return 1
  fi

  # Claude Code creates TWO cache dirs: a version dir (1.0.0) and a SHA dir (564a269...).
  # It may load from EITHER one. We must sync to ALL of them.
  CACHE_DIRS=$(ls -d "$CACHE_BASE"/*/ 2>/dev/null)
  if [[ -z "$CACHE_DIRS" ]]; then
    fail "No cache directories in $CACHE_BASE"
    return 1
  fi

  for CACHE_DIR in $CACHE_DIRS; do
    DIR_NAME=$(basename "$CACHE_DIR")
    echo "  Syncing: $DIR_NAME"

    # Copy skills (new + updated)
    for skill_dir in "$ZUVO_DIR"/skills/*/; do
      cp -r "$skill_dir" "$CACHE_DIR/skills/"
    done

    # Copy shared includes
    if [[ -d "$ZUVO_DIR/shared/includes" ]] && [[ -d "$CACHE_DIR/shared/includes" ]]; then
      cp "$ZUVO_DIR"/shared/includes/*.md "$CACHE_DIR/shared/includes/" 2>/dev/null || true
    fi

    # Copy rules
    if [[ -d "$ZUVO_DIR/rules" ]] && [[ -d "$CACHE_DIR/rules" ]]; then
      cp "$ZUVO_DIR"/rules/*.md "$CACHE_DIR/rules/" 2>/dev/null || true
    fi

    # Copy docs (if dir exists in cache)
    if [[ -d "$CACHE_DIR/docs" ]]; then
      cp -r "$ZUVO_DIR"/docs/*.md "$CACHE_DIR/docs/" 2>/dev/null || true
    fi

    SKILL_COUNT=$(ls -d "$CACHE_DIR/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
    ok "$DIR_NAME — $SKILL_COUNT skills"
  done

  ok "Claude Code updated"
}

# ═══════════════════════════════════════════════════════
# CODEX
# ═══════════════════════════════════════════════════════
install_codex() {
  echo ""
  echo "══════════════════════════════════════"
  echo "  CODEX"
  echo "══════════════════════════════════════"

  if [[ ! -d "$HOME/.codex" ]]; then
    warn "~/.codex not found — Codex not installed. Skipping."
    return 0
  fi

  # Step 1: Build
  echo "  Building Codex distribution..."
  bash "$ZUVO_DIR/scripts/build-codex-skills.sh" "$ZUVO_DIR" > /dev/null 2>&1
  DIST="$ZUVO_DIR/dist/codex"

  if [[ ! -d "$DIST/skills" ]]; then
    fail "Build failed — no dist/codex/skills/ produced"
    return 1
  fi
  ok "Build complete"

  # Step 2: Copy skills
  cp -r "$DIST"/skills/* "$HOME/.codex/skills/"
  SKILL_COUNT=$(ls -d "$HOME/.codex/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
  ok "Skills installed ($SKILL_COUNT total)"

  # Step 3: Copy agents (TOML configs)
  if [[ -d "$DIST/agents" ]] && ls "$DIST"/agents/*.toml &>/dev/null; then
    cp "$DIST"/agents/*.toml "$HOME/.codex/agents/"
    AGENT_COUNT=$(ls "$HOME/.codex/agents"/*.toml 2>/dev/null | wc -l | tr -d ' ')
    ok "Agent TOMLs installed ($AGENT_COUNT total)"
  fi

  # Step 4: Copy shared includes
  if [[ -d "$DIST/shared" ]]; then
    mkdir -p "$HOME/.codex/shared/includes"
    cp -r "$DIST"/shared/* "$HOME/.codex/shared/"
    ok "Shared includes installed"
  fi

  # Step 5: Copy rules
  if [[ -d "$DIST/rules" ]]; then
    mkdir -p "$HOME/.codex/rules"
    cp -r "$DIST"/rules/* "$HOME/.codex/rules/"
    ok "Rules installed"
  fi

  ok "Codex updated"
}

# ═══════════════════════════════════════════════════════
# MAIN
# ═══════════════════════════════════════════════════════
VERSION=$(grep '"version"' "$ZUVO_DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
echo "Installing zuvo v${VERSION} from $ZUVO_DIR"

case "$TARGET" in
  claude) install_claude ;;
  codex)  install_codex ;;
  both)   install_claude; install_codex ;;
  *)      echo "Usage: $0 [claude|codex|both]"; exit 1 ;;
esac

echo ""
echo "══════════════════════════════════════"
echo "  DONE"
echo "══════════════════════════════════════"
echo ""
echo "  Restart Claude Code / Codex to pick up changes."
echo ""
