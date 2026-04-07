# Implementation Plan: zuvo:benchmark

**Spec:** docs/specs/2026-04-07-benchmark-spec.md
**spec_id:** 2026-04-07-benchmark-0634
**plan_revision:** 1
**status:** Reviewed
**Created:** 2026-04-07
**Tasks:** 7
**Estimated complexity:** 3 standard + 4 complex

---

## Architecture Summary

- **benchmark.sh** — raw bash executor (~450 lines): copies 8 provider functions from adversarial-review.sh, adds timing wrappers, token accounting, self-eval score parsing (grep SELF_EVAL_SUMMARY), optional static checks (tsc/jest), cost calculation. Outputs `/tmp/raw_results.json`. No LLM calls.
- **skills/benchmark/SKILL.md** — markdown orchestrator (~250 lines): argument parsing, calls benchmark.sh, invokes Claude meta-judge (opposite-model selection), assembles leaderboard, persists to `audit-results/`, logs to `~/.zuvo/runs.log`.
- **Corpus task files** — fixed prompts in `shared/includes/benchmark-corpus/` for OrderService + useSearchProducts (task-code.md) and test writing (task-tests.md).
- **Modified files**: `skills/using-zuvo/SKILL.md` (1 routing row after line 75), `.claude-plugin/plugin.json` ("45 skills" → "46 skills"), `docs/skills.md` (add benchmark row).

---

## Technical Decisions

- benchmark.sh copies (not imports) 8 functions from adversarial-review.sh: `collect_input`, `detect_providers`, `run_claude`, `run_codex_fast`, `run_cursor_agent`, `run_gemini`, `run_gemini_api`, `dispatch_provider`, PID tracking + cleanup trap.
- Meta-judge uses opposite-model selection (logic from adversarial-review.sh lines 513–517): if `$CLAUDE_MODEL` contains "opus" → use `claude-sonnet-4-6`; else → use `claude-opus-4-6`.
- Token estimation: `wc -w × 1.3` when provider doesn't expose token counts; flagged with `~` prefix in output.
- Cost table: hardcoded bash associative arrays in benchmark.sh.
- Static checks (tsc, jest): optional/best-effort — null if tools not in PATH, never block.
- Self-eval: grep `SELF_EVAL_SUMMARY` block from provider output; null if missing.
- Leaderboard sort: quality DESC, time_s ASC, cost_usd ASC (default mode); (code_score+test_score)/2 DESC in corpus mode.
- No new external dependencies. Requires: timeout, jq, git (already required by adversarial-review.sh).

---

## Quality Strategy

**Active CQ gates:**
- CQ3 (Validation) — benchmark.sh validates task input, provider list, meta-judge JSON response before use
- CQ5 (Null safety) — self_eval_score, compile_ok, tests_pass all nullable; handled explicitly
- CQ6 (Unbounded data) — meta-judge input truncated to 80K / provider_count chars
- CQ8 (Error handling) — provider timeout (exit 124), API error, all-providers-fail → explicit status codes
- CQ22 (Cleanup) — cleanup trap kills PIDs and removes `$JSON_TMPDIR` on EXIT/INT/TERM

**Test approach:** bash integration tests in `tests/benchmark-suite/` using `tests/seo-suite/assert.sh`. Tests verify file contracts (content patterns), function behavior (source benchmark.sh + call functions with mock input), and skill structure (SKILL.md argument table, phase markers, output blocks).

**Risk areas:**
1. Meta-judge JSON parsing — validate with `jq .` before use; run UNSCORED if parse fails
2. Provider dispatch silent failures — capture exit code 124 (timeout) explicitly
3. Self-eval parsing fragility — define exact format in corpus task files
4. Corpus multi-round state — use defined tmpdir structure: `round1_{p}.txt`, `round1_fixed_{p}.txt`, `round3_{p}.txt`

---

## Task Breakdown

