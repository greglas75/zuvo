#!/usr/bin/env bash

set -euo pipefail

# NOTE: this file is an explicit writer->reviewer ROUTING TABLE keyed on concrete model ids
# (case patterns), plus Antigravity-IDE model ids (gemini-3.1-pro-low/high — a different namespace
# than agy's display names). It is intentionally NOT wired to shared/includes/model-registry.sh:
# the registry is for "which model a provider DEFAULTS to", this is a mapping. Bump ids here directly.

PLATFORM_OVERRIDE=""
WRITER_OVERRIDE=""

usage() {
  cat <<'EOF'
Usage: reviewer-model-route.sh [--platform <name>] [--writer-model <model>]

Emits a deterministic reviewer routing contract as KEY=VALUE lines:
  platform
  writer_model
  writer_lane
  reviewer_lane
  reviewer_model
  routing_status

Override flags are for tests and smoke validation only.
Runtime callers should rely on environment detection.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --platform)
      PLATFORM_OVERRIDE="${2:-}"
      shift 2
      ;;
    --writer-model)
      WRITER_OVERRIDE="${2:-}"
      shift 2
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

detect_platform() {
  if [[ -n "$PLATFORM_OVERRIDE" ]]; then
    printf '%s\n' "$PLATFORM_OVERRIDE"
  elif [[ "${CLAUDECODE:-}" == "1" || -n "${CLAUDE_MODEL:-}" ]]; then
    printf 'claude\n'
  elif [[ -n "${CODEX_SANDBOX:-}" || -n "${ZUVO_CODEX_MODEL:-}" ]]; then
    printf 'codex\n'
  elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Cursor"* || -n "${CURSOR_AGENT_MODEL:-}" || -n "${CURSOR_MODEL:-}" ]]; then
    printf 'cursor\n'
  elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Antigravity"* || -n "${ANTIGRAVITY_SESSION_ID:-}" || -n "${GEMINI_MODEL:-}" || -n "${ANTIGRAVITY_MODEL:-}" ]]; then
    printf 'antigravity\n'
  # Kimi Code exports NO identifying variable into its tool subprocess — established
  # empirically on v0.35.0 and documented at adversarial-review.sh:1092. The only signal
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

detect_writer_model() {
  local platform="$1"
  if [[ -n "$WRITER_OVERRIDE" ]]; then
    printf '%s\n' "$WRITER_OVERRIDE"
    return 0
  fi

  case "$platform" in
    claude) printf '%s\n' "${CLAUDE_MODEL:-sonnet}" ;;
    codex) printf '%s\n' "${ZUVO_CODEX_MODEL:-gpt-5.5}" ;;
    cursor) printf '%s\n' "${CURSOR_AGENT_MODEL:-${CURSOR_MODEL:-unknown}}" ;;
    antigravity) printf '%s\n' "${GEMINI_MODEL:-${ANTIGRAVITY_MODEL:-gemini-3.1-pro-low}}" ;;
    # `kimi-code` is the OAuth CLI's own default (k3) that a session inside Kimi Code
    # writes with; model-registry.sh keeps ZUVO_MODEL_KIMI_CLI EMPTY to mean exactly that,
    # so the literal belongs here rather than in the registry.
    kimi) printf '%s\n' "${ZUVO_KIMI_CLI_MODEL:-${ZUVO_KIMI_MODEL:-kimi-code}}" ;;
    *) printf 'unknown\n' ;;
  esac
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

platform="$(detect_platform)"
writer_model="$(detect_writer_model "$platform")"
platform="$(sanitize_token "$platform")"
writer_model="$(sanitize_token "$writer_model")"
writer_lane="unknown"
reviewer_lane="same-model-fallback"
reviewer_model="$writer_model"
routing_status="unknown-writer-model"

