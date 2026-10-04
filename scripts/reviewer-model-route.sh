#!/usr/bin/env bash

set -euo pipefail

# NOTE: this file maps a writer to a reviewer. Claude and Codex hosts route CROSS-VENDOR (a user
# decision, 2026-09-25): a Claude writer is reviewed by Codex (the registry's ZUVO_MODEL_CODEX_PRIMARY),
# a Codex writer by Opus through `claude -p` (ZUVO_MODEL_CLAUDE_REVIEWER_OPUS; probe P5,
# zuvo/proofs/probe-5-claude-from-codex-2026-09-25.txt, proved a nested `claude -p` answers from inside
# `codex exec`). The reviewer is `reviewer_lane=cross-vendor`; which CLI serves it follows from the id
# (zms_client_for_model), and it is routed only when that CLI is installed (zms_client_available —
# looked up, never run). Otherwise, and always with --fallback, the IN-FAMILY row (Claude opus<->sonnet,
# the registry's Codex primary<->review-alt pair) is emitted under a status that says so. The writer is
# never guessed: an unset CLAUDE_MODEL is `unknown`, not sonnet (the old default made an Opus session
# "review" itself with Opus and report ok).
#
# Every Claude/Codex reviewer id is READ from shared/includes/model-registry.sh (zms_source_registry) —
# never restated here (01c1727e had to copy the GPT-6 ids into this table by hand). No registry on a
# Claude/Codex host: the fail-closed sentinel, since no reviewer could be named. Cursor, Antigravity
# (Antigravity-IDE ids, a different namespace from agy's display names) and Kimi keep their own tables
# and need no registry; their answers are unchanged by this (X7), --fallback included.
# The ONE file sourced directly is scripts/lib/model-subprocess.sh (host detection, client lookup,
# registry lookup) — found next to this file or in ~/.zuvo; without it the router prints the sentinel.

PLATFORM_OVERRIDE=""
WRITER_OVERRIDE=""
FALLBACK=0

# Builtins only (printf, not cat): a usage error must still be reported under PATH=/nonexistent.
usage() {
  printf '%s\n' \
    'Usage: reviewer-model-route.sh [--fallback] [--platform <name>] [--writer-model <model>]' \
    '' \
    'Emits a deterministic reviewer routing contract as KEY=VALUE lines:' \
    '  platform' '  writer_model' '  writer_lane' '  reviewer_lane' '  reviewer_model' '  routing_status' \
    '' \
    '--fallback   on a Claude or Codex host, answer with the IN-FAMILY reviewer' \
    '             (routing_status=in-family-fallback; unknown-writer-model when the writer is unknown)' \
    '             for a caller whose cross-vendor reviewer could not run. Runtime policy: allowed' \
    '             without the override gate. Other hosts answer as they do without it.' \
    '' \
    '--platform / --writer-model are for tests and smoke validation only and need' \
    'ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1. Runtime callers rely on environment detection.'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform|--writer-model)
      # A value flag with no value is a usage error: given as the LAST argument (`shift 2` with one
      # argument left used to fail under `set -e` and end the script with status 1 and no word on any
      # stream — backlog B-20260928-ROUTE-PLATFORM-NOVALUE), given an EMPTY value (which read as "no
      # override" and silently routed on detection instead), or followed by anything starting with `-`,
      # which would otherwise be swallowed as the value (`--platform --fallback` routed platform=--fallback).
      if [[ $# -lt 2 || -z "$2" || "$2" == -* ]]; then
        echo "reviewer-model-route: $1 requires a value" >&2
        usage >&2
        exit 2
      fi
      if [[ "$1" == "--platform" ]]; then PLATFORM_OVERRIDE="$2"; else WRITER_OVERRIDE="$2"; fi
      shift 2
      ;;
    --fallback)
      FALLBACK=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ (-n "$PLATFORM_OVERRIDE" || -n "$WRITER_OVERRIDE") && "${ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE:-0}" != "1" ]]; then
  echo "Override flags require ZUVO_ALLOW_REVIEWER_ROUTE_OVERRIDE=1" >&2
  exit 2
fi

