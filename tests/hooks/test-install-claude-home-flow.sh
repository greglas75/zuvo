#!/usr/bin/env bash
# Exercise Claude-home installation against throwaway HOME and global Git config.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME/.claude"

PASS=0; FAIL=0
t_ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
t_no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# install.sh has a source-time sleep-guard write; HOME is isolated before sourcing.
if ! . "$ROOT/scripts/install.sh" >"$TMP/source.out" 2>&1; then
  t_no "install.sh can be sourced into the isolated HOME"
  exit 1
fi

SETTINGS="$HOME/.claude/settings.json"
printf '%s\n' '{"custom":"user-value","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo user-stop"}]}]}}' > "$SETTINGS"
if install_claude_home >"$TMP/first.out" 2>&1; then
  t_ok "Claude-home installation completes"
else
  t_no "Claude-home installation failed: $(tail -5 "$TMP/first.out")"
fi

SCRIPT_COUNT=0
SCRIPT_MISMATCH=0
for src in "$ZUVO_DIR/scripts/claude-home/scripts"/*.sh; do
  [ -f "$src" ] || continue
  SCRIPT_COUNT=$((SCRIPT_COUNT + 1))
  dst="$HOME/.claude/scripts/${src##*/}"
  if [ ! -x "$dst" ] || ! cmp -s "$src" "$dst"; then SCRIPT_MISMATCH=$((SCRIPT_MISMATCH + 1)); fi
done
if [ "$SCRIPT_COUNT" -gt 0 ] && [ "$SCRIPT_MISMATCH" -eq 0 ]; then
  t_ok "all Claude-home helper scripts are executable and byte-identical"
else
  t_no "helper scripts: source=$SCRIPT_COUNT, missing or different=$SCRIPT_MISMATCH"
fi

HOOKS="$HOME/.claude/hooks"
if [ -x "$HOOKS/pre-push" ] && [ -x "$HOOKS/pre-commit" ] && \
   [ -x "$HOOKS/pre-push-gate.sh" ] && [ -x "$HOOKS/refactor-safety-gate.sh" ] && \
   [ -x "$HOOKS/zuvo-stop-retro-sweep.sh" ] && [ -x "$HOOKS/skill-usage-logger.sh" ] && \
   [ -x "$HOOKS/zuvo-plugin-enable-guard.sh" ]; then
  t_ok "global dispatchers, gates and registered hook scripts are installed"
else
  t_no "Claude-home hook tree is incomplete"
fi
if [ "$(git config --global --get core.hooksPath 2>/dev/null || true)" = "$HOOKS" ] && \
   [ -f "$GIT_CONFIG_GLOBAL" ]; then
  t_ok "global core.hooksPath points to the isolated hook tree"
else
  t_no "core.hooksPath was not written into the isolated Git config"
fi

check_settings() {
  python3 - "$SETTINGS" <<'PY'
import json, os, sys
with open(sys.argv[1]) as f:
    settings = json.load(f)
assert settings.get('custom') == 'user-value', 'unrelated setting changed'
hooks = settings['hooks']
assert any(h.get('command') == 'echo user-stop'
           for g in hooks['Stop'] for h in g.get('hooks', [])), 'user Stop hook was lost'
for event, matcher, filename in (
    ('Stop', None, 'zuvo-stop-retro-sweep.sh'),
    ('PostToolUse', 'Skill', 'skill-usage-logger.sh'),
    ('PreToolUse', 'Bash', 'farm-no-local-tests.sh'),
    ('SessionStart', None, 'zuvo-plugin-enable-guard.sh'),
):
    matches = [h for g in hooks.get(event, [])
               if matcher is None or g.get('matcher') == matcher
               for h in g.get('hooks', [])
               if os.path.basename(h.get('command', '')) == filename]
    assert len(matches) == 1, f'{event}/{filename}: expected one registration, got {len(matches)}'
PY
}
if check_settings >"$TMP/settings-first.out" 2>&1; then
  t_ok "Stop, PostToolUse, PreToolUse and SessionStart each register once; user settings survive"
else
  t_no "first settings merge: $(cat "$TMP/settings-first.out")"
fi
if install_claude_home >"$TMP/second.out" 2>&1 && \
   check_settings >"$TMP/settings-second.out" 2>&1; then
  t_ok "reinstallation keeps one registration per event and the user hook"
else
  t_no "reinstallation duplicated or damaged settings: $(cat "$TMP/settings-second.out" 2>/dev/null)"
fi

# A malformed settings file must remain byte-for-byte intact while merge warnings are shown.
export HOME="$TMP/malformed-home"
mkdir -p "$HOME/.claude"
SETTINGS="$HOME/.claude/settings.json"
printf '{"hooks": [malformed json}\n' > "$SETTINGS"
cp "$SETTINGS" "$TMP/malformed-original"
if install_claude_home >"$TMP/malformed.out" 2>&1; then
  if cmp -s "$TMP/malformed-original" "$SETTINGS" && \
     grep -q 'malformed' "$TMP/malformed.out" && \
     grep -q 'merge into ~/.claude/settings.json failed' "$TMP/malformed.out"; then
    t_ok "malformed settings are preserved and skipped merges are reported"
  else
    t_no "malformed settings changed or merge warning was absent"
  fi
else
  t_no "malformed settings aborted the rest of Claude-home installation"
fi

# Missing source returns before creating anything under a fresh HOME.
ORIGINAL_ZUVO_DIR="$ZUVO_DIR"
ZUVO_DIR="$TMP/no-source-repo"
export HOME="$TMP/missing-source-home"
mkdir -p "$HOME"
if install_claude_home >"$TMP/missing-source.out" 2>&1; then
  if [ ! -e "$HOME/.claude" ] && \
     grep -q 'scripts/claude-home/scripts not found' "$TMP/missing-source.out"; then
    t_ok "missing Claude-home source warns and leaves HOME untouched"
  else
    t_no "missing source created Claude-home files or did not warn"
  fi
else
  t_no "missing Claude-home source returned an unexpected error"
fi
ZUVO_DIR="$ORIGINAL_ZUVO_DIR"

printf '  --- install Claude home: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
