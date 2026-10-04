#!/usr/bin/env bash
# The host installers must touch only what zuvo put there, and must work from any HOME.
#   (1) cursor: the duplicate cleanup (Claude Code's cache exists, and Cursor reads it) removes zuvo's
#       skills and agents only. It used to `rm -rf` ~/.cursor/skills and ~/.cursor/agents whole, so the
#       user's own skills and agents went with them;
#   (2) codex: a ~/.codex/hooks.json that does not parse is left as it is, and said (it used to be
#       replaced by `{}` plus zuvo's poll guard, dropping every hook the user had registered); a
#       symlinked one is written through; the user's hooks in a shared group are kept;
#   (3) claude: a HOME containing a space syncs every plugin-cache dir. The dir list was word-split,
#       so each path broke apart at the space.
#
# Test level: MEDIUM — the real builds into a sandbox dist root and the real installers in sandbox
# HOMEs (install.sh sourced, each install_* run under set -euo pipefail as the main run calls it); no
# network, nothing outside $TMP.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }
[ -n "${BASH:-}" ] || BASH="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }

# host_run <install function> <home> — the function in a fresh shell that sourced install.sh with
# HOME=<home>; output to <home>.out, the function's status returned.
host_run() {
  local fn="$1" h="$2"
  env -i PATH="$PATH" HOME="$h" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$h/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$h/.config" ZUVO_DIST_ROOT="$TMP/dist" \
    "$BASH" -c '. "$1" >/dev/null 2>&1 || exit 97; set -euo pipefail; "$2"' _ "$ROOT/scripts/install.sh" "$fn" \
    > "$h.out" 2>&1
}

