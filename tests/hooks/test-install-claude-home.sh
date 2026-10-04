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
skip() { printf 'SKIP: %s\n' "$1"; }
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
    stale) msg="core.hooksPath was stale" ;; ours) msg="core.hooksPath already" ;;
    # Repointing a WORKING hooks dir switches its hooks off machine-wide: the warning carries the way back.
    other) msg="restore it with: git config --global core.hooksPath $H/elsewhere" ;;
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

# (7b) …but a checkout without hooks/ has nothing to install into ~/.claude: every step after the scripts
# copy installs FROM hooks/, and wiring core.hooksPath or settings.json there would point every git command
# and every session at files that never landed. It stops before creating anything, and says why.
R="$TMP/repo-nohooks"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/ci" "$ROOT/package.json" "$R/"
H="$TMP/nohooks"; mkdir -p "$H"
claude_home "$H" "$R"; rc=$?
created="$( { cd "$H" && find . -mindepth 1 | head -5 | tr '\n' ' '; } 2>/dev/null || echo '<HOME unreadable>')"
[ "$rc" -eq 0 ] && grep -q 'hooks/ not found' "$H.out" && [ -z "$created" ] \
  && pass "(7b) without hooks/: nothing is created under HOME, and the warning names hooks/" \
  || bad "(7b) exit $rc; created under HOME: [$created]; [$(tail -2 "$H.out" | tr '\n' '|')]"

# (8) a settings.json whose directory cannot be written: every merge fails BEFORE touching the file
# (the temp file goes beside it), each says so, and nothing is left behind. A truncating
# open(path, 'w') needed no directory write and so used to rewrite the file in place.
H="$TMP/rodir"; mkdir -p "$H/.claude" "$H/dotfiles"; printf '{"keep": 1}\n' > "$H/dotfiles/settings.json"
ln -s ../dotfiles/settings.json "$H/.claude/settings.json"; cp "$H/dotfiles/settings.json" "$TMP/rodir.before"
chmod 555 "$H/dotfiles"
claude_home "$H"; rc=$?
chmod 755 "$H/dotfiles"
if [ "$(id -u)" = 0 ]; then
  skip "(8) not run under root (a 555 directory does not stop root)"
else
  n_warn=$(grep -c 'merge into ~/.claude/settings.json failed' "$H.out")
  extra=""
  for f in "$H/dotfiles"/* "$H/dotfiles"/.[!.]*; do
    [ -e "$f" ] && [ "${f##*/}" != settings.json ] && extra="$extra ${f##*/}"
  done
  n_why=$(grep -c 'could not write ~/.claude/settings.json' "$H.out")
  [ "$rc" -eq 0 ] && [ "$n_warn" -eq 4 ] && [ "$n_why" -eq 4 ] && cmp -s "$TMP/rodir.before" "$H/dotfiles/settings.json" && [ -z "$extra" ] \
    && pass "(8) an unwritable settings directory: four failed merges reported, the file byte-identical, no temp files" \
    || bad "(8) unwritable settings dir: exit $rc, failure warnings x$n_warn, reasons named x$n_why, file $(cmp -s "$TMP/rodir.before" "$H/dotfiles/settings.json" && echo untouched || echo CHANGED)"
fi

# (9) a hook that only shares zuvo's FILE NAME is not zuvo's: a Stop hook at another path, and the skill
# logger under a matcher that never fires for Skill. Both used to count as registered (the merge asked
# only `command.endswith(<name>)`), so zuvo's own hook was silently never added.
H="$TMP/samename"; mkdir -p "$H/.claude"
printf '%s\n' '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"/opt/other/zuvo-stop-retro-sweep.sh"}]}],"PostToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"$HOME/.claude/hooks/skill-usage-logger.sh"}]}]}}' \
  > "$H/.claude/settings.json"
claude_home "$H"; rc=$?
got="$(hooks_of "$H/.claude/settings.json")"
{ [ "$rc" -eq 0 ] && printf '%s\n' "$got" | grep -qx 'Stop - 15 zuvo-stop-retro-sweep.sh' \
  && printf '%s\n' "$got" | grep -qx 'Stop - None zuvo-stop-retro-sweep.sh' \
  && printf '%s\n' "$got" | grep -qx 'PostToolUse Skill 5 skill-usage-logger.sh' \
  && printf '%s\n' "$got" | grep -qx 'PostToolUse Bash None skill-usage-logger.sh'; } \
  && pass "(9) a same-named hook elsewhere, or under a matcher that misses Skill, does not stop zuvo's registration; the user's stays" \
  || bad "(9) exit $rc; registrations: [$(printf '%s' "$got" | tr '\n' '|')]"

# (10) …but a registration that already fires for the event IS zuvo's, whatever its spelling: a matcher
# pattern covering the tool (Skill|Read, Bash|Write), the legacy `bash ~/…` form, and a path through a
# symlink to ~/.claude/hooks. None may gain a duplicate (the farm guard compared paths without resolving
# links, and added a second registration for the same file).
H="$TMP/covered"; mkdir -p "$H/.claude"; ln -s .claude/hooks "$H/linked-hooks"
printf '%s\n' "{\"hooks\":{\"PostToolUse\":[{\"matcher\":\"Skill|Read\",\"hooks\":[{\"type\":\"command\",\"command\":\"\$HOME/.claude/hooks/skill-usage-logger.sh\",\"timeout\":5}]}],\"PreToolUse\":[{\"matcher\":\"Bash|Write\",\"hooks\":[{\"type\":\"command\",\"command\":\"$H/linked-hooks/farm-no-local-tests.sh\",\"timeout\":10}]}],\"SessionStart\":[{\"hooks\":[{\"type\":\"command\",\"command\":\"bash ~/.claude/hooks/zuvo-plugin-enable-guard.sh\",\"timeout\":5}]}]}}" \
  > "$H/.claude/settings.json"
claude_home "$H"; rc=$?
got="$(hooks_of "$H/.claude/settings.json")"
dups=""
for n in skill-usage-logger.sh farm-no-local-tests.sh zuvo-plugin-enable-guard.sh zuvo-stop-retro-sweep.sh; do
  c=$(printf '%s\n' "$got" | grep -c " $n\$"); [ "$c" -eq 1 ] || dups="$dups $n=$c"
done
kept="$(python3 - "$H/.claude/settings.json" "$H" <<'PY'
import json, sys
s = json.load(open(sys.argv[1])); home = sys.argv[2]
def has(event, matcher, command):
    return any(g.get('matcher') == matcher and any(h.get('command') == command for h in g.get('hooks', []))
               for g in s['hooks'].get(event, []))
print(all([has('PostToolUse', 'Skill|Read', '$HOME/.claude/hooks/skill-usage-logger.sh'),
           has('PreToolUse', 'Bash|Write', home + '/linked-hooks/farm-no-local-tests.sh'),
           has('SessionStart', None, 'bash ~/.claude/hooks/zuvo-plugin-enable-guard.sh')]))
PY
)"
[ "$rc" -eq 0 ] && [ -z "$dups" ] && [ "$kept" = True ] \
  && pass "(10) a covering matcher, the bash ~/ form and a symlinked hooks dir all count as registered: the user's three entries are kept as written, one registration each" \
  || bad "(10) exit $rc; counts off:$dups; the user's entries kept as written: $kept [$(printf '%s' "$got" | tr '\n' '|')]"

