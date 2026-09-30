#!/usr/bin/env bash
# Task 11 — install.sh + build scripts ship the pipeline-entry hooks/lib/CI to
# all targets. Sources install.sh (must be source-able), exercises the helper
# functions against a temp HOME, and runs the codex/antigravity builds to verify
# the hardcoded allowlists were extended.
#
# Test level: MEDIUM — real installer functions and builds into temp HOMEs / dist roots, real subprocesses
# (the installed drivers, ~/.zuvo/model-run and its router) against spy clients; no network, no real model
# CLI, nothing written outside the temp dirs.
set -u

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# ZUVO_TEST_INSTALL runs the file against ANOTHER install.sh (a deliberately broken copy inside a mirror of
# the repo, to show a case is red there). Not used in normal runs: default, the repo's own.
INSTALL="${ZUVO_TEST_INSTALL:-$ROOT/scripts/install.sh}"
fail=0
pass() { printf 'PASS: %s\n' "$1"; }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; }
# Every installer and driver run below names its interpreter as "$BASH" — the one running THIS suite
# (P2-106), never a bare `bash` a narrowed PATH would resolve elsewhere. bash always sets BASH; the
# fallback (P3C-35) only keeps an exotic empty value from turning each of those runs into an
# empty-command error.
[ -n "${BASH:-}" ] || BASH="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }

# Every build this file runs writes into a per-run dist root under $TMP — never the shared $ROOT/dist
# (B-DIST-BUILD-RACE: test-kimi-build.sh and reviewer-model-builds.bats build into their own trees for
# the same reason, and a concurrent suite run must not see this file's half-written tree). The builders,
# tests/lib/dist-build.sh and install.sh's dist_root all honour ZUVO_DIST_ROOT.
export ZUVO_DIST_ROOT="$TMP/dist"
mkdir -p "$ZUVO_DIST_ROOT"

# Sourcing install.sh RUNS code, not only definitions: its downgrade guard reads $HOME/.zuvo/.installed-from
# (and `exit`s on a mismatch), and the shell-level sleep guard below its main-run guard copies
# $HOME/.zuvo/zuvo-sleep-guard.zsh and may append to $HOME/.zshenv. So both sources here run with HOME
# pointing at a temp dir — a test run must never write into the real one.
SRC_HOME="$TMP/source-home"; mkdir -p "$SRC_HOME"

# (1) source-able: sourcing must NOT run the installer (no "Installing zuvo" output)
src_out="$( HOME="$SRC_HOME"; . "$INSTALL" 2>&1 )"
if printf '%s' "$src_out" | grep -q 'Installing zuvo'; then
  bad "(1) sourcing install.sh ran the installer (guard missing)"
else
  pass "(1) install.sh is source-able (main run guarded)"
fi

# bring the functions into THIS shell (HOME is the temp one while the file runs, then the caller's again)
_real_home="$HOME"; HOME="$SRC_HOME"
# shellcheck source=/dev/null
. "$INSTALL" >/dev/null 2>&1
HOME="$_real_home"; unset _real_home

for fn in install_hook_tree install_pipeline_artifacts install_git_shim; do
  if declare -F "$fn" >/dev/null 2>&1; then pass "(fn) $fn defined"; else bad "(fn) $fn missing"; fi
done

# (2) install_hook_tree → full tree incl. lib/
HK="$TMP/hooks"
install_hook_tree "$HK" >/dev/null 2>&1
for f in block-no-verify.sh route-suite-through-verify.sh require-inventory-first.sh zuvo-stop-pipeline-gate.sh pre-push-gate.sh pre-commit-adversarial-gate.sh lib/pipeline-gate-lib.sh; do
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
#
# Via tests/lib/dist-build.sh, not the builder directly: these same two platforms are
# also built by scripts/tests/reviewer-model-builds.bats in the same suite run, and
# rebuilding all 57 skills a second time to assert on two file paths cost ~50s per run.
# The helper is a pass-through when ZUVO_DIST_CACHE is unset (running this file by
# hand), so the assertions below are unchanged either way.
# Each check is gated on the build's OWN exit status: a failed build can leave the files of an
# earlier, successful one in dist/, and a file check alone passes on that leftover tree.
codex_log=$(bash "$ROOT/tests/lib/dist-build.sh" codex 2>&1); codex_rc=$?
if [ "$codex_rc" -eq 0 ] && [ -f "$ZUVO_DIST_ROOT/codex/hooks/block-no-verify.sh" ] && [ -f "$ZUVO_DIST_ROOT/codex/hooks/lib/pipeline-gate-lib.sh" ]; then
  pass "(6) codex build exits 0 and ships block-no-verify + hooks/lib/"
else
  bad "(6) codex build exited $codex_rc or is missing block-no-verify or lib (tail: $(printf '%s' "$codex_log" | tail -3))"
fi
# (14f, planted here) A library removed or renamed upstream must not linger in the build's
# scripts/lib/: the build output is regenerated, never merged into. A stale file is planted where
# the build writes BEFORE it runs; (14f) below asserts it is gone.
_ag_stale="${ZUVO_DIST_ROOT:-$ROOT/dist}/antigravity/scripts/lib/zz-removed-upstream.sh"
mkdir -p "${_ag_stale%/*}" && printf '# stale: removed from scripts/lib/ upstream\n' > "$_ag_stale"
# …which needs the plant to have happened (a silent failure leaves nothing to remove), and a REAL build:
# a cache replay (tests/lib/dist-build.sh, when an earlier caller in the suite run or a warm
# ZUVO_DIST_CACHE already built antigravity) rm -rf's the build dir and copies the cached tree back, so
# the planted file would go whatever the builder does. Hence `--fresh`: the builder always runs.
if [ -f "$_ag_stale" ]; then pass "(14f) premise: the stale library is planted in the antigravity build's scripts/lib/ before (6) builds it"
else bad "(14f) premise: could not plant $_ag_stale — (14f) would pass on nothing"; fi
antig_log=$(bash "$ROOT/tests/lib/dist-build.sh" --fresh antigravity 2>&1); antig_rc=$?
if [ "$antig_rc" -eq 0 ] && [ -f "$ZUVO_DIST_ROOT/antigravity/hooks/block-no-verify.sh" ] && [ -f "$ZUVO_DIST_ROOT/antigravity/hooks/lib/pipeline-gate-lib.sh" ]; then
  pass "(6) antigravity build exits 0 and ships block-no-verify + hooks/lib/"
else
  bad "(6) antigravity build exited $antig_rc or is missing block-no-verify or lib (tail: $(printf '%s' "$antig_log" | tail -3))"
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
  [ -f "$ZUVO_DIST_ROOT/$d/hooks/refactor-safety-gate.sh" ] \
    && pass "(6c) $d build ships refactor-safety-gate.sh" \
    || bad "(6c) $d build missing refactor-safety-gate.sh — PHASE 0 has nothing to install"
done
[ -f "$ZUVO_DIST_ROOT/antigravity/scripts/install-refactor-gate.sh" ] \
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
# Execute the actual documentation block: selected harness root and target checkout
# must survive quoting, a different caller CWD, and installer failures.
if python3 "$ROOT/tests/hooks/bootstrap-activation-cases.py"; then
  pass "(6c) refactor PHASE 0 activation snippet behaves correctly"
else
  bad "(6c) refactor PHASE 0 activation snippet failed"
fi

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
# the linter, which happened 2026-08-02 11:55 and turned an unchanged installer
# into 4 FAILs that blocked a release of unrelated work. Error severity still
# upgrades on bash -n (catches real defects, not just parse errors); the style
# warning cleanup is tracked as its own task, not a silent gate downgrade.
for s in scripts/install.sh scripts/build-codex-skills.sh scripts/build-antigravity-skills.sh scripts/build-cursor-skills.sh scripts/build-kimi-skills.sh; do
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
  # Match the COPY, not any mention. `CACHE_DIR/.claude-plugin` also appears on
  # the adjacent `mkdir -p` line, so the loose form reported "inside" even if
  # only the mkdir stayed behind and the cp moved out — the precise half of the
  # split that would break the fix.
  inloop && /^[[:space:]]*cp .*CACHE_DIR\/\.claude-plugin\/plugin\.json/ { found = 1 }
  END { print (found ? "inside" : "outside") }
' "$INSTALL")"
if [ "$_placement" = "inside" ]; then
  pass "(9) the manifest copy is INSIDE the per-CACHE_DIR loop (every cache dir gets it)"
else
  bad "(9) manifest copy is outside the per-CACHE_DIR loop — only one dir would be refreshed, reintroducing the drift"
fi

# (10) Antigravity skills must land in its GLOBAL CUSTOMIZATION ROOT.
#
# Wrong since the Antigravity target was added: skills installed to
# ~/.gemini/antigravity/skills/, which the app never reads. install.sh reported
# success, `ls` showed 57 skills on disk, and zuvo was simply absent from every
# Antigravity session — the failure had no symptom other than nothing happening.
# The read path is ~/.gemini/config/skills (the app's own language_server says
# "Global Discovery: `~/.gemini/config/`" and "Location: skills/<skill_name>/
# (relative to the customization root)"), confirmed by an A/B canary: the same
# skill name in both directories resolved to the ~/.gemini/config copy.
#
# Asserted on the install script rather than on a live $HOME because the bug is a
# hardcoded destination, and that is exactly what a path typo would reintroduce.
if grep -qE 'AG_SKILLS=.*\.gemini/config/skills' "$INSTALL"; then
  pass "(10) Antigravity skills install into ~/.gemini/config/skills (the customization root)"
else
  bad "(10) Antigravity skill destination is not ~/.gemini/config/skills — the app will not load them"
fi

# The legacy directory must be actively removed, not merely abandoned: a machine
# that ran an older install.sh otherwise keeps a full stale copy of every skill
# that no longer updates and that nothing reads.
if grep -qE 'rm -rf "\$HOME/\.gemini/antigravity/skills"' "$INSTALL"; then
  pass "(10b) the legacy ~/.gemini/antigravity/skills copy is cleaned up"
else
  bad "(10b) the legacy ~/.gemini/antigravity/skills copy is left behind (stale, never-loaded skills)"
fi

# The build's cross-skill path rewrites must agree with where skills actually
# live, or a skill referencing another skill points into the dead directory.
if grep -qE "skills/\|~/\.gemini/config/skills/" "$ROOT/scripts/build-antigravity-skills.sh"; then
  pass "(10c) build rewrites cross-skill paths to the customization root"
else
  bad "(10c) build still rewrites ../../skills/ to the unread ~/.gemini/antigravity/skills path"
fi

# (11) EVERY dispatch branch installs ~/.zuvo (B-9, open since v1.3.109).
# Those helpers — append-runlog, append-retro, adversarial-review, compute-preload — are called
# by absolute path from every skill on every platform. `install.sh codex` used to install a full
# skill set and zero helpers, so the first mandatory gate died with "command not found" inside a
# skill run rather than at install time. Asserted structurally per branch, because the failure it
# guards is precisely "a new platform branch was added and this call was forgotten".
_disp="$(sed -n '/^case "\$TARGET" in/,/^esac/p' "$ROOT/scripts/install.sh")"
_missing=""
while IFS= read -r _line; do
  case "$_line" in
    *'install_claude'*|*'install_codex'*|*'install_cursor'*|*'install_antigravity'*|*'install_kimi'*) ;;
    *) continue ;;
  esac
  case "$_line" in *'Usage:'*|*'#'*) continue ;; esac
  case "$_line" in
    *install_zuvo_home*) ;;
    *) _missing="$_missing $(printf '%s' "$_line" | sed 's/^[[:space:]]*//; s/).*//')" ;;
  esac
done <<EOF
$_disp
EOF
if [ -z "$_missing" ]; then
  pass "(11) every install.sh dispatch branch calls install_zuvo_home (B-9)"
else
  bad "(11) dispatch branch(es) without install_zuvo_home:$_missing — those installs ship zero ~/.zuvo helpers"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (12)-(14) The shared reviewer runner travels with EVERY installed copy of adversarial-review.
#
# Since Plan A Task 4 the driver's codex and claude lanes run through scripts/lib/model-subprocess.sh,
# which the driver looks for beside itself — <dir>/lib/model-subprocess.sh, then <dir>/model-
# subprocess.sh — and only then in ~/.zuvo. A driver installed without it still starts, prints one
# warning and loses both lanes: the install says ✓ and every review quietly shrinks. So each location
# is proven the way it is USED: the installed driver runs a codex review against a SPY client
# (tests/hooks/fixtures/model-subprocess/spy-cli — never a real client, no network), and the spy's
# record must show an isolated CODEX_HOME. Only a loaded runner gets that far: without it the codex
# lane fails before any client starts and leaves no record at all.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
RUNNER_LIB="$ROOT/scripts/lib/model-subprocess.sh"
SPY_FIX="$ROOT/tests/hooks/fixtures/model-subprocess"
SPY_SHIM="$TMP/spy-shim"; SPY_OFF="$TMP/spy-off"; SPY_WORK="$TMP/spy-work"; SPY_TMPD="$TMP/spy-tmp"
mkdir -p "$SPY_SHIM" "$SPY_OFF" "$SPY_WORK" "$SPY_TMPD"
# Real coreutils resolved BEFORE PATH is narrowed: without timeout/jq the driver exits before any
# client runs, and a missing record would then say nothing about the runner.
# shellcheck source=tests/lib/hermetic-tools.sh
. "$ROOT/tests/lib/hermetic-tools.sh"
hermetic_link_tools "$SPY_SHIM" timeout gtimeout jq
[ -e "$SPY_SHIM/timeout" ] || bad "(12) premise: no GNU timeout here — the installed drivers below cannot dispatch"
[ -e "$SPY_SHIM/jq" ] || bad "(12) premise: no jq here — the installed drivers below cannot dispatch"
cp "$SPY_FIX/spy-cli" "$SPY_OFF/codex"; chmod +x "$SPY_OFF/codex"
SPY_CH="$TMP/spy-codex-home"; cp -R "$SPY_FIX/codex-home" "$SPY_CH"   # dummy auth.json + a hostile user config
SPY_DIFF='diff --git a/src/auth.ts b/src/auth.ts
--- a/src/auth.ts
+++ b/src/auth.ts
@@ -10,3 +10,4 @@
 export function checkToken(token: string) {
   if (!token) return false;
+  return token.length > 8;
 }
'
# spy_review <tag> <driver> <home> — ONE `--mode code --provider codex-5.3` review by <driver> under
# `env -i`, HOME=<home>, from a neutral directory. The codex client is the spy named by ZUVO_CODEX_BIN;
# nothing called codex is on PATH. Record: $TMP/spy-<tag>/codex.rec; output: $TMP/spy-<tag>.{out,err}.
spy_review() {
  local rc=0
  rm -rf "$TMP/spy-$1"; mkdir -p "$TMP/spy-$1"
  ( cd "$SPY_WORK" && printf '%s' "$SPY_DIFF" | env -i HOME="$3" ZUVO_HOME="$3/.zuvo" TMPDIR="$SPY_TMPD" \
      CODEX_HOME="$SPY_CH" ZUVO_NO_CAFFEINATE=1 PATH="$SPY_SHIM:/usr/bin:/bin" SPY_DIR="$TMP/spy-$1" \
      ZUVO_CODEX_BIN="$SPY_OFF/codex" ZUVO_CODEX_APP_BIN=/nonexistent CLAUDECODE=1 CLAUDE_MODEL=opus \
      "$BASH" "$2" --mode code --provider codex-5.3 ) > "$TMP/spy-$1.out" 2> "$TMP/spy-$1.err" || rc=$?
  return "$rc"
}
# expect_runner_loaded <label> <tag> <rc> — the review ran on the shared runner: exit 0, the spy ran,
# with a CODEX_HOME the runner built (not the user's, none of its config), no missing-runner warning.
expect_runner_loaded() {
  local rec="$TMP/spy-$2/codex.rec" ch
  if [ "$3" -eq 0 ]; then pass "$1: the codex review exits 0"
  else bad "$1: the codex review exited $3 — $(tail -3 "$TMP/spy-$2.err" | tr '\n' ' ')"; fi
  if [ ! -s "$rec" ]; then
    bad "$1: the codex spy never ran — the driver did not load the shared runner [$(awk '/model-subprocess\.sh/' "$TMP/spy-$2.err" | head -1)]"
    return 0
  fi
  pass "$1: the codex spy ran (its record exists)"
  ch="$(awk '/^CODEX_HOME=/ {print substr($0, 12); exit}' "$rec")"
  case "$ch" in
    ""|"$SPY_CH"|*/spy-codex-home) bad "$1: codex ran with the user's CODEX_HOME [$ch], not an isolated one" ;;
    *) pass "$1: codex ran with an isolated CODEX_HOME" ;;
  esac
  if awk '/^config=/ && (/mcp_servers/ || /user-global-model/) {f = 1} END {exit !f}' "$rec"; then
    bad "$1: the isolated CODEX_HOME carries the user's config (mcp_servers / its model)"
  else pass "$1: …holding none of the user's config (no mcp_servers, not its model)"; fi
  if awk '/model-subprocess\.sh/ {f = 1} END {exit !f}' "$TMP/spy-$2.err"; then
    bad "$1: the driver warned about model-subprocess.sh — $(awk '/model-subprocess\.sh/' "$TMP/spy-$2.err" | head -1)"
  else pass "$1: no missing-runner warning"; fi
}

# lib_mismatch <src_lib_dir> <dst_lib_dir> — every REGULAR file of the source dir, checked at the
# destination by name: absent (or a symlink), different content, or an executable bit that does not
# follow the source. Prints the offenders; empty output = the whole dir arrived.
# ADV-C14: an EMPTY source dir must not report "byte-identical" (empty output) by the same vacuous
# for-loop-over-nothing shape this whole review kept finding elsewhere — a build regression that
# ships a hooks/lib dir with zero files is a real miss, not proof nothing was missed.
lib_mismatch() {
  local f n out="" seen=0
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    seen=1
    n="${f##*/}"
    if [ -L "$2/$n" ] || [ ! -f "$2/$n" ]; then out="$out $n(missing)"
    elif ! cmp -s "$f" "$2/$n"; then out="$out $n(differs)"
    elif [ -x "$f" ] && [ ! -x "$2/$n" ]; then out="$out $n(lost its exec bit)"
    elif [ ! -x "$f" ] && [ -x "$2/$n" ]; then out="$out $n(gained an exec bit)"
    fi
  done
  [ "$seen" -eq 1 ] || out="$out <source dir $1 has no regular files — cannot prove anything arrived>"
  printf '%s' "$out"
}
# temp_debris <dir> — dot-entries left in a lib dir (the installer's temp names start with a dot).
temp_debris() { ls -A "$1" 2>/dev/null | awk '/^\./' | tr '\n' ' '; }
# log_field <log> <KEY> — the value of the last KEY=value line in <log>.
# ADV-C40: stop at a literal ---DETAIL--- line — _hi_report puts one before its free-text detail,
# so a detail line that coincidentally looks like KEY=value (e.g. a path starting HOST_INSTALL_RC=)
# can never be misread as a real field.
# P2-110: every record is CR-stripped first (the sub() re-splits $1), so a CRLF-corrupted log still
# stops at its separator — `---DETAIL---\r` no longer runs on into the detail — and a value never
# carries a stray CR into the caller's comparison. P3C-23: EVERY trailing CR, not one — a line that went
# through two CRLF conversions ends in \r\r, and a single-CR strip left the second on the value.
log_field() { printf '%s\n' "$1" | awk -F= -v k="$2" '{ sub(/\r+$/, "") } $0 == "---DETAIL---" { exit } $1 == k {v = substr($0, length(k) + 2)} END {print v}'; }
_lf_crlf="$(printf 'INSTALL_VERIFY_MISSING=0\r\n---DETAIL---\r\nINSTALL_VERIFY_MISSING=9\r\n')"
if [ "$(log_field "$_lf_crlf" INSTALL_VERIFY_MISSING)" = 0 ]; then
  pass "log_field: a CRLF log stops at its ---DETAIL--- line and returns the field without a CR (P2-110)"
else
  bad "log_field: on a CRLF log it returned [$(log_field "$_lf_crlf" INSTALL_VERIFY_MISSING | od -c | head -1)], want [0] (P2-110)"
fi
_lf_crcr="$(printf 'INSTALL_VERIFY_MISSING=0\r\r\n---DETAIL---\r\r\nINSTALL_VERIFY_MISSING=9\r\r\n')"
if [ "$(log_field "$_lf_crcr" INSTALL_VERIFY_MISSING)" = 0 ]; then
  pass "log_field: a doubly converted log (CR CR LF) stops at its separator and returns the field with no CR left (P3C-23)"
else
  bad "log_field: on a CR CR LF log it returned [$(log_field "$_lf_crcr" INSTALL_VERIFY_MISSING | od -c | head -1)], want [0] (P3C-23)"
fi

