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
#   * One environment change, and only for a shell started with neither LC_ALL nor LANG: sourcing
#     exports LANG=C (see "A locale for a shell started with none" below). Its libc children already ran
#     in C; Homebrew bash, which had taken the macOS locale, now runs in C like /bin/bash 3.2. A caller's
#     own LC_ALL or LANG is never touched, and a caller's LC_CTYPE still outranks the added LANG.
#   * Status convention: 0 = yes / found, 1 = no / unknown / unavailable, 2 = usage error.
#     The runners (zms_run_*) have their own, documented at zms_run_codex.
#
# Test seams (also honoured by detection, not only by invocation — see zms_codex_bin):
#   ZUVO_CODEX_BIN, ZUVO_CLAUDE_BIN   pin the client; a NON-EMPTY value is final
#   ZUVO_CODEX_APP_BIN                the app-bundle fallback (unset = the default path, empty = off)
#   ZUVO_CODEX_VERSION_TIMEOUT        seconds allowed for `codex --version` (default 15, also when
#                                     non-numeric or zero — `timeout 0` means NO limit); without GNU
#                                     timeout the probe is not run at all
#   ZUVO_TIMEOUT_GRACE                seconds between TERM and KILL when a runner's budget ends or the
#                                     runner is interrupted (default 15 — the driver's — whenever it is
#                                     not all digits; at least 1, because `timeout -k 0` never KILLs;
#                                     at most 3600, and capped BEFORE any arithmetic, so no length of
#                                     digits can wrap around)
#
# Consumers find this file sibling-first: <dir>/lib/model-subprocess.sh → <dir>/model-subprocess.sh
# → (model-run in a checkout) <repo>/scripts/lib/ → $HOME/.zuvo/model-subprocess.sh (where install.sh
# ships it) — one `zms-locate` block, byte-identical in each consumer, since a script cannot call a
# function from a library it has not found yet.

