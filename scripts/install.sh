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

# NOTE: `set -euo pipefail` is deliberately NOT global — it is enabled inside the
# main run guard at the bottom. This file is source-able (tests source it to call
# install_hook_tree / install_pipeline_artifacts / install_git_shim) and a global
# `set -e` would leak into and abort the sourcing shell.

ZUVO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")/.." && pwd)"
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
# PIPELINE-ENTRY HOOK INSTALL HELPERS (source-able + reused by every target)
# =======================================

# Copy the FULL hooks tree (incl. lib/) to a target hooks dir. Recursive,
# idempotent (cp overwrites; re-runs never duplicate). This is what makes the
# pipeline-gate lib + new hooks reach a target.
install_hook_tree() {
  local dst="$1"
  [ -n "$dst" ] || return 1
  mkdir -p "$dst/lib"
  cp "$ZUVO_DIR"/hooks/*.sh "$dst/" 2>/dev/null || true
  cp "$ZUVO_DIR"/hooks/*.json "$dst/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/hooks/run-hook.cmd" ] && cp "$ZUVO_DIR/hooks/run-hook.cmd" "$dst/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/hooks/session-start" ] && cp "$ZUVO_DIR/hooks/session-start" "$dst/" 2>/dev/null || true
  if [ -d "$ZUVO_DIR/hooks/lib" ]; then
    cp "$ZUVO_DIR"/hooks/lib/*.sh "$dst/lib/" 2>/dev/null || true
  fi
  # refactor commit-gate self-installer (lives in scripts/, needed in the hooks dir so
  # zuvo:refactor Phase 0 can find it at ~/.claude/hooks/install-refactor-gate.sh)
  [ -f "$ZUVO_DIR/scripts/install-refactor-gate.sh" ] && cp "$ZUVO_DIR/scripts/install-refactor-gate.sh" "$dst/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/scripts/setup-dev-hooks.sh" ] && cp "$ZUVO_DIR/scripts/setup-dev-hooks.sh" "$dst/" 2>/dev/null || true
  chmod +x "$dst"/*.sh "$dst"/lib/*.sh 2>/dev/null || true
}

# Copy the CI check script, the git PATH-shim, and the CI workflow template
# under <base>/scripts and <base>/ci.
# Install the tracked global git dispatchers (hooks/git-dispatch/{pre-push,pre-commit})
# into a hooks dir. rm -f first: the existing files may be SYMLINKS to a shared
# hook-chain.sh — writing through them corrupts commit-msg/prepare-commit-msg.
install_git_dispatchers() {
  local hooks_dir="$1" d
  mkdir -p "$hooks_dir"
  for d in pre-push pre-commit; do
    if [[ ! -f "$ZUVO_DIR/hooks/git-dispatch/$d" ]]; then
      warn "hooks/git-dispatch/$d missing from repo — global dispatcher NOT installed"
      return 0
    fi
  done
  for d in pre-push pre-commit; do
    # Atomic replace: cp to a tmp name + mv -f (rename(2)) so there is NO window where the
    # hook is absent mid-install (TOCTOU fail-open) and a symlink target is never written
    # through (mv replaces the link itself). rm -rf first only for the stray-DIRECTORY edge
    # (mv cannot replace a dir). cp rc checked so a failed copy never half-installs.
    [ -d "$hooks_dir/$d" ] && rm -rf "$hooks_dir/$d"
    cp "$ZUVO_DIR/hooks/git-dispatch/$d" "$hooks_dir/.$d.tmp" || { fail "dispatcher copy failed: $d"; return 1; }
    chmod +x "$hooks_dir/.$d.tmp"
    mv -f "$hooks_dir/.$d.tmp" "$hooks_dir/$d" || { fail "dispatcher install failed: $d"; rm -f "$hooks_dir/.$d.tmp"; return 1; }
  done
  ok "global git dispatchers installed (pre-push, pre-commit) — zuvo gates now run in EVERY repo"
}

install_pipeline_artifacts() {
  local base="$1"
  [ -n "$base" ] || return 1
  mkdir -p "$base/scripts" "$base/ci"
  [ -f "$ZUVO_DIR/scripts/zuvo-pipeline-entry-ci.sh" ] && cp "$ZUVO_DIR/scripts/zuvo-pipeline-entry-ci.sh" "$base/scripts/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/scripts/git-noverify-shim.sh" ] && cp "$ZUVO_DIR/scripts/git-noverify-shim.sh" "$base/scripts/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/ci/zuvo-pipeline-entry.yml" ] && cp "$ZUVO_DIR/ci/zuvo-pipeline-entry.yml" "$base/ci/" 2>/dev/null || true
  chmod +x "$base"/scripts/zuvo-pipeline-entry-ci.sh "$base"/scripts/git-noverify-shim.sh 2>/dev/null || true
}

# Opt-in git PATH-shim install/uninstall. Reads ZUVO_INSTALL_GIT_SHIM /
# ZUVO_UNINSTALL_GIT_SHIM. No-op unless one is set (never installs by default —
# a git wrapper is intrusive, so it stays opt-in).
install_git_shim() {
  local shim_dst="${ZUVO_SHIM_PATH:-$HOME/bin/git}"
  if [ "${ZUVO_UNINSTALL_GIT_SHIM:-0}" = "1" ]; then
    if [ -e "$shim_dst" ]; then rm -f "$shim_dst" && ok "git shim removed ($shim_dst)"; else warn "no git shim at $shim_dst (nothing to remove)"; fi
    return 0
  fi
  [ "${ZUVO_INSTALL_GIT_SHIM:-0}" = "1" ] || return 0
  [ -f "$ZUVO_DIR/scripts/git-noverify-shim.sh" ] || { warn "git-noverify-shim.sh not found — shim not installed"; return 0; }
  mkdir -p "$(dirname "$shim_dst")"
  cp "$ZUVO_DIR/scripts/git-noverify-shim.sh" "$shim_dst"
  chmod +x "$shim_dst"
  ok "git shim installed ($shim_dst) — ensure $(dirname "$shim_dst") is EARLY on PATH (before the real git)"
}

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

  # Ensure a cache dir exists for the CURRENT version.
  # ATOMIC creation: Claude Code discovers a version dir by its existence, and dev-push points
  # installPath at it BEFORE this sync runs — so a version dir that is mkdir'd empty and
  # populated later has a window where a concurrent session loads it with EMPTY shared/includes
  # and rules → skills run degraded (the 2026-07-05 report: a parallel plan run fell back to
  # SKILL.md + project rules). Build the dir under a temp name, fully seeded from an existing
  # populated cache dir (upgrade) or bare structure (fresh install), then rename(2) it into
  # place so it NEVER appears half-populated. The sync loop below then updates it in place
  # (overwrite — never empties it).
  local current_version="$VERSION"
  if [[ ! -d "$CACHE_BASE/$current_version" ]]; then
    echo "  Creating cache dir for v${current_version} (atomic)..."
    local _seed="" _d _tmp="$CACHE_BASE/.$current_version.tmp.$$"
    rm -rf "$_tmp"
    # Pick the first NON-hidden existing cache dir as the seed. Filter hidden dirs
    # by BASENAME — the old `ls | grep -v '/\.'` matched "/." anywhere in the
    # ABSOLUTE path, and $HOME/.claude/... always contains "/.": it filtered every
    # candidate, grep exited 1, and `set -euo pipefail` killed the whole install at
    # this line (the real root cause of the 2026-07-08 RELEASE_EXIT=1 incidents —
    # dev-push's old Step 6 grep pipeline then masked it). No pipeline: no set -e hazard.
    for _d in "$CACHE_BASE"/*/; do
      [[ -d "$_d" ]] || continue
      case "$(basename "$_d")" in .*) continue ;; esac
      _seed="${_d%/}"
      break
    done
    if [[ -n "$_seed" ]]; then
      cp -R "${_seed%/}" "$_tmp" 2>/dev/null || mkdir -p "$_tmp"
    else
      mkdir -p "$_tmp"/skills "$_tmp"/shared/includes "$_tmp"/rules "$_tmp"/scripts "$_tmp"/bin "$_tmp"/docs
    fi
    if [[ -d "$CACHE_BASE/$current_version" ]]; then
      rm -rf "$_tmp"                                     # lost a race to another installer — fine
    else
      mv "$_tmp" "$CACHE_BASE/$current_version" 2>/dev/null || { rm -rf "$_tmp"; mkdir -p "$CACHE_BASE/$current_version"/skills "$CACHE_BASE/$current_version"/shared/includes "$CACHE_BASE/$current_version"/rules; }
    fi
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
      cp -R "$ZUVO_DIR"/shared/includes/. "$CACHE_DIR/shared/includes/" 2>/dev/null || true
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

    # Copy the VERSION marker to the target root AND skills/ — so ANY install,
    # including a bare skills-only fleet deploy with no manifest, is version-
    # identifiable (`cat <root>/VERSION` or `cat <root>/skills/VERSION`).
    if [[ -f "$ZUVO_DIR/VERSION" ]]; then
      cp "$ZUVO_DIR/VERSION" "$CACHE_DIR/VERSION" 2>/dev/null || true
      mkdir -p "$CACHE_DIR/skills"
      cp "$ZUVO_DIR/VERSION" "$CACHE_DIR/skills/VERSION" 2>/dev/null || true
    fi

    # Copy bin/ (CLI wrappers — Claude Code adds {plugin_root}/bin to PATH)
    if [[ -d "$ZUVO_DIR/bin" ]]; then
      mkdir -p "$CACHE_DIR/bin"
      cp "$ZUVO_DIR"/bin/* "$CACHE_DIR/bin/" 2>/dev/null || true
      chmod +x "$CACHE_DIR"/bin/* 2>/dev/null || true
    fi

    # Copy hooks — FULL tree incl. hooks/lib/ (recursive) so the pipeline-gate
    # lib reaches the cache, plus the CI script + git shim + CI workflow template.
    if [[ -d "$ZUVO_DIR/hooks" ]]; then
      install_hook_tree "$CACHE_DIR/hooks"
      install_pipeline_artifacts "$CACHE_DIR"
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

  # Remove old cache dirs but KEEP the 2 newest versions (current + the most-recent
  # previous). A live session bakes CLAUDE_PLUGIN_ROOT to whatever version was current
  # when it STARTED; deleting that dir mid-run 404s all its plugin hooks (the
  # 2026-05-31 regression — releasing 1.3.112 while a 1.3.111 session was live broke
  # its hooks with "Plugin directory does not exist"). Keeping the previous version
  # lets that session run until the user restarts it onto the current one. Truly-stale
  # dirs (2+ behind) still get cleaned to avoid version PATH confusion.
  local keep_versions
  keep_versions=$(ls -d "$CACHE_BASE"/*/ 2>/dev/null | xargs -n1 basename 2>/dev/null | sort -V | tail -2)
  for old_dir in "$CACHE_BASE"/*/; do
    local dir_name
    dir_name=$(basename "$old_dir")
    if ! printf '%s\n' "$keep_versions" | grep -qx "$dir_name"; then
      rm -rf "$old_dir"
      echo "  Removed old cache: $dir_name (kept current + previous)"
    fi
  done

  ok "Claude Code updated"
}

# =======================================
# ZUVO HOME ($HOME/.zuvo)
# Forcing-function scripts that gate run-log writes on retrospective presence.
# Independent of plugin host (Claude Code / Codex / Cursor) — installed once
# per machine, called from every skill that loads run-logger.md.
# =======================================
install_zuvo_home() {
  echo ""
  echo "======================================"
  echo "  ZUVO HOME (~/.zuvo)"
  echo "======================================"

  mkdir -p "$HOME/.zuvo"

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/append-runlog" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/append-runlog" "$HOME/.zuvo/append-runlog"
    chmod +x "$HOME/.zuvo/append-runlog"
    ok "append-runlog installed (~/.zuvo/append-runlog)"
  else
    warn "scripts/zuvo-home/append-runlog not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/compute-preload" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/compute-preload" "$HOME/.zuvo/compute-preload"
    chmod +x "$HOME/.zuvo/compute-preload"
    ok "compute-preload installed (~/.zuvo/compute-preload)"
  else
    warn "scripts/zuvo-home/compute-preload not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/verify-audit" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/verify-audit" "$HOME/.zuvo/verify-audit"
    chmod +x "$HOME/.zuvo/verify-audit"
    ok "verify-audit installed (~/.zuvo/verify-audit)"
  else
    warn "scripts/zuvo-home/verify-audit not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/retro-stub" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/retro-stub" "$HOME/.zuvo/retro-stub"
    chmod +x "$HOME/.zuvo/retro-stub"
    ok "retro-stub installed (~/.zuvo/retro-stub)"
  else
    warn "scripts/zuvo-home/retro-stub not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/append-retro" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/append-retro" "$HOME/.zuvo/append-retro"
    chmod +x "$HOME/.zuvo/append-retro"
    ok "append-retro installed (~/.zuvo/append-retro)"
  else
    warn "scripts/zuvo-home/append-retro not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/verify-plan-dag" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/verify-plan-dag" "$HOME/.zuvo/verify-plan-dag"
    chmod +x "$HOME/.zuvo/verify-plan-dag"
    ok "verify-plan-dag installed (~/.zuvo/verify-plan-dag)"
  else
    warn "scripts/zuvo-home/verify-plan-dag not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/rotate-retros" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/rotate-retros" "$HOME/.zuvo/rotate-retros"
    chmod +x "$HOME/.zuvo/rotate-retros"
    ok "rotate-retros installed (~/.zuvo/rotate-retros)"
  else
    warn "scripts/zuvo-home/rotate-retros not found in repo — skipping"
  fi

  if [[ -f "$ZUVO_DIR/scripts/zuvo-home/zuvo-watchdog-check" ]]; then
    cp "$ZUVO_DIR/scripts/zuvo-home/zuvo-watchdog-check" "$HOME/.zuvo/zuvo-watchdog-check"
    chmod +x "$HOME/.zuvo/zuvo-watchdog-check"
    ok "zuvo-watchdog-check installed (~/.zuvo/zuvo-watchdog-check)"
  else
    warn "scripts/zuvo-home/zuvo-watchdog-check not found in repo — skipping"
  fi

  # B-9 (v1.3.109): per-platform `zuvo-home` subcommand is a pre-existing gap
  # affecting ALL zuvo-home helpers equally; out of scope for v1.3.110.
  # NOTE: ~/.zuvo is the SHARED cross-platform helper dir. These zuvo-home
  # helpers (incl. retro-stub) reach Claude/Codex/Cursor via THIS function
  # only — build-codex-skills.sh / build-cursor-skills.sh deliberately do NOT
  # copy scripts/zuvo-home (verified). install_zuvo_home runs in the default
  # `all`/`both` dispatch (the documented canonical install). Do not add a
  # zuvo-home copy to the per-platform build scripts.
}

# =======================================
# CLAUDE HOME (~/.claude/scripts)
# Shared helper scripts that live alongside the user's Claude config.
# Currently: post-commit hook that feeds review-backlog.md / review-queue.md.
# Per-project activation is opt-in (user wires .git/hooks/post-commit themselves);
# we just make sure the script is present and up-to-date for every machine.
# =======================================
install_claude_home() {
  echo ""
  echo "======================================"
  echo "  CLAUDE HOME (~/.claude/scripts)"
  echo "======================================"

  local src_dir="$ZUVO_DIR/scripts/claude-home/scripts"
  local dst_dir="$HOME/.claude/scripts"

  if [[ ! -d "$src_dir" ]]; then
    warn "scripts/claude-home/scripts not found in repo — skipping"
    return 0
  fi

  mkdir -p "$dst_dir"

  local src
  for src in "$src_dir"/*.sh; do
    [[ -f "$src" ]] || continue
    local name
    name="$(basename "$src")"
    cp "$src" "$dst_dir/$name"
    chmod +x "$dst_dir/$name"
    ok "$name installed (~/.claude/scripts/$name)"
  done

  # ── Global git dispatchers: tracked hooks/git-dispatch/* → ~/.claude/hooks (2026-07-02)
  # These REPLACE the codesift pass-through dispatchers: run the repo-local hook first
  # (no exec), then ALWAYS chain the zuvo gates — so freestyle-agent pushes are gated in
  # EVERY repo. SYMLINK TRAP: pre-push/commit-msg/prepare-commit-msg here are symlinks to
  # a shared hook-chain.sh; rm -f FIRST so cp lands as a regular file and never writes
  # through the link (that would corrupt commit-msg/prepare-commit-msg). Never touches any
  # repo's .git/hooks (C2). Uninstall: git config --global --unset core.hooksPath.
  local hooks_dir="$HOME/.claude/hooks"
  install_git_dispatchers "$hooks_dir"
  # Install the GATE TREE (pre-push-gate.sh, refactor-safety-gate.sh, lib/) BEFORE wiring
  # core.hooksPath — otherwise an interrupt in the window between wiring and the later tree
  # install leaves live dispatchers with NO gates (silent ungated fail-open). Idempotent;
  # the later pipeline-artifacts section re-copies harmlessly. (Aggregate-review MUST-FIX.)
  install_hook_tree "$hooks_dir"

  # Wire global git core.hooksPath to ~/.claude/hooks/ so the codesift-mcp
  # dispatcher actually runs (which in turn fires our post-commit-review-backlog).
  # Self-heals against stale paths — codesift-mcp's setup test had a bug that
  # leaked tmp paths like /var/folders/.../codesift-setup-XXXXXX/.claude/hooks
  # into the user's real ~/.gitconfig, silently breaking every git hook on the
  # machine until manual unset.
  # Wire when OUR dispatchers AND the gates they chain are installed — checking only the
  # dispatchers verified the wrong invariant (dispatchers-without-gates = ungated fail-open).
  if [[ -x "$hooks_dir/pre-push" && -x "$hooks_dir/pre-commit" \
        && -x "$hooks_dir/pre-push-gate.sh" && -x "$hooks_dir/refactor-safety-gate.sh" ]]; then
    local current_hooks_path
    current_hooks_path=$(git config --global --get core.hooksPath 2>/dev/null || true)
    if [[ -z "$current_hooks_path" ]]; then
      git config --global core.hooksPath "$hooks_dir"
      ok "core.hooksPath set to $hooks_dir"
    elif [[ "$current_hooks_path" != "$hooks_dir" ]]; then
      if [[ ! -d "$current_hooks_path" ]]; then
        warn "core.hooksPath was stale ($current_hooks_path) — replacing with $hooks_dir"
      else
        warn "core.hooksPath was $current_hooks_path — replacing with $hooks_dir"
      fi
      git config --global core.hooksPath "$hooks_dir"
      ok "core.hooksPath repointed to $hooks_dir"
    else
      ok "core.hooksPath already → $hooks_dir"
    fi
  else
    warn "global git dispatchers/gates incomplete in ~/.claude/hooks (need pre-push, pre-commit, pre-push-gate.sh, refactor-safety-gate.sh from hooks/ + hooks/git-dispatch/) — core.hooksPath NOT wired; fix the checkout and rerun"
  fi

  # ── Claude Code Stop-hook: zuvo-stop-retro-sweep (added 2026-05-29)
  # Copies the hook script into ~/.claude/hooks/ and idempotently merges the
  # Stop matcher into ~/.claude/settings.json. Closes the 2026-05-29 retro
  # gap (819 runs.log / 32 retros.log) where agents print "done" without
  # executing the retro bash — sweep emits ABANDONED stubs at session end so
  # telemetry survives.
  local stop_hook_src="$ZUVO_DIR/hooks/zuvo-stop-retro-sweep.sh"
  local stop_hook_dst="$hooks_dir/zuvo-stop-retro-sweep.sh"
  if [[ -f "$stop_hook_src" ]]; then
    mkdir -p "$hooks_dir"
    cp "$stop_hook_src" "$stop_hook_dst"
    chmod +x "$stop_hook_dst"
    ok "zuvo-stop-retro-sweep.sh installed (~/.claude/hooks/)"

    local claude_settings="$HOME/.claude/settings.json"
    if [[ -f "$claude_settings" ]]; then
      python3 - "$claude_settings" "$stop_hook_dst" <<'PYEOF' || warn "Stop-hook merge into ~/.claude/settings.json failed (manual edit may be needed)"
import json, sys, os
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        s = json.load(f)
except Exception as e:
    print(f'  ! ~/.claude/settings.json is malformed ({e}) — skipping Stop-hook merge')
    sys.exit(1)
hooks = s.setdefault('hooks', {})
stop = hooks.setdefault('Stop', [])
hook_cmd_norm = hook_cmd.replace(os.path.expanduser('~'), '$HOME')
# Idempotency: skip if any existing Stop hook already points at this script
already = any(
    any(h.get('command', '').endswith('zuvo-stop-retro-sweep.sh') for h in group.get('hooks', []))
    for group in stop
)
if already:
    print('  ✓ Stop-hook already registered in ~/.claude/settings.json (no change)')
    sys.exit(0)
stop.append({'hooks': [{'type': 'command', 'command': hook_cmd_norm, 'timeout': 15}]})
with open(settings_path, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
print('  ✓ Stop-hook registered in ~/.claude/settings.json')
PYEOF
    else
      warn "~/.claude/settings.json not found — Stop-hook not registered (Claude Code will not run it)"
    fi
  else
    warn "hooks/zuvo-stop-retro-sweep.sh not found in repo — Claude Code Stop-hook not installed"
  fi

  # ── Claude Code PostToolUse hook: skill-usage-logger (vendored 2026-05-29)
  # Was previously untracked at ~/.claude/hooks/ and hand-built its JSONL via
  # shell string-interpolation of raw $ARGS — 73% of records were unparseable.
  # Vendoring + the jq -c rewrite makes it survive reinstall and emit valid
  # escaped JSON. Registers PostToolUse matcher=Skill idempotently.
  local sul_src="$ZUVO_DIR/hooks/skill-usage-logger.sh"
  local sul_dst="$hooks_dir/skill-usage-logger.sh"
  if [[ -f "$sul_src" ]]; then
    mkdir -p "$hooks_dir"
    cp "$sul_src" "$sul_dst"
    chmod +x "$sul_dst"
    ok "skill-usage-logger.sh installed (~/.claude/hooks/)"
    local claude_settings="$HOME/.claude/settings.json"
    if [[ -f "$claude_settings" ]]; then
      python3 - "$claude_settings" "$sul_dst" <<'PYEOF' || warn "skill-usage-logger merge into ~/.claude/settings.json failed (manual edit may be needed)"
import json, sys, os
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        s = json.load(f)
except Exception as e:
    print(f'  ! ~/.claude/settings.json is malformed ({e}) — skipping skill-usage-logger merge')
    sys.exit(1)
hooks = s.setdefault('hooks', {})
ptu = hooks.setdefault('PostToolUse', [])
hook_cmd_norm = hook_cmd.replace(os.path.expanduser('~'), '$HOME')
already = any(
    any(h.get('command', '').endswith('skill-usage-logger.sh') for h in group.get('hooks', []))
    for group in ptu
)
if already:
    print('  ✓ skill-usage-logger already registered in ~/.claude/settings.json (no change)')
    sys.exit(0)
ptu.append({'matcher': 'Skill', 'hooks': [{'type': 'command', 'command': hook_cmd_norm, 'timeout': 5}]})
with open(settings_path, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
print('  ✓ skill-usage-logger registered in ~/.claude/settings.json (PostToolUse matcher=Skill)')
PYEOF
    else
      warn "~/.claude/settings.json not found — skill-usage-logger not registered"
    fi
  else
    warn "hooks/skill-usage-logger.sh not found in repo — skill-usage logger not installed"
  fi

  # ── Pipeline-entry hooks: full tree (incl. lib/) into ~/.claude/hooks/ (the
  # core.hooksPath target) + CI script + git shim + CI workflow template into
  # ~/.claude/scripts and ~/.claude/ci. The plugin hooks.json (in the cache)
  # already registers the gates + the SINGLE Stop site; install does NOT register
  # the Stop nudge in settings.json (one site, no double-fire).
  install_hook_tree "$hooks_dir"
  install_pipeline_artifacts "$HOME/.claude"
  ok "pipeline-entry hooks + lib + CI artifacts installed (~/.claude/hooks, ~/.claude/scripts, ~/.claude/ci)"
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

  # Step 4: Copy agents (TOML configs), then prune zuvo-managed orphans.
  if [[ -d "$DIST/agents" ]] && ls "$DIST"/agents/*.toml &>/dev/null; then
    cp "$DIST"/agents/*.toml "$HOME/.codex/agents/"
    # Prune stale zuvo TOMLs: present in ~/.codex/agents but no longer in the
    # fresh dist (e.g. a renamed/removed skill like content-optimize). Only
    # delete files we manage — identified by the "zuvo:" marker the generator
    # writes into every TOML — never the user's own Codex agents.
    local pruned=0 installed base
    for installed in "$HOME/.codex/agents"/*.toml; do
      [[ -f "$installed" ]] || continue
      base=$(basename "$installed")
      if [[ ! -f "$DIST/agents/$base" ]] && grep -q "zuvo:" "$installed" 2>/dev/null; then
        rm -f "$installed"
        pruned=$((pruned + 1))
      fi
    done
    AGENT_COUNT=$(ls "$HOME/.codex/agents"/*.toml 2>/dev/null | wc -l | tr -d ' ')
    if [[ $pruned -gt 0 ]]; then
      ok "Agent TOMLs installed ($AGENT_COUNT total, $pruned stale pruned)"
    else
      ok "Agent TOMLs installed ($AGENT_COUNT total)"
    fi
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

  # Step 7: Copy scripts (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh, infra-collect.sh)
  if [[ -d "$ZUVO_DIR/scripts" ]]; then
    mkdir -p "$HOME/.codex/scripts"
    cp "$ZUVO_DIR"/scripts/benchmark.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/adversarial-review.sh "$HOME/.codex/scripts/adversarial-review.sh".zuvo-tmp.$$ 2>/dev/null && mv -f "$HOME/.codex/scripts/adversarial-review.sh".zuvo-tmp.$$ "$HOME/.codex/scripts/adversarial-review.sh" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-model-route.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/blind-audit-codex.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/infra-collect.sh "$HOME/.codex/scripts/" 2>/dev/null || true
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

    # Copy hook scripts + hooks/lib/ (recursive — the pre-push + commit gates SOURCE
    # pipeline-gate-lib.sh; a non-recursive cp would drop lib/ and degrade the gates).
    if [[ -d "$DIST/hooks" ]]; then
      cp "$DIST"/hooks/* "$CODEX_PLUGIN_CACHE/hooks/" 2>/dev/null || true
      [[ -d "$DIST/hooks/lib" ]] && { cp -R "$DIST/hooks/lib" "$CODEX_PLUGIN_CACHE/hooks/" 2>/dev/null || true; chmod +x "$CODEX_PLUGIN_CACHE"/hooks/lib/*.sh 2>/dev/null || true; }
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

  # Step 9: Install zuvo into Codex's proper plugin cache so Codex CLI keeps
  # auto-discovering it after we strip the flat install for Cursor dedup.
  # Cursor scans **/.codex/skills/** but NOT **/.codex/plugins/**, so plugin
  # cache is invisible to Cursor while Codex loads it natively (same path as
  # OpenAI bundled plugins like browser-use).
  local CODEX_PLUGIN_DIR="$HOME/.codex/plugins/cache/zuvo-marketplace/zuvo/$VERSION"
  if [[ -d "$DIST/skills" ]]; then
    rm -rf "$HOME/.codex/plugins/cache/zuvo-marketplace/zuvo"
    mkdir -p "$CODEX_PLUGIN_DIR/skills" "$CODEX_PLUGIN_DIR/.codex-plugin"
    cp -r "$DIST"/skills/* "$CODEX_PLUGIN_DIR/skills/" 2>/dev/null || true
    if [[ -f "$DIST/.codex-plugin/plugin.json" ]]; then
      cp "$DIST/.codex-plugin/plugin.json" "$CODEX_PLUGIN_DIR/.codex-plugin/plugin.json"
    elif [[ -f "$ZUVO_DIR/.codex-plugin/plugin.json" ]]; then
      cp "$ZUVO_DIR/.codex-plugin/plugin.json" "$CODEX_PLUGIN_DIR/.codex-plugin/plugin.json"
    fi
    if [[ -f "$DIST/hooks.json" ]]; then
      cp "$DIST/hooks.json" "$CODEX_PLUGIN_DIR/hooks.json"
    fi
    if [[ -d "$DIST/hooks" ]]; then
      mkdir -p "$CODEX_PLUGIN_DIR/hooks"
      cp "$DIST"/hooks/* "$CODEX_PLUGIN_DIR/hooks/" 2>/dev/null || true
      [[ -d "$DIST/hooks/lib" ]] && { cp -R "$DIST/hooks/lib" "$CODEX_PLUGIN_DIR/hooks/" 2>/dev/null || true; chmod +x "$CODEX_PLUGIN_DIR"/hooks/lib/*.sh 2>/dev/null || true; }
      chmod +x "$CODEX_PLUGIN_DIR"/hooks/*.sh 2>/dev/null || true
      chmod +x "$CODEX_PLUGIN_DIR"/hooks/session-start 2>/dev/null || true
    fi
    ok "Installed to ~/.codex/plugins/cache/zuvo-marketplace/zuvo/$VERSION (Codex plugin cache)"
  fi

  # Codex desktop app reads skills from ~/.codex/skills/ directly (its
  # Skills tab enumerates this dir). Plugin cache copy above is for the
  # Codex CLI / future compat. Cursor v3 reads its own ~/.cursor/skills-cursor/
  # (per cursor-managed-skills-manifest.json) and does NOT scan ~/.codex/skills/,
  # so there is no cross-tool collision to dedup against.

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

  # Step 7: Copy scripts (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh, infra-collect.sh)
  if [[ -d "$ZUVO_DIR/scripts" ]]; then
    mkdir -p "$HOME/.cursor/scripts"
    cp "$ZUVO_DIR"/scripts/benchmark.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/adversarial-review.sh "$HOME/.cursor/scripts/adversarial-review.sh".zuvo-tmp.$$ 2>/dev/null && mv -f "$HOME/.cursor/scripts/adversarial-review.sh".zuvo-tmp.$$ "$HOME/.cursor/scripts/adversarial-review.sh" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-model-route.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/blind-audit-codex.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/infra-collect.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.cursor"/scripts/*.sh 2>/dev/null || true
    ok "Scripts installed"
  fi

  # Step 8: Clean duplicates when Claude Code cache exists
  # Cursor scans ~/.cursor/skills/, ~/.cursor/agents/, AND ~/.claude/plugins/cache/
  # without deduplication (known Cursor bug). When Claude Code's zuvo cache exists,
  # remove ~/.cursor/skills/ and ~/.cursor/agents/ to prevent double/triple entries.
  if [[ -d "$HOME/.claude/plugins/cache/zuvo-marketplace" ]]; then
    local cleaned=false
    if [[ -d "$HOME/.cursor/skills/write-tests" || -d "$HOME/.cursor/skills/using-zuvo" ]]; then
      rm -rf "$HOME/.cursor/skills"
      cleaned=true
    fi
    if [[ -d "$HOME/.cursor/agents" ]] && ls "$HOME/.cursor/agents/"*-*.md &>/dev/null 2>&1; then
      rm -rf "$HOME/.cursor/agents"
      cleaned=true
    fi
    if [[ "$cleaned" == "true" ]]; then
      ok "Duplicate skills/agents removed (Cursor uses Claude Code cache)"
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

  # Step 7: Copy hooks (+ hooks/lib/ recursively — gates source the lib) + merge settings.json
  if [[ -d "$DIST/hooks" ]]; then
    mkdir -p "$HOME/.gemini/antigravity/hooks"
    cp "$DIST"/hooks/* "$HOME/.gemini/antigravity/hooks/" 2>/dev/null || true
    [[ -d "$DIST/hooks/lib" ]] && { cp -R "$DIST/hooks/lib" "$HOME/.gemini/antigravity/hooks/" 2>/dev/null || true; chmod +x "$HOME/.gemini/antigravity"/hooks/lib/*.sh 2>/dev/null || true; }
    chmod +x "$HOME/.gemini/antigravity"/hooks/*.sh 2>/dev/null || true
    chmod +x "$HOME/.gemini/antigravity/hooks/session-start" 2>/dev/null || true
    ok "Hook scripts installed"
  fi

  # Merge hook config into ~/.gemini/settings.json (idempotent, dedup-safe).
  # Strategy: remove ALL entries pointing at ~/.gemini/antigravity/hooks/<zuvo>,
  # then re-append the canonical groups from the template. Repeated install runs
  # cannot accumulate duplicates this way. Also self-heals stale state from the
  # previous merge bug (which only matched 2 of 3 zuvo scripts and appended the
  # full group every run, blowing BeforeTool up to 60+ entries).
  if [[ -f "$DIST/hooks.json" ]]; then
    local gemini_settings="$HOME/.gemini/settings.json"
    python3 -c "
import json, sys, os, tempfile

hooks_template = sys.argv[1]
settings_path = sys.argv[2]
zuvo_hook_marker = '/.gemini/antigravity/hooks/'

with open(hooks_template) as f:
    template = json.load(f)

settings = {}
if os.path.exists(settings_path):
    try:
        with open(settings_path) as f:
            settings = json.load(f)
    except (json.JSONDecodeError, ValueError):
        print('  ! settings.json is malformed -- skipping hook merge')
        sys.exit(0)

settings.setdefault('hooks', {})

removed = 0
added = 0

for event_name, template_groups in template.get('hooks', {}).items():
    existing_groups = settings['hooks'].setdefault(event_name, [])

    cleaned = []
    for group in existing_groups:
        kept_hooks = [
            h for h in group.get('hooks', [])
            if zuvo_hook_marker not in h.get('command', '')
        ]
        before = len(group.get('hooks', []))
        removed += before - len(kept_hooks)
        if kept_hooks:
            new_group = {**group, 'hooks': kept_hooks}
            cleaned.append(new_group)
        elif before == 0:
            cleaned.append(group)

    for tg in template_groups:
        cleaned.append(tg)
        added += len(tg.get('hooks', []))

    settings['hooks'][event_name] = cleaned

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(settings_path), suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    json.dump(settings, f, indent=2)
    f.write('\n')
os.rename(tmp, settings_path)
print(f'  \u2713 Hooks merged into settings.json (removed {removed} stale zuvo entries, added {added} canonical)')
" "$DIST/hooks.json" "$HOME/.gemini/settings.json" 2>/dev/null || warn "settings.json merge failed"
  fi

  ok "Antigravity updated"
}

# =======================================
# MAIN
# =======================================
# VERSION is computed unconditionally (functions reference it; harmless when sourced).
VERSION=$(grep '"version"' "$ZUVO_DIR/package.json" | head -1 | sed 's/.*"version": *"\([^"]*\)".*/\1/')

