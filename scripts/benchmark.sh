#!/usr/bin/env bash
# benchmark.sh — Multi-provider AI coding benchmark runner (low-level)
#
# Dispatches a task to multiple AI providers in parallel, collects responses,
# and writes raw results to a JSON file for the zuvo:benchmark skill to judge.
#
# This is the runner layer. The skill orchestrator (SKILL.md) handles:
#   --compare, --replay-last (skill-only flags — not accepted here)
#   meta-judge scoring, leaderboard assembly, multi-round corpus flow
#
# Usage:
#   ./scripts/benchmark.sh --mode corpus [OPTIONS]
#   ./scripts/benchmark.sh --task "Write an OrderService..." [OPTIONS]
#   ./scripts/benchmark.sh --files "src/auth.ts" [OPTIONS]
#
# Options:
#   --mode <default|corpus>      Run mode (default: default)
#   --task <text>                Task prompt (default mode)
#   --files <path-or-list>        File path or newline-separated list as task input
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
#   2 — no providers available
#   3 — all providers failed or no results to score

set -euo pipefail

BENCHMARK_VERSION="2.0"

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
JSON_OUTPUT=false
ROUND_DIR=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --mode)             MODE="$2"; shift 2 ;;
    --task|--prompt)    TASK_TEXT="$2"; INPUT_MODE="task"; shift 2 ;;
    --files)            FILES="$2"; INPUT_MODE="files"; shift 2 ;;
    --diff)             DIFF_REF="$2"; INPUT_MODE="diff"; shift 2 ;;
    --with-tests)       WITH_TESTS=true; shift ;;
    --with-adversarial) WITH_ADVERSARIAL=true; shift ;;
    --with-test-adversarial) WITH_TEST_ADVERSARIAL=true; shift ;;
    --with-static-checks) WITH_STATIC_CHECKS=true; shift ;;
    --provider|--providers) PROVIDERS_OVERRIDE="$2"; shift 2 ;;
    --output)           OUTPUT_FILE="$2"; shift 2 ;;
    --run-id)           RUN_ID="$2"; shift 2 ;;
    --round-dir)        ROUND_DIR="$2"; shift 2 ;;
    --dry-run)          DRY_RUN=true; shift ;;
    --no-snapshot)      NO_SNAPSHOT=true; shift ;;
    --show-costs)       SHOW_COSTS=true; shift ;;
    --json)             JSON_OUTPUT=true; shift ;;
    --compare)
      echo "ERROR: --compare requires the zuvo:benchmark skill orchestrator." >&2
      echo "Usage: zuvo:benchmark --compare [id1] [id2]" >&2
      exit 0 ;;
    --replay-last)
      echo "ERROR: --replay-last requires the zuvo:benchmark skill orchestrator." >&2
      echo "Usage: zuvo:benchmark --replay-last" >&2
      exit 0 ;;
    --help|-h)
      grep '^# ' "$0" | sed 's/^# //' | head -25
      exit 0 ;;
    *) echo "ERROR: Unknown option: $1" >&2; exit 1 ;;
  esac
done

# ─── Cost tables (USD per 1M tokens) ────────────────────────────
# Using functions instead of declare -A for bash 3.2 compatibility (macOS stock)

cost_in() {
  case "$1" in
    claude)       echo "3.00"  ;;
    codex-fast)   echo "5.00"  ;;
    gemini)       echo "0.00"  ;;
    gemini-api)   echo "1.25"  ;;
    cursor-agent) echo "0.00"  ;;
    *)            echo "0.00"  ;;
  esac
}

cost_out() {
  case "$1" in
    claude)       echo "15.00" ;;
    codex-fast)   echo "15.00" ;;
    gemini)       echo "0.00"  ;;
    gemini-api)   echo "5.00"  ;;
    cursor-agent) echo "0.00"  ;;
    *)            echo "0.00"  ;;
  esac
}

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

  if command -v gemini &>/dev/null; then
    providers="${providers:+$providers }gemini"
  elif [[ -n "${GEMINI_API_KEY:-}" ]]; then
    # gemini-api as fallback when gemini CLI unavailable but API key is set
    providers="${providers:+$providers }gemini-api"
  fi
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
      "$codex_cmd" exec --sandbox read-only 2>"$err_file"
  # Exit code propagates: 0=success, 124=timeout, other=error
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
    | timeout "$PROVIDER_TIMEOUT" claude --model "$model" --print --output-format text 2>"$err_file"
}