# Where this file lives, made absolute with parameter expansion only — no dirname, no cd, no fork.
_zms_src="${BASH_SOURCE[0]:-$0}"
case "$_zms_src" in */*) ;; *) _zms_src="./$_zms_src" ;; esac
case "$_zms_src" in /*) ;; *) _zms_src="${PWD:-.}/$_zms_src" ;; esac
_ZMS_LIB_DIR="${_zms_src%/*}"
_ZMS_LIB_DIR="${_ZMS_LIB_DIR%/.}"
unset _zms_src
_ZMS_CODEX_APP_DEFAULT="/Applications/Codex.app/Contents/Resources/codex"

# ── A locale for a shell started with none — the one thing sourcing this file DOES to its caller ──
#
# A shell started with neither LC_ALL nor LANG (env -i, launchd, cron — the suites run the driver, the
# router, model-run and install.sh's builds exactly so) has no NAME for most locale categories. Homebrew's
# bash on macOS is linked with GNU libintl, and every time bash resets its locale (after a `LC_ALL=C cmd`
# temporary assignment, or when a function's `local LC_ALL=C` goes out of scope) it sets every category
# from LANG and then the ones with a variable of their own; for a category with no variable libintl asks
# CoreFoundation for the user's preferred languages. In a forked subshell — `$(...)`, a pipeline element —
# CoreFoundation is not fork-safe, and now and then EVERY such subshell of one process dies of SIGSEGV
# (status 139; a bash-*.ips crash report in libintl_setlocale -> CFLocaleCopyPreferredLanguages). Seen as:
# the Antigravity build refusing all 48 agents with "zrl_frontmatter_model returned an unexpected status
# (139)" (1 run in 16), and the installed driver ending a blind audit with status 2 and no output.
# LC_CTYPE alone names one category, so it does not stop that lookup for the others; LC_ALL or LANG names
# them all. Exporting LANG=C gives libintl a name for every category, so it never asks CoreFoundation.
# What that changes: libc programs (awk, sed, sort) already ran in C with no variable, so for them
# nothing; Homebrew bash itself had taken the CoreFoundation locale (in `env -i` its ${#x} counts UTF-8
# characters) and now runs in C, as /bin/bash 3.2 (no libintl) always did. A caller's own LC_ALL or LANG is
# never touched, and a caller's LC_CTYPE still outranks the LANG added beside it. Here, because every one
# of those entry points sources this file first: the driver, the router, the preflight and model-run
# directly, install.sh and the builds through reviewer-lanes.sh.
if [ -z "${LC_ALL:-}${LANG:-}" ]; then
  LANG=C
  export LANG
fi

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

# zms_route_same_vendor <client> <platform> — status 0 when a routed reviewer's <client> (codex|claude) is
# the WRITER's own vendor: the route's <platform>, or the host vendor detected independently here
# (CLAUDECODE=1 → claude, zms_is_codex_host → codex), which catches a router that lies about platform=.
# `ok` on a Claude/Codex route promises the OTHER vendor. Prints the detected host vendor (empty when
# none) either way, for the caller's diagnostic. The preflight and model-run both refuse on status 0.
zms_route_same_vendor() {
  local client="${1:-}" platform="${2:-}" host=""
  if [ "${CLAUDECODE:-}" = 1 ]; then host=claude; elif zms_is_codex_host; then host=codex; fi
  printf '%s\n' "$host"
  [ -n "$client" ] || return 1
  [ "$client" = "$platform" ] || [ "$client" = "$host" ]
}

# zms_codex_host_model — print the Codex host's model: CODEX_MODEL, else the TOP-LEVEL `model =`
# of ${CODEX_HOME:-$HOME/.codex}/config.toml. Status 1 (nothing printed) when unknown.
#
# Only the top level counts: reading stops at the first `[table]` header, because a
# `[profiles.x] model =` is not the active model and mistaking it for one re-enables self-review.
# The FIRST top-level model= decides, even when it is empty. Its value is read as TOML writes it:
# up to a '#', surrounding blanks (a CR included) trimmed, then ONE pair of matching quotes — "…" or
# a '…' literal string — stripped. The driver's old sed kept a literal string's quotes ("'gpt-5'")
# and a bare value's trailing blanks ("gpt-6 "); it delegates here now. Pure bash: works without sed.
zms_codex_host_model() {
  if [ -n "${CODEX_MODEL:-}" ]; then printf '%s\n' "$CODEX_MODEL"; return 0; fi
  local cfg line v
  local hdr='^[[:space:]]*\['
  local key='^[[:space:]]*model[[:space:]]*=(.*)$'
  if [ -n "${CODEX_HOME:-}" ]; then cfg="$CODEX_HOME/config.toml"
  elif [ -n "${HOME:-}" ]; then cfg="$HOME/.codex/config.toml"
  else return 1; fi
  [ -f "$cfg" ] && [ -r "$cfg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    [[ $line =~ $hdr ]] && return 1
    [[ $line =~ $key ]] || continue
    v="${BASH_REMATCH[1]%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    case "$v" in \"*\"|\'*\') v="${v:1:${#v}-2}" ;; esac
    [ -n "$v" ] || return 1
    printf '%s\n' "$v"
    return 0
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

# ── Ids and the router's six-key answer ──────────────────────────────────────
# One definition for every consumer: the router, model-run and the preflight source this file, and
# scripts/lib/reviewer-lanes.sh (the build scripts' lane grammar) sources it from beside itself. Four
# hand-restated copies of the charset used to live in those files.

# The id alphabet, spelled out letter by letter: a bracket RANGE follows the locale's collation in bash
# 3.2, so a UTF-8 and a C locale would give different verdicts.
ZMS_ID_ALNUM='abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789'

# zms_is_model_id <value> — status 0 when <value> is ONE reviewer id: [A-Za-z0-9][A-Za-z0-9._:-]*. No
# blank, quote, glob character, `$`, backtick, `/`, `=`, bracket or line break — it is printed into the
# route contract, matched as a literal `case` pattern and handed to a CLI.
zms_is_model_id() {
  case "${1:-}" in
    ""|[!$ZMS_ID_ALNUM]*|*[!$ZMS_ID_ALNUM._:-]*) return 1 ;;
  esac
  return 0
}

# zms_is_writer_id <value> — status 0 when <value> is a WRITER id: a reviewer id optionally followed by
# ONE trailing context suffix of letters and digits in brackets, the way Claude Code reports its model
# (claude-opus-<version>[1m], opus[1m]). Any other bracket — unbalanced (`opus[`), empty (`opus[]`),
# embedded (`op[1m]us`), repeated (`opus[1m][2m]`) — fails.
zms_is_writer_id() {
  local v="${1:-}" base sfx inner
  base="${v%%\[*}"                     # everything before the FIRST `[`
  sfx="${v#"$base"}"                   # empty, or `[` and all that follows it
  zms_is_model_id "$base" || return 1
  [ -n "$sfx" ] || return 0
  case "$sfx" in \[*\]) ;; *) return 1 ;; esac
  inner="${sfx#\[}"; inner="${inner%\]}"
  case "$inner" in ""|*[!$ZMS_ID_ALNUM]*) return 1 ;; esac
  return 0
}

# zms_route_contract_ok <file> — status 0 when <file> holds the router's six-key answer in the strict
# shape of shared/includes/env-compat.md, judged on its BYTES (a shell variable would drop NULs and
# trailing blank lines): no NUL, a final newline, exactly six lines, each `key=value` with a lowercase
# key and a NON-EMPTY value, printable ASCII only (a CR or any control / non-ASCII byte fails), and each
# of the six keys exactly once. Status 1 otherwise, with the reasons printed on stdout as one line
# (`got N lines, per-key counts off: writer_lane=0, …`) for the caller's own diagnostic. Only the shape
# is judged here; what each value may be is zms_route_values_ok's (below).
zms_route_contract_ok() {
  local f="${1:-}" why="" n=0 extra=""
  if [ -z "$f" ] || [ ! -f "$f" ] || [ ! -r "$f" ]; then
    printf 'the answer file cannot be read\n'; return 1
  fi
  if ! LC_ALL=C tr -d '\000' < "$f" | cmp -s - "$f"; then why="a NUL byte"; fi
  if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then why="${why:+$why, }no final newline"; fi
  extra="$(LC_ALL=C awk '
    { n++; if ($0 ~ /[^ -~]/) np = 1
      k = $0; sub(/=.*/, "", k)
      if ($0 !~ /^[a-z_]+=/) bad = bad (bad == "" ? "" : ", ") "line " n " is not key=value"
      else if ($0 !~ /^[a-z_]+=./) empty = empty (empty == "" ? "" : ", ") k
      c[k]++ }
    END { m = split("platform writer_model writer_lane reviewer_lane reviewer_model routing_status", K, " ")
          for (i = 1; i <= m; i++) if (c[K[i]] != 1) off = off (off == "" ? "" : ", ") K[i] "=" (c[K[i]] + 0)
          r = "got " (n + 0) " lines"
          if (off != "") r = r ", per-key counts off: " off
          if (empty != "") r = r ", empty value: " empty
          if (bad != "") r = r ", " bad
          if (np) r = r ", a non-printable byte (CR or control char) was found"
          print r
          exit (n != 6 || off != "" || empty != "" || bad != "" || np) }' "$f")" || n=1
  if [ "$n" -ne 0 ] || [ -n "$why" ]; then
    printf '%s\n' "$extra${why:+, $why}"
    return 1
  fi
}

