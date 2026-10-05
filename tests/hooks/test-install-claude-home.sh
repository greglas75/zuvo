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
# The review queue is retired (2026-10-05): a fresh install puts nothing of it in place and, with nothing
# to clean up, says nothing about it and archives nothing.
[ ! -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] && [ ! -d "$ROOT/scripts/claude-home" ] \
  && ! grep -q 'review queue' "$H.out" && [ ! -e "$H/.zuvo/archive" ] \
  && pass "(1d) no review-queue script installed, nothing to retire: no output about it, no archive" \
  || bad "(1d) review queue on a fresh install: script $([ -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] && echo INSTALLED || echo absent), [$(grep 'review queue' "$H.out" | head -2 | tr '\n' '|')]"
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

# (7) a machine an earlier release left the review queue on: the install retires it (the installed script,
# and its call in a ~/.claude/hooks/post-commit zuvo did not write, whose other lines stay) and still wires
# everything else. What the cleanup keeps and why is tests/hooks/test-retire-review-queue.sh.
H="$TMP/retire"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"; printf '{}\n' > "$H/.claude/settings.json"
cp "$ROOT/tests/fixtures/review-queue/post-commit-review-backlog.sh" "$H/.claude/scripts/"
printf '%s\n' '#!/bin/bash' 'bash "$HOME/.claude/scripts/post-commit-review-backlog.sh" 2>/dev/null' 'echo chained' > "$H/.claude/hooks/post-commit"
chmod +x "$H/.claude/hooks/post-commit"; printf '#!/bin/bash\necho chained\n' > "$TMP/retire.want"
claude_home "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] \
  && cmp -s "$TMP/retire.want" "$H/.claude/hooks/post-commit" \
  && grep -q '✓ review queue retired: 0 memory backlog(s), 0 repository queue file(s), the installed script, its call in' "$H.out" \
  && [ "$(hooks_of "$H/.claude/settings.json")" = "$WANT_HOOKS" ] && [ "$(gitconfig_hooks_path "$H")" = "$H/.claude/hooks" ] \
  && pass "(7) an install retires a left-over review queue (script and dispatcher call) and still wires the hooks and core.hooksPath" \
  || bad "(7) exit $rc; script $([ -e "$H/.claude/scripts/post-commit-review-backlog.sh" ] && echo LEFT || echo gone), dispatcher [$(tr '\n' '|' < "$H/.claude/hooks/post-commit")] [$(grep 'review queue' "$H.out" | tr '\n' '|')]"

# (7c) the cleanup's two failure paths never stop the install: a checkout without retire_review_queue.py
# says so, and a cleanup that ends non-zero (here: no archive can be written, ~/.zuvo being a file) is a
# warning carrying its status — the hooks and core.hooksPath are wired either way
R="$TMP/repo-noretire"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/ci" "$ROOT/package.json" "$R/"
rm -f "$R/scripts/install.d/retire_review_queue.py"
H="$TMP/noretire"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H" "$R"; rc=$?
[ "$rc" -eq 0 ] && grep -q "cannot read .*retire_review_queue.py — the retired review queue's leftover files were not cleaned up" "$H.out" \
  && [ "$(hooks_of "$H/.claude/settings.json")" = "$WANT_HOOKS" ] && [ "$(gitconfig_hooks_path "$H")" = "$H/.claude/hooks" ] \
  && pass "(7c) without retire_review_queue.py: one warning naming it, the hooks and core.hooksPath still wired" \
  || bad "(7c) no cleanup helper: exit $rc [$(grep -i 'review' "$H.out" | head -2 | tr '\n' '|')]"
H="$TMP/retirefail"; mkdir -p "$H/.claude/scripts"; printf '{}\n' > "$H/.claude/settings.json"; : > "$H/.zuvo"
cp "$ROOT/tests/fixtures/review-queue/post-commit-review-backlog.sh" "$H/.claude/scripts/"
claude_home "$H"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'review-queue cleanup ended with status 2' "$H.out" \
  && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] && [ "$(hooks_of "$H/.claude/settings.json")" = "$WANT_HOOKS" ] \
  && pass "(7d) a cleanup that cannot archive: warned with its status 2, nothing deleted, every hook still registered" \
  || bad "(7d) failing cleanup: exit $rc [$(grep -i 'review' "$H.out" | head -3 | tr '\n' '|')]"