# (12) ~/.zuvo — the flat install every skill calls by absolute path (~/.zuvo/adversarial-review).
# The installer is SOURCED in a fresh shell whose HOME is a temp dir. install_zuvo_home writes nothing
# outside $HOME (read before this was written: mkdir/cp/mv under $HOME/.zuvo, the refactor-radar
# bundle under $HOME/.zuvo, chflags only on retro files that do not exist here), so nothing needs a stub.
# zuvo_install <home> — install_zuvo_home into <home> under the shell options the installer's main run
# calls it with (set -euo pipefail), so an unguarded failing command inside it aborts here exactly as
# it would abort a real install. Prints its log, then — from an EXIT trap, so an abort is reported
# too — INSTALL_ZUVO_HOME_RC (install_zuvo_home's OWN status: the one it ended the shell with), the
# verify counter and its detail. (The first version read the child's exit status, which was the
# status of a trailing printf — "install_zuvo_home completes" could not fail.)
zuvo_install() {
  # shellcheck disable=SC2016  # expanded by the child shell
  HOME="$1" "$BASH" -c '. "$1" >/dev/null 2>&1 || { echo "SOURCE FAILED"; exit 97; }
    _zh_report() { printf "INSTALL_ZUVO_HOME_RC=%s\nINSTALL_VERIFY_MISSING=%s\n%s\n" "$1" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL"; }
    trap "_zh_report \$?" EXIT
    set -euo pipefail
    install_zuvo_home' _ "$INSTALL" 2>&1
}
# (12-premise) the harness SEES a failing install_zuvo_home: ~/.zuvo taken by a regular file, so its
# first `mkdir -p "$HOME/.zuvo"` fails and the installer's set -e ends the run there.
ZP="$(mktemp -d "$TMP/zuvo-premise.XXXXXX")"; : > "$ZP/.zuvo"
zp_rc="$(log_field "$(zuvo_install "$ZP")" INSTALL_ZUVO_HOME_RC)"
case "$zp_rc" in
  ""|0) bad "(12-premise) install_zuvo_home into a HOME whose ~/.zuvo is a FILE reported status [$zp_rc] — the harness cannot see a failed install" ;;
  *) pass "(12-premise) the harness reports install_zuvo_home's own failure (status $zp_rc)" ;;
esac
ZH="$(mktemp -d "$TMP/zuvo-home.XXXXXX")"
zh_log="$(zuvo_install "$ZH")"
zh_rc="$(log_field "$zh_log" INSTALL_ZUVO_HOME_RC)"; zh_miss="$(log_field "$zh_log" INSTALL_VERIFY_MISSING)"
if [ "$zh_rc" = 0 ] && [ "$zh_miss" = 0 ]; then
  pass "(12) install_zuvo_home into a temp HOME returns 0 with nothing missing"
else
  bad "(12) install_zuvo_home status=[$zh_rc] INSTALL_VERIFY_MISSING=[$zh_miss] — $(printf '%s' "$zh_log" | tail -4 | tr '\n' '|')"
fi
if [ -f "$ZH/.zuvo/model-subprocess.sh" ] && cmp -s "$RUNNER_LIB" "$ZH/.zuvo/model-subprocess.sh"; then
  pass "(12) ~/.zuvo/model-subprocess.sh is installed, byte-identical to scripts/lib/model-subprocess.sh"
else
  bad "(12) ~/.zuvo/model-subprocess.sh is $([ -e "$ZH/.zuvo/model-subprocess.sh" ] && echo 'different from' || echo 'not installed from') scripts/lib/model-subprocess.sh"
fi
# The ~/.zuvo driver looks in ~/.zuvo/lib/ FIRST, so that is where the fresh copy must be — through the
# same helper as the hosts: every regular file of scripts/lib/.
_mm="$(lib_mismatch "$ROOT/scripts/lib" "$ZH/.zuvo/lib")"
if [ -z "$_mm" ]; then
  pass "(12) ~/.zuvo/lib/ holds every regular file of scripts/lib/, byte-identical (the driver's first candidate)"
else
  bad "(12) ~/.zuvo/lib/ is not a copy of scripts/lib/:$_mm"
fi
rc=0; spy_review zuvo "$ZH/.zuvo/adversarial-review" "$ZH" || rc=$?
expect_runner_loaded "(12) the INSTALLED ~/.zuvo/adversarial-review" zuvo "$rc"
# (12m) Plan C Task 5 — ~/.zuvo/model-run (test-audit's batch dispatch calls it by that absolute path) and
# the router it calls, installed side by side. model-run looks for reviewer-model-route.sh beside itself
# first; the flat router must then find its runner (~/.zuvo/lib/model-subprocess.sh) and the registry
# (~/.zuvo/model-registry.sh) in ~/.zuvo too — nothing from the repo is reachable from this temp HOME. So
# the LONE installed copies are run as they are used: the router directly, then `~/.zuvo/model-run --route`
# on a Claude host, which must reach the codex spy with the registry's primary model and audit effort.
for _mrp in scripts/zuvo-home/model-run:model-run scripts/reviewer-model-route.sh:reviewer-model-route.sh \
            scripts/zuvo-home/test-audit-batch:test-audit-batch; do
  _mrs="$ROOT/${_mrp%%:*}"; _mrd="$ZH/.zuvo/${_mrp#*:}"
  if [ -f "$_mrd" ] && cmp -s "$_mrs" "$_mrd"; then
    pass "(12m) ~/.zuvo/${_mrp#*:} is installed, byte-identical to ${_mrp%%:*}"
  else
    bad "(12m) ~/.zuvo/${_mrp#*:} is $([ -e "$_mrd" ] && echo 'different from' || echo 'not installed from') ${_mrp%%:*}"
  fi
done
[ -x "$ZH/.zuvo/model-run" ] && pass "(12m) ~/.zuvo/model-run is executable" || bad "(12m) ~/.zuvo/model-run is not executable"
# test-audit Phase 1 calls ~/.zuvo/test-audit-batch by that path; it runs the model-run beside it.
[ -x "$ZH/.zuvo/test-audit-batch" ] && pass "(12m) ~/.zuvo/test-audit-batch is executable" || bad "(12m) ~/.zuvo/test-audit-batch is not executable"
_tab_rc=0; _tab_out="$( cd "$SPY_WORK" && env -i HOME="$ZH" PATH=/usr/bin:/bin "$ZH/.zuvo/test-audit-batch" group --nbatch 1 --first 1 --token t 2>&1 )" || _tab_rc=$?
if [ "$_tab_rc" -eq 2 ] && printf '%s\n' "$_tab_out" | grep -qF -- "--owner must be the harness pid"; then
  pass "(12m) the LONE ~/.zuvo/test-audit-batch starts under /bin/bash and answers a call without --owner with its usage error (exit 2)"
else
  bad "(12m) ~/.zuvo/test-audit-batch group without --owner exited $_tab_rc: $_tab_out"
fi
# The ids the installed pair must carry come from the INSTALLED registry — itself byte-identical to the
# source's — one variable per call, printed with %s.
if [ -f "$ZH/.zuvo/model-registry.sh" ] && cmp -s "$ROOT/shared/includes/model-registry.sh" "$ZH/.zuvo/model-registry.sh"; then
  pass "(12m) ~/.zuvo/model-registry.sh (the installed router's registry) is byte-identical to the source"
else
  bad "(12m) ~/.zuvo/model-registry.sh is missing or differs from shared/includes/model-registry.sh"
fi
# A registry that cannot be sourced, or an empty value, fails loudly (exit 97 / 98), never a quiet "".
_mr_reg() { env -i /bin/bash -c '. "$1" || exit 97; n="$2"; v="${!n:-}"; [ -n "$v" ] || exit 98; printf "%s" "$v"' _ "$ZH/.zuvo/model-registry.sh" "$1"; }
_mr_model="$(_mr_reg ZUVO_MODEL_CODEX_PRIMARY)" || bad "(12m) premise: the installed registry could not be sourced, or ZUVO_MODEL_CODEX_PRIMARY is empty"
_mr_effort="$(_mr_reg ZUVO_CODEX_EFFORT_AUDIT)" || bad "(12m) premise: the installed registry could not be sourced, or ZUVO_CODEX_EFFORT_AUDIT is empty"
_mr_env=(HOME="$ZH" TMPDIR="$SPY_TMPD" CODEX_HOME="$SPY_CH" PATH="$SPY_SHIM:/usr/bin:/bin" CLAUDECODE=1 LC_ALL=C
         ZUVO_CODEX_BIN="$SPY_OFF/codex" ZUVO_CODEX_APP_BIN=/nonexistent ZUVO_TIMEOUT_GRACE=1)
# The installed router's answer, as BYTES in a file, held to the strict six-key contract model-run and
# the preflight apply — by the ONE check they call, zms_route_contract_ok of the INSTALLED runner library
# (byte-identical to the source's, asserted above), not a copy of it kept here. The check is first shown
# to refuse a five-line answer, so a pass below is a verdict and not a function that accepts anything.
# A library that does not load, or does not define the check, is its OWN status (2, "lib failed to load"),
# never folded into a refusal — so the premise below can require the check's own refusal (status 1).
route_contract() {
  ( . "$ZH/.zuvo/lib/model-subprocess.sh" >/dev/null 2>&1 && declare -F zms_route_contract_ok >/dev/null \
      || { echo "lib failed to load"; exit 2; }
    zms_route_contract_ok "$1" )
}
_mr_rrc=0
( cd "$SPY_WORK" && env -i "${_mr_env[@]}" "$BASH" "$ZH/.zuvo/reviewer-model-route.sh" ) > "$TMP/mr-route.out" 2> "$TMP/mr-route.err" || _mr_rrc=$?
sed '$d' "$TMP/mr-route.out" > "$TMP/mr-route.short"
_mr_crc=0; _mr_why="$(route_contract "$TMP/mr-route.short")" || _mr_crc=$?
if [ "$_mr_crc" -eq 1 ]; then
  pass "(12m) premise: zms_route_contract_ok refuses the answer with its last line removed ($_mr_why)"
else
  bad "(12m) premise: zms_route_contract_ok did not refuse the answer with its last line removed (status $_mr_crc, want 1: $_mr_why)"
fi
_mr_why=""
if [ "$_mr_rrc" -eq 0 ] && _mr_why="$(route_contract "$TMP/mr-route.out")"; then
  pass "(12m) the installed router's answer is the strict six-key contract (exit 0, zms_route_contract_ok)"
else
  bad "(12m) the installed router's answer breaks the six-key contract (exit $_mr_rrc; ${_mr_why:-no reason}) [$(tr '\n' '|' < "$TMP/mr-route.out" 2>/dev/null)]"
fi
# Key by key — the contract fixes the keys, not their order — all SIX: a Claude host with CLAUDE_MODEL
# unset is an unknown writer in an unknown lane, reviewed cross-vendor by the registry's Codex primary.
for _mr_kv in platform=claude writer_model=unknown writer_lane=unknown reviewer_lane=cross-vendor "reviewer_model=$_mr_model" routing_status=ok; do
  _mr_k="${_mr_kv%%=*}"
  _mr_v="$(LC_ALL=C awk -v k="$_mr_k=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }' "$TMP/mr-route.out" 2>/dev/null)"
  if [ "$_mr_v" = "${_mr_kv#*=}" ]; then pass "(12m) the installed router answers $_mr_kv"
  else bad "(12m) the installed router answers $_mr_k=[$_mr_v], want [${_mr_kv#*=}]"; fi
done
if [ ! -s "$TMP/mr-route.err" ]; then
  pass "(12m) …with no warning: the flat router found its runner and registry in ~/.zuvo"
else
  bad "(12m) the installed router warned: $(tr '\n' ' ' < "$TMP/mr-route.err" 2>/dev/null)"
fi
rm -rf "$TMP/spy-mr"; mkdir -p "$TMP/spy-mr"; printf 'Audit the batch.\n' > "$TMP/mr-prompt.md"
_mr_rc=0
( cd "$SPY_WORK" && env -i "${_mr_env[@]}" SPY_DIR="$TMP/spy-mr" SPY_REPLY='Tier: A' \
    "$BASH" "$ZH/.zuvo/model-run" --route --mode audit --access read --read-root "$SPY_WORK" --prompt-file "$TMP/mr-prompt.md" ) \
  > "$TMP/mr.out" 2> "$TMP/mr.err" || _mr_rc=$?
_mr_line="$(tail -n 1 "$TMP/mr.err" 2>/dev/null)"
if [ "$_mr_rc" -eq 0 ] && [ "$_mr_line" = "model-run: status=ok client=codex model=$_mr_model effort=$_mr_effort route=cross-vendor" ]; then
  pass "(12m) the LONE ~/.zuvo/model-run --route resolves its router and runs the codex spy: $_mr_line"
else
  bad "(12m) ~/.zuvo/model-run --route exited $_mr_rc — stderr: $(tr '\n' '|' < "$TMP/mr.err" 2>/dev/null)"
fi
_mr_ch="$(awk '/^CODEX_HOME=/ { print substr($0, 12); exit }' "$TMP/spy-mr/codex.rec" 2>/dev/null)"
printf 'Tier: A\n' > "$TMP/mr.want"
if awk -v m="config=model = \"$_mr_model\"" '$0 == m {f = 1} END {exit !f}' "$TMP/spy-mr/codex.rec" 2>/dev/null \
   && [ -n "$_mr_ch" ] && [ "$_mr_ch" != "$SPY_CH" ] && cmp -s "$TMP/mr.out" "$TMP/mr.want"; then
  pass "(12m) …the spy saw the routed model in an isolated CODEX_HOME, and its answer came back on stdout"
else
  bad "(12m) the codex spy did not run with model $_mr_model, or the answer did not come back [$(cat "$TMP/mr.out" 2>/dev/null)]"
fi
# (12m-stale) The router's copy FAILS over an OLDER ~/.zuvo/reviewer-model-route.sh. install.sh copies
# with a bare `cp` (PATH lookup, install_zuvo_home's helper loop), so a cp stand-in first on PATH sees it:
# it refuses only a copy whose DESTINATION (the last argument) is the router in this sandbox's ~/.zuvo —
# the final name or the loop's `.reviewer-model-route.sh.tmp.*` staging name, quoted patterns — and runs
# the real cp for everything else. The install must REPORT it (INSTALL_VERIFY_MISSING, the structured
# counter the INSTALL INCOMPLETE exit reads; then the ✗ line and the detail) and remove the stale router —
# so ~/.zuvo/model-run --route fails loudly (route=no-router) instead of routing by an old table.
ZRS="$(mktemp -d "$TMP/zuvo-router-stale.XXXXXX")"; mkdir -p "$ZRS/.zuvo"
printf '#!/bin/sh\n# STALE router from an older install\nprintf "routing_status=ok\\n"\n' > "$ZRS/.zuvo/reviewer-model-route.sh"
ROUTEREFUSE_BIN="$TMP/router-refuse-bin"; mkdir -p "$ROUTEREFUSE_BIN"
# shellcheck disable=SC2016  # the stand-in's own $@ / $ZUVO_T_ZRS
printf '#!/bin/sh\n# cp stand-in: a copy whose destination is the router (or its staging name) in $ZUVO_T_ZRS/.zuvo fails\nfor a in "$@"; do last="$a"; done\ncase "${last:-}" in\n  "$ZUVO_T_ZRS/.zuvo/reviewer-model-route.sh"|"$ZUVO_T_ZRS/.zuvo/.reviewer-model-route.sh.tmp."*) echo "cp stand-in: refusing $last" >&2; exit 1 ;;\nesac\nexec "%s" "$@"\n' \
  "$(command -v cp)" > "$ROUTEREFUSE_BIN/cp"
chmod +x "$ROUTEREFUSE_BIN/cp"
zrs_log="$( PATH="$ROUTEREFUSE_BIN:$PATH" ZUVO_T_ZRS="$ZRS" zuvo_install "$ZRS" )"
if printf '%s\n' "$zrs_log" | grep -qF "reviewer-model-route.sh not installed (~/.zuvo/reviewer-model-route.sh)"; then
  pass "(12m-stale) premise: the router's copy really was refused (the install loop said so)"
else
  bad "(12m-stale) premise: the cp stand-in never refused the router's copy — the case proves nothing"
fi
if [ "$(log_field "$zrs_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zrs_log" INSTALL_VERIFY_MISSING)" = 1 ]; then
  pass "(12m-stale) the structured result: install_zuvo_home returns 0 and INSTALL_VERIFY_MISSING=1 (the main run's INSTALL INCOMPLETE exit 1)"
else
  bad "(12m-stale) status=[$(log_field "$zrs_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zrs_log" INSTALL_VERIFY_MISSING)] (want 0/1)"
fi
if printf '%s\n' "$zrs_log" | grep -qF "cross-vendor reviewer: $ZRS/.zuvo/reviewer-model-route.sh" \
   && printf '%s\n' "$zrs_log" | grep -qF "reviewer-model-route.sh did not install byte-identical"; then
  pass "(12m-stale) …and the log names it: a ✗ line and the INSTALL INCOMPLETE detail"
else
  bad "(12m-stale) the log does not name the router's failed install — $(printf '%s' "$zrs_log" | tail -3 | tr '\n' '|')"
fi
if [ ! -e "$ZRS/.zuvo/reviewer-model-route.sh" ] && [ ! -L "$ZRS/.zuvo/reviewer-model-route.sh" ]; then
  pass "(12m-stale) the STALE ~/.zuvo/reviewer-model-route.sh was removed"
else
  bad "(12m-stale) the STALE ~/.zuvo/reviewer-model-route.sh survived the failed install"
fi
if cmp -s "$ROOT/scripts/zuvo-home/model-run" "$ZRS/.zuvo/model-run"; then
  pass "(12m-stale) premise: ~/.zuvo/model-run itself installed (only the router's copy was refused)"
else
  bad "(12m-stale) premise: ~/.zuvo/model-run did not install — the case does not isolate the router"
fi
_mrs_rc=0
( cd "$SPY_WORK" && env -i HOME="$ZRS" TMPDIR="$SPY_TMPD" PATH="$SPY_SHIM:/usr/bin:/bin" CLAUDECODE=1 \
    ZUVO_CODEX_BIN="$SPY_OFF/codex" ZUVO_CODEX_APP_BIN=/nonexistent SPY_DIR="$TMP/spy-mr-stale" \
    "$BASH" "$ZRS/.zuvo/model-run" --route --prompt-file "$TMP/mr-prompt.md" ) > /dev/null 2> "$TMP/mr-stale.err" || _mrs_rc=$?
if [ "$_mrs_rc" -eq 1 ] && [ "$(tail -n 1 "$TMP/mr-stale.err")" = "model-run: status=unavailable client= model= effort= route=no-router" ]; then
  pass "(12m-stale) …so ~/.zuvo/model-run --route fails loudly: status=unavailable route=no-router"
else
  bad "(12m-stale) ~/.zuvo/model-run --route exited $_mrs_rc — stderr: $(tr '\n' '|' < "$TMP/mr-stale.err" 2>/dev/null)"
fi
# (12m-corrupt) The router's copy SUCCEEDS but lands DIFFERENT bytes (a cp stand-in runs the real cp, then
# appends to the staged router). Only the cmp verification can see it: the install must count it, name it,
# and remove the corrupt copy — never leave a router that is not the source's.
ZRC="$(mktemp -d "$TMP/zuvo-router-corrupt.XXXXXX")"; mkdir -p "$ZRC/.zuvo"
ROUTECORRUPT_BIN="$TMP/router-corrupt-bin"; mkdir -p "$ROUTECORRUPT_BIN"
# shellcheck disable=SC2016  # the stand-in's own $@ / $ZUVO_T_ZRC
printf '#!/bin/sh\n# cp stand-in: the router staged into $ZUVO_T_ZRC/.zuvo is copied, then CORRUPTED (one byte appended)\nfor a in "$@"; do last="$a"; done\n"%s" "$@" || exit\ncase "${last:-}" in\n  "$ZUVO_T_ZRC/.zuvo/.reviewer-model-route.sh.tmp."*) printf "#corrupt\\n" >> "$last" ;;\nesac\n' \
  "$(command -v cp)" > "$ROUTECORRUPT_BIN/cp"
chmod +x "$ROUTECORRUPT_BIN/cp"
zrc_log="$( PATH="$ROUTECORRUPT_BIN:$PATH" ZUVO_T_ZRC="$ZRC" zuvo_install "$ZRC" )"
if printf '%s\n' "$zrc_log" | grep -qF "reviewer-model-route.sh installed (~/.zuvo/reviewer-model-route.sh)"; then
  pass "(12m-corrupt) premise: the corrupted copy itself 'installed' (the copy step reported success)"
else
  bad "(12m-corrupt) premise: the router's copy step did not report success — the case does not isolate the cmp verification"
fi
if [ "$(log_field "$zrc_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zrc_log" INSTALL_VERIFY_MISSING)" = 1 ] \
   && printf '%s\n' "$zrc_log" | grep -qF "cross-vendor reviewer: $ZRC/.zuvo/reviewer-model-route.sh"; then
  pass "(12m-corrupt) the wrong bytes are REPORTED: INSTALL_VERIFY_MISSING=1, the detail names the router"
else
  bad "(12m-corrupt) status=[$(log_field "$zrc_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zrc_log" INSTALL_VERIFY_MISSING)] (want 0/1, the router named)"