# zms_route_values_ok <platform> <writer_model> <writer_lane> <reviewer_lane> <reviewer_model>
#                     <routing_status> — status 0 when every VALUE of the router's six-key answer is in its
# own shape: the router's enums, reviewer_model a reviewer id (zms_is_model_id), writer_model a writer id
# (zms_is_writer_id). zms_route_contract_ok judges the answer's shape; this judges what each value may be.
# The ONE value check for everything that consumes the contract (zuvo-home/model-run, which acts on it,
# and reviewer-preflight.sh, which reports on it): two validators that accepted different answers meant a
# preflight could call a route good that model-run then refused as malformed.
zms_route_values_ok() {
  case "${1:-}" in claude|codex|cursor|antigravity|kimi|unknown) ;; *) return 1 ;; esac
  case "${3:-}" in small|strong_alt|strong_primary|unknown) ;; *) return 1 ;; esac
  case "${4:-}" in cross-vendor|review-primary|review-alt|same-model-fallback) ;; *) return 1 ;; esac
  case "${6:-}" in ok|cross-vendor-unavailable|in-family-fallback|unknown-writer-model|same-model-fallback|routing-failed) ;; *) return 1 ;; esac
  zms_is_model_id "${5:-}" && zms_is_writer_id "${2:-}"
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
# The driver's is_auth_failure_output delegates here. Same verdicts as the copy it used to carry,
# with one deliberate difference: the pattern and the path reach grep as `-e … --`, so a relative
# path starting with '-' is read as a FILE. The old copy let grep parse it as options (both BSD and
# GNU grep permute), which turned a real stub into "not a stub" plus an error on stderr.
# The guard is BYTES for a string too: `${#src}` counts CHARACTERS in a UTF-8 locale, so a 763-byte
# review of 263 characters that mentioned "unauthorized" was dropped as an auth stub. LC_ALL=C is
# local to this function — the caller's locale is back when it returns — and changes nothing else:
# the tokens are ASCII, and a file was always measured by `wc -c`.
zms_is_auth_stub() {
  local LC_ALL=C
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
# Bounded by ZUVO_CODEX_VERSION_TIMEOUT (non-numeric or zero → 15): a CLI that hangs on --version must
# not hang the review it was only asked to vouch for. Zero is not "no budget" here: GNU `timeout 0`
# DISABLES the limit, so 0 (or 000) passed the digits check and ran exactly the unbounded probe the
# budget exists to prevent. Leading zeros go first (not octal), as with ZUVO_TIMEOUT_GRACE. With no
# GNU timeout at all the CLI is NOT run — an unbounded probe is exactly that hang — and the version
# counts as unreadable (one WARN says why). The driver never reaches this case: it exits at startup
# without timeout. The exit status is deliberately not the verdict — the driver never used it either;
# only a parsable version counts.
_zms_codex_version() {
  local bin to out="" secs="${ZUVO_CODEX_VERSION_TIMEOUT:-15}"
  local vre='[0-9]+\.[0-9]+'
  case "$secs" in ''|*[!0-9]*) secs=15 ;; esac
  secs="${secs#"${secs%%[!0]*}"}"
  [ -n "$secs" ] || secs=15
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
# a CLI whose --version answers, or an id outside the guarded families. (The driver's own copy, gone
# since it delegates here, said "set VAR to force"; nothing ever honoured that.)
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

# ── Isolated runners ──────────────────────────────────────────────────────────
#
# Access modes. The none/read flag sets were decided by live probes (2026-09-25, codex-cli 0.156.1,
# Claude Code 2.1.282; transcripts zuvo/proofs/probe-{1,1a,2,3,6}-*-2026-09-25.txt):
#   none   no file access — blind audit, canaries. The client sees the prompt and nothing else.
#          codex:  neutral cwd, isolated CODEX_HOME, read-only sandbox, shell tools AND view_image
#                  disabled. P6: read-only alone is not enough — it confines WRITES, not reads; the
#                  model simply ran `cat` on the planted absolute path. P1a: with the shell gone the
#                  model reached for view_image on that path (it failed only because it was text).
#          claude: neutral cwd, --tools "" --safe-mode, strict EMPTY MCP config, no session (P2).
#   read   read files under a root — test-audit batches.
#          --read-root is ENFORCED for claude and only ADVISORY for codex. Do not read it as a
#          boundary for codex: it is validated, then never handed to the client.
#          codex:  as none, but the shell tool stays, so the prompt can name ABSOLUTE paths; view_image
#                  stays disabled — reads go through the shell, and the image viewer is one more read
#                  primitive (the one P1a saw the model reach for). The read-only sandbox blocks
#                  WRITES, not reads: in P6 the model `cat`-ed a planted file outside any root. What
#                  keeps codex to the root is the prompt, nothing else.
#          claude: --tools Read,Grep,Glob --add-dir <root> --safe-mode --permission-prompts none —
#                  the root was read, a file outside it was not, and nothing hung (P3).
#   agent  the adversarial lanes' benchmarked flags, byte for byte what adversarial-review.sh ran
#          before it delegated here: codex danger-full-access + approval never, run from its own
#          CODEX_HOME dir; claude from the CALLER's cwd with --dangerously-skip-permissions and a
#          strict empty MCP config. Hardening them is a separate change, not a side effect of this one.

# _zms_err <function> <message> — one diagnostic line on stderr.
_zms_err() { echo "model-subprocess: $1: $2" >&2; }

# _zms_toml_safe <value...> — true when no value carries a quote, a backslash or ANY control
# character. model / effort are written INTO config.toml: a quote or a line break would let a model id
# rewrite the sandbox line; a tab, CR or ESC there is invalid TOML (the client rejects its own config)
# or an escape sequence replayed into every log and terminal that prints the id.
_zms_toml_safe() {
  local v
  for v in "$@"; do
    case "$v" in *'"'*|*\\*|*[[:cntrl:]]*) return 1 ;; esac
  done
}

