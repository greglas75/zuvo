#!/usr/bin/env bash
# Behavioral checks for Claude cache reviewer-lane materialization and validation.
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

CACHE="$TMP/cache"
mkdir -p "$CACHE/skills/nested" "$CACHE/shared/includes" "$CACHE/rules"
printf 'primary: review-primary\nalt: review-alt\nunrelated: keep-this-line\n' > "$CACHE/skills/nested/review.md"
printf 'Use review-alt and review-primary.\n' > "$CACHE/shared/includes/guide.md"
printf 'review-primary\n' > "$CACHE/rules/rule.md"
printf 'review-alt in a non-Markdown file\n' > "$CACHE/skills/nested/data.txt"
printf 'primary: opus\nalt: sonnet\nunrelated: keep-this-line\n' > "$TMP/expected-review.md"

if materialize_claude_reviewer_lanes "$CACHE" >"$TMP/materialize.out" 2>&1; then
  t_ok "nested Markdown lanes materialize"
else
  t_no "materialization failed: $(cat "$TMP/materialize.out")"
fi
if cmp -s "$TMP/expected-review.md" "$CACHE/skills/nested/review.md"; then
  t_ok "both lane models are exact and unrelated Markdown is preserved"
else
  t_no "nested Markdown differs from expected concrete lanes"
fi
if [ "$(cat "$CACHE/shared/includes/guide.md")" = 'Use sonnet and opus.' ] && \
   [ "$(cat "$CACHE/rules/rule.md")" = 'opus' ]; then
  t_ok "shared includes and rules materialize recursively"
else
  t_no "shared includes or rules retained abstract lanes"
fi
if [ "$(cat "$CACHE/skills/nested/data.txt")" = 'review-alt in a non-Markdown file' ]; then
  t_ok "non-Markdown files retain their original bytes"
else
  t_no "materialization changed a non-Markdown file"
fi
# Validation scans the whole cache, including non-Markdown files. Remove the
# deliberately abstract data fixture before checking a fully concrete cache.
rm "$CACHE/skills/nested/data.txt"
if validate_claude_reviewer_lanes "$CACHE" >"$TMP/validate.out" 2>&1; then
  t_ok "concrete cache validates"
else
  t_no "concrete cache rejected: $(cat "$TMP/validate.out")"
fi

printf 'review-alt remains\n' > "$CACHE/skills/nested/residual.md"
if validate_claude_reviewer_lanes "$CACHE" >"$TMP/residual.out" 2>&1; then
  t_no "validation accepted a residual abstract lane"
elif grep -q 'residual.md' "$TMP/residual.out" && grep -q 'review-alt' "$TMP/residual.out"; then
  t_ok "validation rejects and names the residual lane and file"
else
  t_no "residual lane rejected without naming its file and token"
fi

MISSING="$TMP/missing"
mkdir -p "$MISSING/skills" "$MISSING/rules"
if materialize_claude_reviewer_lanes "$MISSING" >"$TMP/missing-materialize.out" 2>&1; then
  t_no "materialization accepted a missing required directory"
elif grep -q "$MISSING/shared/includes" "$TMP/missing-materialize.out"; then
  t_ok "materialization reports the missing required directory"
else
  t_no "materialization failed without naming the missing directory"
fi
if validate_claude_reviewer_lanes "$MISSING" >"$TMP/missing-validate.out" 2>&1; then
  t_no "validation accepted a missing required directory"
elif grep -q "$MISSING/shared" "$TMP/missing-validate.out"; then
  t_ok "validation reports the missing required directory"
else
  t_no "validation failed without naming the missing directory"
fi

# A failing rewrite must propagate failure and leave the fixture readable.
FAILBIN="$TMP/failbin"
mkdir -p "$FAILBIN"
printf '#!/bin/sh\necho "injected perl failure" >&2\nexit 43\n' > "$FAILBIN/perl"
chmod +x "$FAILBIN/perl"
printf 'review-primary is untouched on failure\n' > "$CACHE/skills/nested/failing.md"
if ( PATH="$FAILBIN:$PATH"; materialize_claude_reviewer_lanes "$CACHE" ) >"$TMP/perl-fail.out" 2>&1; then
  t_no "materialization swallowed a Perl rewrite failure"
elif [ "$(cat "$CACHE/skills/nested/failing.md")" = 'review-primary is untouched on failure' ] && \
     grep -q 'injected perl failure' "$TMP/perl-fail.out"; then
  t_ok "Perl failure propagates without damaging the Markdown fixture"
else
  t_no "Perl failure was not reported or changed the fixture"
fi

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

printf '  --- install reviewer lanes: PASS=%s FAIL=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
