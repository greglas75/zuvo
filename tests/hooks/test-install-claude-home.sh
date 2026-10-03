#!/usr/bin/env bash
# install_claude_home (scripts/install.d/claude-home.sh), executed for real into temp HOMEs.
#
# This is the installer step with machine-wide reach: it puts zuvo's git dispatchers into
# ~/.claude/hooks, points the GLOBAL core.hooksPath at them, and registers four hooks in
# ~/.claude/settings.json — the file every Claude Code session reads at start. Until this file it
# had no test that ran it: other suites grepped its text. Each case below runs the real function,
# sourced from the repo's install.sh, against its own HOME and its own global git config.
#
# Test level: MEDIUM — real installer code, python merges and git config writes, all under $TMP;
# no network, no provider CLI, nothing outside the temp dir.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }
[ -n "${BASH:-}" ] || BASH="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }

# claude_home <home> [<repo root>] — source <repo>/scripts/install.sh and run install_claude_home
# under set -euo pipefail (as the installer does), output to <home>.out, status returned.
claude_home() {
  local h="$1" repo="${2:-$ROOT}"
  mkdir -p "$h"
  env -i PATH="$PATH" HOME="$h" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$h/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$h/.config" \
    "$BASH" -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude_home' _ "$repo/scripts/install.sh" \
    > "$h.out" 2>&1
}
# hooks_of <settings.json> — one line per registration: <event> <matcher or -> <timeout> <script name>
hooks_of() {
  python3 - "$1" <<'PYEOF'
import json, os, sys
s = json.load(open(sys.argv[1]))
for event, groups in sorted(s.get('hooks', {}).items()):
    for g in groups:
        for h in g.get('hooks', []):
            print(event, g.get('matcher', '-'), h.get('timeout'), os.path.basename(h.get('command', '')))
PYEOF
}
WANT_HOOKS="PostToolUse Skill 5 skill-usage-logger.sh
PreToolUse Bash 10 farm-no-local-tests.sh
SessionStart - 5 zuvo-plugin-enable-guard.sh
Stop - 15 zuvo-stop-retro-sweep.sh"
gitconfig_hooks_path() { git config --file "$1/.gitconfig" --get core.hooksPath 2>/dev/null; }

# (1) a fresh HOME: the four hooks, nothing else touched, the dispatchers wired globally
H="$TMP/fresh"; mkdir -p "$H/.claude"; printf '{"theme": "dark"}\n' > "$H/.claude/settings.json"
claude_home "$H"; rc=$?
got="$(hooks_of "$H/.claude/settings.json")"
[ "$rc" -eq 0 ] && [ "$got" = "$WANT_HOOKS" ] \
  && pass "(1) fresh install registers exactly the four hooks (event, matcher, timeout, script)" \
  || bad "(1) exit $rc; registrations:
$got"
[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("theme"))' "$H/.claude/settings.json")" = dark ] \
  && pass "(1b) the user's own settings survive the merge" || bad "(1b) the user's theme setting was lost"
[ "$(gitconfig_hooks_path "$H")" = "$H/.claude/hooks" ] && [ -x "$H/.claude/hooks/pre-push" ] \
  && [ -x "$H/.claude/hooks/pre-push-gate.sh" ] \
  && pass "(1c) core.hooksPath points at ~/.claude/hooks, which holds the dispatchers AND the gates" \
  || bad "(1c) core.hooksPath=[$(gitconfig_hooks_path "$H")], pre-push $([ -x "$H/.claude/hooks/pre-push" ] && echo ok || echo MISSING)"
