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

# host_run <install function> <home> [<repo root>] — the function in a fresh shell that sourced
# <repo>/scripts/install.sh with HOME=<home>; output to <home>.out, the function's status returned.
# The build root is $TMP/dist unless HR_DIST names another (the stub-build cases keep theirs apart).
host_run() {
  local fn="$1" h="$2" repo="${3:-$ROOT}"
  env -i PATH="$PATH" HOME="$h" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$h/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$h/.config" ZUVO_DIST_ROOT="${HR_DIST:-$TMP/dist}" \
    "$BASH" -c '. "$1" >/dev/null 2>&1 || exit 97; set -euo pipefail; "$2"' _ "$repo/scripts/install.sh" "$fn" \
    > "$h.out" 2>&1
}

# --- (1) cursor -------------------------------------------------------------------------------
# The Cursor distribution every cursor case reads names from, built ONCE here as an explicit fixture
# (install_cursor rebuilds into the same dir), so no case depends on another having run first.
ZUVO_DIST_ROOT="$TMP/dist" bash "$ROOT/scripts/build-cursor-skills.sh" "$ROOT" >"$TMP/cursor-build.log" 2>&1 \
  || bad "(1) fixture: the cursor build failed [$(tail -2 "$TMP/cursor-build.log" | tr '\n' '|')]"
# (1b) Without Claude Code's
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

# (1d) no ~/.cursor: the installer skips Cursor and creates nothing
H="$TMP/cursor-absent"; mkdir -p "$H"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && grep -q 'Cursor not installed' "$H.out" && [ ! -e "$H/.cursor" ] \
  && pass "(1d) without ~/.cursor the installer skips Cursor and creates nothing" \
  || bad "(1d) absent Cursor: exit $rc, ~/.cursor $([ -e "$H/.cursor" ] && echo CREATED || echo absent)"

# (1e) after adoption is spent (.zuvo-provenance present), an UNMARKED directory with a zuvo skill's name
# is somebody else's: skipped with a warning and left byte for byte, while zuvo's other skills install
H="$TMP/cursor-collision"
mkdir -p "$H/.cursor/skills/review" "$H/.cursor/agents"
printf '# the user review skill\n' > "$H/.cursor/skills/review/SKILL.md"
printf 'x\n' > "$H/.cursor/skills/.zuvo-provenance"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && grep -q "skipped 'review'" "$H.out" && [ "$(cat "$H/.cursor/skills/review/SKILL.md")" = '# the user review skill' ] \
  && [ ! -e "$H/.cursor/skills/review/.zuvo-owned" ] && [ -f "$H/.cursor/skills/using-zuvo/.zuvo-owned" ] \
  && pass "(1e) after adoption, an unmarked same-named skill is skipped and left as it was; the rest install" \
  || bad "(1e) name collision: exit $rc, user review [$(head -1 "$H/.cursor/skills/review/SKILL.md" 2>/dev/null)] [$(grep -i "skipped\|review" "$H.out" | head -2 | tr '\n' '|')]"

# (1f) a build that fails stops the Cursor install before anything in ~/.cursor changes
R="$TMP/repo-badbuild"; mkdir -p "$R"
cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/package.json" "$R/"
printf '#!/bin/sh\necho "simulated build failure" >&2\nexit 1\n' > "$R/scripts/build-cursor-skills.sh"
H="$TMP/cursor-badbuild"; mkdir -p "$H/.cursor/skills/my-own-skill"
printf '# mine\n' > "$H/.cursor/skills/my-own-skill/SKILL.md"
host_run install_cursor "$H" "$R"; rc=$?
[ "$rc" -ne 0 ] && grep -q 'Build failed' "$H.out" && grep -q 'simulated build failure' "$H.out" \
  && [ "$(ls -A "$H/.cursor/skills")" = my-own-skill ] \
  && pass "(1f) a failing Cursor build stops the install (status $rc), its output shown, ~/.cursor untouched" \
  || bad "(1f) failing build: exit $rc, skills now [$(ls -A "$H/.cursor/skills" | tr '\n' ' ')]"