case "$platform" in
  claude)
    case "$writer_model" in
      haiku)
        writer_lane="small"
        reviewer_lane="review-primary"
        reviewer_model="opus"
        routing_status="ok"
        ;;
      sonnet)
        writer_lane="strong_alt"
        reviewer_lane="review-primary"
        reviewer_model="opus"
        routing_status="ok"
        ;;
      opus)
        writer_lane="strong_primary"
        reviewer_lane="review-alt"
        reviewer_model="sonnet"
        routing_status="ok"
        ;;
    esac
    ;;
  codex)
    case "$writer_model" in
      gpt-5.4-mini)
        writer_lane="small"
        reviewer_lane="review-primary"
        reviewer_model="gpt-5.4"
        routing_status="ok"
        ;;
      gpt-5.4)
        writer_lane="strong_primary"
        reviewer_lane="review-alt"
        reviewer_model="gpt-5.5"
        routing_status="ok"
        ;;
      gpt-5.5)
        writer_lane="strong_alt"
        reviewer_lane="review-primary"
        reviewer_model="gpt-5.4"
        routing_status="ok"
        ;;
      gpt-5.6-sol)
        # model-registry.sh designates this ZUVO_MODEL_CODEX_PRIMARY, but this
        # table never learned it, so the registry's OWN primary resolved to
        # `unknown-writer-model` -> same-model-fallback: a Codex session on the
        # default model reviewed its own work with itself, which is exactly what
        # the cross-model routing exists to prevent. Found 2026-08-11 while
        # repairing these tests — the two registries had drifted the same way the
        # CLIENT lists had (f5a8a10), just for MODELS instead.
        writer_lane="strong_primary"
        reviewer_lane="review-alt"
        reviewer_model="gpt-5.4"
        routing_status="ok"
        ;;
    esac
    ;;
  cursor)
    # Glob, not literal: `fast`/`inherit` are what Cursor's model PICKER shows,
    # but CURSOR_AGENT_MODEL reports the resolved name (`composer-2.5-fast`), so
    # the literal arms never matched a real run and every Cursor writer was
    # lane=unknown — which is itself a degrade trigger elsewhere.
    case "$writer_model" in
      fast|*-fast|*fast*) writer_lane="small" ;;
      inherit|composer*|*-max|*max*) writer_lane="strong_primary" ;;
    esac
    # Cursor used to hardcode same-model-fallback here, unconditionally — the only
    # host that gave up without looking. antigravity, five lines down, routes to a
    # different model and reports ok. The consequence was not cosmetic: preflight
    # turns a non-ok routing_status into `degraded-routing`, which per
    # test-reviewer-routing.md caps the blind audit at `clean:degraded` — and that
    # include measured a same-model audit returning CLEAN where agy found 8
    # uncovered defensive paths on the same pair. Every Cursor run took that hit,
    # forever, even with a working cross-model client installed.
    #
    # cursor-agent is the host, so agy / codex / claude are all cross-model from
    # here. Name the first one present; the preflight canary still has to prove it
    # answers, so a listed-but-dead client degrades there rather than being
    # asserted working here.
    reviewer_model=""
    for _c in agy codex claude; do
      if command -v "$_c" >/dev/null 2>&1; then reviewer_model="$_c"; break; fi
    done
    if [ -n "$reviewer_model" ]; then
      reviewer_lane="review-alt"
      routing_status="ok"
    else
      routing_status="same-model-fallback"
      reviewer_lane="same-model-fallback"
      reviewer_model="$writer_model"
    fi
    unset _c
    ;;
  kimi)
    # Kimi Code is the only non-Claude target zuvo does not degrade, yet this table did
    # not know it: platform resolved to `unknown`, which lands in the explicit
    # `same-model-fallback` arm at the top of this file. Preflight turns a non-ok
    # routing_status into `degraded-routing`, so every write-tests blind audit run from
    # inside Kimi Code was capped at `clean:degraded` — the same permanent, invisible hit
    # the cursor comment above records, and the same shape as the gpt-5.6-sol arm further
    # up: a model the registry names (ZUVO_MODEL_KIMI / ZUVO_MODEL_KIMI_CLI) that the
    # ROUTING table never learned.
    case "$writer_model" in
      kimi-k2.6|kimi-k2.[0-9]*)   writer_lane="strong_alt" ;;
      kimi-code|k3*|kimi-k3*|kimi-k2.7-code) writer_lane="strong_primary" ;;
    esac
    # Prefer the opposite IN-FAMILY lane, matching what claude (opus<->sonnet) and codex
    # (5.5<->5.4) do — K3 and K2.6 are different generations, not the same model twice.
    # It is offered only when it can actually be reached: the second lane is the curl
    # fallback, which is inert without MOONSHOT_API_KEY, and naming an unreachable
    # reviewer here would report `ok` for a review that cannot run.
    reviewer_model=""
    if [ -n "${MOONSHOT_API_KEY:-}" ]; then
      case "$writer_model" in
        kimi-k2.6|kimi-k2.[0-9]*) reviewer_model="kimi-code" ;;
        *)                        reviewer_model="kimi-k2.6" ;;
      esac
    fi
    # No key: fall back to a cross-host client exactly as the cursor arm does. kimi is the
    # host, so agy / codex / claude are all cross-model from here. The preflight canary
    # still has to prove the named client answers, so a listed-but-dead one degrades there
    # rather than being asserted working here.
    if [ -z "$reviewer_model" ]; then
      for _c in agy codex claude; do
        if command -v "$_c" >/dev/null 2>&1; then reviewer_model="$_c"; break; fi
      done
    fi
    if [ -n "$reviewer_model" ]; then
      reviewer_lane="review-alt"
      routing_status="ok"
    else
      routing_status="same-model-fallback"
      reviewer_lane="same-model-fallback"
      reviewer_model="$writer_model"
    fi
    unset _c
    ;;
  antigravity)
    case "$writer_model" in
      gemini-3-flash)
        writer_lane="small"
        reviewer_lane="review-primary"
        reviewer_model="gemini-3.1-pro-high"
        routing_status="ok"
        ;;
      gemini-2.5-flash*|gemini-3-flash*|gemini-flash*)
        writer_lane="small"
        reviewer_lane="review-primary"
        reviewer_model="gemini-3.1-pro-high"
        routing_status="ok"
        ;;
      gemini-3.1-pro-low)
        writer_lane="strong_alt"
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
      gemini-3.1-pro-high)
        writer_lane="strong_primary"
        reviewer_lane="review-alt"
        reviewer_model="gemini-3.1-pro-low"
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

if [[ "$routing_status" == "ok" && "$reviewer_model" == "$writer_model" ]]; then
  reviewer_lane="same-model-fallback"
  reviewer_model="$writer_model"
  routing_status="same-model-fallback"
fi

printf 'platform=%s\n' "$platform"
printf 'writer_model=%s\n' "$writer_model"
printf 'writer_lane=%s\n' "$writer_lane"
printf 'reviewer_lane=%s\n' "$reviewer_lane"
printf 'reviewer_model=%s\n' "$reviewer_model"
printf 'routing_status=%s\n' "$routing_status"
