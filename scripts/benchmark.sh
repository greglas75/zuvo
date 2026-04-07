#!/usr/bin/env bash
# benchmark.sh — Multi-provider AI coding benchmark runner
#
# Dispatches a task to multiple AI providers in parallel, collects responses,
# and writes raw results to a JSON file for the zuvo:benchmark skill to judge.
#
# Usage:
#   ./scripts/benchmark.sh --mode corpus [OPTIONS]
#   ./scripts/benchmark.sh --task "Write an OrderService..." [OPTIONS]
#   ./scripts/benchmark.sh --files "src/auth.ts" [OPTIONS]
#
# Options:
#   --mode <default|corpus>      Run mode (default: default)
#   --task <text>                Task prompt (default mode)
#   --files <path ...>           Files to read as task input
#   --diff <ref>                 Git diff as task input
#   --with-tests                 Run Round 2: write tests for Round 1 output
#   --with-adversarial           Run adversarial cross-review between rounds
#   --with-static-checks         Run tsc + jest on generated code
#   --providers <p1,p2,...>      Override provider list
#   --output <path>              Output JSON path (default: /tmp/benchmark-raw.json)
#   --run-id <id>                Run identifier (default: bm-<timestamp>)
#   --dry-run                    Print prompt and providers, don't dispatch
#
# Exit codes:
#   0 — completed successfully
#   1 — argument error
#   2 — no providers available or all providers failed

set -euo pipefail

BENCHMARK_VERSION="2.0"
START_TIME=$(date +%s)
GEMINI_MODEL="${ZUVO_GEMINI_MODEL:-gemini-3.1-pro-preview}"

# ─── Argument parsing ───────────────────────────────────────────

MODE="default"
TASK_TEXT=""
FILES=""
DIFF_REF=""
INPUT_MODE="task"        # task | files | diff | stdin
WITH_TESTS=false
WITH_ADVERSARIAL=false
WITH_TEST_ADVERSARIAL=false
WITH_STATIC_CHECKS=false
PROVIDERS_OVERRIDE=""
OUTPUT_FILE="/tmp/benchmark-raw.json"
RUN_ID="bm-$(date +%Y-%m-%d-%H%M%S)-$$"
DRY_RUN=false
NO_SNAPSHOT=false
SHOW_COSTS=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)             MODE="$2"; shift 2 ;;
    --task)             TASK_TEXT="$2"; INPUT_MODE="task"; shift 2 ;;
    --files)            FILES="$2"; INPUT_MODE="files"; shift 2 ;;
    --diff)             DIFF_REF="$2"; INPUT_MODE="diff"; shift 2 ;;
    --with-tests)       WITH_TESTS=true; shift ;;
    --with-adversarial) WITH_ADVERSARIAL=true; shift ;;
    --with-test-adversarial) WITH_TEST_ADVERSARIAL=true; shift ;;
    --with-static-checks) WITH_STATIC_CHECKS=true; shift ;;
    --providers)        PROVIDERS_OVERRIDE="$2"; shift 2 ;;
    --output)           OUTPUT_FILE="$2"; shift 2 ;;
    --run-id)           RUN_ID="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --no-snapshot)      NO_SNAPSHOT=true; shift ;;
    --show-costs)       SHOW_COSTS=true; shift ;;
    --help|-h)
      grep '^# ' "$0" | sed 's/^# //' | head -25
      exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Cost tables (USD per 1M tokens) ────────────────────────────

declare -A COST_IN=(
  [claude]="3.00"
  [codex-fast]="5.00"
  [gemini]="0.00"
  [gemini-api]="1.25"
  [cursor-agent]="0.00"
)

declare -A COST_OUT=(
  [claude]="15.00"
  [codex-fast]="15.00"
  [gemini]="0.00"
  [gemini-api]="5.00"
  [cursor-agent]="0.00"
)

# ─── Globals ────────────────────────────────────────────────────

JSON_TMPDIR=$(mktemp -d)
declare -a PIDS=()
PROVIDER_TIMEOUT="${ZUVO_REVIEW_TIMEOUT:-240}"

