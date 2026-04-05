#!/usr/bin/env bash
# adversarial-review.sh — Cross-provider adversarial code review
#
# Auto-detects available review providers (Gemini CLI, Codex CLI, Ollama)
# and runs an adversarial review of the given diff or files.
#
# Usage:
#   git diff HEAD~1 | ./scripts/adversarial-review.sh
#   ./scripts/adversarial-review.sh --files "src/auth.ts src/user.ts"
#   ./scripts/adversarial-review.sh --diff HEAD~3
#   ./scripts/adversarial-review.sh --provider gemini --diff HEAD~1
#   ./scripts/adversarial-review.sh --provider ollama --model qwen2.5-coder:14b --diff HEAD~1
#
# Exit codes:
#   0 — review completed (output on stdout)
#   1 — no review provider available
#   2 — review provider failed

set -euo pipefail

# ─── Configuration ──────────────────────────────────────────────

OLLAMA_MODEL="${ZUVO_OLLAMA_MODEL:-qwen2.5-coder:32b}"
CODEX_MODEL="${ZUVO_CODEX_MODEL:-}"
GEMINI_MODEL="${ZUVO_GEMINI_MODEL:-}"

# ─── Argument parsing ───────────────────────────────────────────

PROVIDER=""
MULTI_MODE=""  # empty = auto (multi if 2+ available), "single" = first-success only
DIFF_REF=""
FILES=""
INPUT_MODE="stdin"  # stdin | diff | files

while [[ $# -gt 0 ]]; do
  case $1 in
    --provider)  PROVIDER="$2"; shift 2 ;;
    --multi)     MULTI_MODE="multi"; shift ;;
    --single)    MULTI_MODE="single"; shift ;;
    --diff)      DIFF_REF="$2"; INPUT_MODE="diff"; shift 2 ;;
    --files)     FILES="$2"; INPUT_MODE="files"; shift 2 ;;
    --model)     OLLAMA_MODEL="$2"; shift 2 ;;
    --help|-h)
      echo "Usage: adversarial-review.sh [--provider P] [--multi|--single] [--diff REF] [--files \"f1 f2\"] [--model M]"
      echo ""
      echo "Modes:"
      echo "  (default)   Multi-provider: run ALL available providers for maximum coverage"
      echo "  --single    First-success: stop after the first provider that returns results"
      echo "  --provider  Force a specific provider (gemini, codex, ollama)"
      echo ""
      echo "Pipe a diff via stdin, or use --diff/--files to specify input."
      echo ""
      echo "Environment variables:"
      echo "  ZUVO_REVIEW_PROVIDER   Force a specific provider (gemini, codex, ollama)"
      echo "  ZUVO_OLLAMA_MODEL      Ollama model (default: qwen2.5-coder:32b)"
      echo "  ZUVO_CODEX_MODEL       Codex model override"
      echo "  ZUVO_GEMINI_MODEL      Gemini model override"
      exit 0
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

# Allow env var override
PROVIDER="${PROVIDER:-${ZUVO_REVIEW_PROVIDER:-}}"

# ─── Input collection ───────────────────────────────────────────

collect_input() {
  case "$INPUT_MODE" in
    stdin)
      cat
      ;;
    diff)
      git diff "$DIFF_REF"..HEAD 2>/dev/null || git diff "$DIFF_REF"
      ;;
    files)
      for f in $FILES; do
        echo "=== FILE: $f ==="
        cat "$f" 2>/dev/null || echo "(file not found)"
        echo ""
      done
      ;;
  esac
}

INPUT=$(collect_input)

if [[ -z "$INPUT" ]]; then
  echo "ERROR: No input provided. Pipe a diff or use --diff/--files." >&2
  exit 2
fi

