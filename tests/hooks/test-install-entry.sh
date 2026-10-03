#!/usr/bin/env bash
# scripts/install.sh as an ENTRY POINT: what it does before any host is installed, and what the copy
# of it that ships into the Claude plugin cache can still do.
#
# install.sh loads its code from scripts/install.d/ (via _zi_source). Two ways that can go wrong
# without any host installer misbehaving: a module that is not there (sourcing a missing file only
# warns, so the first symptom used to be a "command not found" halfway through a host's install),
# and the plugin cache, which receives install.sh with the flat scripts/*.sh copy — a cached
# install.sh without its modules beside it is an installer that cannot start.
#
# Test level: MEDIUM — real install.sh runs and sources, in temp HOMEs and temp copies of the repo;
# nothing is written outside $TMP, no network, no provider CLI.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
fail=0; npass=0; nfail=0
pass() { printf 'PASS: %s\n' "$1"; npass=$((npass + 1)); }
bad()  { printf 'FAIL: %s\n' "$1"; fail=1; nfail=$((nfail + 1)); }
[ -n "${BASH:-}" ] || BASH="$(command -v bash)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
[ -n "$TMP" ] && [ -d "$TMP" ] || { echo "FAIL: mktemp -d failed"; exit 1; }

# run_sandboxed <home> <command…> — run a command in the isolated environment every case uses.
run_sandboxed() {
  local h="$1"; shift
  env -i PATH="$PATH" HOME="$h" TMPDIR="$TMP" LANG=C LC_ALL=C GIT_CONFIG_GLOBAL="$h/.gitconfig" \
    GIT_CONFIG_NOSYSTEM=1 XDG_CONFIG_HOME="$h/.config" ZUVO_DIST_ROOT="$h.dist" "$@"
}
# repo_copy <dir> — the files install.sh needs to start, without the rest of the repo.
repo_copy() {
  mkdir -p "$1/scripts"
  cp "$ROOT/package.json" "$1/"
  cp -R "$ROOT/scripts/install.sh" "$ROOT/scripts/install.d" "$ROOT/scripts/lib" "$1/scripts/"
}

# (1) a missing module, RUN: refused by name, exit 1, before any host banner, nothing in HOME
R="$TMP/missing-run"; repo_copy "$R"; rm "$R/scripts/install.d/codex.sh"
H="$TMP/h1"; mkdir -p "$H"
run_sandboxed "$H" "$BASH" "$R/scripts/install.sh" claude > "$TMP/1.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && grep -q "REFUSING: cannot read .*/scripts/install.d/codex.sh" "$TMP/1.out" \
   && ! grep -q 'CLAUDE CODE' "$TMP/1.out" && [ -z "$(ls -A "$H")" ]; then
  pass "(1) a missing module stops install.sh by name, before any host is touched (exit 1, HOME untouched)"
else
  bad "(1) missing module, run: exit $rc, HOME: [$(ls -A "$H" | tr '\n' ' ')], output: $(tail -3 "$TMP/1.out")"
fi

# (2) the same tree, SOURCED: install.sh returns 1 and the sourcing shell carries on
H="$TMP/h2"; mkdir -p "$H"
out="$(run_sandboxed "$H" "$BASH" -c '. "$1"; echo "after-source rc=$?"' _ "$R/scripts/install.sh" 2>&1)"
if printf '%s\n' "$out" | grep -q '^after-source rc=1$'; then
  pass "(2) sourced with a missing module, install.sh returns 1 instead of killing the caller"
else
  bad "(2) sourced with a missing module: $(printf '%s' "$out" | tail -2)"
fi

# (3) install_claude ships install.d/ beside the cached install.sh, and that copy still loads
H="$TMP/h3"; CB="$H/.claude/plugins/cache/zuvo-marketplace/zuvo"
mkdir -p "$CB/0.0.1/skills/old-skill" "$CB/0.0.1/shared/includes" "$CB/0.0.1/rules" "$CB/0.0.1/scripts"
printf '# seed\n' > "$CB/0.0.1/skills/old-skill/SKILL.md"
run_sandboxed "$H" "$BASH" -c 'set -euo pipefail; . "$1" >/dev/null 2>&1; install_claude' _ "$ROOT/scripts/install.sh" > "$TMP/3.out" 2>&1
rc=$?
VERSION="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$ROOT/package.json")"
missing=""
for d in 0.0.1 "$VERSION"; do
  cmp -s "$ROOT/scripts/install.sh" "$CB/$d/scripts/install.sh" || missing="$missing $d/install.sh"
done
for m in "$ROOT"/scripts/install.d/*.sh; do
  for d in 0.0.1 "$VERSION"; do
    cmp -s "$m" "$CB/$d/scripts/install.d/${m##*/}" || missing="$missing $d/${m##*/}"
  done
done
[ "$rc" -eq 0 ] && [ -z "$missing" ] \
  && pass "(3) install.sh and every install.d module reach both cache dirs (seed + current), byte-identical" \
  || bad "(3) install_claude exit $rc; modules missing or different in the cache:$missing [$(tail -2 "$TMP/3.out")]"
H4="$TMP/h4"; mkdir -p "$H4"
want_fns="$(run_sandboxed "$H4" "$BASH" -c '. "$1" >/dev/null 2>&1; declare -F | grep -c " install_"' _ "$ROOT/scripts/install.sh" 2>&1)"
out="$(run_sandboxed "$H4" "$BASH" -c '. "$1" >/dev/null 2>&1; echo "rc=$?"; declare -F | grep -c " install_"' _ "$CB/$VERSION/scripts/install.sh" 2>&1)"
[ "$want_fns" -ge 10 ] && [ "$(printf '%s\n' "$out" | tr '\n' ' ')" = "rc=0 $want_fns " ] \
  && pass "(3b) the cached install.sh sources cleanly and defines all $want_fns install_* functions" \
  || bad "(3b) the cached install.sh does not load: $(printf '%s' "$out" | tr '\n' ' ')"

echo
echo "RESULT: PASS=$npass FAIL=$nfail"
[ "$fail" -eq 0 ] && { echo "ALL PASS"; exit 0; }
echo "FAILURES PRESENT"; exit 1