# --- (1) cursor -------------------------------------------------------------------------------
# (1b) runs first: it builds dist/cursor, whose skill and agent names (1a) needs. Without Claude Code's
# cache zuvo's skills stay, each marked as zuvo's and its agents listed in the manifest; a second run,
# after the cache appears, removes exactly what the manifest and the markers name — and the user's own.
H="$TMP/cursor-two-runs"
mkdir -p "$H/.cursor/skills/my-own-skill" "$H/.cursor/agents"
printf '# mine\n' > "$H/.cursor/skills/my-own-skill/SKILL.md"
printf '# my agent\n' > "$H/.cursor/agents/my-own-agent.md"     # a name the old *-*.md test matched
host_run install_cursor "$H"; rc1=$?
n_dist_agents=$(ls "$TMP/dist/cursor/agents"/*.md 2>/dev/null | wc -l | tr -d ' ')
first_ok=no
[ "$n_dist_agents" -gt 0 ] && [ -f "$H/.cursor/skills/review/SKILL.md" ] && [ -f "$H/.cursor/skills/review/.zuvo-owned" ] \
  && [ ! -e "$H/.cursor/skills/my-own-skill/.zuvo-owned" ] \
  && [ "$(grep -c . "$H/.cursor/agents/.zuvo-agents" 2>/dev/null)" -eq "$n_dist_agents" ] \
  && ! grep -qx 'my-own-agent.md' "$H/.cursor/agents/.zuvo-agents" && first_ok=yes
cp "$H/.cursor/agents/.zuvo-agents" "$TMP/cursor-manifest" 2>/dev/null || : > "$TMP/cursor-manifest"
mkdir -p "$H/.claude/plugins/cache/zuvo-marketplace"
host_run install_cursor "$H"; rc2=$?
listed_left=""
while IFS= read -r a; do [ -n "$a" ] && [ -e "$H/.cursor/agents/$a" ] && listed_left="$listed_left $a"; done < "$TMP/cursor-manifest"
marked_left=""; for d in "$H"/.cursor/skills/*/; do [ -f "$d/.zuvo-owned" ] && marked_left="$marked_left ${d%/}"; done
[ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$first_ok" = yes ] && [ -s "$TMP/cursor-manifest" ] && [ -z "$listed_left" ] \
  && [ -z "$marked_left" ] && [ ! -e "$H/.cursor/agents/.zuvo-agents" ] \
  && [ -f "$H/.cursor/skills/my-own-skill/SKILL.md" ] && [ -f "$H/.cursor/agents/my-own-agent.md" ] \
  && pass "(1b) cursor marks its skills and lists its $n_dist_agents agents; a later dedup removes exactly those and keeps the user's own" \
  || bad "(1b) cursor two runs: exits $rc1/$rc2, dist agents $n_dist_agents, first run marked+listed: $first_ok, listed left [$listed_left], marked left [$marked_left] [$(tail -2 "$H.out" | tr '\n' '|')]"

# (1a) the upgrade every existing user makes: no markers yet (installs before this fix wrote none),
# Claude Code's cache present, zuvo's leftovers from an older install (a skill dir and an agent named
# as zuvo ships them) beside the user's own skill and agent. The leftovers go; the user's stay.
H="$TMP/cursor-upgrade"
legacy_agent="$(cd "$TMP/dist/cursor/agents" 2>/dev/null && ls -- *.md 2>/dev/null | head -1)"
mkdir -p "$H/.cursor/skills/my-own-skill" "$H/.cursor/skills/review" "$H/.cursor/agents" "$H/.claude/plugins/cache/zuvo-marketplace"
printf '# mine\n' > "$H/.cursor/skills/my-own-skill/SKILL.md"
printf '# zuvo review, from an older install\n' > "$H/.cursor/skills/review/SKILL.md"
printf '# my agent\n' > "$H/.cursor/agents/my-own-agent.md"
[ -n "$legacy_agent" ] && printf '# older zuvo agent\n' > "$H/.cursor/agents/$legacy_agent"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$legacy_agent" ] && [ -f "$H/.cursor/skills/my-own-skill/SKILL.md" ] && [ -f "$H/.cursor/agents/my-own-agent.md" ] \
  && [ ! -e "$H/.cursor/skills/review" ] && [ ! -e "$H/.cursor/agents/$legacy_agent" ] && [ -f "$H/.cursor/skills/.zuvo-provenance" ] \
  && pass "(1a) the first run with Claude Code's cache removes zuvo's unmarked leftovers by name, once, and keeps the user's skill and agent" \
  || bad "(1a) cursor upgrade: exit $rc, legacy agent [$legacy_agent], user skill $([ -f "$H/.cursor/skills/my-own-skill/SKILL.md" ] && echo kept || echo GONE), user agent $([ -f "$H/.cursor/agents/my-own-agent.md" ] && echo kept || echo GONE), zuvo review $([ -e "$H/.cursor/skills/review" ] && echo LEFT || echo removed) [$(tail -2 "$H.out" | tr '\n' '|')]"

# (1c) without the cache, a zuvo-owned skill and a listed agent that this release no longer ships are
# pruned (they would otherwise stay loaded forever); the user's own are not touched.
H="$TMP/cursor-prune"
mkdir -p "$H/.cursor/skills/retired-skill" "$H/.cursor/skills/my-own-skill" "$H/.cursor/agents"
printf 'zuvo-owned\n' > "$H/.cursor/skills/retired-skill/.zuvo-owned"
printf '# retired\n' > "$H/.cursor/skills/retired-skill/SKILL.md"
printf '# mine\n' > "$H/.cursor/skills/my-own-skill/SKILL.md"
printf 'x\n' > "$H/.cursor/skills/.zuvo-provenance"
printf '# retired\n' > "$H/.cursor/agents/retired-agent.md"
printf '# my agent\n' > "$H/.cursor/agents/my-own-agent.md"
printf 'retired-agent.md\n../escape.md\n..\n' > "$H/.cursor/agents/.zuvo-agents"
printf 'outside\n' > "$H/.cursor/escape.md"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.cursor/skills/retired-skill" ] && [ ! -e "$H/.cursor/agents/retired-agent.md" ] \
  && [ -f "$H/.cursor/skills/my-own-skill/SKILL.md" ] && [ -f "$H/.cursor/agents/my-own-agent.md" ] \
  && [ -f "$H/.cursor/escape.md" ] && [ -f "$H/.cursor/skills/review/.zuvo-owned" ] \
  && pass "(1c) zuvo-owned skills and listed agents this release no longer ships are pruned; the user's and anything outside ~/.cursor/agents stay" \
  || bad "(1c) cursor prune: exit $rc, retired skill $([ -e "$H/.cursor/skills/retired-skill" ] && echo LEFT || echo pruned), retired agent $([ -e "$H/.cursor/agents/retired-agent.md" ] && echo LEFT || echo pruned), outside file $([ -f "$H/.cursor/escape.md" ] && echo kept || echo DELETED) [$(tail -2 "$H.out" | tr '\n' '|')]"

# --- (2) codex: ~/.codex/hooks.json ---------------------------------------------------------------
GUARD_MATCHER='Bash|exec|shell|local_shell'
# guard_count <hooks.json> — how many registrations of the poll guard, under its matcher, as a command.
guard_count() {
  python3 - "$1" "$GUARD_MATCHER" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for g in d['hooks']['PreToolUse'] if g.get('matcher') == sys.argv[2]
          for h in g['hooks'] if h.get('type') == 'command' and 'codex-poll-guard.sh' in h.get('command', '')))
PY
}
# (2a) a hooks.json that does not parse is left byte-identical, the run says why it did not register,
# and the rest of the Codex install still happens.
H="$TMP/codex-malformed"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"
printf '{"hooks": {"PreToolUse": [ {"matcher": "Bash", "hooks": [ broken\n' > "$H/.codex/hooks.json"
cp "$H/.codex/hooks.json" "$TMP/codex-malformed.before"
host_run install_codex "$H"; rc=$?
[ "$rc" -eq 0 ] && cmp -s "$TMP/codex-malformed.before" "$H/.codex/hooks.json" \
  && grep -q 'hooks.json does not parse' "$H.out" && grep -q 'could not register the poll guard' "$H.out" \
  && [ -f "$H/.codex/skills/review/SKILL.md" ] \
  && pass "(2a) a malformed ~/.codex/hooks.json is left byte-identical, the skipped registration is reported, the skills still install" \
  || bad "(2a) malformed hooks.json: exit $rc, file $(cmp -s "$TMP/codex-malformed.before" "$H/.codex/hooks.json" && echo untouched || echo REWRITTEN) [$(grep -i 'hooks.json\|poll guard' "$H.out" | head -3 | tr '\n' '|')]"