### Task 1: Corpus task files + output schema
**Files:**
- NEW `shared/includes/benchmark-corpus/task-code.md`
- NEW `shared/includes/benchmark-corpus/task-tests.md`
- NEW `shared/includes/benchmark-output-schema.md`
- NEW `tests/benchmark-suite/test-benchmark-schema.sh`

**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: Write `tests/benchmark-suite/test-benchmark-schema.sh`:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "$0")/../seo-suite/assert.sh"
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  assert_file_exists "$ROOT/shared/includes/benchmark-corpus/task-code.md"
  assert_file_exists "$ROOT/shared/includes/benchmark-corpus/task-tests.md"
  assert_file_exists "$ROOT/shared/includes/benchmark-output-schema.md"
  assert_contains "$ROOT/shared/includes/benchmark-corpus/task-code.md" "OrderService"
  assert_contains "$ROOT/shared/includes/benchmark-corpus/task-code.md" "useSearchProducts"
  assert_contains "$ROOT/shared/includes/benchmark-corpus/task-code.md" "SELF_EVAL_SUMMARY"
  assert_contains "$ROOT/shared/includes/benchmark-corpus/task-tests.md" "TEST_EVAL_SUMMARY"
  assert_contains "$ROOT/shared/includes/benchmark-output-schema.md" "leaderboard"
  assert_contains "$ROOT/shared/includes/benchmark-output-schema.md" "scorecards"
  assert_contains "$ROOT/shared/includes/benchmark-output-schema.md" "code_composite"
  assert_contains "$ROOT/shared/includes/benchmark-output-schema.md" "self_eval_bias"
  assert_contains "$ROOT/shared/includes/benchmark-output-schema.md" "adversarial_delta"
  pass "Schema and corpus task contracts verified"
  ```
- [ ] GREEN: Create the 3 files:
  - `task-code.md`: Full OrderService.ts + useSearchProducts.ts prompt from spec Section "Corpus Tasks". Must end with `SELF_EVAL_SUMMARY\nOrderService: <score>/20\nuseSearchProducts: <score>/20` block template.
  - `task-tests.md`: Test writing prompt from spec. Must end with `TEST_EVAL_SUMMARY\nFile count: N\nTest count: N` block template.
  - `benchmark-output-schema.md`: Document all JSON fields from spec Data Model section (version, run_id, mode, options, leaderboard[], scorecards{}, self_eval_bias, adversarial_delta, compile_ok, tests_pass, meta_judge_model).
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-schema.sh`
  Expected: `PASS: Schema and corpus task contracts verified`
- [ ] Acceptance: spec AC16 (corpus task files exist)
- [ ] Commit: `add benchmark corpus task files and output schema`

---

### Task 2: benchmark.sh — skeleton + provider dispatch
**Files:**
- NEW `scripts/benchmark.sh`
- NEW `tests/benchmark-suite/test-benchmark-providers.sh`

