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

# (7) syntax check on all four scripts (shellcheck absent → bash -n)
for s in scripts/install.sh scripts/build-codex-skills.sh scripts/build-antigravity-skills.sh scripts/build-cursor-skills.sh; do
  if command -v shellcheck >/dev/null 2>&1; then
    shellcheck "$ROOT/$s" >/dev/null 2>&1 && pass "(7) shellcheck $s" || bad "(7) shellcheck failed: $s"
  else
    bash -n "$ROOT/$s" 2>/dev/null && pass "(7) bash -n $s (shellcheck absent)" || bad "(7) syntax error: $s"
  fi
done

if [ "$fail" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
