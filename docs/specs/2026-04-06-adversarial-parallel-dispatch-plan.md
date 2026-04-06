# Implementation Plan: Adversarial Review Parallel Dispatch

**Spec:** `docs/specs/2026-04-06-adversarial-parallel-dispatch-spec.md`
**spec_id:** 2026-04-06-adversarial-parallel-dispatch-0349
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-06
**Tasks:** 10
**Estimated complexity:** 8 standard + 2 complex

## Architecture Summary

Single bash script (`scripts/adversarial-review.sh`, 702 lines) with 6 provider functions, single/multi dispatch modes, and echo-based JSON output. Three callers: `adversarial-loop.md` (write-path skills), `cross-provider-review.md` (audit-path skills), `skills/review/SKILL.md` (direct dispatch). One helper script to delete (`scripts/gemini-fast.sh`).

**Component list:**
- `scripts/adversarial-review.sh` — primary target (HIGH risk, 400+ lines touched)
- `shared/includes/adversarial-loop.md` — caller, stale provider list (LOW risk)
- `skills/review/SKILL.md` — caller, stale provider names (LOW risk)
- `scripts/gemini-fast.sh` — to delete
- `scripts/tests/adversarial-review.bats` — test fixes (broken assertions after rename)

**Dependency direction:** Skills → includes → script → provider binaries

## Technical Decisions

- **`timeout` dependency:** GNU coreutils `timeout` required. Add preflight check. Users must `brew install coreutils`.
- **No `declare -A`:** Avoid associative arrays (bash 4+ only, macOS ships 3.2). Collect multi-mode results directly from temp files instead.
- **`ZUVO_GEMINI_MODEL` preserved:** Keep env var override for `run_gemini()` model, with new default `gemini-3.1-pro-preview`.
- **`--model` flag removed:** Only used for ollama (deleted). Remove from arg parser.
- **`display_name()` deleted:** Provider canonical names become display names. No aliasing.
- **`run_gemini()` stdin mode:** Use `gemini -p < "$prompt_file"` (stdin via redirect, `-p` enables headless mode). Verify Gemini CLI supports `-p` without positional arg.

## Quality Strategy

**Activated CQ gates:** CQ3 (validation), CQ8 (error handling/timeouts — core of this PR), CQ14 (duplication elimination)

**Risk areas (ranked):**
1. `timeout` binary absent → hard script failure (mitigated by preflight check)
2. Mock name mismatch in bats tests → false failures (mitigated by updating mocks in Task 10)
3. `run_codex_mcp()` timeout-vs-polling transition → possible orphan `codex mcp-server` (mitigated by `timeout --kill-after=5`)
4. `run_gemini()` `-p` flag semantics vary by CLI version (mitigated by testing)

**Test approach:** Update broken existing tests. Add lightweight bats smoke tests for new providers (mock binary, assert args). New comprehensive provider tests are out of scope per spec.

**File size exception:** `adversarial-review.sh` is currently 702 lines and will remain ~630-670 after net changes (delete ~150 lines, add ~100). This exceeds the 300-line limit but has no natural split point — all provider functions share globals (`$REVIEW_PROMPT`, `$JSON_TMPDIR`, `$PROVIDER_TIMEOUT`). Follow-on task: extract provider functions into a sourced `scripts/providers.sh` helper.

**Spec divergence note:** The spec's `run_multi()` pseudocode uses `declare -A RESULTS=()` (associative array). This plan uses file-based collection instead to maintain bash 3.2 compatibility (macOS ships 3.2). The plan's approach is authoritative; the spec pseudocode is illustrative.

---

## Task Breakdown