**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: Write `tests/benchmark-suite/test-benchmark-providers.sh`:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "$0")/../seo-suite/assert.sh"
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  SCRIPT="$ROOT/scripts/benchmark.sh"
  assert_file_exists "$SCRIPT"
  # Is executable
  [ -x "$SCRIPT" ] || fail "benchmark.sh is not executable"
  # Has shebang
  assert_contains "$SCRIPT" "#!/usr/bin/env bash"
  # Has copied core functions
  assert_contains "$SCRIPT" "collect_input()"
  assert_contains "$SCRIPT" "detect_providers()"
  assert_contains "$SCRIPT" "dispatch_provider()"
  assert_contains "$SCRIPT" "run_claude()"
  assert_contains "$SCRIPT" "run_codex_fast()"
  assert_contains "$SCRIPT" "run_gemini()"
  assert_contains "$SCRIPT" "run_gemini_api()"
  assert_contains "$SCRIPT" "run_cursor_agent()"
  # Has cleanup trap
  assert_contains "$SCRIPT" "trap cleanup EXIT"
  # Has timeout config
  assert_contains "$SCRIPT" "PROVIDER_TIMEOUT"
  # Has 0-providers guard
  assert_contains "$SCRIPT" "No providers available"
  # Has cost table
  assert_contains "$SCRIPT" "COST_IN"
  assert_contains "$SCRIPT" "COST_OUT"
  pass "benchmark.sh provider dispatch contracts verified"
  ```
- [ ] GREEN: Create `scripts/benchmark.sh` with:
  - `#!/usr/bin/env bash` + `set -euo pipefail`
  - Global vars: `BENCHMARK_VERSION`, `JSON_TMPDIR=$(mktemp -d)`, `declare -a PIDS=()`, `PROVIDER_TIMEOUT="${ZUVO_REVIEW_TIMEOUT:-240}"`
  - Cost tables: `declare -A COST_IN=([claude]="3.00" [gemini]="0.00" [codex-fast]="5.00" [gemini-api]="1.25" [cursor-agent]="0.00")` and `COST_OUT`
  - Cleanup function: kills all PIDS, removes JSON_TMPDIR; `trap cleanup EXIT INT TERM`
  - **Copy verbatim** from adversarial-review.sh: `collect_input()` (lines 99–118), `detect_providers()` (lines 434–460), `run_codex_fast()` (lines 493–509), `run_claude()` (lines 511–523), `run_cursor_agent()` (lines 525–531), `run_gemini()` (lines 533–555), `run_gemini_api()` (lines 557–588), `dispatch_provider()` (lines 601–611)
  - 0-providers guard: if `detect_providers` returns empty, print install instructions, exit 2
  - CQ8: timeout returns exit code 124 → mark provider status as "TIMEOUT"; other non-zero → "ERROR"
  - CQ22: cleanup trap must run on all exit paths
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-providers.sh`
  Expected: `PASS: benchmark.sh provider dispatch contracts verified`
- [ ] Acceptance: spec AC2 (parallel dispatch), AC9 (0-providers exit), AC18 (--files and --diff work via collect_input)
- [ ] Commit: `add benchmark.sh skeleton with provider dispatch copied from adversarial-review.sh`

---

### Task 3: benchmark.sh — accounting functions
**Files:**
- MODIFY `scripts/benchmark.sh`
- NEW `tests/benchmark-suite/test-benchmark-accounting.sh`

**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default implementation tier

- [ ] RED: Write `tests/benchmark-suite/test-benchmark-accounting.sh`:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "$0")/../seo-suite/assert.sh"
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  SCRIPT="$ROOT/scripts/benchmark.sh"
  assert_contains "$SCRIPT" "estimate_tokens()"
  assert_contains "$SCRIPT" "extract_self_eval_score()"
  assert_contains "$SCRIPT" "calc_cost()"
  assert_contains "$SCRIPT" "run_static_checks_ts()"
  assert_contains "$SCRIPT" "run_static_checks_jest()"
  # Token estimation uses 1.3 multiplier
  assert_contains "$SCRIPT" "1.3"
  # Self-eval parses SELF_EVAL_SUMMARY block
  assert_contains "$SCRIPT" "SELF_EVAL_SUMMARY"
  # Token estimates flagged with ~
  assert_contains "$SCRIPT" "~estimated"
  # Static checks graceful if not in PATH
  assert_contains "$SCRIPT" "command -v tsc"
  assert_contains "$SCRIPT" "command -v jest"
  pass "benchmark.sh accounting functions verified"
  ```
