#!/usr/bin/env bash
# scripts/install.d/antigravity.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Antigravity: build dist/antigravity, then install provenance-marked skills, shared, rules,
# scripts and hooks under ~/.gemini.

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
  DIST="$(dist_root)/antigravity"

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
  # TOMLs (see "never the user's own Codex agents" in install.d/codex.sh).
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
  # HIDDEN DEPENDENCY: this also means ~/.gemini/antigravity/scripts/../skills never exists, so
  # bap_find_protocol (scripts/lib/blind-audit-panel.sh) can never use its repo-relative candidate for
  # this driver — it falls straight to $HOME/.zuvo/blind-coverage-audit.md, so --mode blind-audit here
  # depends on install_zuvo_home having run in the SAME HOME (Task 7 fix round, item 4).
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
    # Not `&&`-chained — see the codex block for why a short-circuit under-reports.
    _vc_rc=0
    # The runner FIRST (the build puts scripts/lib/ in dist/antigravity/scripts/lib/), then the driver
    # that needs it, copied with the other scripts below — see the codex block.
    install_runner_lib "antigravity scripts (runner lib)" "$DIST/scripts/lib" "$HOME/.gemini/antigravity/scripts" || _vc_rc=1
    cp "$DIST"/scripts/*.sh "$HOME/.gemini/antigravity/scripts/" 2>/dev/null || true
    cp "$DIST"/scripts/*.py "$HOME/.gemini/antigravity/scripts/" 2>/dev/null || true
    chmod +x "$HOME/.gemini/antigravity"/scripts/*.sh "$HOME/.gemini/antigravity"/scripts/*.py 2>/dev/null || true
    verify_copied "antigravity scripts" "$DIST/scripts" "$HOME/.gemini/antigravity/scripts" \
         benchmark.sh adversarial-review.sh reviewer-model-route.sh blind-audit-codex.sh infra-collect.sh test-coverage-gate.py reviewer-preflight.sh review-artifact-sync.sh install-refactor-gate.sh || _vc_rc=1
    if [ "$_vc_rc" -eq 0 ]; then
      ok "Scripts installed"
    fi
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
" "$DIST/hooks.json" "$gemini_settings" 2>/dev/null || warn "settings.json merge failed"
  fi

  ok "Antigravity updated"
}