# (~/.claude/scripts also receives the pipeline-entry scripts, so this checks each claude-home one.)
n_src=0; missing=""
for f in "$ROOT"/scripts/claude-home/scripts/*.sh; do
  [ -f "$f" ] || continue
  n_src=$((n_src + 1))
  { [ -x "$H/.claude/scripts/${f##*/}" ] && cmp -s "$f" "$H/.claude/scripts/${f##*/}"; } || missing="$missing ${f##*/}"
done
[ "$n_src" -ge 1 ] && [ -z "$missing" ] \
  && pass "(1d) every scripts/claude-home/scripts/*.sh ($n_src) lands in ~/.claude/scripts, executable and identical" \
  || bad "(1d) claude-home scripts missing or different in ~/.claude/scripts:$missing (of $n_src)"
grep -q '^asserted_at=[0-9]' "$H/.zuvo/plugin-enable-state" 2>/dev/null \
  && pass "(1e) the enable-guard assertion is stamped" || bad "(1e) no ~/.zuvo/plugin-enable-state assertion"

# every registered command is the hook in ~/.claude/hooks, written with a literal $HOME
cmds="$(python3 -c 'import json,sys; [print(h["command"]) for gs in json.load(open(sys.argv[1]))["hooks"].values() for g in gs for h in g["hooks"]]' "$H/.claude/settings.json" | sort)"
[ "$cmds" = "$(printf '%s\n' '$HOME/.claude/hooks/farm-no-local-tests.sh' '$HOME/.claude/hooks/skill-usage-logger.sh' '$HOME/.claude/hooks/zuvo-plugin-enable-guard.sh' '$HOME/.claude/hooks/zuvo-stop-retro-sweep.sh' | sort)" ] \
  && pass "(1f) each registered command is the hook script under \$HOME/.claude/hooks" || bad "(1f) registered commands: $(printf '%s' "$cmds" | tr '\n' ' ')"

# (2) a second run changes nothing in settings.json and says so for each hook
cp "$H/.claude/settings.json" "$TMP/settings.before"
claude_home "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$TMP/settings.before" "$H/.claude/settings.json" \
  && [ "$(grep -c 'already registered' "$H.out")" -eq 4 ] \
  && pass "(2) a rerun leaves settings.json byte-identical and reports all four as already registered" \
  || bad "(2) rerun: exit $rc, 'already registered' x$(grep -c 'already registered' "$H.out"), changed: $(cmp -s "$TMP/settings.before" "$H/.claude/settings.json" && echo no || echo YES)"

# (3) a symlinked settings.json (dotfile managers) with a private mode: every merge writes THROUGH the
# link, keeps the mode, and leaves no temp file behind. The SessionStart merge used to replace the
# file with a fresh one at the default mode, under a fixed temp name.
H="$TMP/symlink"; mkdir -p "$H/.claude" "$H/dotfiles"
printf '{}\n' > "$H/dotfiles/settings.json"; chmod 640 "$H/dotfiles/settings.json"   # not mkstemp's own 600
ln -s ../dotfiles/settings.json "$H/.claude/settings.json"
claude_home "$H"; rc=$?
mode="$(stat -c %a "$H/dotfiles/settings.json" 2>/dev/null || stat -f %Lp "$H/dotfiles/settings.json")"
leftovers=""
for f in "$H/dotfiles"/* "$H/dotfiles"/.[!.]* "$H/.claude"/.[!.]*; do
  [ -e "$f" ] || [ -L "$f" ] || continue
  case "${f##*/}" in settings.json) continue ;; esac
  leftovers="$leftovers ${f##*/}"
done
[ "$rc" -eq 0 ] && [ -L "$H/.claude/settings.json" ] && [ "$mode" = 640 ] && [ -z "$leftovers" ] \
  && [ "$(hooks_of "$H/dotfiles/settings.json")" = "$WANT_HOOKS" ] \
  && pass "(3) through a symlinked settings.json: link kept, mode 640 kept, four hooks, no temp files left" \
  || bad "(3) exit $rc, link $([ -L "$H/.claude/settings.json" ] && echo kept || echo LOST), mode $mode, leftovers [$leftovers]"

# (4) no settings.json: each registration warns, nothing is created
H="$TMP/nosettings"; mkdir -p "$H/.claude"
claude_home "$H"; rc=$?
[ "$rc" -eq 0 ] && [ "$(grep -c 'settings.json not found' "$H.out")" -eq 4 ] && [ ! -e "$H/.claude/settings.json" ] \
  && pass "(4) without settings.json all four registrations warn and none creates it" \
  || bad "(4) exit $rc, warnings x$(grep -c 'settings.json not found' "$H.out")"

# (5) a malformed settings.json is refused by every merge and left byte-identical
H="$TMP/malformed"; mkdir -p "$H/.claude"; printf '{ not json\n' > "$H/.claude/settings.json"
claude_home "$H"; rc=$?
printf '{ not json\n' > "$TMP/malformed.want"
[ "$rc" -eq 0 ] && [ "$(grep -c 'is malformed' "$H.out")" -eq 4 ] && cmp -s "$TMP/malformed.want" "$H/.claude/settings.json" \
  && pass "(5) a malformed settings.json is refused four times and left untouched" \
  || bad "(5) exit $rc, refusals x$(grep -c 'is malformed' "$H.out")"

