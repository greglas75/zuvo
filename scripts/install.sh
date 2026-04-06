#!/bin/bash
# Install zuvo to Claude Code, Codex, and/or Cursor from source.
# Usage:
#   ./scripts/install.sh          # install to all
#   ./scripts/install.sh claude   # Claude Code only
#   ./scripts/install.sh codex    # Codex only
#   ./scripts/install.sh cursor   # Cursor only
#
# What it does:
#   Claude Code: copies source files to plugin cache
#   Codex:       runs build-codex-skills.sh, then copies dist to ~/.codex/
#   Cursor:      runs build-cursor-skills.sh, then copies dist to ~/.cursor/

set -euo pipefail

ZUVO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TARGET="${1:-all}"

# --- Colors ---
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

ok()   { echo -e "  ${GREEN}✓${NC} $1"; }
warn() { echo -e "  ${YELLOW}!${NC} $1"; }
fail() { echo -e "  ${RED}✗${NC} $1"; }

# =======================================
# CLAUDE CODE
# =======================================
install_claude() {
  echo ""
  echo "======================================"
  echo "  CLAUDE CODE"
  echo "======================================"

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
      skill_name=$(basename "$skill_dir")
      mkdir -p "$CACHE_DIR/skills/$skill_name"
      cp -r "$skill_dir"* "$CACHE_DIR/skills/$skill_name/" 2>/dev/null || true
    done
    # Clean up any orphan files at skills/ root level
    rm -f "$CACHE_DIR/skills/SKILL.md" 2>/dev/null || true
    rm -rf "$CACHE_DIR/skills/agents" 2>/dev/null || true

    # Copy shared includes
    if [[ -d "$ZUVO_DIR/shared/includes" ]] && [[ -d "$CACHE_DIR/shared/includes" ]]; then
      cp "$ZUVO_DIR"/shared/includes/*.md "$CACHE_DIR/shared/includes/" 2>/dev/null || true
    fi

    # Copy rules
    if [[ -d "$ZUVO_DIR/rules" ]] && [[ -d "$CACHE_DIR/rules" ]]; then
      cp "$ZUVO_DIR"/rules/*.md "$CACHE_DIR/rules/" 2>/dev/null || true
    fi

    # Copy scripts (adversarial-review.sh, etc.)
    if [[ -d "$ZUVO_DIR/scripts" ]]; then
      mkdir -p "$CACHE_DIR/scripts"
      cp "$ZUVO_DIR"/scripts/*.sh "$CACHE_DIR/scripts/" 2>/dev/null || true
      chmod +x "$CACHE_DIR"/scripts/*.sh 2>/dev/null || true
    fi

    # Copy docs (if dir exists in cache)
    if [[ -d "$CACHE_DIR/docs" ]]; then
      cp -r "$ZUVO_DIR"/docs/*.md "$CACHE_DIR/docs/" 2>/dev/null || true
    fi

    SKILL_COUNT=$(ls -d "$CACHE_DIR/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
    ok "$DIR_NAME -- $SKILL_COUNT skills"
  done

  # Fix stale SHA in installed_plugins.json (Claude Code cache bug workaround)
  local plugins_json="$HOME/.claude/plugins/installed_plugins.json"
  if [[ -f "$plugins_json" ]]; then
    local current_sha
    current_sha=$(cd "$ZUVO_DIR" && git rev-parse HEAD 2>/dev/null || echo "")
    if [[ -n "$current_sha" ]]; then
      python3 -c "
import json, sys
sha = sys.argv[1]
with open(sys.argv[2]) as f:
    data = json.load(f)
changed = False
for entry in data.get('plugins', {}).get('zuvo@zuvo-marketplace', []):
    if entry.get('gitCommitSha') != sha:
        entry['gitCommitSha'] = sha
        changed = True
if changed:
    with open(sys.argv[2], 'w') as f:
        json.dump(data, f, indent=2)
    print('  \u2713 Fixed stale SHA in installed_plugins.json')
" "$current_sha" "$plugins_json" 2>/dev/null || true
    fi
  fi

  ok "Claude Code updated"
}

# =======================================
# CODEX
# =======================================
install_codex() {
  echo ""
  echo "======================================"
  echo "  CODEX"
  echo "======================================"

  if [[ ! -d "$HOME/.codex" ]]; then
    warn "~/.codex not found -- Codex not installed. Skipping."
    return 0
  fi

  # Step 1: Build
  echo "  Building Codex distribution..."
  local build_log
  build_log=$(mktemp)
  if ! bash "$ZUVO_DIR/scripts/build-codex-skills.sh" "$ZUVO_DIR" > "$build_log" 2>&1; then
    fail "Build failed. Build output:"
    cat "$build_log" >&2
    rm -f "$build_log"
    return 1
  fi
  rm -f "$build_log"
  DIST="$ZUVO_DIR/dist/codex"

  if [[ ! -d "$DIST/skills" ]]; then
    fail "Build failed -- no dist/codex/skills/ produced"
    return 1
  fi
  ok "Build complete"

  # Step 2: Clean old toolkit symlinks (from claude-code-toolkit era)
  local old_codex_links=(
    "$HOME/.codex/CLAUDE.md"
    "$HOME/.codex/skill-workflows.md"
    "$HOME/.codex/refactoring-protocol.md"
    "$HOME/.codex/review-protocol.md"
    "$HOME/.codex/agent-instructions.md"
    "$HOME/.codex/test-patterns.md"
    "$HOME/.codex/test-patterns-catalog.md"
    "$HOME/.codex/test-patterns-nestjs.md"
    "$HOME/.codex/test-patterns-redux.md"
    "$HOME/.codex/test-patterns-yii2.md"
    "$HOME/.codex/conditional-rules"
    "$HOME/.codex/refactoring-examples"
  )
  local cleaned=0
  for link in "${old_codex_links[@]}"; do
    if [[ -L "$link" ]]; then
      rm "$link"
      cleaned=$((cleaned + 1))
    fi
  done
  if [[ "$cleaned" -gt 0 ]]; then
    ok "Cleaned $cleaned old toolkit symlinks"
  fi

  # Step 3: Copy skills
  cp -r "$DIST"/skills/* "$HOME/.codex/skills/"
  SKILL_COUNT=$(ls -d "$HOME/.codex/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
  ok "Skills installed ($SKILL_COUNT total)"

  # Step 4: Copy agents (TOML configs)
  if [[ -d "$DIST/agents" ]] && ls "$DIST"/agents/*.toml &>/dev/null; then
    cp "$DIST"/agents/*.toml "$HOME/.codex/agents/"
    AGENT_COUNT=$(ls "$HOME/.codex/agents"/*.toml 2>/dev/null | wc -l | tr -d ' ')
    ok "Agent TOMLs installed ($AGENT_COUNT total)"
  fi

  # Step 5: Copy shared includes
  if [[ -d "$DIST/shared" ]]; then
    mkdir -p "$HOME/.codex/shared/includes"
    cp -r "$DIST"/shared/* "$HOME/.codex/shared/"
    ok "Shared includes installed"
  fi

  # Step 6: Copy rules
  if [[ -d "$DIST/rules" ]]; then
    mkdir -p "$HOME/.codex/rules"
    cp -r "$DIST"/rules/* "$HOME/.codex/rules/"
    ok "Rules installed"
  fi

  ok "Codex updated"
}

# =======================================
# CURSOR
# =======================================
install_cursor() {
  echo ""
  echo "======================================"
  echo "  CURSOR"
  echo "======================================"

  if [[ ! -d "$HOME/.cursor" ]]; then
    warn "~/.cursor not found -- Cursor not installed. Skipping."
    return 0
  fi

  # Step 1: Build
  echo "  Building Cursor distribution..."
  local build_log
  build_log=$(mktemp)
  if ! bash "$ZUVO_DIR/scripts/build-cursor-skills.sh" "$ZUVO_DIR" > "$build_log" 2>&1; then
    fail "Build failed. Build output:"
    cat "$build_log" >&2
    rm -f "$build_log"
    return 1
  fi
  rm -f "$build_log"
  DIST="$ZUVO_DIR/dist/cursor"

  if [[ ! -d "$DIST/skills" ]]; then
    fail "Build failed -- no dist/cursor/skills/ produced"
    return 1
  fi
  ok "Build complete"

  # Step 2: Clean old toolkit symlinks (from claude-code-toolkit era)
  local old_symlinks=(
    "$HOME/.cursor/CLAUDE.md"
    "$HOME/.cursor/skill-workflows.md"
    "$HOME/.cursor/refactoring-protocol.md"
    "$HOME/.cursor/review-protocol.md"
    "$HOME/.cursor/test-patterns.md"
    "$HOME/.cursor/test-patterns-catalog.md"
    "$HOME/.cursor/test-patterns-nestjs.md"
    "$HOME/.cursor/test-patterns-redux.md"
    "$HOME/.cursor/test-patterns-yii2.md"
    "$HOME/.cursor/agent-instructions.md"
  )
  local cleaned=0
  for link in "${old_symlinks[@]}"; do
    if [[ -L "$link" ]]; then
      rm "$link"
      cleaned=$((cleaned + 1))
    fi
  done
  if [[ "$cleaned" -gt 0 ]]; then
    ok "Cleaned $cleaned old toolkit symlinks"
  fi

  # Step 3: Copy skills (do NOT touch skills-cursor/ -- those are Cursor built-in)
  mkdir -p "$HOME/.cursor/skills"
  for skill_dir in "$DIST"/skills/*/; do
    skill_name=$(basename "$skill_dir")
    mkdir -p "$HOME/.cursor/skills/$skill_name"
    cp -r "$skill_dir"* "$HOME/.cursor/skills/$skill_name/" 2>/dev/null || true
  done
  SKILL_COUNT=$(ls -d "$DIST/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
  ok "Skills installed ($SKILL_COUNT total)"

  # Step 4: Copy agents (flat .md files with skill-prefixed names)
  mkdir -p "$HOME/.cursor/agents"
  if ls "$DIST"/agents/*.md &>/dev/null; then
    cp "$DIST"/agents/*.md "$HOME/.cursor/agents/"
    AGENT_COUNT=$(ls "$DIST"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
    ok "Agents installed ($AGENT_COUNT total)"
  fi

  # Step 5: Copy shared includes
  if [[ -d "$DIST/shared" ]]; then
    mkdir -p "$HOME/.cursor/shared/includes"
    cp -r "$DIST"/shared/* "$HOME/.cursor/shared/"
    ok "Shared includes installed"
  fi

  # Step 6: Copy rules
  if [[ -d "$DIST/rules" ]]; then
    mkdir -p "$HOME/.cursor/rules"
    cp -r "$DIST"/rules/* "$HOME/.cursor/rules/"
    ok "Rules installed"
  fi

  ok "Cursor updated"
}

# =======================================
# MAIN
# =======================================
VERSION=$(grep '"version"' "$ZUVO_DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')
echo "Installing zuvo v${VERSION} from $ZUVO_DIR"

case "$TARGET" in
  claude) install_claude ;;
  codex)  install_codex ;;
  cursor) install_cursor ;;
  both|all) install_claude; install_codex; install_cursor ;;
  *)      echo "Usage: $0 [claude|codex|cursor|all]"; exit 1 ;;
esac

echo ""
echo "======================================"
echo "  DONE"
echo "======================================"
echo ""
echo "  Restart Claude Code / Codex / Cursor to pick up changes."
echo ""