- [ ] GREEN: Add to `scripts/benchmark.sh`:
  - `estimate_tokens(file)`: `awk '{words += NF} END {print int(words * 1.3)}' "$1"` — returns estimated token count
  - `extract_self_eval_score(response_file)`: grep for `SELF_EVAL_SUMMARY` block, extract numeric scores (OrderService + useSearchProducts), average to 0–20 range; return `null` if block missing or malformed
  - `calc_cost(provider, tokens_in, tokens_out)`: `bc` arithmetic using COST_IN/COST_OUT tables; return `0.0000` for unknown provider
  - `run_static_checks_ts(response_file)`: extract code block from response, write to tmp .ts file, run `tsc --noEmit` if available; return `true`/`false`/`null`
  - `run_static_checks_jest(response_file)`: extract test block from response, write to tmp .test.ts file, run `jest --passWithNoTests` if available; return `true`/`false`/`null` + test count
  - CQ5: all functions return `null` (not empty string) when unable to compute
  - CQ8: `command -v tsc`, `command -v jest` guards — never block on missing tool
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-accounting.sh`
  Expected: `PASS: benchmark.sh accounting functions verified`
- [ ] Acceptance: spec AC14 (self_eval_bias via SELF_EVAL_SUMMARY parsing), AC15 (static checks), AC19 (token estimates flagged ~estimated)
- [ ] Commit: `add benchmark.sh token accounting, cost calculation, self-eval parser, static checks`

---

### Task 4: benchmark.sh — main execution loop + JSON output
**Files:**
- MODIFY `scripts/benchmark.sh`
- NEW `tests/benchmark-suite/test-benchmark-execution.sh`

**Complexity:** complex
**Dependencies:** Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Write `tests/benchmark-suite/test-benchmark-execution.sh`:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "$0")/../seo-suite/assert.sh"
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  SCRIPT="$ROOT/scripts/benchmark.sh"
  assert_contains "$SCRIPT" "raw_results.json"
  # Has parallel execution loop
  assert_contains "$SCRIPT" "PIDS+="
  assert_contains "$SCRIPT" "wait \$pid"
  # Has per-provider timing
  assert_contains "$SCRIPT" "time_start"
  assert_contains "$SCRIPT" "response_time_s"
  # Has JSON assembly with jq
  assert_contains "$SCRIPT" "jq -n"
  # Has --show-costs flag
  assert_contains "$SCRIPT" "show-costs"
  # Has all exit codes documented
  assert_contains "$SCRIPT" "exit 0"
  assert_contains "$SCRIPT" "exit 1"
  assert_contains "$SCRIPT" "exit 2"
  pass "benchmark.sh execution loop contracts verified"
  ```
