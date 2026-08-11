#!/usr/bin/env bash

set -euo pipefail

# Central model registry (fail-safe: inline `:-<id>` fallbacks below keep this working if missing).
_zuvo_reg="$(dirname "${BASH_SOURCE[0]:-$0}")/../shared/includes/model-registry.sh"
[ -f "$_zuvo_reg" ] && . "$_zuvo_reg"

PROTOCOL_FILE=""
PRODUCTION_FILE=""
TEST_FILE=""
MODEL=""
PROVIDER=""
# Default raised from 180s: Codex cuts an idle stream at 300_000 ms of its own,
# so a 180s wrapper killed long audits BEFORE the client could report why, and
# every such run looked like blocked infrastructure. The wrapper must outlive the
# client's own limit so the real cause surfaces.
TIMEOUT_SECONDS="${ZUVO_BLIND_AUDIT_TIMEOUT:-600}"

# Reasoning effort for the audit subprocess.
#
# Without this the run inherits `model_reasoning_effort` from the user's global
# ~/.codex/config.toml. At "xhigh" a large audit thinks for >5 minutes without
# emitting a single stream event, and Codex's 300s idle timeout kills it:
#   stream disconnected before completion: idle timeout waiting for websocket
# Observed on both 0.144.6 and 0.146.0-alpha.3.1, so it is not a CLI-version bug.
# "high" keeps audit quality while staying well inside the idle window.
REASONING_EFFORT="${ZUVO_BLIND_AUDIT_EFFORT:-high}"

usage() {
  cat <<'EOF'
Usage: blind-audit-codex.sh --protocol <blind-coverage-audit.md> --production <file> --test <file> [--model <model>] [--provider codex|agy|gemini|claude] [--timeout <seconds>] [--effort <low|medium|high|xhigh>]

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
    --effort)
      REASONING_EFFORT="${2:-}"
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

# HOST_EXCLUDE is a SET, not one name: a host can front more than one client for the same
# model. Antigravity fronts BOTH Gemini lanes (`gemini` and `agy`), so excluding only
# "gemini" left `agy` free to audit its own output — the self-audit this block exists to
# prevent. Same scalar-vs-set defect fixed in adversarial-review.sh --exclude on 2026-08-11.
HOST_EXCLUDE=""
if [[ "${CLAUDECODE:-}" == "1" ]]; then
  HOST_EXCLUDE="claude"
elif [[ -n "${CODEX_SANDBOX:-}" ]]; then
  HOST_EXCLUDE="codex"
elif [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"Antigravity"* ]] \
   || [[ "${VSCODE_GIT_ASKPASS_MAIN:-}" == *"antigravity"* ]] \
   || [[ -n "${ANTIGRAVITY_SESSION_ID:-}" ]]; then
  HOST_EXCLUDE="gemini agy"
# Cursor hosts nothing on this list (cursor-agent is not a blind-audit client), so every
# provider below stays eligible — notably `agy`, which is what makes a Cursor-hosted blind
# audit genuinely cross-model instead of silently degraded.
fi

host_excluded() { [[ " $HOST_EXCLUDE " == *" $1 "* ]]; }

if [[ -n "$HOST_EXCLUDE" ]]; then
  echo "  Host detected: $HOST_EXCLUDE -- auto-excluding to prevent self-audit" >&2
fi