# ── Host detection: the shared runner library ─────────────────────────────────
# "Is this a Codex host" has ONE implementation, zms_is_codex_host in scripts/lib/model-subprocess.sh:
# four signals, the ones the adversarial driver uses. This router used to check only CODEX_SANDBOX,
# which Codex Desktop does not set (it announces itself through CODEX_INTERNAL_ORIGINATOR_OVERRIDE,
# CODEX_SHELL and __CFBundleIdentifier), so a review started there resolved platform=unknown and
# fell back to the writer's own model. No inline copy of the signals is kept: a second copy is how
# the router and the driver drifted apart in the first place.
#
# Found by the shared `zms-locate` block below (sibling first: <this dir>/lib/ → <this dir>/ → ~/.zuvo/).
# install.sh puts scripts/lib/ beside EVERY installed copy of this file (Claude cache, ~/.codex,
# ~/.cursor, ~/.gemini/antigravity, ~/.kimi-code — install_runner_lib) and the flat copy in ~/.zuvo.
# The directory is resolved the way the driver and the preflight resolve theirs, with BUILTINS only — no
# dirname — because the router must answer with PATH=/nonexistent: from BASH_SOURCE by parameter
# expansion, then made PHYSICAL with `cd -P` + `pwd -P` (a `..` after a symlinked directory is the
# directory the kernel resolved, not a lexical guess). A bare name (`bash reviewer-model-route.sh`)
# means bash opened it from the current directory (a PATH-searched script is recorded with its full
# path); the -f check keeps it that way, so a lookup never points at a CWD the file is not in — the
# CWD is often the repository under review.
#
# A candidate that exists but does not load, or loads without defining every library function this
# file calls (_zms_fns below), is named on stderr and the next one is tried. None loads: the fail-closed six-key sentinel of
# shared/includes/env-compat.md ("Failure mode contract"), exit 0 — the sentinel is data for the
# caller (reviewer-preflight.sh parses stdout and degrades on routing-failed), not a process failure.
emit_routing_failed() {
  printf 'platform=unknown\nwriter_model=unknown\nwriter_lane=unknown\n'
  printf 'reviewer_lane=same-model-fallback\nreviewer_model=unknown\nrouting_status=routing-failed\n'
}