# zms_codex_home <dir> <model> <effort> <sandbox> — build an isolated CODEX_HOME in <dir>: mode 700;
# auth.json copied from ${CODEX_HOME:-$HOME/.codex} WHEN PRESENT (mode 600; one already in <dir> is
# removed either way, and neither file is ever written through an existing one); a minimal config.toml —
# model, sandbox_mode, approval_policy never, and model_reasoning_effort only when <effort> is
# non-empty (empty leaves the model's own default). Nothing else from the user's config: no MCP
# servers (a required one whose daemon hung took every codex run down, 2026-09-25), no profiles.
# Whether a missing auth.json is fatal is the caller's decision — the runners: yes for none/read
# unless OPENAI_API_KEY is set, no for agent (run_codex never required it; env-key users keep the
# adversarial lane). <dir> may not BE the source CODEX_HOME — by path, or physically (-ef: a symlink
# or another spelling of it): building there would chmod the user's own Codex home and rm its
# auth.json and config.toml, the account login and the user's whole config. Refused as a usage error —
# checked again once <dir> exists, before anything in it is touched: a spelling through a component
# that does not exist yet ($CODEX_HOME/new/..) is not -ef the source until mkdir creates it, and then
# it IS the source (the empty component mkdir made is all that is left behind).
# Status: 0 built, 1 filesystem error, 2 usage error.
zms_codex_home() {
  local dir="${1:-}" model="${2:-}" effort="${3:-}" sandbox="${4:-}"
  local srch="${CODEX_HOME:-${HOME:-}/.codex}" d s
  local src="$srch/auth.json"
  if [ -z "$dir" ] || [ -z "$model" ]; then
    _zms_err zms_codex_home "usage: <dir> <model> <effort> <sandbox>"; return 2
  fi
  d="$dir"; s="$srch"
  while case "$d" in ?*/) true ;; *) false ;; esac; do d="${d%/}"; done
  while case "$s" in ?*/) true ;; *) false ;; esac; do s="${s%/}"; done
  if [ "$d" = "$s" ] || [ "$dir" -ef "$srch" ]; then
    _zms_err zms_codex_home "refusing $dir: it is the source CODEX_HOME ($srch) — building there would delete its auth.json and config.toml"
    return 2
  fi
  case "$sandbox" in
    read-only|workspace-write|danger-full-access) ;;
    *) _zms_err zms_codex_home "unknown sandbox: $sandbox"; return 2 ;;
  esac
  if ! _zms_toml_safe "$model" "$effort"; then
    _zms_err zms_codex_home "model/effort may not contain quotes, backslashes or control characters"; return 2
  fi
  (
    umask 077
    mkdir -p "$dir" || exit 1
    if [ "$dir" -ef "$srch" ]; then
      _zms_err zms_codex_home "refusing $dir: it is the source CODEX_HOME ($srch) — building there would delete its auth.json and config.toml"
      exit 2
    fi
    # chmod as well: mkdir -p leaves an EXISTING directory's mode as it was.
    chmod 700 "$dir" || exit 1
    # rm both first, always: writing onto an EXISTING file keeps that file's mode (umask shapes only
    # files that get created) and writes THROUGH a symlink — the sandbox config or the account token
    # would land in whatever file the link named. And a stale auth.json must not outlive a source that
    # has none: the client would run on an account the caller no longer has. chmod after the copy:
    # it is 600 whatever the source's mode.
    rm -f "$dir/auth.json" "$dir/config.toml" || exit 1
    if [ -f "$src" ]; then
      { cp "$src" "$dir/auth.json" && chmod 600 "$dir/auth.json"; } || exit 1
    fi
    {
      printf 'model = "%s"\n' "$model"
      printf 'sandbox_mode = "%s"\n' "$sandbox"
      printf 'approval_policy = "never"\n'
      if [ -n "$effort" ]; then printf 'model_reasoning_effort = "%s"\n' "$effort"; fi
    } > "$dir/config.toml" || exit 1
  )
}

