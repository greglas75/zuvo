#!/usr/bin/env bash
# scripts/install.d/claude-home.sh — part of scripts/install.sh, which sources it; not runnable alone.
# ~/.claude: the claude-home scripts, the global git dispatchers and core.hooksPath, and the
# Claude Code hooks registered in ~/.claude/settings.json.

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

  local hooks_dir="$HOME/.claude/hooks"
  # Order matters. _claude_home_git_hooks installs the hook tree (the gates, farm-no-local-tests.sh,
  # lib/) BEFORE it wires core.hooksPath, and _claude_home_farm_guard registers a
  # farm-no-local-tests.sh only if that tree already put it in place — so the git step goes first.
  _claude_home_git_hooks "$hooks_dir"
  _claude_home_stop_hook "$hooks_dir"
  _claude_home_skill_usage_logger "$hooks_dir"
  _claude_home_farm_guard "$hooks_dir"
  _claude_home_enable_guard "$hooks_dir"

  # ── Pipeline-entry hooks: full tree (incl. lib/) into ~/.claude/hooks/ (the
  # core.hooksPath target) + CI script + git shim + CI workflow template into
  # ~/.claude/scripts and ~/.claude/ci. The plugin hooks.json (in the cache)
  # already registers the gates + the SINGLE Stop site; install does NOT register
  # the Stop nudge in settings.json (one site, no double-fire).
  install_hook_tree "$hooks_dir"
  install_pipeline_artifacts "$HOME/.claude"
  ok "pipeline-entry hooks + lib + CI artifacts installed (~/.claude/hooks, ~/.claude/scripts, ~/.claude/ci)"
}

# _claude_home_git_hooks <hooks_dir> — the global git dispatchers + the gate tree, then core.hooksPath.
# ── Global git dispatchers: tracked hooks/git-dispatch/* → ~/.claude/hooks (2026-07-02)
# These REPLACE the codesift pass-through dispatchers: run the repo-local hook first
# (no exec), then ALWAYS chain the zuvo gates — so freestyle-agent pushes are gated in
# EVERY repo. SYMLINK TRAP: pre-push/commit-msg/prepare-commit-msg here are symlinks to
# a shared hook-chain.sh; rm -f FIRST so cp lands as a regular file and never writes
# through the link (that would corrupt commit-msg/prepare-commit-msg). Never touches any
# repo's .git/hooks (C2). Uninstall: git config --global --unset core.hooksPath.
_claude_home_git_hooks() {
  local hooks_dir="$1"
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
}

# _claude_home_stop_hook <hooks_dir> — zuvo-stop-retro-sweep.sh + its Stop registration.
# ── Claude Code Stop-hook: zuvo-stop-retro-sweep (added 2026-05-29)
# Copies the hook script into ~/.claude/hooks/ and idempotently merges the
# Stop matcher into ~/.claude/settings.json. Closes the 2026-05-29 retro
# gap (819 runs.log / 32 retros.log) where agents print "done" without
# executing the retro bash — sweep emits ABANDONED stubs at session end so
# telemetry survives.
_claude_home_stop_hook() {
  local hooks_dir="$1"
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
}

# _claude_home_skill_usage_logger <hooks_dir> — skill-usage-logger.sh + its PostToolUse(Skill) registration.
# ── Claude Code PostToolUse hook: skill-usage-logger (vendored 2026-05-29)
# Was previously untracked at ~/.claude/hooks/ and hand-built its JSONL via
# shell string-interpolation of raw $ARGS — 73% of records were unparseable.
# Vendoring + the jq -c rewrite makes it survive reinstall and emit valid
# escaped JSON. Registers PostToolUse matcher=Skill idempotently.
_claude_home_skill_usage_logger() {
  local hooks_dir="$1"
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
}

