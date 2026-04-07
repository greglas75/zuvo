# zuvo:benchmark — Design Specification

> **spec_id:** 2026-04-07-benchmark-0634
> **topic:** Multi-provider AI benchmark with meta-judge quality scoring
> **status:** Approved — v2 extended
> **created_at:** 2026-04-07T06:34:22Z
> **approved_at:** 2026-04-07T06:34:22Z
> **v2_extended_at:** 2026-04-07
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

When working with zuvo adversarial reviews, multiple AI providers (Claude, Gemini, Codex, Cursor) run on the same task — but the goal is consensus, not comparison. There is no way to know which provider is fastest, cheapest, or most accurate for a given type of task. Without this data, provider selection is guesswork. Over time, as providers update their models, the rankings shift — but there is no way to detect the change.

`zuvo:benchmark` solves this by running the same task on all available providers, scoring each response with a meta-judge, and persisting results for historical comparison.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Task input | Real diff/files (default) OR fixed corpus tasks (`--mode corpus`) | Corpus mode enables apples-to-apples comparison across runs and providers |
| Quality scoring | Meta-judge always (no --deep flag) | Benchmarking requires accurate measurement; structural heuristics alone are unreliable |
| Meta-judge model | Claude with opposite-model selection: if `$CLAUDE_MODEL` contains "opus" → use `claude-sonnet-4-6`; otherwise → use `claude-opus-4-6`. Logic copied from `scripts/adversarial-review.sh:run_claude()` lines 510-514 | Ensures meta-judge uses a different model than the one running the benchmark, reducing self-scoring bias |
| Parallel execution | All providers in parallel (default) | Matches adversarial-review.sh; real-world performance measurement |
| Cost tracking | Included — tokens × hardcoded per-provider pricing | Essential for provider selection decisions |
| Storage | `audit-results/benchmark-YYYY-MM-DD-NNN.md` + `.json` | Enables historical comparison. Uses custom `benchmark-output-schema.md` (NOT audit-output-schema.md v1.1 — benchmark has no `findings[]` or `critical_gates` semantics) |
| Historical comparison | `--compare [id1] [id2]` | Corpus builds naturally from saved runs; no extra work |
| Architecture | `scripts/benchmark.sh` + `skills/benchmark/SKILL.md` | Reuses provider dispatcher from adversarial-review.sh; follows skill conventions |
| Multi-round (corpus) | Round 1: write code → Round 2: write tests → Optional Round 3: adversarial | Tests both code quality and test quality in one run; adversarial delta is a separate opt-in round |
| Self-eval bias | Agent self-score captured, compared to meta-judge | Measures how accurately each provider assesses its own output — a separate quality signal |
| Static checks | `tsc --noEmit` + `jest --passWithNoTests` on generated files (corpus mode only) | Objective pass/fail — not subject to meta-judge interpretation |
| Adversarial delta | Optional `--with-adversarial` — runs adversarial review on Round 1 output, re-scores | Answers the key question: does adversarial review close the gap between cheap and expensive providers? |

## Solution Overview

### Default mode (diff / files / prompt)

```
zuvo:benchmark [task-input] [options]
      │
      ▼
scripts/benchmark.sh   ← raw execution only (no meta-judge)
  ├─ collect_input()          ← diff / files / prompt (same as adversarial-review.sh)
  │    └─ saves task_snapshot to tmp/ (actual content, not just ref)
  ├─ detect_providers()       ← reuse from adversarial-review.sh
  ├─ for each provider:
  │    └─ dispatch in background → tmp/result_{provider}.txt
  │         records: response, wall-clock time, tokens in/out, self_eval_score (parsed from output)
  ├─ cost calculation         ← tokens × per-provider pricing table
  └─ outputs tmp/raw_results.json  (no scores yet)

SKILL.md Phase 2 — meta-judge (separate from benchmark.sh):
  ├─ reads tmp/raw_results.json
  ├─ shuffles provider order (prevents positional bias)
  ├─ single Claude call → scores all providers at once
  │    subscores: completeness, accuracy, actionability, no_hallucinations (0-10 each)
  │    composite = (c + a + act + nh) / 4  ← deterministic formula, NOT LLM-computed
  ├─ self_eval_bias = self_eval_score - composite  (per provider)
  ├─ if meta-judge fails → run marked UNSCORED (no fallback heuristics)
  └─ leaderboard assembly → rank by: quality DESC, time_s ASC, cost_usd ASC

SKILL.md Phase 3:
  └─ output:
       audit-results/benchmark-YYYY-MM-DD-NNN.md   ← human-readable
       audit-results/benchmark-YYYY-MM-DD-NNN.json ← machine-readable
```