run_cursor_agent() {
  local err_file="$JSON_TMPDIR/err_cursor-agent.txt"
  printf '%s' "$TASK_PROMPT" \
    | timeout "$PROVIDER_TIMEOUT" cursor-agent -p --mode ask --trust --workspace /tmp 2>"$err_file"
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
    return $status
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
    return $status
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

  local rate_in
  rate_in=$(cost_in "$provider")
  local rate_out
  rate_out=$(cost_out "$provider")

  if command -v bc &>/dev/null; then
    printf '%.6f' "$(bc -l <<< "($tokens_in * $rate_in / 1000000) + ($tokens_out * $rate_out / 1000000)")"
  else
    echo "null"
  fi
}

extract_all_ts_blocks() {
  # Extract ALL fenced ```typescript blocks from a file, concatenated
  # Splits by // FILE: markers when present (corpus format)
  local file="$1"
  awk '/^```typescript/{found=1; next} found && /^```/{found=0; next} found{print}' "$file" 2>/dev/null
}

run_static_checks_ts() {
  # Run tsc --noEmit on all TypeScript blocks from provider response
  # Returns true/false/null
  local file="$1"
  command -v tsc &>/dev/null || { echo "null"; return; }

  local ts_file="$JSON_TMPDIR/static_check_$$.ts"
  extract_all_ts_blocks "$file" > "$ts_file"
  [[ ! -s "$ts_file" ]] && { echo "null"; return; }

  if tsc --noEmit --strict "$ts_file" &>/dev/null; then
    echo "true"
  else
    echo "false"
  fi
}

run_static_checks_jest() {
  # Run jest --passWithNoTests on all test blocks from provider response
  # Returns true/false/null
  local file="$1"
  command -v jest &>/dev/null || { echo "null"; return; }

  local test_file="$JSON_TMPDIR/static_check_$$.test.ts"
  extract_all_ts_blocks "$file" > "$test_file"
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

# ─── Show costs and exit (fast path — no task input needed) ─────

if [[ "$SHOW_COSTS" == "true" ]]; then
  printf '| %-14s | %10s | %11s |\n' "Provider" "$/M in" "$/M out"
  printf '|%s|%s|%s|\n' "----------------" "------------" "-------------"
  for p in codex-fast claude gemini gemini-api cursor-agent; do
    printf '| %-14s | %10s | %11s |\n' "$p" "$(cost_in "$p")" "$(cost_out "$p")"
  done
  exit 0
fi

# ─── Load corpus task if mode=corpus ────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CORPUS_CODE_TASK="$SCRIPT_DIR/../shared/includes/benchmark-corpus/task-code.md"
CORPUS_TEST_TASK="$SCRIPT_DIR/../shared/includes/benchmark-corpus/task-tests.md"

if [[ "$MODE" == "corpus" ]]; then
  [[ -f "$CORPUS_CODE_TASK" ]] || { echo "ERROR: Corpus task file not found: $CORPUS_CODE_TASK" >&2; exit 1; }
  TASK_TEXT=$(cat "$CORPUS_CODE_TASK")
  INPUT_MODE="task"
fi

# Default: no input specified → diff HEAD~1
if [[ "$INPUT_MODE" == "task" && -z "$TASK_TEXT" && "$MODE" != "corpus" ]]; then
  INPUT_MODE="diff"
  DIFF_REF="HEAD~1"
fi

# ─── Collect task input ─────────────────────────────────────────

TASK_PROMPT=$(collect_input)

if [[ -z "$TASK_PROMPT" ]]; then
  echo "ERROR: No task input. Use --prompt, --files, --diff, or --mode corpus." >&2
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

# ─── File extraction ────────────────────────────────────────────

extract_code_files() {
  # Extract TypeScript code blocks from response, split by // FILE: markers
  # Saves each file as prefix-Filename.ts in output_dir
  local response_file="$1" output_dir="$2" prefix="$3"
  mkdir -p "$output_dir"
  awk -v outdir="$output_dir" -v prefix="$prefix" '
    /^```typescript/ { in_block=1; next }
    in_block && /^```/ { if (outfile) close(outfile); outfile=""; in_block=0; next }
    in_block && /^\/\/ FILE: / {
      if (outfile) close(outfile)
      fname = $0; sub(/^\/\/ FILE: /, "", fname); gsub(/[^a-zA-Z0-9._-]/, "", fname)
      outfile = outdir "/" prefix "-" fname
      next
    }
    in_block && !outfile {
      outfile = outdir "/" prefix "-code.ts"
    }
    in_block && outfile { print > outfile }
  ' "$response_file" 2>/dev/null
}

# ─── Single-provider dispatch with custom prompt ────────────────

dispatch_single() {
  # Dispatch a custom prompt to one provider, write output to file
  local provider="$1" prompt="$2" outfile="$3"
  TASK_PROMPT="$prompt"
  local time_start time_end
  time_start=$(date +%s)
  dispatch_provider "$provider" > "$outfile" 2>"$JSON_TMPDIR/stderr_${provider}_dispatch.txt"
  local exit_code=$?
  time_end=$(date +%s)
  echo $((time_end - time_start))  # prints elapsed seconds to stdout caller captures
  return $exit_code
}

# ─── Main execution ────────────────────────────────────────────

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)
PROJECT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)

