#!/usr/bin/env bash
# scripts/install.d/cursor.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Cursor: build dist/cursor, then install into ~/.cursor.

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
  DIST="$(dist_root)/cursor"

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
    # Verdict accumulator for this block (see the codex block).
    _vc_rc=0
    # The runner FIRST, then the driver that needs it (see the codex block).
    install_runner_lib "cursor scripts (runner lib)" "$ZUVO_DIR/scripts/lib" "$HOME/.cursor/scripts" || _vc_rc=1
    cp "$ZUVO_DIR"/scripts/benchmark.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/adversarial-review.sh "$HOME/.cursor/scripts/adversarial-review.sh".zuvo-tmp.$$ 2>/dev/null && mv -f "$HOME/.cursor/scripts/adversarial-review.sh".zuvo-tmp.$$ "$HOME/.cursor/scripts/adversarial-review.sh" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-model-route.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/blind-audit-codex.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/infra-collect.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    # write-tests executable gate + Phase-0 reviewer canary + artifact pair sync (2026-07-31)
    cp "$ZUVO_DIR"/scripts/test-coverage-gate.py "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/reviewer-preflight.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    cp "$ZUVO_DIR"/scripts/review-artifact-sync.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    # review-artifact-sync.sh sources path-contain.sh from its OWN directory, so the shared
    # containment rule has to travel with it (B-PATH-CONTAIN-SHARED-FN). Without this the
    # script refuses to sync rather than falling back to a private copy of the rule.
    cp "$ZUVO_DIR"/hooks/lib/path-contain.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.cursor"/scripts/*.py 2>/dev/null || true
    # install-refactor-gate.sh is invoked by zuvo:refactor PHASE 0 to wire the repo git hook.
    cp "$ZUVO_DIR"/scripts/install-refactor-gate.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    # …and the gate itself. Kept next to the installer (not only in the plugin cache, which is
    # created conditionally) so PHASE 0 resolves both halves from one predictable location.
    cp "$ZUVO_DIR"/hooks/refactor-safety-gate.sh "$HOME/.cursor/scripts/" 2>/dev/null || true
    mkdir -p "$HOME/.cursor/scripts/lib"
    guard_lib_collisions "cursor scripts (lib)" "$ZUVO_DIR/hooks/lib" "$ZUVO_DIR/scripts/lib" "$HOME/.cursor/scripts/lib" || _vc_rc=1
    cp "$ZUVO_DIR"/hooks/lib/*.sh "$ZUVO_DIR"/hooks/lib/*.py "$HOME/.cursor/scripts/lib/"
    chmod +x "$HOME/.cursor"/scripts/*.sh 2>/dev/null || true
    # The copies above all end in `|| true`; verify the claim before making it.
    # Not `&&`-chained — see the matching block in install.d/codex.sh for why a short-circuit under-reports.
    verify_copied "cursor scripts" "$ZUVO_DIR/scripts" "$HOME/.cursor/scripts" \
      benchmark.sh adversarial-review.sh reviewer-model-route.sh blind-audit-codex.sh infra-collect.sh test-coverage-gate.py reviewer-preflight.sh review-artifact-sync.sh install-refactor-gate.sh || _vc_rc=1
    verify_copied "cursor scripts (gate)" "$ZUVO_DIR/hooks" "$HOME/.cursor/scripts" refactor-safety-gate.sh || _vc_rc=1
    verify_copied "cursor scripts (lib)" "$ZUVO_DIR/hooks/lib" "$HOME/.cursor/scripts" path-contain.sh || _vc_rc=1
    if [ "$_vc_rc" -eq 0 ]; then
      ok "Scripts installed"
    fi
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