### Corpus mode (--mode corpus)

```
zuvo:benchmark --mode corpus [--with-tests] [--with-adversarial] [--with-static-checks]
      │
      ▼
  Round 1 — Write code
  ├─ task: corpus/task-code.md (OrderService.ts + useSearchProducts.ts)
  ├─ all providers in parallel → tmp/round1_{provider}.txt
  ├─ each provider appends CQ1-CQ20 self-eval to output
  ├─ static checks (--with-static-checks): tsc --noEmit + jest --passWithNoTests
  └─ meta-judge scores code quality (completeness, accuracy, actionability, no_hallucinations)

  [Optional] Round 2 — Adversarial review (--with-adversarial)
  ├─ adversarial-review.sh runs on each provider's Round 1 output
  ├─ provider reads findings and rewrites → tmp/round1_fixed_{provider}.txt
  ├─ re-score with meta-judge → adversarial_delta = fixed_score - original_score
  └─ static checks repeated on fixed output

  Round 3 — Write tests (--with-tests)
  ├─ task: corpus/task-tests.md (write tests for the code from Round 1 or fixed)
  ├─ all providers in parallel → tmp/round3_{provider}.txt
  ├─ static checks: jest --passWithNoTests (runs the tests)
  └─ meta-judge scores test quality (coverage intent, edge cases, mock discipline, no tautologies)

  SKILL.md final phase:
  └─ leaderboard with all available columns
       audit-results/benchmark-YYYY-MM-DD-NNN.md
       audit-results/benchmark-YYYY-MM-DD-NNN.json
```

## Detailed Design

### Task Modes

| Mode | Flag | Task source | Rounds | Extra dimensions |
|------|------|-------------|--------|-----------------|
| diff (default) | _(none)_ | `git diff HEAD~1` | 1 (review/analysis) | meta-judge only |
| files | `--files "f1 f2"` | named files | 1 | meta-judge only |
| prompt | `--prompt "text"` | arbitrary text | 1 | meta-judge only |
| corpus | `--mode corpus` | fixed standard tasks | 1–3 | code score + test score + static checks + self-eval bias + adversarial delta |

### Corpus Tasks

Stored in `shared/includes/benchmark-corpus/`:

**`task-code.md`** — Write two production files (based on 2026-03-13 experiment):

```
Write TWO production files as if going into a NestJS + React monorepo.
Follow all rules you have loaded. After writing EACH file, print CQ1-CQ20
self-eval with a numeric score (0–20) and evidence for each gate.

File 1: OrderService.ts
NestJS service — Injectable with PrismaService, RedisService, EmailService,
PaymentGateway. Implement: findAll (filters + Redis caching), findById,
create (with line items), deleteOrder (transactional), updateStatus (state
machine: pending→confirmed→processing→shipped→delivered + cancellation),
calculateMonthlyRevenue (aggregate by currency), bulkUpdateStatus,
getOrdersForExport. Multi-tenant (organizationId scope on all queries).
Audit logging on mutations. Email on shipping with error handling.

File 2: useSearchProducts.ts
React custom hook — debounced search (300ms, AbortController), pagination
with loadMore (append), runtime API response validation (no Zod), error
handling with retry (max 3), separate isLoading / isLoadingMore states,
cleanup on unmount. Return: { products, total, isLoading, isLoadingMore,
error, hasMore, loadMore, retry }.

After both files, print:
SELF_EVAL_SUMMARY
OrderService: <score>/20
useSearchProducts: <score>/20
```

**`task-tests.md`** — Write tests for the files from Round 1:

```
Write tests for the two files produced in Round 1.
Follow all rules you have loaded. Cover: happy path, edge cases, error paths.
Use Jest + ts-jest. Mock external dependencies (Prisma, Redis, Email, fetch).
After writing, print TEST_EVAL_SUMMARY with: file count, test count, and
which edge cases you explicitly covered.
```

**Self-eval parsing:** benchmark.sh greps output for `SELF_EVAL_SUMMARY` block and extracts numeric scores. If block is missing → `self_eval_score: null`.