if [[ "$MODE" == "corpus" ]]; then TASK_SOURCE="corpus"
elif [[ "$INPUT_MODE" == "diff" ]]; then TASK_SOURCE="diff"
elif [[ "$INPUT_MODE" == "files" ]]; then TASK_SOURCE="files"
else TASK_SOURCE="user"
fi

# Auto-create round dir for multi-round
if [[ -z "$ROUND_DIR" ]]; then
  ROUND_DIR="/tmp/benchmark-${RUN_ID}"
fi
mkdir -p "$ROUND_DIR"

echo "BENCHMARK START" >&2
echo "  Run ID: $RUN_ID" >&2
echo "  Mode: $MODE | Artifacts: $ROUND_DIR" >&2
echo "  Providers: $PROVIDERS" >&2
echo "  Task hash: ${TASK_HASH:0:8}" >&2

declare -a PROVIDER_ARRAY=()
for p in $PROVIDERS; do PROVIDER_ARRAY+=("$p"); done

ADVERSARIAL_SCRIPT="$SCRIPT_DIR/adversarial-review.sh"

# ═══════════════════════════════════════════════════════════════
#  ROUND 1 — Code generation (parallel)
# ═══════════════════════════════════════════════════════════════

echo "" >&2
echo "── Round 1: Code generation ──────────────────────────" >&2

for p in "${PROVIDER_ARRAY[@]}"; do
  outfile="$JSON_TMPDIR/r1_${p}.txt"
  timefile="$JSON_TMPDIR/time_r1_${p}.txt"
  statusfile="$JSON_TMPDIR/status_${p}.txt"
  printf 'scored' > "$statusfile"
  echo "  R1 launching: $p..." >&2

  (
    time_start=$(date +%s)
    dispatch_provider "$p" > "$outfile" 2>"$JSON_TMPDIR/stderr_r1_${p}.txt"
    dispatch_exit=$?
    time_end=$(date +%s)
    printf '%d' "$((time_end - time_start))" > "$timefile"
    if [[ $dispatch_exit -eq 0 && -s "$outfile" ]]; then
      printf 'scored' > "$statusfile"
    elif [[ $dispatch_exit -eq 124 ]]; then
      printf 'timeout' > "$statusfile"
    else
      printf 'error' > "$statusfile"
    fi
  ) &
  PIDS+=($!)
done

for pid in "${PIDS[@]}"; do wait $pid 2>/dev/null || true; done
PIDS=()

