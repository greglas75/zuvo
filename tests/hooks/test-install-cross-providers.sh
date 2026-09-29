#!/usr/bin/env bash
# Behavioral checks for install.sh's post-install cross-provider count (check_cross_providers).
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)" || exit 1
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" GIT_CONFIG_GLOBAL="$TMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"

PASS=0; FAIL=0
t_ok() { printf '  PASS %s\n' "$1"; PASS=$((PASS + 1)); }
t_no() { printf '  FAIL %s\n' "$1"; FAIL=$((FAIL + 1)); }

# Sourcing also wires the shell sleep guard; HOME is isolated above for that side effect.
if ! . "$ROOT/scripts/install.sh" >"$TMP/source.out" 2>&1; then
  t_no "install.sh can be sourced into the isolated HOME"
  exit 1
fi

# Reviewer-lane materialization (materialize_/validate_claude_reviewer_lanes) is NOT tested here:
# its contract changed to "only skills/*/agents/*.md frontmatter; prose keeps the router's words",
# and scripts/tests/reviewer-model-builds.bats ("Claude cache: …" + "reviewer-lanes: …") covers it —
# rewrite, prose preserved, residual lane, missing dir, symlink, unreadable file, failed rewrite.
# This file keeps the cross-provider count, which nothing else exercises.

# Stub only the provider lookup. The app-bundle Codex fallback is an absolute
# path, so account for its presence independently of the function under test.
# This post-install function is defined inside the direct-execution guard, so
# sourcing install.sh does not define it; extract the unchanged function body
# from the production file rather than reimplementing its behavior in the test.
# shellcheck disable=SC1090
source <(sed -n '/^check_cross_providers() {/,/^}/p' "$ROOT/scripts/install.sh")
codex_bundle=0
[ -x /Applications/Codex.app/Contents/Resources/codex ] && codex_bundle=1
provider_case() (
  local provided="$1"
  unset MOONSHOT_API_KEY
  command() {
    if [ "$1" != -v ]; then builtin command "$@"; return $?; fi
    case " $provided " in
      *" $2 "*) return 0 ;;
      *) return 1 ;;
    esac
  }
  check_cross_providers
)
google_count=$((codex_bundle + 1))
agy_only="$(provider_case agy)"
if [[ "$agy_only" == *"Cross-provider check: $google_count vendor"* ]] && \
   [[ "$agy_only" == *'agy (Google/Antigravity)'* ]]; then
  t_ok "agy alone counts as one Google vendor"
else
  t_no "agy-only provider count or label is wrong: $(printf '%s' "$agy_only" | tr '\n' '|')"
fi
gemini_only="$(provider_case gemini)"
if [[ "$gemini_only" == *"Cross-provider check: $google_count vendor"* ]] && \
   [[ "$gemini_only" == *'gemini (Google'* ]]; then
  t_ok "gemini alone counts as one Google vendor"
else
  t_no "gemini-only provider count or label is wrong: $(printf '%s' "$gemini_only" | tr '\n' '|')"
fi
both_google="$(provider_case 'agy gemini')"
if [[ "$both_google" == *"Cross-provider check: $google_count vendor"* ]] && \
   [[ "$both_google" == *'agy (Google/Antigravity)'* ]] && \
   [[ "$both_google" != *'gemini (Google'* ]]; then
  t_ok "agy and gemini count as one vendor and prefer the agy label"
else
  t_no "two Google clients were double-counted or the preferred label changed: $(printf '%s' "$both_google" | tr '\n' '|')"
fi

# install.sh's main run calls check_cross_providers as a plain statement under `set -euo pipefail`.
# print_providers used to END on `[[ -n "$has_claude" ]] && echo …` — status 1 when claude is absent —
# so a host without the claude CLI aborted right here, before the copy-verification summary, the
# install stamp and DONE. The cases above run without errexit and could never see it.
for _prov in codex 'codex agy' 'agy kimi'; do
  _out="$(set -euo pipefail; provider_case "$_prov"; echo "__survived__")"; _rc=$?
  if [ "$_rc" -eq 0 ] && [[ "$_out" == *__survived__* ]]; then
    t_ok "under set -euo pipefail, providers [$_prov] without claude do not abort the install"
  else
    t_no "under set -euo pipefail, providers [$_prov] without claude aborted (rc=$_rc): $(printf '%s' "$_out" | tr '\n' '|')"
  fi
done

printf '  --- install cross-providers: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
