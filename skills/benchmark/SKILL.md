---
name: benchmark
description: "Multi-provider AI coding benchmark. Dispatches a task to Codex, Gemini, Claude, and Cursor-Agent in parallel, scores responses with a Claude meta-judge, and produces a ranked leaderboard with cost, time, quality, and self-eval bias metrics. Supports corpus mode (fixed OrderService + useSearchProducts tasks) for apples-to-apples comparison across runs."
---

# zuvo:benchmark — Multi-Provider Coding Benchmark

Measures how well different AI coding agents handle a task. Dispatches to all available providers in parallel, collects responses, and uses an opposite-model Claude meta-judge to score on four dimensions (completeness, accuracy, actionability, no_hallucinations). Outputs a ranked leaderboard with cost and time breakdown.

**Use corpus mode (`--mode corpus`) to compare runs across time.** The corpus uses fixed OrderService + useSearchProducts tasks — the same prompt every time — so runs from different days are directly comparable.

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `--diff [ref]` | Benchmark against a git diff (default: HEAD~1) |
| `--files <paths>` | Benchmark on specific files as task input |
| `--prompt <text>` | Use a literal text prompt as the task |
| `--mode corpus` | Use fixed corpus tasks (OrderService + useSearchProducts) |
| `--mode default` | Use user-provided task (default) |
| `--with-tests` | Run Round 2: have providers write tests for their own Round 1 code |
| `--with-adversarial` | Run adversarial cross-review on Round 1 code |
| `--with-test-adversarial` | Run adversarial cross-review on Round 3 tests (requires `--with-tests`) |
| `--with-static-checks` | Run tsc + jest on generated code (best-effort, null if tools missing) |
| `--provider <name>` | Restrict to a single provider (codex-fast, gemini, claude, cursor-agent) |
| `--show-costs` | Print provider cost table ($/M tokens) and exit |
| `--compare [id1] [id2]` | Compare two prior runs from audit-results/; default: last two |
| `--replay-last` | Re-run benchmark with the same task as the most recent run |
| `--json` | Output raw JSON to stdout instead of formatted leaderboard |
| `--no-snapshot` | Suppress task_snapshot storage (use if task contains secrets or PII) |
| `--dry-run` | Print prompt + providers without dispatching |
| _(remaining text)_ | Treated as `--prompt <text>` if no other input flag given |

## Mandatory File Loading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. ../../shared/includes/benchmark-output-schema.md  -- READ/MISSING
  2. ../../shared/includes/run-logger.md               -- READ/MISSING
  3. ../../shared/includes/env-compat.md               -- READ/MISSING
```

If any core file is missing, proceed in degraded mode and note it in the BENCHMARK COMPLETE block.

---

## Phase 0: Parse and Validate Arguments

1. Parse all flags from `$ARGUMENTS` per the table above.

2. `--show-costs`: run `scripts/benchmark.sh --show-costs`, print the table, stop. No benchmark run.

3. `--compare`: load the two specified run JSONs from `audit-results/` (or the last two if no IDs given). Print a delta table: quality, time_s, cost_usd per provider. Warn if task_hash values differ (different tasks, comparison may be misleading). Stop — no benchmark run.

4. `--replay-last`: find the most recent `.json` file in `audit-results/`. Read `task_snapshot` as the task input. Set `INPUT_MODE=prompt`. Error if no history found. Error if `--mode corpus` (corpus uses fixed prompts, replay makes no sense).

5. Validate flag combinations:
   - `--with-tests` and `--with-adversarial` require `--mode corpus` (they assume a two-round structure). If set without `--mode corpus`, print a warning and auto-set `--mode corpus`.
   - `--provider` with a name not in the detected provider list → warn, but don't fail (provider may appear after dispatch attempt).

6. Determine task source:
   - `--mode corpus` → `task_source: "corpus"`, load from `../../shared/includes/benchmark-corpus/task-code.md`
   - `--diff` → `task_source: "diff"`, input via git diff
   - `--files` → `task_source: "files"`, input via file concatenation
   - `--prompt` or remaining text → `task_source: "user"`, input is the literal text
   - None of the above → `task_source: "diff"`, default to `HEAD~1`

7. Print run header:
   ```
   BENCHMARK RUN
   Mode: [default|corpus] | Task: [first 60 chars or "corpus"] | Providers: [list]
   Options: tests=[bool] adversarial=[bool] static=[bool]
   ```

---

## Phase 1: Dispatch Providers

1. Run `scripts/benchmark.sh` with all parsed flags. Capture stdout to `$TMPDIR/benchmark-raw.json`.

   ```bash
   scripts/benchmark.sh \
     --mode <mode> \
     [--task <text>|--files <paths>|--diff <ref>] \
     [--with-tests] [--with-adversarial] [--with-static-checks] \
     [--providers <list>] \
     --run-id <run_id> \
     --output "$TMPDIR/benchmark-raw.json"
   ```

2. Check exit code:
   - `0`: success, proceed to Phase 2
   - `1`: bad arguments → show error and stop
   - `2`: no providers available → show install instructions and stop
   - `3`: all providers failed → show error and stop

3. Print progress as providers complete (read from stderr in real time or wait for script exit):
   ```
   [1/4] claude — done (42s)
   [2/4] gemini — done (31s)
   [3/4] codex-fast — done (28s)
   [4/4] cursor-agent — timeout
   ```

---

## Phase 2: Meta-Judge Scoring

**Never skip this phase.** Even if only one provider succeeded, still score it.

### Model Selection (opposite-model rule)

The judge must be a different model than the one running this skill to reduce self-serving bias:
- If `$CLAUDE_MODEL` contains "opus" → use `claude-sonnet-4-6`
- Otherwise (sonnet, haiku, or unset) → use `claude-opus-4-6`

This is the **opposite** model from the one executing this skill.

### Input Preparation (CQ6 — bounded input)

For each provider response in `providers_raw`:
1. Extract `response_excerpt` or the full response text
2. CQ6 truncation: limit each response to `floor(80000 / provider_count)` characters before including in the judge prompt. Set `judge_input_truncated: true` in output if any response was truncated.

Shuffle the presentation order randomly (store in `judge_presentation_order`) to reduce positional bias.

### Judge Prompt

Send a single Claude call to the judge model with this prompt structure:

```
You are an objective code quality judge. Score each provider's response on four dimensions (0–5 each):