# Collect Round 1 results
PROVIDERS_SUCCEEDED=()
for p in "${PROVIDER_ARRAY[@]}"; do
  status=$(cat "$JSON_TMPDIR/status_${p}.txt" 2>/dev/null || echo "error")
  r1_time=$(cat "$JSON_TMPDIR/time_r1_${p}.txt" 2>/dev/null || echo "0")
  if [[ -s "$JSON_TMPDIR/r1_${p}.txt" && "$status" == "scored" ]]; then
    PROVIDERS_SUCCEEDED+=("$p")
    mkdir -p "$ROUND_DIR/$p"
    cp "$JSON_TMPDIR/r1_${p}.txt" "$ROUND_DIR/$p/r1-response.txt"
    extract_code_files "$ROUND_DIR/$p/r1-response.txt" "$ROUND_DIR/$p" "r1"
    r1_files=$(ls "$ROUND_DIR/$p"/r1-*.ts 2>/dev/null | wc -l | tr -d ' ')
    echo "  R1 done: $p (${r1_time}s, ${r1_files} files extracted)" >&2
  else
    echo "  R1 WARN: $p — $status (${r1_time}s)" >&2
  fi
done

if [[ ${#PROVIDERS_SUCCEEDED[@]} -eq 0 ]]; then
  echo "ERROR: All providers failed Round 1." >&2
  exit 3
fi

# ═══════════════════════════════════════════════════════════════
#  ROUND 2 — Adversarial review + fix (if --with-adversarial)
# ═══════════════════════════════════════════════════════════════

if [[ "$WITH_ADVERSARIAL" == "true" ]]; then
  echo "" >&2
  echo "── Round 2: Adversarial review + fix ───────────────" >&2

  for p in "${PROVIDERS_SUCCEEDED[@]}"; do
    echo "  R2 reviewing: $p..." >&2
    provider_dir="$ROUND_DIR/$p"
    r1_files_list=$(ls "$provider_dir"/r1-*.ts 2>/dev/null | tr '\n' ' ')

    # Get adversarial findings
    findings=""
    if [[ -x "$ADVERSARIAL_SCRIPT" && -n "$r1_files_list" ]]; then
      findings=$("$ADVERSARIAL_SCRIPT" --files "$r1_files_list" --json --single 2>/dev/null) || true
    fi

    if [[ -z "$findings" ]]; then
      echo "  R2 WARN: $p — no adversarial findings (skipping fix)" >&2
      # Copy r1 as r2 (no change)
      for f in "$provider_dir"/r1-*.ts; do
        base=$(basename "$f" | sed 's/^r1-/r2-/')
        cp "$f" "$provider_dir/$base"
      done
      continue
    fi

    # Save findings
    printf '%s\n' "$findings" > "$provider_dir/r2-adversarial-findings.txt"

    # Build code context
    code_context=""
    for f in "$provider_dir"/r1-*.ts; do
      fname=$(basename "$f")
      code_context="${code_context}
=== ${fname} ===
$(cat "$f")
"
    done

    # Build fix prompt
    fix_prompt="You previously wrote this code in a benchmark:

${code_context}

An adversarial review found these issues:

${findings}

Fix all issues found. Output corrected files using fenced \`\`\`typescript blocks with \`// FILE: <filename>\` on the first line of each block. Keep the same filenames."

    # Dispatch fix to same provider
    (
      time_start=$(date +%s)
      TASK_PROMPT="$fix_prompt"
      dispatch_provider "$p" > "$provider_dir/r2-response.txt" 2>"$JSON_TMPDIR/stderr_r2_${p}.txt"
      time_end=$(date +%s)
      printf '%d' "$((time_end - time_start))" > "$JSON_TMPDIR/time_r2_${p}.txt"
    ) &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do wait $pid 2>/dev/null || true; done
  PIDS=()

  # Extract Round 2 files
  for p in "${PROVIDERS_SUCCEEDED[@]}"; do
    provider_dir="$ROUND_DIR/$p"
    if [[ -s "$provider_dir/r2-response.txt" ]]; then
      extract_code_files "$provider_dir/r2-response.txt" "$provider_dir" "r2"
      r2_time=$(cat "$JSON_TMPDIR/time_r2_${p}.txt" 2>/dev/null || echo "?")
      r2_files=$(ls "$provider_dir"/r2-*.ts 2>/dev/null | wc -l | tr -d ' ')
      echo "  R2 done: $p (${r2_time}s, ${r2_files} files)" >&2
    else
      echo "  R2 WARN: $p — fix dispatch failed, keeping r1 files" >&2
      for f in "$provider_dir"/r1-*.ts; do
        base=$(basename "$f" | sed 's/^r1-/r2-/')
        cp "$f" "$provider_dir/$base"
      done
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════
#  ROUND 3 — Write tests (if --with-tests)
# ═══════════════════════════════════════════════════════════════

if [[ "$WITH_TESTS" == "true" ]]; then
  echo "" >&2
  echo "── Round 3: Test generation ────────────────────────" >&2

  # Use best available code: r2 (post-adversarial) or r1 (original)
  code_round="r1"
  [[ "$WITH_ADVERSARIAL" == "true" ]] && code_round="r2"

  for p in "${PROVIDERS_SUCCEEDED[@]}"; do
    provider_dir="$ROUND_DIR/$p"

    # Build code context from latest round files
    code_for_tests=""
    for f in "$provider_dir"/${code_round}-*.ts; do
      [[ -f "$f" ]] || continue
      fname=$(basename "$f")
      code_for_tests="${code_for_tests}
\`\`\`typescript
// FILE: ${fname}
$(cat "$f")
\`\`\`
"
    done

    # Load test task template and interpolate
    test_prompt=$(cat "$CORPUS_TEST_TASK")
    test_prompt="${test_prompt//\{\{ROUND_1_CODE\}\}/$code_for_tests}"

    # Dispatch test task
    (
      time_start=$(date +%s)
      TASK_PROMPT="$test_prompt"
      dispatch_provider "$p" > "$provider_dir/r3-response.txt" 2>"$JSON_TMPDIR/stderr_r3_${p}.txt"
      time_end=$(date +%s)
      printf '%d' "$((time_end - time_start))" > "$JSON_TMPDIR/time_r3_${p}.txt"
    ) &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do wait $pid 2>/dev/null || true; done
  PIDS=()

  # Extract Round 3 test files
  for p in "${PROVIDERS_SUCCEEDED[@]}"; do
    provider_dir="$ROUND_DIR/$p"
    if [[ -s "$provider_dir/r3-response.txt" ]]; then
      extract_code_files "$provider_dir/r3-response.txt" "$provider_dir" "r3"
      r3_time=$(cat "$JSON_TMPDIR/time_r3_${p}.txt" 2>/dev/null || echo "?")
      r3_files=$(ls "$provider_dir"/r3-*.ts 2>/dev/null | wc -l | tr -d ' ')
      echo "  R3 done: $p (${r3_time}s, ${r3_files} test files)" >&2
    else
      echo "  R3 WARN: $p — test dispatch failed" >&2
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════
#  ROUND 4 — Adversarial on tests + fix (if --with-test-adversarial)
# ═══════════════════════════════════════════════════════════════

if [[ "$WITH_TEST_ADVERSARIAL" == "true" && "$WITH_TESTS" == "true" ]]; then
  echo "" >&2
  echo "── Round 4: Adversarial on tests + fix ─────────────" >&2

  for p in "${PROVIDERS_SUCCEEDED[@]}"; do
    provider_dir="$ROUND_DIR/$p"
    r3_files_list=$(ls "$provider_dir"/r3-*.ts 2>/dev/null | tr '\n' ' ')
    [[ -z "$r3_files_list" ]] && continue

    echo "  R4 reviewing: $p..." >&2

    findings=""
    if [[ -x "$ADVERSARIAL_SCRIPT" ]]; then
      findings=$("$ADVERSARIAL_SCRIPT" --files "$r3_files_list" --json --single --mode test 2>/dev/null) || true
    fi

    if [[ -z "$findings" ]]; then
      echo "  R4 WARN: $p — no findings, copying r3 as r4" >&2
      for f in "$provider_dir"/r3-*.ts; do
        base=$(basename "$f" | sed 's/^r3-/r4-/')
        cp "$f" "$provider_dir/$base"
      done
      continue
    fi

    printf '%s\n' "$findings" > "$provider_dir/r4-adversarial-findings.txt"

    test_context=""
    for f in "$provider_dir"/r3-*.ts; do
      fname=$(basename "$f")
      test_context="${test_context}
=== ${fname} ===
$(cat "$f")
"
    done

    fix_prompt="You previously wrote these tests in a benchmark:

${test_context}

An adversarial review found these issues:

${findings}

Fix all issues. Output corrected test files using fenced \`\`\`typescript blocks with \`// FILE: <filename>\` on the first line."

    (
      time_start=$(date +%s)
      TASK_PROMPT="$fix_prompt"
      dispatch_provider "$p" > "$provider_dir/r4-response.txt" 2>"$JSON_TMPDIR/stderr_r4_${p}.txt"
      time_end=$(date +%s)
      printf '%d' "$((time_end - time_start))" > "$JSON_TMPDIR/time_r4_${p}.txt"
    ) &
    PIDS+=($!)
  done

  for pid in "${PIDS[@]}"; do wait $pid 2>/dev/null || true; done
  PIDS=()

  for p in "${PROVIDERS_SUCCEEDED[@]}"; do
    provider_dir="$ROUND_DIR/$p"
    if [[ -s "$provider_dir/r4-response.txt" ]]; then
      extract_code_files "$provider_dir/r4-response.txt" "$provider_dir" "r4"
      r4_time=$(cat "$JSON_TMPDIR/time_r4_${p}.txt" 2>/dev/null || echo "?")
      r4_files=$(ls "$provider_dir"/r4-*.ts 2>/dev/null | wc -l | tr -d ' ')
      echo "  R4 done: $p (${r4_time}s, ${r4_files} files)" >&2
    else
      echo "  R4 WARN: $p — fix failed, keeping r3 files" >&2
      for f in "$provider_dir"/r3-*.ts; do
        base=$(basename "$f" | sed 's/^r3-/r4-/')
        cp "$f" "$provider_dir/$base"
      done
    fi
  done
fi

# ═══════════════════════════════════════════════════════════════
#  COLLECT — per-provider metrics + file inventory
# ═══════════════════════════════════════════════════════════════

echo "" >&2
echo "── Collecting results ─────────────────────────────────" >&2

for p in "${PROVIDER_ARRAY[@]}"; do
  provider_dir="$ROUND_DIR/$p"
  result_json="$JSON_TMPDIR/result_${p}.json"
  status=$(cat "$JSON_TMPDIR/status_${p}.txt" 2>/dev/null || echo "error")
  r1_time=$(cat "$JSON_TMPDIR/time_r1_${p}.txt" 2>/dev/null || echo "0")
  r2_time=$(cat "$JSON_TMPDIR/time_r2_${p}.txt" 2>/dev/null || echo "null")
  r3_time=$(cat "$JSON_TMPDIR/time_r3_${p}.txt" 2>/dev/null || echo "null")
  r4_time=$(cat "$JSON_TMPDIR/time_r4_${p}.txt" 2>/dev/null || echo "null")

  # Self-eval from Round 1
  self_eval_raw="null"
  [[ -f "$JSON_TMPDIR/r1_${p}.txt" ]] && self_eval_raw=$(extract_self_eval_score "$JSON_TMPDIR/r1_${p}.txt")

  # Token estimates
  tokens_in=$(printf '%s' "$TASK_PROMPT" | wc -w | awk '{printf "%d~estimated", int($1 * 1.3)}')
  tokens_out="0~estimated"
  if [[ -f "$JSON_TMPDIR/r1_${p}.txt" ]]; then
    tokens_out=$(estimate_tokens "$JSON_TMPDIR/r1_${p}.txt")
  fi

  # File inventory
  r1_files=$(ls "$provider_dir"/r1-*.ts 2>/dev/null | xargs -I{} basename {} | jq -R . | jq -s . 2>/dev/null || echo "[]")
  r2_files=$(ls "$provider_dir"/r2-*.ts 2>/dev/null | xargs -I{} basename {} | jq -R . | jq -s . 2>/dev/null || echo "[]")
  r3_files=$(ls "$provider_dir"/r3-*.ts 2>/dev/null | xargs -I{} basename {} | jq -R . | jq -s . 2>/dev/null || echo "[]")
  r4_files=$(ls "$provider_dir"/r4-*.ts 2>/dev/null | xargs -I{} basename {} | jq -R . | jq -s . 2>/dev/null || echo "[]")

  # Quote times that might be "null"
  [[ "$r2_time" == "null" ]] && r2_time_json="null" || r2_time_json="$r2_time"
  [[ "$r3_time" == "null" ]] && r3_time_json="null" || r3_time_json="$r3_time"
  [[ "$r4_time" == "null" ]] && r4_time_json="null" || r4_time_json="$r4_time"

  jq -n \
    --arg provider "$p" \
    --arg status "$status" \
    --argjson r1_time_s "$r1_time" \
    --argjson r2_time_s "$r2_time_json" \
    --argjson r3_time_s "$r3_time_json" \
    --argjson r4_time_s "$r4_time_json" \
    --argjson self_eval_raw "$self_eval_raw" \
    --arg tokens_in "$tokens_in" \
    --arg tokens_out "$tokens_out" \
    --argjson r1_files "$r1_files" \
    --argjson r2_files "$r2_files" \
    --argjson r3_files "$r3_files" \
    --argjson r4_files "$r4_files" \
    --arg artifacts_dir "$provider_dir" \
    '{
      provider: $provider,
      status: $status,
      r1_time_s: $r1_time_s,
      r2_time_s: $r2_time_s,
      r3_time_s: $r3_time_s,
      r4_time_s: $r4_time_s,
      self_eval_raw: $self_eval_raw,
      tokens_in: $tokens_in,
      tokens_out: $tokens_out,
      artifacts: {
        dir: $artifacts_dir,
        r1_code: $r1_files,
        r2_fixed: $r2_files,
        r3_tests: $r3_files,
        r4_fixed_tests: $r4_files
      }
    }' > "$result_json"
done

# ═══════════════════════════════════════════════════════════════
#  OUTPUT — assemble final JSON
# ═══════════════════════════════════════════════════════════════

RAW_RESULTS_FILE="$JSON_TMPDIR/raw_results.json"
jq -s '.' "$JSON_TMPDIR"/result_*.json > "$RAW_RESULTS_FILE" 2>/dev/null || echo "[]" > "$RAW_RESULTS_FILE"

jq -n \
  --arg version "$BENCHMARK_VERSION" \
  --arg run_id "$RUN_ID" \
  --arg timestamp "$TIMESTAMP" \
  --arg project "$PROJECT" \
  --arg mode "$MODE" \
  --arg task_source "$TASK_SOURCE" \
  --arg task_hash "$TASK_HASH" \
  --arg task_snapshot "$TASK_SNAPSHOT" \
  --argjson task_snapshot_truncated "$TASK_SNAPSHOT_TRUNCATED" \
  --argjson with_tests "$WITH_TESTS" \
  --argjson with_adversarial "$WITH_ADVERSARIAL" \
  --argjson with_test_adversarial "$WITH_TEST_ADVERSARIAL" \
  --argjson with_static_checks "$WITH_STATIC_CHECKS" \
  --arg round_dir "$ROUND_DIR" \
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
    round_dir: $round_dir,
    providers_raw: $providers_raw
  }' > "$OUTPUT_FILE"

echo "" >&2
echo "  Output JSON: $OUTPUT_FILE" >&2
echo "  Artifacts:   $ROUND_DIR/" >&2

# Print file tree summary
for p in "${PROVIDERS_SUCCEEDED[@]}"; do
  file_count=$(ls "$ROUND_DIR/$p"/*.ts 2>/dev/null | wc -l | tr -d ' ')
  echo "    $p/ — ${file_count} files" >&2
done

if [[ "$JSON_OUTPUT" == "true" ]]; then
  cat "$OUTPUT_FILE"
fi

echo "" >&2
echo "BENCHMARK DONE" >&2
exit 0