fi
if [ ! -e "$ZRC/.zuvo/reviewer-model-route.sh" ]; then pass "(12m-corrupt) the corrupt router was removed (model-run then reports no-router, never a wrong route)"
else bad "(12m-corrupt) the corrupt ~/.zuvo/reviewer-model-route.sh was left in place"; fi
# (12m-registry) The router reads its model ids from ~/.zuvo/model-registry.sh, and test-audit runs
# model-run through ~/.zuvo/test-audit-batch. Both copies FAIL over OLDER files (the same cp stand-in,
# refusing these two destinations). A stale registry would keep routing last release's ids with only a
# warning in the log; a stale batch script would keep last release's dispatch. The install must count
# both, name both, and remove both stale copies.
ZRG="$(mktemp -d "$TMP/zuvo-registry-stale.XXXXXX")"; mkdir -p "$ZRG/.zuvo"
printf '# STALE registry from an older install\nZUVO_MODEL_CODEX_PRIMARY=gpt-stale-id\n' > "$ZRG/.zuvo/model-registry.sh"
printf '#!/bin/sh\n# STALE batch script from an older install\n' > "$ZRG/.zuvo/test-audit-batch"
REGREFUSE_BIN="$TMP/registry-refuse-bin"; mkdir -p "$REGREFUSE_BIN"
# shellcheck disable=SC2016  # the stand-in's own $@ / $ZUVO_T_ZRG
printf '#!/bin/sh\n# cp stand-in: a copy whose destination is the registry or the batch script (or its staging name) in $ZUVO_T_ZRG/.zuvo fails\nfor a in "$@"; do last="$a"; done\ncase "${last:-}" in\n  "$ZUVO_T_ZRG/.zuvo/model-registry.sh"|"$ZUVO_T_ZRG/.zuvo/.model-registry.sh.tmp."*|"$ZUVO_T_ZRG/.zuvo/test-audit-batch"|"$ZUVO_T_ZRG/.zuvo/.test-audit-batch.tmp."*) echo "cp stand-in: refusing $last" >&2; exit 1 ;;\nesac\nexec "%s" "$@"\n' \
  "$(command -v cp)" > "$REGREFUSE_BIN/cp"
chmod +x "$REGREFUSE_BIN/cp"
zrg_log="$( PATH="$REGREFUSE_BIN:$PATH" ZUVO_T_ZRG="$ZRG" zuvo_install "$ZRG" )"
if printf '%s\n' "$zrg_log" | grep -qF "model-registry.sh not installed (~/.zuvo/model-registry.sh)" \
   && printf '%s\n' "$zrg_log" | grep -qF "test-audit-batch not installed (~/.zuvo/test-audit-batch)"; then
  pass "(12m-registry) premise: both copies really were refused (the install loop said so)"
else
  bad "(12m-registry) premise: the cp stand-in never refused the registry's and the batch script's copies — the case proves nothing"
fi
if [ "$(log_field "$zrg_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zrg_log" INSTALL_VERIFY_MISSING)" = 2 ]; then
  pass "(12m-registry) the structured result: install_zuvo_home returns 0 and INSTALL_VERIFY_MISSING=2 (INSTALL INCOMPLETE)"
else
  bad "(12m-registry) status=[$(log_field "$zrg_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zrg_log" INSTALL_VERIFY_MISSING)] (want 0/2): a stale registry / batch script went uncounted"
fi
for _zrg_f in model-registry.sh test-audit-batch; do
  if printf '%s\n' "$zrg_log" | grep -qF "cross-vendor reviewer: $ZRG/.zuvo/$_zrg_f" \
     && printf '%s\n' "$zrg_log" | grep -qF "$_zrg_f did not install byte-identical"; then
    pass "(12m-registry) the log names ~/.zuvo/$_zrg_f: a ✗ line and the INSTALL INCOMPLETE detail"
  else
    bad "(12m-registry) the log does not name the failed install of ~/.zuvo/$_zrg_f"
  fi
  if [ ! -e "$ZRG/.zuvo/$_zrg_f" ] && [ ! -L "$ZRG/.zuvo/$_zrg_f" ]; then
    pass "(12m-registry) the STALE ~/.zuvo/$_zrg_f was removed"
  else
    bad "(12m-registry) the STALE ~/.zuvo/$_zrg_f survived the failed install"
  fi
done
# …so the router, left without a registry, fails closed instead of routing the stale id.
_zrg_rc=0
( cd "$SPY_WORK" && env -i HOME="$ZRG" TMPDIR="$SPY_TMPD" PATH="$SPY_SHIM:/usr/bin:/bin" CLAUDECODE=1 LC_ALL=C \
    ZUVO_CODEX_BIN="$SPY_OFF/codex" ZUVO_CODEX_APP_BIN=/nonexistent "$BASH" "$ZRG/.zuvo/reviewer-model-route.sh" ) \
  > "$TMP/zrg-route.out" 2> "$TMP/zrg-route.err" || _zrg_rc=$?
if grep -qx 'routing_status=routing-failed' "$TMP/zrg-route.out" && ! grep -q 'gpt-stale-id' "$TMP/zrg-route.out"; then
  pass "(12m-registry) …and the installed router, with no registry left, answers routing-failed — never the stale id"
else
  bad "(12m-registry) the installed router answered [$(tr '\n' '|' < "$TMP/zrg-route.out" 2>/dev/null)] (exit $_zrg_rc) — want routing_status=routing-failed and no stale id"
fi
# (12b) …and a copy that did not land is LOUD: counted for the final INSTALL INCOMPLETE summary and
# named, never swallowed — and REFUSED: the flat destination is taken by a DIRECTORY, where a bare
# `mv -f tmp dst` moves the temp INTO it. The install carries on (status 0, the miss is counted), and
# nothing lands inside the directory.
ZB="$(mktemp -d "$TMP/zuvo-blocked.XXXXXX")"; mkdir -p "$ZB/.zuvo/model-subprocess.sh"
zb_log="$(zuvo_install "$ZB")"
if [ "$(log_field "$zb_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zb_log" INSTALL_VERIFY_MISSING)" = 1 ] \
   && printf '%s\n' "$zb_log" | grep -qF "$ZB/.zuvo/model-subprocess.sh"; then
  pass "(12b) a ~/.zuvo/model-subprocess.sh that did not install is counted and named (INSTALL INCOMPLETE), and the install carries on"
else
  bad "(12b) a failed ~/.zuvo/model-subprocess.sh went unreported or aborted the install — $(printf '%s' "$zb_log" | tail -3 | tr '\n' '|')"
fi
# `-d` first: the blocking path must still BE the directory. `ls -A` of a path that vanished prints
# nothing too, so without it an install that deleted the blocker would pass as "nothing moved in".
if [ -d "$ZB/.zuvo/model-subprocess.sh" ] && [ -z "$(ls -A "$ZB/.zuvo/model-subprocess.sh" 2>/dev/null)" ] \
   && ! compgen -G "$ZB/.zuvo/.model-subprocess.sh.*" >/dev/null; then
  pass "(12b) nothing was moved into the directory in the way, and no temp file was left beside it"
else
  bad "(12b) the install wrote into the directory in the way [$(ls -A "$ZB/.zuvo/model-subprocess.sh" 2>/dev/null | tr '\n' ' ')] or left a temp [$(compgen -G "$ZB/.zuvo/.model-subprocess.sh.*" | tr '\n' ' ')]"
fi
# (12c) A STALE ~/.zuvo/lib/model-subprocess.sh — an older install, a manual copy — sits where the
# ~/.zuvo driver looks first. The install must replace it: otherwise it silently shadows the fresh flat
# copy on every review. This stale one leaves a mark when sourced, so the review below proves which
# copy the installed driver really loaded.
ZS="$(mktemp -d "$TMP/zuvo-stale.XXXXXX")"; mkdir -p "$ZS/.zuvo/lib"
printf ': > "%s/stale-lib-sourced"\n' "$TMP" > "$ZS/.zuvo/lib/model-subprocess.sh"
zs_log="$(zuvo_install "$ZS")"
if [ "$(log_field "$zs_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zs_log" INSTALL_VERIFY_MISSING)" = 0 ] \
   && cmp -s "$RUNNER_LIB" "$ZS/.zuvo/lib/model-subprocess.sh"; then
  pass "(12c) a stale ~/.zuvo/lib/model-subprocess.sh is replaced by the source's"
else
  bad "(12c) a stale ~/.zuvo/lib/model-subprocess.sh survived the install — $(printf '%s' "$zs_log" | tail -3 | tr '\n' '|')"
fi
rc=0; spy_review zuvo-stale "$ZS/.zuvo/adversarial-review" "$ZS" || rc=$?
expect_runner_loaded "(12c) the ~/.zuvo driver after a stale ~/.zuvo/lib/ copy" zuvo-stale "$rc"
if [ -e "$TMP/stale-lib-sourced" ]; then
  bad "(12c) the installed ~/.zuvo/adversarial-review SOURCED the stale ~/.zuvo/lib/model-subprocess.sh"
else
  pass "(12c) the installed ~/.zuvo/adversarial-review did not source the stale copy"
fi
# (12d) ~/.zuvo/lib/ did NOT install (the name is taken by a regular file, so its mkdir fails) while
# the flat ~/.zuvo/model-subprocess.sh did. The ✓ line must not claim ~/.zuvo/lib/: every library
# there is counted and named, the flat copy still lands, and the install carries on.
ZL="$(mktemp -d "$TMP/zuvo-libblocked.XXXXXX")"; mkdir -p "$ZL/.zuvo"; : > "$ZL/.zuvo/lib"
zl_log="$(zuvo_install "$ZL")"
_nlib=0; for _f in "$ROOT"/scripts/lib/*; do [ -f "$_f" ] && _nlib=$((_nlib + 1)); done
if [ "$(log_field "$zl_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zl_log" INSTALL_VERIFY_MISSING)" = "$_nlib" ] \
   && printf '%s\n' "$zl_log" | grep -qF "$ZL/.zuvo/lib/model-subprocess.sh"; then
  pass "(12d) a ~/.zuvo/lib/ that did not install: all $_nlib libraries counted and named, and the install carries on"
else
  bad "(12d) a blocked ~/.zuvo/lib/: status=[$(log_field "$zl_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zl_log" INSTALL_VERIFY_MISSING)] (want 0/$_nlib, the runner named) — $(printf '%s' "$zl_log" | tail -3 | tr '\n' '|')"
fi
if printf '%s\n' "$zl_log" | awk '/✓/ && /\.zuvo\/lib/ {f = 1} END {exit !f}'; then
  bad "(12d) a ✓ line claims ~/.zuvo/lib/ although it did not install: [$(printf '%s\n' "$zl_log" | awk '/✓/ && /\.zuvo\/lib/' | head -1)]"
else
  pass "(12d) no ✓ line claims ~/.zuvo/lib/ when it did not install"
fi
if cmp -s "$RUNNER_LIB" "$ZL/.zuvo/model-subprocess.sh"; then
  pass "(12d) the flat ~/.zuvo/model-subprocess.sh still installed"
else
  bad "(12d) the flat ~/.zuvo/model-subprocess.sh did not install beside a blocked ~/.zuvo/lib/"
fi
# (12e) A STALE ~/.zuvo/lib/model-subprocess.sh AND a ~/.zuvo/lib/ that REFUSES the new copy, while the
# flat ~/.zuvo/model-subprocess.sh installs. The stale copy is the ~/.zuvo driver's FIRST candidate:
# left in place it shadows the fresh flat one on every review, although the miss is counted. The
# refusal is a cp stand-in that corrupts every copy staged INSIDE ~/.zuvo/lib/ (install_file_atomic's
# content check then refuses it) and is the real cp everywhere else. The stale copy is the COMPLETE
# runner plus one marker line — it passes any load check the driver makes — so only its removal from
# the load path keeps the marker away.
ZE="$(mktemp -d "$TMP/zuvo-stale-refused.XXXXXX")"; mkdir -p "$ZE/.zuvo/lib"
{ cat "$RUNNER_LIB"; printf '\n: > "%s/stale-refused-sourced"\n' "$TMP"; } > "$ZE/.zuvo/lib/model-subprocess.sh"
LIBREFUSE_BIN="$TMP/lib-refuse-bin"; mkdir -p "$LIBREFUSE_BIN"
# shellcheck disable=SC2016  # the stand-in's own $1/$2/$@
printf '#!/bin/sh\n# cp stand-in: a copy staged inside ~/.zuvo/lib/ gets 16 bytes; anything else is the real cp\ncase "$2" in */.zuvo/lib/*) head -c 16 "$1" > "$2"; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$(command -v cp)" > "$LIBREFUSE_BIN/cp"
chmod +x "$LIBREFUSE_BIN/cp"
ze_log="$( PATH="$LIBREFUSE_BIN:$PATH"; zuvo_install "$ZE" )"
if [ "$(log_field "$ze_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$ze_log" INSTALL_VERIFY_MISSING)" = "$_nlib" ] \
   && printf '%s\n' "$ze_log" | grep -qF "$ZE/.zuvo/lib/model-subprocess.sh"; then
  pass "(12e) a ~/.zuvo/lib/ that refuses the new copies: all $_nlib counted and named (the miss stays), and the install carries on"
else
  bad "(12e) a refusing ~/.zuvo/lib/: status=[$(log_field "$ze_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$ze_log" INSTALL_VERIFY_MISSING)] (want 0/$_nlib) — $(printf '%s' "$ze_log" | tail -3 | tr '\n' '|')"
fi
if cmp -s "$RUNNER_LIB" "$ZE/.zuvo/model-subprocess.sh"; then pass "(12e) premise: the flat ~/.zuvo/model-subprocess.sh installed fresh"
else bad "(12e) premise: the flat ~/.zuvo/model-subprocess.sh did not install — the case proves nothing"; fi
if [ ! -e "$ZE/.zuvo/lib/model-subprocess.sh" ] && [ ! -L "$ZE/.zuvo/lib/model-subprocess.sh" ]; then
  pass "(12e) the STALE ~/.zuvo/lib/model-subprocess.sh was removed (it can no longer shadow the flat copy)"
else
  bad "(12e) the STALE ~/.zuvo/lib/model-subprocess.sh is still there, the ~/.zuvo driver's first candidate"
fi
expect_log_has() { if printf '%s\n' "$2" | grep -qF -e "$3"; then pass "$1"; else bad "$1 — [$3] not in the log: $(printf '%s' "$2" | awk '/✗|!/' | tail -3 | tr '\n' '|')"; fi; }
expect_log_has "(12e) …and the install says so" "$ze_log" "removed the STALE $ZE/.zuvo/lib/model-subprocess.sh"
rm -f "$TMP/stale-refused-sourced"
rc=0; spy_review zuvo-stale-refused "$ZE/.zuvo/adversarial-review" "$ZE" || rc=$?
expect_runner_loaded "(12e) the ~/.zuvo driver after a refused lib install over a stale copy" zuvo-stale-refused "$rc"
if [ -e "$TMP/stale-refused-sourced" ]; then
  bad "(12e) the installed ~/.zuvo/adversarial-review SOURCED the stale ~/.zuvo/lib/model-subprocess.sh, not the fresh flat copy"
else
  pass "(12e) the installed ~/.zuvo/adversarial-review loaded the FRESH flat copy (the stale one's marker is absent)"
fi
# (12f) …and when the stale copy CANNOT be removed (a read-only ~/.zuvo/lib/: the new copy cannot be
# staged there, and nothing can be unlinked either), the install says so loudly and names it in the
# summary; the miss stays counted and the install carries on.
ZR="$(mktemp -d "$TMP/zuvo-stale-ro.XXXXXX")"; mkdir -p "$ZR/.zuvo/lib"
printf '# stale runner from an older install\n' > "$ZR/.zuvo/lib/model-subprocess.sh"
chmod 555 "$ZR/.zuvo/lib"
if ( : > "$ZR/.zuvo/lib/.write-probe" ) 2>/dev/null; then
  rm -f "$ZR/.zuvo/lib/.write-probe"
  echo "SKIP: (12f) this user can write into a 0555 directory (root?) — a read-only ~/.zuvo/lib/ cannot be staged; (12f, stand-in) below drives the same branch"
else
  zr_log="$(zuvo_install "$ZR")"
  if [ "$(log_field "$zr_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zr_log" INSTALL_VERIFY_MISSING)" = "$_nlib" ]; then
    pass "(12f) a read-only ~/.zuvo/lib/ holding a stale runner: all $_nlib counted, and the install carries on"
  else
    bad "(12f) a read-only ~/.zuvo/lib/: status=[$(log_field "$zr_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zr_log" INSTALL_VERIFY_MISSING)] (want 0/$_nlib)"
  fi
  expect_log_has "(12f) …it says the stale copy could not be removed, naming it" "$zr_log" "a STALE $ZR/.zuvo/lib/model-subprocess.sh could not be removed"
  expect_log_has "(12f) …and the summary detail names it too" "$zr_log" "stale runner: $ZR/.zuvo/lib/model-subprocess.sh"
fi
chmod 755 "$ZR/.zuvo/lib"
# (12f, stand-in) The same branch without file permissions, so it runs as root too: the cp stand-in of
# (12e) refuses every copy staged in ~/.zuvo/lib/, and an rm stand-in first on PATH fails for the stale
# runner there (and is the real rm everywhere else) — the stale copy can neither be replaced nor removed.
ZS="$(mktemp -d "$TMP/zuvo-stale-rmfail.XXXXXX")"; mkdir -p "$ZS/.zuvo/lib"
printf '# stale runner from an older install\n' > "$ZS/.zuvo/lib/model-subprocess.sh"
RMFAIL_BIN="$TMP/rm-fail-bin"; mkdir -p "$RMFAIL_BIN"
cp "$LIBREFUSE_BIN/cp" "$RMFAIL_BIN/cp"
# shellcheck disable=SC2016  # the stand-in's own $@
printf '#!/bin/sh\n# rm stand-in: refuses the stale runner in ~/.zuvo/lib/; anything else is the real rm\nfor a in "$@"; do case "$a" in */.zuvo/lib/model-subprocess.sh) exit 1 ;; esac; done\nexec "%s" "$@"\n' \
  "$(command -v rm)" > "$RMFAIL_BIN/rm"
chmod +x "$RMFAIL_BIN/cp" "$RMFAIL_BIN/rm"
zs_log="$( PATH="$RMFAIL_BIN:$PATH"; zuvo_install "$ZS" )"
if [ "$(log_field "$zs_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zs_log" INSTALL_VERIFY_MISSING)" = "$_nlib" ]; then
  pass "(12f, stand-in) a stale runner that cannot be removed: all $_nlib counted, and the install carries on"
else
  bad "(12f, stand-in) status=[$(log_field "$zs_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zs_log" INSTALL_VERIFY_MISSING)] (want 0/$_nlib)"
fi
if [ -f "$ZS/.zuvo/lib/model-subprocess.sh" ]; then pass "(12f, stand-in) premise: the stale runner is still in place (the rm stand-in refused it)"
else bad "(12f, stand-in) premise: the stale runner is gone — the rm stand-in did not intercept, the case proves nothing"; fi
expect_log_has "(12f, stand-in) …it says the stale copy could not be removed, naming it" "$zs_log" "a STALE $ZS/.zuvo/lib/model-subprocess.sh could not be removed"
expect_log_has "(12f, stand-in) …and the summary detail names it too" "$zs_log" "stale runner: $ZS/.zuvo/lib/model-subprocess.sh"

# (13) The Claude Code plugin cache: every cache dir gets the WHOLE scripts/lib/ beside scripts/, and
# Claude Code puts <cache dir>/bin on PATH — bin/adversarial-review execs ../scripts/adversarial-
# review.sh, whose sibling lib/ is the first place it looks. This HOME has no ~/.zuvo, so the sibling is
# the only runner it can load. install_claude writes only under $HOME (read before this was written;
# installed_plugins.json is touched only when it exists, and it does not here).
ZC="$(mktemp -d "$TMP/claude-home.XXXXXX")"; ZC_BASE="$ZC/.claude/plugins/cache/zuvo-marketplace/zuvo"
mkdir -p "$ZC_BASE"
# shellcheck disable=SC2016  # expanded by the child shell
zc_log="$(HOME="$ZC" "$BASH" -c '. "$1" >/dev/null 2>&1 || { echo "SOURCE FAILED"; exit 97; }
  install_claude || exit $?
  printf "CACHE_VERSION=%s\n" "$VERSION"' _ "$INSTALL" 2>&1)"; zc_rc=$?
zc_ver="$(printf '%s\n' "$zc_log" | awk -F= '$1 == "CACHE_VERSION" {v = $2} END {print v}')"
ZC_DIR="$ZC_BASE/$zc_ver"
if [ "$zc_rc" -eq 0 ] && [ -n "$zc_ver" ] && [ -d "$ZC_DIR/scripts" ]; then
  pass "(13) install_claude into a temp HOME populates cache dir $zc_ver"
else
  bad "(13) install_claude rc=$zc_rc version=[$zc_ver] — $(printf '%s' "$zc_log" | tail -4 | tr '\n' '|')"
fi
if cmp -s "$RUNNER_LIB" "$ZC_DIR/scripts/lib/model-subprocess.sh"; then
  pass "(13) the cache dir carries scripts/lib/model-subprocess.sh, byte-identical to the source"
else
  bad "(13) the cache dir has no (or a different) scripts/lib/model-subprocess.sh"
