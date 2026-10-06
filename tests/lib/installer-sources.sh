#!/usr/bin/env bash
# installer-sources.sh — the TEXT of the installer, for tests that read it. Sourced, not run.
#
# scripts/install.sh is the entry point; the installer functions live in scripts/install.d/*.sh,
# which it loads through `_zi_source`. A test that greps, slices or awk-extracts install.sh alone
# stops seeing every function that moved out of it — and several tests assert ABSENCE ("no blanket
# rm -rf …"), where a grep that finds nothing reads as a pass. So every test that reads the
# installer's text reads it through here, and the set of files is defined once: by install.sh.
#
#   installer_sources [root]   one path per line: scripts/install.sh, then each module it loads
#                              through `_zi_source`, in load order
#   installer_text [root]      their contents, concatenated in that order, each ending in a newline
#
# [root] defaults to the repo this file lives in. Both FAIL (status 1, reason on stderr) instead of
# returning a partial installer: a module install.sh loads that is missing or unreadable, or a
# scripts/install.d/*.sh that install.sh never loads (text a test would read and the installer
# never runs). A SHORT text is the dangerous failure here — an absence check over half the
# installer passes. And an absence check fed through `<(installer_text)` cannot see that status,
# so sourcing this file checks the repo's installer text once and exits the test if it is
# incomplete; the guarantee has to exist before the first assertion, not after it.
#
# Use the process substitution form for single-file tools — `grep -q pat <(installer_text)` — rather
# than a pipe: `installer_text | grep -q` under `set -o pipefail` reports the writer's SIGPIPE.
# install.sh comes FIRST, so its source-time code (the guards, VERSION, the target dispatch)
# precedes every function body, and line positions compared across them keep their meaning.
#
# Python tests use the same definition through bash:
#   subprocess.run(["bash", "-c", '. "$1/tests/lib/installer-sources.sh"; installer_text "$1"', "_", str(ROOT)], …)

_INSTALLER_SOURCES_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# installer_modules <root> — the module names install.sh passes to `_zi_source`, in load order.
installer_modules() {
  local line
  while IFS= read -r line || [ -n "$line" ]; do        # || [ -n ]: a last line with no newline counts
    line="${line#"${line%%[![:space:]]*}"}"              # an indented call is still a call
    case "$line" in
      "_zi_source "*)
        line="${line#_zi_source }"
        line="${line%%||*}"
        # shellcheck disable=SC2086  # the names are [a-z-] words: splitting them is the point
        printf '%s\n' $line
        ;;
    esac
  done < "$1/scripts/install.sh"
}

installer_sources() {
  local root="${1:-$_INSTALLER_SOURCES_ROOT}" m f loaded=" "
  if [ ! -r "$root/scripts/install.sh" ]; then
    echo "installer_sources: cannot read $root/scripts/install.sh" >&2
    return 1
  fi
  printf '%s\n' "$root/scripts/install.sh"
  while IFS= read -r m; do
    f="$root/scripts/install.d/$m.sh"
    if [ ! -r "$f" ]; then
      echo "installer_sources: install.sh loads '$m' but $f cannot be read" >&2
      return 1
    fi
    printf '%s\n' "$f"
    loaded="$loaded$m "
  done < <(installer_modules "$root")
  for f in "$root"/scripts/install.d/*.sh; do
    [ -e "$f" ] || continue
    m="${f##*/}"; m="${m%.sh}"
    case "$loaded" in
      *" $m "*) ;;
      *) echo "installer_sources: $f is never loaded by install.sh (no \`_zi_source $m\`)" >&2; return 1 ;;
    esac
  done
}

installer_text() {
  local list f
  list="$(installer_sources "$@")" || return 1
  while IFS= read -r f; do
    cat "$f" || return 1
    # A file without a final newline must not run its last line into the next file's first.
    [ -z "$(tail -c 1 "$f")" ] || echo
  done <<< "$list"
}

if ! installer_text "$_INSTALLER_SOURCES_ROOT" > /dev/null; then
  echo "FAIL: the installer's text is incomplete (see above) — refusing to run text assertions against it"
  exit 1
fi