# Only RUN the installer when executed directly — not when sourced (tests source
# this file to call install_hook_tree / install_pipeline_artifacts / install_git_shim).
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
set -euo pipefail

echo "Installing zuvo v${VERSION} from $ZUVO_DIR"

echo "Validating banned-vocabulary contracts..."
"$ZUVO_DIR/scripts/validate-banned-vocabulary.sh"
echo "Validating banned-vocabulary fixtures..."
"$ZUVO_DIR/scripts/validate-banned-vocabulary-fixtures.sh"

case "$TARGET" in
  claude) install_claude; install_claude_home ;;
  codex)  install_codex ;;
  cursor) install_cursor ;;
  antigravity) install_antigravity ;;
  both|all) install_claude; install_codex; install_cursor; install_antigravity; install_zuvo_home; install_claude_home ;;
  *)      echo "Usage: $0 [claude|codex|cursor|antigravity|all]"; exit 1 ;;
esac

# Opt-in git PATH-shim (ZUVO_INSTALL_GIT_SHIM / ZUVO_UNINSTALL_GIT_SHIM); no-op otherwise.
install_git_shim

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
  # Mirror adversarial-review.sh detect_providers (the source of truth): the real
  # auto-detected set is codex → agy → cursor-agent → kimi → claude. The free
  # `gemini` CLI is DEAD for individuals (agy is the live Google channel), and
  # kimi (Moonshot, OAuth CLI) was added in v1.6.18 — an install check that still
  # probes `gemini` and omits `kimi` is exactly the stale list that misleads.
  local has_codex="" has_agy="" has_gemini="" has_cursor="" has_kimi="" has_claude=""
  command -v codex &>/dev/null && has_codex=1
  [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]] && has_codex=1
  command -v agy &>/dev/null && has_agy=1
  command -v gemini &>/dev/null && has_gemini=1   # legacy/dead CLI — only counts if agy absent
  command -v cursor-agent &>/dev/null && has_cursor=1
  { command -v kimi &>/dev/null || [[ -n "${MOONSHOT_API_KEY:-}" ]]; } && has_kimi=1
  command -v claude &>/dev/null && has_claude=1

  # Google is ONE vendor: count agy OR gemini once (agy preferred).
  local has_google=""
  [[ -n "$has_agy" || -n "$has_gemini" ]] && has_google=1

  local count=0
  [[ -n "$has_codex" ]] && count=$((count + 1))
  [[ -n "$has_google" ]] && count=$((count + 1))
  [[ -n "$has_cursor" ]] && count=$((count + 1))
  [[ -n "$has_kimi" ]] && count=$((count + 1))
  [[ -n "$has_claude" ]] && count=$((count + 1))

  print_providers() {
    [[ -n "$has_codex" ]] && echo "    ✓ codex (OpenAI)"
    [[ -n "$has_agy" ]] && echo "    ✓ agy (Google/Antigravity)" || { [[ -n "$has_gemini" ]] && echo "    ✓ gemini (Google — legacy CLI, dead for individuals; prefer agy)"; }
    [[ -n "$has_cursor" ]] && echo "    ✓ cursor-agent (Cursor)"
    [[ -n "$has_kimi" ]] && echo "    ✓ kimi (Moonshot — OAuth CLI, no API key needed)"
    [[ -n "$has_claude" ]] && echo "    ✓ claude (Anthropic)"
  }

  if [[ $count -eq 0 ]]; then
    echo "  ⚠ WARNING: No adversarial review providers found!"
    echo ""
    echo "  Zuvo uses cross-model review — a DIFFERENT AI reviews code"
    echo "  written by your primary AI. Install at least one (different vendor from your host):"
    echo ""
    echo "    npm install -g @openai/codex              # Codex CLI (OpenAI)"
    echo "    curl -fsSL https://antigravity.google/cli/install.sh | bash   # agy (Google/Gemini)"
    echo "    # kimi (Moonshot) — install the kimi CLI, then: kimi login"
    echo "    # claude CLI — already included with Claude Code"
    echo ""
    echo "  Without a cross-provider, adversarial review will be skipped."
    echo "  Verify what actually works: adversarial-review --doctor"
    echo ""
  elif [[ $count -eq 1 ]]; then
    echo "  Cross-provider check: 1 vendor found."
    echo "  Adversarial review needs a provider DIFFERENT from your host IDE."
    print_providers
    echo ""
    echo "  For full coverage, install one more provider from a different vendor."
    echo "  Verify: adversarial-review --doctor"
    echo ""
  else
    echo "  Cross-provider check: $count vendors found ✓"
    print_providers
    echo ""
  fi
}

check_cross_providers

fi  # end main run guard (skipped when sourced)