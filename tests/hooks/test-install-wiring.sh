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
if [ "$codex_rc" -eq 0 ] && [ -f "$ROOT/dist/codex/hooks/block-no-verify.sh" ] && [ -f "$ROOT/dist/codex/hooks/lib/pipeline-gate-lib.sh" ]; then
  pass "(6) codex build exits 0 and ships block-no-verify + hooks/lib/"
else
  bad "(6) codex build exited $codex_rc or is missing block-no-verify or lib (tail: $(printf '%s' "$codex_log" | tail -3))"
fi
# (14f, planted here) A library removed or renamed upstream must not linger in the build's
# scripts/lib/: the build output is regenerated, never merged into. A stale file is planted where
# the build writes BEFORE it runs; (14f) below asserts it is gone.
_ag_stale="${ZUVO_DIST_ROOT:-$ROOT/dist}/antigravity/scripts/lib/zz-removed-upstream.sh"
mkdir -p "${_ag_stale%/*}" && printf '# stale: removed from scripts/lib/ upstream\n' > "$_ag_stale"
antig_log=$(bash "$ROOT/tests/lib/dist-build.sh" antigravity 2>&1); antig_rc=$?
if [ "$antig_rc" -eq 0 ] && [ -f "$ROOT/dist/antigravity/hooks/block-no-verify.sh" ] && [ -f "$ROOT/dist/antigravity/hooks/lib/pipeline-gate-lib.sh" ]; then
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
for _tool in timeout gtimeout jq; do
  _real="$(command -v "$_tool" 2>/dev/null || true)"
  [ -n "$_real" ] && ln -s "$_real" "$SPY_SHIM/$_tool"
done
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
      bash "$2" --mode code --provider codex-5.3 ) > "$TMP/spy-$1.out" 2> "$TMP/spy-$1.err" || rc=$?
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
lib_mismatch() {
  local f n out=""
  for f in "$1"/*; do
    [ -f "$f" ] || continue
    n="${f##*/}"
    if [ -L "$2/$n" ] || [ ! -f "$2/$n" ]; then out="$out $n(missing)"
    elif ! cmp -s "$f" "$2/$n"; then out="$out $n(differs)"
    elif [ -x "$f" ] && [ ! -x "$2/$n" ]; then out="$out $n(lost its exec bit)"
    elif [ ! -x "$f" ] && [ -x "$2/$n" ]; then out="$out $n(gained an exec bit)"
    fi
  done
  printf '%s' "$out"
}
# temp_debris <dir> — dot-entries left in a lib dir (the installer's temp names start with a dot).
temp_debris() { ls -A "$1" 2>/dev/null | awk '/^\./' | tr '\n' ' '; }
# log_field <log> <KEY> — the value of the last KEY=value line in <log>.
log_field() { printf '%s\n' "$1" | awk -F= -v k="$2" '$1 == k {v = substr($0, length(k) + 2)} END {print v}'; }

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
if ( : > "$HR/.codex/scripts/lib/.write-probe" ) 2>/dev/null; then
  rm -f "$HR/.codex/scripts/lib/.write-probe"
  echo "SKIP: (14a-ro) this user can write into a 0555 directory (root?) — a read-only destination cannot be staged"
else
  INSTALL_VERIFY_MISSING=0; INSTALL_VERIFY_DETAIL=""
  ro_rc=0; install_runner_lib "codex scripts (runner lib)" "$LIBCOPY" "$HR/.codex/scripts" > "$TMP/ro.out" 2>&1 || ro_rc=$?
  _nfiles=0; for _f in "$LIBCOPY"/*; do [ -f "$_f" ] && _nfiles=$((_nfiles + 1)); done
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
  echo "SKIP: (14a-cp) this user can read a 0000 file (root?) — an unreadable source cannot be staged"
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

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