if [[ -z "$PROVIDER" ]]; then
  # Build candidate list, excluding host provider(s)
  candidates=()
  if ! host_excluded codex && command -v codex >/dev/null 2>&1; then
    candidates+=("codex")
  fi
  if ! host_excluded agy && command -v agy >/dev/null 2>&1; then
    candidates+=("agy")
  fi
  if ! host_excluded gemini && command -v gemini >/dev/null 2>&1; then
    candidates+=("gemini")
  fi
  if ! host_excluded claude && command -v claude >/dev/null 2>&1; then
    candidates+=("claude")
  fi

  if [[ ${#candidates[@]} -gt 0 ]]; then
    PROVIDER="${candidates[0]}"
  else
    echo "No supported blind-audit client found (need codex, agy, gemini, or claude — host excluded: ${HOST_EXCLUDE:-none})" >&2
    exit 2
  fi
fi

case "$PROVIDER" in
  codex|agy|gemini|claude) ;;
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
    codex) MODEL="${ZUVO_CODEX_MODEL:-${ZUVO_MODEL_CODEX_PRIMARY:-gpt-5.5}}" ;;
    # agy takes the DISPLAY name from `agy models`, not an API id.
    agy) MODEL="${ZUVO_AGY_MODEL:-${ZUVO_MODEL_AGY:-Gemini 3.1 Pro (High)}}" ;;
    gemini) MODEL="${ZUVO_GEMINI_MODEL:-${ZUVO_MODEL_GEMINI_API:-gemini-3.1-pro-preview}}" ;;
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
    --skip-git-repo-check
    -C "$tmpdir"
    -o "$tmpdir/out.txt"
  )
  # No -s/--sandbox override: inherit the user's global Codex profile
  # (e.g. danger-full-access + never). The blind-audit prompt itself forbids
  # repo tools and the run is confined to an isolated $tmpdir via -C.
  #
  # Reasoning effort, however, must NOT be inherited: a global "xhigh" makes the
  # model think silently past Codex's 300s stream-idle limit and the run dies as
  # "idle timeout waiting for websocket" — reported as blocked infrastructure.
  if [[ -n "$REASONING_EFFORT" ]]; then
    codex_args+=( -c "model_reasoning_effort=$REASONING_EFFORT" )
  fi

  if [[ -n "$MODEL" ]]; then
    codex_args+=( -m "$MODEL" )
  fi

  # The bare "-" (read prompt from stdin) is positional and must come last.
  codex_args+=( - )

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

run_agy() {
  if ! command -v agy >/dev/null 2>&1; then
    echo "agy command not found" >&2
    return 2
  fi

  # agy takes the prompt as an ARGUMENT, not on stdin — piping makes it answer an empty
  # prompt and hallucinate (verified 2026-07-11, see run_agy in adversarial-review.sh).
  # Every other provider here reads $tmpdir/prompt.txt from stdin; agy is the exception.
  local prompt
  prompt="$(cat "$tmpdir/prompt.txt")"

  # …and being the exception is what makes a size guard necessary HERE and nowhere else.
  # An argv element is capped by the kernel (Linux MAX_ARG_STRLEN = 128 KiB), and this
  # script never truncates: the prompt is protocol + the WHOLE production file + the WHOLE
  # test file. adversarial-review.sh does not hit this because it caps its input at
  # 30-50 K chars before building the prompt (scripts/adversarial-review.sh:462-463);
  # blind audit has no such cap, so a normal-sized entity + spec pair can exceed the limit
  # and `execve` fails with a bare "Argument list too long" that reads like agy is broken.
  # Fail with a legible message instead — an honest, attributable degradation.
  # Measure the FILE, not the shell string. `${#prompt}` counts CHARACTERS: in a UTF-8
  # locale 100k chars of em-dashes/arrows/curly quotes — which this codebase's own prose
  # uses constantly — is well over the 131072-BYTE kernel limit, so a char-count guard
  # passes and E2BIG fires anyway. `wc -c` on the source file is exact and needs no locale
  # juggling. (Caught by the post-fix adversarial pass on the guard's first version.)
  local prompt_bytes
  prompt_bytes=$(wc -c < "$tmpdir/prompt.txt" | tr -d ' ')
  if [[ $prompt_bytes -gt 120000 ]]; then
    echo "agy prompt is ${prompt_bytes} bytes, over the ~128KB single-argument limit — agy takes the prompt as an argv element, so this cannot be streamed. Use --provider codex|claude for this pair, or split the audit." >&2
    return 2
  fi

  run_with_timeout agy -p "$prompt" \
    --model "$MODEL" --dangerously-skip-permissions \
    > "$tmpdir/stdout.txt" 2> "$tmpdir/stderr.txt"
  local status=$?

  # agy can exit 0 while printing a quota/auth error AS its output. Without this guard a
  # quota'd agy hands its error string to the verdict parser below, which finds no
  # "Coverage verdict:" line and would report an unusable audit as a completed one.
  if [[ $status -eq 0 ]] && head -c 400 "$tmpdir/stdout.txt" 2>/dev/null | grep -qE \
      '^Error:|quota reached|Please upgrade your subscription|Authentication required|IneligibleTier'; then
    echo "agy unusable (quota/auth), not an audit: $(head -1 "$tmpdir/stdout.txt" | head -c 120)" >&2
    return 1
  fi
  return $status
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
  agy)
    if ! run_agy; then
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