# Truncate very large diffs to avoid token limits (keep first 15K chars)
if [[ ${#INPUT} -gt 15000 ]]; then
  INPUT="${INPUT:0:15000}

... [TRUNCATED — diff exceeds 15K chars. Review focused on first portion.]"
fi

# ─── Review prompt ──────────────────────────────────────────────

REVIEW_PROMPT="You are a hostile code reviewer performing an adversarial review.
The code was written by an AI assistant (Claude). Your job is to find issues that the author's own review process is likely to MISS.

FOCUS ON:
1. Edge cases the author didn't consider (timezone, unicode, concurrent access, empty collections, integer overflow)
2. Assumptions true in tests but false in production (network latency, partial failures, clock skew, out-of-order events)
3. Security paths that bypass the happy path (expired tokens mid-request, TOCTOU races, parameter pollution)
4. Silent failures (catch blocks that swallow errors, promises without rejection handlers, fallbacks that hide data loss)
5. Data integrity issues (partial writes without rollback, cache inconsistency with DB, stale reads after write)
6. Missing validation at boundaries (user input, API responses, deserialized data)
7. Resource leaks (unclosed connections, missing cleanup on error paths, unbounded memory growth)

OUTPUT FORMAT:
For each issue found, report:
  SEVERITY: CRITICAL | WARNING | INFO
  FILE: path:line (if identifiable from the diff)
  ISSUE: One-line description
  ATTACK VECTOR: How this breaks in production
  SUGGESTED FIX: Brief fix description

If no issues found, say: NO ISSUES FOUND.

Do NOT repeat obvious issues that a standard code review would catch (formatting, naming, simple type errors).
Focus on what a DIFFERENT reviewer with DIFFERENT blind spots would find.

--- CODE TO REVIEW ---
$INPUT"

# ─── Provider detection ─────────────────────────────────────────

detect_providers() {
  # Returns space-separated list of available providers in priority order
  local providers=""

  if command -v gemini &>/dev/null; then
    providers="gemini"
  elif command -v npx &>/dev/null && npx --yes @google/gemini-cli --version &>/dev/null 2>&1; then
    providers="gemini-npx"
  fi

  # Codex: check direct command, then macOS app bundle
  if command -v codex &>/dev/null; then
    providers="$providers codex"
  elif [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
    providers="$providers codex-app"
  fi

  if command -v ollama &>/dev/null && curl -s http://localhost:11434/api/tags &>/dev/null; then
    providers="$providers ollama"
  fi

  echo "$providers"
}

if [[ -n "$PROVIDER" ]]; then
  PROVIDERS="$PROVIDER"
else
  PROVIDERS=$(detect_providers)
fi

if [[ -z "$PROVIDERS" ]]; then
  cat >&2 <<'EOF'
ERROR: No cross-provider review tool found.

Install one of these (in order of recommendation):

  1. Gemini CLI (free, recommended):
     npm install -g @google/gemini-cli
     gemini   # first run: login with Google account

  2. Codex CLI (needs ChatGPT sub or API key):
     npm install -g @openai/codex
     codex    # first run: login with ChatGPT

  3. Ollama (free, local, needs GPU):
     curl -fsSL https://ollama.com/install.sh | sh
     ollama pull qwen2.5-coder:32b
EOF
  exit 1
fi

# ─── Provider execution ─────────────────────────────────────────

run_gemini() {
  local model_flag=""
  if [[ -n "$GEMINI_MODEL" ]]; then
    model_flag="--model $GEMINI_MODEL"
  fi

  # -p/--prompt takes the prompt as argument (not stdin)
  # --sandbox for safety
  if command -v gemini &>/dev/null; then
    gemini -p "$REVIEW_PROMPT" --sandbox $model_flag
  else
    npx --yes @google/gemini-cli -p "$REVIEW_PROMPT" --sandbox $model_flag
  fi
}

run_codex() {
  local codex_cmd="codex"
  if ! command -v codex &>/dev/null; then
    codex_cmd="/Applications/Codex.app/Contents/Resources/codex"
  fi

  # Build args as array to prevent injection via CODEX_MODEL
  local -a codex_args=(exec --sandbox read-only)
  if [[ -n "$CODEX_MODEL" ]]; then
    # Sanitize: strip quotes and special chars
    local safe_model="${CODEX_MODEL//[\"\'\\]/}"
    codex_args+=(-c "model=\"$safe_model\"")
  fi

  echo "$REVIEW_PROMPT" | "$codex_cmd" "${codex_args[@]}" -
}

run_ollama() {
  # Check if preferred model is available, fall back to any available coding model
  local model="$OLLAMA_MODEL"
  if ! ollama list 2>/dev/null | grep -q "$model"; then
    # Try common coding models in order
    for fallback in "qwen2.5-coder:14b" "qwen2.5-coder:7b" "mistral-small" "mistral"; do
      if ollama list 2>/dev/null | grep -q "$fallback"; then
        echo "  NOTE: $model not found, using $fallback" >&2
        model="$fallback"
        break
      fi
    done
    # If still not found, try to pull the preferred model
    if ! ollama list 2>/dev/null | grep -q "$model"; then
      echo "  Pulling $model (first run only)..." >&2
      ollama pull "$model" >&2
    fi
  fi

  echo "$REVIEW_PROMPT" | ollama run "$model" --nowordwrap 2>/dev/null
}

# ─── Determine mode ────────────────────────────────────────────

# If --provider is set, always single. Otherwise: default is multi.
if [[ -n "$PROVIDER" ]]; then
  MULTI_MODE="single"
elif [[ -z "$MULTI_MODE" ]]; then
  MULTI_MODE="multi"
fi

# ─── Execute ───────────────────────────────────────────────────

echo "CROSS-PROVIDER REVIEW" >&2
echo "  Input: ${#INPUT} chars" >&2
echo "  Mode: $MULTI_MODE" >&2

run_provider() {
  local p="$1"
  case "$p" in
    gemini|gemini-npx) run_gemini 2>/dev/null ;;
    codex|codex-app)   run_codex 2>/dev/null ;;
    ollama)            run_ollama 2>/dev/null ;;
    *) return 1 ;;
  esac
}