# (7e) ZUVO_KEEP_REVIEW_QUEUE=1 is a person's opt-out: the cleanup says it was skipped and touches nothing
H="$TMP/keepqueue"; mkdir -p "$H/.claude/scripts" "$H/.claude/hooks"; printf '{}\n' > "$H/.claude/settings.json"
cp "$ROOT/tests/fixtures/review-queue/post-commit-review-backlog.sh" "$H/.claude/scripts/"
printf '%s\n' '#!/bin/bash' 'bash "$HOME/.claude/scripts/post-commit-review-backlog.sh" 2>/dev/null' > "$H/.claude/hooks/post-commit"
cp "$H/.claude/hooks/post-commit" "$TMP/keepqueue.before"
env -i PATH="$PATH" HOME="$H" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
  XDG_CONFIG_HOME="$H/.config" ZUVO_KEEP_REVIEW_QUEUE=1 \
  "$BASH" -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude_home' _ "$ROOT/scripts/install.sh" > "$H.out" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -q 'ZUVO_KEEP_REVIEW_QUEUE=1 — the retired review queue' "$H.out" \
  && [ -f "$H/.claude/scripts/post-commit-review-backlog.sh" ] && cmp -s "$TMP/keepqueue.before" "$H/.claude/hooks/post-commit" \
  && [ ! -e "$H/.zuvo/archive" ] && [ "$(hooks_of "$H/.claude/settings.json")" = "$WANT_HOOKS" ] \
  && pass "(7e) ZUVO_KEEP_REVIEW_QUEUE=1: the cleanup is skipped and says so, nothing touched, the rest installs" \
  || bad "(7e) opt-out: exit $rc [$(grep -i 'review' "$H.out" | head -2 | tr '\n' '|')]"

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
# released by one start signal once all six are waiting, so they read the file together instead of one
# after another.
H="$TMP/parallel"; mkdir -p "$H/.claude/hooks"; printf '{}\n' > "$H/.claude/settings.json"
env -i PATH="$PATH" HOME="$H" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$H/.gitconfig" GIT_CONFIG_NOSYSTEM=1 \
  "$BASH" -c '. "$1" >/dev/null 2>&1 || exit 97
    for i in 1 2 3 4 5 6; do
      ( : > "$HOME/ready$i"; while [ ! -e "$HOME/go" ]; do sleep 0.01; done
        _claude_home_register_hook "$HOME/.claude/settings.json" "$HOME/.claude/hooks/p$i.sh" Stop - 5 "p$i" >"$HOME/p$i.out" 2>&1
        echo $? > "$HOME/p$i.rc" ) &
    done
    n=0; until [ "$(ls "$HOME"/ready? 2>/dev/null | wc -l)" -eq 6 ] || [ "$n" -ge 500 ]; do sleep 0.01; n=$((n + 1)); done
    touch "$HOME/go"; wait' _ "$ROOT/scripts/install.sh"
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
  && grep -q "no python3 on PATH — the retired review queue's leftover files were not cleaned up" "$H.out" \
  && pass "(12) without python3: all four registrations say python3 is missing, the review-queue cleanup says so too, settings.json untouched" \
  || bad "(12) without python3: exit $rc, 'python3 not found' x$n_py/4 [$(grep -E 'settings|python' "$H.out" | head -3 | tr '\n' '|')]"