# _zms_reap <pid> <grace> [waited] — take a runner's client down for good; the EXIT trap's job, on
# EVERY exit path, a clean one included. <pid> is the GNU timeout wrapping the client. timeout leads a
# process group (setpgid, unless --foreground) holding the client and all it started, and that group
# outlives timeout for as long as any member lives — a detached grandchild that ignores TERM, say. So
# timeout's own exit proves nothing, and the KILL is never skipped: TERM timeout and its group (timeout
# passes it on and, given -k, arms its own KILL), allow <grace> seconds while either lives, then KILL
# the group, timeout, and every descendant still attached by parent pid (read just before, and only
# while timeout lives: an orphan has left that tree, not the group). One `kill` per target, errors
# ignored, so a target already gone cannot cut the rest short. Every wait is bounded; `kill -0`
# decides because bash reaps an exited background child by itself. [waited] = the runner has already
# waited for <pid>, which the system may then reuse: only the group is still a target — a group id
# cannot be reused while the group has a member, which is exactly when it matters.
_zms_reap() {
  local pid="$1" grace="$2" i=0 t tree="" own="$1"
  [ -z "${3:-}" ] || own=""
  # shellcheck disable=SC2086  # one pid per word, by design ($own is empty or one pid)
  for t in $own "-$pid"; do kill -TERM -- "$t" 2>/dev/null; done
  while [ "$i" -lt "$grace" ] && _zms_live "$pid" "$own"; do sleep 1; i=$((i + 1)); done
  if [ -n "$own" ] && kill -0 "$own" 2>/dev/null; then
    tree="$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v r="$pid" '{ k[$2] = k[$2] " " $1 }
      END { q = k[r]; while (q != "") { n = split(q, a, " "); q = ""; for (j = 1; j <= n; j++) { print a[j]; q = q k[a[j]] } } }')"
  fi
  # shellcheck disable=SC2086  # one pid per word, by design
  for t in "-$pid" $own $tree; do kill -KILL -- "$t" 2>/dev/null; done
  i=0
  while [ "$i" -lt 5 ] && _zms_live "$pid" "$own"; do sleep 1; i=$((i + 1)); done
  return 0
}

