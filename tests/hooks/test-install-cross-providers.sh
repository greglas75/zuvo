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

# HOME is isolated above so nothing install.sh reads at source time comes from the caller's home.
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
# The macOS Codex app bundle is an absolute path no PATH stub can hide, so the extracted body has that one
# path pointed at a fixture: absent here (every case below then means the same on any host), and an
# executable stand-in in the bundle case. Nothing else in the function is touched.
BUNDLE="$TMP/Codex.app/Contents/Resources/codex"
[ "$(grep -c '/Applications/Codex.app/Contents/Resources/codex' "$ROOT/scripts/install.sh")" -eq 1 ] \
  || { t_no "check_cross_providers names the Codex app bundle exactly once (the fixture rewrite needs it)"; exit 1; }
# shellcheck disable=SC1090
source <(sed -n '/^check_cross_providers() {/,/^}/p' "$ROOT/scripts/install.sh" | sed "s|/Applications/Codex.app/Contents/Resources/codex|$BUNDLE|")
provider_case() (   # <space-separated CLIs on the PATH> [<MOONSHOT_API_KEY value>]
  local provided="$1"
  unset MOONSHOT_API_KEY
  [ -n "${2:-}" ] && export MOONSHOT_API_KEY="$2"
  command() {
    if [ "$1" != -v ]; then builtin command "$@"; return $?; fi
    case " $provided " in
      *" $2 "*) return 0 ;;
      *) return 1 ;;
    esac
  }
  check_cross_providers
)
agy_only="$(provider_case agy)"
if [[ "$agy_only" == *"Cross-provider check: 1 vendor"* ]] && \
   [[ "$agy_only" == *'agy (Google/Antigravity)'* ]]; then
  t_ok "agy alone counts as one Google vendor"
else
  t_no "agy-only provider count or label is wrong: $(printf '%s' "$agy_only" | tr '\n' '|')"
fi
gemini_only="$(provider_case gemini)"
if [[ "$gemini_only" == *"Cross-provider check: 1 vendor"* ]] && \
   [[ "$gemini_only" == *'gemini (Google'* ]]; then
  t_ok "gemini alone counts as one Google vendor"
else
  t_no "gemini-only provider count or label is wrong: $(printf '%s' "$gemini_only" | tr '\n' '|')"
fi
both_google="$(provider_case 'agy gemini')"
if [[ "$both_google" == *"Cross-provider check: 1 vendor"* ]] && \
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
for _spec in 'codex|codex (OpenAI)' 'codex agy|agy (Google/Antigravity)' 'agy kimi|kimi (Moonshot'; do
  _prov="${_spec%%|*}"; _label="${_spec#*|}"
  _out="$(set -euo pipefail; provider_case "$_prov"; echo "__survived__")"; _rc=$?
  if [ "$_rc" -eq 0 ] && [[ "$_out" == *__survived__* ]] && [[ "$_out" == *"$_label"* ]]; then
    t_ok "under set -euo pipefail, providers [$_prov] without claude do not abort the install, and are listed"
  else
    t_no "under set -euo pipefail, providers [$_prov] without claude aborted (rc=$_rc): $(printf '%s' "$_out" | tr '\n' '|')"
  fi
done

# No provider at all: the warning names the problem and how to fix it.
none="$(provider_case '')"
if [[ "$none" == *'No adversarial review providers found'* ]] && [[ "$none" == *'npm install -g @openai/codex'* ]] \
   && [[ "$none" != *'Cross-provider check:'* ]]; then
  t_ok "no provider: the warning names the problem and the install commands, and no vendor count is printed"
else
  t_no "no provider: [$(printf '%s' "$none" | head -3 | tr '\n' '|')]"
fi

# The Codex app bundle alone (no codex CLI on the PATH) is a provider: one vendor, labelled codex.
mkdir -p "${BUNDLE%/*}"; printf '#!/bin/sh\nexit 0\n' > "$BUNDLE"; chmod +x "$BUNDLE"
app_only="$(provider_case '')"
rm -f "$BUNDLE"
if [[ "$app_only" == *'Cross-provider check: 1 vendor found'* ]] && [[ "$app_only" == *'codex (OpenAI)'* ]]; then
  t_ok "the Codex app bundle alone counts as the one (OpenAI) vendor"
else
  t_no "Codex app bundle: [$(printf '%s' "$app_only" | tr '\n' '|')]"
fi

# Every other vendor is detected and labelled: cursor-agent, kimi, claude — three vendors.
three="$(provider_case 'cursor-agent kimi claude')"
if [[ "$three" == *"Cross-provider check: 3 vendors found"* ]] && [[ "$three" == *'cursor-agent (Cursor)'* ]] \
   && [[ "$three" == *'kimi (Moonshot'* ]] && [[ "$three" == *'claude (Anthropic)'* ]]; then
  t_ok "cursor-agent, kimi and claude are each detected and labelled (3 vendors)"
else
  t_no "cursor-agent/kimi/claude detection: [$(printf '%s' "$three" | tr '\n' '|')]"
fi

# kimi needs no CLI when MOONSHOT_API_KEY is set: the key alone counts it as a vendor (codex counts once,
# from its CLI or the app bundle).
keyed="$(provider_case 'codex' 'sk-test-not-a-real-key')"
if [[ "$keyed" == *"Cross-provider check: 2 vendors found"* ]] \
   && [[ "$keyed" == *'kimi (Moonshot'* ]]; then
  t_ok "MOONSHOT_API_KEY alone counts kimi as a vendor"
else
  t_no "MOONSHOT_API_KEY did not count kimi: [$(printf '%s' "$keyed" | tr '\n' '|')]"
fi

printf '  --- install cross-providers: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