# (1g)-(1i) run a stub build (in a repo copy, into its own dist root) so the dist's shape is the case.
# stub_build <repo> <shape: noskills | noagents | locked> — replace the Cursor build with one that emits that shape.
stub_build() {
  local r="$1"; mkdir -p "$r"; cp -R "$ROOT/scripts" "$ROOT/hooks" "$ROOT/package.json" "$r/"
  {
    printf '#!/bin/sh\nd="$ZUVO_DIST_ROOT/cursor"; rm -rf "$d"; mkdir -p "$d/agents"\n'
    case "$2" in
      noagents) printf 'mkdir -p "$d/skills/stub-skill"; printf "# stub\\n" > "$d/skills/stub-skill/SKILL.md"\n' ;;
      locked) printf 'mkdir -p "$d/skills/stub-skill"; printf "# stub\\n" > "$d/skills/stub-skill/SKILL.md"\n'
              printf 'printf "x\\n" > "$d/skills/stub-skill/locked.md"; chmod 000 "$d/skills/stub-skill/locked.md"\n'
              printf 'printf "# a\\n" > "$d/agents/stub-agent.md"\n' ;;
    esac
    printf 'exit 0\n'
  } > "$r/scripts/build-cursor-skills.sh"
}
# (1g) a build that exits 0 but produced no skills is a failed build: status 1, said, ~/.cursor untouched
R="$TMP/repo-noskills"; stub_build "$R" noskills
H="$TMP/cursor-noskills"; mkdir -p "$H/.cursor/skills/my-own-skill"; printf '# mine\n' > "$H/.cursor/skills/my-own-skill/SKILL.md"
HR_DIST="$TMP/dist-noskills" host_run install_cursor "$H" "$R"; rc=$?
[ "$rc" -eq 1 ] && grep -q 'no dist/cursor/skills/ produced' "$H.out" && [ "$(ls -A "$H/.cursor/skills")" = my-own-skill ] \
  && pass "(1g) a build that produced no skills fails the Cursor install (status 1, said) and leaves ~/.cursor as it was" \
  || bad "(1g) build without skills: exit $rc [$(grep -i 'build' "$H.out" | head -2 | tr '\n' '|')]"

# (1h) the claude-code-toolkit era left symlinks in ~/.cursor; they are removed — a regular file under
# one of those names is the user's and stays
H="$TMP/cursor-symlinks"; mkdir -p "$H/.cursor"
ln -s /nonexistent/CLAUDE.md "$H/.cursor/CLAUDE.md"; ln -s /nonexistent/review-protocol.md "$H/.cursor/review-protocol.md"
printf '# my own notes\n' > "$H/.cursor/test-patterns.md"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -L "$H/.cursor/CLAUDE.md" ] && [ ! -L "$H/.cursor/review-protocol.md" ] \
  && [ "$(cat "$H/.cursor/test-patterns.md")" = '# my own notes' ] && grep -q 'Cleaned 2 old toolkit symlinks' "$H.out" \
  && pass "(1h) the two toolkit-era symlinks are removed and counted; a regular file of a toolkit name stays" \
  || bad "(1h) toolkit symlinks: exit $rc [$(grep -i 'symlink' "$H.out" | tr '\n' '|')]"

# (1i) a skill that does not copy completely is said, counted, and still marked zuvo's (so the next run
# can repair or remove it)
if [ "$(id -u)" = 0 ]; then
  printf 'SKIP: %s\n' "(1i) not run under root (a mode-000 file is readable by root)"
else
  R="$TMP/repo-locked"; stub_build "$R" locked
  H="$TMP/cursor-locked"; mkdir -p "$H/.cursor"
  HR_DIST="$TMP/dist-locked" host_run install_cursor "$H" "$R"; rc=$?
  chmod 644 "$TMP/dist-locked/cursor/skills/stub-skill/locked.md" 2>/dev/null
  [ "$rc" -eq 0 ] && grep -q "skill 'stub-skill' did not copy completely" "$H.out" && grep -q '1 incomplete' "$H.out" \
    && [ -f "$H/.cursor/skills/stub-skill/.zuvo-owned" ] && [ -f "$H/.cursor/skills/stub-skill/SKILL.md" ] \
    && pass "(1i) an incomplete skill copy is said and counted, and the directory is still marked zuvo's" \
    || bad "(1i) incomplete copy: exit $rc [$(grep -iE 'stub-skill|incomplete' "$H.out" | head -3 | tr '\n' '|')]"
