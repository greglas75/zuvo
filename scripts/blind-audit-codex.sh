#!/usr/bin/env bash

set -euo pipefail

PROTOCOL_FILE=""
PRODUCTION_FILE=""
TEST_FILE=""
MODEL=""
PROVIDER=""
TIMEOUT_SECONDS="${ZUVO_BLIND_AUDIT_TIMEOUT:-180}"

usage() {
  cat <<'EOF'
Usage: blind-audit-codex.sh --protocol <blind-coverage-audit.md> --production <file> --test <file> [--model <model>] [--provider codex|gemini|claude] [--timeout <seconds>]

Runs a strict blind coverage audit in a platform-aware subprocess.
Success requires a non-empty final message containing:
  - Audit mode: strict
  - Coverage verdict:
  - INVENTORY COMPLETE:
  - the required inventory table header
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --protocol)
      PROTOCOL_FILE="${2:-}"
      shift 2
      ;;
    --production)
      PRODUCTION_FILE="${2:-}"
      shift 2
      ;;
    --test)
      TEST_FILE="${2:-}"
      shift 2
      ;;
    --provider)
      PROVIDER="${2:-}"
      shift 2
      ;;
    --model)
      MODEL="${2:-}"
      shift 2
      ;;
    --timeout)
      TIMEOUT_SECONDS="${2:-}"
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

for required in "$PROTOCOL_FILE" "$PRODUCTION_FILE" "$TEST_FILE"; do
  if [[ -z "$required" ]]; then
    echo "Missing required arguments." >&2
    usage >&2
    exit 2
  fi
done

for path in "$PROTOCOL_FILE" "$PRODUCTION_FILE" "$TEST_FILE"; do
  if [[ ! -f "$path" ]]; then
    echo "Missing file: $path" >&2
    exit 2
  fi
done

# ─── Host platform detection (prevent self-audit) ─────────────────
# Same logic as adversarial-review.sh — blind audit must use a DIFFERENT
# provider than the host to avoid self-review bias.

HOST_EXCLUDE=""
if [[ "${CLAUDECODE:-}" == "1" ]]; then
  HOST_EXCLUDE="claude"
elif [[ -n "${CODEX_SANDBOX:-}" ]]; then
  HOST_EXCLUDE="codex"
elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Antigravity"* ]] \
   || [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"antigravity"* ]] \
   || [[ -n "${ANTIGRAVITY_SESSION_ID:-}" ]]; then
  HOST_EXCLUDE="gemini"
# Cursor: no blind-audit provider (only codex/gemini/claude supported), nothing to exclude
fi

if [[ -n "$HOST_EXCLUDE" ]]; then
  echo "  Host detected: $HOST_EXCLUDE -- auto-excluding to prevent self-audit" >&2
fi

if [[ -z "$PROVIDER" ]]; then
  # Build candidate list, excluding host provider
  candidates=()
  if [[ "$HOST_EXCLUDE" != "codex" ]] && command -v codex >/dev/null 2>&1; then
    candidates+=("codex")
  fi
  if [[ "$HOST_EXCLUDE" != "gemini" ]] && command -v gemini >/dev/null 2>&1; then
    candidates+=("gemini")
  fi
  if [[ "$HOST_EXCLUDE" != "claude" ]] && command -v claude >/dev/null 2>&1; then
    candidates+=("claude")
  fi

  if [[ ${#candidates[@]} -gt 0 ]]; then
    PROVIDER="${candidates[0]}"
  else
    echo "No supported blind-audit client found (need codex, gemini, or claude — host excluded: ${HOST_EXCLUDE:-none})" >&2
    exit 2
  fi
fi

case "$PROVIDER" in
  codex|gemini|claude) ;;
  *)
    echo "Unsupported provider: $PROVIDER" >&2
    usage >&2
    exit 2
    ;;
esac

if [[ -z "$MODEL" ]]; then
  # Use ZUVO_*_MODEL env vars (explicit overrides), NOT host env vars like
  # GEMINI_MODEL or CLAUDE_MODEL which reflect the WRITER model, not the auditor.
  case "$PROVIDER" in
    codex) MODEL="${ZUVO_CODEX_MODEL:-gpt-5.3-codex}" ;;
    gemini) MODEL="${ZUVO_GEMINI_MODEL:-gemini-3.1-pro-preview}" ;;
    claude) MODEL="${ZUVO_CLAUDE_AUDIT_MODEL:-opus}" ;;
  esac
fi