_rmr_src="${BASH_SOURCE[0]:-$0}"
_rmr_dir=""
case "$_rmr_src" in
  */*) _rmr_dir="${_rmr_src%/*}"; [ -n "$_rmr_dir" ] || _rmr_dir=/ ;;
  ?*)  if [ -n "${PWD:-}" ] && [ -f "$PWD/$_rmr_src" ]; then _rmr_dir="$PWD"; fi ;;
esac
if [ -n "$_rmr_dir" ]; then _rmr_dir="$(CDPATH='' cd -P -- "$_rmr_dir" 2>/dev/null && pwd -P)" || _rmr_dir=""; fi
_zms_dir="$_rmr_dir" _zms_repo="" _zms_who="reviewer-model-route: "
_zms_fns="zms_is_codex_host zms_codex_host_model zms_client_for_model zms_client_available zms_source_registry zms_is_model_id zms_is_writer_id"
# zms-locate:begin — the ONE runner-lib candidate order, byte-identical in every consumer (the router,
# the preflight, model-run, the adversarial driver; tests/hooks/test-reviewer-preflight-isolation.sh
# compares the four): <dir>/lib/ → <dir>/ (flat) → <repo>/scripts/lib/ (model-run in a checkout) →
# ~/.zuvo/. Inputs _zms_dir and _zms_repo (empty: no such candidate), _zms_fns, _zms_who; output
# ZMS_LOADED. A candidate loads only when it sources AND defines every function in _zms_fns — unset
# before each try, so what a half-loaded earlier one defined cannot pass for it; a rejected one is named.
ZMS_LOADED=""
_zms_cands=()
if [ -n "$_zms_dir" ]; then _zms_cands=("$_zms_dir/lib/model-subprocess.sh" "$_zms_dir/model-subprocess.sh"); fi
if [ -n "$_zms_repo" ]; then _zms_cands+=("$_zms_repo/scripts/lib/model-subprocess.sh"); fi
if [ -n "${HOME:-}" ]; then _zms_cands+=("$HOME/.zuvo/model-subprocess.sh"); fi
for _zms_lib in ${_zms_cands[@]+"${_zms_cands[@]}"}; do
  [ -f "$_zms_lib" ] || continue
  # shellcheck disable=SC2086  # one function name per word, by design
  unset -f $_zms_fns
  _zms_ok=0
  # shellcheck source=/dev/null
  if . "$_zms_lib"; then
    _zms_ok=1
    for _zms_fn in $_zms_fns; do declare -F "$_zms_fn" >/dev/null || _zms_ok=0; done
  fi
  if [ "$_zms_ok" -eq 1 ]; then ZMS_LOADED="$_zms_lib"; break; fi
  printf '%sWARN: %s exists but did not load the shared runner (%s) — trying the next candidate\n' "$_zms_who" "$_zms_lib" "$_zms_fns" >&2
done
unset _zms_cands _zms_lib _zms_fn _zms_ok
# zms-locate:end
unset _rmr_src _rmr_dir _zms_dir _zms_repo _zms_who _zms_fns
if [[ -z "$ZMS_LOADED" ]]; then
  echo "reviewer-model-route: model-subprocess.sh (shared host detection) not loaded from next to this script or from ~/.zuvo — routing failed closed. Fix: ./scripts/install.sh" >&2
  emit_routing_failed
  exit 0
fi

# is_hint <value> — a writer variable that says something: set, and not the literal `unknown`.
is_hint() { [[ -n "${1:-}" && "$1" != "unknown" ]]; }

detect_platform() {
  if [[ -n "$PLATFORM_OVERRIDE" ]]; then
    printf '%s\n' "$PLATFORM_OVERRIDE"
  # A writer variable holding the literal `unknown` names no writer, so it is no host signal either
  # (is_hint): CLAUDE_MODEL=unknown answers exactly like an unset CLAUDE_MODEL.
  elif [[ "${CLAUDECODE:-}" == "1" ]] || is_hint "${CLAUDE_MODEL:-}"; then
    printf 'claude\n'
  # ZUVO_CODEX_MODEL is this router's own writer-model hint, not a host signal: it stays here, and
  # the library knows only the host's own signals.
  elif zms_is_codex_host || is_hint "${ZUVO_CODEX_MODEL:-}"; then
    printf 'codex\n'
  elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Cursor"* || -n "${CURSOR_AGENT_MODEL:-}" || -n "${CURSOR_MODEL:-}" ]]; then
    printf 'cursor\n'
  elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Antigravity"* || -n "${ANTIGRAVITY_SESSION_ID:-}" || -n "${GEMINI_MODEL:-}" || -n "${ANTIGRAVITY_MODEL:-}" ]]; then
    printf 'antigravity\n'
  # Kimi Code exports NO identifying variable into its tool subprocess — established
  # empirically on v0.35.0 and documented in the driver's detect_host_platform
  # (scripts/lib/adversarial-providers.sh). The only signal
  # is that it prepends its bin dir to PATH, so this is the same probe that script uses.
  #
  # Checked LAST, and that placement is load-bearing rather than stylistic: the signal is
  # a PATH component, which `env -u` cannot strip, so any developer with ~/.kimi-code/bin
  # in their login PATH would otherwise have this branch answer for every marker-driven
  # case in reviewer-model-route.bats. Those cases set CLAUDE_MODEL / ZUVO_CODEX_MODEL /
  # GEMINI_MODEL, so an earlier branch always claims them first and the ordering keeps the
  # suite's result independent of who runs it — the exact failure mode that file's own
  # header records from 2026-08-10.
  elif [[ -n "${ZUVO_KIMI_CLI_MODEL:-}" || -n "${ZUVO_KIMI_MODEL:-}" ]]; then
    printf 'kimi\n'
  elif [[ ":${PATH}:" == *":$HOME/.kimi-code/bin:"* ]]; then
    printf 'kimi\n'
  else
    printf 'unknown\n'
  fi
}

# The two id checks come from the library, the one definition model-run and the preflight use too:
#   zms_is_model_id  <v>  a REVIEWER id from the registry: [A-Za-z0-9][A-Za-z0-9._:-]*.
#   zms_is_writer_id <v>  a WRITER id, from any source: a reviewer-shaped id plus at most ONE trailing
#                         [letters-and-digits] context suffix (claude-opus-<version>[1m], opus[1m]).
# is_blank <value> — empty or nothing but ASCII whitespace. Not [[:space:]]: under a UTF-8 locale that class
# can take in a no-break space, and a writer hint that is "blank" in one locale and not in another would
# route differently depending on who ran the router.
is_blank() { [[ -z "${1//[$' \t\n\r\v\f']/}" ]]; }

detect_writer_model() {
  local platform="$1" host_model=""
  if [[ -n "$WRITER_OVERRIDE" ]]; then
    printf '%s\n' "$WRITER_OVERRIDE"
    return 0
  fi

  # Claude and Codex writers are returned RAW here; the one validation point is where detect_writer_model
  # is called (below), for every source alike.
  case "$platform" in
    # An unset CLAUDE_MODEL — the normal Claude Code case — is an UNKNOWN writer, never an assumed one.
    claude) printf '%s\n' "${CLAUDE_MODEL:-unknown}" ;;
    # ZUVO_CODEX_MODEL (this router's own hint; empty or blank = not given) → CODEX_MODEL → the top-level
    # `model =` of ${CODEX_HOME:-~/.codex}/config.toml (both read by zms_codex_host_model) → unknown. The
    # library's status is not trusted alone: status 0 with nothing printed is caught by the validation.
    # The literal `unknown` in either variable is "not given" too, so the lookup goes on to the next source
    # (CODEX_MODEL=unknown is hidden from the library, which would otherwise return it as the model).
    codex)
      if ! is_blank "${ZUVO_CODEX_MODEL:-}" && is_hint "${ZUVO_CODEX_MODEL:-}"; then
        printf '%s\n' "$ZUVO_CODEX_MODEL"
      elif host_model="$(if is_hint "${CODEX_MODEL:-}"; then zms_codex_host_model; else CODEX_MODEL='' zms_codex_host_model; fi)"; then
        printf '%s\n' "$host_model"
      else
        printf 'unknown\n'
      fi
      ;;
    cursor) printf '%s\n' "${CURSOR_AGENT_MODEL:-${CURSOR_MODEL:-unknown}}" ;;
    antigravity) printf '%s\n' "${GEMINI_MODEL:-${ANTIGRAVITY_MODEL:-gemini-3.1-pro-low}}" ;;
    # `kimi-code` is the OAuth CLI's own default (k3) that a session inside Kimi Code
    # writes with; model-registry.sh keeps ZUVO_MODEL_KIMI_CLI EMPTY to mean exactly that,
    # so the literal belongs here rather than in the registry.
    kimi) printf '%s\n' "${ZUVO_KIMI_CLI_MODEL:-${ZUVO_KIMI_MODEL:-kimi-code}}" ;;
    *) printf 'unknown\n' ;;
  esac
}

# route_probe_hosts — the Cursor / Kimi fallback: the host itself is one model, so agy / codex / claude
# are all cross-model from here. The first one on PATH (looked up, never run) is the reviewer, ok;
# none: same-model-fallback with the writer as reviewer. The preflight canary still has to prove the
# named client answers, so a listed-but-dead one degrades there rather than being asserted working here.
route_probe_hosts() {
  local c
  for c in agy codex claude; do
    if command -v "$c" >/dev/null 2>&1; then reviewer_model="$c"; reviewer_lane="review-alt"; routing_status="ok"; return 0; fi
  done
  reviewer_model="$writer_model"; reviewer_lane="same-model-fallback"; routing_status="same-model-fallback"
}

sanitize_token() {
  local raw="${1:-unknown}"
  raw="${raw//$'\r'/}"
  if [[ "$raw" == *$'\n'* || "$raw" == *=* || -z "$raw" ]]; then
    printf 'unknown\n'
    return 0
  fi
  printf '%s\n' "$raw"
}

# ── Registry (Claude and Codex hosts only) ────────────────────────────────────
# load_registry — the reviewer ids, through the library's own lookup (the repo / plugin root this
# library sits in first, then ~/.zuvo/model-registry.sh, where install.sh puts it). Each id read here is
# printed into the six-key contract and used as a literal `case` pattern below, so each must pass
# zms_is_model_id — one plain token, no blank, `=`, glob character, `$`, backtick, `/` or line break. A
# registry that is not found, or a value that is not one id, fails the route closed: a reviewer that was
# never read is never named.
REGISTRY_IDS="ZUVO_MODEL_CODEX_PRIMARY ZUVO_MODEL_CODEX_ALT ZUVO_MODEL_CODEX_REVIEW_ALT ZUVO_MODEL_CODEX_SMALL ZUVO_MODEL_CLAUDE_REVIEWER_OPUS"
load_registry() {
  local var val
  if ! zms_source_registry; then
    echo "reviewer-model-route: shared/includes/model-registry.sh (the reviewer model ids) not found beside the runner library or in ~/.zuvo — routing failed closed. Fix: ./scripts/install.sh" >&2
    return 1
  fi
  for var in $REGISTRY_IDS; do
    val="${!var:-}"
    if ! zms_is_model_id "$val"; then
      # %q: the rejected value is shown escaped, so a line break or control character in it cannot
      # forge a line of its own on the caller's stderr.
      printf 'reviewer-model-route: %s from %s is not a single model id (%q) — routing failed closed\n' \
        "$var" "${ZMS_REGISTRY_FILE:-the registry}" "$val" >&2
      return 1
    fi
  done
}

# ── In-family tables (the labelled fallback) ─────────────────────────────────
# Each sets writer_lane and, when the writer is one it knows, if_lane / if_model: the reviewer of the
# writer's OWN vendor. Left empty for a writer the table does not know. if_lane / if_model are LOCALS of
# route_vendor_host, the only caller (bash's dynamic scope hands them to the table it calls), so nothing
# outside that call — an exported variable of the same name included — can reach them.
# A Claude writer names its tier in any of these shapes, and each names the same lane:
#   the harness alias            opus        opus[1m]     (a context suffix)
#   the full id, bare            claude-opus
#   the full id with a version   claude-opus-<version>    claude-opus-<version>[1m]
#   the legacy id                claude-3-opus-20240229   claude-3-5-sonnet-20241022
# A version must have at least one character: `claude-opus-` is not a model and has no lane (`?*`, not `*`,
# which would match the empty string). The reviewers stay the abstract tier labels the Agent tool takes.
in_family_claude() {
  case "$writer_model" in
    haiku|haiku\[?*\]|claude-haiku|claude-haiku-?*|claude-[0-9]*-haiku|claude-[0-9]*-haiku-?*)
      writer_lane="small";          if_lane="review-primary"; if_model="opus" ;;
    sonnet|sonnet\[?*\]|claude-sonnet|claude-sonnet-?*|claude-[0-9]*-sonnet|claude-[0-9]*-sonnet-?*)
      writer_lane="strong_alt";     if_lane="review-primary"; if_model="opus" ;;
    opus|opus\[?*\]|claude-opus|claude-opus-?*|claude-[0-9]*-opus|claude-[0-9]*-opus-?*)
      writer_lane="strong_primary"; if_lane="review-alt";     if_model="sonnet" ;;
  esac
}

# The registry's Codex pair: its primary is reviewed by review-alt, every other writer the table knows by
# the primary. The first three arms ARE registry values (quoted patterns match literally), so a registry
# bump moves the table with it — the drift that left the registry's own primary at unknown-writer-model
# (2026-08-11) and the reviewer ids a generation behind (01c1727e) cannot recur. The unquoted arms are
# OLDER writers (sessions still on an earlier generation: the primaries gpt-5.6-sol and gpt-5.4, the alt
# gpt-5.5, the small gpt-5.4-mini) — writer ids only, never a reviewer.
in_family_codex() {
  case "$writer_model" in
    "$ZUVO_MODEL_CODEX_PRIMARY"|gpt-5.6-sol|gpt-5.4)
      writer_lane="strong_primary"; if_lane="review-alt"; if_model="$ZUVO_MODEL_CODEX_REVIEW_ALT" ;;
    "$ZUVO_MODEL_CODEX_ALT"|"$ZUVO_MODEL_CODEX_REVIEW_ALT"|gpt-5.5)
      writer_lane="strong_alt"; if_lane="review-primary"; if_model="$ZUVO_MODEL_CODEX_PRIMARY" ;;
    "$ZUVO_MODEL_CODEX_SMALL"|gpt-5.4-mini)
      writer_lane="small"; if_lane="review-primary"; if_model="$ZUVO_MODEL_CODEX_PRIMARY" ;;
  esac
}

# route_vendor_host <in-family table> <cross-vendor id> <CLI that must serve it> <assumed lane> <assumed id>
# The Claude/Codex decision, after running the host's in-family table:
#   the other vendor's CLI present → cross-vendor, ok — for ANY writer, an unknown one included: the
#   (and no --fallback)              platform alone says which vendor wrote
#   otherwise, writer known        → the in-family row: in-family-fallback with --fallback,
#                                    cross-vendor-unavailable without it
#   otherwise, writer unknown      → the in-family row of the ASSUMED writer (the assumption the
#                                    adversarial driver's claude_reviewer_model makes: Opus on a Claude
#                                    host, the registry primary on a Codex host), unknown-writer-model —
#                                    with or without --fallback. On these two hosts reviewer_model is
#                                    therefore NEVER `unknown`: a caller always gets a model that can run,
#                                    and the status still says the writer was not known.
# The id must be served by the OTHER vendor's CLI (zms_client_for_model): an id no CLI serves, or one this
# host's own vendor serves, is never routed as cross-vendor. Availability is zms_client_available — a PATH
# lookup or the ZUVO_CODEX_BIN / ZUVO_CLAUDE_BIN seam; the client is never run.
route_vendor_host() {
  local in_family="$1" xv_model="$2" xv_client="$3" assume_lane="$4" assume_model="$5" client="" if_lane="" if_model=""
  "$in_family"
  if [[ "$FALLBACK" != "1" ]] && client="$(zms_client_for_model "$xv_model")" && [[ "$client" == "$xv_client" ]] \
      && zms_client_available "$client" 2>/dev/null; then
    reviewer_lane="cross-vendor"; reviewer_model="$xv_model"; routing_status="ok"
  elif [[ -n "$if_model" ]]; then
    reviewer_lane="$if_lane"; reviewer_model="$if_model"
    if [[ "$FALLBACK" == "1" ]]; then routing_status="in-family-fallback"; else routing_status="cross-vendor-unavailable"; fi
  else
    reviewer_lane="$assume_lane"; reviewer_model="$assume_model"; routing_status="unknown-writer-model"
  fi
}

platform="$(detect_platform)"
writer_raw="$(detect_writer_model "$platform")"
platform="$(sanitize_token "$platform")"
# THE writer validation point, for every source on the two hosts this file routes itself — --writer-model,
# CLAUDE_MODEL, ZUVO_CODEX_MODEL, CODEX_MODEL and config.toml alike: one writer token, or `unknown`. ONE
# trailing CR (a CRLF line ending) is dropped first; a CR or LF anywhere else makes the value malformed —
# it is never deleted to leave some other, valid-looking id (`op<CR>us` is not `opus`). (Cursor, Antigravity
# and Kimi keep sanitize_token, byte for byte — X7.)
case "$platform" in
  claude|codex)
    writer_model="${writer_raw%$'\r'}"
    zms_is_writer_id "$writer_model" || writer_model="unknown"
    ;;
  *) writer_model="$(sanitize_token "$writer_raw")" ;;
esac
writer_lane="unknown"
reviewer_lane="same-model-fallback"
reviewer_model="$writer_model"
routing_status="unknown-writer-model"

case "$platform" in
  claude|codex)
    if ! load_registry; then
      emit_routing_failed
      exit 0
    fi
    ;;
esac

case "$platform" in
  claude)
    route_vendor_host in_family_claude "$ZUVO_MODEL_CODEX_PRIMARY" codex review-alt sonnet
    ;;
  codex)
    route_vendor_host in_family_codex "$ZUVO_MODEL_CLAUDE_REVIEWER_OPUS" claude review-alt "$ZUVO_MODEL_CODEX_REVIEW_ALT"
    ;;
  cursor)
    # Glob, not literal: `fast`/`inherit` are what Cursor's model PICKER shows,
    # but CURSOR_AGENT_MODEL reports the resolved name (`composer-2.5-fast`), so
    # the literal arms never matched a real run and every Cursor writer was
    # lane=unknown — which is itself a degrade trigger elsewhere.
    case "$writer_model" in
      *fast*) writer_lane="small" ;;
      inherit|composer*|*max*) writer_lane="strong_primary" ;;
    esac
    # Cursor used to hardcode same-model-fallback here, unconditionally — the only
    # host that gave up without looking. antigravity, five lines down, routes to a
    # different model and reports ok. The consequence was not cosmetic: preflight
    # turns a non-ok routing_status into `degraded-routing`, which gates Step 4's
    # fallback-local degrade to same-model (test-reviewer-routing.md) — Step 3.5
    # blind-audit strictness is unaffected, since it comes from the panel's own
    # `Audit panel:` line, never from routing_status. Every Cursor Step-4 review
    # took that same-model hit, forever, even with a working cross-model client
    # installed.
    #
    route_probe_hosts
    ;;
  kimi)
    # Kimi Code is the only non-Claude target zuvo does not degrade, yet this table did
    # not know it: platform resolved to `unknown`, which lands in the explicit
    # `same-model-fallback` arm at the top of this file. Preflight turns a non-ok
    # routing_status into `degraded-routing`, so every write-tests Step-4 review run
    # from inside Kimi Code was capped at same-model — the same permanent, invisible
    # hit the cursor comment above records (Step 3.5 blind-audit strictness is
    # unaffected; it comes from the panel's own `Audit panel:` line, not
    # routing_status), and the same shape as the gpt-5.6-sol arm further up: a model
    # the registry names (ZUVO_MODEL_KIMI / ZUVO_MODEL_KIMI_CLI) that the ROUTING
    # table never learned.
    # ORDER IS LOAD-BEARING: `case` takes the FIRST matching arm, and `kimi-k2.[0-9]*` matches
    # `kimi-k2.` + `7` + `-code`, i.e. the whole of `kimi-k2.7-code`. With the generic arm first,
    # the explicit `kimi-k2.7-code` literal below was unreachable and that model was classified
    # strong_alt — the opposite of what naming it in the strong_primary arm was meant to say.
    # Specific arms first; the glob is the fallback. (Found by two independent auditors; no bats
    # case covered this input, which is why it shipped.)
    case "$writer_model" in
      kimi-code|k3*|kimi-k3*|kimi-k2.7-code) writer_lane="strong_primary" ;;
      kimi-k2.[0-9]*)                        writer_lane="strong_alt" ;;
    esac
    # Prefer the opposite IN-FAMILY lane, matching what claude (opus<->sonnet) and codex
    # (5.5<->5.4) do — K3 and K2.6 are different generations, not the same model twice.
    # It is offered only when it can actually be reached: the second lane is the curl
    # fallback, which is inert without MOONSHOT_API_KEY, and naming an unreachable
    # reviewer here would report `ok` for a review that cannot run.
    # No key: a cross-host client, exactly as the cursor arm does.
    if [ -n "${MOONSHOT_API_KEY:-}" ]; then
      case "$writer_model" in
        kimi-k2.[0-9]*) reviewer_model="kimi-code" ;;
        *)              reviewer_model="kimi-k2.6" ;;
      esac
      reviewer_lane="review-alt"
      routing_status="ok"
    else
      route_probe_hosts
    fi
    ;;
  antigravity)
    case "$writer_model" in
      gemini-2.5-flash*|gemini-3-flash*|gemini-flash*)
        writer_lane="small"
        reviewer_lane="review-primary"
        reviewer_model="gemini-3.1-pro-high"
        routing_status="ok"
        ;;
      gemini-3.1-pro-low*|gemini-2.5-pro-low*)
        writer_lane="strong_alt"
        reviewer_lane="review-primary"
        reviewer_model="gemini-3.1-pro-high"
        routing_status="ok"
        ;;
      gemini-3.1-pro-high*|gemini-2.5-pro*|gemini-pro*)
        writer_lane="strong_primary"
        reviewer_lane="review-alt"
        reviewer_model="gemini-3.1-pro-low"
        routing_status="ok"
        ;;
      gemini)
        writer_lane="strong_primary"
        reviewer_lane="same-model-fallback"
        reviewer_model="gemini"
        routing_status="same-model-fallback"
        ;;
    esac
    ;;
esac

# A reviewer that IS the writer is never reported as anything but same-model — not as ok, and not as a
# labelled fallback either (a registry whose review-alt equals the writer would otherwise say
# in-family-fallback for a model reviewing itself). A trailing context suffix does not make another model:
# `<id>[1m]` reviewed by `<id>` is the same model, so both sides are compared without one. unknown-writer-model
# / same-model-fallback rows are already honest and are left alone.
model_base() { case "$1" in *\]) printf '%s' "${1%\[*}" ;; *) printf '%s' "$1" ;; esac; }
case "$routing_status" in
  ok|in-family-fallback|cross-vendor-unavailable)
    if [[ "$(model_base "$reviewer_model")" == "$(model_base "$writer_model")" ]]; then
      reviewer_lane="same-model-fallback"
      routing_status="same-model-fallback"
    fi
    ;;
esac

printf 'platform=%s\n' "$platform"
printf 'writer_model=%s\n' "$writer_model"
printf 'writer_lane=%s\n' "$writer_lane"
printf 'reviewer_lane=%s\n' "$reviewer_lane"
printf 'reviewer_model=%s\n' "$reviewer_model"
printf 'routing_status=%s\n' "$routing_status"