# (13) a malformed call to the merge script says so on one '  ! ' line (status 64), never a traceback,
# and touches nothing
H="$TMP/badcall"; mkdir -p "$H"; printf '{"keep": 1}\n' > "$H/settings.json"
out="$(HOME="$H" python3 "$ROOT/scripts/install.d/claude_settings.py" "$H/settings.json" "$H/x.sh" Stop - five label 2>&1)"; rc=$?
[ "$rc" -eq 64 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && printf '%s' "$out" | grep -q '^  ! claude_settings.py: bad arguments' \
  && ! printf '%s' "$out" | grep -q Traceback && [ "$(cat "$H/settings.json")" = '{"keep": 1}' ] \
  && pass "(13) a malformed call to claude_settings.py: one '  ! ' line, status 64, settings untouched" \
  || bad "(13) malformed call: status $rc [$(printf '%s' "$out" | head -2 | tr '\n' '|')]"

# (13b) the rest of the call's shape: an empty positional argument (an empty script would register a
# bare `bash`) and a timeout of non-ASCII digits ('²'.isdigit() is True; int() rejects it) are bad calls
# too, and so is a short call under python -OO, where the docstring the usage line once came from is gone
H="$TMP/badcall2"; mkdir -p "$H"; printf '{"keep": 1}\n' > "$H/settings.json"
n_ok=0
for call in "empty-script" "superscript-timeout" "optimized-short"; do
  case "$call" in
    empty-script)        out="$(HOME="$H" python3 "$ROOT/scripts/install.d/claude_settings.py" "$H/settings.json" "" Stop - 5 label 2>&1)"; rc=$? ;;
    superscript-timeout) out="$(HOME="$H" python3 "$ROOT/scripts/install.d/claude_settings.py" "$H/settings.json" "$H/x.sh" Stop - '²' label 2>&1)"; rc=$? ;;
    optimized-short)     out="$(HOME="$H" python3 -OO "$ROOT/scripts/install.d/claude_settings.py" "$H/settings.json" 2>&1)"; rc=$? ;;
  esac
  [ "$rc" -eq 64 ] && [ "$(printf '%s\n' "$out" | wc -l)" -eq 1 ] && printf '%s' "$out" | grep -q '^  ! claude_settings.py: bad arguments .* usage: claude_settings.py <settings.json>' \
    && n_ok=$((n_ok + 1)) || printf '  (13b) %s: status %s [%s]\n' "$call" "$rc" "$(printf '%s' "$out" | head -2 | tr '\n' '|')"
done
[ "$n_ok" -eq 3 ] && [ "$(cat "$H/settings.json")" = '{"keep": 1}' ] \
  && pass "(13b) an empty argument, a non-ASCII timeout and a short call under -OO: each one '  ! ' line with the usage, status 64, settings untouched" \
  || bad "(13b) bad call shapes: $n_ok/3 refused as a bad call"

# (14) a checkout missing each registered hook script: every one is said by name, none is registered,
# and the rest of the install still happens
R="$TMP/repo-nohookfiles"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/ci" "$ROOT/package.json" "$R/"
rm -f "$R/hooks/zuvo-stop-retro-sweep.sh" "$R/hooks/skill-usage-logger.sh" "$R/hooks/zuvo-plugin-enable-guard.sh" "$R/hooks/farm-no-local-tests.sh"
H="$TMP/nohookfiles"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H" "$R"; rc=$?
n_missing=0
for n in zuvo-stop-retro-sweep.sh skill-usage-logger.sh zuvo-plugin-enable-guard.sh farm-no-local-tests.sh; do
  grep -q "hooks/$n not found in repo" "$H.out" && n_missing=$((n_missing + 1))
done
[ "$rc" -eq 0 ] && [ "$n_missing" -eq 4 ] && [ -z "$(hooks_of "$H/.claude/settings.json")" ] && [ "$(gitconfig_hooks_path "$H")" = "$H/.claude/hooks" ] \
  && pass "(14) four missing hook scripts: each named, none registered, core.hooksPath still wired" \
  || bad "(14) missing hook scripts: exit $rc, named $n_missing/4, registered [$(hooks_of "$H/.claude/settings.json" | tr '\n' '|')]"

# (15) dispatchers that did not install leave core.hooksPath alone and say so — wiring it to a directory
# without them would leave every git command ungated
R="$TMP/repo-nodispatch"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/ci" "$ROOT/package.json" "$R/"
rm -rf "$R/hooks/git-dispatch"
H="$TMP/nodispatch"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H" "$R"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'core.hooksPath NOT wired' "$H.out" && [ -z "$(gitconfig_hooks_path "$H")" ] \
  && pass "(15) without the git dispatchers core.hooksPath is not wired, and the run says so" \
  || bad "(15) no dispatchers: exit $rc, core.hooksPath [$(gitconfig_hooks_path "$H")]"