fi
rc=0; spy_review claude-cache "$ZC_DIR/bin/adversarial-review" "$ZC" || rc=$?
expect_runner_loaded "(13) the cache's bin/adversarial-review (the PATH entry Claude Code adds)" claude-cache "$rc"
# (13b) …in EVERY cache dir: Claude Code keeps a version dir AND a SHA dir and may load either, so the
# lib install must sit inside the per-CACHE_DIR loop (the same parse as (9)) — through the same
# helper as every other host (atomic, content-verified, a miss counted: (13c)).
_lib_place="$(awk '
  /for CACHE_DIR in/           { inloop = 1; depth = 1; next }
  inloop && /(^|[[:space:]])(do|then)[[:space:]]*$/ { depth++ }
  inloop && /^[[:space:]]*(done|fi)[[:space:]]*$/   { depth--; if (depth == 0) inloop = 0 }
  inloop && /^[^#]*install_runner_lib / && index($0, "\"$ZUVO_DIR/scripts/lib\" \"${CACHE_DIR%/}/scripts\"") { found = 1 }
  END { print (found ? "inside" : "outside") }
' "$INSTALL")"
if [ "$_lib_place" = "inside" ]; then
  pass "(13b) the scripts/lib install (install_runner_lib) is INSIDE the per-CACHE_DIR loop (every cache dir gets the runner)"
else
  bad "(13b) no install_runner_lib of scripts/lib inside the per-CACHE_DIR loop — some cache dirs' drivers would run without the runner"
fi
# (13c) …and a cache lib that did not install is COUNTED for INSTALL INCOMPLETE and named, like every
# other host's — not a WARN line with a zero miss count. The cache dir's scripts/lib is taken by a
# regular file (in the seed dir, so the version dir cp'd from it has the same block).
ZCB="$(mktemp -d "$TMP/claude-blocked.XXXXXX")"; ZCB_BASE="$ZCB/.claude/plugins/cache/zuvo-marketplace/zuvo"
mkdir -p "$ZCB_BASE/blocked-seed/skills" "$ZCB_BASE/blocked-seed/shared/includes" "$ZCB_BASE/blocked-seed/rules" \
         "$ZCB_BASE/blocked-seed/scripts" "$ZCB_BASE/blocked-seed/bin" "$ZCB_BASE/blocked-seed/docs"
: > "$ZCB_BASE/blocked-seed/scripts/lib"
# shellcheck disable=SC2016  # expanded by the child shell
zcb_log="$(HOME="$ZCB" "$BASH" -c '. "$1" >/dev/null 2>&1 || { echo "SOURCE FAILED"; exit 97; }
  _ic_rc=0; install_claude || _ic_rc=$?
  printf "INSTALL_CLAUDE_RC=%s\nINSTALL_VERIFY_MISSING=%s\n%s\n" "$_ic_rc" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL"' _ "$INSTALL" 2>&1)"
zcb_miss="$(log_field "$zcb_log" INSTALL_VERIFY_MISSING)"
if [ "${zcb_miss:-0}" -ge "$_nlib" ] 2>/dev/null \
   && printf '%s\n' "$zcb_log" | grep -qF "$ZCB_BASE/blocked-seed/scripts/lib/model-subprocess.sh"; then
  pass "(13c) a cache scripts/lib that did not install is counted ($zcb_miss) and named for INSTALL INCOMPLETE"
else
  bad "(13c) a blocked cache scripts/lib: INSTALL_VERIFY_MISSING=[$zcb_miss] (want >= $_nlib, the cache runner named) — $(printf '%s' "$zcb_log" | awk '/WARN|✗/' | head -2 | tr '\n' '|')"
fi

# (14) Codex, Cursor, Antigravity and Kimi each get their OWN copy of the driver in <host>/scripts/ —
# the path their skills call. The runner goes into <host>/scripts/lib/ beside it through ONE helper,
# install_runner_lib, so a host's driver and its runner always come from the same install: `install.sh
# claude` refreshes ~/.zuvo but not ~/.codex/scripts, and a host driver that could only reach ~/.zuvo's
# runner would run against a library from a different install.
# (14a) the helper, in a host layout (the driver copied where install_codex copies it; no ~/.zuvo).
# Its source is a COPY of scripts/lib/ plus one fixture file, blind-audit-panel.sh — the name Plan B
# adds. The contract is the whole directory, not one hard-coded name: a library added to scripts/lib/
# later must reach every host with no installer change, or it is silently missing on all of them.
LIBCOPY="$TMP/lib-copy"; mkdir -p "$LIBCOPY"
for _f in "$ROOT"/scripts/lib/*; do [ -f "$_f" ] && cp -p "$_f" "$LIBCOPY/"; done
printf '# blind-audit-panel.sh - test fixture standing in for a library added to scripts/lib/ later\n' > "$LIBCOPY/blind-audit-panel.sh"
HH="$(mktemp -d "$TMP/host-home.XXXXXX")"; mkdir -p "$HH/.codex/scripts"
cp "$ROOT/scripts/adversarial-review.sh" "$HH/.codex/scripts/adversarial-review.sh"
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
irl_rc=0; install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HH/.codex/scripts" >/dev/null 2>&1 || irl_rc=$?
_mm="$(lib_mismatch "$LIBCOPY" "$HH/.codex/scripts/lib")"
if [ "$irl_rc" -eq 0 ] && [ "$INSTALL_VERIFY_MISSING" -eq 0 ] && [ -z "$_mm" ]; then
  pass "(14a) install_runner_lib ships EVERY regular file of the lib dir into <host>/scripts/lib/ — byte-identical, exec bit following the source"
else
  bad "(14a) install_runner_lib rc=$irl_rc missing=$INSTALL_VERIFY_MISSING, not delivered:$_mm"
fi
if cmp -s "$LIBCOPY/blind-audit-panel.sh" "$HH/.codex/scripts/lib/blind-audit-panel.sh"; then
  pass "(14a) a file added to the lib dir later (fixture blind-audit-panel.sh) reaches the host lib dir"
else
  bad "(14a) the fixture blind-audit-panel.sh did not reach the host lib dir — a new scripts/lib/ library would be missing on every host"
fi
_deb="$(temp_debris "$HH/.codex/scripts/lib")"
[ -z "$_deb" ] && pass "(14a) no temp files left in the host lib dir" || bad "(14a) temp debris left in the host lib dir: $_deb"
rc=0; spy_review host "$HH/.codex/scripts/adversarial-review.sh" "$HH" || rc=$?
expect_runner_loaded "(14a) a host copy of the driver (~/.codex/scripts layout, no ~/.zuvo)" host "$rc"
# (14a-dir) The destination NAME is taken by a directory. A bare `mv -f tmp dst` moves the temp INTO it
# and returns 0. Refused by name instead: counted and named, nothing inside the directory, no temp
# left — and the other files of the lib dir still install.
HD="$(mktemp -d "$TMP/host-dirblock.XXXXXX")"; mkdir -p "$HD/.codex/scripts/lib/model-subprocess.sh"
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
hd_rc=0; install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HD/.codex/scripts" > "$TMP/hd.out" 2>&1 || hd_rc=$?
if [ "$hd_rc" -eq 1 ] && [ "$INSTALL_VERIFY_MISSING" -eq 1 ]; then
  case "$INSTALL_VERIFY_DETAIL" in
    *"$HD/.codex/scripts/lib/model-subprocess.sh"*"not a regular file"*) pass "(14a-dir) a destination taken by a directory is refused, counted and named" ;;
    *) bad "(14a-dir) counted, but the summary does not name the path and the reason: [$INSTALL_VERIFY_DETAIL]" ;;
  esac
else
  bad "(14a-dir) a destination taken by a directory: rc=$hd_rc missing=$INSTALL_VERIFY_MISSING (want 1/1) — $(tr '\n' ' ' < "$TMP/hd.out")"
fi
if [ -d "$HD/.codex/scripts/lib/model-subprocess.sh" ] && [ -z "$(ls -A "$HD/.codex/scripts/lib/model-subprocess.sh" 2>/dev/null)" ] \
   && [ -z "$(temp_debris "$HD/.codex/scripts/lib")" ]; then
  pass "(14a-dir) nothing was moved into the directory, and no temp file was left"
else
  bad "(14a-dir) the directory in the way now holds [$(ls -A "$HD/.codex/scripts/lib/model-subprocess.sh" 2>/dev/null | tr '\n' ' ')], temp debris [$(temp_debris "$HD/.codex/scripts/lib")]"
fi
if cmp -s "$LIBCOPY/portable.sh" "$HD/.codex/scripts/lib/portable.sh" && cmp -s "$LIBCOPY/blind-audit-panel.sh" "$HD/.codex/scripts/lib/blind-audit-panel.sh"; then
  pass "(14a-dir) one refused file does not stop the rest of the lib dir"
else
  bad "(14a-dir) one refused file stopped the rest of the lib dir from installing"
fi
# (14a-ro) A step that FAILS must fail the helper even when the destination already holds the right
# bytes from an earlier install: the first version swallowed the temp-copy/mv failures and then asked
# `cmp`, which passed against the PREVIOUS file. The lib dir is made read-only after a good install.
HR="$(mktemp -d "$TMP/host-ro.XXXXXX")"; mkdir -p "$HR/.codex/scripts"
install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HR/.codex/scripts" >/dev/null 2>&1 || true
chmod 555 "$HR/.codex/scripts/lib"
_nfiles=0; for _f in "$LIBCOPY"/*; do [ -f "$_f" ] && _nfiles=$((_nfiles + 1)); done
if ( : > "$HR/.codex/scripts/lib/.write-probe" ) 2>/dev/null; then
  rm -f "$HR/.codex/scripts/lib/.write-probe"
  echo "SKIP: (14a-ro) this user can write into a 0555 directory (root?) — a read-only destination cannot be staged; (14a-ro, stand-in) below drives the same branch"
else
  INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
  ro_rc=0; install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HR/.codex/scripts" > "$TMP/ro.out" 2>&1 || ro_rc=$?
  if [ "$ro_rc" -eq 1 ] && [ "$INSTALL_VERIFY_MISSING" -eq "$_nfiles" ]; then
    case "$INSTALL_VERIFY_DETAIL" in
      *"$HR/.codex/scripts/lib/model-subprocess.sh"*"mktemp failed"*) pass "(14a-ro) a failed step is a miss even over matching old bytes — all $_nfiles counted, the failed step named" ;;
      *) bad "(14a-ro) counted, but the summary does not name the path and the failed step: [$INSTALL_VERIFY_DETAIL]" ;;
    esac
  else
    bad "(14a-ro) read-only destination holding the old bytes: rc=$ro_rc missing=$INSTALL_VERIFY_MISSING (want 1/$_nfiles) — a failed install reported success"
  fi
fi
chmod 755 "$HR/.codex/scripts/lib"
# (14a-ro, stand-in) The same branch without file permissions, so it runs as root too (root writes into
# a 0555 dir, and the case above SKIPs there): install_file_atomic resolves `mktemp` on PATH, and a
# stand-in that fails is first on it — in a subshell, like the cp stand-in of (14a-trunc). Over a lib dir
# holding a good install: every file counted, "mktemp failed" named, the old bytes kept, no temp left.
HM="$(mktemp -d "$TMP/host-mktemp.XXXXXX")"; mkdir -p "$HM/.codex/scripts"
install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HM/.codex/scripts" >/dev/null 2>&1 || true
FAILMK_BIN="$TMP/fail-mktemp-bin"; mkdir -p "$FAILMK_BIN"
printf '#!/bin/sh\n# mktemp stand-in: always fails, creates nothing\nexit 1\n' > "$FAILMK_BIN/mktemp"
chmod +x "$FAILMK_BIN/mktemp"
hm_log="$( PATH="$FAILMK_BIN:$PATH"; INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""; _rc=0
  install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HM/.codex/scripts" >/dev/null 2>&1 || _rc=$?
  printf 'RC=%s\nMISSING=%s\n%s\n' "$_rc" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL" )"
if [ "$(log_field "$hm_log" RC)" = 1 ] && [ "$(log_field "$hm_log" MISSING)" = "$_nfiles" ]; then
  case "$hm_log" in
    *"$HM/.codex/scripts/lib/model-subprocess.sh"*"mktemp failed"*) pass "(14a-ro, stand-in) a failing mktemp is a miss even over matching old bytes — all $_nfiles counted, the failed step named" ;;
    *) bad "(14a-ro, stand-in) counted, but the summary does not name the path and the failed step: [$hm_log]" ;;
  esac
else
  bad "(14a-ro, stand-in) a failing mktemp over the old bytes: rc=[$(log_field "$hm_log" RC)] missing=[$(log_field "$hm_log" MISSING)] (want 1/$_nfiles) — a failed install reported success"
fi
_mm="$(lib_mismatch "$LIBCOPY" "$HM/.codex/scripts/lib")"; _deb="$(temp_debris "$HM/.codex/scripts/lib")"
if [ -z "$_mm" ] && [ -z "$_deb" ]; then pass "(14a-ro, stand-in) the installed files kept their bytes and no temp was left"
else bad "(14a-ro, stand-in) installed files changed [$_mm] or temp debris left [$_deb]"; fi
# (14a-sym) The temp name is not predictable. The first version wrote to <lib>/.model-subprocess.sh.tmp.$$
# — a name anyone can pre-plant as a symlink, which `cp` then follows (writing outside the lib dir) and
# `mv` installs as the "runner". A symlink planted at that name must be ignored.
HS="$(mktemp -d "$TMP/host-sym.XXXXXX")"; mkdir -p "$HS/.codex/scripts/lib"
ln -s "$TMP/planted-victim" "$HS/.codex/scripts/lib/.model-subprocess.sh.tmp.$$"
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HS/.codex/scripts" >/dev/null 2>&1 || true
if [ ! -e "$TMP/planted-victim" ] && [ ! -L "$HS/.codex/scripts/lib/model-subprocess.sh" ] \
   && cmp -s "$RUNNER_LIB" "$HS/.codex/scripts/lib/model-subprocess.sh"; then
  pass "(14a-sym) a symlink planted at the old predictable temp name is not followed"
else
  bad "(14a-sym) the planted temp-name symlink was followed: victim written=$([ -e "$TMP/planted-victim" ] && echo yes || echo no), runner is a symlink=$([ -L "$HS/.codex/scripts/lib/model-subprocess.sh" ] && echo yes || echo no)"
fi
# (14a-cp) A copy that fails AFTER the temp file exists (an unreadable source) removes that temp.
LIBU="$TMP/lib-unreadable"; cp -Rp "$LIBCOPY" "$LIBU"; chmod 000 "$LIBU/blind-audit-panel.sh"
if [ -r "$LIBU/blind-audit-panel.sh" ]; then
  echo "SKIP: (14a-cp) this user can read a 0000 file (root?) — an unreadable source cannot be staged; (14a-cp, stand-in) below drives the same branch"
else
  HU="$(mktemp -d "$TMP/host-cp.XXXXXX")"; mkdir -p "$HU/.codex/scripts"
  INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
  hu_rc=0; install_runner_lib "codex scripts (runner lib)" "$LIBU" "$HU/.codex/scripts" > "$TMP/hu.out" 2>&1 || hu_rc=$?
  if [ "$hu_rc" -eq 1 ] && [ "$INSTALL_VERIFY_MISSING" -eq 1 ] && [ -z "$(temp_debris "$HU/.codex/scripts/lib")" ] \
     && cmp -s "$RUNNER_LIB" "$HU/.codex/scripts/lib/model-subprocess.sh"; then
    case "$INSTALL_VERIFY_DETAIL" in
      *"$HU/.codex/scripts/lib/blind-audit-panel.sh"*"cp failed"*) pass "(14a-cp) a failed copy is counted and named, its temp removed, the other files installed" ;;
      *) bad "(14a-cp) counted, but the summary does not name the path and the failed step: [$INSTALL_VERIFY_DETAIL]" ;;
    esac
  else
    bad "(14a-cp) unreadable source: rc=$hu_rc missing=$INSTALL_VERIFY_MISSING (want 1/1), temp debris [$(temp_debris "$HU/.codex/scripts/lib")]"
  fi
fi
chmod 644 "$LIBU/blind-audit-panel.sh"
# (14a-cp, stand-in) The same branch without file permissions, so it runs as root too: a `cp` first on
# PATH that writes a PARTIAL temp (16 bytes) and then fails. Into an empty host lib dir: every file
# counted with "cp failed", and no temp — the partial one included — left behind.
HP="$(mktemp -d "$TMP/host-cpfail.XXXXXX")"; mkdir -p "$HP/.codex/scripts"
FAILCP_BIN="$TMP/fail-cp-bin"; mkdir -p "$FAILCP_BIN"
# shellcheck disable=SC2016  # the stand-in's own $1/$2
printf '#!/bin/sh\n# cp stand-in: writes the first 16 bytes of the source, then fails\nhead -c 16 "$1" > "$2"\nexit 1\n' > "$FAILCP_BIN/cp"
chmod +x "$FAILCP_BIN/cp"
hp_log="$( PATH="$FAILCP_BIN:$PATH"; INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""; _rc=0
  install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HP/.codex/scripts" >/dev/null 2>&1 || _rc=$?
  printf 'RC=%s\nMISSING=%s\n%s\n' "$_rc" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL" )"
if [ "$(log_field "$hp_log" RC)" = 1 ] && [ "$(log_field "$hp_log" MISSING)" = "$_nfiles" ]; then
  case "$hp_log" in
    *"$HP/.codex/scripts/lib/model-subprocess.sh"*"cp failed"*) pass "(14a-cp, stand-in) a copy that fails after writing part of the temp is a miss — all $_nfiles counted, the failed step named" ;;
    *) bad "(14a-cp, stand-in) counted, but the summary does not name the path and the failed step: [$hp_log]" ;;
  esac
else
  bad "(14a-cp, stand-in) a failing cp: rc=[$(log_field "$hp_log" RC)] missing=[$(log_field "$hp_log" MISSING)] (want 1/$_nfiles)"
fi
if [ -d "$HP/.codex/scripts/lib" ] && [ -z "$(ls -A "$HP/.codex/scripts/lib")" ]; then
  pass "(14a-cp, stand-in) the host lib dir is empty: no partial temp left, nothing installed"
else
  bad "(14a-cp, stand-in) the host lib dir holds [$(ls -A "$HP/.codex/scripts/lib" 2>/dev/null | tr '\n' ' ')] — a partial temp was left (or the dir is gone)"
fi
# (14a-chmod, stand-in) install_file_atomic's chmod step (scripts/install.sh:219): a chmod stand-in
# first on PATH refuses ONLY the model-subprocess.sh hidden temp (install_file_atomic's own name,
# .model-subprocess.sh.<mktemp suffix>, in the SAME dir as the destination) — same targeted-match
# technique as the cp stand-ins above and (12e)/(17e)'s protocol stand-ins, so the lib dir's other
# files still install through the real chmod. Run over a lib dir that already holds a GOOD install:
# the exact reason string ("chmod failed") must be named, no temp left (install_file_atomic's own
# `rm -f "$tmp"` on failure), and the destination's OLD bytes must survive untouched — a swallowed
# chmod failure followed by `mv` would silently ship a 0600 runner, or worse, report success with
# nothing changed.
HC="$(mktemp -d "$TMP/host-chmodfail.XXXXXX")"; mkdir -p "$HC/.codex/scripts"
install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HC/.codex/scripts" >/dev/null 2>&1 || true
FAILCHMOD_BIN="$TMP/fail-chmod-bin"; mkdir -p "$FAILCHMOD_BIN"
# shellcheck disable=SC2016  # the stand-in's own $2/$@
printf '#!/bin/sh\n# chmod stand-in: refuses only the model-subprocess.sh hidden temp; real chmod otherwise\ncase "$2" in */.model-subprocess.sh.*) exit 1 ;; esac\nexec "%s" "$@"\n' \
  "$(command -v chmod)" > "$FAILCHMOD_BIN/chmod"
chmod +x "$FAILCHMOD_BIN/chmod"
hc_log="$( PATH="$FAILCHMOD_BIN:$PATH"; INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""; _rc=0
  install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HC/.codex/scripts" >/dev/null 2>&1 || _rc=$?
  printf 'RC=%s\nMISSING=%s\n%s\n' "$_rc" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL" )"
if [ "$(log_field "$hc_log" RC)" = 1 ] && [ "$(log_field "$hc_log" MISSING)" = 1 ]; then
  case "$hc_log" in
    *"$HC/.codex/scripts/lib/model-subprocess.sh"*"chmod failed"*) pass "(14a-chmod, stand-in) a failing chmod names the exact reason (\"chmod failed\") and is counted a miss" ;;
    *) bad "(14a-chmod, stand-in) counted, but the summary does not name the path and the failed step: [$hc_log]" ;;
  esac
else
  bad "(14a-chmod, stand-in) a failing chmod: rc=[$(log_field "$hc_log" RC)] missing=[$(log_field "$hc_log" MISSING)] (want 1/1)"
fi
if cmp -s "$RUNNER_LIB" "$HC/.codex/scripts/lib/model-subprocess.sh"; then
  pass "(14a-chmod, stand-in) the destination kept its old (good) bytes — a failed chmod never reached mv"