- [ ] GREEN: Add to `scripts/benchmark.sh`:
  - Main execution loop: `for provider in $PROVIDERS; do ( ... ) & PIDS+=($!) done; for pid in ${PIDS[@]}; do wait $pid || true; done`
  - Per-provider timing: `time_start=$(date +%s%N)` before dispatch, `time_end=$(date +%s%N)` after; `response_time_s=$(( ($time_end - $time_start) / 1000000000 ))`
  - Each provider subshell: call `dispatch_provider`, capture response + exit code, call accounting functions, serialize with `jq -n` to `$JSON_TMPDIR/result_{provider}.json`
  - JSON assembly: `jq -s '.' "$JSON_TMPDIR"/result_*.json > "$JSON_TMPDIR/raw_results.json"` then `cat "$JSON_TMPDIR/raw_results.json"` to stdout
  - `--show-costs` flag: print COST_IN/COST_OUT tables as formatted markdown and exit 0 (no benchmark run)
  - Exit codes: 0 (success), 1 (no input), 2 (no providers), 3 (all providers failed)
  - CQ3: validate task input not empty before dispatch
  - CQ6: if no providers succeed → exit 3 with error message
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-execution.sh`
  Expected: `PASS: benchmark.sh execution loop contracts verified`
- [ ] Acceptance: spec AC1 (runs by default on git diff HEAD~1 via collect_input), AC20 (--show-costs)
- [ ] Commit: `add benchmark.sh main execution loop, JSON output, and --show-costs`

---

### Task 5: SKILL.md — default mode (phases 0–4)
**Files:**
- NEW `skills/benchmark/SKILL.md`
- NEW `tests/benchmark-suite/test-benchmark-skill-contract.sh`

**Complexity:** complex
**Dependencies:** Tasks 1, 2, 4
**Execution routing:** deep implementation tier

- [ ] RED: Write `tests/benchmark-suite/test-benchmark-skill-contract.sh`:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "$0")/../seo-suite/assert.sh"
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  SKILL="$ROOT/skills/benchmark/SKILL.md"
  assert_file_exists "$SKILL"
  # Frontmatter
  assert_contains "$SKILL" "name: benchmark"
  # Argument table has all flags
  assert_contains "$SKILL" "--diff"
  assert_contains "$SKILL" "--files"
  assert_contains "$SKILL" "--prompt"
  assert_contains "$SKILL" "--provider"
  assert_contains "$SKILL" "--show-costs"
  assert_contains "$SKILL" "--compare"
  assert_contains "$SKILL" "--replay-last"
  assert_contains "$SKILL" "--json"
  # Phase markers
  assert_contains "$SKILL" "Phase 0"
  assert_contains "$SKILL" "Phase 1"
  assert_contains "$SKILL" "Phase 2"
  assert_contains "$SKILL" "Phase 3"
  assert_contains "$SKILL" "Phase 4"
  # Meta-judge opposite-model selection
  assert_contains "$SKILL" "opus"
  assert_contains "$SKILL" "sonnet"
  assert_contains "$SKILL" "opposite"
  # Output block
  assert_contains "$SKILL" "BENCHMARK COMPLETE"
  # Run log
  assert_contains "$SKILL" "Run:"
  # Compare flag
  assert_contains "$SKILL" "--compare"
  # Schema reference
  assert_contains "$SKILL" "benchmark-output-schema"
  pass "SKILL.md default mode contract verified"
  ```
