#!/usr/bin/env bash
# scripts/install.d/hooks.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Pipeline-entry hook helpers every target reuses: the hook tree, the global git dispatchers,
# the CI/pipeline artifacts and the opt-in git PATH shim.

# =======================================
# PIPELINE-ENTRY HOOK INSTALL HELPERS (source-able + reused by every target)
# =======================================

# Copy the FULL hooks tree (incl. lib/) to a target hooks dir. Recursive,
# idempotent (cp overwrites; re-runs never duplicate). This is what makes the
# pipeline-gate lib + new hooks reach a target.
install_hook_tree() {
  local dst="$1" src global_refactor=0
  [ -n "$dst" ] || return 1
  mkdir -p "$dst/lib"
  [[ "$dst" = "$HOME/.claude/hooks" ]] && global_refactor=1
  for src in "$ZUVO_DIR"/hooks/*.sh; do
    # The stable global gate has its own ownership check below. Never write
    # through a foreign symlink before that check has even run.
    if [[ "$global_refactor" = 1 && "${src##*/}" = refactor-safety-gate.sh ]]; then continue; fi
    if [[ -L "$dst/${src##*/}" || ( -e "$dst/${src##*/}" && ! -f "$dst/${src##*/}" ) ]]; then
      echo "  WARN: foreign hook destination $dst/${src##*/} preserved" >&2
      continue
    fi
    cp "$src" "$dst/" 2>/dev/null || true
  done
  cp "$ZUVO_DIR"/hooks/*.json "$dst/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/hooks/run-hook.cmd" ] && cp "$ZUVO_DIR/hooks/run-hook.cmd" "$dst/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/hooks/session-start" ] && cp "$ZUVO_DIR/hooks/session-start" "$dst/" 2>/dev/null || true
  if [ -d "$ZUVO_DIR/hooks/lib" ]; then
    cp "$ZUVO_DIR"/hooks/lib/*.sh "$ZUVO_DIR"/hooks/lib/*.py "$dst/lib/" 2>/dev/null || true
  fi
  # refactor commit-gate self-installer (lives in scripts/, needed in the hooks dir so
  # zuvo:refactor Phase 0 can find it at ~/.claude/hooks/install-refactor-gate.sh)
  [ -f "$ZUVO_DIR/scripts/install-refactor-gate.sh" ] && cp "$ZUVO_DIR/scripts/install-refactor-gate.sh" "$dst/" 2>/dev/null || true
  [ -f "$ZUVO_DIR/scripts/setup-dev-hooks.sh" ] && cp "$ZUVO_DIR/scripts/setup-dev-hooks.sh" "$dst/" 2>/dev/null || true
  # The global entry must follow cache upgrades, while versioned cache entries
  # remain the real gate (dispatching there again would recurse).
  if [[ "$global_refactor" = 1 && -f "$ZUVO_DIR/hooks/refactor-safety-gate.sh" \
        && -f "$ZUVO_DIR/hooks/refactor-gate-dispatch.sh" ]]; then
    if ! sh "$ZUVO_DIR/scripts/install-refactor-gate.sh" --global-dispatch \
        "$dst/refactor-safety-gate.sh" "$ZUVO_DIR/hooks/refactor-safety-gate.sh"; then
      echo '  WARN: global refactor-gate dispatcher skipped; existing hook preserved (see reason above)' >&2
    fi
  fi
  for src in "$dst"/*.sh; do
    if [[ "$global_refactor" = 1 && "${src##*/}" = refactor-safety-gate.sh ]]; then continue; fi
    [[ -L "$src" || ! -f "$src" ]] && continue
    chmod +x "$src" 2>/dev/null || true
  done
  chmod +x "$dst"/lib/*.sh 2>/dev/null || true
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
    [ -d "$hooks_dir/$d" ] && rm -rf "${hooks_dir:?}/$d"
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
