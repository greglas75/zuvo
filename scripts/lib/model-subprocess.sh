# shellcheck shell=bash
# model-subprocess.sh — the ONE place zuvo decides how to find a Codex or Claude reviewer CLI and
# which host it is running in. Sourced, never executed; every public function is prefixed `zms_`.
#
# Why it exists: the adversarial driver, the reviewer router and the preflight each carried their
# own copy of this, and the copies disagreed. The driver recognised a Codex host by FOUR signals,
# the router by one; the driver fell back to /Applications/Codex.app, nothing else did; and the
# blind-audit wrapper ran codex against the user's global CODEX_HOME, so it died with the required
# `codesift` MCP daemon when that hung (2026-09-25). One implementation, one answer.
#
# Contract for everything below (tests/hooks/test-model-subprocess.sh pins each point):
#   * bash 3.2 (macOS /bin/bash): no `declare -A`, `mapfile`, `${x,,}`; empty arrays as ${a[@]+…}.
#   * NOTHING external runs at source time — sourcing works with PATH=/nonexistent, which is
#     exactly how the router is exercised. Commands run only when a function is called.
#   * Safe under the caller's `set -euo pipefail`: every environment read has a default, and a
#     non-zero status is always the ANSWER (no / unknown / unavailable), never a crash.
#   * Never changes the caller's shell options or traps.
#   * Status convention: 0 = yes / found, 1 = no / unknown / unavailable, 2 = usage error.
#
# Test seams (also honoured by detection, not only by invocation — see zms_codex_bin):
#   ZUVO_CODEX_BIN, ZUVO_CLAUDE_BIN   pin the client; a NON-EMPTY value is final
#   ZUVO_CODEX_APP_BIN                the app-bundle fallback (unset = the default path, empty = off)
#   ZUVO_CODEX_VERSION_TIMEOUT        seconds allowed for `codex --version` (default 15, also when
#                                     non-numeric); without GNU timeout the probe is not run at all
#
# Consumers find this file sibling-first: <dir>/lib/model-subprocess.sh → <dir>/model-subprocess.sh
# → $HOME/.zuvo/model-subprocess.sh (where install.sh ships it).