# _claude_home_farm_guard <hooks_dir> — the PreToolUse(Bash) registration of farm-no-local-tests.sh.
# ── Claude Code PreToolUse hook: farm-no-local-tests (vendored 2026-09-06)
# Kept every test suite off this workstation, and lived ONLY at ~/.claude/hooks/ with no
# source here — one machine rebuild from vanishing, and unreviewable while it existed. Its
# own defect proved the cost: it segmented commands without joining backslash-newlines, so
# the continuation line of a multi-line `git add a.md \\ <newline> tests/hooks/x.sh` became a
# segment whose first word IS a test path, and it blocked a `git add`. A guard that cries
# wolf on staging is a guard people learn to route around. The file copy rides along on
# install_hook_tree above; only the registration is here. PreToolUse matcher=Bash.
_claude_home_farm_guard() {
  local hooks_dir="$1"
  local fnlt_dst="$hooks_dir/farm-no-local-tests.sh"
  if [[ -f "$ZUVO_DIR/hooks/farm-no-local-tests.sh" ]]; then
    if [[ ! -f "$fnlt_dst" ]]; then
      warn "farm-no-local-tests.sh was not copied to ~/.claude/hooks — registration skipped"
    elif ! chmod +x "$fnlt_dst"; then
      warn "farm-no-local-tests.sh is not executable — registration skipped"
    else
    local claude_settings="$HOME/.claude/settings.json"
    if [[ -f "$claude_settings" ]]; then
      python3 - "$claude_settings" "$fnlt_dst" <<'PYEOF' || warn "farm-no-local-tests merge into ~/.claude/settings.json failed (manual edit may be needed)"
# merge-claude-farm-hook-settings-v1
import json, sys, os, shlex, stat, tempfile
settings_path, hook_cmd = sys.argv[1], sys.argv[2]
real_path = os.path.realpath(settings_path)
try:
    with open(real_path, 'rb') as f:
        original = f.read()
    original_mode = stat.S_IMODE(os.stat(real_path).st_mode)
    s = json.loads(original)
    if not isinstance(s, dict):
        raise ValueError('root must be an object')
    hooks = s.get('hooks')
    if hooks is None:
        hooks = s['hooks'] = {}
    if not isinstance(hooks, dict):
        raise ValueError('hooks must be an object')
    ptu = hooks.get('PreToolUse')
    if ptu is None:
        ptu = hooks['PreToolUse'] = []
    if not isinstance(ptu, list) or not all(isinstance(group, dict) for group in ptu):
        raise ValueError('PreToolUse must be an array of objects')
except Exception as e:
    print(f'  ! ~/.claude/settings.json is malformed ({e}) — skipping farm-no-local-tests merge')
    sys.exit(1)
hook_cmd_norm = hook_cmd.replace(os.path.expanduser('~'), '$HOME')
def same_hook(command):
    if not isinstance(command, str):
        return False
    expanded = command.replace('$HOME', os.path.expanduser('~'))
    try:
        tokens = shlex.split(expanded)
    except ValueError:
        return False
    if len(tokens) == 1:
        candidate = tokens[0]
    elif len(tokens) == 2 and os.path.basename(tokens[0]) in ('bash', 'sh'):
        candidate = tokens[1]
    else:
        return False
    return os.path.normpath(os.path.expanduser(candidate)) == os.path.normpath(hook_cmd)
already = False
for group in ptu:
    entries = group.get('hooks', [])
    if not isinstance(entries, list) or not all(isinstance(h, dict) for h in entries):
        print('  ! ~/.claude/settings.json is malformed (hook entries must be objects) — skipping farm-no-local-tests merge')
        sys.exit(1)
    if group.get('matcher') == 'Bash' and any(
        h.get('type') in (None, 'command') and same_hook(h.get('command')) for h in entries
    ):
        already = True
        break
if already:
    print('  ✓ farm-no-local-tests already registered in ~/.claude/settings.json (no change)')
    sys.exit(0)
ptu.append({'matcher': 'Bash', 'hooks': [{'type': 'command', 'command': hook_cmd_norm, 'timeout': 10}]})
fd, temporary = tempfile.mkstemp(prefix='.settings.', suffix='.tmp', dir=os.path.dirname(real_path))
try:
    with os.fdopen(fd, 'w') as f:
        json.dump(s, f, indent=2)
        f.write('\n')
        f.flush()
        os.fsync(f.fileno())
    os.chmod(temporary, original_mode)
    with open(real_path, 'rb') as f:
        if f.read() != original:
            raise RuntimeError('settings changed during merge; retry the installation')
    os.replace(temporary, real_path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
print('  ✓ farm-no-local-tests registered in ~/.claude/settings.json (PreToolUse matcher=Bash)')
PYEOF
    else
      warn "~/.claude/settings.json not found — farm-no-local-tests not registered"
    fi
    fi
  else
    warn "hooks/farm-no-local-tests.sh not found in repo — farm guard not installed"
  fi
}

# _claude_home_enable_guard <hooks_dir> — zuvo-plugin-enable-guard.sh, its assertion stamp + SessionStart registration.
# ── Claude Code SessionStart hook: zuvo-plugin-enable-guard (added 2026-08-12)
# A release can leave the plugin DISABLED even after `claude plugin enable` reports
# success: the CLI writes ~/.claude/settings.json, and a Claude Code that was running
# through the release owns that file and can persist its own older view afterwards.
# Measured 2026-08-12 — release said "✓ Plugin enabled", next start had it disabled in
# both scopes and all 57 skills invisible. Must be GLOBAL: a plugin-scoped hook does not
# run while its own plugin is off, which is the state it would need to fix.
_claude_home_enable_guard() {
  local hooks_dir="$1"
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
}