else
  bad "(14a-chmod, stand-in) the destination changed despite the chmod failure"
fi
if [ -z "$(temp_debris "$HC/.codex/scripts/lib")" ]; then
  pass "(14a-chmod, stand-in) no temp file was left behind"
else
  bad "(14a-chmod, stand-in) temp debris left: $(temp_debris "$HC/.codex/scripts/lib")"
fi
if cmp -s "$LIBCOPY/portable.sh" "$HC/.codex/scripts/lib/portable.sh" && cmp -s "$LIBCOPY/blind-audit-panel.sh" "$HC/.codex/scripts/lib/blind-audit-panel.sh"; then
  pass "(14a-chmod, stand-in) the one refused file does not stop the rest of the lib dir"
else
  bad "(14a-chmod, stand-in) the refused file stopped the rest of the lib dir from installing"
fi
# (14a-mv, stand-in) install_file_atomic's mv step (scripts/install.sh:220): a mv stand-in refuses
# ONLY the model-subprocess.sh hidden temp as its SOURCE argument (the same hidden name the chmod
# stand-in above matched) — the real mv otherwise. Over the same kind of pre-existing GOOD install:
# the exact reason ("mv failed") must be named, no temp left, and the destination must keep its old
# bytes — "mv failed" never touches the destination at all, so a swallowed failure here is
# indistinguishable from success without checking the bytes explicitly.
HV="$(mktemp -d "$TMP/host-mvfail.XXXXXX")"; mkdir -p "$HV/.codex/scripts"
install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HV/.codex/scripts" >/dev/null 2>&1 || true
FAILMV_BIN="$TMP/fail-mv-bin"; mkdir -p "$FAILMV_BIN"
# shellcheck disable=SC2016  # the stand-in's own $2/$@
printf '#!/bin/sh\n# mv stand-in: refuses only the model-subprocess.sh hidden temp SOURCE; real mv otherwise\ncase "$2" in */.model-subprocess.sh.*) exit 1 ;; esac\nexec "%s" "$@"\n' \
  "$(command -v mv)" > "$FAILMV_BIN/mv"
chmod +x "$FAILMV_BIN/mv"
hv_log="$( PATH="$FAILMV_BIN:$PATH"; INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""; _rc=0
  install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HV/.codex/scripts" >/dev/null 2>&1 || _rc=$?
  printf 'RC=%s\nMISSING=%s\n%s\n' "$_rc" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL" )"
if [ "$(log_field "$hv_log" RC)" = 1 ] && [ "$(log_field "$hv_log" MISSING)" = 1 ]; then
  case "$hv_log" in
    *"$HV/.codex/scripts/lib/model-subprocess.sh"*"mv failed"*) pass "(14a-mv, stand-in) a failing mv names the exact reason (\"mv failed\") and is counted a miss" ;;
    *) bad "(14a-mv, stand-in) counted, but the summary does not name the path and the failed step: [$hv_log]" ;;
  esac
else
  bad "(14a-mv, stand-in) a failing mv: rc=[$(log_field "$hv_log" RC)] missing=[$(log_field "$hv_log" MISSING)] (want 1/1)"
fi
if cmp -s "$RUNNER_LIB" "$HV/.codex/scripts/lib/model-subprocess.sh"; then
  pass "(14a-mv, stand-in) the destination kept its old (good) bytes — a failed mv never replaced it"
else
  bad "(14a-mv, stand-in) the destination changed despite the mv failure"
fi
if [ -z "$(temp_debris "$HV/.codex/scripts/lib")" ]; then
  pass "(14a-mv, stand-in) no temp file was left behind"
else
  bad "(14a-mv, stand-in) temp debris left: $(temp_debris "$HV/.codex/scripts/lib")"
fi
if cmp -s "$LIBCOPY/portable.sh" "$HV/.codex/scripts/lib/portable.sh" && cmp -s "$LIBCOPY/blind-audit-panel.sh" "$HV/.codex/scripts/lib/blind-audit-panel.sh"; then
  pass "(14a-mv, stand-in) the one refused file does not stop the rest of the lib dir"
else
  bad "(14a-mv, stand-in) the refused file stopped the rest of the lib dir from installing"
fi
# (14a-trunc) A copy that "succeeds" with the WRONG bytes (a cp that truncates and exits 0), over a
# lib dir holding a good install. The staged temp is checked against the source BEFORE it replaces
# anything: the destination keeps its old good bytes, every file is counted with the reason, and no
# temp is left. (The first version moved the temp into place and only then compared — the corrupted
# copy had already replaced the good one when the check found it.)
HT="$(mktemp -d "$TMP/host-trunc.XXXXXX")"; mkdir -p "$HT/.codex/scripts"
install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HT/.codex/scripts" >/dev/null 2>&1 || true
TRUNC_BIN="$TMP/trunc-cp-bin"; mkdir -p "$TRUNC_BIN"
# shellcheck disable=SC2016  # the stand-in's own $1/$2
printf '#!/bin/sh\n# cp stand-in: writes the first 16 bytes of the source only, and exits 0\nhead -c 16 "$1" > "$2"\n' > "$TRUNC_BIN/cp"
chmod +x "$TRUNC_BIN/cp"
# In a subshell: the stand-in shadows cp there only (a PATH assignment also clears bash's command hash).
ht_log="$( PATH="$TRUNC_BIN:$PATH"; INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""; _rc=0
  install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HT/.codex/scripts" >/dev/null 2>&1 || _rc=$?
  printf 'RC=%s\nMISSING=%s\n%s\n' "$_rc" "$INSTALL_VERIFY_MISSING" "$INSTALL_VERIFY_DETAIL" )"
_nfiles=0; for _f in "$LIBCOPY"/*; do [ -f "$_f" ] && _nfiles=$((_nfiles + 1)); done
if [ "$(log_field "$ht_log" RC)" = 1 ] && [ "$(log_field "$ht_log" MISSING)" = "$_nfiles" ]; then
  case "$ht_log" in
    *"$HT/.codex/scripts/lib/model-subprocess.sh"*"content check failed"*) pass "(14a-trunc) a copy with the wrong bytes is a miss — all $_nfiles counted, the failed check named" ;;
    *) bad "(14a-trunc) counted, but the summary does not name the path and the failed check: [$ht_log]" ;;
  esac
else
  bad "(14a-trunc) a truncating copy: rc=[$(log_field "$ht_log" RC)] missing=[$(log_field "$ht_log" MISSING)] (want 1/$_nfiles)"
fi
_mm="$(lib_mismatch "$LIBCOPY" "$HT/.codex/scripts/lib")"
if [ -z "$_mm" ]; then
  pass "(14a-trunc) the good installed files kept their bytes — the bad copy never replaced them"
else
  bad "(14a-trunc) a bad copy REPLACED good installed files before the check caught it:$_mm"
fi
_deb="$(temp_debris "$HT/.codex/scripts/lib")"
[ -z "$_deb" ] && pass "(14a-trunc) no temp files left" || bad "(14a-trunc) temp debris left: $_deb"
# …and a runner that did not install is counted and named, never swallowed.
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
mkdir -p "$TMP/no-runner-src"
if install_runner_lib "probe" "$TMP/no-runner-src" "$HH/.cursor/scripts" >/dev/null 2>&1; then
  bad "(14a) install_runner_lib reported success with no runner to install"
elif [ "$INSTALL_VERIFY_MISSING" -eq 1 ]; then
  case "$INSTALL_VERIFY_DETAIL" in
    *"$HH/.cursor/scripts/lib/model-subprocess.sh"*) pass "(14a) a runner that did not install is counted and named (INSTALL INCOMPLETE)" ;;
    *) bad "(14a) the miss was counted but the summary does not name it: [$INSTALL_VERIFY_DETAIL]" ;;
  esac
else
  bad "(14a) install_runner_lib failed without counting it (INSTALL_VERIFY_MISSING=$INSTALL_VERIFY_MISSING)"
fi
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
# (14b) EVERY installer function that copies the driver into a host dir calls the helper — derived from
# the functions install.sh defines (`declare -f`: comments stripped), not from a list, so a sixth host
# added by copying the Kimi block cannot ship a driver without its runner while every check above
# stays green. install_zuvo_home is in scope too (it fills ~/.zuvo/lib/ through the helper, (12)), and
# so is install_claude (the cache copies scripts/*.sh, driver included, and its lib through the helper).
_drv_fns=""; _drv_missing=""
for _fn in $(declare -F | awk '$3 ~ /^install_/ {print $3}'); do
  _body="$(declare -f "$_fn")"
  case "$_body" in *adversarial-review.sh*|*'"$DIST"/scripts/*.sh'*|*'"$ZUVO_DIR"/scripts/*.sh'*) ;; *) continue ;; esac
  _drv_fns="$_drv_fns $_fn"
  case "$_body" in *"install_runner_lib "*) ;; *) _drv_missing="$_drv_missing $_fn" ;; esac
done
_drv_absent=""
for _fn in install_claude install_codex install_cursor install_antigravity install_kimi install_zuvo_home; do
  case " $_drv_fns " in *" $_fn "*) ;; *) _drv_absent="$_drv_absent $_fn" ;; esac
done
if [ -n "$_drv_absent" ]; then
  bad "(14b) the driver-copy scan did not recognise:$_drv_absent — it would prove nothing about them"
elif [ -n "$_drv_missing" ]; then
  bad "(14b) installer(s) copying adversarial-review without the shared runner beside it:$_drv_missing"
else
  pass "(14b) every installer that copies the driver also installs the runner through install_runner_lib (scanned:${_drv_fns})"
fi
# (14c) …into the SAME dir as that host's driver, from the same source as the driver, and its failure
# decides the host's "Scripts installed" verdict (`|| _vc_rc=1`).
for _pair in \
  'install_codex|"$ZUVO_DIR/scripts/lib" "$HOME/.codex/scripts"' \
  'install_cursor|"$ZUVO_DIR/scripts/lib" "$HOME/.cursor/scripts"' \
  'install_antigravity|"$DIST/scripts/lib" "$HOME/.gemini/antigravity/scripts"' \
  'install_kimi|"$DIST/scripts/lib" "$KIMI_HOME/scripts"'; do
  _fn="${_pair%%|*}"; _args="${_pair#*|}"
  if declare -f "$_fn" 2>/dev/null | awk -v a="$_args" 'index($0, "install_runner_lib ") && index($0, a) && index($0, "|| _vc_rc=1") {f = 1} END {exit !f}'; then
    pass "(14c) $_fn installs the runner beside its driver: $_args"
  else
    bad "(14c) $_fn has no \`install_runner_lib … $_args || _vc_rc=1\`"
  fi
done
# (14d) Antigravity and Kimi install from their build's dist/ tree, so the BUILD must carry the runner
# — the whole scripts/lib/ dir, the same contract as the helper — next to the driver it ships (the
# antigravity dist was built in (6); kimi's is pinned in tests/hooks/test-kimi-build.sh, which builds it).
# …and that build must still PASS its own validation: it scans the whole dist for residual tokens
# ({plugin_root}, ToolSearch, CLAUDE_PLUGIN_ROOT), shipped libraries included, and a failed build
# still leaves the tree the file checks above look at.
_ag="${ZUVO_DIST_ROOT:-$ROOT/dist}/antigravity/scripts"
_mm="$(lib_mismatch "$ROOT/scripts/lib" "$_ag/lib")"
if [ -f "$_ag/adversarial-review.sh" ] && cmp -s "$RUNNER_LIB" "$_ag/lib/model-subprocess.sh" && [ -z "$_mm" ]; then
  pass "(14d) the antigravity build ships every regular file of scripts/lib/ beside scripts/adversarial-review.sh"
else
  bad "(14d) the antigravity build's scripts/lib/ beside its driver is not a copy of scripts/lib/:$_mm"
fi
if [ "$antig_rc" -eq 0 ]; then
  pass "(14d) the antigravity build that ships scripts/lib/ exits 0 (its own validation passes)"
else
  bad "(14d) the antigravity build exited $antig_rc — $(printf '%s' "$antig_log" | awk '/ERROR/ {getline n; print $0 " " n}' | head -3 | tr '\n' '|')"
fi
# (14e) The runner lands BEFORE the driver it serves, in every installer that ships both. Driver first
# means a review starting mid-install runs the NEW driver with no sibling runner yet — it falls back to
# ~/.zuvo, possibly an older library. Read from `declare -f` (comments stripped): the first line that
# installs the runner must precede the first line that copies the driver.
#   <function>|<the runner install>|<the driver copy>
for _trip in \
  'install_codex|install_runner_lib |cp "$ZUVO_DIR"/scripts/adversarial-review.sh' \
  'install_cursor|install_runner_lib |cp "$ZUVO_DIR"/scripts/adversarial-review.sh' \
  'install_antigravity|install_runner_lib |cp "$DIST"/scripts/*.sh' \
  'install_kimi|install_runner_lib |cp "$DIST"/scripts/*.sh' \
  'install_zuvo_home|install_runner_lib |"$ZUVO_DIR"/scripts/adversarial-review.sh' \
  'install_claude|install_runner_lib |cp_warn "scripts/*.sh"'; do
  _fn="${_trip%%|*}"; _rest="${_trip#*|}"; _lib_pat="${_rest%%|*}"; _drv_pat="${_rest#*|}"
  _order="$(declare -f "$_fn" 2>/dev/null | awk -v l="$_lib_pat" -v d="$_drv_pat" '
    !li && index($0, l) { li = NR }
    !di && index($0, d) { di = NR }
    END { print (li ? li : 0) " " (di ? di : 0) }')"
  _li="${_order%% *}"; _di="${_order#* }"
  if [ "$_li" -eq 0 ] || [ "$_di" -eq 0 ]; then
    bad "(14e) $_fn: could not find the runner install [$_lib_pat] ($_li) or the driver copy [$_drv_pat] ($_di)"
  elif [ "$_li" -lt "$_di" ]; then
    pass "(14e) $_fn installs the runner (line $_li) before the driver (line $_di)"
  else
    bad "(14e) $_fn copies the driver (line $_di) BEFORE its runner (line $_li) — mid-install reviews run it without its sibling library"
  fi
done
# (14f) The stale library planted in the antigravity build's scripts/lib/ before (6) built it is gone:
# install_antigravity ships that dir file by file, so a leftover would reach every host as a library
# scripts/lib/ no longer has. (The kimi build: tests/hooks/test-kimi-build.sh (11b).)
if [ "$antig_rc" -eq 0 ] && [ ! -e "$_ag_stale" ]; then
  pass "(14f) the antigravity build's scripts/lib/ is regenerated: a file removed upstream does not linger"
else
  bad "(14f) after the antigravity build (exit $antig_rc) the planted stale library [${_ag_stale##*/}] $([ -e "$_ag_stale" ] && echo 'is still in' || echo 'is gone from') its scripts/lib/"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (15) install_codex, install_cursor, install_antigravity and install_kimi EXECUTED, not only read.
# (14b)/(14c)/(14e) scan their text; Plan A changed all four (the runner library now installs before
# the driver; the antigravity and kimi builds ship scripts/lib/), so each is run for real: build +
# install into a temp HOME, then the installed <host scripts dir>/adversarial-review.sh reviews through
# a codex SPY — the (12)/(13) proof. Read before this was written: all four write only under $HOME —
#   codex/cursor: skills, agents, shared, rules, scripts, ~/.codex/AGENTS.md through
#     install-agents-md-blocks.sh, ~/.codex/config.toml + hooks.json through python3, ~/.codex/plugins/…;
#     cursor's duplicate cleanup looks at $HOME/.claude/… only;
#   antigravity: ~/.gemini/config/skills (its customization root), ~/.gemini/antigravity/{shared,rules,
#     scripts,hooks}, ~/.gemini/settings.json through python3 (temp file in the same dir);
#   kimi: ${KIMI_CODE_HOME:-$HOME/.kimi-code}/{skills,agents,shared,rules,scripts,hooks} and its
#     config.toml through python3 (temp file in the same dir) — KIMI_CODE_HOME is the ONE input that
#     can point it outside $HOME, so host_install unsets it: an exported KIMI_CODE_HOME in the caller's
#     shell would otherwise send this run into the caller's real Kimi home.
# Each runs its builder with the build root taken from ZUVO_DIST_ROOT (set to a sandbox here — the
# repo's dist/ is never written; the builders write only under it), uses mktemp for a build log (TMPDIR
# is the sandbox's) and reaches no network. Nothing needs a stub.
# host_install <fn> <home> <dist-root> — <fn> in a fresh shell that SOURCED install.sh with HOME=<home>,
# under the options the main run calls it with (set -euo pipefail), so an unguarded failing command
# aborts here as it would abort a real install. Prints the log, then — from an EXIT trap, so an abort is
# reported too — the function's OWN status and the verify counter and detail (the zuvo_install pattern).
# HI_REPORT_DEF — that report, _hi_report <status>: HOST_INSTALL_RC, INSTALL_VERIFY_MISSING,
# INSTALL_VERSION, then ---DETAIL--- and the free-text detail. ONE definition, handed to the child (and
# to host_install_chain's below), so the self-test after it runs the very function the installs use.
# P3C-24: VERSION goes out on ONE line, CR/LF stripped. It is package.json's today, but a value holding
# a newline would print a KEY=value line of its own, and log_field (the last match wins) would read it:
# `1.0<LF>HOST_INSTALL_RC=0` turned a failed install's reported status into 0.
# shellcheck disable=SC2016  # expanded in the child shell
HI_REPORT_DEF='_hi_report() { printf "HOST_INSTALL_RC=%s\nINSTALL_VERIFY_MISSING=%s\nINSTALL_VERSION=%s\n---DETAIL---\n%s\n" "$1" "${INSTALL_VERIFY_MISSING:-}" "$(printf "%s" "${VERSION:-}" | tr -d "\r\n")" "${INSTALL_VERIFY_DETAIL:-}"; }'
host_install() {
  mkdir -p "$3" "$2/tmp"
  # shellcheck disable=SC2016  # expanded by the child shell
  HOME="$2" ZUVO_DIST_ROOT="$3" TMPDIR="$2/tmp" "$BASH" -c 'unset KIMI_CODE_HOME
    . "$1" >/dev/null 2>&1 || { echo "SOURCE FAILED"; exit 97; }
    eval "$3"
    trap "_hi_report \$?" EXIT
    set -euo pipefail
    "$2"' _ "$INSTALL" "$1" "$HI_REPORT_DEF" 2>&1
}
# shellcheck disable=SC2034  # VERSION is read by the eval'd _hi_report
_hr_log="$(eval "$HI_REPORT_DEF"; INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
  VERSION="$(printf '1.2.3\nHOST_INSTALL_RC=0')"; _hi_report 5)"
if [ "$(log_field "$_hr_log" HOST_INSTALL_RC)" = 5 ] && [ "$(log_field "$_hr_log" INSTALL_VERSION)" = "1.2.3HOST_INSTALL_RC=0" ]; then
  pass "_hi_report: a VERSION holding a newline stays on its own line — it cannot forge a HOST_INSTALL_RC the log reader would take (P3C-24)"
else
  bad "_hi_report: with VERSION=[1.2.3<LF>HOST_INSTALL_RC=0] and status 5, log_field read HOST_INSTALL_RC=[$(log_field "$_hr_log" HOST_INSTALL_RC)] INSTALL_VERSION=[$(log_field "$_hr_log" INSTALL_VERSION)] — want 5 and the joined one-line value (P3C-24)"