# ─── Cleanup ────────────────────────────────────────────────────

cleanup() {
  [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null || true
  wait 2>/dev/null || true
  rm -rf "$JSON_TMPDIR"
}
trap cleanup EXIT INT TERM

# ─── Input collection ───────────────────────────────────────────

collect_input() {
  case "$INPUT_MODE" in
    task)
      printf '%s' "$TASK_TEXT"
      ;;
    stdin)
      timeout 10 cat || true
      ;;
    diff)
      git diff "$DIFF_REF"..HEAD 2>/dev/null || git diff "$DIFF_REF"
      ;;
    files)
      while IFS= read -r f || [[ -n "$f" ]]; do
        [[ -z "$f" ]] && continue
        echo "=== FILE: $f ==="
        cat "$f" 2>/dev/null || echo "(file not found)"
        echo ""
      done <<< "$FILES"
      ;;
  esac
}

# ─── Provider detection ─────────────────────────────────────────

detect_providers() {
  local providers=""

  local codex_bin=""
  if command -v codex &>/dev/null; then
    codex_bin="codex"
  elif [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
    codex_bin="/Applications/Codex.app/Contents/Resources/codex"
  fi
  [[ -n "$codex_bin" ]] && providers="codex-fast"

  command -v gemini &>/dev/null && providers="${providers:+$providers }gemini"
  command -v cursor-agent &>/dev/null && providers="${providers:+$providers }cursor-agent"
  command -v claude &>/dev/null && providers="${providers:+$providers }claude"

  echo "$providers"
}

# ─── Provider execution ─────────────────────────────────────────

run_codex_fast() {
  local codex_cmd
  codex_cmd=$(command -v codex || echo "/Applications/Codex.app/Contents/Resources/codex")
  local real_home="${CODEX_HOME:-$HOME/.codex}"
  local tmp_home="$JSON_TMPDIR/codex_home_fast"
  mkdir -p "$tmp_home"

  [[ -f "$real_home/auth.json" ]] && cp "$real_home/auth.json" "$tmp_home/"
  printf 'model = "gpt-5.4"\n' > "$tmp_home/config.toml"

  local err_file="$JSON_TMPDIR/err_codex-fast.txt"
  printf '%s' "$TASK_PROMPT" \
    | CODEX_HOME="$tmp_home" timeout "$PROVIDER_TIMEOUT" \
      "$codex_cmd" exec --sandbox read-only 2>"$err_file" \
    || {
      local exit_code=$?
      [[ $exit_code -eq 124 ]] && echo "PROVIDER_STATUS:TIMEOUT" >&2 || echo "PROVIDER_STATUS:ERROR" >&2
      return 1
    }
}

run_claude() {
  local model
  if [[ "${CLAUDE_MODEL:-}" == *opus* ]]; then
    model="claude-sonnet-4-6"
  else
    model="claude-opus-4-6"
  fi

  local err_file="$JSON_TMPDIR/err_claude.txt"
  printf '%s' "$TASK_PROMPT" \
    | timeout "$PROVIDER_TIMEOUT" claude --model "$model" --print --output-format text 2>"$err_file" \
    || {
      local exit_code=$?
      [[ $exit_code -eq 124 ]] && echo "PROVIDER_STATUS:TIMEOUT" >&2 || echo "PROVIDER_STATUS:ERROR" >&2
      return 1
    }
}

run_cursor_agent() {
  local err_file="$JSON_TMPDIR/err_cursor-agent.txt"
  printf '%s' "$TASK_PROMPT" \
    | timeout "$PROVIDER_TIMEOUT" cursor-agent -p --mode ask --trust --workspace /tmp 2>"$err_file" \
    || {
      local exit_code=$?
      [[ $exit_code -eq 124 ]] && echo "PROVIDER_STATUS:TIMEOUT" >&2 || echo "PROVIDER_STATUS:ERROR" >&2
      return 1
    }
}

run_gemini() {
  local model="${ZUVO_GEMINI_MODEL:-gemini-3.1-pro-preview}"
  local prompt_file="$JSON_TMPDIR/gemini_prompt.txt"
  printf '%s\n' "$TASK_PROMPT" > "$prompt_file"

  local err_file="$JSON_TMPDIR/err_gemini.txt"
  local result status=0
  result=$(timeout "$PROVIDER_TIMEOUT" gemini \
    --allowed-mcp-server-names __NONE__ \
    --model "$model" \
    -p "" < "$prompt_file" 2>"$err_file") || status=$?

  if [[ $status -ne 0 || -z "$result" ]]; then
    [[ $status -eq 124 ]] && echo "PROVIDER_STATUS:TIMEOUT" >&2 || echo "PROVIDER_STATUS:ERROR" >&2
    return 1
  fi
  printf '%s\n' "$result"
}

run_gemini_api() {
  [[ -z "${GEMINI_API_KEY:-}" ]] && return 1

  local model
  model=$(printf '%s' "${ZUVO_GEMINI_API_MODEL:-gemini-3.1-pro-preview}" | tr -cd 'a-zA-Z0-9._-')

  local payload_file="$JSON_TMPDIR/gemini_api_payload.json"
  printf '%s' "$TASK_PROMPT" | jq -Rs '{contents:[{parts:[{text:.}]}]}' > "$payload_file"

  local err_file="$JSON_TMPDIR/err_gemini-api.txt"
  local response status=0
  response=$(curl -sf --max-time "$PROVIDER_TIMEOUT" \
    "https://generativelanguage.googleapis.com/v1beta/models/${model}:generateContent" \
    -H "x-goog-api-key: $GEMINI_API_KEY" \
    -H "Content-Type: application/json" \
    -d @"$payload_file" \
    2>"$err_file") || status=$?

  if [[ $status -ne 0 || -z "$response" ]]; then
    [[ $status -eq 124 ]] && echo "PROVIDER_STATUS:TIMEOUT" >&2 || echo "PROVIDER_STATUS:ERROR" >&2
    return 1
  fi

  local text
  text=$(printf '%s' "$response" | jq -r '.candidates[0].content.parts[0].text // empty')
  [[ -z "$text" ]] && return 1
  printf '%s\n' "$text"
}

dispatch_provider() {
  local provider="$1"
  case "$provider" in
    codex-fast)    run_codex_fast ;;
    cursor-agent)  run_cursor_agent ;;
    gemini)        run_gemini ;;
    claude)        run_claude ;;
    gemini-api)    run_gemini_api ;;
    *) echo "ERROR: Unknown provider: $provider" >&2; return 1 ;;
  esac
}