- completeness: All required methods, fields, and behaviors implemented
- accuracy: Logic is correct, state machines valid, edge cases handled
- actionability: Production-ready; no stubs, TODOs, or placeholder logic
- no_hallucinations: No invented APIs, non-existent methods, or fabricated behavior

TASK:
<task_snapshot or task prompt>

PROVIDER RESPONSES (in random order):
[provider ID redacted — labeled A, B, C, D]

<response A>
---
<response B>
...

Respond with JSON only, no prose:
{
  "A": { "completeness": N, "accuracy": N, "actionability": N, "no_hallucinations": N },
  "B": { ... },
  ...
}
```

### Parse Judge Response

1. Extract JSON from the response. If `jq .` fails → mark run `UNSCORED`, skip to Phase 3 with null scores. Log the raw judge output for debugging.
2. Map labeled responses (A, B, C...) back to provider names using `judge_presentation_order`.
3. Compute per-provider:
   - `code_composite = completeness + accuracy + actionability + no_hallucinations` (0–20)
   - `quality = round(code_composite * 5)` (0–100) — code-only mode
   - `self_eval_bias = self_eval_raw - code_composite` — null if `self_eval_raw` is null

---

## Phase 3: Assemble Leaderboard

### Rank Providers

Sort by:
1. `quality` DESC (higher is better)
2. `time_s` ASC (faster wins ties)
3. `cost_usd` ASC (cheaper wins cost ties)
4. `provider` alphabetical (deterministic final tiebreaker)

### Build Leaderboard Array

For each provider in ranked order:
```json
{
  "rank": 1,
  "provider": "claude",
  "quality": 87,
  "code_score": 18,
  "test_score": null,
  "time_s": 42.1,
  "cost_usd": 0.031,
  "compile_ok": null,
  "tests_pass": null,
  "self_eval_bias": 1.2,
  "adversarial_delta": null,
  "status": "scored"
}
```

### Build Scorecards Object

```json
{
  "claude": {
    "code_completeness": 5,
    "code_accuracy": 4,
    "code_actionability": 5,
    "code_no_hallucinations": 4,
    "code_composite": 18,
    "test_completeness": null,
    "test_accuracy": null,
    "test_actionability": null,
    "test_no_hallucinations": null,
    "test_composite": null,
    "adversarial_delta": null,
    "test_adversarial_delta": null,
    "self_eval_bias": 1.2,
    "response_excerpt": "<first 500 chars of response>"
  }
}
```

### Leaderboard Display

Print the leaderboard as a markdown table:

```
## Benchmark Results — [run_id]
Task: [first 60 chars] | Mode: [default|corpus]

| Rank | Provider     | Quality | Code | Tests | Time  | Cost    | Status |
|------|-------------|---------|------|-------|-------|---------|--------|
|  1   | claude       |    87   |  18  |  null |  42s  | $0.031  | scored |
|  2   | gemini       |    74   |  15  |  null |  31s  | $0.000  | scored |
|  3   | codex-fast   |    65   |  13  |  null |  28s  | $0.008  | scored |
|  4   | cursor-agent |   —     |  —   |  —    |  55s  |  —      | timeout|

