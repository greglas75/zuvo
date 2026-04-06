# Adversarial Review Parallel Dispatch — Design Specification

> **spec_id:** 2026-04-06-adversarial-parallel-dispatch-0349
> **topic:** Parallel provider dispatch in adversarial-review.sh
> **status:** Approved
> **created_at:** 2026-04-06T03:49:09Z
> **approved_at:** 2026-04-06T03:49:09Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

The `--multi` mode in `scripts/adversarial-review.sh` does not work. When multiple providers run in parallel via bash background subshells, `run_codex_mcp()` breaks because it contains nested background processes (a pipe subshell + polling loop inside a function that is itself backgrounded). This causes zombie processes, empty output, and 50+ orphan `codex mcp-server` processes.

Additionally:
- `gemini-fast` (highest-priority provider) is broken (OAuth scope insufficient) — wastes 5-10s on every auto-detect run
- `ollama` is too slow (3-10min) for practical use
- Gemini CLI loads 5 MCP servers on startup (~20-25s) when it could run without them (~11s)
- No Claude provider exists, despite being the most natural cross-model adversarial reviewer
- `adversarial-loop.md` has an outdated provider list (includes deleted `cursor`, omits fast providers)

If we do nothing, adversarial reviews remain limited to single-provider sequential dispatch via Agent tool. Multi-provider diversity (the core value proposition) requires manual orchestration.

## Design Decisions

### DD-1: Hybrid approach (fix both script and caller path)

**Chosen:** Make every provider function synchronous (zero internal background processes), then implement a simplified `--multi` mode using `timeout` + `wait`. Callers can still use Agent tool dispatch with `--single --provider X`.

**Why:** Fixing `run_codex_mcp()` to be synchronous is needed regardless (improves reliability in `--single` too). A working `--multi` gives standalone capability (CI, terminal, non-Claude environments) without losing the existing Agent tool pattern.

**Rejected alternatives:**
- (A) Fix only `--multi` — same result but doesn't address the root cause (nested backgrounds)
- (B) Deprecate `--multi` — loses standalone/CI capability

### DD-2: Provider roster

**Chosen:** 5 providers in priority order:

| # | Provider | Method | Est. time | Requires |
|---|----------|--------|-----------|----------|
| 1 | codex-fast | `codex exec` + empty CODEX_HOME (0 MCP) | 4.5-23s | codex binary |
| 2 | gemini | CLI + `--allowed-mcp-server-names __NONE__` | 11s | gemini CLI |
| 3 | claude | CLI `--print` + opposite model | 10-30s | claude binary |
| 4 | gemini-api | curl + API key | 15-60s | `GEMINI_API_KEY` |
| 5 | codex-mcp | JSON-RPC stdio (fixed, synchronous) | 25-30s | codex + mcp-server |

**Removed:** `gemini-fast` (broken OAuth), `ollama` (too slow), `run_codex()` (old exec fallback), `cursor` (deleted in e8cedff)

### DD-3: Claude opposite model logic

**Chosen:** Detect current model from `CLAUDE_MODEL` env var. If opus → use `claude-sonnet-4-6`. If sonnet or unknown → use `claude-opus-4-6`. This ensures the adversarial reviewer has a different "perspective" than the agent that wrote the code.

### DD-4: Gemini model

**Chosen:** `gemini-3.1-pro-preview` for both `gemini` (CLI) and `gemini-api` (curl) providers.

### DD-5: Simplified `--multi` mode

**Chosen:** Replace the polling-loop multi-mode with:
```
for each provider:
    timeout $TIMEOUT run_PROVIDER > $tmpdir/result_$provider.txt &
    PIDS+=($!)
wait for all PIDs
collect results from files
```

No polling loop. No per-provider kill logic. `timeout` handles process tree cleanup. One `wait` at the end. EXIT trap kills any stragglers.

### DD-6: Unified dispatch function

**Chosen:** Merge the duplicated `case` statements (one in `--multi`, one in `--single`) into a single `dispatch_provider()` function used by both paths.

## Solution Overview

```
adversarial-review.sh
├── collect_input()          — stdin / --diff / --files → truncated text
├── detect_providers()       — probe binaries + env vars, return priority list
├── Provider functions       — ALL synchronous blocking calls:
│   ├── run_codex_fast()     — CODEX_HOME=$(mktemp -d) codex exec
│   ├── run_gemini()         — gemini --allowed-mcp-server-names __NONE__ -p
│   ├── run_claude()         — echo | claude --model $opposite --print
│   ├── run_gemini_api()     — curl + GEMINI_API_KEY
│   └── run_codex_mcp()     — timeout + synchronous pipe (no polling)
├── dispatch_provider()      — single case statement mapping name → function
├── --single mode            — sequential: dispatch_provider until first success
└── --multi mode             — parallel: timeout + dispatch_provider & per provider, wait
```

