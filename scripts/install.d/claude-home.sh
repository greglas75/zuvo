#!/usr/bin/env bash
# scripts/install.d/claude-home.sh — part of scripts/install.sh, which sources it; not runnable alone.
# ~/.claude: the global git dispatchers and core.hooksPath, the pipeline-entry hooks and scripts, the
# Claude Code hooks registered in ~/.claude/settings.json — and the cleanup of the retired review queue.

# =======================================
# CLAUDE HOME (~/.claude)
# Until 2026-10-05 this step also copied scripts/claude-home/scripts/post-commit-review-backlog.sh into
# ~/.claude/scripts. Called from ~/.claude/hooks/post-commit, it appended every commit to
# ~/.claude/projects/<repo>/memory/review-backlog.md and to an untracked docs/review-queue.md in every
# repository with a docs/ directory, and nothing read either file: review coverage is content-keyed
# (memory/reviews/). The script is gone; _claude_home_retire_review_queue removes what it left behind.
# =======================================
install_claude_home() {
  echo ""
  echo "======================================"
  echo "  CLAUDE HOME (~/.claude)"
  echo "======================================"

  # The cleanup needs nothing from hooks/, so it runs even on a checkout the guard below stops.
  _claude_home_retire_review_queue
  # Everything else installs FROM hooks/. Without it there is nothing to install, and wiring
  # core.hooksPath or settings.json at hooks that never landed would point every git command and every
  # session at missing files — so stop here, before anything is installed into ~/.claude.
  if [[ ! -d "$ZUVO_DIR/hooks" ]]; then
    warn "hooks/ not found in $ZUVO_DIR — nothing installed into ~/.claude"
    return 0
  fi

  local hooks_dir="$HOME/.claude/hooks"
  # Order matters. _claude_home_git_hooks installs the hook tree (the gates, farm-no-local-tests.sh,
  # lib/) BEFORE it wires core.hooksPath.
  _claude_home_git_hooks "$hooks_dir"

  # ── Pipeline-entry hooks: full tree (incl. lib/) into ~/.claude/hooks/ (the
  # core.hooksPath target) + CI script + git shim + CI workflow template into
  # ~/.claude/scripts and ~/.claude/ci. The plugin hooks.json (in the cache)
  # already registers the gates + the SINGLE Stop site; install does NOT register
  # the Stop nudge in settings.json (one site, no double-fire).
  install_hook_tree "$hooks_dir"
  install_pipeline_artifacts "$HOME/.claude"
  ok "pipeline-entry hooks + lib + CI artifacts installed (~/.claude/hooks, ~/.claude/scripts, ~/.claude/ci)"

  # The settings.json registrations LAST: _claude_home_farm_guard registers farm-no-local-tests.sh only
  # if the hook tree put it in place, and it ran before both tree copies above had happened, so a first
  # copy that failed skipped the registration although the second one landed the file.
  _claude_home_stop_hook "$hooks_dir"
  _claude_home_skill_usage_logger "$hooks_dir"
  _claude_home_farm_guard "$hooks_dir"
  _claude_home_enable_guard "$hooks_dir"
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

  # Wire global git core.hooksPath to ~/.claude/hooks/ so our dispatchers (and any other dispatcher
  # already there, such as a post-commit that chains each repository's own hook) actually run.
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
    # Same directory by IDENTITY, not spelling: Git for Windows stores C:/Users/x/.claude/hooks while
    # Git Bash spells it /c/Users/x/.claude/hooks, and a trailing slash or a symlink differ the same way.
    elif [[ "$current_hooks_path" != "$hooks_dir" && ! "$current_hooks_path" -ef "$hooks_dir" ]]; then
      if [[ ! -d "$current_hooks_path" ]]; then
        warn "core.hooksPath was stale ($current_hooks_path) — replacing with $hooks_dir"
      else
        # A WORKING hooks dir: replacing it switches its hooks off for every repo on this machine, so
        # the way back goes with the warning.
        warn "core.hooksPath was $current_hooks_path — replacing with $hooks_dir (restore it with: git config --global core.hooksPath $(printf '%q' "$current_hooks_path"))"
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

# _claude_home_retire_review_queue — remove what the retired review queue left on this machine, through
# install.d/retire_review_queue.py (what it removes, what it keeps and why, and its archive are documented
# there). Every install runs it, so each machine cleans itself on its next install. It never stops the
# install: without python3, or when the cleanup fails, there is one warning and the leftovers stay as they
# were — the old post-commit call keeps writing them until an install succeeds; nothing breaks. Worded so it
# never repeats the settings-merge warnings, which tests count.
# ZUVO_KEEP_REVIEW_QUEUE=1 skips it (a person's opt-out; the dry run is
# `python3 scripts/install.d/retire_review_queue.py "$HOME" --dry-run`).
_claude_home_retire_review_queue() {
  if [[ "${ZUVO_KEEP_REVIEW_QUEUE:-}" == 1 ]]; then
    warn "ZUVO_KEEP_REVIEW_QUEUE=1 — the retired review queue's files were left in place"
    return 0
  fi
  local retire="$ZUVO_DIR/scripts/install.d/retire_review_queue.py"
  if ! zuvo_py_available; then
    warn "no Python 3 found (python3, python, py -3) — the retired review queue's leftover files were not cleaned up"
    return 0
  fi
  if [[ ! -r "$retire" ]]; then
    warn "cannot read $retire — the retired review queue's leftover files were not cleaned up"
    return 0
  fi
  zuvo_py "$retire" "$HOME" \
    || warn "review-queue cleanup ended with status $? — see the line above; nothing was deleted without an archive"
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
      _claude_home_register_hook "$claude_settings" "$stop_hook_dst" Stop - 15 Stop-hook \
        || warn "Stop-hook merge into ~/.claude/settings.json failed (manual edit may be needed)"
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
      _claude_home_register_hook "$claude_settings" "$sul_dst" PostToolUse Skill 5 skill-usage-logger " (PostToolUse matcher=Skill)" \
        || warn "skill-usage-logger merge into ~/.claude/settings.json failed (manual edit may be needed)"
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
      _claude_home_register_hook "$claude_settings" "$fnlt_dst" PreToolUse Bash 10 farm-no-local-tests " (PreToolUse matcher=Bash)" \
        || warn "farm-no-local-tests merge into ~/.claude/settings.json failed (manual edit may be needed)"
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
      _claude_home_register_hook "$claude_settings" "$peg_dst" SessionStart - 5 enable-guard " (SessionStart)" \
        || warn "enable-guard merge into ~/.claude/settings.json failed (manual edit may be needed)"
    else
      warn "~/.claude/settings.json not found — enable-guard not registered"
    fi
  else
    warn "hooks/zuvo-plugin-enable-guard.sh not found in repo — plugin enable-guard not installed"
  fi
}

# _claude_home_register_hook <settings.json> <hook script> <event> <matcher|-> <timeout> <label> [<note>]
# — register one hook in ~/.claude/settings.json, idempotently, through install.d/claude_settings.py:
# the one merge behind all four registrations (Stop, PostToolUse(Skill), PreToolUse(Bash) for the farm
# guard, SessionStart). What counts as "already registered", how it writes and what it does when the
# file changes under it are documented there. Status 0 registered or already there; non-zero otherwise,
# after one '  ! ' line naming why (the caller adds its own warning) — including the two causes that used
# to surface only as a bare "merge failed": no python3, and no merge script beside this file.
_claude_home_register_hook() {
  local merge="$ZUVO_DIR/scripts/install.d/claude_settings.py"
  if ! zuvo_py_available; then
    echo "  ! no Python 3 found (python3, python, py -3) — $6 not registered in ~/.claude/settings.json"
    return 1
  fi
  if [[ ! -r "$merge" ]]; then
    echo "  ! cannot read $merge — $6 not registered in ~/.claude/settings.json"
    return 1
  fi
  zuvo_py "$merge" "$@"
}