Self-eval bias (positive = overconfident): claude +1.2, gemini +3.0, codex-fast +4.5
```

---

## Phase 4: Persist and Log

### Output Files

Auto-increment the run number (NNN) by reading existing files in `audit-results/`:
- `audit-results/benchmark-NNN-[run_id].md` — human-readable report
- `audit-results/benchmark-NNN-[run_id].json` — machine-readable JSON per benchmark-output-schema.md

The JSON file must conform to the schema version `"2.0"` defined in `../../shared/includes/benchmark-output-schema.md`.

### JSON Output Structure

```json
{
  "version": "2.0",
  "skill": "benchmark",
  "run_id": "<run_id>",
  "timestamp": "<ISO-8601>",
  "project": "<project path>",
  "mode": "default",
  "task_source": "user",
  "task_hash": "<64-char SHA-256>",
  "task_snapshot": "<first 30000 chars>",
  "options": { "with_tests": false, "with_adversarial": false, "with_static_checks": false },
  "providers_attempted": ["claude", "gemini", "codex-fast"],
  "providers_succeeded": ["claude", "gemini", "codex-fast"],
  "scored": ["claude", "gemini", "codex-fast"],
  "leaderboard": [...],
  "scorecards": {...},
  "meta_judge_model": "claude-opus-4-6",
  "judge_presentation_order": ["gemini", "claude", "codex-fast"],
  "judge_input_truncated": false
}
```

### Run Log

```
Run: <ISO-8601-Z>	benchmark	<project>	-	-	<VERDICT>	<providers_count>-providers	<mode>	<notes>	<BRANCH>	<SHA7>
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `../../shared/includes/run-logger.md`.

VERDICT: `PASS` (all providers scored), `PARTIAL` (some failed), `FAIL` (all failed), `UNSCORED` (judge parse failed).

### BENCHMARK COMPLETE Block

```
BENCHMARK COMPLETE
Run ID:    [run_id]
Mode:      [default|corpus]
Task:      [hash prefix] — [first 60 chars or "corpus tasks"]
Providers: [N attempted / M succeeded / K scored]
Judge:     [model name] (opposite-model rule)

Results saved:
  audit-results/benchmark-NNN-[run_id].md
  audit-results/benchmark-NNN-[run_id].json

Top provider: [name] (quality: [score], time: [Xs], cost: $[N])
Self-eval bias range: [min] to [max] (positive = overconfident)
```

---

## Corpus Mode — Additional Phases (phases 5–8)

*Corpus mode activates when `--mode corpus` is set. Phases 5–8 extend the default pipeline.*

See Phase 5 (adversarial round), Phase 6 (Round 2 test writing), Phase 7 (test scoring), and Phase 8 (corpus leaderboard) defined in the corpus mode extension below.

**Corpus mode quality formula (both rounds):**
`quality = round((code_composite + test_composite) * 2.5)` → range 0–100

**Default mode formula (code only):**
`quality = round(code_composite * 5)` → range 0–100

---

## Corpus Mode Extension

*This section only runs when `--mode corpus` is set.*

### Phase 5: Adversarial Cross-Review (if `--with-adversarial`)

Each provider's Round 1 output is stored as `tmp/round1_<provider>.txt`.

For each provider that succeeded in Phase 1:
1. Run `scripts/adversarial-review.sh --files tmp/round1_<provider>.txt --json`
2. Have the adversarial reviewers (other providers) challenge the code
3. Record the adversarial findings; provider may rewrite → `tmp/round1_fixed_<provider>.txt`
4. Compute `adversarial_delta`: re-score the post-adversarial output. Delta = fixed_score − original_score (typically negative: critiques lower scores).
5. CQ8: if adversarial fails for a provider, continue with unfixed `round1_<provider>.txt` output

### Phase 6: Round 3 — Write Tests (if `--with-tests`)

Round 1 produces code. Round 3 produces tests for that code. (Round 2 is adversarial review — optional, can run between rounds.)

For each provider that succeeded Round 1:
1. Load `../../shared/includes/benchmark-corpus/task-tests.md`
2. Interpolate `{{ROUND_1_CODE}}` with the provider's `round1_<provider>.txt` output
3. Dispatch the interpolated prompt back to the same provider
4. Capture Round 3 response (test code) → `tmp/round3_<provider>.txt` + `TEST_EVAL_SUMMARY` block

### Phase 7: Round 4 — Adversarial on Tests (if `--with-test-adversarial`)

Mirrors Phase 5 but targets test files from Round 3.

Each provider's Round 3 output is stored as `tmp/round3_<provider>.txt`.

For each provider that succeeded Round 3:
1. Run `scripts/adversarial-review.sh --files tmp/round3_<provider>.txt --json`
2. Other providers critique: missing branches, weak assertions, echo tests, tautological oracles
3. Author may rewrite tests → `tmp/round3_fixed_<provider>.txt`
4. CQ8: if adversarial fails for a provider, continue with unfixed `round3_<provider>.txt`

`test_adversarial_delta` = meta-judge score of fixed tests − original tests (typically negative).

### Phase 7b: Score Round 3 Responses

Use the same meta-judge model to score test quality on four dimensions (0–5 each):
- `test_completeness`: coverage of happy paths, error paths, edge cases
- `test_accuracy`: assertions are meaningful; mocks are correctly set up
- `test_actionability`: tests are runnable and follow project conventions
- `test_no_hallucinations`: no invented test utilities or non-existent matchers

`test_composite = test_completeness + test_accuracy + test_actionability + test_no_hallucinations`

### Phase 8: Corpus Leaderboard

Assemble final leaderboard using the both-rounds quality formula:
`quality = round((code_composite + test_composite) * 2.5)`

Include `test_score`, `adversarial_delta`, `tests_pass` in the leaderboard and scorecards.

Print extended leaderboard with all columns populated.