### Data Model

**Per-provider result (default mode):**
```json
{
  "provider": "claude",
  "status": "ok",
  "response_time_s": 14.2,
  "tokens_in": 850,
  "tokens_out": 312,
  "response": "... full text ...",
  "self_eval_score": null,
  "error": null
}
```

**Per-provider result (corpus mode, with all options):**
```json
{
  "provider": "claude",
  "status": "ok",
  "rounds": {
    "code": {
      "response_time_s": 42.1,
      "tokens_in": 1200,
      "tokens_out": 890,
      "self_eval_score": 17,
      "compile_ok": true,
      "response": "..."
    },
    "adversarial": {
      "findings_critical": 2,
      "findings_warning": 4,
      "findings_info": 1,
      "fixed_response_time_s": 28.3,
      "compile_ok": true
    },
    "tests": {
      "response_time_s": 31.5,
      "tokens_in": 2100,
      "tokens_out": 620,
      "tests_pass": true,
      "test_count": 24,
      "response": "..."
    }
  },
  "error": null
}
```

**Meta-judge scoring (one call, all providers at once):**
```json
{
  "claude": {
    "code_completeness": 9, "code_accuracy": 8, "code_actionability": 9, "code_no_hallucinations": 9,
    "code_composite": 8.8,
    "test_completeness": 8, "test_accuracy": 9, "test_actionability": 7, "test_no_hallucinations": 9,
    "test_composite": 8.3,
    "adversarial_delta": 1.2,
    "self_eval_bias": -0.5
  },
  "gemini": {
    "code_composite": 7.0,
    "test_composite": 6.5,
    "adversarial_delta": null,
    "self_eval_bias": 1.8
  }
}
```

Notes:
- `self_eval_bias` = `self_eval_score_normalized` (0–10) − `code_composite`. Positive = overconfident. Negative = underconfident. `null` if self-eval block missing.
- `adversarial_delta` = `code_composite_after_fix` − `code_composite_before_fix`. `null` if `--with-adversarial` not used.

**Cost table (hardcoded in benchmark.sh, updated per release):**
```bash
# Per 1M tokens (input/output separately)
declare -A COST_IN=([claude]="3.00" [gemini]="0.00" [codex-fast]="5.00" [gemini-api]="1.25" [cursor-agent]="0.00")
declare -A COST_OUT=([claude]="15.00" [gemini]="0.00" [codex-fast]="15.00" [gemini-api]="5.00" [cursor-agent]="0.00")
```

**Leaderboard row (default mode):**
```json
{
  "rank": 1,
  "provider": "claude",
  "quality": 8.8,
  "time_s": 14.2,
  "tokens_out": 312,
  "cost_usd": 0.0052,
  "status": "ok"
}
```

**Leaderboard row (corpus mode, full):**
```json
{
  "rank": 1,
  "provider": "claude",
  "code_score": 8.8,
  "test_score": 8.3,
  "compile_ok": true,
  "tests_pass": true,
  "self_eval_bias": -0.5,
  "adversarial_delta": 1.2,
  "time_s": 101.9,
  "cost_usd": 0.031,
  "status": "ok"
}
```

**Benchmark run JSON (saved to audit-results/):**
```json
{
  "version": "2.0",
  "skill": "benchmark",
  "run_id": "2026-04-07-001",
  "timestamp": "2026-04-07T06:34:22Z",
  "project": "zuvo-plugin",
  "mode": "corpus",
  "corpus_version": "1.0",
  "options": {
    "with_tests": true,
    "with_adversarial": false,
    "with_static_checks": true
  },
  "task_source": "corpus",
  "task_hash": "sha256:abc123",
  "judge_presentation_order": ["gemini", "claude", "codex-fast"],
  "providers_attempted": ["claude", "gemini", "codex-fast"],
  "providers_succeeded": ["claude", "gemini"],
  "scored": true,
  "leaderboard": [...],
  "scorecards": {...},
  "meta_judge_model": "claude-sonnet-4-6"
}
```

Note: `task_snapshot` not stored in corpus mode (tasks are fixed files, reproducible by corpus version). In diff/files/prompt modes: stores actual content (first 30K chars), enabling `--replay-last`.

### API Surface

**Argument parsing (SKILL.md phase 0):**