- [ ] GREEN: Create `skills/benchmark/SKILL.md` with:
  - YAML frontmatter: `name: benchmark`, `description: ...`
  - Mandatory file loading checklist: `benchmark-output-schema.md`, `run-logger.md`, `env-compat.md`
  - Argument parsing table (all 9 flags from spec)
  - Phase 0: parse args; validate `--with-tests`/`--with-adversarial` require `--mode corpus`; `--show-costs` exits immediately; 0-providers exits with instructions
  - Phase 1: call `scripts/benchmark.sh` with parsed args; save stdout to `tmp/raw_results.json`
  - Phase 2 (meta-judge): load `tmp/raw_results.json`; shuffle provider order; build meta-judge prompt (completeness/accuracy/actionability/no_hallucinations 0–10); opposite-model selection (if CLAUDE_MODEL contains "opus" → sonnet, else → opus); single Claude call; parse JSON; compute `composite = (c+a+act+nh)/4`; compute `self_eval_bias = self_eval_score_normalized − composite`; if parse fails → mark run UNSCORED, proceed; CQ6: truncate each response to `80000 / provider_count` chars before prompt
  - Phase 3: assemble leaderboard — rank by quality DESC, time_s ASC, cost_usd ASC; per-provider scorecard (subscores + 300-char response excerpt)
  - Phase 4: auto-increment NNN suffix for audit-results/ output; write `.md` (human) + `.json` (machine, schema v2.0); log to `~/.zuvo/runs.log` (11-field TSV); print `BENCHMARK COMPLETE` output block
  - `--compare [id1] [id2]`: load two run JSONs from audit-results/, print delta table (quality, time, cost per provider); warn if task sources differ
  - `--replay-last`: load last run JSON, re-use `task_snapshot` as input; error if no history; error if corpus mode
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-skill-contract.sh`
  Expected: `PASS: SKILL.md default mode contract verified`
- [ ] Acceptance: spec AC1–AC9, AC17, AC20 (all default mode must-haves)
- [ ] Commit: `add benchmark SKILL.md with default mode, meta-judge scoring, and leaderboard`

---

### Task 6: SKILL.md — corpus mode (phases 1–8)
**Files:**
- MODIFY `skills/benchmark/SKILL.md`
- MODIFY `tests/benchmark-suite/test-benchmark-skill-contract.sh` (add corpus assertions)

**Complexity:** complex
**Dependencies:** Task 5
**Execution routing:** deep implementation tier

- [ ] RED: Extend `tests/benchmark-suite/test-benchmark-skill-contract.sh` with:
  ```bash
  # Corpus mode flags
  assert_contains "$SKILL" "--mode corpus"
  assert_contains "$SKILL" "--with-tests"
  assert_contains "$SKILL" "--with-adversarial"
  assert_contains "$SKILL" "--with-static-checks"
  # Multi-round phases
  assert_contains "$SKILL" "Round 1"
  assert_contains "$SKILL" "Round 3"
  assert_contains "$SKILL" "adversarial"
  # Corpus task file references
  assert_contains "$SKILL" "benchmark-corpus/task-code.md"
  assert_contains "$SKILL" "benchmark-corpus/task-tests.md"
  # Extended leaderboard columns
  assert_contains "$SKILL" "code_score"
  assert_contains "$SKILL" "test_score"
  assert_contains "$SKILL" "compile_ok"
  assert_contains "$SKILL" "tests_pass"
  assert_contains "$SKILL" "self_eval_bias"
  assert_contains "$SKILL" "adversarial_delta"
  # Multi-round tmpdir structure
  assert_contains "$SKILL" "round1_"
  assert_contains "$SKILL" "round3_"
  ```
- [ ] GREEN: Extend `skills/benchmark/SKILL.md` corpus phases:
  - Corpus mode phase 1 (code): read `benchmark-corpus/task-code.md`; dispatch to all providers in parallel; each provider output → `tmp/round1_{provider}.txt`; capture self_eval_score
  - Corpus mode phase 2 (static Round 1): if `--with-static-checks`, run `run_static_checks_ts()` on each `tmp/round1_{provider}.txt`; record `compile_ok` per provider
  - Corpus mode phase 3 (adversarial): if `--with-adversarial`, for each provider call `adversarial-review.sh --files tmp/round1_{provider}.txt --json`; count findings (critical/warning/info); provider rewrites code; save to `tmp/round1_fixed_{provider}.txt`; CQ8: if adversarial fails for a provider, continue with unfixed output
  - Corpus mode phase 4 (tests): if `--with-tests`, read `benchmark-corpus/task-tests.md` + prepend Round 1 code as context; dispatch to all providers; save to `tmp/round3_{provider}.txt`
  - Corpus mode phase 5 (static Round 3): if `--with-static-checks`, run `run_static_checks_jest()` on each `tmp/round3_{provider}.txt`; record `tests_pass` + `test_count`
  - Corpus mode phase 6 (meta-judge): single call with all rounds at once; subscores for code_* and test_* separately; compute adversarial_delta = fixed_score − original_score
  - Corpus mode phase 7 (leaderboard): full corpus leaderboard sorted by `(code_score + test_score) / 2 DESC`; show all 10 columns
  - Corpus mode phase 8 (storage): version `2.0` JSON with `mode: corpus`, `options: {...}`, `rounds: {...}` structure per spec Data Model
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-skill-contract.sh`
  Expected: `PASS: SKILL.md default mode contract verified` (same test extended)
- [ ] Acceptance: spec AC10–AC16 (corpus mode must-haves)
- [ ] Commit: `extend benchmark SKILL.md with corpus mode, multi-round execution, and adversarial delta`

---

### Task 7: Wiring — routing table + manifest + docs
**Files:**
- MODIFY `skills/using-zuvo/SKILL.md`
- MODIFY `.claude-plugin/plugin.json`
- MODIFY `docs/skills.md`
- NEW `tests/benchmark-suite/test-benchmark-wiring.sh`

