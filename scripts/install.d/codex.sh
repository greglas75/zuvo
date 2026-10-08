#!/usr/bin/env bash
# scripts/install.d/codex.sh — part of scripts/install.sh, which sources it; not runnable alone.
# Codex: build dist/codex, then install skills, agents, shared, rules, scripts and hooks into
# ~/.codex and the Codex plugin cache.

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
  DIST="$(dist_root)/codex"

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

  # Step 3: Copy skills, then prune the zuvo skills this release no longer ships. ~/.codex/skills is
  # shared with the user's own skills, so only directories titled `# zuvo:<name>` go (copy.sh).
  cp -r "$DIST"/skills/* "$HOME/.codex/skills/"
  prune_retired_skills "$HOME/.codex/skills" "$DIST/skills" "$HOME/.codex/skills"
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

  # Step 6.5: zuvo's marker blocks in ~/.codex/AGENTS.md
  #
  # Codex reads AGENTS.md, not CLAUDE.md, and the two rules that keep this workstation usable live
  # there: the poll ceiling and "when the farm is busy, WAIT". They were hand-written into the
  # user's file and nothing in this repo knew about them — so they were one machine rebuild away
  # from disappearing, and a drafting mistake in one could not be caught by any test. One such
  # mistake ("re-queue once, or report BLOCKED_FARM_BUSY and stop") cost a finished branch its
  # push, PR and merge on 2026-09-03. Only the marked regions are rewritten; the user's own text
  # is copied through untouched.
  if [[ -d "$ZUVO_DIR/shared/codex/agents-md" ]]; then
    bash "$ZUVO_DIR/scripts/install-agents-md-blocks.sh" \
      "$ZUVO_DIR/shared/codex/agents-md" "$HOME/.codex/AGENTS.md" || true
  fi

  # Step 7: Copy scripts (benchmark.sh, adversarial-review.sh, reviewer-model-route.sh, blind-audit-codex.sh, infra-collect.sh)
  if [[ -d "$ZUVO_DIR/scripts" ]]; then
    mkdir -p "$HOME/.codex/scripts"
    # Each copy below is renamed into place (install_files_atomic: a session may be running the installed
    # driver), each group is verified before "Scripts installed" is claimed, and _vc_rc accumulates the verdict.
    _vc_rc=0
    # The driver copied below runs its codex/claude lanes through the shared runner, found beside it
    # in scripts/lib/. Installed FIRST: a review starting mid-install must never run the new driver
    # with no sibling runner yet (it would fall back to ~/.zuvo, possibly an older library).
    install_runner_lib "codex scripts (runner lib)" "$ZUVO_DIR/scripts/lib" "$HOME/.codex/scripts" || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/benchmark.sh || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/adversarial-review.sh || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/reviewer-model-route.sh || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/blind-audit-codex.sh || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/infra-collect.sh || _vc_rc=1
    # write-tests executable gate + Phase-0 reviewer canary + artifact pair sync (2026-07-31)
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/test-coverage-gate.py || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/reviewer-preflight.sh || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/review-artifact-sync.sh || _vc_rc=1
    # mutation-test resolves these helpers from the active Codex root.
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/stryker-scoped-config.sh || _vc_rc=1
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/mutation-survivor-reprobe.sh || _vc_rc=1
    # review-artifact-sync.sh sources path-contain.sh from its OWN directory, so the shared
    # containment rule has to travel with it (B-PATH-CONTAIN-SHARED-FN). Without this the
    # script refuses to sync rather than falling back to a private copy of the rule.
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/hooks/lib/path-contain.sh || _vc_rc=1
    chmod +x "$HOME/.codex"/scripts/*.py 2>/dev/null || true
    # install-refactor-gate.sh is invoked by zuvo:refactor PHASE 0 to wire the repo git hook.
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/scripts/install-refactor-gate.sh || _vc_rc=1
    # …and the gate itself. Kept next to the installer (not only in the plugin cache, which is
    # created conditionally) so PHASE 0 resolves both halves from one predictable location.
    install_files_atomic "codex scripts" "$HOME/.codex/scripts" "$ZUVO_DIR"/hooks/refactor-safety-gate.sh || _vc_rc=1
    mkdir -p "$HOME/.codex/scripts/lib"
    guard_lib_collisions "codex scripts (lib)" "$ZUVO_DIR/hooks/lib" "$ZUVO_DIR/scripts/lib" "$HOME/.codex/scripts/lib" || _vc_rc=1
    copy_hooks_lib_except_collisions "$ZUVO_DIR/hooks/lib" "$ZUVO_DIR/scripts/lib" "$HOME/.codex/scripts/lib" || _vc_rc=1
    chmod +x "$HOME/.codex"/scripts/*.sh 2>/dev/null || true
    # verify_copied stays the hard verdict on the copies above; check before making the claim.
    # NOT `&&`-chained: verify_copied returns 1 on a miss, so a short-circuit would skip the
    # remaining groups and their misses would never reach INSTALL_VERIFY_DETAIL. The run still
    # exited 1 either way — but the printed list named only the first group's files, so someone
    # fixing "the one missing file" could still be left with a broken install. Run all three,
    # accumulate (onto the runner-lib verdict above), then decide.
    verify_copied "codex scripts" "$ZUVO_DIR/scripts" "$HOME/.codex/scripts" \
      benchmark.sh adversarial-review.sh reviewer-model-route.sh blind-audit-codex.sh infra-collect.sh test-coverage-gate.py reviewer-preflight.sh review-artifact-sync.sh install-refactor-gate.sh stryker-scoped-config.sh mutation-survivor-reprobe.sh || _vc_rc=1
    verify_copied "codex scripts (gate)" "$ZUVO_DIR/hooks" "$HOME/.codex/scripts" refactor-safety-gate.sh || _vc_rc=1
    verify_copied "codex scripts (lib)" "$ZUVO_DIR/hooks/lib" "$HOME/.codex/scripts" path-contain.sh || _vc_rc=1
    if [ "$_vc_rc" -eq 0 ]; then
      ok "Scripts installed"
    fi

    # ---- Codex event hooks: ~/.codex/hooks.json, NOT the plugin cache ------------------
    # zuvo is not a `[plugins.*]` entry in Codex (see CLAUDE.md), so everything written to
    # ~/.codex/plugins/cache/... is inert — Codex never reads it. The path it DOES read is
    # ~/.codex/hooks.json, which config.toml proves by carrying a trusted_hash for
    # `<...>/hooks.json:pre_tool_use`. Writing the manifest to the cache and reporting
    # "Hooks installed" was true about the copy and false about the effect.
    mkdir -p "$HOME/.codex/hooks"
    cp "$ZUVO_DIR"/hooks/codex-poll-guard.sh "$HOME/.codex/hooks/" 2>/dev/null || true
    chmod +x "$HOME/.codex"/hooks/*.sh 2>/dev/null || true
    # Codex hooks are OFF BY DEFAULT. Without `[features].hooks = true` the config is read,
    # parsed, trusted and then silently ignored — which cost three app restarts and most of a
    # night to discover, because nothing anywhere says so. (`codex_hooks` is the deprecated
    # spelling; Codex itself prints the rename.) config.toml is the user's, so: back it up, and
    # never leave one that does not parse.
    zuvo_py - "$HOME/.codex/config.toml" <<'PYFLAG' || true
import os, re, shutil, sys
p = sys.argv[1]
try:
    s = open(p).read()
except Exception:
    s = ""
# BOTH spellings. This build fires hooks on `codex_hooks` (printing a deprecation notice) and
# does NOT fire on `hooks`, which is the name the notice tells you to use — so following the
# advice silently turns the feature off. Newer builds are the other way round. Writing both is
# the only version-proof choice.
have = lambda k: re.search(r"^\s*%s\s*=\s*true" % k, s, re.M)
missing = [k for k in ("codex_hooks", "hooks") if not have(k)]
if not missing:
    print("hooks already enabled"); raise SystemExit
add = "".join("%s = true\n" % k for k in missing)
if "[features]" in s:
    s2 = re.sub(r"(\[features\]\n)", lambda m: m.group(1) + add, s, count=1)
else:
    s2 = s.rstrip() + "\n\n[features]\n" + add
tmp = p + ".zuvo.tmp"
open(tmp, "w").write(s2)
try:
    import tomllib; tomllib.load(open(tmp, "rb"))
except Exception as e:
    os.remove(tmp); print("REFUSED (would not parse): %s" % e); raise SystemExit
if s:
    shutil.copyfile(p, p + ".zuvo-bak")
os.replace(tmp, p)
print("enabled [features]: %s" % ", ".join(missing))
PYFLAG
    if zuvo_py - "$HOME/.codex/hooks.json" "$HOME/.codex/hooks/codex-poll-guard.sh" <<'PYHOOK'
import json, os, shlex, stat, sys, tempfile
try:
    import fcntl
except ImportError:  # Windows Python: no advisory lock; one installer at a time
    fcntl = None
path, script = sys.argv[1], sys.argv[2]
# The REAL file: a symlinked hooks.json (a dotfile manager) is written through, never replaced by a copy.
real = os.path.realpath(path)
# Concurrent zuvo installers (parallel agents) would each read, edit and replace the file, and the last
# one would drop the others' changes: one advisory lock serializes them. Where it cannot be taken (no
# fcntl, a root-owned lock file left by a sudo install) that is said, and the byte check before the
# replace below is what still refuses to overwrite a file that changed after it was read.
held = None
if fcntl is not None:
    lock_path = os.path.join(os.path.expanduser("~"), ".zuvo", "locks", "codex-hooks.lock")
    try:
        os.makedirs(os.path.dirname(lock_path), exist_ok=True)
        held = open(lock_path, "a")
        fcntl.flock(held, fcntl.LOCK_EX)
    except OSError as e:
        if held is not None:
            held.close()
        held = None
        print("  ! could not take %s (%s) — merging without it; the file is re-checked before it is replaced"
              % (lock_path, e))
# A hooks.json that holds something this cannot read as that shape is the USER's, and is left exactly as
# it is: this used to fall back to `{}` on any parse error and write that plus zuvo's hook over the file —
# every hook the user had registered was gone, and the install reported the guard as registered. A
# missing or EMPTY file holds nothing to lose and starts from {}.
try:
    with open(real, "rb") as fh:
        before = fh.read()
    text = before.decode("utf-8-sig")
    cfg = json.loads(text) if text.strip() else {}
except FileNotFoundError:
    before, cfg = None, {}
except (OSError, ValueError) as e:
    print("  ! %s does not parse (%s) — left as it is" % (path, e)); raise SystemExit(1)
if not isinstance(cfg, dict) or not isinstance(cfg.setdefault("hooks", {}), dict) \
        or not isinstance(cfg["hooks"].setdefault("PreToolUse", []), list) \
        or not all(isinstance(g, dict) and isinstance(g.get("hooks", []), list) for g in cfg["hooks"]["PreToolUse"]):
    print("  ! %s does not parse as {\"hooks\": {\"PreToolUse\": [{\"hooks\": [...]}]}} — left as it is" % path)
    raise SystemExit(1)
hooks = cfg["hooks"]
# `PreToolUse` — PascalCase, confirmed by a real payload once hooks were switched on:
# {"hook_event_name": "PreToolUse", "tool_name": "Bash", "tool_input": {"command": "..."}, …}.
# The `:pre_tool_use:` in config.toml's hooks.state trust key is a NORMALISED form, and reading it
# as the file's spelling is what produced a registration that could never fire.
entry = {
    # `Bash` is the real tool name in the payload — verified, not guessed:
    # {"hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"…"}}.
    # The names guessed from session logs (exec/wait/write_stdin) match nothing; the first two
    # are kept only so a future rename does not silently un-hook everything.
    "matcher": "Bash|exec|shell|local_shell",
    "hooks": [{"type": "command", "command": "bash %s" % shlex.quote(script), "timeout": 10}],
}
def ours(h):
    """zuvo's own guard: a command (an entry's "command", or a bare string) that RUNS a codex-poll-guard.sh,
    directly or as `bash|sh <script>` — at any path, so an earlier install's entry is replaced too. A
    command that merely mentions the name (`echo codex-poll-guard.sh`) is the user's."""
    command = h.get("command") if isinstance(h, dict) else h
    if not isinstance(command, str):
        return False
    try:
        words = shlex.split(command)
    except ValueError:
        return False
    if words and os.path.basename(words[0]) in ("bash", "sh"):
        words = words[1:]
    return bool(words) and os.path.basename(words[0]) == "codex-poll-guard.sh"
for event in ("PreToolUse",):
    group = hooks.setdefault(event, [])
    # Remove zuvo's OWN earlier entries — not every group that mentions the guard: a group the user
    # shares with it keeps the user's hooks, and is dropped only when nothing else is left in it.
    kept = []
    for g in group:
        if not g.get("hooks") and ours(g):
            continue  # a flat {"matcher": …, "command": …} entry of the guard: replaced, not duplicated
        rest = [h for h in g.get("hooks", []) if not ours(h)]
        if rest or not g.get("hooks"):
            kept.append(dict(g, hooks=rest) if len(rest) != len(g.get("hooks", [])) else g)
    group[:] = kept
    group.append(dict(entry))
# A unique temp beside the REAL file (a fixed `.tmp` name is shared by concurrent installers), fsync'd,
# the file's own mode kept, then one atomic replace: a half-written hooks.json would break the CLI itself.
# The directory is made first — a dotfile link may point into a directory that does not exist yet.
try:
    mode = stat.S_IMODE(os.stat(real).st_mode)
except OSError:
    mode = 0o644
tmp = None
try:
    os.makedirs(os.path.dirname(real) or ".", exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".hooks.", suffix=".tmp", dir=os.path.dirname(real) or ".")
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(cfg, fh, indent=2)
        fh.flush()
        os.fsync(fh.fileno())
    os.chmod(tmp, mode)
    # Something else wrote the file after it was read (Codex itself, or an installer that could not
    # take the lock): replacing it would drop that write, so it is left as it is.
    try:
        with open(real, "rb") as fh:
            now = fh.read()
    except FileNotFoundError:
        now = None
    if now != before:
        print("  ! %s changed during the merge — left as it is; rerun the install" % path); raise SystemExit(1)
    os.replace(tmp, real)
except OSError as e:
    print("  ! could not write %s (%s) — left as it is" % (path, e)); raise SystemExit(1)
finally:
    if tmp is not None and os.path.exists(tmp):
        os.unlink(tmp)
print("ok")
PYHOOK
    then
      ok "poll guard registered in ~/.codex/hooks.json (PreToolUse) and [features].hooks enabled"
    else

      warn "could not register the poll guard in ~/.codex/hooks.json"
    fi
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
      prune_absent "Codex plugin-cache skills" "$DIST/skills" "$CODEX_PLUGIN_CACHE/skills" d
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