if ! [[ "$TIMEOUT_SECONDS" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT_SECONDS" -le 0 ]]; then
  echo "Invalid timeout: $TIMEOUT_SECONDS" >&2
  exit 2
fi

tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/zuvo-blind-audit.XXXXXX")"
cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

{
  cat <<EOF
You are running a strict blind coverage audit.
Read only the material below.

--- FILE: blind-coverage-audit.md ---
EOF
  cat "$PROTOCOL_FILE"
  cat <<EOF
--- END FILE ---

--- FILE: $(basename "$PRODUCTION_FILE") ---
EOF
  cat "$PRODUCTION_FILE"
  cat <<EOF
--- END FILE ---

--- FILE: $(basename "$TEST_FILE") ---
EOF
  cat "$TEST_FILE"
  cat <<'EOF'
--- END FILE ---

Follow blind-coverage-audit.md exactly.
Do not use repo tools, CodeSift, or any prior conversation context.
Return only the required strict output block.
EOF
} > "$tmpdir/prompt.txt"

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" "$@"
  else
    "$@"
  fi
}

run_codex() {
  if ! command -v codex >/dev/null 2>&1; then
    echo "codex command not found" >&2
    return 2
  fi

  local codex_args=(
    exec
    --ephemeral
    --color never
    -s read-only
    --skip-git-repo-check
    -C "$tmpdir"
    -o "$tmpdir/out.txt"
    -
  )

  if [[ -n "$MODEL" ]]; then
    codex_args+=( -m "$MODEL" )
  fi

  run_with_timeout codex "${codex_args[@]}" < "$tmpdir/prompt.txt" > "$tmpdir/stdout.txt" 2> "$tmpdir/stderr.txt"
}

run_gemini() {
  if ! command -v gemini >/dev/null 2>&1; then
    echo "gemini command not found" >&2
    return 2
  fi

  local gemini_args=(
    --allowed-mcp-server-names __NONE__
    -p ""
  )

  if [[ -n "$MODEL" ]]; then
    gemini_args+=( --model "$MODEL" )
  fi

  run_with_timeout gemini "${gemini_args[@]}" < "$tmpdir/prompt.txt" > "$tmpdir/stdout.txt" 2> "$tmpdir/stderr.txt"
}

run_claude() {
  if ! command -v claude >/dev/null 2>&1; then
    echo "claude command not found" >&2
    return 2
  fi

  run_with_timeout claude \
    --model "$MODEL" \
    --print \
    --output-format text \
    --tools "" \
    < "$tmpdir/prompt.txt" > "$tmpdir/stdout.txt" 2> "$tmpdir/stderr.txt"
}

case "$PROVIDER" in
  codex)
    if ! run_codex; then
      cat "$tmpdir/stderr.txt" >&2 || true
      exit 1
    fi
    ;;
  gemini)
    if ! run_gemini; then
      cat "$tmpdir/stderr.txt" >&2 || true
      exit 1
    fi
    ;;
  claude)
    if ! run_claude; then
      cat "$tmpdir/stderr.txt" >&2 || true
      exit 1
    fi
    ;;
esac

candidate_file=""
if [[ -s "$tmpdir/out.txt" ]]; then
  candidate_file="$tmpdir/out.txt"
fi

if [[ -s "$tmpdir/stdout.txt" ]]; then
  if grep -q 'Audit mode: strict' "$tmpdir/stdout.txt" \
    && grep -q 'Coverage verdict:' "$tmpdir/stdout.txt" \
    && grep -q 'INVENTORY COMPLETE:' "$tmpdir/stdout.txt" \
    && grep -q '| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |' "$tmpdir/stdout.txt"; then
    candidate_file="$tmpdir/stdout.txt"
  fi
fi

if [[ -z "$candidate_file" ]]; then
  echo "blind-audit-codex: missing validated strict output" >&2
  cat "$tmpdir/stderr.txt" >&2 || true
  cat "$tmpdir/stdout.txt" >&2 || true
  exit 1
fi

if ! grep -q 'Audit mode: strict' "$candidate_file"; then
  echo "blind-audit-codex: strict audit marker missing" >&2
  cat "$candidate_file" >&2
  exit 1
fi

if ! grep -q 'Coverage verdict:' "$candidate_file"; then
  echo "blind-audit-codex: coverage verdict missing" >&2
  cat "$candidate_file" >&2
  exit 1
fi

if ! grep -q 'INVENTORY COMPLETE:' "$candidate_file"; then
  echo "blind-audit-codex: inventory summary missing" >&2
  cat "$candidate_file" >&2
  exit 1
fi

if ! grep -q '| id | kind | production lines | owned_or_delegated | coverage | test evidence | notes |' "$candidate_file"; then
  echo "blind-audit-codex: required inventory table header missing" >&2
  cat "$candidate_file" >&2
  exit 1
fi

cat "$candidate_file"