# ─── Provider availability ──────────────────────────────────────

if [[ -n "$PROVIDERS_OVERRIDE" ]]; then
  PROVIDERS=$(echo "$PROVIDERS_OVERRIDE" | tr ',' ' ')
else
  PROVIDERS=$(detect_providers)
fi

if [[ -z "$PROVIDERS" ]]; then
  cat >&2 <<'EOF'
ERROR: No providers available.

Install one of these:

  1. Codex CLI:   npm install -g @openai/codex && codex
  2. Gemini CLI:  npm install -g @google/gemini-cli && gemini
  3. Claude CLI:  already installed if you use Claude Code
  4. Gemini API:  export GEMINI_API_KEY=<key>
EOF
  exit 2
fi

# ─── Accounting functions ───────────────────────────────────────
# (filled in Task 3)

estimate_tokens() {
  # Estimate token count from a file: word count × 1.3
  # Returns integer with "~estimated" suffix to flag non-exact counts
  local file="$1"
  local words
  words=$(awk '{words += NF} END {print int(words * 1.3)}' "$file" 2>/dev/null || echo "0")
  printf '%s~estimated' "$words"
}

extract_self_eval_score() {
  # Parse SELF_EVAL_SUMMARY block from provider response file
  # Returns null if block missing or malformed
  local file="$1"
  [[ ! -f "$file" ]] && echo "null" && return

  local block
  block=$(awk '/^SELF_EVAL_SUMMARY/{found=1; next} found && /^[A-Za-z]/{print; count++} count==2{exit}' "$file" 2>/dev/null)
  [[ -z "$block" ]] && echo "null" && return

  local scores=()
  while IFS= read -r line; do
    local score
    score=$(printf '%s' "$line" | grep -oE '[0-9]+/20' | head -1 | cut -d/ -f1) || true
    [[ -n "$score" ]] && scores+=("$score")
  done <<< "$block"

  if [[ ${#scores[@]} -eq 0 ]]; then
    echo "null"
  else
    local sum=0
    for s in "${scores[@]}"; do sum=$((sum + s)); done
    printf '%s' "$((sum / ${#scores[@]}))"
  fi
}

calc_cost() {
  # Calculate USD cost from provider name + token counts
  # Returns 0.0000 for unknown providers or when bc unavailable
  local provider="$1" tokens_in="$2" tokens_out="$3"
  tokens_in=$(printf '%s' "$tokens_in" | tr -d '~estimated' | grep -oE '[0-9]+' || echo "0")
  tokens_out=$(printf '%s' "$tokens_out" | tr -d '~estimated' | grep -oE '[0-9]+' || echo "0")

  local rate_in="${COST_IN[$provider]:-0.00}"
  local rate_out="${COST_OUT[$provider]:-0.00}"

  if command -v bc &>/dev/null; then
    printf '%.6f' "$(bc -l <<< "($tokens_in * $rate_in / 1000000) + ($tokens_out * $rate_out / 1000000)")"
  else
    echo "null"
  fi
}

run_static_checks_ts() {
  # Run tsc --noEmit on extracted TypeScript from provider response
  # Returns true/false/null
  local file="$1"
  command -v tsc &>/dev/null || { echo "null"; return; }

  local ts_file="$JSON_TMPDIR/static_check_$$.ts"
  awk '/^```typescript/{found=1; next} found && /^```/{exit} found{print}' "$file" > "$ts_file" 2>/dev/null
  [[ ! -s "$ts_file" ]] && { echo "null"; return; }

  if tsc --noEmit --strict "$ts_file" &>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

run_static_checks_jest() {
  # Run jest --passWithNoTests on extracted test file from provider response
  # Returns true/false/null
  local file="$1"
  command -v jest &>/dev/null || { echo "null"; return; }

  local test_file="$JSON_TMPDIR/static_check_$$.test.ts"
  awk '/^```typescript/{found=1; next} found && /^```/{exit} found{print}' "$file" > "$test_file" 2>/dev/null
  [[ ! -s "$test_file" ]] && { echo "null"; return; }

  if jest --passWithNoTests --testPathPattern "$test_file" &>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

# ─── Preflight ──────────────────────────────────────────────────

command -v timeout &>/dev/null || { echo "ERROR: GNU timeout required. Install: brew install coreutils" >&2; exit 1; }
command -v jq &>/dev/null || { echo "ERROR: jq required. Install: brew install jq" >&2; exit 1; }

# ─── Load corpus task if mode=corpus ────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS_CODE_TASK="$SCRIPT_DIR/../shared/includes/benchmark-corpus/task-code.md"
CORPUS_TEST_TASK="$SCRIPT_DIR/../shared/includes/benchmark-corpus/task-tests.md"

if [[ "$MODE" == "corpus" ]]; then
  [[ -f "$CORPUS_CODE_TASK" ]] || { echo "ERROR: Corpus task file not found: $CORPUS_CODE_TASK" >&2; exit 1; }
  TASK_TEXT=$(cat "$CORPUS_CODE_TASK")
  INPUT_MODE="task"
fi

# ─── Collect task input ─────────────────────────────────────────

TASK_PROMPT=$(collect_input)

if [[ -z "$TASK_PROMPT" ]]; then
  echo "ERROR: No task input. Use --task, --files, --diff, or --mode corpus." >&2
  exit 1
fi

# ─── Compute task hash + snapshot ───────────────────────────────

TASK_HASH=$(printf '%s' "$TASK_PROMPT" | shasum -a 256 | awk '{print $1}')
if [[ "$NO_SNAPSHOT" == "true" ]]; then
  TASK_SNAPSHOT="[suppressed via --no-snapshot]"
else
  TASK_SNAPSHOT="${TASK_PROMPT:0:30000}"
fi
TASK_SNAPSHOT_TRUNCATED=$( [[ "${#TASK_PROMPT}" -gt 30000 ]] && echo "true" || echo "false" )

# ─── Dry run ────────────────────────────────────────────────────

if [[ "$DRY_RUN" == "true" ]]; then
  echo "=== DRY RUN ===" >&2
  echo "Mode: $MODE | Providers: $PROVIDERS" >&2
  echo "With tests: $WITH_TESTS | Adversarial: $WITH_ADVERSARIAL | Static: $WITH_STATIC_CHECKS" >&2
  echo "Task hash: ${TASK_HASH:0:8} | Prompt: ${#TASK_PROMPT} chars" >&2
  printf '%s\n' "$TASK_PROMPT"
  exit 0
fi

# ─── Show costs and exit ────────────────────────────────────────

if [[ "${SHOW_COSTS:-false}" == "true" ]]; then
  printf '| %-14s | %10s | %11s |\n' "Provider" "$/M in" "$/M out"
  printf '|%s|%s|%s|\n' "----------------" "------------" "-------------"
  for p in codex-fast claude gemini gemini-api cursor-agent; do
    printf '| %-14s | %10s | %11s |\n' "$p" "${COST_IN[$p]:-0.00}" "${COST_OUT[$p]:-0.00}"
  done
  exit 0
fi

# ─── Main execution loop ────────────────────────────────────────

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

echo "BENCHMARK START" >&2
echo "  Run ID: $RUN_ID" >&2
echo "  Mode: $MODE" >&2
echo "  Providers: $PROVIDERS" >&2
echo "  Task hash: ${TASK_HASH:0:8}" >&2

declare -a PROVIDER_ARRAY=()
for p in $PROVIDERS; do PROVIDER_ARRAY+=("$p"); done

# ── Parallel dispatch with per-provider timing ──────────────────

for p in "${PROVIDER_ARRAY[@]}"; do
  outfile="$JSON_TMPDIR/result_${p}.txt"
  timefile="$JSON_TMPDIR/time_${p}.txt"
  statusfile="$JSON_TMPDIR/status_${p}.txt"
  printf 'scored' > "$statusfile"

  echo "  Launching: $p..." >&2

  (
    time_start=$(date +%s)
    dispatch_provider "$p" > "$outfile" 2>/dev/null
    dispatch_exit=$?
    time_end=$(date +%s)
    response_time_s=$((time_end - time_start))
    printf '%d' "$response_time_s" > "$timefile"
    if [[ $dispatch_exit -eq 124 ]]; then
      printf 'timeout' > "$statusfile"
    elif [[ $dispatch_exit -ne 0 ]]; then
      printf 'error' > "$statusfile"
    fi
  ) &
  PIDS+=($!)
done

# Wait for all providers
for pid in "${PIDS[@]}"; do
  wait $pid 2>/dev/null || true
done

# ── Collect results and assemble per-provider JSON ──────────────

PROVIDERS_SUCCEEDED=()
ALL_RESULTS_JSON="[]"

for p in "${PROVIDER_ARRAY[@]}"; do
  outfile="$JSON_TMPDIR/result_${p}.txt"
  timefile="$JSON_TMPDIR/time_${p}.txt"
  statusfile="$JSON_TMPDIR/status_${p}.txt"
  result_json_file="$JSON_TMPDIR/result_${p}.json"

  status=$(cat "$statusfile" 2>/dev/null || echo "error")
  response_time_s=$(cat "$timefile" 2>/dev/null || echo "0")

  if [[ -s "$outfile" && "$status" == "scored" ]]; then
    PROVIDERS_SUCCEEDED+=("$p")
    echo "  Done: $p (${response_time_s}s)" >&2
  else
    echo "  WARN: $p — status: $status (${response_time_s}s)" >&2
  fi

  # Estimate tokens from response
  tokens_out=$(estimate_tokens "$outfile")
  tokens_in=$(printf '%s' "$TASK_PROMPT" | wc -w | awk '{printf "%d~estimated", int($1 * 1.3)}')

  # Static checks (if requested)
  compile_ok="null"
  tests_pass="null"
  if [[ "$WITH_STATIC_CHECKS" == "true" ]]; then
    compile_ok=$(run_static_checks_ts "$outfile")
    tests_pass=$(run_static_checks_jest "$outfile")
  fi

  # Self-eval score
  self_eval_raw=$(extract_self_eval_score "$outfile")

  # Response excerpt (first 500 chars)
  response_excerpt=""
  if [[ -s "$outfile" ]]; then
    response_excerpt=$(head -c 500 "$outfile")
  fi

  jq -n \
    --arg provider "$p" \
    --arg status "$status" \
    --argjson response_time_s "$response_time_s" \
    --arg tokens_in "$tokens_in" \
    --arg tokens_out "$tokens_out" \
    --argjson compile_ok "$compile_ok" \
    --argjson tests_pass "$tests_pass" \
    --argjson self_eval_raw "$self_eval_raw" \
    --arg response_excerpt "$response_excerpt" \
    '{
      provider: $provider,
      status: $status,
      response_time_s: $response_time_s,
      tokens_in: $tokens_in,
      tokens_out: $tokens_out,
      compile_ok: $compile_ok,
      tests_pass: $tests_pass,
      self_eval_raw: $self_eval_raw,
      response_excerpt: $response_excerpt
    }' > "$result_json_file"
done

# ── CQ6: fail if no providers succeeded ────────────────────────

if [[ ${#PROVIDERS_SUCCEEDED[@]} -eq 0 ]]; then
  echo "ERROR: All providers failed. No results to score." >&2
  exit 3
fi

# ── Assemble raw_results.json ───────────────────────────────────

PROVIDERS_ATTEMPTED_JSON=$(printf '"%s",' "${PROVIDER_ARRAY[@]}" | sed 's/,$//')
PROVIDERS_SUCCEEDED_JSON=$(printf '"%s",' "${PROVIDERS_SUCCEEDED[@]}" | sed 's/,$//')

# Combine per-provider result JSONs into array
RAW_RESULTS_FILE="$JSON_TMPDIR/raw_results.json"
jq -s '.' "$JSON_TMPDIR"/result_*.json > "$RAW_RESULTS_FILE" 2>/dev/null || echo "[]" > "$RAW_RESULTS_FILE"

jq -n \
  --arg version "$BENCHMARK_VERSION" \
  --arg run_id "$RUN_ID" \
  --arg timestamp "$TIMESTAMP" \
  --arg project "$PROJECT" \
  --arg mode "$MODE" \
  --arg task_source "${MODE:-user}" \
  --arg task_hash "$TASK_HASH" \
  --arg task_snapshot "$TASK_SNAPSHOT" \
  --argjson task_snapshot_truncated "$TASK_SNAPSHOT_TRUNCATED" \
  --argjson with_tests "$WITH_TESTS" \
  --argjson with_adversarial "$WITH_ADVERSARIAL" \
  --argjson with_test_adversarial "$WITH_TEST_ADVERSARIAL" \
  --argjson with_static_checks "$WITH_STATIC_CHECKS" \
  --argjson providers_raw "$(cat "$RAW_RESULTS_FILE")" \
  '{
    version: $version,
    run_id: $run_id,
    timestamp: $timestamp,
    project: $project,
    mode: $mode,
    task_source: $task_source,
    task_hash: $task_hash,
    task_snapshot: $task_snapshot,
    task_snapshot_truncated: $task_snapshot_truncated,
    options: {
      with_tests: $with_tests,
      with_adversarial: $with_adversarial,
      with_test_adversarial: $with_test_adversarial,
      with_static_checks: $with_static_checks
    },
    providers_raw: $providers_raw
  }' > "$OUTPUT_FILE"

echo "  Output: $OUTPUT_FILE" >&2
echo "BENCHMARK DONE" >&2
exit 0
