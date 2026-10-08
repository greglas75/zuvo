#!/usr/bin/env bash
# scripts/install.d/kimi.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Kimi Code: build dist/kimi, then install provenance-marked skills, manifest-tracked agents,
# shared, rules, scripts and hooks under $KIMI_CODE_HOME (default ~/.kimi-code).

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
  DIST="$(dist_root)/kimi"

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
  # may prune or overwrite -- torn. The installer already gets it right twice (install_file_atomic
  # in install.d/copy.sh, and the cursor helper copy), both co-located, both commented for this reason.
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
    # Not `&&`-chained — see the codex block for why a short-circuit under-reports.
    _vc_rc=0
    # The runner FIRST (the build puts scripts/lib/ in dist/kimi/scripts/lib/), then the driver that
    # needs it, copied with the other scripts below — see the codex block.
    install_runner_lib "kimi scripts (runner lib)" "$DIST/scripts/lib" "$KIMI_HOME/scripts" || _vc_rc=1
    install_files_atomic "kimi scripts" "$KIMI_HOME/scripts" "$DIST"/scripts/*.sh || _vc_rc=1
    install_files_atomic "kimi scripts" "$KIMI_HOME/scripts" "$DIST"/scripts/*.py || _vc_rc=1
    chmod +x "$KIMI_HOME"/scripts/*.sh "$KIMI_HOME"/scripts/*.py 2>/dev/null || true
    verify_copied "kimi scripts" "$DIST/scripts" "$KIMI_HOME/scripts" \
         benchmark.sh adversarial-review.sh reviewer-model-route.sh blind-audit-codex.sh infra-collect.sh test-coverage-gate.py reviewer-preflight.sh review-artifact-sync.sh install-refactor-gate.sh || _vc_rc=1
    if [ "$_vc_rc" -eq 0 ]; then
      ok "Scripts installed"
    fi
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
    zuvo_py - "$DIST/hooks.kimi.toml" "$KIMI_HOME/config.toml" <<'PYKIMIHOOK' || warn "config.toml hook merge failed"
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
PYKIMIHOOK
  fi

  ok "Kimi Code updated"
}
