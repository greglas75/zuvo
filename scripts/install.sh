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

# Portable primitives (sed_i, zuvo_python) — Windows/Git-Bash is a supported target and
# the BSD-only `sed -i ''` it replaces breaks there. See scripts/lib/portable.sh.
. "$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)/lib/portable.sh"

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
      # Never carry a test fixture out of the repo. tests/skill-suite/test-references-guards.sh
      # creates skills/tmp-refguard-$$-test/ inside the real tree (B-REFGUARD); an install that
      # overlaps a running guard test — or follows a killed one — copied it into the cache, where
      # it persisted indefinitely. Found in BOTH 1.6.52 and 1.6.53 on 2026-08-03 and removed by
      # hand. Skipping `tmp-*` makes the leak impossible regardless of timing.
      case "$skill_name" in tmp-*) continue ;; esac
      mkdir -p "$CACHE_DIR/skills/$skill_name"
      cp -r "$skill_dir"* "$CACHE_DIR/skills/$skill_name/" 2>/dev/null || true
    done
    # Replace {plugin_root} placeholder with actual resolved path in all skill files
    local resolved_root="${CACHE_DIR%/}"
    # `find -exec` cannot call the sed_i shell function, so use the portable -i.<suffix> form
    # directly and sweep the backups. The old `sed -i ''` here was BSD-only AND swallowed by
    # `|| true`, so on Git Bash the install "succeeded" with {plugin_root} never substituted.
    find "$CACHE_DIR/skills" -name "*.md" -exec \
      sed -i.zbak "s|{plugin_root}|${resolved_root}|g" {} + 2>/dev/null || true
    find "$CACHE_DIR/skills" -name "*.md.zbak" -delete 2>/dev/null || true
    # Clean up any orphan files at skills/ root level
    rm -f "$CACHE_DIR/skills/SKILL.md" 2>/dev/null || true
    rm -rf "$CACHE_DIR/skills/agents" 2>/dev/null || true

    # Strip non-Claude-Code platform blocks (CODEX, CURSOR, ANTIGRAVITY)
    # Each block is delimited by <!-- PLATFORM:X --> ... <!-- /PLATFORM:X -->
    find "$CACHE_DIR/skills" -name "*.md" -exec \
      sed_i -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
                -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
                -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
                  -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
                {} + 2>/dev/null || true

    # Copy shared includes
    if [[ -d "$ZUVO_DIR/shared/includes" ]] && [[ -d "$CACHE_DIR/shared/includes" ]]; then
      cp -R "$ZUVO_DIR"/shared/includes/. "$CACHE_DIR/shared/includes/" 2>/dev/null || true
      # Strip non-Claude-Code platform blocks from shared includes too
      find "$CACHE_DIR/shared/includes" -name "*.md" -exec \
        sed_i -e '/<!-- PLATFORM:CODEX -->/,/<!-- \/PLATFORM:CODEX -->/d' \
                  -e '/<!-- PLATFORM:CURSOR -->/,/<!-- \/PLATFORM:CURSOR -->/d' \
                  -e '/<!-- PLATFORM:ANTIGRAVITY -->/,/<!-- \/PLATFORM:ANTIGRAVITY -->/d' \
                  -e '/<!-- PLATFORM:KIMI -->/,/<!-- \/PLATFORM:KIMI -->/d' \
                  {} + 2>/dev/null || true
    fi

    # Copy rules
    if [[ -d "$ZUVO_DIR/rules" ]] && [[ -d "$CACHE_DIR/rules" ]]; then
      cp "$ZUVO_DIR"/rules/*.md "$CACHE_DIR/rules/" 2>/dev/null || true
    fi

    # Copy scripts (adversarial-review.sh, etc.). *.py too — test-coverage-gate.py
    # is the write-tests executable gate; a *.sh-only copy silently shipped a skill
    # that calls a nonexistent validator (caught 2026-07-31). scripts/lib/ rides
    # along for anything that sources it.
    if [[ -d "$ZUVO_DIR/scripts" ]]; then
      mkdir -p "$CACHE_DIR/scripts"
      cp "$ZUVO_DIR"/scripts/*.sh "$CACHE_DIR/scripts/" 2>/dev/null || true
      cp "$ZUVO_DIR"/scripts/*.py "$CACHE_DIR/scripts/" 2>/dev/null || true
      [[ -d "$ZUVO_DIR/scripts/lib" ]] && cp -R "$ZUVO_DIR"/scripts/lib "$CACHE_DIR/scripts/" 2>/dev/null || true
      chmod +x "$CACHE_DIR"/scripts/*.sh "$CACHE_DIR"/scripts/*.py 2>/dev/null || true
    fi

    # Copy the VERSION marker to the target root AND skills/ — so ANY install,
    # including a bare skills-only fleet deploy with no manifest, is version-
    # identifiable (`cat <root>/VERSION` or `cat <root>/skills/VERSION`).
    if [[ -f "$ZUVO_DIR/VERSION" ]]; then
      cp "$ZUVO_DIR/VERSION" "$CACHE_DIR/VERSION" 2>/dev/null || true
      mkdir -p "$CACHE_DIR/skills"
      cp "$ZUVO_DIR/VERSION" "$CACHE_DIR/skills/VERSION" 2>/dev/null || true
    fi

    # Copy the Claude Code plugin manifest. The Codex targets have had this since
    # forever (see the .codex-plugin copies further down); the Claude cache never
    # did, so every cache dir kept whatever manifest Claude Code itself wrote when
    # it created that directory — and nothing refreshed it afterwards.
    # Measured 2026-08-03 while verifying the v1.6.54 install (backlog
    # B-INSTALL-CLAUDE-MANIFEST): after installing 1.6.54, the manifest inside the
    # 1.6.53 cache dir still declared 1.6.16, and the one inside 1.6.54 declared
    # 1.6.47. Skills still load (everything else here IS synced to every cache
    # dir), so this is metadata drift rather than a load failure — which is
    # exactly why it survived ~40 releases unnoticed.
    # NB the drift is not visible in a dir Claude Code has just created for a
    # fresh version: it writes a correct manifest at creation time, and only
    # later installs into that same dir leave it behind. Guarded by
    # test-install-wiring.sh (9).
    if [[ -f "$ZUVO_DIR/.claude-plugin/plugin.json" ]]; then
      mkdir -p "$CACHE_DIR/.claude-plugin"
      # WARN, not a silent `|| true`. The seven sibling copies in this loop
      # swallow their failures, and that convention is precisely how this
      # manifest went stale for ~40 releases without a signal. A copy that fails
      # here leaves the drift this block exists to fix, so a failed run must at
      # least SAY so — otherwise "install.sh reported OK" answers a question it
      # never actually checked.
      cp "$ZUVO_DIR/.claude-plugin/plugin.json" "$CACHE_DIR/.claude-plugin/plugin.json" 2>/dev/null \
        || echo "  WARN: could not refresh $CACHE_DIR/.claude-plugin/plugin.json — its version/skill-count metadata stays stale" >&2
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

  # Install EVERY helper in scripts/zuvo-home/ — a loop, not a per-file block. The explicit list
  # this replaces had silently drifted: retro-mine.py, retro-mine-weekly.sh and rotate-retros-cron.sh
  # were versioned in the repo but never installed, so a fresh machine got the file in git and
  # nothing in ~/.zuvo. Adding a helper must not require remembering to add an install block.
  local _installed=0 _skipped=0
  # `scripts/adversarial-review.sh` is appended to the loop's input even though it
  # does not live in scripts/zuvo-home/ — it is also shipped as bin/adversarial-review,
  # so it cannot simply be moved. It belongs in ~/.zuvo/ for the same reason every
  # helper here does, and its absence was a real fleet-wide outage:
  #
  # Claude Code puts {installPath}/bin on PATH ONCE, at session start. A release
  # creates a new cache dir and removes the old one, so every session that was open
  # across a release has a PATH entry pointing at a deleted directory and
  # `adversarial-review` becomes "command not found" mid-run. Measured 2026-08-05
  # after four same-day releases (1.6.53 -> .57): a live session's PATH still held
  # .../zuvo/1.6.53/bin while only 1.6.56 and 1.6.57 existed on disk. That is the
  # "adversarial doesn't work" agents were reporting — not a provider problem.
  #
  # ~/.zuvo/ is version-independent, which is exactly why append-runlog,
  # build-review-patch and verify-plan-dag already live here and never break this way.
  # review-artifact-sync.sh joins them for the same reason, one level up: it is the documented
  # remedy when the pre-push gate blocks because the review pair lives in another checkout, and
  # every skill that names it used a REPO-RELATIVE path (`scripts/review-artifact-sync.sh`). That
  # path exists only inside zuvo-plugin — in the repo the agent is actually shipping, the
  # remediation command a blocked run prints did not exist. It keeps its `.sh` (callers use it).
  for _src in "$ZUVO_DIR"/scripts/zuvo-home/* "$ZUVO_DIR"/scripts/adversarial-review.sh \
              "$ZUVO_DIR"/scripts/review-artifact-sync.sh; do
    [[ -f "$_src" ]] || continue
    local _name; _name="$(basename "$_src")"
    case "$_name" in *.pyc|__pycache__|.*) continue ;; esac
    # Installed WITHOUT the .sh, matching how every skill and the bin wrapper name
    # it. The other *.sh helpers in zuvo-home keep their extension (callers use it),
    # so this is a targeted rename, not a blanket strip.
    [[ "$_name" == "adversarial-review.sh" ]] && _name="adversarial-review"
    # Copy to a temp name and mv into place: `cp` over a LIVE executable truncates it first, so a
    # helper running from cron at that moment reads a half-written file. mv within one filesystem
    # is atomic. (Not a regression from the loop — the per-file blocks used a plain cp too — but
    # cheap to get right while the code is being touched.)
    if cp "$_src" "$HOME/.zuvo/.$_name.tmp.$$" 2>/dev/null; then
      # Executable bit follows the SOURCE, not a blanket +x. chmod'ing every regular file turned
      # any future data/README dropped into scripts/zuvo-home/ into a runnable user command.
      if [[ -x "$_src" ]]; then chmod +x "$HOME/.zuvo/.$_name.tmp.$$" 2>/dev/null || true; fi
      mv -f "$HOME/.zuvo/.$_name.tmp.$$" "$HOME/.zuvo/$_name" 2>/dev/null || {
        rm -f "$HOME/.zuvo/.$_name.tmp.$$" 2>/dev/null
        warn "$_name not installed (~/.zuvo/$_name) — atomic replace failed"
        _skipped=$((_skipped + 1)); continue
      }
      # Per-helper line, not just a count: the install log is how you find out WHICH helper
      # failed to land. Dropping it for a tidy summary lost real information (and an outcome
      # test caught it), so the loop keeps the same message shape the per-file blocks emitted.
      ok "$_name installed (~/.zuvo/$_name)"
      _installed=$((_installed + 1))
    else
      warn "$_name not installed (~/.zuvo/$_name) — copy failed"
      _skipped=$((_skipped + 1))
    fi
  done
  if [[ "$_skipped" -gt 0 ]]; then
    ok "$_installed zuvo-home helpers installed to ~/.zuvo/ ($_skipped skipped)"
  else
    ok "$_installed zuvo-home helpers installed to ~/.zuvo/"
  fi

  # portable.sh must sit NEXT TO the helpers: retro-mine-weekly.sh / rotate-retros-cron.sh /
  # runlog-sync.sh source it as "$(dirname "$0")/portable.sh" to resolve a Python 3 interpreter,
  # and `python3` is not a command on Windows.
  if [[ -f "$ZUVO_DIR/scripts/lib/portable.sh" ]]; then
    cp "$ZUVO_DIR/scripts/lib/portable.sh" "$HOME/.zuvo/.portable.sh.tmp.$$" 2>/dev/null \
      && mv -f "$HOME/.zuvo/.portable.sh.tmp.$$" "$HOME/.zuvo/portable.sh" \
      && ok "portable.sh installed (~/.zuvo/portable.sh — sed_i + zuvo_python)"
  fi

  # Local, NEVER-versioned config for host-coupled helpers (collector SSH target). Created empty
  # so the file exists to edit; the helpers fail loudly with instructions when it has no host.
  if [[ ! -f "$HOME/.zuvo/collector.conf" ]]; then
    cat > "$HOME/.zuvo/collector.conf" <<'CONF'
# ~/.zuvo/collector.conf — machine-local, NOT in git (it names a private host).
# Set this to the telemetry collector's SSH target to enable backlog/runlog/popebot sync.
# ZUVO_COLLECTOR_SSH=user@host
CONF
    chmod 600 "$HOME/.zuvo/collector.conf"
    ok "collector.conf stub created (~/.zuvo/collector.conf — set ZUVO_COLLECTOR_SSH to enable sync)"
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
# Currently: post-commit hook that appends each commit to
# ~/.claude/projects/<project>/memory/review-backlog.md (a HOME-local list, per project).
# It does NOT write docs/review-queue.md — that file was removed 2026-07-28 as a dead artifact:
# nothing wrote to it and zuvo:review had already moved to content-keyed memory/reviews/ coverage.
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

  # ── Claude Code SessionStart hook: zuvo-plugin-enable-guard (added 2026-08-12)
  # A release can leave the plugin DISABLED even after `claude plugin enable` reports
  # success: the CLI writes ~/.claude/settings.json, and a Claude Code that was running
  # through the release owns that file and can persist its own older view afterwards.
  # Measured 2026-08-12 — release said "✓ Plugin enabled", next start had it disabled in
  # both scopes and all 57 skills invisible. Must be GLOBAL: a plugin-scoped hook does not
  # run while its own plugin is off, which is the state it would need to fix.
  local peg_src="$ZUVO_DIR/hooks/zuvo-plugin-enable-guard.sh"
  local peg_dst="$hooks_dir/zuvo-plugin-enable-guard.sh"
  if [[ -f "$peg_src" ]]; then
    mkdir -p "$hooks_dir"
    cp "$peg_src" "$peg_dst"
    chmod +x "$peg_dst"
    # Stamp the assertion: running install IS the claim that zuvo should be active. The
    # guard heals exactly this one stamp, once — so a deliberate `claude plugin disable`
    # after an install still sticks on the second try.
    # Guarded, unlike the naked `mkdir -p` this started as: the whole file runs under
    # `set -euo pipefail`, so if ~/.zuvo is ever NOT a directory (a stray `touch ~/.zuvo`, a
    # half-finished earlier install) the bare form aborts install.sh mid-run with a one-line
    # `mkdir: File exists` and silently skips every remaining step — Codex, Cursor and
    # Antigravity builds included. A stamp we could not write is worth a warning, never a
    # dead installer; the guard already treats a missing stamp as "no assertion on record".
    if mkdir -p "$HOME/.zuvo" 2>/dev/null \
       && printf 'asserted_at=%s\nhealed_for=\n' "$(date +%s)" > "$HOME/.zuvo/plugin-enable-state" 2>/dev/null; then
      ok "zuvo-plugin-enable-guard.sh installed (~/.claude/hooks/) + assertion stamped"
    else
      warn "zuvo-plugin-enable-guard.sh installed, but ~/.zuvo/plugin-enable-state could NOT be written — the guard will stand down instead of re-enabling after a release"
    fi
    local claude_settings="$HOME/.claude/settings.json"
    if [[ -f "$claude_settings" ]]; then
      python3 - "$claude_settings" "$peg_dst" <<'PYEOF' || warn "enable-guard merge into ~/.claude/settings.json failed (manual edit may be needed)"
import json, sys, os
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
try:
    with open(settings_path) as f:
        s = json.load(f)
except Exception as e:
    print(f'  ! ~/.claude/settings.json is malformed ({e}) — skipping enable-guard merge')
    sys.exit(1)
hooks = s.setdefault('hooks', {})
ss = hooks.setdefault('SessionStart', [])
hook_cmd_norm = hook_cmd.replace(os.path.expanduser('~'), '$HOME')
already = any(
    any(h.get('command', '').endswith('zuvo-plugin-enable-guard.sh') for h in group.get('hooks', []))
    for group in ss
)
if already:
    print('  ✓ enable-guard already registered in ~/.claude/settings.json (no change)')
    sys.exit(0)
ss.append({'hooks': [{'type': 'command', 'command': hook_cmd_norm, 'timeout': 5}]})
# Atomic, and THROUGH a symlink if settings.json is one (dotfile managers). A bare
# open(path,'w') truncates first, so an interrupt mid-write leaves an invalid
# settings.json and every future Claude Code session is broken until hand-repaired.
# The hook being registered here documents exactly this reasoning; the installer that
# registers it should not contradict it.
real = os.path.realpath(settings_path)
tmp = real + '.zuvo-tmp'
with open(tmp, 'w') as f:
    json.dump(s, f, indent=2)
    f.write('\n')
os.replace(tmp, real)
print('  ✓ enable-guard registered in ~/.claude/settings.json (SessionStart)')
PYEOF
    else
      warn "~/.claude/settings.json not found — enable-guard not registered"
    fi
  else
    warn "hooks/zuvo-plugin-enable-guard.sh not found in repo — plugin enable-guard not installed"
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
    # write-tests executable gate + Phase-0 reviewer canary + artifact pair sync (2026-07-31)
    cp "$ZUVO_DIR"/scripts/test-coverage-gate.py "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-preflight.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/review-artifact-sync.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.codex"/scripts/*.py 2>/dev/null || true
    # install-refactor-gate.sh is invoked by zuvo:refactor PHASE 0 to wire the repo git hook.
    cp "$ZUVO_DIR"/scripts/install-refactor-gate.sh "$HOME/.codex/scripts/" 2>/dev/null || true
    # …and the gate itself. Kept next to the installer (not only in the plugin cache, which is
    # created conditionally) so PHASE 0 resolves both halves from one predictable location.
    cp "$ZUVO_DIR"/hooks/refactor-safety-gate.sh "$HOME/.codex/scripts/" 2>/dev/null || true
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
    # write-tests executable gate + Phase-0 reviewer canary + artifact pair sync (2026-07-31)
    cp "$ZUVO_DIR"/scripts/test-coverage-gate.py "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-preflight.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/review-artifact-sync.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.cursor"/scripts/*.py 2>/dev/null || true
    # install-refactor-gate.sh is invoked by zuvo:refactor PHASE 0 to wire the repo git hook.
    cp "$ZUVO_DIR"/scripts/install-refactor-gate.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    # …and the gate itself. Kept next to the installer (not only in the plugin cache, which is
    # created conditionally) so PHASE 0 resolves both halves from one predictable location.
    cp "$ZUVO_DIR"/hooks/refactor-safety-gate.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
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

  # Antigravity's GLOBAL CUSTOMIZATION ROOT is ~/.gemini/config -- skills are read
  # from "skills/<name>/" relative to THAT, not from ~/.gemini/antigravity/.
  #
  # This was wrong from the first Antigravity release: every skill installed to
  # ~/.gemini/antigravity/skills/, which the app never reads, so zuvo was silently
  # absent while `install.sh` reported success and the files were visibly on disk.
  # Established 2026-08-11 by the app's own language_server strings ("Global
  # Discovery: `~/.gemini/config/`", "Location: skills/<skill_name>/ (relative to
  # the customization root)") and then PROVEN by an A/B canary: the same skill name
  # placed in both directories resolved to the ~/.gemini/config copy.
  local AG_SKILLS="$HOME/.gemini/config/skills"

  # Step 2: Clean old symlinks and stale files
  #
  # Remove ONLY zuvo-owned skill directories, never the whole tree. `$AG_SKILLS` is
  # Antigravity's SHARED global customization root — the same directory any other
  # tool or the user puts skills in. The pre-fix code could `rm -rf` its target
  # safely because that target (~/.gemini/antigravity/skills) belonged to zuvo
  # alone; moving to the shared root without narrowing the delete turned a safe
  # line into silent third-party data loss, with install still reporting success.
  # Caught by the adversarial pass on this very change (2026-08-11).
  # Narrowing the delete to zuvo's 57 NAMES was still not enough: several of them are
  # generic English words (review, docs, debug, design, backlog), so a user's or another
  # tool's same-named skill in this shared root was deleted anyway — the same silent data
  # loss, narrowed from "always" to "on collision". And a name-keyed delete can never prune
  # a skill zuvo RENAMED (content-optimize -> content-expand): the old name is absent from
  # $DIST, so nothing targets it and it stays loaded forever. Both are fixed by keying on
  # PROVENANCE instead of name — the same marker pattern install_codex() already uses for
  # TOMLs (see "never the user's own Codex agents" above).
  local AG_MARKER=".zuvo-owned"
  mkdir -p "$AG_SKILLS"

  # Is this the first run since markers existed? If nothing carries one, the only evidence
  # available is the name, so adopt by name ONCE — which is exactly the previous behaviour,
  # no worse — and stamp markers on the way out. Every later run is provenance-checked.
  local ag_adopt=1 _d _base
  for _d in "$AG_SKILLS"/*/; do
    [[ -d "$_d" ]] || continue
    if [[ -f "$_d$AG_MARKER" ]]; then ag_adopt=0; break; fi
  done

  # Prune zuvo-owned skills this release no longer ships.
  local ag_pruned=0
  for _d in "$AG_SKILLS"/*/; do
    [[ -d "$_d" ]] || continue
    _base=$(basename "$_d")
    if [[ -f "$_d$AG_MARKER" && ! -d "$DIST/skills/$_base" ]]; then
      rm -rf "$_d"
      ag_pruned=$((ag_pruned + 1))
    fi
  done
  rm -rf "$HOME/.gemini/antigravity/shared"
  rm -rf "$HOME/.gemini/antigravity/rules"
  rm -rf "$HOME/.gemini/antigravity/scripts"
  # Remove the pre-fix location so a machine that ran an older install.sh does not
  # keep a full, stale, never-loaded copy of every skill lying around.
  rm -rf "$HOME/.gemini/antigravity/skills"
  ok "Cleaned old installation (incl. the legacy ~/.gemini/antigravity/skills path)"

  # Step 3: Copy skills (agents stay in subdirectories), stamping ownership as we go.
  # A same-named directory WITHOUT our marker is somebody else's — report and leave it,
  # never overwrite. Refusing to install one skill is recoverable; deleting a user's work
  # is not, so this fails toward doing less.
  mkdir -p "$AG_SKILLS"
  local ag_skipped=0 ag_target
  for skill_dir in "$DIST"/skills/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name=$(basename "$skill_dir")
    ag_target="$AG_SKILLS/$skill_name"
    if [[ -d "$ag_target" && ! -f "$ag_target/$AG_MARKER" && $ag_adopt -eq 0 ]]; then
      warn "skipped '$skill_name' — a directory of that name in $AG_SKILLS carries no zuvo marker (not ours)"
      ag_skipped=$((ag_skipped + 1))
      continue
    fi
    rm -rf "$ag_target"
    cp -r "$skill_dir" "$ag_target"
    printf 'zuvo-owned skill directory. install.sh deletes ONLY directories carrying this file.\n' > "$ag_target/$AG_MARKER"
  done
  SKILL_COUNT=$(ls -d "$AG_SKILLS"/*/ 2>/dev/null | wc -l | tr -d ' ')
  if [[ $ag_pruned -gt 0 || $ag_skipped -gt 0 ]]; then
    ok "Skills installed ($SKILL_COUNT in $AG_SKILLS; $ag_pruned stale pruned, $ag_skipped left to their owners)"
  else
    ok "Skills installed ($SKILL_COUNT total) -> $AG_SKILLS"
  fi

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

  # Step 6: Copy scripts (*.py too — the write-tests executable gate)
  if [[ -d "$DIST/scripts" ]]; then
    mkdir -p "$HOME/.gemini/antigravity/scripts"
    cp "$DIST"/scripts/*.sh "$HOME/.gemini/antigravity/scripts/" 2>/dev/null || true
    cp "$DIST"/scripts/*.py "$HOME/.gemini/antigravity/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.gemini/antigravity"/scripts/*.sh "$HOME/.gemini/antigravity"/scripts/*.py 2>/dev/null || true
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
# KIMI CODE
# =======================================
# Kimi Code auto-discovers user-scope skills at ~/.kimi-code/skills/<name>/SKILL.md and
# agent profiles at ~/.kimi-code/agents/ (FLAT namespace, resolved byName). Both are
# SHARED roots — the user's own skills and agents live there too — so every delete and
# overwrite here is provenance-keyed, exactly as install_antigravity() does. Kimi's
# native plugin registry ($KIMI_CODE_HOME/plugins/installed.json) is deliberately not
# used; see the header of build-kimi-skills.sh.
install_kimi() {
  echo ""
  echo "======================================"
  echo "  KIMI CODE"
  echo "======================================"

  local KIMI_HOME="${KIMI_CODE_HOME:-$HOME/.kimi-code}"

  if [[ ! -d "$KIMI_HOME" ]]; then
    warn "$KIMI_HOME not found -- Kimi Code not installed. Skipping."
    return 0
  fi

  # KIMI_CODE_HOME is user-settable, and two steps below we `rm -rf "$KIMI_HOME/shared"` and
  # "$KIMI_HOME/rules" -- two of the most common directory names there are. "It is a directory"
  # is not evidence that it is KIMI'S directory. Everywhere else in this function the install is
  # provenance-keyed (.zuvo-owned markers, the .zuvo-agents manifest) precisely so zuvo never
  # deletes what it did not install; shared/ and rules/ were the one part with no such guard.
  # Antigravity has the same wipe-then-recreate shape but no home-directory override, so Kimi is
  # the first place the pattern meets a path a typo can redirect.
  if [[ -n "${KIMI_CODE_HOME:-}" ]] \
     && [[ ! -f "$KIMI_HOME/config.toml" && ! -d "$KIMI_HOME/skills" && ! -d "$KIMI_HOME/agents" ]]; then
    fail "KIMI_CODE_HOME=$KIMI_HOME does not look like a Kimi Code home"
    echo "       (no config.toml, no skills/, no agents/). Refusing to run destructive" >&2
    echo "       install steps against it. Unset KIMI_CODE_HOME to use ~/.kimi-code." >&2
    return 1
  fi

  # Step 1: Build
  echo "  Building Kimi distribution..."
  local build_log
  build_log=$(mktemp)
  if ! bash "$ZUVO_DIR/scripts/build-kimi-skills.sh" "$ZUVO_DIR" > "$build_log" 2>&1; then
    fail "Build failed. Build output:"
    cat "$build_log" >&2
    rm -f "$build_log"
    return 1
  fi
  rm -f "$build_log"
  DIST="$ZUVO_DIR/dist/kimi"

  if [[ ! -d "$DIST/skills" ]]; then
    fail "Build failed -- no dist/kimi/skills/ produced"
    return 1
  fi
  ok "Build complete"

  local KIMI_SKILLS="$KIMI_HOME/skills"
  local KIMI_AGENTS="$KIMI_HOME/agents"
  local KIMI_MARKER=".zuvo-owned"
  mkdir -p "$KIMI_SKILLS" "$KIMI_AGENTS"

  # Step 2: Skills — prune zuvo-owned dirs this release no longer ships, then install.
  # First run since markers existed has no provenance to read, so it adopts by name ONCE
  # (same as the Antigravity path) and stamps markers on the way out.
  local kimi_adopt=1 _d _base
  for _d in "$KIMI_SKILLS"/*/; do
    [[ -d "$_d" ]] || continue
    if [[ -f "$_d$KIMI_MARKER" ]]; then kimi_adopt=0; break; fi
  done

  local kimi_pruned=0
  for _d in "$KIMI_SKILLS"/*/; do
    [[ -d "$_d" ]] || continue
    _base=$(basename "$_d")
    if [[ -f "$_d$KIMI_MARKER" && ! -d "$DIST/skills/$_base" ]]; then
      rm -rf "$_d"
      kimi_pruned=$((kimi_pruned + 1))
    fi
  done

  local kimi_skipped=0 kimi_target skill_name
  for skill_dir in "$DIST"/skills/*/; do
    [[ -d "$skill_dir" ]] || continue
    skill_name=$(basename "$skill_dir")
    kimi_target="$KIMI_SKILLS/$skill_name"
    if [[ -d "$kimi_target" && ! -f "$kimi_target/$KIMI_MARKER" && $kimi_adopt -eq 0 ]]; then
      warn "skipped '$skill_name' — a directory of that name in $KIMI_SKILLS carries no zuvo marker (not ours)"
      kimi_skipped=$((kimi_skipped + 1))
      continue
    fi
    rm -rf "$kimi_target"
    cp -r "$skill_dir" "$kimi_target"
    printf 'zuvo-owned skill directory. install.sh deletes ONLY directories carrying this file.\n' > "$kimi_target/$KIMI_MARKER"
  done
  SKILL_COUNT=$(ls -d "$KIMI_SKILLS"/*/ 2>/dev/null | wc -l | tr -d ' ')
  if [[ $kimi_pruned -gt 0 || $kimi_skipped -gt 0 ]]; then
    ok "Skills installed ($SKILL_COUNT in $KIMI_SKILLS; $kimi_pruned stale pruned, $kimi_skipped left to their owners)"
  else
    ok "Skills installed ($SKILL_COUNT total) -> $KIMI_SKILLS"
  fi

  # Step 3: Agents — flat .md files, so a per-directory marker cannot express ownership.
  # A sidecar manifest lists exactly the filenames zuvo installed: it drives pruning of
  # renamed/removed agents AND stops zuvo from clobbering a same-named agent the user
  # wrote (several zuvo agent names are ordinary words once prefixed).
  local KIMI_AGENT_MANIFEST="$KIMI_AGENTS/.zuvo-agents"
  local kimi_agents_installed=0 kimi_agents_skipped=0 kimi_agents_pruned=0

  # `ls "$DIST"/agents/*.md` guard: the prune below deletes every manifest entry ABSENT from the
  # dist, so an empty/missing dist/agents would delete every agent zuvo owns. The manifest write
  # 30 lines down already defends against exactly that case ("no agents in dist -- kept the
  # previous agent manifest"), which means a build exiting 0 with nothing emitted was considered
  # reachable -- the manifest was protected and the FILES were not.
  if [[ -f "$KIMI_AGENT_MANIFEST" ]] && ls "$DIST"/agents/*.md >/dev/null 2>&1; then
    while IFS= read -r _prev; do
      [[ -n "$_prev" ]] || continue
      if [[ ! -f "$DIST/agents/$_prev" && -f "$KIMI_AGENTS/$_prev" ]]; then
        rm -f "$KIMI_AGENTS/$_prev"
        kimi_agents_pruned=$((kimi_agents_pruned + 1))
      fi
    done < "$KIMI_AGENT_MANIFEST"
  fi

  local kimi_manifest_tmp
  # mktemp INSIDE $KIMI_AGENTS, not $TMPDIR: the `mv -f` below is only atomic within one
  # filesystem, and $TMPDIR is commonly a separate one. A cross-device mv degrades to
  # copy+unlink, so an interruption leaves .zuvo-agents -- the file deciding which agents zuvo
  # may prune or overwrite -- torn. This file already gets it right twice (install.sh:440-444
  # and the cursor helper copy), both co-located, both commented for this reason.
  kimi_manifest_tmp=$(mktemp "$KIMI_AGENTS/.zuvo-agents.XXXXXX")
  if ls "$DIST"/agents/*.md >/dev/null 2>&1; then
    local _agent _aname
    for _agent in "$DIST"/agents/*.md; do
      _aname=$(basename "$_agent")
      # Unknown pre-existing file that zuvo never installed → leave it to its owner.
      # With NO manifest yet (first run since this code existed) there is no provenance to
      # read, so the first run adopts by name — same one-time concession the skills path
      # above makes, and every later run is manifest-checked.
      if [[ -f "$KIMI_AGENTS/$_aname" && -f "$KIMI_AGENT_MANIFEST" ]] \
         && ! grep -qxF "$_aname" "$KIMI_AGENT_MANIFEST" 2>/dev/null; then
        warn "skipped agent '$_aname' — exists in $KIMI_AGENTS and is not zuvo-owned"
        kimi_agents_skipped=$((kimi_agents_skipped + 1))
        continue
      fi
      cp "$_agent" "$KIMI_AGENTS/$_aname"
      printf '%s\n' "$_aname" >> "$kimi_manifest_tmp"
      kimi_agents_installed=$((kimi_agents_installed + 1))
    done
  fi
  # Only replace the manifest when this run actually installed something. Writing an EMPTY
  # manifest (a build that produced no agents) would make the next run treat every agent
  # zuvo owns as a stranger's — it would then refuse to update them and never prune them.
  if [[ $kimi_agents_installed -gt 0 ]]; then
    mv -f "$kimi_manifest_tmp" "$KIMI_AGENT_MANIFEST"
  else
    rm -f "$kimi_manifest_tmp"
    warn "no agents in dist — kept the previous agent manifest"
  fi
  if [[ $kimi_agents_pruned -gt 0 || $kimi_agents_skipped -gt 0 ]]; then
    ok "Agents installed ($kimi_agents_installed; $kimi_agents_pruned stale pruned, $kimi_agents_skipped left to their owners)"
  else
    ok "Agents installed ($kimi_agents_installed total) -> $KIMI_AGENTS"
  fi

  # Step 4: shared includes / rules / scripts (referenced by absolute path from skills)
  if [[ -d "$DIST/shared" ]]; then
    rm -rf "$KIMI_HOME/shared"
    mkdir -p "$KIMI_HOME/shared/includes"
    cp -r "$DIST"/shared/* "$KIMI_HOME/shared/"
    ok "Shared includes installed"
  fi
  if [[ -d "$DIST/rules" ]]; then
    rm -rf "$KIMI_HOME/rules"
    mkdir -p "$KIMI_HOME/rules"
    cp -r "$DIST"/rules/* "$KIMI_HOME/rules/"
    ok "Rules installed"
  fi
  if [[ -d "$DIST/scripts" ]]; then
    mkdir -p "$KIMI_HOME/scripts"
    cp "$DIST"/scripts/*.sh "$KIMI_HOME/scripts/" 2>/dev/null || true
    cp "$DIST"/scripts/*.py "$KIMI_HOME/scripts/" 2>/dev/null || true
    chmod +x "$KIMI_HOME"/scripts/*.sh "$KIMI_HOME"/scripts/*.py 2>/dev/null || true
    ok "Scripts installed"
  fi

  # Step 5: hook scripts
  if [[ -d "$DIST/hooks" ]]; then
    mkdir -p "$KIMI_HOME/hooks"
    cp "$DIST"/hooks/* "$KIMI_HOME/hooks/" 2>/dev/null || true
    [[ -d "$DIST/hooks/lib" ]] && { cp -R "$DIST/hooks/lib" "$KIMI_HOME/hooks/" 2>/dev/null || true; chmod +x "$KIMI_HOME"/hooks/lib/*.sh 2>/dev/null || true; }
    chmod +x "$KIMI_HOME"/hooks/*.sh 2>/dev/null || true
    chmod +x "$KIMI_HOME/hooks/session-start" 2>/dev/null || true
    ok "Hook scripts installed"
  fi

  # Step 6: merge hook config into ~/.kimi-code/config.toml.
  #
  # Kimi's hook config is TOML, so the JSON deep-merge used for the other targets does
  # not apply. Instead the block is marker-delimited and rewritten wholesale each run:
  # idempotent, and it never touches hooks the user wrote outside the markers.
  # A corrupt config.toml would break the CLI itself, so the merged file is parsed
  # before it replaces the original and the write is aborted if it does not parse.
  if [[ -f "$DIST/hooks.kimi.toml" ]]; then
    python3 -c "
import os, sys, tempfile

template_path, config_path = sys.argv[1], sys.argv[2]
BEGIN = '# >>> zuvo hooks (managed by install.sh — do not edit inside this block) >>>'
END   = '# <<< zuvo hooks <<<'

with open(template_path) as f:
    template = f.read().strip()

existing = ''
if os.path.exists(config_path):
    with open(config_path) as f:
        existing = f.read()

# Drop any previous zuvo block (including a half-written one missing its END marker).
lines, out, inside = existing.split('\n'), [], False
for line in lines:
    if line.strip() == BEGIN:
        inside = True
        continue
    if inside:
        if line.strip() == END:
            inside = False
        continue
    out.append(line)
body = '\n'.join(out).rstrip()

merged = f'{body}\n\n{BEGIN}\n{template}\n{END}\n' if body else f'{BEGIN}\n{template}\n{END}\n'

try:
    import tomllib
    tomllib.loads(merged)
except ModuleNotFoundError:
    # python < 3.11: no TOML parser. The justification that used to sit here -- 'the block is
    # generated, not hand-edited' -- only covers the TEMPLATE half of `merged`. The other half is
    # the user's EXISTING config, parsed by hand-rolled BEGIN/END line matching, which can be
    # malformed independently of anything zuvo wrote. Writing unvalidated therefore contradicts
    # the guarantee stated 40 lines above, and CLAUDE.md states it absolutely: a corrupt
    # config.toml breaks the Kimi CLI itself. Un-provable is not the same as safe -- abort.
    print('  ! python < 3.11: cannot validate merged config.toml (no tomllib) -- hook merge aborted')
    print('    upgrade python3, or merge the hooks block by hand from dist/kimi/hooks.kimi.toml')
    sys.exit(0)
except Exception as exc:
    print(f'  ! merged config.toml would not parse ({exc}) -- hook merge aborted')
    sys.exit(0)

fd, tmp = tempfile.mkstemp(dir=os.path.dirname(config_path) or '.', suffix='.tmp')
with os.fdopen(fd, 'w') as f:
    f.write(merged)
os.replace(tmp, config_path)
n = sum(1 for l in template.split('\n') if l.strip() == '[[hooks]]')
print(f'  ✓ Hooks merged into config.toml ({n} zuvo hooks in a managed block)')
" "$DIST/hooks.kimi.toml" "$KIMI_HOME/config.toml" || warn "config.toml hook merge failed"
  fi

  ok "Kimi Code updated"
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
  # install_zuvo_home on EVERY branch, not just both|all (B-9, open since v1.3.109).
  # ~/.zuvo/ holds append-runlog, append-retro, adversarial-review, compute-preload,
  # build-review-patch and review-artifact-sync.sh — helpers that EVERY skill calls by absolute
  # path, on every platform. A platform-only invocation used to install a full skill set that
  # then failed at its first mandatory gate with "command not found", and the failure surfaces
  # inside a skill run rather than at install time, which is where the four days of confusion
  # came from. The function is standalone (no DIST/SKILL_COUNT/CACHE_DIR from a sibling
  # installer) and idempotent, so calling it per-branch is a no-op when it already ran.
  claude) install_claude; install_zuvo_home; install_claude_home ;;
  codex)  install_codex; install_zuvo_home ;;
  cursor) install_cursor; install_zuvo_home ;;
  antigravity) install_antigravity; install_zuvo_home ;;
  kimi)   install_kimi; install_zuvo_home ;;
  both|all) install_claude; install_codex; install_cursor; install_antigravity; install_kimi; install_zuvo_home; install_claude_home ;;
  *)      echo "Usage: $0 [claude|codex|cursor|antigravity|kimi|all]"; exit 1 ;;
esac

# Opt-in git PATH-shim (ZUVO_INSTALL_GIT_SHIM / ZUVO_UNINSTALL_GIT_SHIM); no-op otherwise.
install_git_shim

echo ""
echo "======================================"
echo "  DONE"
echo "======================================"
echo ""
echo "  Restart Claude Code / Codex / Cursor / Antigravity / Kimi Code to pick up changes."
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