# _zms_live <pid> <own> — true while process group <pid> has a member, or while <own> (the pid itself,
# empty once it has been waited for) is alive.
_zms_live() {
  kill -0 -- "-$1" 2>/dev/null && return 0
  [ -n "$2" ] && kill -0 "$2" 2>/dev/null
}

# zms_run_codex / zms_run_claude — run ONE prompt through the client, isolated per --access.
#   --model <id> --access none|read|agent --prompt-file <f> --timeout <s>
#   [--effort <e>] [--read-root <dir>] (read only, required there: ENFORCED for claude through
#   --add-dir, ADVISORY for codex — validated, never handed to it; see Access modes) [--stderr-file <f>]
# The prompt goes to the client on stdin; the answer is the runner's stdout. The client's stderr goes
# to --stderr-file when given, else to the runner's stderr — never to stdout. The file is created /
# truncated only as the client starts: a runner that cannot start leaves it as it was.
# Relative paths are resolved against the caller's cwd (the client runs elsewhere) — a relative
# TMPDIR too, which the client then inherits absolute; --read-root is also made PHYSICAL, so a
# symlinked root reaches --add-dir as the directory that was validated. The budget is
# `timeout -k <ZUVO_TIMEOUT_GRACE> <s>`.
# Status: the client's own (0 = it answered), 124 timed out, 137 GNU timeout had to escalate to KILL
# (the client ignored TERM past the budget) — callers should treat it like 124, as the adversarial
# driver's dispatch_provider does (it remaps 137 only when the budget was really used up: an EARLY 137
# is an OOM or an outside kill -9, not a timeout), 127 client not available, 2 could not start (usage
# error, no GNU timeout, codex none/read with neither auth.json nor OPENAI_API_KEY, unwritable
# --stderr-file, a --stderr-file that is the --prompt-file by path, symlink or hardlink [opening it
# would truncate the prompt, so it is refused before it is opened], a --read-root that cannot be
# entered), 143/130/129 the runner was interrupted (TERM/INT/HUP). However the client ends, whatever
# is left of it — its process group included — is TERMed, KILLed after the grace, and the temp dir
# removed. The runner reports ITS failures on stderr; a client's failure is reported by the client
# (its stderr) and the status, nothing is added.
zms_run_codex() { _zms_run codex "$@"; }
zms_run_claude() { _zms_run claude "$@"; }

# The body is a SUBSHELL: its EXIT/INT/TERM/HUP trap — take the client down, delete the temp dir
# with the auth.json copy — can never replace a caller's trap, and cd / umask / shell options stay
# local. The client runs in the background + `wait` because bash defers a trap while a FOREGROUND
# child runs: a TERM would otherwise sit out the whole budget with the auth copy on disk.
# The steps live in the _zms_run_* helpers below, and they run INSIDE this one subshell — never call
# them from anywhere else: they share its variables (none is `local`), their `exit` ends the runner,
# and their cd / exec / export are the subshell's. The order is the contract: every argument is
# validated before anything is created, and the trap is set before the temp dir exists.
_zms_run() (
  set +e
  client="$1" fn="zms_run_$1"; shift
  model="" effort="" access="" prompt="" secs="" root="" errf="" tmp="" child="" waited="" home="" cwd=""
  _zms_run_args "$@"
  _zms_run_validate
  # The EXIT trap ignores further signals first: a second Ctrl-C during the reap must not skip the
  # rm -rf of the temp dir that holds the auth.json copy.
  trap 'trap "" INT TERM HUP; [ -z "$child" ] || _zms_reap "$child" "$grace" "$waited"; [ -z "$tmp" ] || rm -rf "$tmp"' EXIT
  trap 'exit 143' TERM
  trap 'exit 130' INT
  trap 'exit 129' HUP
  _zms_run_setup
  _zms_run_exec
)

# _zms_run_args <runner args...> — the runner's arguments into model / effort / access / prompt /
# secs / root / errf. An unknown flag or a flag without a value is a usage error (exit 2).
_zms_run_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --model|--effort|--access|--prompt-file|--timeout|--read-root|--stderr-file) ;;
      *) _zms_err "$fn" "unknown argument: $1"; exit 2 ;;
    esac
    if [ $# -lt 2 ]; then _zms_err "$fn" "$1 needs a value"; exit 2; fi
    case "$1" in
      --model) model="$2" ;;          --effort) effort="$2" ;;     --access) access="$2" ;;
      --prompt-file) prompt="$2" ;;   --timeout) secs="$2" ;;      --read-root) root="$2" ;;
      --stderr-file) errf="$2" ;;
    esac
    shift 2
  done
}