display_name() {
  local p="$1"
  p="${p/gemini-npx/gemini}"
  p="${p/codex-app/codex}"
  echo "$p"
}

ALL_RESULTS=""
PROVIDERS_USED=""
PROVIDER_COUNT=0

for p in $PROVIDERS; do
  local_display=$(display_name "$p")
  echo "  Running: $local_display..." >&2

  RESULT=$(run_provider "$p") || true

  if [[ -n "$RESULT" ]]; then
    PROVIDER_COUNT=$((PROVIDER_COUNT + 1))
    PROVIDERS_USED="${PROVIDERS_USED:+$PROVIDERS_USED, }$local_display"

    if [[ "$MULTI_MODE" == "multi" ]]; then
      # Accumulate results from all providers
      upper_display=$(echo "$local_display" | tr '[:lower:]' '[:upper:]')
      ALL_RESULTS="${ALL_RESULTS}

###############################################################
###   REVIEW BY: ${upper_display}
###############################################################

$RESULT
"
    else
      # Single mode: stop at first success
      ALL_RESULTS="$RESULT"
      break
    fi
  else
    echo "  WARN: $local_display failed or returned empty." >&2
  fi
done

if [[ -z "$ALL_RESULTS" ]]; then
  echo "ERROR: All providers failed. Tried: $PROVIDERS" >&2
  exit 2
fi

# ─── Output ─────────────────────────────────────────────────────

cat <<HEADER
===============================================================
CROSS-PROVIDER ADVERSARIAL REVIEW
===============================================================
Providers: $PROVIDERS_USED ($PROVIDER_COUNT total)
Input size: ${#INPUT} chars
Date: $(date -u +%Y-%m-%dT%H:%M:%SZ)
===============================================================
$ALL_RESULTS
===============================================================
END OF CROSS-PROVIDER REVIEW
===============================================================
HEADER