fi
# One row per host: <host>|<the dirs its installer takes as "installed here", HOME-relative>|<its
# scripts dir, HOME-relative>|<what its driver is copied from: src = scripts/, dist = its build>.
# The build dir is always <dist-root>/<host>.
for _spec in \
  'codex|.codex/skills .codex/agents .codex/.tmp/plugins|.codex/scripts|src' \
  'cursor|.cursor/skills .cursor/agents|.cursor/scripts|src' \
  'antigravity|.gemini/antigravity|.gemini/antigravity/scripts|dist' \
  'kimi|.kimi-code/skills .kimi-code/agents|.kimi-code/scripts|dist'; do
  IFS='|' read -r _host _hmarks _hrel _hdrv <<< "$_spec"
  _hh="$(mktemp -d "$TMP/$_host-install-home.XXXXXX")"; _hd="$TMP/$_host-install-dist"
  # A home the installer recognises as having the host (its first check), with what a real one carries.
  for _m in $_hmarks; do mkdir -p "$_hh/$_m"; done
  # P2-101: a stale OLDER plugin version left in the codex plugin dir, carrying a NEWER mtime (a
  # repaired or touched old install) — exactly what an mtime-based "newest" pick would have taken
  # for the fresh one. install_codex wipes the whole zuvo/ plugin dir before writing $VERSION, so
  # after the install below it must be gone; (6b) checks that, and the one dir it names.
  if [ "$_host" = codex ]; then
    _hstale="$_hh/.codex/plugins/cache/zuvo-marketplace/zuvo/0.0.0-stale"
    mkdir -p "$_hstale/hooks/lib" && printf '# stale\n' > "$_hstale/hooks/lib/pipeline-gate-lib.sh" \
      && touch -t 203001010000 "$_hstale" "$_hstale/hooks/lib" \
      || bad "(6b, real) codex: could not seed the stale plugin version dir $_hstale"
  fi
  _hl="$(host_install "install_$_host" "$_hh" "$_hd")"
  _hrc="$(log_field "$_hl" HOST_INSTALL_RC)"; _hmiss="$(log_field "$_hl" INSTALL_VERIFY_MISSING)"
  if [ "$_hrc" = 0 ] && [ "$_hmiss" = 0 ]; then
    pass "(15) install_$_host, executed into a temp HOME, returns 0 with nothing missing"
  else
    bad "(15) install_$_host status=[$_hrc] INSTALL_VERIFY_MISSING=[$_hmiss] — $(printf '%s' "$_hl" | awk '/✗|WARN|FAILED|failed/' | head -3 | tr '\n' '|')"
  fi
  # The sandbox is real: the build this install ran went to the per-case root, not the repo's dist/.
  if [ -d "$_hd/$_host/skills" ]; then pass "(15) install_$_host built into the sandboxed ZUVO_DIST_ROOT ($_hd/$_host)"
  else bad "(15) install_$_host left no build under the sandboxed ZUVO_DIST_ROOT [$_hd] — where did it build?"; fi
  _hs="$_hh/$_hrel"
  if [ -f "$_hs/lib/model-subprocess.sh" ] && cmp -s "$RUNNER_LIB" "$_hs/lib/model-subprocess.sh"; then
    pass "(15) ~/$_hrel/lib/model-subprocess.sh is installed, byte-identical to scripts/lib/model-subprocess.sh"
  else
    bad "(15) ~/$_hrel/lib/model-subprocess.sh is $([ -e "$_hs/lib/model-subprocess.sh" ] && echo 'different from' || echo 'not installed from') scripts/lib/model-subprocess.sh"
  fi
  _mm="$(lib_mismatch "$ROOT/scripts/lib" "$_hs/lib")"
  [ -z "$_mm" ] && pass "(15) ~/$_hrel/lib/ holds every regular file of scripts/lib/" \
    || bad "(15) ~/$_hrel/lib/ is not a copy of scripts/lib/:$_mm"
  # The driver the installer copied: codex/cursor take scripts/adversarial-review.sh, antigravity/kimi
  # the one their build shipped (the build under the sandboxed root, checked above).
  case "$_hdrv" in
    src) _hdsrc="$ROOT/scripts/adversarial-review.sh"; _hdname="scripts/adversarial-review.sh" ;;
    *)   _hdsrc="$_hd/$_host/scripts/adversarial-review.sh"; _hdname="its build's scripts/adversarial-review.sh" ;;
  esac
  if [ -f "$_hdsrc" ] && cmp -s "$_hdsrc" "$_hs/adversarial-review.sh"; then
    pass "(15) ~/$_hrel/adversarial-review.sh is $_hdname"
  else bad "(15) ~/$_hrel/adversarial-review.sh is missing or differs from $_hdname [$_hdsrc]"; fi
  # Non-vacuous: this HOME holds no ~/.zuvo runner, so the sibling lib/ is the only one the driver can load.
  if [ ! -e "$_hh/.zuvo/model-subprocess.sh" ] && [ ! -e "$_hh/.zuvo/lib/model-subprocess.sh" ]; then
    pass "(15) premise: no ~/.zuvo runner in the $_host HOME — only the sibling scripts/lib/ can serve the driver"
  else bad "(15) premise: the $_host HOME has a ~/.zuvo runner — the review below could load that instead"; fi
  rc=0; spy_review "$_host-installed" "$_hs/adversarial-review.sh" "$_hh" || rc=$?
  expect_runner_loaded "(15) the driver install_$_host installed (~/$_hrel/adversarial-review.sh)" "$_host-installed" "$rc"

  # (6b, real) hooks/lib/ at its EXACT destination, byte-identical to what THIS host's OWN build
  # shipped at $DIST/hooks/lib (install.sh's cp -R source — the build applies per-host path
  # rewriting, so the repo's hooks/lib/ itself is the wrong comparison target and would always
  # "differ"; the sandboxed build dir this host already built into above, $_hd/$_host/hooks/lib, is
  # the right one). (6b)'s own check above only counts `cp -R "$DIST/hooks/lib"` call sites in
  # install.sh's TEXT, so a regression that kept 3+ sites but pointed one at the wrong directory
  # would still pass it. This host is ALREADY installed for real above (install_$_host into $_hh);
  # no extra build or install is run here, only the hooks/lib/ side effect of that same call is
  # checked. cursor has no recursive hooks/lib copy of its own — its hooks/lib files are merged flat
  # into scripts/lib/, covered by (16)'s collision guard — so it has no case here.
  _hbuiltlib="$_hd/$_host/hooks/lib"
  if [ "$_host" = cursor ]; then
    : # no recursive hooks/lib copy for cursor — see comment above
  elif [ ! -d "$_hbuiltlib" ]; then
    bad "(6b, real) $_host: premise failed — $_hbuiltlib (this host's own build output) does not exist"
  else
    case "$_host" in
      codex)
        # Plugin CACHE (only written when ~/.codex/.tmp/plugins exists — added to this host's marks above).
        _hlibdir="$_hh/.codex/.tmp/plugins/plugins/zuvo/hooks/lib"
        if [ -d "$_hlibdir" ] && [ -z "$(lib_mismatch "$_hbuiltlib" "$_hlibdir")" ]; then
          pass "(6b, real) codex plugin cache: $_hlibdir is byte-identical to its own build's hooks/lib/"
        else
          bad "(6b, real) codex plugin cache: $_hlibdir is missing or differs from $_hbuiltlib:$(lib_mismatch "$_hbuiltlib" "$_hlibdir")"
        fi
        # Plugin DIR (~/.codex/plugins/cache/zuvo-marketplace/zuvo/<VERSION>/hooks/lib).
        # P2-101/102/104 (replacing ADV-C15/C17's newest-by-mtime pick): the dir is NAMED, not guessed —
        # install_codex writes exactly "$VERSION" (reported by this install's own _hi_report) after
        # wiping the whole zuvo/ plugin dir, so it is also the ONLY entry there. mtime was a proxy for
        # "the fresh one" that a touched older version (seeded above) defeats; its `stat -f %m` probe
        # meant --file-system on GNU (the Linux farm), not mtime; and a failed stat fell back to 0 and
        # silently kept the first glob hit. No stat, no guess: a leftover version dir, or a missing
        # VERSION, is its own named FAIL.
        # P3C-26: the reported VERSION is cross-checked against package.json, read HERE independently of
        # install.sh's own derivation — naming the dir by the installer's self-report alone could not
        # catch a bug in that very report. P3C-32: the listing is sorted (C collation), so a failure
        # names leftover dirs in the same order on every host.
        _hver="$(log_field "$_hl" INSTALL_VERSION)"
        _hpkgver="$(awk -F'"' '$2 == "version" { print $4; exit }' "$(dirname "$INSTALL")/../package.json" 2>/dev/null)"
        _hvroot="$_hh/.codex/plugins/cache/zuvo-marketplace/zuvo"
        _hvdirs="$(ls -A "$_hvroot" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
        _hlibdir="$_hvroot/$_hver/hooks/lib"
        if [ -z "$_hver" ]; then
          bad "(6b, real) codex plugin dir: install_codex reported no VERSION — the dir it wrote cannot be named"
        elif [ "$_hver" != "$_hpkgver" ]; then
          bad "(6b, real) codex plugin dir: install_codex reported VERSION [$_hver], but package.json says [$_hpkgver] — the installer's own version report is wrong, so the dir it names proves nothing (P3C-26)"
        elif [ "$_hvdirs" != "$_hver " ]; then
          bad "(6b, real) codex plugin dir: $_hvroot holds [$_hvdirs], want exactly [$_hver] — an older version dir survived the install"
        elif [ -d "$_hlibdir" ] && [ -z "$(lib_mismatch "$_hbuiltlib" "$_hlibdir")" ]; then
          pass "(6b, real) codex plugin dir: $_hlibdir (the ONLY version dir, $_hver) is byte-identical to its own build's hooks/lib/"
        else
          bad "(6b, real) codex plugin dir: [$_hlibdir] is missing or differs from $_hbuiltlib:$(lib_mismatch "$_hbuiltlib" "$_hlibdir")"
        fi
        ;;
      antigravity)
        _hlibdir="$_hh/.gemini/antigravity/hooks/lib"
        if [ -d "$_hlibdir" ] && [ -z "$(lib_mismatch "$_hbuiltlib" "$_hlibdir")" ]; then
          pass "(6b, real) antigravity: $_hlibdir is byte-identical to its own build's hooks/lib/"
        else
          bad "(6b, real) antigravity: $_hlibdir is missing or differs from $_hbuiltlib:$(lib_mismatch "$_hbuiltlib" "$_hlibdir")"
        fi
        ;;
      kimi)
        _hlibdir="$_hh/.kimi-code/hooks/lib"
        if [ -d "$_hlibdir" ] && [ -z "$(lib_mismatch "$_hbuiltlib" "$_hlibdir")" ]; then
          pass "(6b, real) kimi: $_hlibdir is byte-identical to its own build's hooks/lib/"
        else
          bad "(6b, real) kimi: $_hlibdir is missing or differs from $_hbuiltlib:$(lib_mismatch "$_hbuiltlib" "$_hlibdir")"
        fi
        ;;
    esac
  fi
done

# (16) install_codex and install_cursor put hooks/lib/*.sh|*.py and scripts/lib/* into ONE
# <host>/scripts/lib/, so a shared file name silently replaces a runner library with a hook helper (or
# the reverse), and every check above would still compare the name it expects. A cheap guard fails
# LOUDLY instead — each colliding name an install miss (INSTALL INCOMPLETE), named with the destination.
if ! declare -F lib_name_collisions >/dev/null || ! declare -F guard_lib_collisions >/dev/null; then
  bad "(16) install.sh defines no lib_name_collisions / guard_lib_collisions — nothing checks the shared <host>/scripts/lib/"
else
  _col="$(lib_name_collisions "$ROOT/hooks/lib" "$ROOT/scripts/lib")"
  if [ -z "$_col" ]; then pass "(16) hooks/lib/ and scripts/lib/ share no file name today"
  else bad "(16) hooks/lib/ and scripts/lib/ share [$_col] — one replaces the other in ~/.codex|~/.cursor/scripts/lib/"; fi
  # Planted: one shared name, one name each side only. Exactly the shared one is counted and named.
  CL="$TMP/collide"; mkdir -p "$CL/hooks-lib" "$CL/scripts-lib"
  printf '# hook helper\n' > "$CL/hooks-lib/portable.sh"; printf '# hook-only helper\n' > "$CL/hooks-lib/only-hook.py"
  printf '# runner library\n' > "$CL/scripts-lib/portable.sh"; printf '# runner\n' > "$CL/scripts-lib/model-subprocess.sh"
  expect_eq_16() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 — expected [$2], got [$3]"; fi; }
  expect_eq_16 "(16) planted: lib_name_collisions names exactly the shared file" "portable.sh" \
    "$(lib_name_collisions "$CL/hooks-lib" "$CL/scripts-lib")"
  INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
  gc_rc=0; guard_lib_collisions "codex scripts (lib)" "$CL/hooks-lib" "$CL/scripts-lib" "$CL/dst" > "$TMP/gc.out" 2>&1 || gc_rc=$?
  if [ "$gc_rc" -eq 1 ] && [ "$INSTALL_VERIFY_MISSING" -eq 1 ]; then
    case "$INSTALL_VERIFY_DETAIL" in
      *"$CL/dst/portable.sh"*"share a name"*) pass "(16) planted collision: status 1, one miss counted, the destination named in the summary" ;;
      *) bad "(16) planted collision counted, but the summary does not name it: [$INSTALL_VERIFY_DETAIL]" ;;
    esac
  else
    bad "(16) planted collision: rc=$gc_rc missing=$INSTALL_VERIFY_MISSING (want 1/1) — $(tr '\n' ' ' < "$TMP/gc.out")"
  fi
  expect_log_has "(16) …and it FAILS loudly on the install log" "$(cat "$TMP/gc.out")" "both ship [portable.sh]"
  INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
  gc_rc=0; guard_lib_collisions "codex scripts (lib)" "$ROOT/hooks/lib" "$ROOT/scripts/lib" "$CL/dst" > "$TMP/gc.out" 2>&1 || gc_rc=$?
  expect_eq_16 "(16) anchor: the repo's own dirs pass the guard (status 0, nothing counted, nothing said)" "0/0/" \
    "$gc_rc/$INSTALL_VERIFY_MISSING/$(cat "$TMP/gc.out")"
  INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
fi
# …wired where the two copies meet: before the hooks/lib copy, its failure deciding "Scripts installed".
for _fn in install_codex install_cursor; do
  if declare -f "$_fn" 2>/dev/null | awk '
      !g && index($0, "guard_lib_collisions ") && index($0, "\"$ZUVO_DIR/hooks/lib\" \"$ZUVO_DIR/scripts/lib\"") && index($0, "|| _vc_rc=1") { g = NR }
      !c && index($0, "cp \"$ZUVO_DIR\"/hooks/lib/*.sh") { c = NR }
      END { exit !(g && c && g < c) }'; then
    pass "(16) $_fn runs guard_lib_collisions (|| _vc_rc=1) before it copies hooks/lib/ into scripts/lib/"
  else
    bad "(16) $_fn copies hooks/lib/ into its scripts/lib/ without guard_lib_collisions before it"
  fi
done

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (17) Task 7 (docs/specs/2026-09-25-blind-audit-panel-plan.md): the blind-audit panel's library AND
# its protocol must both reach ~/.zuvo, so the INSTALLED driver (~/.zuvo/adversarial-review, no repo
# beside it) can run --mode blind-audit on its own, with no --protocol flag.
#
# scripts/lib/blind-audit-panel.sh already ships to ~/.zuvo/lib/ through install_runner_lib — (12)
# above proves every regular file of scripts/lib/ lands there byte-identical, and that is the driver's
# FIRST lookup candidate (<dir>/lib/ -> <dir>/ -> ~/.zuvo/). What Task 7 actually adds is the PROTOCOL:
# bap_find_protocol (scripts/lib/blind-audit-panel.sh) only reaches shared/includes/blind-coverage-
# audit.md at <driver_dir>/../shared/includes/ when <driver_dir>/../skills exists (a real repo or
# plugin-cache tree) — ~/.zuvo, installed flat, has no ../skills beside it, so it falls through to its
# last candidate, $HOME/.zuvo/blind-coverage-audit.md, which nothing installed before this task.
# Reuses $ZH (the golden temp HOME (12) already installed into) and $SPY_SHIM (the real timeout/jq
# resolved before PATH is narrowed, from the same section).
# ═════════════════════════════════════════════════════════════════════════════════════════════════
if [ -f "$ZH/.zuvo/lib/blind-audit-panel.sh" ] && cmp -s "$ROOT/scripts/lib/blind-audit-panel.sh" "$ZH/.zuvo/lib/blind-audit-panel.sh"; then
  pass "(17) ~/.zuvo/lib/blind-audit-panel.sh installed, byte-identical to scripts/lib/blind-audit-panel.sh — the driver's first candidate"
else
  bad "(17) ~/.zuvo/lib/blind-audit-panel.sh is $([ -e "$ZH/.zuvo/lib/blind-audit-panel.sh" ] && echo 'different from' || echo 'not installed from') scripts/lib/blind-audit-panel.sh"
fi
# Item 2 (fix round): the FLAT ~/.zuvo/blind-audit-panel.sh too — the panel library's OWN fallback when
# ~/.zuvo/lib/ fails, mirroring model-subprocess.sh's <dir>/lib/ -> <dir>/ -> ~/.zuvo/ order. (17d) below
# proves it actually serves the driver when ~/.zuvo/lib/ is blocked.
if [ -f "$ZH/.zuvo/blind-audit-panel.sh" ] && cmp -s "$ROOT/scripts/lib/blind-audit-panel.sh" "$ZH/.zuvo/blind-audit-panel.sh"; then
  pass "(17) ~/.zuvo/blind-audit-panel.sh (flat) installed too, byte-identical to scripts/lib/blind-audit-panel.sh — the library's own fallback"
else
  bad "(17) ~/.zuvo/blind-audit-panel.sh (flat) is $([ -e "$ZH/.zuvo/blind-audit-panel.sh" ] && echo 'different from' || echo 'not installed from') scripts/lib/blind-audit-panel.sh"
fi
if [ -f "$ZH/.zuvo/blind-coverage-audit.md" ] && cmp -s "$ROOT/shared/includes/blind-coverage-audit.md" "$ZH/.zuvo/blind-coverage-audit.md"; then
  pass "(17) ~/.zuvo/blind-coverage-audit.md installed, byte-identical to shared/includes/blind-coverage-audit.md — bap_find_protocol's flat fallback"
else
  bad "(17) ~/.zuvo/blind-coverage-audit.md is $([ -e "$ZH/.zuvo/blind-coverage-audit.md" ] && echo 'different from' || echo 'not installed from') shared/includes/blind-coverage-audit.md"
fi
if [ -f "$ZH/.zuvo/model-subprocess.sh" ] && cmp -s "$RUNNER_LIB" "$ZH/.zuvo/model-subprocess.sh"; then
  pass "(17) ~/.zuvo/model-subprocess.sh present too (Plan A's shared codex/claude runner, unaffected by this task)"
else
  bad "(17) ~/.zuvo/model-subprocess.sh missing or stale"
fi

# The LONE installed driver: HOME=$ZH, no --protocol, no repo beside it. PATH is exactly the timeout/jq
# shim dir plus the blind-audit mocks plus the bare system dirs — nothing that could let a real model
# CLI run. ZUVO_ADVERSARIAL_TEST_HARNESS=1 with ZUVO_REVIEW_TEST_PROVIDERS pins the panel to the two
# named mocks; since 2 candidates <= the default panel size, both run (bap: "<= panel available -> all
# run"), so a clean strict merge is exactly 2 valid of 2.
BA_MOCKS="$ROOT/tests/adversarial/mocks"
if [ ! -d "$BA_MOCKS" ]; then
  bad "(17) premise: mock lane dir missing: $BA_MOCKS"
elif [ ! -x "$BA_MOCKS/mock-strict-clean" ] || [ ! -x "$BA_MOCKS/mock-strict-fix" ]; then
  bad "(17) premise: mock-strict-clean / mock-strict-fix not found executable in $BA_MOCKS"
else
  pass "(17) premise: mock-strict-clean and mock-strict-fix are present and executable"
fi
BAP="$TMP/blind-audit-prod.sh"; BAT="$TMP/blind-audit-prod.test.sh"
printf '#!/bin/sh\nsum_or_zero() {\n  [ -z "$1" ] && { echo 0; return 0; }\n  t=0; for n in $1; do t=$((t + n)); done\n  echo "$t"\n}\n' > "$BAP"
printf '#!/bin/sh\n. ./blind-audit-prod.sh\n[ "$(sum_or_zero "1 2 3")" = 6 ] || exit 1\n' > "$BAT"
BA_WORK="$TMP/blind-audit-work"; mkdir -p "$BA_WORK"
ba_rc=0
# The mocks keep the prompt they were handed (MOCK_STDIN_DIR) — (17f) below compares against it.
BA17_STDIN="$TMP/ba17-stdin"; mkdir -p "$BA17_STDIN"
( cd "$BA_WORK" && env -i HOME="$ZH" ZUVO_HOME="$ZH/.zuvo" TMPDIR="$SPY_TMPD" ZUVO_NO_CAFFEINATE=1 \
    ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
    PATH="$SPY_SHIM:$BA_MOCKS:/usr/bin:/bin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix" MOCK_STDIN_DIR="$BA17_STDIN" \
    "$BASH" "$ZH/.zuvo/adversarial-review" --mode blind-audit --production "$BAP" --test "$BAT" ) \
  > "$TMP/blind-audit.out" 2> "$TMP/blind-audit.err" || ba_rc=$?
if [ "$ba_rc" -eq 0 ]; then
  pass "(17) the installed ~/.zuvo/adversarial-review --mode blind-audit (no --protocol) exits 0"
else
  bad "(17) the installed ~/.zuvo/adversarial-review --mode blind-audit exited $ba_rc — $(tail -3 "$TMP/blind-audit.err" | tr '\n' '|')"
fi
if grep -qF 'Audit panel: strict valid=2/2' "$TMP/blind-audit.out" 2>/dev/null; then
  pass "(17) …stdout shows 'Audit panel: strict valid=2/2' — it found BOTH the library and the protocol from ~/.zuvo"
else
  bad "(17) …stdout does not show 'Audit panel: strict valid=2/2' — stdout: $(tr '\n' '|' < "$TMP/blind-audit.out" 2>/dev/null) stderr: $(tail -5 "$TMP/blind-audit.err" | tr '\n' '|')"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# P1: _zuvo_home_drop_stale must not treat "cannot compare" (cmp exit 2, e.g. a missing/unreadable
