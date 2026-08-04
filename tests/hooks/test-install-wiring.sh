#!/usr/bin/env bash
# Task 11 — install.sh + build scripts ship the pipeline-entry hooks/lib/CI to
# all targets. Sources install.sh (must be source-able), exercises the helper
# functions against a temp HOME, and runs the codex/antigravity builds to verify
# the hardcoded allowlists were extended.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
INSTALL="$ROOT/scripts/install.sh"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# (1) source-able: sourcing must NOT run the installer (no "Installing zuvo" output)
src_out="$( . "$INSTALL" 2>&1 )"
if printf '%s' "$src_out" | grep -q 'Installing zuvo'; then
  bad "(1) sourcing install.sh ran the installer (guard missing)"
else
  pass "(1) install.sh is source-able (main run guarded)"
fi

# bring the functions into THIS shell
# shellcheck source=/dev/null
. "$INSTALL" >/dev/null 2>&1

for fn in install_hook_tree install_pipeline_artifacts install_git_shim; do
  if declare -F "$fn" >/dev/null 2>&1; then pass "(fn) $fn defined"; else bad "(fn) $fn missing"; fi
done

# (2) install_hook_tree → full tree incl. lib/
HK="$TMP/hooks"
install_hook_tree "$HK" >/dev/null 2>&1
for f in block-no-verify.sh zuvo-stop-pipeline-gate.sh pre-push-gate.sh pre-commit-adversarial-gate.sh lib/pipeline-gate-lib.sh; do
  [ -f "$HK/$f" ] && pass "(2) hook tree has $f" || bad "(2) hook tree missing $f"
done
[ -x "$HK/lib/pipeline-gate-lib.sh" ] && pass "(2) lib is executable" || bad "(2) lib not executable"

# (3) idempotency: re-run → no duplicates, same file set
before=$(find "$HK" -type f | sort | md5 2>/dev/null || find "$HK" -type f | sort | md5sum)
install_hook_tree "$HK" >/dev/null 2>&1
after=$(find "$HK" -type f | sort | md5 2>/dev/null || find "$HK" -type f | sort | md5sum)
[ "$before" = "$after" ] && pass "(3) install_hook_tree idempotent (no dup on re-run)" || bad "(3) re-run changed file set"

# (4) pipeline artifacts: CI script + shim + workflow template
PA="$TMP/claude"
install_pipeline_artifacts "$PA" >/dev/null 2>&1
[ -f "$PA/scripts/zuvo-pipeline-entry-ci.sh" ] && pass "(4) CI check script shipped" || bad "(4) CI script missing"
[ -f "$PA/scripts/git-noverify-shim.sh" ]      && pass "(4) git shim shipped"       || bad "(4) shim missing"
[ -f "$PA/ci/zuvo-pipeline-entry.yml" ]        && pass "(4) CI workflow template shipped" || bad "(4) workflow missing"

# (5) git shim install/uninstall (opt-in)
HOME_T="$TMP/home"; mkdir -p "$HOME_T"
( export HOME="$HOME_T" ZUVO_INSTALL_GIT_SHIM=1; install_git_shim >/dev/null 2>&1 )
[ -x "$HOME_T/bin/git" ] && pass "(5) ZUVO_INSTALL_GIT_SHIM=1 → ~/bin/git installed" || bad "(5) shim not installed"
( export HOME="$HOME_T" ZUVO_UNINSTALL_GIT_SHIM=1; install_git_shim >/dev/null 2>&1 )
[ ! -e "$HOME_T/bin/git" ] && pass "(5) ZUVO_UNINSTALL_GIT_SHIM=1 → ~/bin/git removed" || bad "(5) shim not removed"
# default (no env) → no-op (never installs a git wrapper silently)
HOME_T2="$TMP/home2"; mkdir -p "$HOME_T2"
( export HOME="$HOME_T2"; unset ZUVO_INSTALL_GIT_SHIM ZUVO_UNINSTALL_GIT_SHIM 2>/dev/null; install_git_shim >/dev/null 2>&1 )
[ ! -e "$HOME_T2/bin/git" ] && pass "(5) default → shim NOT installed (opt-in only)" || bad "(5) shim installed without opt-in"

# (6) build allowlists: codex + antigravity dist include block-no-verify + lib
codex_log=$(bash "$ROOT/scripts/build-codex-skills.sh" "$ROOT" 2>&1)
if [ -f "$ROOT/dist/codex/hooks/block-no-verify.sh" ] && [ -f "$ROOT/dist/codex/hooks/lib/pipeline-gate-lib.sh" ]; then
  pass "(6) codex build ships block-no-verify + hooks/lib/"
else
  bad "(6) codex build missing block-no-verify or lib (tail: $(printf '%s' "$codex_log" | tail -3))"
fi
antig_log=$(bash "$ROOT/scripts/build-antigravity-skills.sh" "$ROOT" 2>&1)
if [ -f "$ROOT/dist/antigravity/hooks/block-no-verify.sh" ] && [ -f "$ROOT/dist/antigravity/hooks/lib/pipeline-gate-lib.sh" ]; then
  pass "(6) antigravity build ships block-no-verify + hooks/lib/"