fi

# (1j) after adoption is spent, an agent file the user wrote under a zuvo agent's name (not in the
# manifest) is skipped and left byte for byte; zuvo's other agents install and are listed
H="$TMP/cursor-agent-collision"; mkdir -p "$H/.cursor/skills" "$H/.cursor/agents"
coll_agent="$(cd "$TMP/dist/cursor/agents" 2>/dev/null && ls -- *.md 2>/dev/null | head -1)"
printf 'x\n' > "$H/.cursor/skills/.zuvo-provenance"
printf 'other.md\n' > "$H/.cursor/agents/.zuvo-agents"
[ -n "$coll_agent" ] && printf '# my agent, same name\n' > "$H/.cursor/agents/$coll_agent"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -n "$coll_agent" ] && grep -q "skipped agent '$coll_agent'" "$H.out" \
  && [ "$(cat "$H/.cursor/agents/$coll_agent")" = '# my agent, same name' ] && ! grep -qx "$coll_agent" "$H/.cursor/agents/.zuvo-agents" \
  && [ "$(grep -c . "$H/.cursor/agents/.zuvo-agents")" -gt 1 ] \
  && pass "(1j) a user's agent under a zuvo agent's name is skipped and kept; the rest install and are listed" \
  || bad "(1j) agent collision [$coll_agent]: exit $rc [$(grep -i 'skipped agent' "$H.out" | head -2 | tr '\n' '|')]"

# (1k) a build that ships skills but NO agents keeps the previous manifest (an empty one would make the
# next run treat every agent zuvo owns as a stranger's) and installs no agents
R="$TMP/repo-noagents"; stub_build "$R" noagents
H="$TMP/cursor-noagents"; mkdir -p "$H/.cursor/agents"; printf 'kept-agent.md\n' > "$H/.cursor/agents/.zuvo-agents"
HR_DIST="$TMP/dist-noagents" host_run install_cursor "$H" "$R"; rc=$?
[ "$rc" -eq 0 ] && [ "$(cat "$H/.cursor/agents/.zuvo-agents")" = 'kept-agent.md' ] && [ -f "$H/.cursor/skills/stub-skill/.zuvo-owned" ] \
  && ! grep -q 'Agents installed' "$H.out" \
  && pass "(1k) a build with no agents keeps the previous agent manifest and installs no agents" \
  || bad "(1k) no agents: exit $rc, manifest [$(tr '\n' ' ' < "$H/.cursor/agents/.zuvo-agents" 2>/dev/null)]"