**Complexity:** standard
**Dependencies:** Task 5
**Execution routing:** default implementation tier

- [ ] RED: Write `tests/benchmark-suite/test-benchmark-wiring.sh`:
  ```bash
  #!/usr/bin/env bash
  source "$(dirname "$0")/../seo-suite/assert.sh"
  ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
  assert_contains "$ROOT/skills/using-zuvo/SKILL.md" "zuvo:benchmark"
  assert_contains "$ROOT/.claude-plugin/plugin.json" "46 skills"
  assert_contains "$ROOT/docs/skills.md" "benchmark"
  pass "Benchmark wiring verified (routing + manifest + docs)"
  ```
- [ ] GREEN:
  - `skills/using-zuvo/SKILL.md`: Insert after line 75 (after `| Audit accessibility (WCAG 2.2, ADA, keyboard, contrast) | \`zuvo:a11y-audit\` |`):
    ```
    | Benchmark providers, compare models, measure quality/speed/cost | `zuvo:benchmark` |
    ```
  - `.claude-plugin/plugin.json`: Change `"45 skills"` → `"46 skills"` in the description field (line 3)
  - `docs/skills.md`: Add benchmark row after a11y-audit entry (near line 98). Follow the existing table format: `| \`zuvo:benchmark\` | Multi-provider AI benchmark with meta-judge quality scoring. Runs code/test tasks across all available providers (Claude, Codex, Gemini, Cursor), scores responses on completeness/accuracy/actionability (0-10 composite), and generates a quality/speed/cost leaderboard. Supports corpus mode with adversarial delta and self-eval bias measurement. | Comparing provider quality, measuring adversarial impact, tracking model changes over time | \`--mode corpus\`, \`--with-tests\`, \`--with-adversarial\`, \`--with-static-checks\`, \`--compare [id1] [id2]\`, \`--provider P\` |`
- [ ] Verify: `bash tests/benchmark-suite/test-benchmark-wiring.sh`
  Expected: `PASS: Benchmark wiring verified (routing + manifest + docs)`
- [ ] Acceptance: routing entry present, plugin count accurate
- [ ] Commit: `wire benchmark skill into routing table, plugin manifest, and docs`

---

## Spec Coverage Map

| Spec AC | Task |
|---------|------|
| AC1: runs on `git diff HEAD~1` by default | T5 |
| AC2: all providers in parallel, failed = TIMEOUT/ERROR | T2 |
| AC3: meta-judge scores completeness/accuracy/actionability/no_hallucinations | T5 |
| AC4: leaderboard with rank/quality/time/tokens/cost/status | T5 |
| AC5: per-provider scorecard with breakdown + excerpt | T5 |
| AC6: saved to `audit-results/benchmark-YYYY-MM-DD-NNN.md/.json` | T5 |
| AC7: `--compare` delta table | T5 |
| AC8: run logged to `~/.zuvo/runs.log` | T5 |
| AC9: 0-providers exits with install instructions | T2 |
| AC10: `--mode corpus` runs corpus task-code.md | T6 |
| AC11: `--with-tests` adds Round 3 + test_score | T6 |
| AC12: `--with-adversarial` adds adversarial round + adversarial_delta | T6 |
| AC13: corpus leaderboard has all 10 columns | T6 |
| AC14: self_eval_bias from SELF_EVAL_SUMMARY | T3 |
| AC15: static checks tsc/jest (null if not in PATH) | T3 |
| AC16: corpus task files exist | T1 |
| AC17: `--replay-last` re-runs last diff/files/prompt task | T5 |
| AC18: `--files` and `--diff REF` work | T2 |
| AC19: token estimates flagged `~estimated` | T3 |
| AC20: `--show-costs` prints pricing table | T4 |