| Argument | Default | Description |
|----------|---------|-------------|
| _(empty)_ | `git diff HEAD~1` | Benchmark the last commit diff |
| `--diff REF` | — | Specific git ref (e.g. `HEAD~3`) |
| `--files "f1 f2"` | — | Space-separated file list |
| `--prompt "text"` | — | Arbitrary prompt (non-code tasks) |
| `--mode corpus` | — | Use fixed corpus tasks (OrderService + useSearchProducts) |
| `--with-tests` | off | Add test-writing round after code round (corpus mode only) |
| `--with-adversarial` | off | Add adversarial review + fix round before tests (corpus mode only) |
| `--with-static-checks` | off | Run `tsc --noEmit` + `jest --passWithNoTests` on generated files (corpus mode only) |
| `--provider P` | all | Force single provider |
| `--show-costs` | — | Print provider pricing table and exit (no benchmark run) |
| `--compare [id1] [id2]` | last 2 runs | Compare benchmark runs. If task sources differ, prints a warning: "Task sources differ — comparison is cross-task and may not be meaningful." |
| `--replay-last` | — | Re-run the most recent task (diff/files/prompt modes only) |
| `--json` | — | JSON-only output |

**Output file naming:**
```bash
# Auto-increment NNN if same-day collision
benchmark-2026-04-07-001.md
benchmark-2026-04-07-002.md
```

### Integration Points

**Reused from adversarial-review.sh (copy, not import):**
- `collect_input()` — stdin / diff / files input handling
- `detect_providers()` — auto-detection of available providers
- `dispatch_provider()` — per-provider call with timeout
- PID tracking + cleanup trap pattern
- `JSON_TMPDIR` temp file pattern

**New in benchmark.sh:**
- Per-provider timing wrappers (`time_start=$(date +%s)` before/after dispatch)
- Token accounting for all providers (Gemini API already exists; Claude/Codex: estimate via `wc -w × 1.3`)
- Cost calculation function
- Self-eval score parser (greps `SELF_EVAL_SUMMARY` block from provider output)
- Static checks runner (corpus mode): `tsc --noEmit`, `jest --passWithNoTests` on tmp files
- Adversarial round dispatcher (calls adversarial-review.sh per provider, captures findings count)
- Meta-judge call (single Claude call with all responses — all rounds at once)
- Leaderboard assembly + ranking
- Historical run lookup for `--compare`

**SKILL.md phases (default mode):**
- Phase 0: Argument parsing + provider detection + input collection
- Phase 1: Execute benchmark (calls benchmark.sh)
- Phase 2: Meta-judge quality scoring
- Phase 3: Leaderboard + scorecards output
- Phase 4: Save to audit-results/ + run log

**SKILL.md phases (corpus mode):**
- Phase 0: Argument parsing + provider detection
- Phase 1: Round 1 — dispatch code task to all providers in parallel
- Phase 2: Static checks on Round 1 output (--with-static-checks)
- Phase 3: Adversarial round — per provider (--with-adversarial)
- Phase 4: Round 3 — dispatch test task to all providers in parallel (--with-tests)
- Phase 5: Static checks on Round 3 output (--with-static-checks)
- Phase 6: Meta-judge — score all providers across all completed rounds
- Phase 7: Leaderboard + scorecards + adversarial delta + self-eval bias output
- Phase 8: Save to audit-results/ + run log

**New files:**
```
skills/benchmark/SKILL.md
scripts/benchmark.sh
shared/includes/benchmark-output-schema.md
shared/includes/benchmark-corpus/task-code.md
shared/includes/benchmark-corpus/task-tests.md
```

**Routing (using-zuvo/SKILL.md):** Add row:
```
| Benchmark providers, compare models, measure quality/speed/cost | `zuvo:benchmark` |
```

### Static Checks (corpus mode only)

Static checks run after each code-producing round. They are objective pass/fail — not subject to meta-judge interpretation.

**TypeScript check:**
```bash
# Write provider output to tmp file, run tsc
echo "$provider_output" | grep -A99999 '```typescript' | grep -B99999 '```' > /tmp/bench_check.ts
tsc --noEmit --strict /tmp/bench_check.ts 2>/dev/null
compile_ok=$?   # 0 = pass, non-zero = fail
```

**Jest check (tests round):**
```bash
# Write test output to tmp file
jest --testPathPattern=/tmp/bench_test --passWithNoTests 2>/dev/null
tests_pass=$?
test_count=$(jest --testPathPattern=/tmp/bench_test --json 2>/dev/null | jq '.numTotalTests // 0')
```