# Where this file lives, made absolute with parameter expansion only — no dirname, no cd, no fork.
_zms_src="${BASH_SOURCE[0]:-$0}"
case "$_zms_src" in */*) ;; *) _zms_src="./$_zms_src" ;; esac
case "$_zms_src" in /*) ;; *) _zms_src="${PWD:-.}/$_zms_src" ;; esac
_ZMS_LIB_DIR="${_zms_src%/*}"
_ZMS_LIB_DIR="${_ZMS_LIB_DIR%/.}"
unset _zms_src
_ZMS_CODEX_APP_DEFAULT="/Applications/Codex.app/Contents/Resources/codex"

# ── Host detection ────────────────────────────────────────────────────────────

# zms_is_codex_host — true when running inside Codex CLI or Codex Desktop. Any ONE of the four
# signals the driver has used since 2026-08 is enough; the router used to check only the first,
# so inside Codex Desktop it answered `platform=unknown` and routed a reviewer to the writer's model.
zms_is_codex_host() {
  [ -n "${CODEX_SANDBOX:-}" ] \
    || [ "${CODEX_INTERNAL_ORIGINATOR_OVERRIDE:-}" = "Codex Desktop" ] \
    || [ "${CODEX_SHELL:-}" = "1" ] \
    || [ "${__CFBundleIdentifier:-}" = "com.openai.codex" ]
}

# zms_codex_host_model — print the Codex host's model: CODEX_MODEL, else the TOP-LEVEL `model =`
# of ${CODEX_HOME:-$HOME/.codex}/config.toml. Status 1 (nothing printed) when unknown.
#
# Only the top level counts: reading stops at the first `[table]` header, because a
# `[profiles.x] model =` is not the active model and mistaking it for one re-enables self-review.
# Same expression as the driver's `sed '/^[[:space:]]*\[/q; s/…model…/\1/p' | head -1` (the test
# checks parity line for line), done in bash so it also works where PATH has no sed.
zms_codex_host_model() {
  if [ -n "${CODEX_MODEL:-}" ]; then printf '%s\n' "$CODEX_MODEL"; return 0; fi
  local cfg line
  local hdr='^[[:space:]]*\['
  local key='^[[:space:]]*model[[:space:]]*=[[:space:]]*"?([^"#]*)"?'
  if [ -n "${CODEX_HOME:-}" ]; then cfg="$CODEX_HOME/config.toml"
  elif [ -n "${HOME:-}" ]; then cfg="$HOME/.codex/config.toml"
  else return 1; fi
  [ -f "$cfg" ] && [ -r "$cfg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $hdr ]] && return 1
    if [[ $line =~ $key ]]; then
      # The FIRST top-level model= decides, even when it is empty (the driver's `head -1`).
      [ -n "${BASH_REMATCH[1]}" ] || return 1
      printf '%s\n' "${BASH_REMATCH[1]}"
      return 0
    fi
  done < "$cfg"
  return 1
}

# ── Client resolution ─────────────────────────────────────────────────────────

# _zms_exe <name-or-path> — print the ABSOLUTE path of an executable regular file, or return 1.
# A bare name is looked up on PATH with `type -P` (files only: never a function or an alias). A
# relative path is made absolute because the runners execute clients from a different directory.
# Nothing is ever executed here: availability is decided by PATH lookup and `-f`/`-x` alone.
_zms_exe() {
  local p="${1:-}"
  [ -n "$p" ] || return 1
  case "$p" in */*) ;; *) p="$(type -P "$p")" || return 1 ;; esac
  case "$p" in /*) ;; *) p="${PWD:-.}/$p" ;; esac
  [ -f "$p" ] && [ -x "$p" ] || return 1
  printf '%s\n' "$p"
}

# zms_codex_bin — the codex executable: ZUVO_CODEX_BIN → `codex` on PATH → ZUVO_CODEX_APP_BIN.
# A non-empty ZUVO_CODEX_BIN is FINAL: when it does not resolve, the chain stops there instead of
# falling through to PATH or the app. Without that, an installed Codex.app makes "codex missing"
# impossible to fake, and every hermetic test would silently pick up the real client.
zms_codex_bin() {
  if [ -n "${ZUVO_CODEX_BIN:-}" ]; then
    _zms_exe "$ZUVO_CODEX_BIN" && return 0
    return 1
  fi
  _zms_exe codex && return 0
  _zms_exe "${ZUVO_CODEX_APP_BIN-$_ZMS_CODEX_APP_DEFAULT}"
}

# zms_claude_bin — the claude executable: ZUVO_CLAUDE_BIN (final when non-empty) → `claude` on PATH.
zms_claude_bin() {
  if [ -n "${ZUVO_CLAUDE_BIN:-}" ]; then
    _zms_exe "$ZUVO_CLAUDE_BIN" && return 0
    return 1
  fi
  _zms_exe claude
}

# zms_client_available <client> — codex/claude through their resolvers (seams included); any other
# client (agy, cursor-agent, kimi, …) by PATH lookup. Never runs the client.
zms_client_available() {
  case "${1:-}" in
    "")     echo "model-subprocess: zms_client_available: client name required" >&2; return 2 ;;
    codex)  zms_codex_bin >/dev/null ;;
    claude) zms_claude_bin >/dev/null ;;
    *)      _zms_exe "$1" >/dev/null ;;
  esac
}

# zms_client_for_model <model-id> — which CLI serves a model id: prints `codex` or `claude`,
# status 1 for anything else (Gemini, Kimi, OpenRouter ids, empty).
zms_client_for_model() {
  case "${1:-}" in
    # Open-weight gpt-oss is served through agy / OpenRouter, not through the Codex CLI account.
    gpt-oss*)                       return 1 ;;
    gpt-*|o[0-9]*|codex-*)          printf 'codex\n' ;;
    claude-*|opus*|sonnet*|haiku*)  printf 'claude\n' ;;
    *)                              return 1 ;;
  esac
}

# ── Registry ──────────────────────────────────────────────────────────────────

# zms_source_registry — source shared/includes/model-registry.sh into the caller's shell and set
# ZMS_REGISTRY_FILE to the file loaded. Status 1 (nothing loaded) when no registry is found.
#
# Sibling first: when this file sits at <root>/scripts/lib/ inside a real repo or plugin-cache tree
# (<root>/skills exists), <root>/shared/includes/model-registry.sh wins — so repo tests never pick
# up whatever an older install left in ~/.zuvo. The `skills` check is a guard, not decoration:
# installed flat in ~/.zuvo, a `../..` path would leave the install root for a directory another
# user may be able to create (/Users/Shared is world-writable), and this file is SOURCED.
# shellcheck disable=SC2034  # ZMS_REGISTRY_FILE is this function's output, read by the caller
zms_source_registry() {
  local root="" f=""
  ZMS_REGISTRY_FILE=""
  case "$_ZMS_LIB_DIR" in */scripts/lib) root="${_ZMS_LIB_DIR%/scripts/lib}" ;; esac
  if [ -n "$root" ] && [ -d "$root/skills" ] && [ -f "$root/shared/includes/model-registry.sh" ]; then
    f="$root/shared/includes/model-registry.sh"
  elif [ -n "${HOME:-}" ] && [ -f "$HOME/.zuvo/model-registry.sh" ]; then
    f="$HOME/.zuvo/model-registry.sh"
  else
    return 1
  fi
  # shellcheck source=/dev/null
  . "$f" || return 1
  ZMS_REGISTRY_FILE="$f"
}