# <source> in a broken checkout) as "content differs" (cmp exit 1, the only condition that means
# stale). A destination that cannot be PROVEN stale must survive, not be deleted on a guess — called
# directly (it is sourced into this shell already, like install_hook_tree/lib_name_collisions above).
# ═════════════════════════════════════════════════════════════════════════════════════════════════
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
P1D="$TMP/p1-dest.txt"; printf 'destination content, must survive an undetermined-staleness call\n' > "$P1D"
# NOT `p1_out="$(_zuvo_home_drop_stale ...)"` — a command substitution forks a subshell, and
# INSTALL_VERIFY_DETAIL is a plain (non-exported) shell variable: a subshell's assignment to it never
# reaches this shell. Redirecting a plain command's output to a file keeps the call in THIS shell, so
# the global actually updates.
P1_OUT="$TMP/p1-out.txt"
p1_rc=0; _zuvo_home_drop_stale "test label" "$P1D" "$TMP/p1-source-does-not-exist.txt" > "$P1_OUT" 2>&1 || p1_rc=$?
p1_out="$(cat "$P1_OUT")"
if [ "$p1_rc" -eq 1 ]; then
  pass "(P1) _zuvo_home_drop_stale with a missing source returns 1 (staleness undetermined, not proven)"
else
  bad "(P1) _zuvo_home_drop_stale with a missing source returned $p1_rc (want 1)"
fi
if [ -f "$P1D" ] && grep -qF 'destination content, must survive an undetermined-staleness call' "$P1D"; then
  pass "(P1) the destination survives when staleness could not be determined"
else
  bad "(P1) the destination was removed although staleness could not be determined — cmp exit 2 treated as stale"
fi
case "$p1_out" in
  *"could not"*) pass "(P1) …and it says loudly that it could not compare" ;;
  *) bad "(P1) …no loud message about being unable to compare — [$p1_out]" ;;
esac
case "$INSTALL_VERIFY_DETAIL" in
  *"$P1D"*) pass "(P1) …and the summary detail names the destination" ;;
  *) bad "(P1) …the summary detail does not name $P1D — [$INSTALL_VERIFY_DETAIL]" ;;
esac
INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# ADV-A53: a DANGLING symlink (the link exists, its target does not) must be removed UNCONDITIONALLY,
# never routed through the "cannot compare, keep + fail loud" branch above. `cmp` on a dangling link
# always fails to read the target — the same cmp-exit-not-1 shape as P1's genuinely-undetermined
# case — but there is nothing ambiguous about a broken link: it can never be "already correct".
# ═════════════════════════════════════════════════════════════════════════════════════════════════
P1_DANGLING="$TMP/p1-dangling-link"
ln -s "$TMP/p1-dangling-target-does-not-exist" "$P1_DANGLING"
P1D_OUT="$TMP/p1-dangling-out.txt"
p1d_rc=0; _zuvo_home_drop_stale "test label" "$P1_DANGLING" "$P1D" > "$P1D_OUT" 2>&1 || p1d_rc=$?
p1d_out="$(cat "$P1D_OUT")"
if [ "$p1d_rc" -eq 0 ]; then
  pass "(P1-dangling) _zuvo_home_drop_stale on a dangling symlink returns 0 (removed, not 'undetermined')"
else
  bad "(P1-dangling) _zuvo_home_drop_stale on a dangling symlink returned $p1d_rc (want 0) — [$p1d_out]"
fi
if [ ! -e "$P1_DANGLING" ] && [ ! -L "$P1_DANGLING" ]; then
  pass "(P1-dangling) the dangling symlink itself is gone"
else
  bad "(P1-dangling) the dangling symlink survived — it should be removed unconditionally"
fi
case "$p1d_out" in
  *"could not"*) bad "(P1-dangling) wrongly reported 'could not compare' for an unconditionally-removable dangling link — [$p1d_out]" ;;
  *) pass "(P1-dangling) …and it does not claim staleness was undetermined" ;;
esac

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (17-premise) Q7: a plain failure path for the protocol copy — its destination is a DIRECTORY, like
# (12b)'s block for model-subprocess.sh, so install_file_atomic refuses it outright before any staleness
# question applies (a directory is neither -L nor -f, so _zuvo_home_drop_stale leaves it alone). Proof
# that a failed protocol copy is counted and named, the way every other ~/.zuvo file's failure is.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
ZPB="$(mktemp -d "$TMP/zuvo-proto-blocked.XXXXXX")"; mkdir -p "$ZPB/.zuvo/blind-coverage-audit.md"
zpb_log="$(zuvo_install "$ZPB")"
if [ "$(log_field "$zpb_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zpb_log" INSTALL_VERIFY_MISSING)" = 1 ] \
   && printf '%s\n' "$zpb_log" | grep -qF "$ZPB/.zuvo/blind-coverage-audit.md"; then
  pass "(17-premise) a blocked ~/.zuvo/blind-coverage-audit.md is counted (INSTALL_VERIFY_MISSING=1) and named, and the install carries on"
else
  bad "(17-premise) a blocked ~/.zuvo/blind-coverage-audit.md: status=[$(log_field "$zpb_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zpb_log" INSTALL_VERIFY_MISSING)] (want 0/1) — $(printf '%s' "$zpb_log" | tail -3 | tr '\n' '|')"
fi
expect_log_has "(17-premise) …the install says WHY" "$zpb_log" "blind-coverage-audit.md (the blind-audit panel's protocol) did NOT install"
# T1: the installer must NEVER remove a user's directory — install_file_atomic refuses a directory
# destination outright, and _zuvo_home_drop_stale only ever touches a -L or -f path, so the blocking
# directory itself must survive the install untouched.
if [ -d "$ZPB/.zuvo/blind-coverage-audit.md" ]; then
  pass "(17-premise) the blocking directory itself was never removed by the install"
else
  bad "(17-premise) the blocking directory is GONE — the installer removed a user's directory"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (17e)/(17f) Item 1: a FAILED install of ~/.zuvo/blind-coverage-audit.md must not leave an OLDER copy
# in place — the same class Plan A fixed for model-subprocess.sh (_zuvo_home_drop_stale, generalised
# this round). Left stale, the panel library would silently load a DIFFERENT protocol than the one it
# validates answers against (every answer invalid) while the install only said "failed". Same cp/rm
# stand-in technique as (12e)/(12f), scoped to the ONE flat file this task adds: the cp stand-in matches
# install_file_atomic's hidden temp name (.blind-coverage-audit.md.XXXXXX, same directory as the dest),
# not the final path — that temp name is what `cp` actually receives.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
ZPS="$(mktemp -d "$TMP/zuvo-proto-stale.XXXXXX")"; mkdir -p "$ZPS/.zuvo"
printf 'Audit mode: strict\n# STALE protocol from an older install — must not survive a failed copy\n' > "$ZPS/.zuvo/blind-coverage-audit.md"
PROTOREFUSE_BIN="$TMP/proto-refuse-bin"; mkdir -p "$PROTOREFUSE_BIN"
# shellcheck disable=SC2016  # the stand-in's own $1/$2/$@
printf '#!/bin/sh\n# cp stand-in: a copy staged as .zuvo/.blind-coverage-audit.md.* (install_file_atomic'"'"'s\n# hidden temp name) gets 16 bytes; the real cp everywhere else\ncase "$2" in */.zuvo/.blind-coverage-audit.md.*) head -c 16 "$1" > "$2"; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$(command -v cp)" > "$PROTOREFUSE_BIN/cp"
chmod +x "$PROTOREFUSE_BIN/cp"
zps_log="$( PATH="$PROTOREFUSE_BIN:$PATH"; zuvo_install "$ZPS" )"
if [ "$(log_field "$zps_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zps_log" INSTALL_VERIFY_MISSING)" = 1 ] \
   && printf '%s\n' "$zps_log" | grep -qF "$ZPS/.zuvo/blind-coverage-audit.md"; then
  pass "(17e) a refused protocol copy is counted (INSTALL_VERIFY_MISSING=1) and named, and the install carries on"
else
  bad "(17e) a refused protocol copy: status=[$(log_field "$zps_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zps_log" INSTALL_VERIFY_MISSING)] (want 0/1) — $(printf '%s' "$zps_log" | tail -3 | tr '\n' '|')"
fi
if [ ! -e "$ZPS/.zuvo/blind-coverage-audit.md" ] && [ ! -L "$ZPS/.zuvo/blind-coverage-audit.md" ]; then
  pass "(17e) the STALE ~/.zuvo/blind-coverage-audit.md was removed — a mismatched protocol can no longer be silently loaded"
else
  bad "(17e) the STALE ~/.zuvo/blind-coverage-audit.md is still there — the panel library would load it as current"
fi
expect_log_has "(17e) …and the install says so" "$zps_log" "removed the STALE $ZPS/.zuvo/blind-coverage-audit.md"

# make_rm_refuser <bin-dir> — an `rm` stand-in in <bin-dir> that refuses to remove ONE file, named at
# run time by $ZUVO_T_RM_REFUSE, and hands everything else to the real rm ($ZUVO_T_REAL_RM). P2-111
# anchored the refusal to that one file instead of a `*.zuvo/…` suffix; two more things now:
#   * P3C-27: the path is never pasted into the stand-in's SOURCE — it used to be printf'd into a
#     double-quoted `case` pattern, where a `"`, `$`, `*` or `` ` `` in a temp path would change what the
#     generated script means. The stand-in is a quoted heredoc; the path arrives as data;
#   * P3C-28/P3C-34: it is compared PHYSICALLY — directory resolved with `pwd -P`, both sides — so a
#     relative (`rm ./x` from its directory) or symlinked (/var vs /private/var on macOS) spelling of the
#     same file is refused too. The case's own premise ("the stale copy is still in place") would catch a
#     miss, but only after the case had proved nothing.
make_rm_refuser() {
  mkdir -p "$1" || return 1
  cat > "$1/rm" <<'RMSTAND'
#!/bin/sh
# rm stand-in (test-install-wiring.sh, make_rm_refuser): refuses $ZUVO_T_RM_REFUSE however it is
# spelled; the real rm ($ZUVO_T_REAL_RM) for everything else.
want="${ZUVO_T_RM_REFUSE:-}"
phys() { ( d=$(dirname "$1") && b=$(basename "$1") && cd "$d" 2>/dev/null && printf '%s/%s' "$(pwd -P)" "$b" ); }
if [ -n "$want" ]; then
  w=$(phys "$want") || w="$want"
  for a in "$@"; do
    case "$a" in -*) continue ;; esac
    [ "$a" = "$want" ] && exit 1
    p=$(phys "$a") && [ "$p" = "$w" ] && exit 1
  done
fi
exec "${ZUVO_T_REAL_RM:-/bin/rm}" "$@"
RMSTAND
  chmod +x "$1/rm"
}
REAL_RM="$(command -v rm)"
# The stand-in itself, on the spellings it must refuse (and one file it must still remove), before any
# case relies on it: a stand-in that lets a spelling through makes its case's premise fail for a reason
# that has nothing to do with install.sh.
RMR="$(mktemp -d "$TMP/rm-refuser.XXXXXX")"; mkdir -p "$RMR/d"
printf 'x\n' > "$RMR/d/keep"; printf 'x\n' > "$RMR/d/other"; ln -s "$RMR/d" "$RMR/link"
make_rm_refuser "$RMR/bin"
_rmr_rc1=0; ( cd "$RMR/d" && ZUVO_T_RM_REFUSE="$RMR/d/keep" ZUVO_T_REAL_RM="$REAL_RM" "$RMR/bin/rm" -f keep ) || _rmr_rc1=$?
_rmr_rc2=0; ZUVO_T_RM_REFUSE="$RMR/d/keep" ZUVO_T_REAL_RM="$REAL_RM" "$RMR/bin/rm" -f "$RMR/link/keep" || _rmr_rc2=$?
_rmr_rc3=0; ZUVO_T_RM_REFUSE="$RMR/d/keep" ZUVO_T_REAL_RM="$REAL_RM" "$RMR/bin/rm" -f "$RMR/d/other" || _rmr_rc3=$?
if [ "$_rmr_rc1" -ne 0 ] && [ "$_rmr_rc2" -ne 0 ] && [ -f "$RMR/d/keep" ] && [ "$_rmr_rc3" -eq 0 ] && [ ! -e "$RMR/d/other" ]; then
  pass "rm stand-in: refuses its file by relative and by symlinked spelling, and still removes anything else (P3C-28/P3C-34)"
else
  bad "rm stand-in: relative rc=$_rmr_rc1, symlinked rc=$_rmr_rc2, keep $([ -f "$RMR/d/keep" ] && echo kept || echo REMOVED), other rc=$_rmr_rc3 $([ -e "$RMR/d/other" ] && echo 'NOT removed' || echo removed) — want refused, refused, kept, 0, removed (P3C-28/P3C-34)"
fi

ZPR="$(mktemp -d "$TMP/zuvo-proto-rmfail.XXXXXX")"; mkdir -p "$ZPR/.zuvo"
printf 'Audit mode: strict\n# STALE protocol from an older install\n' > "$ZPR/.zuvo/blind-coverage-audit.md"
PROTORMFAIL_BIN="$TMP/proto-rmfail-bin"; mkdir -p "$PROTORMFAIL_BIN"
cp "$PROTOREFUSE_BIN/cp" "$PROTORMFAIL_BIN/cp"
chmod +x "$PROTORMFAIL_BIN/cp"
make_rm_refuser "$PROTORMFAIL_BIN"
zpr_log="$( PATH="$PROTORMFAIL_BIN:$PATH"
            ZUVO_T_RM_REFUSE="$ZPR/.zuvo/blind-coverage-audit.md" ZUVO_T_REAL_RM="$REAL_RM" zuvo_install "$ZPR" )"
if [ "$(log_field "$zpr_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zpr_log" INSTALL_VERIFY_MISSING)" = 1 ]; then
  pass "(17f) a stale protocol that cannot be removed: counted (INSTALL_VERIFY_MISSING=1), and the install carries on"
else
  bad "(17f) status=[$(log_field "$zpr_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zpr_log" INSTALL_VERIFY_MISSING)] (want 0/1)"
fi
if [ -f "$ZPR/.zuvo/blind-coverage-audit.md" ]; then pass "(17f) premise: the stale protocol is still in place (the rm stand-in refused it)"
else bad "(17f) premise: the stale protocol is gone — the rm stand-in did not intercept, the case proves nothing"; fi
expect_log_has "(17f) …it says the stale copy could not be removed, naming it" "$zpr_log" "a STALE $ZPR/.zuvo/blind-coverage-audit.md could not be removed"
expect_log_has "(17f) …and the summary detail names it too" "$zpr_log" "stale blind-audit protocol: $ZPR/.zuvo/blind-coverage-audit.md"
# ADV-C26: (17e) proves the STALE protocol is removed; this sibling (17f, "removal refused") must
# also prove the installed driver still runs sanely end-to-end afterward — the same `--mode
# blind-audit` run (17)/(17d)/(P2) already do — rather than stopping at "the miss was counted".
# P2-106: "$BASH", never a bare `bash` — under env -i a bare name resolves on the NARROWED PATH
# (/bin/bash, 3.2, on macOS), whatever interpreter this suite was deliberately run under.
# P2-113: the driver's own presence is a premise with its own message, not a generic rc=127 below.
# P2-105: and the prompt is checked, not only the exit — the mocks answer the same whatever they are
# sent, so "strict valid=2/2" proves the driver did not crash, not that it built its prompt from the
# stuck-stale protocol. The lane's kept prompt must BEGIN with that file, byte for byte; the negative
# control is (17)'s fresh-install run, whose prompt must not carry the stale file's marker line —
# otherwise the positive check would pass on any prompt at all.
zpr_rc=0
ZPR_STDIN="$TMP/zpr-stdin"; mkdir -p "$ZPR_STDIN"
if [ ! -f "$ZPR/.zuvo/adversarial-review" ]; then
  bad "(17f) premise: the installed driver $ZPR/.zuvo/adversarial-review is missing — the driver run below is skipped"
else
  ( cd "$BA_WORK" && env -i HOME="$ZPR" ZUVO_HOME="$ZPR/.zuvo" TMPDIR="$SPY_TMPD" ZUVO_NO_CAFFEINATE=1 \
      ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
      PATH="$SPY_SHIM:$BA_MOCKS:/usr/bin:/bin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
      ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix" MOCK_STDIN_DIR="$ZPR_STDIN" \
      "$BASH" "$ZPR/.zuvo/adversarial-review" --mode blind-audit --production "$BAP" --test "$BAT" ) \
    > "$TMP/blind-audit-stale-protocol.out" 2> "$TMP/blind-audit-stale-protocol.err" || zpr_rc=$?
  if [ "$zpr_rc" -eq 0 ] && grep -qF 'Audit panel: strict valid=2/2' "$TMP/blind-audit-stale-protocol.out" 2>/dev/null; then
    pass "(17f) the installed driver still runs --mode blind-audit sanely with a stuck-stale, unremovable protocol file"
  else
    bad "(17f) the installed driver did not run sanely with the stuck-stale protocol — rc=$zpr_rc stdout: $(tr '\n' '|' < "$TMP/blind-audit-stale-protocol.out" 2>/dev/null) stderr: $(tail -5 "$TMP/blind-audit-stale-protocol.err" | tr '\n' '|')"
  fi
  # P3C-29: provenance only means something about a run that completed. When the driver run above
  # already FAILED (reported there), these would add a second, differently worded FAIL for the same
  # cause — the cascade P2-138 removed from the preflight suite — so they are skipped, and say so.
  if [ "$zpr_rc" -ne 0 ]; then
    echo "SKIP: (17f) provenance checks — the driver run above already failed (rc=$zpr_rc), so its prompt proves nothing either way"
  else
    _zpr_proto="$ZPR/.zuvo/blind-coverage-audit.md"
    _zpr_pn="$(wc -c < "$_zpr_proto" 2>/dev/null | tr -d ' ')"
    if [ -s "$ZPR_STDIN/mock-strict-clean.stdin" ] && [ -n "$_zpr_pn" ] \
       && head -c "$_zpr_pn" "$ZPR_STDIN/mock-strict-clean.stdin" | cmp -s - "$_zpr_proto"; then
      pass "(17f) …and the lane's prompt begins with the stuck-stale protocol, byte for byte — the run really used that file (P2-105)"
    else
      bad "(17f) the lane's prompt does not begin with the stuck-stale protocol ($_zpr_proto) — the run's provenance is unproven (P2-105)"
    fi
    if [ -s "$BA17_STDIN/mock-strict-clean.stdin" ] \
       && ! grep -qF '# STALE protocol from an older install' "$BA17_STDIN/mock-strict-clean.stdin"; then
      pass "(17f) negative control: (17)'s fresh-install prompt does NOT carry the stale marker — the check above tells protocols apart (P2-105)"
    else
      bad "(17f) negative control: (17)'s fresh-install prompt is missing or carries the stale marker — the provenance check above proves nothing (P2-105)"
    fi
  fi
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# T2: the FLAT ~/.zuvo/blind-audit-panel.sh gets the SAME refused-copy / rm-refused coverage as the
# protocol in (17e)/(17f) — that pair only ever exercised the protocol's own install_file_atomic call;
# the flat panel-library copy has an identical, independent one that needs its own proof. The cp
# stand-in matches install_file_atomic's hidden temp name for the FLAT destination
# (.zuvo/.blind-audit-panel.sh.XXXXXX) and deliberately does NOT match the ~/.zuvo/lib/ copy's temp
# name (.zuvo/lib/.blind-audit-panel.sh.XXXXXX has an extra path segment), so ~/.zuvo/lib/ installs
# normally and this stays isolated to the flat copy's own failure path.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
ZBS="$(mktemp -d "$TMP/zuvo-bap-stale.XXXXXX")"; mkdir -p "$ZBS/.zuvo"
printf '#!/bin/sh\n# STALE blind-audit-panel.sh from an older install — must not survive a failed copy\n' > "$ZBS/.zuvo/blind-audit-panel.sh"
BAPREFUSE_BIN="$TMP/bap-refuse-bin"; mkdir -p "$BAPREFUSE_BIN"
# shellcheck disable=SC2016  # the stand-in's own $1/$2/$@
printf '#!/bin/sh\n# cp stand-in: a copy staged as .zuvo/.blind-audit-panel.sh.* (the FLAT copy'"'"'s hidden\n# temp name, not .zuvo/lib/) gets 16 bytes; the real cp everywhere else\ncase "$2" in */.zuvo/.blind-audit-panel.sh.*) head -c 16 "$1" > "$2"; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$(command -v cp)" > "$BAPREFUSE_BIN/cp"
chmod +x "$BAPREFUSE_BIN/cp"
zbs_log="$( PATH="$BAPREFUSE_BIN:$PATH"; zuvo_install "$ZBS" )"
if [ "$(log_field "$zbs_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zbs_log" INSTALL_VERIFY_MISSING)" = 1 ] \
   && printf '%s\n' "$zbs_log" | grep -qF "$ZBS/.zuvo/blind-audit-panel.sh"; then
  pass "(T2) a refused flat blind-audit-panel.sh copy is counted (INSTALL_VERIFY_MISSING=1) and named, and the install carries on"
else
  bad "(T2) a refused flat blind-audit-panel.sh copy: status=[$(log_field "$zbs_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zbs_log" INSTALL_VERIFY_MISSING)] (want 0/1) — $(printf '%s' "$zbs_log" | tail -3 | tr '\n' '|')"
fi
if [ ! -e "$ZBS/.zuvo/blind-audit-panel.sh" ] && [ ! -L "$ZBS/.zuvo/blind-audit-panel.sh" ]; then
  pass "(T2) the STALE flat ~/.zuvo/blind-audit-panel.sh was removed"
else
  bad "(T2) the STALE flat ~/.zuvo/blind-audit-panel.sh is still there"
fi
expect_log_has "(T2) …and the install says so" "$zbs_log" "removed the STALE $ZBS/.zuvo/blind-audit-panel.sh"

ZBR="$(mktemp -d "$TMP/zuvo-bap-rmfail.XXXXXX")"; mkdir -p "$ZBR/.zuvo"
printf '#!/bin/sh\n# STALE blind-audit-panel.sh from an older install\n' > "$ZBR/.zuvo/blind-audit-panel.sh"
BAPRMFAIL_BIN="$TMP/bap-rmfail-bin"; mkdir -p "$BAPRMFAIL_BIN"
cp "$BAPREFUSE_BIN/cp" "$BAPRMFAIL_BIN/cp"
chmod +x "$BAPRMFAIL_BIN/cp"
# The same stand-in as (17f)'s (make_rm_refuser: the file named at run time, compared physically).
make_rm_refuser "$BAPRMFAIL_BIN"
zbr_log="$( PATH="$BAPRMFAIL_BIN:$PATH"
            ZUVO_T_RM_REFUSE="$ZBR/.zuvo/blind-audit-panel.sh" ZUVO_T_REAL_RM="$REAL_RM" zuvo_install "$ZBR" )"
