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

materialize_claude_reviewer_lanes() {
  local target_root="$1"
  local dir
  local file

  for dir in "$target_root/skills" "$target_root/shared/includes" "$target_root/rules"; do
    if [[ ! -d "$dir" ]]; then
      fail "Required Claude cache dir missing: $dir"
      return 1
    fi

    while IFS= read -r -d '' file; do
      perl -0pi -e 's/\breview-primary\b/opus/g; s/\breview-alt\b/sonnet/g' "$file" || return 1
    done < <(find "$dir" -name "*.md" -print0)
  done
}

validate_claude_reviewer_lanes() {
  local target_root="$1"
  local dir
  local refs

  for dir in "$target_root/skills" "$target_root/shared" "$target_root/rules"; do
    if [[ ! -d "$dir" ]]; then
      fail "Required Claude cache dir missing during validation: $dir"
      return 1
    fi
  done

  refs=$(grep -rn 'review-primary\|review-alt' "$target_root/skills" "$target_root/shared" "$target_root/rules" 2>/dev/null || true)
  if [[ -n "$refs" ]]; then
    fail "Abstract reviewer lanes remain in Claude cache:"
    echo "$refs" | head -10 | sed 's/^/     /'
    return 1
  fi
  return 0
}

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

  # Ensure a cache dir exists for the CURRENT version
  local current_version="$VERSION"
  if [[ ! -d "$CACHE_BASE/$current_version" ]]; then
    echo "  Creating cache dir for v${current_version}..."
    mkdir -p "$CACHE_BASE/$current_version"
    # Bootstrap directory structure
    mkdir -p "$CACHE_BASE/$current_version/skills"
    mkdir -p "$CACHE_BASE/$current_version/shared/includes"
    mkdir -p "$CACHE_BASE/$current_version/rules"
    mkdir -p "$CACHE_BASE/$current_version/scripts"
    mkdir -p "$CACHE_BASE/$current_version/bin"
    mkdir -p "$CACHE_BASE/$current_version/docs"
  fi

  # Sync to ALL existing cache dirs (Claude Code may have version + SHA dirs)
  CACHE_DIRS=$(ls -d "$CACHE_BASE"/*/ 2>/dev/null)
  if [[ -z "$CACHE_DIRS" ]]; then
    fail "No cache directories in $CACHE_BASE"
    return 1
  fi

  for CACHE_DIR in $CACHE_DIRS; do
    DIR_NAME=$(basename "$CACHE_DIR")
    echo "  Syncing: $DIR_NAME"

    # Copy skills (new + updated), resolve {plugin_root} to actual cache path
    for skill_dir in "$ZUVO_DIR"/skills/*/; do
      skill_name=$(basename "$skill_dir")
      mkdir -p "$CACHE_DIR/skills/$skill_name"
      cp -r "$skill_dir"* "$CACHE_DIR/skills/$skill_name/" 2>/dev/null || true
    done
    # Replace {plugin_root} placeholder with actual resolved path in all skill files
    local resolved_root="${CACHE_DIR%/}"
    find "$CACHE_DIR/skills" -name "*.md" -exec \
      sed -i '' "s|{plugin_root}|${resolved_root}|g" {} + 2>/dev/null || true
    # Clean up any orphan files at skills/ root level
    rm -f "$CACHE_DIR/skills/SKILL.md" 2>/dev/null || true
    rm -rf "$CACHE_DIR/skills/agents" 2>/dev/null || true

    # Strip non-Claude-Code platform blocks (CODEX, CURSOR, ANTIGRAVITY)
    # Each block is delimited by <!-- PLATFORM:X --> ... <!-- /PLATFORM:X -->
    find "$CACHE_DIR/skills" -name "*.md" -exec \
      sed -i '' -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
                -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
                -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
                {} + 2>/dev/null || true

    # Copy shared includes
    if [[ -d "$ZUVO_DIR/shared/includes" ]] && [[ -d "$CACHE_DIR/shared/includes" ]]; then
      cp "$ZUVO_DIR"/shared/includes/*.md "$CACHE_DIR/shared/includes/" 2>/dev/null || true
      # Strip non-Claude-Code platform blocks from shared includes too
      find "$CACHE_DIR/shared/includes" -name "*.md" -exec \
        sed -i '' -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
                  -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
                  -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
                  {} + 2>/dev/null || true
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

    # Copy bin/ (CLI wrappers — Claude Code adds {plugin_root}/bin to PATH)
    if [[ -d "$ZUVO_DIR/bin" ]]; then
      mkdir -p "$CACHE_DIR/bin"
      cp "$ZUVO_DIR"/bin/* "$CACHE_DIR/bin/" 2>/dev/null || true
      chmod +x "$CACHE_DIR"/bin/* 2>/dev/null || true
    fi

    # Copy hooks (pre-push gate, session hooks)
    if [[ -d "$ZUVO_DIR/hooks" ]]; then
      mkdir -p "$CACHE_DIR/hooks"
      cp "$ZUVO_DIR"/hooks/* "$CACHE_DIR/hooks/" 2>/dev/null || true
      chmod +x "$CACHE_DIR"/hooks/*.sh 2>/dev/null || true
    fi

    # Copy docs (if dir exists in cache)
    if [[ -d "$CACHE_DIR/docs" ]]; then
      cp -r "$ZUVO_DIR"/docs/*.md "$CACHE_DIR/docs/" 2>/dev/null || true
    fi

    materialize_claude_reviewer_lanes "$CACHE_DIR"
    validate_claude_reviewer_lanes "$CACHE_DIR" || return 1

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

  # Remove old cache dirs (keep only current version)
  # Claude Code creates a new dir per version but never cleans old ones.
  # Old dirs cause PATH confusion (agent may load skills from wrong version).
  local current_version="$VERSION"
  for old_dir in "$CACHE_BASE"/*/; do
    local dir_name
    dir_name=$(basename "$old_dir")
    if [[ "$dir_name" != "$current_version" ]]; then
      rm -rf "$old_dir"
      echo "  Removed old cache: $dir_name"
    fi
  done

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

  # Step 7: Copy scripts (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh)
  if [[ -d "$ZUVO_DIR/scripts" ]]; then
    mkdir -p "$HOME/.codex/scripts"
    cp "$ZUVO_DIR"/scripts/benchmark.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/adversarial-review.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-model-route.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/blind-audit-codex.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.codex"/scripts/*.sh 2>/dev/null || true
    ok "Scripts installed"
  fi

  # Step 8: Install hooks to Codex plugin cache
  # Codex only discovers hooks.json from formally-installed plugins
  # in ~/.codex/.tmp/plugins/plugins/<name>/
  local CODEX_PLUGIN_CACHE="$HOME/.codex/.tmp/plugins/plugins/zuvo"
  if [[ -d "$HOME/.codex/.tmp/plugins" ]]; then
    mkdir -p "$CODEX_PLUGIN_CACHE/hooks"
    mkdir -p "$CODEX_PLUGIN_CACHE/.codex-plugin"

    # Copy hooks.json to plugin root
    if [[ -f "$DIST/hooks.json" ]]; then
      cp "$DIST/hooks.json" "$CODEX_PLUGIN_CACHE/hooks.json"
    fi

    # Copy plugin manifest
    if [[ -f "$DIST/.codex-plugin/plugin.json" ]]; then
      cp "$DIST/.codex-plugin/plugin.json" "$CODEX_PLUGIN_CACHE/.codex-plugin/plugin.json"
    fi

    # Copy hook scripts
    if [[ -d "$DIST/hooks" ]]; then
      cp "$DIST"/hooks/* "$CODEX_PLUGIN_CACHE/hooks/" 2>/dev/null || true
      chmod +x "$CODEX_PLUGIN_CACHE"/hooks/*.sh 2>/dev/null || true
      chmod +x "$CODEX_PLUGIN_CACHE"/hooks/session-start 2>/dev/null || true
    fi

    # Copy skills to plugin cache (self-contained plugin)
    if [[ -d "$DIST/skills" ]]; then
      mkdir -p "$CODEX_PLUGIN_CACHE/skills"
      cp -r "$DIST"/skills/* "$CODEX_PLUGIN_CACHE/skills/" 2>/dev/null || true
    fi

    ok "Hooks installed to plugin cache"
  else
    warn "Codex plugin cache not found -- hooks not installed (skills still work)"
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

  # Step 7: Copy scripts (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh)
  if [[ -d "$ZUVO_DIR/scripts" ]]; then
    mkdir -p "$HOME/.cursor/scripts"
    cp "$ZUVO_DIR"/scripts/benchmark.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/adversarial-review.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-model-route.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/blind-audit-codex.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.cursor"/scripts/*.sh 2>/dev/null || true
    ok "Scripts installed"
  fi

  # Step 8: Clean duplicate skills from Claude Code cache
  # Cursor scans both ~/.cursor/skills/ AND ~/.claude/plugins/cache/ without
  # deduplication (known Cursor bug). Remove zuvo skills from ~/.cursor/skills/
  # so only Claude Code's plugin cache is used — avoids double entries in /skills.
  if [[ -d "$HOME/.claude/plugins/cache/zuvo-marketplace" ]]; then
    if [[ -d "$HOME/.cursor/skills/write-tests" || -d "$HOME/.cursor/skills/using-zuvo" ]]; then
      echo "  Cleaning duplicate skills from ~/.cursor/skills/ (Cursor dedup bug)..."
      rm -rf "$HOME/.cursor/skills"
      ok "Duplicate skills removed (Cursor uses Claude Code cache)"
    fi
  fi

  ok "Cursor updated"
}

# =======================================
# ANTIGRAVITY
# =======================================
install_antigravity() {
  echo ""
  echo "======================================"
  echo "  ANTIGRAVITY"
  echo "======================================"

  if [[ ! -d "$HOME/.gemini/antigravity" ]]; then
    warn "~/.gemini/antigravity not found -- Antigravity not installed. Skipping."
    return 0
  fi

  # Step 1: Build
  echo "  Building Antigravity distribution..."
  local build_log
  build_log=$(mktemp)
  if ! bash "$ZUVO_DIR/scripts/build-antigravity-skills.sh" "$ZUVO_DIR" > "$build_log" 2>&1; then
    fail "Build failed. Build output:"
    cat "$build_log" >&2
    rm -f "$build_log"
    return 1
  fi
  rm -f "$build_log"
  DIST="$ZUVO_DIR/dist/antigravity"

  if [[ ! -d "$DIST/skills" ]]; then
    fail "Build failed -- no dist/antigravity/skills/ produced"
    return 1
  fi
  ok "Build complete"

  # Step 2: Clean old symlinks and stale files
  rm -rf "$HOME/.gemini/antigravity/skills"
  rm -rf "$HOME/.gemini/antigravity/shared"
  rm -rf "$HOME/.gemini/antigravity/rules"
  rm -rf "$HOME/.gemini/antigravity/scripts"
  ok "Cleaned old installation"

  # Step 3: Copy skills (agents stay in subdirectories)
  mkdir -p "$HOME/.gemini/antigravity/skills"
  for skill_dir in "$DIST"/skills/*/; do
    skill_name=$(basename "$skill_dir")
    cp -r "$skill_dir" "$HOME/.gemini/antigravity/skills/$skill_name"
  done
  SKILL_COUNT=$(ls -d "$DIST/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
  ok "Skills installed ($SKILL_COUNT total, agents in subdirectories)"

  # Step 4: Copy shared includes
  if [[ -d "$DIST/shared" ]]; then
    mkdir -p "$HOME/.gemini/antigravity/shared/includes"
    cp -r "$DIST"/shared/* "$HOME/.gemini/antigravity/shared/"
    ok "Shared includes installed"
  fi

  # Step 5: Copy rules
  if [[ -d "$DIST/rules" ]]; then
    mkdir -p "$HOME/.gemini/antigravity/rules"
    cp -r "$DIST"/rules/* "$HOME/.gemini/antigravity/rules/"
    ok "Rules installed"
  fi

  # Step 6: Copy scripts
  if [[ -d "$DIST/scripts" ]]; then
    mkdir -p "$HOME/.gemini/antigravity/scripts"
    cp "$DIST"/scripts/*.sh "$HOME/.gemini/antigravity/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.gemini/antigravity"/scripts/*.sh 2>/dev/null || true
    ok "Scripts installed"
  fi

  # Step 7: Copy hooks + merge into ~/.gemini/settings.json
  if [[ -d "$DIST/hooks" ]]; then
    mkdir -p "$HOME/.gemini/antigravity/hooks"
    cp "$DIST"/hooks/* "$HOME/.gemini/antigravity/hooks/" 2>/dev/null || true
    chmod +x "$HOME/.gemini/antigravity"/hooks/*.sh 2>/dev/null || true
    chmod +x "$HOME/.gemini/antigravity/hooks/session-start" 2>/dev/null || true
    ok "Hook scripts installed"
  fi

  # Merge hook config into ~/.gemini/settings.json (idempotent)
  if [[ -f "$DIST/hooks.json" ]]; then
    local gemini_settings="$HOME/.gemini/settings.json"
    python3 -c "
import json, sys, os, tempfile

hooks_template = sys.argv[1]
settings_path = sys.argv[2]

# Read template
with open(hooks_template) as f:
    template = json.load(f)

# Read existing settings (or create empty)
settings = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except (json.JSONDecodeError, ValueError):
        print('  ! settings.json is malformed -- skipping hook merge')
        sys.exit(0)

if 'hooks' not in settings:
    settings['hooks'] = {}

changed = False
for event_name, event_hooks in template.get('hooks', {}).items():
    if event_name not in settings['hooks']:
        settings['hooks'][event_name] = []

    existing_entries = settings['hooks'][event_name]

    for new_hook_group in event_hooks:
        for new_hook in new_hook_group.get('hooks', []):
            cmd = new_hook.get('command', '')
            # Check if zuvo hook already exists (match on script name)
            already_exists = False
            for existing_group in existing_entries:
                for existing_hook in existing_group.get('hooks', []):
                    existing_cmd = existing_hook.get('command', '')
                    if 'antigravity/hooks/' in existing_cmd and any(
                        s in existing_cmd for s in ['pre-push-gate', 'session-start']
                        if s in cmd
                    ):
                        # Update in place
                        existing_hook.update(new_hook)
                        already_exists = True
                        changed = True
                        break
                if already_exists:
                    break

            if not already_exists:
                existing_entries.append(new_hook_group)
                changed = True
                break  # Only add the group once

if changed:
    # Write atomically
    fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path), suffix='.tmp')
    with os.fdopen(fd, 'w') as f:
        json.dump(settings, f, indent=2)
        f.write('\n')
    os.rename(tmp, settings_path)
    print('  \u2713 Hooks merged into settings.json')
else:
    print('  \u2713 Hooks already present in settings.json (no changes)')
" "$DIST/hooks.json" "$HOME/.gemini/settings.json" 2>/dev/null || warn "settings.json merge failed"
  fi

  ok "Antigravity updated"
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
  antigravity) install_antigravity ;;
  both|all) install_claude; install_codex; install_cursor; install_antigravity ;;
  *)      echo "Usage: $0 [claude|codex|cursor|antigravity|all]"; exit 1 ;;
esac

echo ""
echo "======================================"
echo "  DONE"
echo "======================================"
echo ""
echo "  Restart Claude Code / Codex / Cursor / Antigravity to pick up changes."
echo ""

# =======================================
# POST-INSTALL: Cross-provider check
# =======================================
# Adversarial review needs a DIFFERENT provider than the host IDE.
# Warn if no cross-providers are available.

check_cross_providers() {
  local has_codex="" has_gemini="" has_cursor="" has_claude=""
  command -v codex &>/dev/null && has_codex=1
  [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]] && has_codex=1
  command -v gemini &>/dev/null && has_gemini=1
  command -v cursor-agent &>/dev/null && has_cursor=1
  command -v claude &>/dev/null && has_claude=1

  local count=0
  [[ -n "$has_codex" ]] && count=$((count + 1))
  [[ -n "$has_gemini" ]] && count=$((count + 1))
  [[ -n "$has_cursor" ]] && count=$((count + 1))
  [[ -n "$has_claude" ]] && count=$((count + 1))

  if [[ $count -eq 0 ]]; then
    echo "  ⚠ WARNING: No adversarial review providers found!"
    echo ""
    echo "  Zuvo uses cross-model review — a DIFFERENT AI reviews code"
    echo "  written by your primary AI. Install at least one:"
    echo ""
    echo "    npm install -g @openai/codex     # Codex CLI (fastest)"
    echo "    npm install -g @google/gemini-cli # Gemini CLI (free)"
    echo "    # Claude CLI — already included with Claude Code"
    echo ""
    echo "  Without a cross-provider, adversarial review will be skipped."
    echo ""
  elif [[ $count -eq 1 ]]; then
    echo "  Cross-provider check: 1 provider found."
    echo "  Adversarial review needs a provider DIFFERENT from your host IDE."
    [[ -n "$has_codex" ]] && echo "    ✓ codex (excluded in Codex — need another for Codex users)"
    [[ -n "$has_gemini" ]] && echo "    ✓ gemini (excluded in Antigravity — need another for Antigravity users)"
    [[ -n "$has_claude" ]] && echo "    ✓ claude (excluded in Claude Code — need another for Claude Code users)"
    [[ -n "$has_cursor" ]] && echo "    ✓ cursor-agent (excluded in Cursor — need another for Cursor users)"
    echo ""
    echo "  For full coverage, install one more provider from a different vendor."
    echo ""
  else
    echo "  Cross-provider check: $count providers found ✓"
    [[ -n "$has_codex" ]] && echo "    ✓ codex"
    [[ -n "$has_gemini" ]] && echo "    ✓ gemini"
    [[ -n "$has_claude" ]] && echo "    ✓ claude"
    [[ -n "$has_cursor" ]] && echo "    ✓ cursor-agent"
    echo ""
  fi
}

check_cross_providers
