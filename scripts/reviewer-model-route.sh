#!/usr/bin/env bash

set -euo pipefail

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
  elif [[ -n "${CLAUDE_MODEL:-}" ]]; then
    printf 'claude\n'
  elif [[ -n "${ZUVO_CODEX_MODEL:-}" ]]; then
    printf 'codex\n'
  elif [[ -n "${CURSOR_AGENT_MODEL:-}" || -n "${CURSOR_MODEL:-}" ]]; then
    printf 'cursor\n'
  elif [[ -n "${GEMINI_MODEL:-}" || -n "${ANTIGRAVITY_MODEL:-}" ]]; then
    printf 'antigravity\n'
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
    claude) printf '%s\n' "${CLAUDE_MODEL:-unknown}" ;;
    codex) printf '%s\n' "${ZUVO_CODEX_MODEL:-unknown}" ;;
    cursor) printf '%s\n' "${CURSOR_AGENT_MODEL:-${CURSOR_MODEL:-unknown}}" ;;
    antigravity) printf '%s\n' "${GEMINI_MODEL:-${ANTIGRAVITY_MODEL:-unknown}}" ;;
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
        reviewer_model="gpt-5.3-codex"
        routing_status="ok"
        ;;
      gpt-5.3-codex)
        writer_lane="strong_alt"
        reviewer_lane="review-primary"
        reviewer_model="gpt-5.4"
        routing_status="ok"
        ;;
    esac
    ;;
  cursor)
    case "$writer_model" in
      fast) writer_lane="small" ;;
      inherit) writer_lane="strong_primary" ;;
    esac
    routing_status="same-model-fallback"
    reviewer_lane="same-model-fallback"
    reviewer_model="$writer_model"
    ;;
  antigravity)
    case "$writer_model" in
      gemini-3-flash)
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
      gemini-3.1-pro-high)
        writer_lane="strong_primary"
        reviewer_lane="review-alt"
        reviewer_model="gemini-3.1-pro-low"
        routing_status="ok"
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