if [ "$(log_field "$zbr_log" INSTALL_ZUVO_HOME_RC)" = 0 ] && [ "$(log_field "$zbr_log" INSTALL_VERIFY_MISSING)" = 1 ]; then
  pass "(T2) a stale flat blind-audit-panel.sh that cannot be removed: counted (INSTALL_VERIFY_MISSING=1), and the install carries on"
else
  bad "(T2) status=[$(log_field "$zbr_log" INSTALL_ZUVO_HOME_RC)] missing=[$(log_field "$zbr_log" INSTALL_VERIFY_MISSING)] (want 0/1)"
fi
if [ -f "$ZBR/.zuvo/blind-audit-panel.sh" ]; then pass "(T2) premise: the stale flat copy is still in place (the rm stand-in refused it)"
else bad "(T2) premise: the stale flat copy is gone — the rm stand-in did not intercept, the case proves nothing"; fi
expect_log_has "(T2) …it says the stale copy could not be removed, naming it" "$zbr_log" "a STALE $ZBR/.zuvo/blind-audit-panel.sh could not be removed"
expect_log_has "(T2) …and the summary detail names it too" "$zbr_log" "stale blind-audit panel library: $ZBR/.zuvo/blind-audit-panel.sh"

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (17d) Item 2: ~/.zuvo/lib/ blocked entirely (the (12d) technique: its name taken by a regular file, so
# install_runner_lib's mkdir fails). model-subprocess.sh already has a flat fallback for this; the panel
# library needs the SAME one, or --mode blind-audit would break exactly where the codex/claude lanes do
# not. The installed driver must still reach 'Audit panel: strict valid=2/2' through the FLAT
# ~/.zuvo/blind-audit-panel.sh alone.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
ZLB="$(mktemp -d "$TMP/zuvo-libblocked-bap.XXXXXX")"; mkdir -p "$ZLB/.zuvo"; : > "$ZLB/.zuvo/lib"
zlb_log="$(zuvo_install "$ZLB")"
if [ "$(log_field "$zlb_log" INSTALL_ZUVO_HOME_RC)" = 0 ]; then
  pass "(17d) install_zuvo_home still returns 0 despite the blocked ~/.zuvo/lib/"
else
  bad "(17d) install_zuvo_home status=[$(log_field "$zlb_log" INSTALL_ZUVO_HOME_RC)] with ~/.zuvo/lib/ blocked"
fi
if [ ! -e "$ZLB/.zuvo/lib/blind-audit-panel.sh" ]; then
  pass "(17d) premise: ~/.zuvo/lib/ did not install (blocked by a file) — only the flat copy can serve the driver"
else
  bad "(17d) premise: ~/.zuvo/lib/blind-audit-panel.sh exists although ~/.zuvo/lib/ should be blocked — the case proves nothing"
fi
if [ -f "$ZLB/.zuvo/blind-audit-panel.sh" ] && cmp -s "$ROOT/scripts/lib/blind-audit-panel.sh" "$ZLB/.zuvo/blind-audit-panel.sh"; then
  pass "(17d) the flat ~/.zuvo/blind-audit-panel.sh still installed, byte-identical, beside a blocked ~/.zuvo/lib/"
else
  bad "(17d) the flat ~/.zuvo/blind-audit-panel.sh did not install beside a blocked ~/.zuvo/lib/"
fi
zlb_rc=0
( cd "$BA_WORK" && env -i HOME="$ZLB" ZUVO_HOME="$ZLB/.zuvo" TMPDIR="$SPY_TMPD" ZUVO_NO_CAFFEINATE=1 \
    ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
    PATH="$SPY_SHIM:$BA_MOCKS:/usr/bin:/bin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix" \
    "$BASH" "$ZLB/.zuvo/adversarial-review" --mode blind-audit --production "$BAP" --test "$BAT" ) \
  > "$TMP/blind-audit-libblocked.out" 2> "$TMP/blind-audit-libblocked.err" || zlb_rc=$?
if [ "$zlb_rc" -eq 0 ] && grep -qF 'Audit panel: strict valid=2/2' "$TMP/blind-audit-libblocked.out" 2>/dev/null; then
  pass "(17d) the installed driver still runs --mode blind-audit to 'Audit panel: strict valid=2/2' via the FLAT panel library alone"
else
  bad "(17d) the installed driver did not reach the merged panel via the flat library — rc=$zlb_rc stdout: $(tr '\n' '|' < "$TMP/blind-audit-libblocked.out" 2>/dev/null) stderr: $(tail -5 "$TMP/blind-audit-libblocked.err" | tr '\n' '|')"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# P2: when ~/.zuvo/lib/ does not fully install, the sweep must drop a STALE ~/.zuvo/lib/blind-audit-
# panel.sh too, not only model-subprocess.sh (proven elsewhere, 12c/12e) — otherwise a stale
# ~/.zuvo/lib/blind-audit-panel.sh shadows the fresh flat ~/.zuvo/blind-audit-panel.sh (the driver's
# ~/.zuvo/lib/ candidate is checked FIRST). ADV-C27: this case exercises exactly that ONE library, not
# "every library" — model-subprocess.sh's own stale-removal is independently proven elsewhere. Same
# (12e) technique — a real ~/.zuvo/lib/ dir, pre-seeded with a stale blind-audit-panel.sh, and a cp
# stand-in that refuses every copy staged under ~/.zuvo/lib/* (so _zlib_ok=0, the flat copy is
# untouched, _zms_ok=1) — proving the sweep runs even in the "flat runner ok, lib/ failed" combination.
# ═════════════════════════════════════════════════════════════════════════════════════════════════
ZLP="$(mktemp -d "$TMP/zuvo-lib-stale-bap.XXXXXX")"; mkdir -p "$ZLP/.zuvo/lib"
printf '#!/bin/sh\n# STALE blind-audit-panel.sh from an older install, sitting in ~/.zuvo/lib/\n' > "$ZLP/.zuvo/lib/blind-audit-panel.sh"
LIBPANELREFUSE_BIN="$TMP/lib-panel-refuse-bin"; mkdir -p "$LIBPANELREFUSE_BIN"
# shellcheck disable=SC2016  # the stand-in's own $1/$2/$@
printf '#!/bin/sh\n# cp stand-in: a copy staged anywhere under .zuvo/lib/ gets 16 bytes; the real cp elsewhere\ncase "$2" in */.zuvo/lib/*) head -c 16 "$1" > "$2"; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "$(command -v cp)" > "$LIBPANELREFUSE_BIN/cp"
chmod +x "$LIBPANELREFUSE_BIN/cp"
zlp_log="$( PATH="$LIBPANELREFUSE_BIN:$PATH"; zuvo_install "$ZLP" )"
if cmp -s "$RUNNER_LIB" "$ZLP/.zuvo/model-subprocess.sh"; then
  pass "(P2) premise: the flat ~/.zuvo/model-subprocess.sh still installed (only ~/.zuvo/lib/ is refused)"
else
  bad "(P2) premise: the flat ~/.zuvo/model-subprocess.sh did not install — the case does not isolate ~/.zuvo/lib/ as intended"
fi
if [ ! -e "$ZLP/.zuvo/lib/blind-audit-panel.sh" ] && [ ! -L "$ZLP/.zuvo/lib/blind-audit-panel.sh" ]; then
  pass "(P2) the STALE ~/.zuvo/lib/blind-audit-panel.sh was removed by the sweep"
else
  bad "(P2) the STALE ~/.zuvo/lib/blind-audit-panel.sh is still there — it would shadow the fresh flat copy"
fi
expect_log_has "(P2) …the install says so, naming the library" "$zlp_log" "removed the STALE $ZLP/.zuvo/lib/blind-audit-panel.sh"
if [ -f "$ZLP/.zuvo/blind-audit-panel.sh" ] && cmp -s "$ROOT/scripts/lib/blind-audit-panel.sh" "$ZLP/.zuvo/blind-audit-panel.sh"; then
  pass "(P2) the flat ~/.zuvo/blind-audit-panel.sh installed fine (untouched by the ~/.zuvo/lib/ refusal)"
else
  bad "(P2) the flat ~/.zuvo/blind-audit-panel.sh did not install — the case proves nothing about the fallback"
fi
zlp_rc=0
( cd "$BA_WORK" && env -i HOME="$ZLP" ZUVO_HOME="$ZLP/.zuvo" TMPDIR="$SPY_TMPD" ZUVO_NO_CAFFEINATE=1 \
    ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
    PATH="$SPY_SHIM:$BA_MOCKS:/usr/bin:/bin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
    ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix" \
    "$BASH" "$ZLP/.zuvo/adversarial-review" --mode blind-audit --production "$BAP" --test "$BAT" ) \
  > "$TMP/blind-audit-libstale.out" 2> "$TMP/blind-audit-libstale.err" || zlp_rc=$?
if [ "$zlp_rc" -eq 0 ] && grep -qF 'Audit panel: strict valid=2/2' "$TMP/blind-audit-libstale.out" 2>/dev/null; then
  pass "(P2) the installed driver reaches 'Audit panel: strict valid=2/2' through the FLAT copy — the stale ~/.zuvo/lib/ one no longer shadows it"
else
  bad "(P2) the installed driver did not reach the merged panel — rc=$zlp_rc stdout: $(tr '\n' '|' < "$TMP/blind-audit-libstale.out" 2>/dev/null) stderr: $(tail -5 "$TMP/blind-audit-libstale.err" | tr '\n' '|')"
fi

# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (17g) Item 4: install_antigravity deletes ~/.gemini/antigravity/skills (named at that rm -rf site), so
# <driver_dir>/../skills never exists for THIS driver either — bap_find_protocol's repo-relative
# candidate never qualifies, and --mode blind-audit here has a HIDDEN dependency on install_zuvo_home
# having ALSO run in the SAME HOME. host_install_chain runs both functions in one sourced shell (the
# (15) host_install machinery, two calls instead of one).
# ═════════════════════════════════════════════════════════════════════════════════════════════════
# (17g-locale) The chain below runs with NO locale variable (env -i), and under Homebrew bash on macOS
# that made one build in ~16 lose every forked subshell to a SIGSEGV inside libintl -> CoreFoundation
# (scripts/lib/model-subprocess.sh explains). The runner library — sourced by the driver, the router, the
# preflight and model-run, and through reviewer-lanes.sh by install.sh and every build — names the C
# locale the shell already has, exported so child builds inherit it, and never touches a caller's own.
# shellcheck disable=SC2016  # expanded by the child shell
_pl_probe='. "$1" || exit 97; printf "%s|%s" "${LANG-unset}" "$(env | awk "/^LANG=/")"'
expect_eq_pl() { if [ "$2" = "$3" ]; then pass "$1"; else bad "$1 — got [$3], want [$2]"; fi; }
for _pl_lib in model-subprocess.sh reviewer-lanes.sh; do
  expect_eq_pl "(17g-locale) $_pl_lib gives a shell with no locale LANG=C, exported" "C|LANG=C" \
    "$(env -i /bin/bash -c "$_pl_probe" _ "$ROOT/scripts/lib/$_pl_lib")"
done
expect_eq_pl "(17g-locale) …and keeps a caller's LANG as it is" "pl_PL.UTF-8|LANG=pl_PL.UTF-8" \
  "$(env -i LANG=pl_PL.UTF-8 /bin/bash -c "$_pl_probe" _ "$ROOT/scripts/lib/model-subprocess.sh")"
expect_eq_pl "(17g-locale) …and adds no LANG beside a caller's LC_ALL" "unset|" \
  "$(env -i LC_ALL=C /bin/bash -c "$_pl_probe" _ "$ROOT/scripts/lib/model-subprocess.sh")"
# Every entry point that runs with no locale in these suites sources the runner library.
for _pl_src in scripts/adversarial-review.sh scripts/reviewer-preflight.sh scripts/reviewer-model-route.sh scripts/zuvo-home/model-run scripts/lib/reviewer-lanes.sh; do
  if awk '/^[[:space:]]*#/ { next } /model-subprocess\.sh/ { f = 1 } END { exit !f }' "$ROOT/$_pl_src"; then pass "(17g-locale) $_pl_src sources the runner library"
  else bad "(17g-locale) $_pl_src no longer sources model-subprocess.sh — it runs without the locale name"; fi
done
unset _pl_lib _pl_src
unset _pl_probe

host_install_chain() {
  mkdir -p "$4" "$3/tmp"
  # ADV-C30: env -i, like the driver-probe runs elsewhere in this file — install_antigravity /
  # install_zuvo_home are pure file-copy functions with no conditional host-signal branching this
  # ambient environment would perturb, but isolating it removes the one call site in this file that
  # still inherits the calling test process's full environment instead of a controlled one.
  # shellcheck disable=SC2016  # expanded by the child shell
  env -i HOME="$3" ZUVO_DIST_ROOT="$4" TMPDIR="$3/tmp" PATH="$PATH" "$BASH" -c 'unset KIMI_CODE_HOME
    . "$1" >/dev/null 2>&1 || { echo "SOURCE FAILED"; exit 97; }
    : "${INSTALL_VERIFY_MISSING:=0}" "${INSTALL_VERIFY_DETAIL:=}"
    eval "$4"
    trap "_hi_report \$?" EXIT
    set -euo pipefail
    "$2" && "$3"' _ "$INSTALL" "$1" "$2" "$HI_REPORT_DEF" 2>&1
}
AGH="$(mktemp -d "$TMP/antigravity-zuvo-home.XXXXXX")" || { echo "FATAL: mktemp -d failed"; exit 1; }
AGD="$TMP/antigravity-zuvo-dist"
mkdir -p "$AGH/.gemini/antigravity" || { echo "FATAL: mkdir -p $AGH/.gemini/antigravity failed"; exit 1; }   # the mark install_antigravity's first check recognises, per (15)
agh_log="$(host_install_chain install_antigravity install_zuvo_home "$AGH" "$AGD")"; agh_subst_rc=$?
agh_rc="$(log_field "$agh_log" HOST_INSTALL_RC)"
agh_miss="$(log_field "$agh_log" INSTALL_VERIFY_MISSING)"
# ADV-C38: also check the OUTER command-substitution's own exit status, not only the printed
# HOST_INSTALL_RC= field the trap reports — symmetric with the field check below, for a total
# crash that somehow still lets the trap run but prints an unexpected value.
if [ "$agh_subst_rc" = 0 ]; then
  pass "(17g) the host_install_chain command substitution itself exits 0"
else
  bad "(17g) the host_install_chain command substitution exited $agh_subst_rc"
fi
if [ "$agh_rc" = 0 ]; then
  pass "(17g) install_antigravity then install_zuvo_home, chained into ONE HOME, returns 0"
else
  # The ERROR lines, not the WARNs: a WARN-only excerpt once hid the cause (a bash SIGSEGV, status 139).
  bad "(17g) the chained install exited $agh_rc — $(printf '%s' "$agh_log" | awk '/ERROR|✗|FAILED/' | head -5 | tr '\n' '|')"
fi
# T3: a clean chained install into a fresh temp HOME must have NOTHING missing.
# ADV-C29: gated on agh_rc too — a chained-install FAILURE (already caught above) must not also
# print a locally-true-but-misleading "nothing missing" line next to it; a real chain failure
# should read as one clear FAIL for this fixture, not FAIL-then-PASS side by side.
if [ "$agh_rc" = 0 ] && [ "$agh_miss" = 0 ]; then
  pass "(17g) INSTALL_VERIFY_MISSING=0 — nothing missing across the chained install"
elif [ "$agh_rc" != 0 ]; then
  bad "(17g) skipped — the chained install itself already failed (rc=$agh_rc), so INSTALL_VERIFY_MISSING is not meaningful"
else
  bad "(17g) INSTALL_VERIFY_MISSING=$agh_miss (want 0) — $(printf '%s' "$agh_log" | awk '/ERROR|✗|FAILED|failed|MISSING/' | head -5 | tr '\n' '|')"
fi
# ADV-C33 (+dup C34/C35): both premises must GATE the driver-run block below, not just call bad()
# and let it run anyway — a violated premise already fails the suite via its own bad(), but the
# driver sub-assertion's "prove-the-fallback-specifically" claim would otherwise still print
# pass/fail independently, which could read as misleading if a premise silently drifted.
_17g_premises_ok=1
if [ ! -d "$AGH/.gemini/antigravity/skills" ]; then
  pass "(17g) premise: ~/.gemini/antigravity/skills does not exist — the driver's repo-relative protocol candidate can never qualify"
else
  bad "(17g) premise: ~/.gemini/antigravity/skills exists — this case would prove nothing about the ~/.zuvo fallback"
  _17g_premises_ok=0
fi
if [ -f "$AGH/.zuvo/blind-coverage-audit.md" ]; then
  pass "(17g) premise: install_zuvo_home's ~/.zuvo/blind-coverage-audit.md is there for the fallback to reach"
else
  bad "(17g) premise: ~/.zuvo/blind-coverage-audit.md missing — install_zuvo_home did not run, the case proves nothing"
  _17g_premises_ok=0
fi
AG_DRV="$AGH/.gemini/antigravity/scripts/adversarial-review.sh"
# P2-109: gated on the chained install's own status as well (ADV-C29's rule, extended from the
# "nothing missing" line above to this run) — a chain that already FAILED must not print a
# locally-true driver PASS beneath its own FAIL.
if [ "$agh_rc" != 0 ]; then
  echo "SKIP: (17g) driver run skipped — the chained install itself already failed (rc=$agh_rc), so a pass here would say nothing about a working install"
elif [ ! -f "$AG_DRV" ]; then
  bad "(17g) the antigravity driver did not install at $AG_DRV — the run below is skipped"
elif [ "$_17g_premises_ok" -ne 1 ]; then
  echo "SKIP: (17g) driver run skipped — a premise above was violated, so this run would prove nothing about the ~/.zuvo fallback specifically"
else
  agp_rc=0
  # ADV-C36: "$BASH" (the interpreter running THIS suite), not a bare `bash` — every other
  # bash-3.2-coverage invocation in this file uses "$BASH"; a bare `bash` here silently ran under
  # bash 5 even when the outer suite was deliberately run under /bin/bash to prove 3.2 compatibility.
  ( cd "$BA_WORK" && env -i HOME="$AGH" ZUVO_HOME="$AGH/.zuvo" TMPDIR="$SPY_TMPD" ZUVO_NO_CAFFEINATE=1 \
      ZUVO_PROVIDER_BENCH=0 ZUVO_CODEX_BIN=/nonexistent ZUVO_CODEX_APP_BIN=/nonexistent \
      PATH="$SPY_SHIM:$BA_MOCKS:/usr/bin:/bin" ZUVO_ADVERSARIAL_TEST_HARNESS=1 \
      ZUVO_REVIEW_TEST_PROVIDERS="mock-strict-clean mock-strict-fix" \
      "$BASH" "$AG_DRV" --mode blind-audit --production "$BAP" --test "$BAT" ) \
    > "$TMP/blind-audit-antigravity.out" 2> "$TMP/blind-audit-antigravity.err" || agp_rc=$?
  if [ "$agp_rc" -eq 0 ] && grep -qF 'Audit panel: strict valid=2/2' "$TMP/blind-audit-antigravity.out" 2>/dev/null; then
    pass "(17g) the installed antigravity driver reaches 'Audit panel: strict valid=2/2' through the ~/.zuvo protocol fallback, no --protocol flag"
  else
    bad "(17g) the antigravity driver did not reach the merged panel — rc=$agp_rc stdout: $(tr '\n' '|' < "$TMP/blind-audit-antigravity.out" 2>/dev/null) stderr: $(tail -5 "$TMP/blind-audit-antigravity.err" | tr '\n' '|')"
  fi
fi

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