# (1l) a symlinked skill dir is the user's even when zuvo's marker travelled with it (a skill moved into
# dotfiles and linked back): the prune neither follows it (`rm -rf link/` deletes the TARGET) nor removes
# the link, and a symlink sitting at a name this release ships is skipped, nothing written through it.
# Also: a manifest without its final newline still prunes its last agent.
H="$TMP/cursor-skill-links"
mkdir -p "$H/.cursor/skills" "$H/.cursor/agents" "$H/dotfiles/retired" "$H/dotfiles/review"
printf 'zuvo-owned\n' > "$H/dotfiles/retired/.zuvo-owned"; printf '# moved\n' > "$H/dotfiles/retired/SKILL.md"
printf '# my review\n' > "$H/dotfiles/review/SKILL.md"
ln -s ../../dotfiles/retired "$H/.cursor/skills/retired-linked"
ln -s ../../dotfiles/review "$H/.cursor/skills/review"
printf 'x\n' > "$H/.cursor/skills/.zuvo-provenance"
printf '# retired\n' > "$H/.cursor/agents/retired-agent.md"
printf 'retired-agent.md' > "$H/.cursor/agents/.zuvo-agents"          # no final newline
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -L "$H/.cursor/skills/retired-linked" ] && [ -f "$H/dotfiles/retired/SKILL.md" ] \
  && [ -L "$H/.cursor/skills/review" ] && [ "$(ls -A "$H/dotfiles/review")" = SKILL.md ] \
  && grep -q "skipped 'review' — .* is a symlink" "$H.out" && [ ! -e "$H/.cursor/agents/retired-agent.md" ] \
  && [ -f "$H/.cursor/skills/build/.zuvo-owned" ] \
  && pass "(1l) symlinked skill dirs are never pruned through or written through; a manifest without its final newline still prunes its last agent" \
  || bad "(1l) cursor symlinks: exit $rc, linked target $([ -f "$H/dotfiles/retired/SKILL.md" ] && echo kept || echo DELETED), review target [$(ls -A "$H/dotfiles/review" | tr '\n' ' ')], retired agent $([ -e "$H/.cursor/agents/retired-agent.md" ] && echo LEFT || echo pruned) [$(grep -iE 'symlink|skipped' "$H.out" | head -2 | tr '\n' '|')]"

# (1m) the same in the dedup cleanup (Claude Code's cache present): a marked skill reached through a
# symlink keeps its target and its link, while a real marked dir is removed
H="$TMP/cursor-dedup-symlink"
mkdir -p "$H/.cursor/skills/old-zuvo" "$H/.cursor/agents" "$H/dotfiles/linked" "$H/.claude/plugins/cache/zuvo-marketplace"
printf 'zuvo-owned\n' > "$H/.cursor/skills/old-zuvo/.zuvo-owned"
printf 'zuvo-owned\n' > "$H/dotfiles/linked/.zuvo-owned"; printf '# linked\n' > "$H/dotfiles/linked/SKILL.md"
ln -s ../../dotfiles/linked "$H/.cursor/skills/linked"
host_run install_cursor "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.cursor/skills/old-zuvo" ] && [ -L "$H/.cursor/skills/linked" ] && [ -f "$H/dotfiles/linked/SKILL.md" ] \
  && pass "(1m) the dedup cleanup removes a real marked dir and leaves a symlinked one, link and target" \
  || bad "(1m) dedup symlink: exit $rc, old-zuvo $([ -e "$H/.cursor/skills/old-zuvo" ] && echo LEFT || echo removed), target $([ -f "$H/dotfiles/linked/SKILL.md" ] && echo kept || echo DELETED)"

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

# (2g) zuvo's entry is one that RUNS a codex-poll-guard.sh: a user's command that only mentions the
# name stays; earlier zuvo entries in other shapes (a bare string in a group's hooks, a flat group with
# its own "command") are replaced, not left beside a new one
H="$TMP/codex-shapes"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"
printf '%s\n' '{"hooks": {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "echo codex-poll-guard.sh is zuvo"}]}, {"matcher": "Bash", "hooks": ["bash /old/codex-poll-guard.sh"]}, {"matcher": "Bash", "command": "sh /older/codex-poll-guard.sh"}]}}' \
  > "$H/.codex/hooks.json"
host_run install_codex "$H"; rc=$?
if [ "$rc" -eq 0 ] && [ "$(guard_count "$H/.codex/hooks.json")" = 1 ] && python3 - "$H/.codex/hooks.json" <<'PY'
import json, sys
groups = json.load(open(sys.argv[1]))['hooks']['PreToolUse']
text = json.dumps(groups)
assert 'echo codex-poll-guard.sh is zuvo' in text and '/old/' not in text and '/older/' not in text, text
assert len(groups) == 2, groups
PY
then
  pass "(2g) a command that only mentions the guard is the user's and stays; zuvo's string and flat entries are replaced by one"
else
  bad "(2g) entry shapes: exit $rc [$(tr -d '\n' < "$H/.codex/hooks.json" | cut -c1-300)]"
fi