Data flow:
```
Input → Truncation → Language detection → Prompt assembly
  → [--single] dispatch_provider(P1) || dispatch_provider(P2) || ...
  → [--multi]  timeout dispatch_provider(P1) &
                timeout dispatch_provider(P2) &
                wait → collect all results
  → Output (text/JSON)
```

## Detailed Design

### Provider Functions

All provider functions follow the same contract:
- **Input:** reads `$REVIEW_PROMPT` (global, assembled before dispatch)
- **Output:** writes review text to stdout
- **Return:** 0 on success, 1 on failure
- **Side effects:** temp files created inside `$JSON_TMPDIR` only (shared cleanup)
- **Background processes:** ZERO internal/nested backgrounds — the function itself never spawns `&` jobs. The caller (multi-mode or Agent tool) may background the entire function call, but that is one level only

#### `run_codex_fast()` (NEW)

```bash
run_codex_fast() {
  local codex_cmd
  codex_cmd=$(command -v codex || echo "/Applications/Codex.app/Contents/Resources/codex")
  local tmp_home
  tmp_home="$JSON_TMPDIR/codex_home"
  mkdir -p "$tmp_home"

  CODEX_HOME="$tmp_home" timeout "$PROVIDER_TIMEOUT" \
    "$codex_cmd" exec --sandbox read-only --model gpt-5.4 \
    -m "$REVIEW_PROMPT" 2>/dev/null || return 1
}
```

#### `run_claude()` (NEW)

```bash
run_claude() {
  local model
  if [[ "${CLAUDE_MODEL:-}" == *opus* ]]; then
    model="claude-sonnet-4-6"
  else
    model="claude-opus-4-6"
  fi

  printf '%s' "$REVIEW_PROMPT" \
    | timeout "$PROVIDER_TIMEOUT" claude --model "$model" --print --output-format text 2>/dev/null \
    || return 1
}
```

#### `run_gemini()` (MODIFIED)

```bash
run_gemini() {
  local prompt_file="$JSON_TMPDIR/gemini_prompt.txt"
  printf '%s' "$REVIEW_PROMPT" > "$prompt_file"

  timeout "$PROVIDER_TIMEOUT" gemini \
    --allowed-mcp-server-names __NONE__ \
    --model gemini-3.1-pro-preview \
    -p < "$prompt_file" 2>/dev/null || return 1
}
```

Note: prompt passed via stdin only (`< "$prompt_file"`). The `-p` flag enables non-interactive/headless mode without requiring an inline argument.

#### `run_gemini_api()` (MODIFIED — model default update)

Existing curl implementation. Change the default model from `gemini-3-flash-preview` to `gemini-3.1-pro-preview`. Preserve the `ZUVO_GEMINI_API_MODEL` env-var override so users can still force a specific model:

```bash
local model="${ZUVO_GEMINI_API_MODEL:-gemini-3.1-pro-preview}"
```

#### `run_codex_mcp()` (FIXED)

```bash
run_codex_mcp() {
  local codex_cmd
  codex_cmd=$(command -v codex || echo "/Applications/Codex.app/Contents/Resources/codex")
  # ... build init_msg, call_msg as before ...

  local mcp_output="$JSON_TMPDIR/codex_mcp_output.txt"

  timeout "$PROVIDER_TIMEOUT" bash -c '
    printf "%s\n" "$1"
    sleep 1
    printf "%s\n" "$2"
    sleep 300
  ' _ "$init_msg" "$call_msg" \
    | "$codex_cmd" mcp-server > "$mcp_output" 2>/dev/null || true

  local text
  text=$(jq -r 'select(.id == 2) | .result.content[0].text // empty' "$mcp_output" 2>/dev/null)
  [[ -z "$text" ]] && return 1
  printf '%s\n' "$text"
}
```

Key change: no `&`, no `pipe_pid`, no polling loop. `timeout` kills the entire pipeline on deadline.

### Dispatch Function

```bash
dispatch_provider() {
  local provider="$1"
  case "$provider" in
    codex-fast)  run_codex_fast ;;
    gemini)      run_gemini ;;
    claude)      run_claude ;;
    gemini-api)  run_gemini_api ;;
    codex-mcp)   run_codex_mcp ;;
    *) return 1 ;;
  esac
}
```

Used by both `--single` and `--multi` paths. Eliminates the duplicated `case` statements.

### Multi-mode Dispatch