Both checks are **best-effort** — if they cannot run (no tsc/jest in PATH), record `"compile_ok": null`, `"tests_pass": null`. Never block the benchmark on static check failure.

### Edge Cases

| Case | Handling |
|------|----------|
| 0 providers available | STOP — print install instructions, exit 1 |
| 1 provider | Proceed, warn "No comparison available (1 provider)" |
| Provider timeout (>240s) | Mark TIMEOUT, continue with others |
| Provider error / API key missing | Mark ERROR with reason, continue |
| All providers fail | Exit 2 — no leaderboard generated |
| Token count unavailable | Triggered when provider response contains `tokens_in = 0`, `tokens_out = 0`, or missing token fields. Estimate both: `tokens_out = wc -w response × 1.3`; `tokens_in = wc -w task_snapshot × 1.3` (task content is identical across providers — estimate once, reuse). Flag both as `~estimated`. |
| No previous runs for `--compare` | "No prior benchmark found. Run without --compare first." |
| `--replay-last` but no history | Same as above |
| `--replay-last` in corpus mode | Not supported — corpus tasks are already fixed. Print "Use --mode corpus to re-run corpus tasks." |
| Same-day run collision (NNN) | Auto-increment suffix |
| Meta-judge call fails | Run saved as UNSCORED (`"scored": false`). Leaderboard shows providers ranked by time only with a note: "Quality scoring unavailable — meta-judge failed." No structural heuristics fallback (would contradict Design Decision). |
| Meta-judge input too large | If combined provider responses exceed 80K chars, truncate each response to `80K / provider_count` chars before meta-judge call. Flag `"judge_input_truncated": true` in run JSON. |
| Self-eval block missing | `self_eval_score: null`, `self_eval_bias: null`. Not an error — providers that don't follow the format still get scored by meta-judge. |
| Static checks not in PATH (tsc/jest) | Record `null` for that check, print warning, continue. Never block benchmark. |
| `--with-tests` without `--mode corpus` | Print error: "Test round requires --mode corpus." Exit 1. |
| `--with-adversarial` without `--mode corpus` | Same as above. |
| Adversarial round fails for one provider | Mark that provider's `adversarial_delta: null`. Others continue. |

## Acceptance Criteria

**Must have:**
1. `zuvo:benchmark` runs on `git diff HEAD~1` by default and produces a leaderboard
2. All available providers run in parallel; failed providers are marked TIMEOUT/ERROR without blocking others
3. Meta-judge scores every provider response on completeness, accuracy, actionability, no-hallucinations (0-10 composite)
4. Leaderboard shows: rank, provider, quality score, time (seconds), tokens out, estimated cost ($), status
5. Per-provider scorecard shows: full quality breakdown + response excerpt (first 300 chars)
6. Results saved to `audit-results/benchmark-YYYY-MM-DD-NNN.md` and `.json`
7. `--compare` loads two run JSONs and shows delta table (quality, time, cost per provider)
8. Run logged to `~/.zuvo/runs.log` in 11-field TSV format
9. 0-providers case exits with clear install instructions

**Should have:**
10. `--replay-last` re-runs the exact task from the most recent benchmark run
11. `--files` and `--diff REF` work as task input alternatives
12. Token estimates flagged as `~estimated` when provider response contains `tokens_in = 0`, `tokens_out = 0`, or missing token fields — verifiable by running benchmark against a provider with no token API (e.g. cursor-agent)
13. Cost table visible with `--show-costs` (prints pricing table, no benchmark run)

**Edge case handling:**
14. 1-provider run completes with a warning (not a failure)
15. Meta-judge failure saves run as UNSCORED (`scored: false`), ranks by time only, explains reason in output — no structural scoring fallback
16. `--compare` with non-existent run ID prints a useful error, not a crash

## Out of Scope

- Standard task corpus (v2 — corpus builds naturally from saved runs)
- Cost caps (`--max-cost`) — v2
- `--sequential` mode for fairer timing — v2
- Seed/temperature control for reproducibility — v2
- Integration with `zuvo:review` to auto-select best provider — future
- Web UI or dashboard for benchmark history — future

## Open Questions

None — all design decisions resolved in Phase 2 dialogue.