# (2h) a lock that cannot be taken (~/.zuvo is a file) is said, naming it, and the guard still registers
H="$TMP/codex-nolock"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"; : > "$H/.zuvo"
host_run install_codex "$H"; rc=$?
[ "$rc" -eq 0 ] && grep -q "could not take $H/.zuvo/locks/codex-hooks.lock" "$H.out" && [ "$(guard_count "$H/.codex/hooks.json")" = 1 ] \
  && pass "(2h) a lock that cannot be taken is said, and the poll guard still registers" \
  || bad "(2h) no lock: exit $rc [$(grep -iE 'lock|poll guard' "$H.out" | head -3 | tr '\n' '|')]"

# (2i) a dotfile link into a directory that does not exist yet: the directory is made and the file
# written through it, the link kept
H="$TMP/codex-dangling"; mkdir -p "$H/.codex/skills" "$H/.codex/agents"
ln -s ../dotfiles/codex/hooks.json "$H/.codex/hooks.json"
host_run install_codex "$H"; rc=$?
[ "$rc" -eq 0 ] && [ -L "$H/.codex/hooks.json" ] && [ "$(guard_count "$H/dotfiles/codex/hooks.json")" = 1 ] \
  && pass "(2i) a link into a missing directory: the directory is made, the guard written through, the link kept" \
  || bad "(2i) dangling link: exit $rc [$(grep -iE 'hooks.json|poll guard|Traceback|Error' "$H.out" | head -3 | tr '\n' '|')]"

# (2j) a write that lands between the read and the replace (Codex itself, an installer that could not
# take the lock) is not overwritten: the merge, run as codex.sh holds it, is given a mkstemp that writes
# the file first — deterministically inside that window — and must leave the other write in place
H="$TMP/codex-race"; mkdir -p "$H/.codex"
printf '%s\n' '{"hooks": {"PreToolUse": []}}' > "$H/.codex/hooks.json"
awk '/<<.PYHOOK.$/{f=1;next} /^PYHOOK$/{f=0} f' "$ROOT/scripts/install.d/codex.sh" > "$TMP/pyhook.py"
race_out="$(HOME="$H" python3 - "$TMP/pyhook.py" "$H/.codex/hooks.json" <<'PY' 2>&1
import sys, tempfile
body, target = sys.argv[1], sys.argv[2]
real_mkstemp = tempfile.mkstemp
def racing(*a, **k):
    with open(target, 'w') as f:
        f.write('{"theirs": 1}\n')
    return real_mkstemp(*a, **k)
tempfile.mkstemp = racing
sys.argv = ['-', target, '/g/codex-poll-guard.sh']
try:
    exec(compile(open(body).read(), 'pyhook', 'exec'), {'__name__': '__main__'})
    print('status 0')
except SystemExit as e:
    print('status', e.code)
PY
)"
[ -s "$TMP/pyhook.py" ] && printf '%s' "$race_out" | grep -q 'hooks.json changed during the merge — left as it is' \
  && printf '%s' "$race_out" | grep -q '^status 1$' && [ "$(cat "$H/.codex/hooks.json")" = '{"theirs": 1}' ] \
  && [ -z "$(ls -A "$H/.codex" | grep -v '^hooks.json$')" ] \
  && pass "(2j) a write landing between the read and the replace is kept: status 1, said, no temp file left" \
  || bad "(2j) concurrent write: [$(printf '%s' "$race_out" | tr '\n' '|' | cut -c1-300)] file [$(cat "$H/.codex/hooks.json")]"

# (2f) no ~/.codex: the installer skips Codex and creates nothing
H="$TMP/codex-absent"; mkdir -p "$H"
host_run install_codex "$H"; rc=$?
[ "$rc" -eq 0 ] && [ ! -e "$H/.codex" ] \
  && pass "(2f) without ~/.codex the installer skips Codex and creates nothing" \
  || bad "(2f) absent Codex: exit $rc, ~/.codex $([ -e "$H/.codex" ] && echo CREATED || echo absent) [$(head -3 "$H.out" | tr '\n' '|')]"

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