# (16) a ~/.zuvo that is not a directory: the enable-guard's stamp is a warning, never a dead installer
H="$TMP/zuvofile"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"; : > "$H/.zuvo"
claude_home "$H"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'plugin-enable-state could NOT be written' "$H.out" && [ "$(hooks_of "$H/.claude/settings.json")" = "$WANT_HOOKS" ] \
  && pass "(16) ~/.zuvo not a directory: the stamp is a warning, every hook still registers" \
  || bad "(16) ~/.zuvo a file: exit $rc [$(grep -i 'enable' "$H.out" | head -2 | tr '\n' '|')]"

# (17) a checkout without the merge script: each registration names the missing file
R="$TMP/repo-nomerge"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/ci" "$ROOT/package.json" "$R/"
rm -f "$R/scripts/install.d/claude_settings.py"
H="$TMP/nomerge"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H" "$R"; rc=$?
n_named=$(grep -c 'cannot read .*claude_settings.py' "$H.out")
[ "$rc" -eq 0 ] && [ "$n_named" -eq 4 ] && cmp -s <(printf '{}\n') "$H/.claude/settings.json" \
  && pass "(17) without claude_settings.py: all four registrations name the missing merge script, settings untouched" \
  || bad "(17) no merge script: exit $rc, named x$n_named"

# (18) the merge's own retry, driven deterministically through its functions: a file that keeps changing
# under every attempt ends in status 3 with that cause and nothing written; one that changes ONCE is
# merged on the next attempt.
H="$TMP/retry"; mkdir -p "$H"
retry_out="$(HOME="$H" python3 - "$ROOT/scripts/install.d/claude_settings.py" "$H" <<'PY'
import importlib.util, io, json, os, sys, contextlib
spec = importlib.util.spec_from_file_location('claude_settings', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = sys.argv[2]; path = os.path.join(home, 'settings.json')
real_replace = m.replace_checked
def run(replace):
    with open(path, 'w') as f:
        f.write('{}\n')
    m.replace_checked = replace
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = m.merge(path, os.path.join(home, 'h.sh'), 'Stop', '-', '5', 'h')
    return rc, out.getvalue(), json.load(open(path))
rc, out, data = run(lambda *a: False)
print('always', rc, 'kept changing during the merge (3 attempts)' in out, data == {})
calls = []
def once(*a):
    calls.append(1)
    return False if len(calls) == 1 else real_replace(*a)
rc, out, data = run(once)
print('once', rc, len(calls), [h['command'] for g in data['hooks']['Stop'] for h in g['hooks']])
PY
)"
[ "$(printf '%s\n' "$retry_out" | sed -n 1p)" = "always 3 True True" ] \
  && [ "$(printf '%s\n' "$retry_out" | sed -n 2p)" = "once 0 2 ['\$HOME/h.sh']" ] \
  && pass "(18) a file changing under every attempt: status 3, the cause said, nothing written; changing once: merged on the retry" \
  || bad "(18) merge retry: [$(printf '%s' "$retry_out" | tr '\n' '|')]"

# (19) the farm guard's two refusals: its file did not land (a directory sits where it goes) or cannot
# be made executable (a chmod stand-in refuses exactly that path). Either way it is not registered, the
# run says which, and the other three hooks still register.
H="$TMP/farm-nocopy"; mkdir -p "$H/.claude/hooks/farm-no-local-tests.sh"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H"; rc=$?
got="$(hooks_of "$H/.claude/settings.json")"
[ "$rc" -eq 0 ] && grep -q 'farm-no-local-tests.sh was not copied to ~/.claude/hooks — registration skipped' "$H.out" \
  && ! printf '%s\n' "$got" | grep -q 'farm-no-local-tests.sh' && [ "$(printf '%s\n' "$got" | grep -c .)" -eq 3 ] \
  && pass "(19) farm guard file not copied: not registered, said so, the other three hooks registered" \
  || bad "(19) farm guard not copied: exit $rc [$(printf '%s' "$got" | tr '\n' '|')]"
CHSTUB="$TMP/chmod-stub"; mkdir -p "$CHSTUB"
printf '#!/bin/sh\ncase "$*" in *farm-no-local-tests.sh*) exit 1 ;; esac\nexec %s "$@"\n' "$(command -v chmod)" > "$CHSTUB/chmod"
chmod +x "$CHSTUB/chmod"
H="$TMP/farm-nochmod"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
env -i PATH="$CHSTUB:$PATH" HOME="$H" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$H/.gitconfig" \
  GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$H/.config" \
  "$BASH" -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude_home' _ "$ROOT/scripts/install.sh" > "$H.out" 2>&1; rc=$?