```bash
# --multi mode (inside run_multi() function)
run_multi() {
  declare -A RESULTS=()

  for p in $PROVIDERS; do
    (
      result=$(dispatch_provider "$p") || exit 1
      printf '%s' "$result" > "$JSON_TMPDIR/result_${p}.txt"
    ) &
    PIDS+=($!)
  done

  # Wait for all — timeout is per-provider (inside each provider function)
  for pid in "${PIDS[@]}"; do
    wait "$pid" 2>/dev/null || true
  done

  # Collect results from files
  for p in $PROVIDERS; do
    local result_file="$JSON_TMPDIR/result_${p}.txt"
    if [[ -s "$result_file" ]]; then
      RESULTS["$p"]=$(cat "$result_file")
    fi
  done

  # Build ALL_RESULTS_JSON from RESULTS associative array
  ALL_RESULTS_JSON="{}"
  for p in "${!RESULTS[@]}"; do
    ALL_RESULTS_JSON=$(printf '%s' "$ALL_RESULTS_JSON" \
      | jq --arg k "$p" --arg v "${RESULTS[$p]}" '. + {($k): $v}')
  done
}
```

### EXIT Trap

```bash
JSON_TMPDIR=$(mktemp -d)
declare -a PIDS=()
cleanup() {
  [[ ${#PIDS[@]} -gt 0 ]] && kill "${PIDS[@]}" 2>/dev/null
  wait 2>/dev/null
  rm -rf "$JSON_TMPDIR"
}
trap cleanup EXIT INT TERM
```

### detect_providers()

```bash
detect_providers() {
  local providers=""

  # 1. codex-fast
  if command -v codex &>/dev/null || [[ -x "/Applications/Codex.app/Contents/Resources/codex" ]]; then
    providers="codex-fast"
  fi

  # 2. gemini CLI
  if command -v gemini &>/dev/null; then
    providers="$providers gemini"
  fi

  # 3. claude CLI
  if command -v claude &>/dev/null; then
    providers="$providers claude"
  fi

  # 4. gemini-api
  if [[ -n "${GEMINI_API_KEY:-}" ]]; then
    providers="$providers gemini-api"
  fi

  # 5. codex-mcp
  local codex_bin
  codex_bin=$(command -v codex || echo "/Applications/Codex.app/Contents/Resources/codex")
  # Intentional literal 5s (not PROVIDER_TIMEOUT — this is a startup probe, not a review)
  if timeout 5 "$codex_bin" mcp-server --help &>/dev/null; then
    providers="$providers codex-mcp"
  fi

  echo "$providers"
}
```

### JSON Output

Replace `echo`-based JSON construction with `jq`:

```bash
jq -n \
  --arg providers "$PROVIDERS_USED" \
  --arg mode "$REVIEW_MODE" \
  --argjson results "$ALL_RESULTS_JSON" \
  '{providers: $providers, mode: $mode, results: $results}'
```

### adversarial-loop.md Update

Update provider list from `gemini, codex-app, cursor` to:
```
codex-fast, gemini, claude, gemini-api, codex-mcp
```

Also update the Agent dispatch commands (lines ~83-85) that reference `--provider {RANDOM_PROVIDER}` — these draw from the stale list and must use the new provider names.

Remove `cursor` reference (deleted in e8cedff) and `codex-app` (replaced by `codex-fast`).

### skills/review/SKILL.md Update

Update adversarial dispatch commands (lines ~702-703) to use new provider names. Remove `--provider codex-app` and `--provider cursor` references.

### Files to Delete

- `scripts/gemini-fast.sh` — broken OAuth reuse, fully replaced by `gemini-api` and optimized `gemini` CLI
- All references to `run_gemini_fast()` in `adversarial-review.sh`
- All references to `run_ollama()` in `adversarial-review.sh`
- All references to `run_codex()` (old exec fallback) in `adversarial-review.sh`

## Acceptance Criteria

1. `--multi` with `codex-fast` + `gemini` both available: both produce non-empty output, no zombie processes after exit
2. If one provider hangs in `--multi`, others still complete. No orphan processes remain.
3. All temp files cleaned on exit (normal, SIGINT, SIGTERM)
4. Background PIDs killed in EXIT trap
5. Script exits within `PROVIDER_TIMEOUT + 10s` under all conditions
6. `gemini-fast` and `ollama` fully removed from codebase
7. `detect_providers()` probes `codex mcp-server` with `timeout 5`
8. `--json` output is always valid JSON (built with `jq`)
9. `adversarial-loop.md` provider list matches actual providers
10. `run_claude()` uses opposite model (opus→sonnet, sonnet→opus)
11. `run_gemini()` uses `--allowed-mcp-server-names __NONE__` and model `gemini-3.1-pro-preview`
12. `run_codex_fast()` uses empty `CODEX_HOME` (0 MCP servers)
13. Single `dispatch_provider()` function used by both `--single` and `--multi` (no duplicate case)

## Out of Scope

- Exit code differentiation (0=clean, 3=CRITICAL) — separate task
- Hash-based dedup/cache (1h TTL) — separate task
- Bats tests for new providers — separate task
- Phase 2 adversarial loop rollout (execute, write-e2e, refactor) — separate task
- Finding/dedup across multi-provider results — separate task

## Open Questions

None — all questions resolved in Phase 2.