# (2b) a valid one keeps the user's hooks and other keys; two runs register the guard once, under its
# matcher, as `bash <script>`.
H="$TMP/codex-valid"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"
printf '%s\n' '{"other": 1, "hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}]}]}}' \
  > "$H/.codex/hooks.json"
host_run install_codex "$H"; rc=$?
host_run install_codex "$H"; rc2=$?
if [ "$rc" -eq 0 ] && [ "$rc2" -eq 0 ] && [ "$(guard_count "$H/.codex/hooks.json")" = 1 ] && python3 - "$H/.codex/hooks.json" "$H" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
assert d['other'] == 1
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
assert cmds.count('echo mine') == 1, cmds
assert ('bash %s/.codex/hooks/codex-poll-guard.sh' % sys.argv[2]) in cmds, cmds
PY
then
  pass "(2b) a valid ~/.codex/hooks.json keeps the user's hook and keys; two runs register the guard once, under its matcher"
else
  bad "(2b) valid hooks.json: exits $rc/$rc2 [$(tr -d '\n' < "$H/.codex/hooks.json" | cut -c1-300)]"
fi

# (2c) a symlinked hooks.json (a dotfile manager) is written THROUGH: the link stays, its target gets
# the guard; a group the user shares with an older guard entry keeps the user's hook.
H="$TMP/codex-symlink"; mkdir -p "$H/.codex/skills" "$H/.codex/agents" "$H/dotfiles"
printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo mine"}, {"type": "command", "command": "bash /old/path/codex-poll-guard.sh"}]}]}}' \
  > "$H/dotfiles/hooks.json"
ln -s ../dotfiles/hooks.json "$H/.codex/hooks.json"
host_run install_codex "$H"; rc=$?
if [ "$rc" -eq 0 ] && [ -L "$H/.codex/hooks.json" ] && [ "$(guard_count "$H/dotfiles/hooks.json")" = 1 ] \
   && python3 - "$H/dotfiles/hooks.json" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks']]