got="$(hooks_of "$H/.claude/settings.json")"
[ "$rc" -eq 0 ] && grep -q 'farm-no-local-tests.sh is not executable — registration skipped' "$H.out" \
  && ! printf '%s\n' "$got" | grep -q 'farm-no-local-tests.sh' && [ "$(printf '%s\n' "$got" | grep -c .)" -eq 3 ] \
  && pass "(19b) farm guard not executable: not registered, said so, the other three hooks registered" \
  || bad "(19b) farm guard chmod refused: exit $rc [$(grep -i farm "$H.out" | head -2 | tr '\n' '|')]"

# (20) the dispatchers installed but one of the gates they chain did not: core.hooksPath stays unwired —
# live dispatchers without their gates would run every git command ungated
R="$TMP/repo-nogate"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/ci" "$ROOT/package.json" "$R/"
rm -f "$R/hooks/refactor-safety-gate.sh"
H="$TMP/nogate"; mkdir -p "$H/.claude"; printf '{}\n' > "$H/.claude/settings.json"
claude_home "$H" "$R"; rc=$?
[ "$rc" -eq 0 ] && [ -x "$H/.claude/hooks/pre-push" ] && grep -q 'core.hooksPath NOT wired' "$H.out" && [ -z "$(gitconfig_hooks_path "$H")" ] \
  && pass "(20) dispatchers present but a gate missing: core.hooksPath is not wired, and the run says so" \
  || bad "(20) gate missing: exit $rc, core.hooksPath [$(gitconfig_hooks_path "$H")]"

# (21) the replace's own byte check, driven through replace_checked itself (case 18 swaps the whole
# function out): a file whose bytes are no longer the ones read is left exactly as it is, False, no temp
# file left beside it; a file still holding them is replaced with the merged settings, True.
H="$TMP/bytecheck"; mkdir -p "$H"
check_out="$(python3 - "$ROOT/scripts/install.d/claude_settings.py" "$H" <<'PY'
import importlib.util, json, os, sys
spec = importlib.util.spec_from_file_location('claude_settings', sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
home = sys.argv[2]; path = os.path.join(home, 'settings.json')
with open(path, 'w') as f:
    f.write('{"theirs": 1}\n')
changed = m.replace_checked(path, {'mine': 1}, b'{}\n')
print('changed', changed, open(path).read() == '{"theirs": 1}\n', sorted(os.listdir(home)))
same = m.replace_checked(path, {'mine': 1}, b'{"theirs": 1}\n')
print('same', same, json.load(open(path)), sorted(os.listdir(home)))
PY
)"
[ "$(printf '%s\n' "$check_out" | sed -n 1p)" = "changed False True ['settings.json']" ] \
  && [ "$(printf '%s\n' "$check_out" | sed -n 2p)" = "same True {'mine': 1} ['settings.json']" ] \
  && pass "(21) replace_checked leaves a file whose bytes changed since the read untouched (False, no temp left) and replaces an unchanged one (True)" \
  || bad "(21) byte check: [$(printf '%s' "$check_out" | tr '\n' '|')]"

# (22) a lock that cannot be taken (~/.zuvo is a file, as a root-owned lock dir would also be) is SAID
# on one '  ! ' line naming the lock, and the merge still registers under the byte check
H="$TMP/nolock"; mkdir -p "$H"; : > "$H/.zuvo"; printf '{}\n' > "$H/settings.json"
out="$(HOME="$H" python3 "$ROOT/scripts/install.d/claude_settings.py" "$H/settings.json" "$H/h.sh" Stop - 5 h 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "^  ! could not take $H/.zuvo/locks/claude-settings.lock" \
  && printf '%s' "$out" | grep -q '^  ✓ h registered' && [ "$(hooks_of "$H/settings.json")" = "Stop - 5 h.sh" ] \
  && pass "(22) a lock that cannot be taken is said, naming it, and the merge still registers the hook" \
  || bad "(22) no lock: status $rc [$(printf '%s' "$out" | tr '\n' '|')] hooks [$(hooks_of "$H/settings.json" | tr '\n' '|')]"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