# (11) concurrent registrations (parallel agents each run install.sh; the race is in the settings
# merge, so that is what runs here, six times at once): none may be lost or refused. Every writer is
# released by one start signal, so they read the file together instead of one after another.
H="$TMP/parallel"; mkdir -p "$H/.claude/hooks"; printf '{}\n' > "$H/.claude/settings.json"
env -i PATH="$PATH" HOME="$H" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
  "$BASH" -c '. "$1" >/dev/null 2>&1 || exit 97
    for i in 1 2 3 4 5 6; do
      ( while [ ! -e "$HOME/go" ]; do sleep 0.01; done
        _claude_home_register_hook "$HOME/.claude/settings.json" "$HOME/.claude/hooks/p$i.sh" Stop - 5 "p$i" >"$HOME/p$i.out" 2>&1
        echo $? > "$HOME/p$i.rc" ) &
    done
    sleep 0.3; touch "$HOME/go"; wait' _ "$ROOT/scripts/install.sh"
n_ok=0; for i in 1 2 3 4 5 6; do [ "$(cat "$H/p$i.rc" 2>/dev/null)" = 0 ] && n_ok=$((n_ok + 1)); done
n_reg="$(hooks_of "$H/.claude/settings.json" | grep -c '^Stop - 5 p[1-6]\.sh$')"
[ "$n_ok" -eq 6 ] && [ "$n_reg" -eq 6 ] \
  && pass "(11) six registrations released at once into one settings.json: all six succeed, all six present" \
  || bad "(11) concurrent registrations: $n_ok/6 succeeded, $n_reg/6 present [$(cat "$H"/p?.out 2>/dev/null | grep -v '✓' | head -3 | tr '\n' '|')]"

# (12) no python3 on the PATH: each registration says THAT, not a bare 'merge failed'.
. "$ROOT/tests/lib/hermetic-tools.sh"
NOPY="$TMP/nopy-bin"; mkdir -p "$NOPY"
hermetic_link_tools "$NOPY" bash sh env git cp mv rm ln mkdir chmod cat cmp ls head tail tr wc sort sed awk grep \
  find mktemp basename dirname date readlink touch stat id uname sleep printf
H="$TMP/nopython"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
env -i PATH="$NOPY" HOME="$H" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
  "$NOPY/bash" -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude_home' _ "$ROOT/scripts/install.sh" > "$H.out" 2>&1; rc=$?
n_py=$(grep -c 'python3 not found' "$H.out")
[ "$rc" -eq 0 ] && [ "$n_py" -eq 4 ] && cmp -s <(printf '{}\n') "$H/.claude/settings.json" \
  && pass "(12) without python3: all four registrations say python3 is missing, settings.json untouched" \
  || bad "(12) without python3: exit $rc, 'python3 not found' x$n_py/4 [$(grep -E 'settings|python' "$H.out" | head -3 | tr '\n' '|')]"

# (13) a malformed call to the merge script says so on one '  ! ' line (status 64), never a traceback,
# and touches nothing
H="$TMP/badcall"; mkdir -p "$H"; printf '{"keep": 1}\n' > "$H/settings.json"
out="$(HOME="$H" python3 "$ROOT/scripts/install.d/claude_settings.py" "$H/settings.json" "$H/x.sh" Stop - five label 2>&1)"; rc=$?
[ "$rc" -eq 64 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && printf '%s' "$out" | grep -q '^  ! claude_settings.py: bad arguments' \
  && ! printf '%s' "$out" | grep -q Traceback && [ "$(cat "$H/settings.json")" = '{"keep": 1}' ] \
  && pass "(13) a malformed call to claude_settings.py: one '  ! ' line, status 64, settings untouched" \
  || bad "(13) malformed call: status $rc [$(printf '%s' "$out" | head -2 | tr '\n' '|')]"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