# _zms_run_validate — everything is checked before anything is created or run. Leaves root, prompt and
# errf absolute (root physical too), to = GNU timeout, bin = the client, grace = the KILL grace.
_zms_run_validate() {
  if [ -z "$model" ]; then _zms_err "$fn" "--model is required"; exit 2; fi
  if ! _zms_toml_safe "$model" "$effort"; then
    _zms_err "$fn" "--model/--effort may not contain quotes, backslashes or control characters"; exit 2
  fi
  case "$access" in
    none|agent)
      if [ -n "$root" ]; then _zms_err "$fn" "--read-root is only valid with --access read"; exit 2; fi ;;
    read)
      if [ -z "$root" ]; then _zms_err "$fn" "--access read needs --read-root <dir>"; exit 2; fi
      if [ ! -d "$root" ]; then _zms_err "$fn" "--read-root is not a directory: $root"; exit 2; fi
      # Absolute AND physical, resolved from the caller's cwd: --add-dir is the boundary claude
      # enforces, and handed a symlink it is only a name — whatever the link points at by the time
      # the client resolves it. CDPATH must not redirect a relative root.
      if ! abs="$(CDPATH='' cd -P -- "$root" 2>/dev/null && pwd -P)" || [ -z "$abs" ]; then
        _zms_err "$fn" "--read-root cannot be entered: $root"; exit 2
      fi
      root="$abs" ;;
    *) _zms_err "$fn" "--access must be none, read or agent (got '${access}')"; exit 2 ;;
  esac
  case "$secs" in
    ''|0*|*[!0-9]*) _zms_err "$fn" "--timeout must be a positive whole number of seconds"; exit 2 ;;
  esac
  case "$prompt" in ''|/*) ;; *) prompt="$PWD/$prompt" ;; esac
  if [ -z "$prompt" ] || [ ! -f "$prompt" ] || [ ! -r "$prompt" ]; then
    _zms_err "$fn" "--prompt-file must name a readable file"; exit 2
  fi
  # Opening --stderr-file truncates it: named as the prompt — same path, symlink or hardlink (-ef:
  # same device and inode) — it emptied the prompt before the client read a byte.
  case "$errf" in ''|/*) ;; *) errf="$PWD/$errf" ;; esac
  if [ -n "$errf" ] && { [ "$errf" = "$prompt" ] || [ "$errf" -ef "$prompt" ]; }; then
    _zms_err "$fn" "--stderr-file must differ from --prompt-file (opening it would truncate the prompt)"; exit 2
  fi
  if ! to="$(_zms_timeout_bin)"; then
    echo "model-subprocess: GNU timeout required (timeout or gtimeout on PATH; macOS: brew install coreutils)" >&2
    exit 2
  fi
  if ! bin="$("zms_${client}_bin")"; then
    if [ "$client" = codex ]; then where="ZUVO_CODEX_BIN, PATH, Codex.app"; else where="ZUVO_CLAUDE_BIN, PATH"; fi
    _zms_err "$fn" "$client CLI not available (looked at: $where)"
    exit 127
  fi
  grace="${ZUVO_TIMEOUT_GRACE:-15}"
  case "$grace" in *[!0-9]*) grace=15 ;; esac
  # Leading zeros go first (not octal, and not length). Then the cap is decided on the LENGTH before
  # any number is compared: 30 digits reached shell arithmetic whole and wrapped to a negative value.
  # At least 1: `timeout -k 0` disables the KILL, so a client ignoring TERM outlived its budget for
  # ever. At most 3600: past that the "grace" is a runner sitting out an hour on a stuck client.
  grace="${grace#"${grace%%[!0]*}"}"
  case "$grace" in '') grace=1 ;; ?????*) grace=3600 ;; esac
  [ "$grace" -le 3600 ] || grace=3600
}

# _zms_run_setup — the call's temp dir (tmp; the EXIT trap removes it), then the per-client, per-access
# invocation: the isolated CODEX_HOME (home) or the empty MCP config, the argv (args), the client's cwd.
_zms_run_setup() {
  # A relative TMPDIR is anchored to the caller's cwd BEFORE any cd, and the client gets it that way:
  # it runs elsewhere, and handed `rel-tmp` its TMPDIR named a directory that does not exist there.
  # Still the caller's directory, not the call's temp dir; an unset or absolute TMPDIR is left alone.
  base="${TMPDIR:-/tmp}"
  case "$base" in /*) ;; *) base="$PWD/$base"; export TMPDIR="$base" ;; esac
  if ! tmp="$(mktemp -d "${base%/}/zms.XXXXXX")"; then
    tmp=""; _zms_err "$fn" "cannot create a temp dir under $base"; exit 2
  fi
  # Physical, too, BEFORE any cd: a relative temp path was re-anchored by the cd below — the client got
  # a CODEX_HOME / MCP config it could not find, and the EXIT trap's rm -rf deleted nothing, the
  # auth.json copy included. CDPATH must not redirect the cd.
  if ! abs="$(CDPATH='' cd -P -- "$tmp" && pwd -P)" || [ -z "$abs" ]; then
    _zms_err "$fn" "cannot resolve the temp dir $tmp"; exit 2
  fi
  tmp="$abs"
  cwd="$tmp/cwd"
  if [ "$client" = codex ]; then
    home="$tmp/codex_home_$access"
    sandbox=read-only
    if [ "$access" = agent ]; then sandbox=danger-full-access; fi
    zms_codex_home "$home" "$model" "$effort" "$sandbox" || { _zms_err "$fn" "cannot build an isolated CODEX_HOME"; exit 2; }
    # none/read take the account file — or an API key: the codex CLI reads OPENAI_API_KEY from its
    # environment and needs no auth.json for it. The key stays in the environment, never on disk.
    if [ "$access" != agent ] && [ ! -f "$home/auth.json" ] && [ -z "${OPENAI_API_KEY:-}" ]; then
      _zms_err "$fn" "no auth.json in ${CODEX_HOME:-${HOME:-}/.codex} and no OPENAI_API_KEY — run 'codex login' or export OPENAI_API_KEY (access $access uses no other credentials)"
      exit 2
    fi
    args=(exec --skip-git-repo-check)
    case "$access" in
      none)  args+=(-s read-only --disable shell_tool --disable unified_exec --disable view_image) ;;
      read)  args+=(-s read-only --disable view_image) ;;   # the shell stays; --read-root is advisory
      agent) cwd="$home" ;;   # run_codex: cd "$tmp_home"
    esac
  else
    mcp="$tmp/claude_empty_mcp.json"
    printf '{"mcpServers":{}}' > "$mcp" || { _zms_err "$fn" "cannot write the empty MCP config"; exit 2; }
    args=(--model "$model")
    if [ -n "$effort" ]; then args+=(--effort "$effort"); fi
    args+=(--print --output-format text)
    case "$access" in
      none)  args+=(--tools "" --safe-mode --mcp-config "$mcp" --strict-mcp-config --no-session-persistence) ;;
      read)  args+=(--tools "Read,Grep,Glob" --add-dir "$root" --safe-mode --permission-prompts none
                    --mcp-config "$mcp" --strict-mcp-config --no-session-persistence) ;;
      agent) args+=(--mcp-config "$mcp" --strict-mcp-config --dangerously-skip-permissions); cwd="" ;;
    esac
  fi
  if [ -n "$cwd" ]; then
    { mkdir -p "$cwd" && cd "$cwd"; } || { _zms_err "$fn" "cannot enter $cwd"; exit 2; }
    # `cd` leaves the caller's directory (usually the repo) in OLDPWD, which the client inherits.
    # agent keeps that, exactly as run_codex did; none/read must not hand the repo path over.
    if [ "$access" != agent ]; then export OLDPWD="$cwd"; fi
  fi
}

# _zms_run_exec — open the stderr capture, start the client under GNU timeout in the background, wait,
# and end the runner with the client's status (the EXIT trap then reaps what is left).
_zms_run_exec() {
  # Opened LAST — it creates or truncates the file: a runner that cannot start (rc 2) leaves the
  # caller's capture file as it was. errf is absolute (validation), so the cd above does not move it.
  if [ -n "$errf" ]; then
    { exec 4> "$errf"; } 2>/dev/null || { _zms_err "$fn" "cannot write --stderr-file $errf"; exit 2; }
  else
    exec 4>&2
  fi
  if [ "$client" = codex ]; then
    CODEX_HOME="$home" "$to" -k "$grace" "$secs" "$bin" "${args[@]}" < "$prompt" 2>&4 4>&- &
  else
    "$to" -k "$grace" "$secs" "$bin" "${args[@]}" < "$prompt" 2>&4 4>&- &
  fi
  child=$!
  wait "$child"
  status=$?
  # child stays set: timeout has exited, but its process group can still hold what the client left
  # behind, and the EXIT trap reaps that group on this path too — only the pid itself is done with.
  waited=1
  exit "$status"
}