else
  bad "(6) antigravity build missing block-no-verify or lib (tail: $(printf '%s' "$antig_log" | tail -3))"
fi

# (6b) install_codex + install_antigravity must ship hooks/lib/ recursively (regression:
# v1.3.122 shipped with non-recursive `cp $DIST/hooks/*` that dropped lib/ on Codex+Antigravity)
libcopies=$(grep -c 'cp -R "\$DIST/hooks/lib"' "$ROOT/scripts/install.sh" 2>/dev/null || echo 0)
[ "${libcopies:-0}" -ge 3 ] && pass "(6b) install ships hooks/lib recursively to codex+antigravity ($libcopies sites)" \
  || bad "(6b) install drops hooks/lib (found $libcopies recursive lib copies, need >=3)"

# (6c) refactor-safety-gate.sh + install-refactor-gate.sh must reach EVERY host. zuvo:refactor
# PHASE 0 self-installs the git commit gate from one of them; before v1.6.47 only the Claude
# marketplace cache carried them, so every Codex/Cursor/Antigravity run printed "not found" and
# silently ran with no commit bind at all.
for d in codex antigravity; do
  [ -f "$ROOT/dist/$d/hooks/refactor-safety-gate.sh" ] \
    && pass "(6c) $d build ships refactor-safety-gate.sh" \
    || bad "(6c) $d build missing refactor-safety-gate.sh — PHASE 0 has nothing to install"
done
[ -f "$ROOT/dist/antigravity/scripts/install-refactor-gate.sh" ] \
  && pass "(6c) antigravity build ships install-refactor-gate.sh" \
  || bad "(6c) antigravity build missing install-refactor-gate.sh"
for h in .codex .cursor; do
  grep -q "install-refactor-gate.sh \"\$HOME/$h/scripts/\"" "$ROOT/scripts/install.sh" \
    && pass "(6c) install.sh ships install-refactor-gate.sh to $h" \
    || bad "(6c) install.sh does not ship install-refactor-gate.sh to $h"
  grep -q "hooks/refactor-safety-gate.sh \"\$HOME/$h/scripts/\"" "$ROOT/scripts/install.sh" \
    && pass "(6c) install.sh ships refactor-safety-gate.sh to $h" \
    || bad "(6c) install.sh does not ship refactor-safety-gate.sh to $h"
done
# and the skill must actually probe those paths (a shipped file nobody looks for is still missing)
for probe in '.codex/scripts/refactor-safety-gate.sh' '.cursor/scripts/refactor-safety-gate.sh' \
             '.gemini/antigravity/hooks/refactor-safety-gate.sh'; do
  grep -q "$probe" "$ROOT/skills/refactor/SKILL.md" \
    && pass "(6c) refactor PHASE 0 probes ~/$probe" \
    || bad "(6c) refactor PHASE 0 does not probe ~/$probe"
done

# (8) EVERY zuvo-home helper must be installed, and none may carry a host or secret.
# Two failures this locks. (a) install.sh used explicit per-file cp blocks and had silently
# drifted: retro-mine.py, retro-mine-weekly.sh and rotate-retros-cron.sh were versioned but never
# installed — the file was in git and nothing was in ~/.zuvo. It is a loop now, so the list cannot
# drift again. (b) six helpers were unversioned because they hardcoded a private SSH host; the
# address moved to ~/.zuvo/collector.conf (machine-local, never in git) so the CODE can ship.
grep -q 'for _src in "\$ZUVO_DIR"/scripts/zuvo-home/\*' "$ROOT/scripts/install.sh"   && pass "(8) install.sh installs zuvo-home helpers by LOOP, not a driftable list"   || bad "(8) install.sh is back to per-file blocks — new helpers will be forgotten"

