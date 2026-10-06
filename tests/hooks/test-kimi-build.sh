#!/bin/bash
# Kimi Code build target — contract tests.
#
# The build script validates its own output and fails closed, so this suite does NOT
# re-assert what the build already gates. It covers the opposite risk: that someone
# maintaining five build targets copies a Cursor/Antigravity transform into the Kimi
# one and silently DEGRADES it. Kimi is the only non-Claude target with real parallel
# sub-agents, plan mode and AskUserQuestion; a degradation there is invisible — skills
# keep running, just single-agent and worse, while every build still reports success.
#
# Run: bash tests/hooks/test-kimi-build.sh   (also /bin/bash — bash 3.2)
#
# PER-RUN dist root (B-DIST-BUILD-RACE): the build lands in a sandbox this file creates, never in the
# shared $ROOT/dist that install.sh, test-install-wiring.sh and reviewer-model-builds.bats also write
# — the same two-variable pattern and literal-prefix teardown as scripts/tests/reviewer-model-builds.bats
# (whose dirname-derived cleanup once deleted this checkout). ZUVO_TEST_KIMI_BUILDER runs every build
# here with ANOTHER builder copy (a deliberately broken one, to show the cases are red there); the copy
# needs its lib/ beside it. Unset: tests/lib/dist-build.sh (cached) and scripts/build-kimi-skills.sh.

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
KIMI_BUILDER="${ZUVO_TEST_KIMI_BUILDER:-$ROOT/scripts/build-kimi-skills.sh}"
KIMI_SANDBOX="$(mktemp -d)"
[ -n "$KIMI_SANDBOX" ] && [ -d "$KIMI_SANDBOX" ] || {
  echo "  FAIL: mktemp -d failed — refusing to run with an unset sandbox" >&2
  exit 1
}
# Remove ONLY a path that still looks like the mktemp directory made above; anything else is refused
# out loud. No $TMPDIR arm: an unset TMPDIR would turn it into `/*` (see reviewer-model-builds.bats).
kimi_cleanup() {
  case "${KIMI_SANDBOX:-}" in
    /tmp/*|/var/folders/*) [ -d "$KIMI_SANDBOX" ] && rm -rf "$KIMI_SANDBOX" ;;
    *) echo "test-kimi-build: refusing to remove unexpected sandbox '${KIMI_SANDBOX:-}'" >&2 ;;
  esac
}
trap kimi_cleanup EXIT
ZUVO_DIST_ROOT="$KIMI_SANDBOX/dist"
export ZUVO_DIST_ROOT
DIST="$ZUVO_DIST_ROOT/kimi"

pass_count=0; fail_count=0
pass() { echo "  PASS: $1"; pass_count=$((pass_count + 1)); }
bad()  { echo "  FAIL: $1"; fail_count=$((fail_count + 1)); }

echo "=== kimi build target ==="

# (1) The build must succeed and be self-validating.
# tests/lib/dist-build.sh replays the build's exact log and exit code from a per-run
# cache when one exists, so this assertion still tests "the kimi build exits 0" — it
# just does not pay for a second full 57-skill build when a sibling already ran one.
# A stale library is planted in the build's scripts/lib/ first — (11b) asserts the build removed it.
KIMI_STALE="$DIST/scripts/lib/zz-removed-upstream.sh"
mkdir -p "${KIMI_STALE%/*}" && printf '# stale: removed from scripts/lib/ upstream\n' > "$KIMI_STALE"
# The premise of (11b): a plant that silently failed would leave nothing to be removed, and (11b) would
# pass on that.
if [ -f "$KIMI_STALE" ]; then pass "(11b) premise: the stale library is planted in the build's scripts/lib/ before the build"
else bad "(11b) premise: could not plant $KIMI_STALE — (11b) would pass on nothing"; fi
# A cache REPLAY (tests/lib/dist-build.sh, when an earlier caller in the same suite run — or a warm
# ZUVO_DIST_CACHE the harness passed in — already built kimi) rm -rf's the build dir and copies the
# cached tree back: the planted file disappears whatever the builder does, and (11b) passes on nothing.
# So the build goes through the helper with `--fresh`: the builder always runs, and the cache entry is
# refreshed from it.
kimi_build() {
  if [ -n "${ZUVO_TEST_KIMI_BUILDER:-}" ]; then bash "$KIMI_BUILDER" "$ROOT"
  else bash "$ROOT/tests/lib/dist-build.sh" --fresh kimi; fi
}
if build_log=$(kimi_build 2>&1); then
  pass "(1) build-kimi-skills.sh exits 0"
else
  bad "(1) build failed (tail: $(printf '%s' "$build_log" | tail -3))"
  echo "  -> remaining assertions would be vacuous; stopping"
  exit 1
fi

# (2) Sub-agent dispatch survives. Cursor and Antigravity rewrite spawn blocks into
#     "Execute inline: ..." because they lack sub-agents; Kimi has the Agent tool, so
#     that rewrite must NOT be present here.
if grep -rq 'Execute inline: read instructions from' "$DIST/skills" 2>/dev/null; then
  bad "(2) dist contains the inline-sequential rewrite — Kimi's sub-agents were degraded away"
else
  pass "(2) no inline-sequential rewrite (sub-agent dispatch preserved)"
fi

# (3) Agent profiles are actually shipped and flat. Kimi resolves profiles byName from a
#     single directory, so a subdirectory layout would load nothing.
agent_files=$(ls "$DIST"/agents/*.md 2>/dev/null | wc -l | tr -d ' ')
if [ "${agent_files:-0}" -ge 40 ]; then
  pass "(3) flat agent namespace populated ($agent_files profiles)"
else
  bad "(3) expected >=40 flat agent profiles, found ${agent_files:-0}"
fi
if [ -d "$DIST/skills/review/agents" ]; then
  bad "(3b) agents left in a skill subdirectory — Kimi would not discover them"
else
  pass "(3b) no per-skill agents/ subdirectories in dist"
fi

# (4) Kimi HAS these tools; the Cursor/Antigravity builds must strip them, this one must
#     not. Presence is asserted, NOT a source-vs-dist count: platform-block stripping
#     legitimately removes mentions that live inside other harnesses' sections, so a
#     count comparison fails for a correct build (it did, on the first version of this
#     test). The substitution check below is what actually catches a degradation.
#     Only tools the source uses are checked — ExitPlanMode appears zero times today,
#     and asserting it would be vacuous.
for tool in AskUserQuestion EnterPlanMode; do
  src_n=$( { grep -rho "$tool" "$ROOT"/skills/*/SKILL.md "$ROOT"/skills/*/agents/*.md "$ROOT"/shared/includes/*.md 2>/dev/null || true; } | wc -l | tr -d ' ')
  dst_n=$( { grep -rho "$tool" "$DIST"/skills "$DIST"/agents "$DIST"/shared 2>/dev/null || true; } | wc -l | tr -d ' ')
  if [ "${src_n:-0}" -eq 0 ]; then
    echo "  SKIP: (4) $tool absent from source — nothing to preserve"
  elif [ "${dst_n:-0}" -ge 1 ]; then
    pass "(4) $tool survives in dist ($dst_n mentions; Kimi supports it)"
  else
    bad "(4) $tool stripped from dist entirely ($src_n in source) — Kimi supports it"
  fi
done

# (4a) The Cursor/Antigravity builds replace AskUserQuestion with a canned
#      "[AUTO-DECISION: proceed with safest default]". Kimi can ask the user, so that
#      substitution appearing here means a run will silently guess instead of asking.
if grep -rqF '[AUTO-DECISION: proceed with safest default]' "$DIST" 2>/dev/null; then
  bad "(4a) dist contains the [AUTO-DECISION] substitution — Kimi can ask the user"
else
  pass "(4a) no [AUTO-DECISION] substitution (interactive prompts preserved)"
fi

# (4b) The dist must carry Kimi's platform guidance and NOT another harness's. Shipping
#      Codex's single-agent section to Kimi is the subtlest degradation available: nothing
#      breaks, runs just quietly stop dispatching because the prose told them to.
ENVC="$DIST/shared/includes/env-compat.md"
if [ -f "$ENVC" ]; then
  if grep -q '### Kimi Code' "$ENVC" && ! grep -q '### Codex' "$ENVC"; then
    pass "(4b) env-compat carries the Kimi section and not Codex's single-agent block"
  else
    bad "(4b) env-compat platform sections wrong (kimi=$(grep -c '### Kimi Code' "$ENVC"), codex=$(grep -c '### Codex' "$ENVC"))"
  fi
else
  bad "(4b) dist is missing shared/includes/env-compat.md"
fi

# (5) Tools Kimi does NOT have must be gone.
if grep -rq '\bTodoWrite\b\|\bMultiEdit\b' "$DIST/skills" "$DIST/agents" 2>/dev/null; then
  bad "(5) dist references TodoWrite/MultiEdit — neither exists in Kimi"
else
  pass "(5) no TodoWrite/MultiEdit references"
fi

# (6) model_preference is a closed enum in Kimi's loader ("primary" | "secondary");
#     anything else is a hard parse error that disables the agent.
bad_pref=$(grep -rh '^model_preference:' "$DIST"/agents/*.md 2>/dev/null \
  | grep -vcE '^model_preference: *"?(primary|secondary)"? *$' || true)
if [ "${bad_pref:-0}" -eq 0 ]; then
  pass "(6) every model_preference is primary|secondary"
else
  bad "(6) $bad_pref agent(s) carry an invalid model_preference"
fi

# (7) Hook template must use Kimi's flat [[hooks]] TOML shape, not the nested JSON one.
if [ -f "$DIST/hooks.kimi.toml" ]; then
  if grep -q '^\[\[hooks\]\]' "$DIST/hooks.kimi.toml"; then
    pass "(7) hooks template uses [[hooks]] array-of-tables"
  else
    bad "(7) hooks template has no [[hooks]] tables"
  fi
  # StopFailure is the rewake path. Kimi supports the event, so unlike Cursor/Antigravity
  # this target has no excuse to drop it.
  if grep -q 'StopFailure' "$DIST/hooks.kimi.toml"; then
    pass "(7b) StopFailure rewake hook is wired (Kimi supports the event)"
  else
    bad "(7b) StopFailure hook missing — the API-error rewake path is silently absent"
  fi
else
  bad "(7) dist/kimi/hooks.kimi.toml missing"
fi

# (8) install.sh must actually wire the target, in the case dispatch AND in `all`.
# The installer's TEXT is install.sh plus the scripts/install.d/ modules it sources; read it as one file.
. "$ROOT/tests/lib/installer-sources.sh"
# A text dump of install.sh + its install.d/ modules — read, never run (hence not $INSTALL).
INSTALL_TEXT="$KIMI_SANDBOX/installer-text.sh"
installer_text > "$INSTALL_TEXT" || { bad "(8) cannot assemble the installer text — stopping: (9) would pass on an empty file"; exit 1; }
if grep -q 'install_kimi()' "$INSTALL_TEXT" && grep -qE '^\s*kimi\)\s*install_kimi' "$INSTALL_TEXT"; then
  pass "(8) install.sh defines and dispatches install_kimi"
else
  bad "(8) install.sh does not define/dispatch install_kimi"
fi
if grep -qE 'both\|all\).*install_kimi' "$INSTALL_TEXT"; then
  pass '(8b) install_kimi runs as part of the "all" target'
else
  bad "(8b) install_kimi is missing from the 'all' target — a normal install would skip Kimi"
fi

# (9) Provenance: the shared user roots must never be blanket-deleted. ~/.kimi-code/skills
#     and /agents hold the user's own work too (this is the bug class that hit the
#     Antigravity target in 2026-08-11).
if grep -qE 'rm -rf "\$KIMI_SKILLS"|rm -rf "\$KIMI_AGENTS"' "$INSTALL_TEXT"; then
  bad "(9) install.sh blanket-deletes a shared Kimi root — third-party data loss"
else
  pass "(9) no blanket delete of the shared Kimi skills/agents roots"
fi
if grep -q 'KIMI_AGENT_MANIFEST' "$INSTALL_TEXT"; then
  pass "(9b) flat agent installs are manifest-tracked (prune + no-clobber)"
else
  bad "(9b) no agent manifest — stale agents cannot be pruned and user agents can be clobbered"
fi

# (10) Execute the real shell/Python boundary, not only the TOML template. Backticks
# inside a Python comment in a double-quoted shell argument still execute shell code.
if python3 - "$INSTALL_TEXT" "$DIST/hooks.kimi.toml" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import tempfile
try:
    import tomllib
except ModuleNotFoundError:
    tomllib = None

source = Path(sys.argv[1]).read_text()
try:
    start = source.index('  if [[ -f "$DIST/hooks.kimi.toml" ]]; then')
    end = source.index('\n  fi', start) + len('\n  fi')
except ValueError as exc:
    raise SystemExit('test (10) extraction marker is stale; inspect the installer block') from exc
snippet = source[start:end]
# Shell interpolation must stay off for arbitrary Python comments, not just `merged`.
snippet = snippet.replace('import os, sys, tempfile',
                          'import os, sys, tempfile\n# `merged` $(merged) $ZUVO_COMMENT_PROBE')
with tempfile.TemporaryDirectory() as directory:
    root = Path(directory)
    (root / 'hooks.kimi.toml').write_bytes(Path(sys.argv[2]).read_bytes())
    config = root / 'config.toml'
    config.write_text('provider = "keep-me"\n')
    env = dict(os.environ, DIST=directory, KIMI_HOME=directory)
    command = ('merged() { printf "UNEXPECTED_COMMAND_SUBSTITUTION\\n" >&2; }; '
               'warn() { printf "%s\\n" "$*" >&2; }; ' + snippet)
    previous = None
    for _ in range(2):
        run = subprocess.run(['bash', '-c', command], env=env, capture_output=True, text=True)
        assert run.returncode == 0, run.stderr
        assert not run.stderr, run.stderr
        actual = config.read_text()
        if tomllib is None:
            assert actual == 'provider = "keep-me"\n'
            assert 'cannot validate merged config.toml' in run.stdout
            continue
        parsed = tomllib.loads(actual)
        assert parsed['provider'] == 'keep-me'
        assert len(parsed['hooks']) == Path(sys.argv[2]).read_text().count('[[hooks]]')
        if previous is not None:
            assert actual == previous, 'hook installation is not idempotent'
        previous = actual
    # Exercise missing-parser safety even when the host has Python 3.11+.
    shim = root / 'no-parser'
    shim.mkdir()
    (shim / 'tomllib.py').write_text('raise ModuleNotFoundError("test: no tomllib")\n')
    before = config.read_bytes()
    run = subprocess.run(['bash', '-c', command], env=dict(env, PYTHONPATH=str(shim)),
                         capture_output=True, text=True)
    assert run.returncode == 0 and not run.stderr, run.stderr
    assert 'cannot validate merged config.toml' in run.stdout
    assert config.read_bytes() == before, 'missing parser changed user configuration'
PY
then
  pass '(10) hook merge preserves user config, is idempotent, and executes no comment text'
else
  bad '(10) real hook merge failed or executed Python comment text as a shell command'
fi

# (11) The dist ships the shared reviewer runner BESIDE the driver it ships. install_kimi copies
#      dist/scripts/ to ~/.kimi-code/scripts/, and that adversarial-review.sh looks for
#      scripts/lib/model-subprocess.sh first; without it the Kimi install's codex and claude review
#      lanes fail (tests/hooks/test-install-wiring.sh (14) pins the install half). The contract is
#      the WHOLE scripts/lib/ dir (every regular file, byte-identical): a library added there later
#      must reach the host with no build change, not go silently missing.
_lib_miss=""
for _f in "$ROOT"/scripts/lib/*; do
  [ -f "$_f" ] || continue
  cmp -s "$_f" "$DIST/scripts/lib/${_f##*/}" || _lib_miss="$_lib_miss ${_f##*/}"
done
if [ -f "$DIST/scripts/adversarial-review.sh" ] \
   && cmp -s "$ROOT/scripts/lib/model-subprocess.sh" "$DIST/scripts/lib/model-subprocess.sh" \
   && [ -z "$_lib_miss" ]; then
  pass "(11) dist ships every regular file of scripts/lib/ (incl. model-subprocess.sh) beside scripts/adversarial-review.sh"
else
  bad "(11) dist's scripts/lib/ beside its adversarial-review.sh is not a copy of scripts/lib/ — missing or different:${_lib_miss:- model-subprocess.sh}"
fi
# (11b) …and ONLY that: the build's scripts/lib/ is regenerated, not merged into. install_kimi ships
#       every file of it, so a library removed or renamed upstream that lingered here would reach
#       ~/.kimi-code/scripts/lib/ on every install. The stale file planted before (1) must be gone.
if [ ! -e "$KIMI_STALE" ]; then
  pass "(11b) a library removed upstream does not linger in the build's scripts/lib/"
else
  bad "(11b) the stale library planted before the build [${KIMI_STALE##*/}] is still in the build's scripts/lib/"
fi
# (11c) zuvo_ship_runner_lib — the one function both builds ship scripts/lib/ through (the portable.sh
#       beside the builder under test) — refuses an EMPTY <plugin_dir> or <dist_dir> before anything is
#       removed: an empty <dist_dir> made its clearing step `rm -rf /scripts/lib`, at the filesystem root.
#       Driven with `rm` and `mkdir` stand-ins first on PATH that only RECORD (mkdir then fails), so no
#       version of the function can delete or create anything here; the anchor shows the recorder does
#       see the function's rm — with `--`, so a <dist_dir> starting with '-' is never an option.
SHIP_SPY="$KIMI_SANDBOX/ship-spy"; mkdir -p "$SHIP_SPY/bin"
printf '#!/bin/sh\necho "rm $*" >> "%s/calls"\n' "$SHIP_SPY" > "$SHIP_SPY/bin/rm"
printf '#!/bin/sh\necho "mkdir $*" >> "%s/calls"\nexit 1\n' "$SHIP_SPY" > "$SHIP_SPY/bin/mkdir"
chmod +x "$SHIP_SPY/bin/rm" "$SHIP_SPY/bin/mkdir"
SHIP_LIB="$(dirname "$KIMI_BUILDER")/lib/portable.sh"
# ship_case <plugin_dir> <dist_dir> — prints "rc=<status>"; what the stand-ins saw lands in
# $SHIP_SPY/calls, the function's stderr in $SHIP_SPY/err.
ship_case() {
  rm -f "$SHIP_SPY/calls" "$SHIP_SPY/err"
  # shellcheck source=scripts/lib/portable.sh
  ( PATH="$SHIP_SPY/bin:$PATH"; . "$SHIP_LIB" || exit 9
    rc=0; zuvo_ship_runner_lib "$1" "$2" "(11c) test" 2> "$SHIP_SPY/err" || rc=$?; echo "rc=$rc" )
}
for _pair in "empty <dist_dir>|$ROOT|" "empty <plugin_dir>||$KIMI_SANDBOX/ship-dist"; do
  _lbl="${_pair%%|*}"; _rest="${_pair#*|}"
  _out="$(ship_case "${_rest%%|*}" "${_rest#*|}")"
  _calls="$(tr '\n' '|' < "$SHIP_SPY/calls" 2>/dev/null)"
  if [ "$_out" = "rc=1" ] && [ -z "$_calls" ] && grep -qF 'empty <plugin_dir>' "$SHIP_SPY/err" 2>/dev/null; then
    pass "(11c) $_lbl: refused (status 1, said so) before any rm or mkdir ran"
  else
    bad "(11c) $_lbl: [$_out], rm/mkdir seen [$_calls], stderr [$(tr '\n' ' ' < "$SHIP_SPY/err" 2>/dev/null)] — want rc=1, none, the refusal"
  fi
done
# …and a <dist_dir> whose scripts/lib/ IS the source's (the plugin dir itself, or a link to it) or the
# root's: clearing it would delete the very libraries being shipped, or /scripts/lib.
# The root is matched by file identity, not spelling: `/./` and a link to / are the root too.
ln -s "$ROOT" "$KIMI_SANDBOX/ship-link"
ln -s / "$KIMI_SANDBOX/root-link"
for _pair in "<dist_dir> = <plugin_dir>|$ROOT" "<dist_dir> linked to <plugin_dir>|$KIMI_SANDBOX/ship-link" "<dist_dir> = /|/" \
             "<dist_dir> = /./|/./" "<dist_dir> linked to /|$KIMI_SANDBOX/root-link"; do
  _lbl="${_pair%%|*}"
  _out="$(ship_case "$ROOT" "${_pair#*|}")"
  _calls="$(tr '\n' '|' < "$SHIP_SPY/calls" 2>/dev/null)"
  if [ "$_out" = "rc=1" ] && [ -z "$_calls" ] && grep -qF 'refusing to ship' "$SHIP_SPY/err" 2>/dev/null; then
    pass "(11c) $_lbl: refused (status 1, said so) before any rm or mkdir ran"
  else
    bad "(11c) $_lbl: [$_out], rm/mkdir seen [$_calls], stderr [$(tr '\n' ' ' < "$SHIP_SPY/err" 2>/dev/null)] — want rc=1, none, the refusal"
  fi
done
_out="$(ship_case "$ROOT" "$KIMI_SANDBOX/ship-dist")"
case "$(tr '\n' '|' < "$SHIP_SPY/calls" 2>/dev/null)" in
  "rm -rf -- $KIMI_SANDBOX/ship-dist/scripts/lib|mkdir -p $KIMI_SANDBOX/ship-dist/scripts/lib|")
    pass "(11c) anchor: with both dirs set the recorder sees the clearing rm (with --), then mkdir" ;;
  *) bad "(11c) anchor: with both dirs set the recorder saw [$(tr '\n' '|' < "$SHIP_SPY/calls" 2>/dev/null)] ($_out) — the empty-arg cases above prove nothing" ;;
esac

# (12) team-lead.md is a PROCEDURE DOC, not a dispatch target (build-kimi-skills.sh, the team-lead
#      branch of the agent loop): it ships inside the skill dir, never as a flat agent profile, and the
#      SKILL.md reference the generic agents/*.md rewrite turned into a flat-namespace path is repointed
#      at it. The real skill that ships one (plan) exercises the prefixed form of that rewrite.
if [ -f "$ROOT/skills/plan/agents/team-lead.md" ]; then
  if [ -s "$DIST/skills/plan/team-lead.md" ]; then
    pass "(12) plan's team-lead.md ships inside the skill dir"
  else
    bad "(12) dist/kimi/skills/plan/team-lead.md missing or empty — the skill points at a file that was never shipped"
  fi
  if [ -e "$DIST/agents/plan-team-lead.md" ]; then
    bad "(12) team-lead was registered as a flat agent profile (agents/plan-team-lead.md) — a phantom subagent_type"
  else
    pass "(12) team-lead is not registered as an agent profile"
  fi
  if grep -qF '~/.kimi-code/skills/plan/team-lead.md' "$DIST/skills/plan/SKILL.md" 2>/dev/null; then
    pass "(12) plan's SKILL.md points at ~/.kimi-code/skills/plan/team-lead.md"
  else
    bad "(12) plan's SKILL.md does not reference ~/.kimi-code/skills/plan/team-lead.md"
  fi
  if grep -qE '~/\.kimi-code/agents/(plan-)?team-lead\.md' "$DIST/skills/plan/SKILL.md" 2>/dev/null; then
    bad "(12) plan's SKILL.md still points team-lead at the flat agent namespace: $(grep -oE '~/\.kimi-code/agents/(plan-)?team-lead\.md' "$DIST/skills/plan/SKILL.md" | head -1)"
  else
    pass "(12) no flat-namespace team-lead reference is left in plan's SKILL.md"
  fi
else
  echo "  SKIP: (12) no real skill ships agents/team-lead.md any more — (12b) below still covers the rewrite"
fi

# (12b)/(13) need inputs no real skill has: the UN-prefixed reference form (an install-root path,
#      ~/.claude/agents/team-lead.md, which replace_paths turns into ~/.kimi-code/agents/team-lead.md
#      without a skill prefix) and a kimi/SKILL.kimi.md overlay (none ships today). The builder takes
#      its plugin dir as $1, so a FIXTURE plugin tree is built on its own, into its own sandbox dist.
FIXP="$KIMI_SANDBOX/fixture-plugin"
FIXD="$KIMI_SANDBOX/fixture-dist/kimi"
mkdir -p "$FIXP/skills/fx-lead/agents" "$FIXP/skills/fx-overlay/kimi" "$FIXP/skills/fx-auto" \
         "$FIXP/shared/includes" "$FIXP/scripts/lib"
cp "$ROOT/scripts/lib/model-subprocess.sh" "$FIXP/scripts/lib/"   # the build refuses to ship a driver without it
printf '# Fixture include\n' > "$FIXP/shared/includes/fixture.md"
cat > "$FIXP/skills/fx-lead/SKILL.md" <<'EOF'
---
name: fx-lead
description: fixture skill whose Team Lead step names its procedure doc in both forms
---
# zuvo:fx-lead
Step A: read `agents/team-lead.md` and execute it yourself.
Step B: the installed copy is ~/.claude/agents/team-lead.md.
EOF
cat > "$FIXP/skills/fx-lead/agents/team-lead.md" <<'EOF'
---
name: team-lead
description: fixture team lead procedure
---
FIXTURE-TEAM-LEAD-PROCEDURE → synthesize
EOF
# The overlay and the auto-transformed control carry the SAME tokens, each one the transform rewrites
# (em dash, arrow, a relative shared path, "Claude Code", CLAUDE.md): the control proves they would
# have changed, so the overlay arriving byte-identical proves it was copied, not transformed.
_fx_body='kept — verbatim → ../../shared/includes/fixture.md
Claude Code reads CLAUDE.md here.'
printf -- '---\nname: fx-overlay\ndescription: fixture source that must NOT ship\n---\nSOURCE-BODY-MUST-NOT-SHIP\n%s\n' "$_fx_body" > "$FIXP/skills/fx-overlay/SKILL.md"
printf -- '---\nname: fx-overlay\ndescription: fixture overlay\n---\nOVERLAY-BODY\n%s\n' "$_fx_body" > "$FIXP/skills/fx-overlay/kimi/SKILL.kimi.md"
printf -- '---\nname: fx-auto\ndescription: fixture control, auto-transformed\n---\nAUTO-BODY\n%s\n' "$_fx_body" > "$FIXP/skills/fx-auto/SKILL.md"
if fx_log=$(ZUVO_DIST_ROOT="$KIMI_SANDBOX/fixture-dist" bash "$KIMI_BUILDER" "$FIXP" 2>&1); then
  pass "(12b) the fixture plugin tree builds (exit 0, self-validation included)"
else
  bad "(12b) the fixture build failed (tail: $(printf '%s' "$fx_log" | tail -4 | tr '\n' ' '))"
fi
_fx_lead="$FIXD/skills/fx-lead/SKILL.md"
if [ "$(grep -cF '~/.kimi-code/skills/fx-lead/team-lead.md' "$_fx_lead" 2>/dev/null)" = "2" ]; then
  pass "(12b) BOTH reference forms (prefixed and un-prefixed) are repointed at the skill-local team-lead.md"
else
  bad "(12b) expected 2 references to ~/.kimi-code/skills/fx-lead/team-lead.md, got: $(grep -F 'team-lead' "$_fx_lead" 2>/dev/null | tr '\n' ' ')"
fi
if grep -qF '~/.kimi-code/agents/' "$_fx_lead" 2>/dev/null; then
  bad "(12b) a flat-namespace reference survived: $(grep -oE '~/\.kimi-code/agents/[a-z-]*\.md' "$_fx_lead" | tr '\n' ' ')"
else
  pass "(12b) no ~/.kimi-code/agents/ reference is left in the skill"
fi
if grep -qF 'FIXTURE-TEAM-LEAD-PROCEDURE -> synthesize' "$FIXD/skills/fx-lead/team-lead.md" 2>/dev/null \
   && [ ! -e "$FIXD/agents/fx-lead-team-lead.md" ]; then
  pass "(12b) the fixture team-lead ships transformed inside the skill dir, not as an agent profile"
else
  bad "(12b) fixture team-lead.md missing/untransformed, or registered as agents/fx-lead-team-lead.md"
fi
if cmp -s "$FIXP/skills/fx-overlay/kimi/SKILL.kimi.md" "$FIXD/skills/fx-overlay/SKILL.md"; then
  pass "(13) a kimi/SKILL.kimi.md overlay ships byte-for-byte as the skill's SKILL.md"
else
  bad "(13) the overlay was not shipped verbatim (dist SKILL.md: $(head -c 300 "$FIXD/skills/fx-overlay/SKILL.md" 2>/dev/null | tr '\n' ' '))"
fi
if grep -qF 'SOURCE-BODY-MUST-NOT-SHIP' "$FIXD/skills/fx-overlay/SKILL.md" 2>/dev/null; then
  bad "(13) the overlaid skill's own SKILL.md was shipped instead of the overlay"
else
  pass "(13) the overlaid skill's own SKILL.md did not ship"
fi
case "$fx_log" in
  *"+ fx-overlay (overlay)"*"Overlays: fx-overlay"*) pass "(13) the build log names the overlay (per skill and in the summary)" ;;
  *) bad "(13) the build log does not report fx-overlay as an overlay" ;;
esac
if grep -qF 'kept -- verbatim -> ~/.kimi-code/shared/includes/fixture.md' "$FIXD/skills/fx-auto/SKILL.md" 2>/dev/null \
   && grep -qF 'Kimi Code reads AGENTS.md here.' "$FIXD/skills/fx-auto/SKILL.md" 2>/dev/null; then
  pass "(13) control: the same tokens in a skill WITHOUT an overlay are transformed"
else
  bad "(13) control: the auto-transformed fixture did not rewrite the tokens — the overlay check above proves nothing"
fi

echo ""
echo "  $pass_count passed, $fail_count failed"
[ "$fail_count" -eq 0 ] || exit 1