# (6) core.hooksPath already set: a stale path and a different existing path are both repointed, with
# the reason said; our own path is left alone
for state in stale other ours; do
  H="$TMP/hp-$state"; mkdir -p "$H/.claude" "$H/elsewhere"; printf '{}\n' > "$H/.claude/settings.json"
  case "$state" in
    stale) git config --file "$H/.gitconfig" core.hooksPath "$H/gone" ;;
    other) git config --file "$H/.gitconfig" core.hooksPath "$H/elsewhere" ;;
    ours)  git config --file "$H/.gitconfig" core.hooksPath "$H/.claude/hooks" ;;
  esac
  claude_home "$H"; rc=$?
  case "$state" in
    stale) msg="core.hooksPath was stale" ;; other) msg="core.hooksPath was $H/elsewhere" ;; ours) msg="core.hooksPath already" ;;
  esac
  [ "$rc" -eq 0 ] && [ "$(gitconfig_hooks_path "$H")" = "$H/.claude/hooks" ] && grep -qF "$msg" "$H.out" \
    && pass "(6) core.hooksPath $state -> ~/.claude/hooks ('$msg')" \
    || bad "(6) core.hooksPath $state: exit $rc, now [$(gitconfig_hooks_path "$H")], message '$msg' $(grep -qF "$msg" "$H.out" && echo seen || echo MISSING)"
done

# (7) a checkout without scripts/claude-home/scripts skips that copy only. It used to `return 0`
# there, skipping the dispatchers, core.hooksPath and every settings.json hook as well.
R="$TMP/repo-noscripts"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/ci" "$ROOT/package.json" "$R/"
rm -rf "$R/scripts/claude-home/scripts"
H="$TMP/noscripts"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H" "$R"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'skipping the ~/.claude/scripts copy' "$H.out" \
  && [ "$(hooks_of "$H/.claude/settings.json")" = "$WANT_HOOKS" ] && [ "$(gitconfig_hooks_path "$H")" = "$H/.claude/hooks" ] \
  && pass "(7) without scripts/claude-home/scripts: the copy is skipped, the hooks and core.hooksPath are still wired" \
  || bad "(7) exit $rc; hooks: $(hooks_of "$H/.claude/settings.json" 2>/dev/null | wc -l)/4, core.hooksPath [$(gitconfig_hooks_path "$H")] [$(tail -2 "$H.out" | tr '\n' '|')]"

# (8) a settings.json whose directory cannot be written: every merge fails BEFORE touching the file
# (the temp file goes beside it), each says so, and nothing is left behind. A truncating
# open(path, 'w') needed no directory write and so used to rewrite the file in place.
H="$TMP/rodir"; mkdir -p "$H/.claude" "$H/dotfiles"; printf '{"keep": 1}\n' > "$H/dotfiles/settings.json"
ln -s ../dotfiles/settings.json "$H/.claude/settings.json"; cp "$H/dotfiles/settings.json" "$TMP/rodir.before"
chmod 555 "$H/dotfiles"
claude_home "$H"; rc=$?
chmod 755 "$H/dotfiles"
if [ "$(id -u)" = 0 ]; then
  pass "(8) skipped under root (a 555 directory does not stop root)"
else
  n_warn=$(grep -c 'merge into ~/.claude/settings.json failed' "$H.out")
  extra=""
  for f in "$H/dotfiles"/* "$H/dotfiles"/.[!.]*; do
    [ -e "$f" ] && [ "${f##*/}" != settings.json ] && extra="$extra ${f##*/}"
  done
  [ "$rc" -eq 0 ] && [ "$n_warn" -eq 4 ] && cmp -s "$TMP/rodir.before" "$H/dotfiles/settings.json" && [ -z "$extra" ] \
    && pass "(8) an unwritable settings directory: four failed merges reported, the file byte-identical, no temp files" \
    || bad "(8) unwritable settings dir: exit $rc, failure warnings x$n_warn, file $(cmp -s "$TMP/rodir.before" "$H/dotfiles/settings.json" && echo untouched || echo CHANGED)"
fi

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