### Task 1: Delete dead providers and helper script
**Files:** `scripts/adversarial-review.sh`, `scripts/gemini-fast.sh`
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: Existing tests should still pass after deletions (no test covers deleted functions). Verify with `bats scripts/tests/adversarial-review.bats` — all 64 tests pass before changes.
- [ ] GREEN: Delete from `adversarial-review.sh`:
  - `run_gemini_fast()` (lines ~311-325)
  - `run_ollama()` (lines ~451-471)
  - `run_codex()` (lines ~434-449) — old exec fallback
  - `display_name()` (lines ~528-536)
  - `run_provider()` polling wrapper (lines ~490-526)
  - `gemini-fast` and `ollama` branches in `detect_providers()` 
  - `codex-app` branch in `detect_providers()` (old name)
  - `--model` flag from arg parser (only used for ollama)
  - `ZUVO_OLLAMA_MODEL` variable declaration
  - `gemini-fast` and `ollama` case entries from both dispatch locations
  - Delete `scripts/gemini-fast.sh` entirely
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: All existing tests pass (mocks don't exercise deleted functions)
- [ ] Acceptance: AC-6 (gemini-fast and ollama fully removed)
- [ ] Commit: `remove dead providers: gemini-fast, ollama, codex legacy exec, display_name, run_provider polling wrapper`

### Task 2: Add preflight check and upgrade EXIT trap
**Files:** `scripts/adversarial-review.sh`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default

- [ ] RED: Run `bats scripts/tests/adversarial-review.bats` — confirm current state is green after Task 1.
- [ ] GREEN: Add near top of script (after arg parsing, before `detect_providers`):
  - Preflight: `command -v timeout &>/dev/null || { echo "ERROR: GNU timeout required. Install: brew install coreutils" >&2; exit 1; }`
  - Replace EXIT trap with:
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
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: Tests pass. Add a `timeout` mock to bats test setup (or add `create_mock "timeout" 'exec "$@"'` passthrough) so preflight doesn't block tests.
  Manual SIGINT check: `echo "sleep 30" | ./scripts/adversarial-review.sh --provider gemini & PID=$!; sleep 2; kill -INT $PID; sleep 1; [[ ! -d "$JSON_TMPDIR" ]] && echo "PASS: cleanup on SIGINT"`
- [ ] Acceptance: AC-3 (temp cleanup on SIGINT/SIGTERM), AC-4 (background PIDs killed in EXIT trap), AC-5 (script exits within timeout)
- [ ] Commit: `add timeout preflight check and EXIT trap that kills background PIDs`

### Task 3: Rewrite detect_providers()
**Files:** `scripts/adversarial-review.sh`
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: Existing provider detection tests should still work after rewrite. The mock `codex` binary (rejects `mcp-server`) now maps to `codex-fast` detection.
- [ ] GREEN: Rewrite `detect_providers()` with new priority order:
  1. `codex-fast` — `command -v codex` or Codex.app bundle path
  2. `gemini` — `command -v gemini`
  3. `claude` — `command -v claude`
  4. `gemini-api` — `[[ -n "${GEMINI_API_KEY:-}" ]]`
  5. `codex-mcp` — `timeout 5 "$codex_bin" mcp-server --help &>/dev/null`
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: Provider detection tests pass (mock `codex` binary → detects `codex-fast`)
- [ ] Acceptance: AC-7 (codex mcp-server probe with timeout 5)
- [ ] Commit: `rewrite detect_providers with new priority: codex-fast, gemini, claude, gemini-api, codex-mcp`

### Task 4: Add dispatch_provider() and simplify single-mode
**Files:** `scripts/adversarial-review.sh`
**Complexity:** standard
**Dependencies:** Task 3
**Execution routing:** default

- [ ] RED: Single-mode tests should still work via new dispatch function.
- [ ] GREEN: Create `dispatch_provider()`:
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
  Rewrite `--single` path to use `dispatch_provider` in a loop:
  ```bash
  for p in $PROVIDERS; do
    result=$(dispatch_provider "$p" 2>/dev/null) && [[ -n "$result" ]] && {
      # success — store result, break
      break
    }
  done
  ```
  Stub `run_codex_fast` and `run_claude` as `return 1` (implemented in Tasks 5-6).
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: Single-mode tests pass via dispatch_provider → existing run_gemini/run_gemini_api
- [ ] Acceptance: AC-13 (single dispatch_provider function)
- [ ] Commit: `add unified dispatch_provider, rewrite single-mode dispatch`

### Task 5: Implement run_codex_fast()
**Files:** `scripts/adversarial-review.sh`, `scripts/tests/adversarial-review.bats`
**Complexity:** standard
**Dependencies:** Task 4
**Execution routing:** default
**Note:** Tasks 5, 6, and 7 are independent of each other and can be developed in any order after Task 4.

- [ ] RED: Add bats test: mock `codex` binary that inspects args → assert `CODEX_HOME` env is set, `exec --sandbox read-only` in args, `--model gpt-5.4` in args. Test should fail because `run_codex_fast` is currently a stub.
- [ ] GREEN: Implement `run_codex_fast()`:
  ```bash
  run_codex_fast() {
    local codex_cmd
    codex_cmd=$(command -v codex || echo "/Applications/Codex.app/Contents/Resources/codex")
    local tmp_home="$JSON_TMPDIR/codex_home"
    mkdir -p "$tmp_home"
    CODEX_HOME="$tmp_home" timeout "$PROVIDER_TIMEOUT" \
      "$codex_cmd" exec --sandbox read-only --model gpt-5.4 \
      -m "$REVIEW_PROMPT" 2>/dev/null || return 1
  }
  ```
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: New test passes. Also manual: `echo "test code" | ./scripts/adversarial-review.sh --provider codex-fast`
- [ ] Acceptance: AC-12 (empty CODEX_HOME, 0 MCP servers)
- [ ] Commit: `add codex-fast provider: codex exec with empty CODEX_HOME for zero MCP overhead`

### Task 6: Implement run_claude()
**Files:** `scripts/adversarial-review.sh`, `scripts/tests/adversarial-review.bats`
**Complexity:** standard
**Dependencies:** Task 4
**Execution routing:** default
**Note:** Tasks 5, 6, and 7 are independent — any order after Task 4.

- [ ] RED: Add bats tests:
  - Mock `claude` binary that inspects args → assert `--print --output-format text` in args
  - Test 1: `CLAUDE_MODEL=opus` → assert `--model claude-sonnet-4-6` (inspecting mock)
  - Test 2: `CLAUDE_MODEL=sonnet` → assert `--model claude-opus-4-6`
  - Test 3: `CLAUDE_MODEL` unset → assert `--model claude-opus-4-6` (default)
  Tests should fail because `run_claude` is currently a stub.
- [ ] GREEN: Implement `run_claude()`:
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
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: All 3 opposite-model tests pass.
- [ ] Acceptance: AC-10 (opposite model logic)
- [ ] Commit: `add claude provider with opposite-model adversarial logic`

### Task 7: Modify run_gemini() and run_gemini_api()
**Files:** `scripts/adversarial-review.sh`
**Complexity:** standard
**Dependencies:** Task 4
**Execution routing:** default
**Note:** Tasks 5, 6, and 7 are independent — any order after Task 4.

- [ ] RED: Existing gemini tests should pass after modifications.
- [ ] GREEN:
  - `run_gemini()`: Add `--allowed-mcp-server-names __NONE__` flag. Update model to `gemini-3.1-pro-preview` (with `ZUVO_GEMINI_MODEL` override preserved). Ensure prompt is delivered via stdin with `-p` flag for headless mode.
  - `run_gemini_api()`: Change default model from `gemini-3-flash-preview` to `gemini-3.1-pro-preview`. Keep `ZUVO_GEMINI_API_MODEL` override.
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: Gemini-related tests pass
- [ ] Acceptance: AC-11 (--allowed-mcp-server-names __NONE__, model gemini-3.1-pro-preview)
- [ ] Commit: `optimize gemini: disable MCP servers on CLI, update default model to 3.1-pro-preview`

### Task 8: Fix run_codex_mcp() — remove nested background
**Files:** `scripts/adversarial-review.sh`, `scripts/tests/adversarial-review.bats`
**Complexity:** complex
**Dependencies:** Task 4
**Execution routing:** deep

- [ ] RED: Add bats test: mock `codex` binary that accepts `mcp-server` subcommand, reads stdin, outputs JSON-RPC response with `"id":2` and `"result"` containing review text. Assert the script extracts and prints the review text. Also add a test with a slow mock (sleep 60) + `ZUVO_REVIEW_TIMEOUT=2` → assert no orphan `codex` PIDs remain after exit. Guard: `command -v timeout || skip "GNU timeout required"`.
- [ ] GREEN: Rewrite `run_codex_mcp()` to be synchronous:
  ```bash
  run_codex_mcp() {
    local codex_cmd
    codex_cmd=$(command -v codex || echo "/Applications/Codex.app/Contents/Resources/codex")
    # ... build init_msg, call_msg (preserve existing JSON-RPC message construction) ...
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
  Key: no `&`, no `pipe_pid`, no polling loop. `timeout` kills entire pipeline.
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: New MCP tests pass. Also manual: `echo "test code" | ./scripts/adversarial-review.sh --provider codex-mcp` + `ps aux | grep "codex mcp-server"` shows no orphans.
- [ ] Acceptance: AC-1 (multi-mode works), AC-2 (no zombies)
- [ ] Commit: `fix codex-mcp: replace nested background + polling with synchronous timeout pipe`

### Task 9: Rewrite multi-mode dispatch and JSON output
**Files:** `scripts/adversarial-review.sh`
**Complexity:** complex
**Dependencies:** Tasks 4-8
**Execution routing:** deep

- [ ] RED: Multi-mode tests should work with new dispatch. JSON output should be valid.
- [ ] GREEN:
  - **Multi-mode:** Replace polling-loop dispatch with:
    ```bash
    for p in $PROVIDERS; do
      (
        result=$(dispatch_provider "$p" 2>/dev/null) || exit 1
        printf '%s' "$result" > "$JSON_TMPDIR/result_${p}.txt"
      ) &
      PIDS+=($!)
    done
    for pid in "${PIDS[@]}"; do
      wait "$pid" 2>/dev/null || true
    done
    ```
    Collect results by reading files directly (no `declare -A`):
    ```bash
    ALL_RESULTS="" PROVIDERS_USED="" PROVIDER_COUNT=0
    for p in $PROVIDERS; do
      if [[ -s "$JSON_TMPDIR/result_${p}.txt" ]]; then
        result=$(cat "$JSON_TMPDIR/result_${p}.txt")
        ALL_RESULTS="$ALL_RESULTS${ALL_RESULTS:+$'\n'}### REVIEW BY: $(echo "$p" | tr '[:lower:]' '[:upper:]')$'\n'$result"
        PROVIDERS_USED="$PROVIDERS_USED${PROVIDERS_USED:+, }$p"
        PROVIDER_COUNT=$((PROVIDER_COUNT + 1))
      fi
    done
    ```
  - **JSON output:** Replace echo-based construction with jq:
    ```bash
    if [[ "$OUTPUT_FORMAT" == "json" ]]; then
      json_results="{}"
      for p in $PROVIDERS; do
        if [[ -s "$JSON_TMPDIR/result_${p}.txt" ]]; then
          json_results=$(printf '%s' "$json_results" | jq --arg k "$p" --arg v "$(cat "$JSON_TMPDIR/result_${p}.txt")" '. + {($k): $v}')
        fi
      done
      jq -n \
        --arg mode "$REVIEW_MODE" \
        --arg providers "$PROVIDERS_USED" \
        --argjson count "$PROVIDER_COUNT" \
        --argjson results "$json_results" \
        --argjson input_size "${#INPUT}" \
        --arg date "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        '{mode: $mode, providers_used: $providers, provider_count: $count, input_size: $input_size, date: $date, results: $results}'
    fi
    ```
  - Update help text: remove ollama, add codex-fast, claude. Update env var list.
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: Multi-mode and JSON tests pass. Also manual: `echo "test" | ./scripts/adversarial-review.sh --json`  piped through `jq .` should parse clean.
- [ ] Acceptance: AC-1 (multi works), AC-2 (no zombies), AC-3 (temp cleanup), AC-8 (valid JSON)
- [ ] Commit: `rewrite multi-mode: parallel timeout dispatch, jq-based JSON output, no polling loop`

### Task 10: Update callers and fix broken test assertions
**Files:** `shared/includes/adversarial-loop.md`, `shared/includes/cross-provider-review.md`, `skills/review/SKILL.md`, `scripts/tests/adversarial-review.bats`
**Complexity:** standard
**Dependencies:** Task 9
**Execution routing:** default

- [ ] RED: After Tasks 1-9, some bats tests may fail on mock names (`codex` no longer matches `codex-fast` detection). Callers reference stale provider names.
- [ ] GREEN:
  - **adversarial-loop.md:** Update provider list from `gemini, codex-app, cursor` to `codex-fast, gemini, claude, gemini-api, codex-mcp`. Update Agent dispatch command examples to use new names.
  - **cross-provider-review.md:** Update provider references: remove `ollama` mentions, update env var table (remove `ZUVO_OLLAMA_MODEL`), add `codex-fast` and `claude` to provider list.
  - **skills/review/SKILL.md:** Update TIER dispatch: replace `codex-app` with `codex-fast`, remove `cursor`, add `claude` as third option for TIER 3.
  - **adversarial-review.bats:** Fix broken assertions:
    - Mock binary name stays `codex` (because `detect_providers` probes `command -v codex`), but the detected provider name becomes `codex-fast` — so the display output changes from `"REVIEW BY: CODEX"` to `"REVIEW BY: CODEX-FAST"`
    - Update all `"REVIEW BY: CODEX"` assertions to `"REVIEW BY: CODEX-FAST"`
    - Add `command -v timeout || skip "GNU timeout required"` guard to timeout test
- [ ] Verify: `bats scripts/tests/adversarial-review.bats`
  Expected: All tests pass with updated assertions
- [ ] Acceptance: AC-9 (adversarial-loop.md provider list matches), AC-13 (unified dispatch)
- [ ] Commit: `update callers to new provider names, fix bats assertions for codex-fast rename`