# ── Output and CLI guards (lifted from adversarial-review.sh) ────────────────

# zms_is_auth_stub <file-or-string> — true when a provider's "answer" is only an auth error.
# A CLI can exit 0 while printing "Not logged in"; counted as a review, that output made a dead
# reviewer look alive. Length-guarded: a real review that merely discusses login code is > 600 B.
# Same logic as the driver's is_auth_failure_output (the test runs both on the same fixtures), with
# one deliberate difference: the pattern and the path reach grep as `-e … --`, so a relative path
# starting with '-' is read as a FILE. The driver's copy lets grep parse it as options (both BSD and
# GNU grep permute), which turned a real stub into "not a stub" plus an error on stderr.
zms_is_auth_stub() {
  local src="${1:-}" bytes
  local re='not logged in|please run /login|login_required|requires login|invalid_grant|unauthorized|not authenticated'
  if [[ -f "$src" ]]; then
    [[ -s "$src" ]] || return 1
    # 2>/dev/null must precede the input redirection: bash applies redirections left to right, and
    # an unreadable file fails to OPEN before a trailing `2>/dev/null` would ever take effect — that
    # ordering still printed "Permission denied" to the caller's stderr. `|| return 1` covers the
    # same unreadable case: an unreadable file is not a stub either way.
    bytes=$(wc -c 2>/dev/null < "$src") || return 1
    (( bytes > 600 )) && return 1
    grep -qiE -e "$re" -- "$src" 2>/dev/null
  else
    [[ -n "$src" ]] || return 1
    (( ${#src} > 600 )) && return 1
    printf '%s' "$src" | grep -qiE -e "$re"
  fi
}

# _zms_timeout_bin — GNU timeout under either name (macOS has none; Homebrew installs both).
_zms_timeout_bin() {
  _zms_exe timeout || _zms_exe gtimeout
}

# _zms_codex_version — print the codex CLI's `major.minor`, or return 1 when it cannot be read.
# Bounded by ZUVO_CODEX_VERSION_TIMEOUT (non-numeric → 15): a CLI that hangs on --version must not
# hang the review it was only asked to vouch for. With no GNU timeout at all the CLI is NOT run —
# an unbounded probe is exactly that hang — and the version counts as unreadable (one WARN says
# why). The driver never reaches this case: it exits at startup without timeout. The exit status is
# deliberately not the verdict — the driver never used it either; only a parsable version counts.
_zms_codex_version() {
  local bin to out="" secs="${ZUVO_CODEX_VERSION_TIMEOUT:-15}"
  local vre='[0-9]+\.[0-9]+'
  case "$secs" in ''|*[!0-9]*) secs=15 ;; esac
  bin="$(zms_codex_bin)" || return 1
  if ! to="$(_zms_timeout_bin)"; then
    echo "  WARN: GNU timeout not found — skipping codex --version probe (install coreutils for timeout/gtimeout)" >&2
    return 1
  fi
  out="$("$to" -k 2 "$secs" "$bin" --version 2>/dev/null)" || true   # status is not the verdict
  [[ $out =~ $vre ]] || return 1
  printf '%s\n' "${BASH_REMATCH[0]}"
}

# zms_codex_cli_guard <model> [override-var-name] — print a model the local codex CLI can reach.
# <override-var-name> is only NAMED in the WARN: it is the variable the caller read <model> from
# (the driver: ZUVO_MODEL_CODEX_PRIMARY / _ALT). Setting it cannot push a guarded id past this
# check — the guard sees whatever model it is given — so the WARN names the two things that work:
# a CLI whose --version answers, or an id outside the guarded families. (The driver's WARN still
# says "set VAR to force"; nothing ever honoured that. It goes when the driver delegates here.)
#
# A model id the CLI does not know fails as an opaque 400 ("not supported when using Codex with a
# ChatGPT account") that reads like an ACCOUNT problem and is not one (CLI 0.153 vs gpt-6,
# 2026-09-23). Each guarded family downgrades one rung per check: gpt-6 (needs >=0.156) →
# gpt-5.6-sol (needs >=0.144) → gpt-5.5. An unreadable or missing CLI counts as TOO OLD: wrongly
# downgrading a new CLI costs one generation, wrongly keeping a new id costs EVERY review a 400.
# The ladder only descends, so the loop ends on an unguarded id. The CLI is asked for its version
# at most once, and not at all for a model outside the guarded families.
zms_codex_cli_guard() {
  local model="${1:-}" override="${2:-the model variable}"
  local need fallback cv="" probed=0 cv_major cv_minor
  if [ -z "$model" ]; then
    echo "model-subprocess: zms_codex_cli_guard: model required" >&2
    return 2
  fi
  while :; do
    case "$model" in
      gpt-6*)   need=156; fallback="gpt-5.6-sol" ;;
      gpt-5.6*) need=144; fallback="gpt-5.5" ;;
      *)        break ;;
    esac
    if [ "$probed" -eq 0 ]; then cv="$(_zms_codex_version)" || cv=""; probed=1; fi
    if [ -z "$cv" ]; then
      echo "  WARN: cannot parse codex CLI version — falling back to $fallback for safety ($override cannot force $model past this check: make \`codex --version\` answer, or set $override to a model outside gpt-6*/gpt-5.6*)" >&2
      model="$fallback"; continue
    fi
    cv_major="${cv%%.*}"; cv_minor="${cv#*.}"; cv_minor="${cv_minor%%.*}"
    if [ "$cv_major" -eq 0 ] && [ "$cv_minor" -lt "$need" ]; then
      echo "  WARN: codex CLI $cv is too old for $model (needs >=0.$need) — falling back to $fallback. Upgrade: brew upgrade --cask codex" >&2
      model="$fallback"; continue
    fi
    break
  done
  printf '%s' "$model"
}
