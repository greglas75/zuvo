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

  # Steps 3-4: skills and agents, keyed on PROVENANCE. ~/.cursor/skills and ~/.cursor/agents are the
  # user's directories too, so zuvo marks what it puts there — a .zuvo-owned file in each skill dir, a
  # .zuvo-agents manifest of agent file names — and removes only that (the scheme of install.d/antigravity.sh
  # and kimi.sh). Before the first provenance-aware run there is nothing to read, so that run adopts by
  # NAME, once; .zuvo-provenance records that it happened, and every later run leaves an unmarked
  # same-named directory or unlisted agent to its owner.
  #
  # Cursor scans ~/.cursor/skills/, ~/.cursor/agents/, AND ~/.claude/plugins/cache/ without
  # deduplication (known Cursor bug), so when Claude Code's zuvo cache exists zuvo's skills and agents are
  # NOT copied here, and the ones an earlier run put here are removed (Step 8). That cleanup used to
  # `rm -rf` both directories whole whenever one zuvo skill was there or any agent matched *-*.md,
  # taking the user's own skills and agents with them.
  local CU_SKILLS="$HOME/.cursor/skills" CU_AGENTS="$HOME/.cursor/agents" CU_MARKER=".zuvo-owned"
  local CU_MANIFEST="$HOME/.cursor/agents/.zuvo-agents" CU_SENTINEL="$HOME/.cursor/skills/.zuvo-provenance"
  local cu_dedup=0 cu_adopt=1 _d
  [[ -d "$HOME/.claude/plugins/cache/zuvo-marketplace" ]] && cu_dedup=1
  [[ -f "$CU_SENTINEL" ]] && cu_adopt=0
  # _cu_real_dir <dir/> — a directory that is not a symlink. A symlinked skill dir is the user's
  # arrangement (a dotfile manager, a skill moved and linked back) even when zuvo's marker travelled with
  # it, and `rm -rf link/` deletes what the link points at, not the link.
  _cu_real_dir() { [[ -d "$1" && ! -L "${1%/}" ]]; }
  # _cu_manifest_entry <name> — a manifest line that can only name a file directly in $CU_AGENTS.
  _cu_manifest_entry() { [[ -n "$1" && "$1" != */* && "$1" != . && "$1" != .. ]]; }

  for _d in "$CU_SKILLS"/*/; do
    _cu_real_dir "$_d" && [[ -f "$_d$CU_MARKER" ]] && { cu_adopt=0; break; }
  done
  mkdir -p "$CU_SKILLS" "$CU_AGENTS"

  if [[ $cu_dedup -eq 0 ]]; then
    # Step 3: Copy skills (do NOT touch skills-cursor/ -- those are Cursor built-in), stamping ownership.
    # Prune first: a zuvo-owned skill this release no longer ships (renamed or removed) would otherwise
    # stay loaded forever. Only when the build produced skills — an empty dist must not prune everything.
    local cu_skipped=0 cu_failed=0 cu_pruned=0 cu_target
    if compgen -G "$DIST/skills/*/" >/dev/null; then
      for _d in "$CU_SKILLS"/*/; do
        _cu_real_dir "$_d" && [[ -f "$_d$CU_MARKER" && ! -d "$DIST/skills/$(basename "$_d")" ]] || continue
        rm -rf "${_d%/}"
        cu_pruned=$((cu_pruned + 1))
      done
    fi
    for skill_dir in "$DIST"/skills/*/; do
      [[ -d "$skill_dir" ]] || continue
      skill_name=$(basename "$skill_dir")
      cu_target="$CU_SKILLS/$skill_name"
      if [[ -L "$cu_target" ]]; then
        warn "skipped '$skill_name' — $cu_target is a symlink (the user's; zuvo copies only into its own directories)"
        cu_skipped=$((cu_skipped + 1))
        continue
      fi
      if [[ -d "$cu_target" && ! -f "$cu_target/$CU_MARKER" && $cu_adopt -eq 0 ]]; then
        warn "skipped '$skill_name' — a directory of that name in $CU_SKILLS carries no zuvo marker (not ours)"
        cu_skipped=$((cu_skipped + 1))
        continue
      fi
      mkdir -p "$cu_target"
      # Marked even when the copy fails: the directory is zuvo's either way, and the marker is what lets
      # the next run repair or remove it. The failure itself is said, not swallowed.
      if ! cp -r "$skill_dir"* "$cu_target/" 2>/dev/null; then
        warn "skill '$skill_name' did not copy completely into $cu_target"
        cu_failed=$((cu_failed + 1))
      fi
      if ! { printf 'zuvo-owned skill directory. install.sh deletes ONLY directories carrying this file.\n' > "$cu_target/$CU_MARKER"; } 2>/dev/null; then
        warn "skill '$skill_name': the ownership marker could not be written — the next run will not repair or remove it"
        cu_failed=$((cu_failed + 1))
      fi
    done
    SKILL_COUNT=$(ls -d "$DIST/skills"/*/ 2>/dev/null | wc -l | tr -d ' ')
    if [[ $cu_failed -gt 0 ]]; then
      warn "Skills installed with $cu_failed incomplete ($SKILL_COUNT; $cu_pruned stale pruned, $cu_skipped left to their owners)"
    elif [[ $cu_skipped -gt 0 || $cu_pruned -gt 0 ]]; then
      ok "Skills installed ($SKILL_COUNT; $cu_pruned stale pruned, $cu_skipped left to their owners)"
    else
      ok "Skills installed ($SKILL_COUNT total)"
    fi

    # Step 4: Copy agents (flat .md files with skill-prefixed names), each listed in the manifest.
    if ls "$DIST"/agents/*.md &>/dev/null; then
      local cu_manifest_tmp _agent _aname cu_agents=0 _prev
      # Prune agents an earlier release installed and this one no longer ships: the manifest is rewritten
      # below from the current dist, so without this they would drop out of it and stay forever.
      if [[ -f "$CU_MANIFEST" ]]; then
        # `|| [[ -n … ]]`: a manifest edited by hand may lack its final newline; its last name still counts.
        while IFS= read -r _prev || [[ -n "$_prev" ]]; do
          _cu_manifest_entry "$_prev" || continue
          [[ ! -f "$DIST/agents/$_prev" && -f "$CU_AGENTS/$_prev" ]] && rm -f "$CU_AGENTS/$_prev"
        done < "$CU_MANIFEST"
      fi
      # In $CU_AGENTS, not $TMPDIR: the mv below is atomic only within one filesystem (see kimi.sh).
      cu_manifest_tmp=$(mktemp "$CU_AGENTS/.zuvo-agents.XXXXXX")
      for _agent in "$DIST"/agents/*.md; do
        _aname=$(basename "$_agent")
        if [[ -f "$CU_AGENTS/$_aname" && $cu_adopt -eq 0 ]] && ! grep -qxF "$_aname" "$CU_MANIFEST" 2>/dev/null; then
          warn "skipped agent '$_aname' — exists in $CU_AGENTS and is not zuvo-owned"
          continue
        fi
        if [[ -L "$CU_AGENTS/$_aname" ]]; then
          warn "skipped agent '$_aname' — $CU_AGENTS/$_aname is a symlink (the user's)"
          continue
        fi
        # Listed only when it copied: a manifest naming a file zuvo did not write would let a later run
        # delete whatever the user puts under that name.
        if ! cp "$_agent" "$CU_AGENTS/$_aname" 2>/dev/null; then
          warn "agent '$_aname' did not copy into $CU_AGENTS"
          continue
        fi
        printf '%s\n' "$_aname" >> "$cu_manifest_tmp"
        cu_agents=$((cu_agents + 1))
      done
      # An empty manifest would make the next run treat every agent zuvo owns as a stranger's.
      if [[ $cu_agents -gt 0 ]]; then mv -f "$cu_manifest_tmp" "$CU_MANIFEST"; else rm -f "$cu_manifest_tmp"; fi
      AGENT_COUNT=$cu_agents
      ok "Agents installed ($AGENT_COUNT total)"
    fi
  else
    ok "Skills and agents not copied — Cursor reads zuvo's from Claude Code's cache"
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
    copy_hooks_lib_except_collisions "$ZUVO_DIR/hooks/lib" "$ZUVO_DIR/scripts/lib" "$HOME/.cursor/scripts/lib" || _vc_rc=1
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

  # Step 8: with Claude Code's cache present, remove the skills and agents an earlier run put in
  # ~/.cursor (see Steps 3-4): the marked skill dirs and the manifest's agents — and, on the one run
  # that adopts by name, unmarked dirs and agents carrying the names this release ships.
  if [[ $cu_dedup -eq 1 ]]; then
    local cu_removed=0 _prev _base
    for _d in "$CU_SKILLS"/*/; do
      _cu_real_dir "$_d" || continue
      _base=$(basename "$_d")
      if [[ -f "$_d$CU_MARKER" ]] || { [[ $cu_adopt -eq 1 ]] && [[ -d "$DIST/skills/$_base" ]]; }; then
        rm -rf "${_d%/}"
        cu_removed=$((cu_removed + 1))
      fi
    done
    if [[ -f "$CU_MANIFEST" ]]; then
      while IFS= read -r _prev || [[ -n "$_prev" ]]; do
        _cu_manifest_entry "$_prev" && [[ -f "$CU_AGENTS/$_prev" ]] || continue
        rm -f "$CU_AGENTS/$_prev"
        cu_removed=$((cu_removed + 1))
      done < "$CU_MANIFEST"
      rm -f "$CU_MANIFEST"
    fi
    if [[ $cu_adopt -eq 1 ]]; then
      for _prev in "$DIST"/agents/*.md; do
        [[ -f "$_prev" && -f "$CU_AGENTS/${_prev##*/}" ]] || continue
        rm -f "$CU_AGENTS/${_prev##*/}"
        cu_removed=$((cu_removed + 1))
      done
    fi
    if [[ $cu_removed -gt 0 ]]; then
      ok "Duplicate skills/agents removed (Cursor uses Claude Code cache)"
    fi
  fi
  # Adoption by name is spent: from here on only provenance decides.
  printf 'zuvo has run here with provenance markers; it removes only marked skills and listed agents.\n' > "$CU_SENTINEL"

  ok "Cursor updated"
}