assert 'echo mine' in cmds and 'bash /old/path/codex-poll-guard.sh' not in cmds, cmds
PY
then
  pass "(2c) a symlinked hooks.json is written through (link kept); the user's hook in a shared group survives, the old guard entry is replaced"
else
  bad "(2c) symlinked hooks.json: exit $rc, link $([ -L "$H/.codex/hooks.json" ] && echo kept || echo REPLACED) [$(tr -d '\n' < "$H/dotfiles/hooks.json" | cut -c1-300)]"
fi

# (2d) an EMPTY hooks.json holds nothing to lose: it gets the guard instead of being refused for good.
H="$TMP/codex-empty"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"; : > "$H/.codex/hooks.json"
host_run install_codex "$H"; rc=$?
[ "$rc" -eq 0 ] && [ "$(guard_count "$H/.codex/hooks.json" 2>/dev/null)" = 1 ] \
  && pass "(2d) an empty ~/.codex/hooks.json gets the poll guard" \
  || bad "(2d) empty hooks.json: exit $rc [$(grep -i 'hooks.json\|poll guard' "$H.out" | head -2 | tr '\n' '|')]"

# (2e) a HOME with a space: the guard's command quotes its path, so the shell runs the right file.
H="$TMP/codex home"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"
host_run install_codex "$H"; rc=$?
if [ "$rc" -eq 0 ] && python3 - "$H/.codex/hooks.json" "$H" <<'PY'
import json, shlex, sys
d = json.load(open(sys.argv[1]))
cmds = [h['command'] for g in d['hooks']['PreToolUse'] for h in g['hooks'] if 'codex-poll-guard' in h['command']]
assert cmds == ['bash ' + shlex.quote(sys.argv[2] + '/.codex/hooks/codex-poll-guard.sh')], cmds
assert shlex.split(cmds[0])[1] == sys.argv[2] + '/.codex/hooks/codex-poll-guard.sh'
PY
then
  pass "(2e) from a HOME with a space the poll guard's command quotes the script path"
else
  bad "(2e) HOME with a space: exit $rc [$(grep -iE 'poll guard|hooks.json|fail' "$H.out" | head -3 | tr '\n' '|')]"
fi

# --- (3) claude: a HOME with a space ------------------------------------------------------------
# Two cache dirs shaped like the ones Claude Code creates (install_claude syncs into every existing dir).
H="$TMP/home with space"
for v in 0.0.1 0.0.2; do
  seed="$H/.claude/plugins/cache/zuvo-marketplace/zuvo/$v"
  mkdir -p "$seed/skills/old-skill" "$seed/shared/includes" "$seed/rules" "$seed/scripts" "$seed/bin" "$seed/docs"
  printf '# old seed %s\n' "$v" > "$seed/skills/old-skill/SKILL.md"
done
printf '{\n  "plugins": {\n    "zuvo@zuvo-marketplace": [\n      {"version": "0.0.1", "gitCommitSha": "0000000"}\n    ]\n  }\n}\n' \
  > "$H/.claude/plugins/installed_plugins.json"
host_run install_claude "$H"; rc=$?
CB="$H/.claude/plugins/cache/zuvo-marketplace/zuvo"
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/package.json")"
synced=0; for v in 0.0.2 "$VERSION"; do [ -f "$CB/$v/skills/build/SKILL.md" ] && synced=$((synced + 1)); done
[ "$rc" -eq 0 ] && [ "$synced" -eq 2 ] && [ ! -e "$TMP/home" ] && [ ! -e "$CB/0.0.1" ] \
  && pass "(3) from a HOME containing a space, install_claude syncs every cache dir and prunes the oldest" \
  || bad "(3) HOME with a space: exit $rc, dirs synced $synced/2, fragment '$TMP/home' $([ -e "$TMP/home" ] && echo CREATED || echo absent) [$(grep -iE 'fail|error|No such' "$H.out" | head -3 | tr '\n' '|')]"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
