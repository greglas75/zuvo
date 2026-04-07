# zuvo:benchmark — Design Specification

> **spec_id:** 2026-04-07-benchmark-0634
> **topic:** Multi-provider AI benchmark with meta-judge quality scoring
> **status:** Approved
> **created_at:** 2026-04-07T06:34:22Z
> **approved_at:** 2026-04-07T06:34:22Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

When working with zuvo adversarial reviews, multiple AI providers (Claude, Gemini, Codex, Cursor) run on the same task — but the goal is consensus, not comparison. There is no way to know which provider is fastest, cheapest, or most accurate for a given type of task. Without this data, provider selection is guesswork. Over time, as providers update their models, the rankings shift — but there is no way to detect the change.

`zuvo:benchmark` solves this by running the same task on all available providers, scoring each response with a meta-judge, and persisting results for historical comparison.

## Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Task input | Real diff/files from project (evolves to corpus) | Reuses existing adversarial-review.sh input model; real tasks are more meaningful than synthetic ones |
| Quality scoring | Meta-judge always (no --deep flag) | Benchmarking requires accurate measurement; structural heuristics alone are unreliable |
| Meta-judge model | Claude with opposite-model selection: if `$CLAUDE_MODEL` contains "opus" → use `claude-sonnet-4-6`; otherwise → use `claude-opus-4-6`. Logic copied from `scripts/adversarial-review.sh:run_claude()` lines 510-514 | Ensures meta-judge uses a different model than the one running the benchmark, reducing self-scoring bias |
| Parallel execution | All providers in parallel (default) | Matches adversarial-review.sh; real-world performance measurement |
| Cost tracking | Included — tokens × hardcoded per-provider pricing | Essential for provider selection decisions |
| Storage | `audit-results/benchmark-YYYY-MM-DD-NNN.md` + `.json` | Enables historical comparison. Uses custom `benchmark-output-schema.md` (NOT audit-output-schema.md v1.1 — benchmark has no `findings[]` or `critical_gates` semantics) |
| Historical comparison | `--compare [id1] [id2]` | Corpus builds naturally from saved runs; no extra work |
| Architecture | `scripts/benchmark.sh` + `skills/benchmark/SKILL.md` | Reuses provider dispatcher from adversarial-review.sh; follows skill conventions |

## Solution Overview

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
  │         records: response, wall-clock time, tokens in/out
  ├─ cost calculation         ← tokens × per-provider pricing table
  └─ outputs tmp/raw_results.json  (no scores yet)

SKILL.md Phase 2 — meta-judge (separate from benchmark.sh):
  ├─ reads tmp/raw_results.json
  ├─ shuffles provider order (prevents positional bias)
  ├─ single Claude call → scores all providers at once
  │    subscores: completeness, accuracy, actionability, no_hallucinations (0-10 each)
  │    composite = (c + a + act + nh) / 4  ← deterministic formula, NOT LLM-computed
  ├─ if meta-judge fails → run marked UNSCORED (no fallback heuristics)
  └─ leaderboard assembly → rank by: quality DESC, time_s ASC, cost_usd ASC

SKILL.md Phase 3:
  └─ output:
       audit-results/benchmark-YYYY-MM-DD-NNN.md   ← human-readable
       audit-results/benchmark-YYYY-MM-DD-NNN.json ← machine-readable
```

## Detailed Design

### Data Model

**Per-provider result (collected during execution):**
```json
{
  "provider": "claude",
  "status": "ok",
  "response_time_s": 14.2,
  "tokens_in": 850,
  "tokens_out": 312,
  "response": "... full text ...",
  "error": null
}
```

**Meta-judge scoring (one call, all providers at once):**
```json
{
  "claude":      { "completeness": 9, "accuracy": 8, "actionability": 9, "no_hallucinations": 9, "composite": 8.8 },
  "gemini":      { "completeness": 7, "accuracy": 7, "actionability": 6, "no_hallucinations": 8, "composite": 7.0 },
  "codex-fast":  { "completeness": 6, "accuracy": 7, "actionability": 6, "no_hallucinations": 7, "composite": 6.5 }
}
```

**Cost table (hardcoded in benchmark.sh, updated per release):**
```bash
# Per 1M tokens (input/output separately)
declare -A COST_IN=([claude]="3.00" [gemini]="0.00" [codex-fast]="5.00" [gemini-api]="1.25" [cursor-agent]="0.00")
declare -A COST_OUT=([claude]="15.00" [gemini]="0.00" [codex-fast]="15.00" [gemini-api]="5.00" [cursor-agent]="0.00")
```

**Leaderboard row:**
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

**Benchmark run JSON (saved to audit-results/):**
```json
{
  "version": "1.0",
  "skill": "benchmark",
  "run_id": "2026-04-07-001",
  "timestamp": "2026-04-07T06:34:22Z",
  "project": "zuvo-plugin",
  "task_source": "diff HEAD~1",
  "task_snapshot": "... actual captured content of the diff/file/prompt ...",
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

Note: `task_snapshot` stores the actual content (not the reference), enabling `--replay-last` to feed identical input regardless of current git state. If task content exceeds 30K chars, store first 30K + `"task_snapshot_truncated": true`.

### API Surface

**Argument parsing (SKILL.md phase 0):**

| Argument | Default | Description |
|----------|---------|-------------|
| _(empty)_ | `git diff HEAD~1` | Benchmark the last commit diff |
| `--diff REF` | — | Specific git ref (e.g. `HEAD~3`) |
| `--files "f1 f2"` | — | Space-separated file list |
| `--prompt "text"` | — | Arbitrary prompt (non-code tasks) |
| `--provider P` | all | Force single provider |
| `--show-costs` | — | Print provider pricing table and exit (no benchmark run) |
| `--compare [id1] [id2]` | last 2 runs | Compare benchmark runs. Works regardless of `task_source` (diff vs files vs prompt). If task sources differ between compared runs, prints a warning: "Task sources differ — comparison is cross-task and may not be meaningful." |
| `--replay-last` | — | Re-run the most recent task |
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
- Meta-judge call (single Claude call with all responses)
- Leaderboard assembly + ranking
- Historical run lookup for `--compare`

**SKILL.md phases:**
- Phase 0: Argument parsing + provider detection + input collection
- Phase 1: Execute benchmark (calls benchmark.sh)
- Phase 2: Meta-judge quality scoring
- Phase 3: Leaderboard + scorecards output
- Phase 4: Save to audit-results/ + run log

**New files:**
```
skills/benchmark/SKILL.md
scripts/benchmark.sh
shared/includes/benchmark-output-schema.md
```

**Routing (using-zuvo/SKILL.md):** Add row:
```
| Benchmark providers, compare models, measure quality/speed/cost | `zuvo:benchmark` |
```

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
| Same-day run collision (NNN) | Auto-increment suffix |
| Meta-judge call fails | Run saved as UNSCORED (`"scored": false`). Leaderboard shows providers ranked by time only with a note: "Quality scoring unavailable — meta-judge failed." No structural heuristics fallback (would contradict Design Decision). |
| Meta-judge input too large | If combined provider responses exceed 80K chars, truncate each response to `80K / provider_count` chars before meta-judge call. Flag `"judge_input_truncated": true` in run JSON. |

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