viol=0
for f in "$ROOT"/scripts/zuvo-home/*; do
  [ -f "$f" ] || continue
  case "$f" in *.pyc) continue ;; esac
  # any dotted quad that is not a loopback/wildcard placeholder
  if grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' "$f" 2>/dev/null      | grep -qvE '^(127\.0\.0\.1|0\.0\.0\.0)$'; then
    bad "(8) versioned helper names a host address: $(basename "$f")"; viol=$((viol+1))
  fi
  if grep -qiE '(token|secret|api[_-]?key)[[:space:]]*=[[:space:]]*["'"'"'][A-Za-z0-9_-]{16,}' "$f" 2>/dev/null; then
    bad "(8) versioned helper embeds a literal secret: $(basename "$f")"; viol=$((viol+1))
  fi
done
[ "$viol" -eq 0 ] && pass "(8) no versioned helper carries a host address or literal secret"

# the resolver must fail LOUDLY rather than defaulting to somebody else's collector
grep -q 'There is deliberately NO fallback default' "$ROOT/scripts/zuvo-home/zuvo-collector-host.sh"   && pass "(8) collector-host resolver documents why it has no default"   || bad "(8) collector-host resolver lost its no-default contract"
_t=$(mktemp -d)
if ( export ZUVO_HOME="$_t"; unset ZUVO_COLLECTOR_SSH
     . "$ROOT/scripts/zuvo-home/zuvo-collector-host.sh"; zuvo_collector_host ) 2>/dev/null; then
  bad "(8) resolver succeeded with no config — it must fail closed"
else
  pass "(8) resolver fails closed when no host is configured"
fi
# config is PARSED, never sourced: a config that contains code must not execute it
printf 'ZUVO_COLLECTOR_SSH=safe@host
touch %s/PWNED
' "$_t" > "$_t/collector.conf"
( export ZUVO_HOME="$_t"; unset ZUVO_COLLECTOR_SSH
  . "$ROOT/scripts/zuvo-home/zuvo-collector-host.sh"; zuvo_collector_host ) >/dev/null 2>&1
[ -f "$_t/PWNED" ] && bad "(8) collector.conf was SOURCED — arbitrary code ran"                    || pass "(8) collector.conf is parsed, not sourced (no code execution)"
rm -rf "$_t"

# (7) syntax check on all four scripts (shellcheck absent → bash -n).
# --severity=error, matching this check's stated contract ("syntax check"): the
# default severity includes style/info findings the four scripts have carried for
# months. That stricter path was LATENT — it activates the moment anyone installs
# shellcheck, which happened 2026-08-02 11:55 and turned an unchanged installer
# into 4 FAILs that blocked a release of unrelated work. Error severity still
# upgrades on bash -n (catches real defects, not just parse errors); the style
# warning cleanup is tracked as its own task, not a silent gate downgrade.
for s in scripts/install.sh scripts/build-codex-skills.sh scripts/build-antigravity-skills.sh scripts/build-cursor-skills.sh; do
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck --severity=error "$ROOT/$s" >/dev/null 2>&1 && pass "(7) shellcheck -Serror $s" || bad "(7) shellcheck (error severity) failed: $s"
  else
    bash -n "$ROOT/$s" 2>/dev/null && pass "(7) bash -n $s (shellcheck absent)" || bad "(7) syntax error: $s"
  fi
done

# (9) the Claude Code cache manifest must be refreshed by an install.
#
# install.sh copied skills/, shared/, rules/, scripts/, bin/, docs/ and VERSION
# into every cache dir, and .codex-plugin/plugin.json into the Codex targets —
# but never .claude-plugin/plugin.json into the Claude cache. So each cache dir
# kept whatever manifest Claude Code itself wrote when it created the directory,
# and nothing ever refreshed it. Measured 2026-08-03 verifying the v1.6.54
# install (backlog B-INSTALL-CLAUDE-MANIFEST): after installing 1.6.54, the
# manifest in the 1.6.53 cache dir still declared 1.6.16 and the one in 1.6.54
# declared 1.6.47. Skills still loaded, which is why ~40 releases went by without
# anyone noticing — metadata drift is silent.
# A freshly-created cache dir does NOT show the drift (Claude Code writes a
# correct manifest when it creates one); it appears only in dirs that later
# installs write into. So this asserts the copy exists in install.sh and that
# the copy itself produces a version-matching manifest — it deliberately does
# NOT assert against the live cache, which would pass vacuously right after a
# fresh install and fail for reasons unrelated to this code.
if grep -q 'CACHE_DIR/\.claude-plugin' "$INSTALL"; then
  pass "(9) install.sh copies .claude-plugin/plugin.json into the Claude cache"
else
  bad "(9) install.sh never refreshes the Claude cache manifest — it will drift silently"
fi

# End-to-end: run the copy the way install.sh does and compare versions. Uses a
# throwaway CACHE_DIR so it never touches the real install.
# PLACEMENT is the property, not "does cp work". The previous version of this
# check re-implemented the mkdir+cp itself against $ROOT and compared versions —
# which tests coreutils, not install.sh. The failure it needs to catch is the
# copy drifting OUTSIDE the `for CACHE_DIR` loop, where it would refresh only
# one cache dir and silently restore the very drift this fixes; a content grep
# still matches then, and so did the old copy-and-compare. So: parse install.sh,
# track do/done depth (the inner `for skill_dir` loop has its own `done`, which
# is exactly what a naive "next done" match gets wrong), and assert the manifest
# copy lands inside the per-CACHE_DIR loop body.
_placement="$(awk '
  /for CACHE_DIR in/           { inloop = 1; depth = 1; next }
  inloop && /(^|[[:space:]])(do|then)[[:space:]]*$/ { depth++ }
  inloop && /^[[:space:]]*(done|fi)[[:space:]]*$/   { depth--; if (depth == 0) inloop = 0 }
  inloop && /CACHE_DIR\/\.claude-plugin/            { found = 1 }
  END { print (found ? "inside" : "outside") }
' "$INSTALL")"
if [ "$_placement" = "inside" ]; then
  pass "(9) the manifest copy is INSIDE the per-CACHE_DIR loop (every cache dir gets it)"
else
  bad "(9) manifest copy is outside the per-CACHE_DIR loop — only one dir would be refreshed, reintroducing the drift"
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
