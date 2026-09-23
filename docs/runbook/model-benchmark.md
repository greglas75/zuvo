# Model Benchmark Runbook — choosing a model or effort for an adversarial lane

How to decide which model, and which effort, an `adversarial-review` lane runs. Read this before
changing any value in `shared/includes/model-registry.sh` or any provider default in
`scripts/adversarial-review.sh`. **A model change without a benchmark behind it is a guess**, and
the registry comments exist to record the measurement that justified the current value.

## Where it lives

The harness and its corpus are **HOME-local on the owner's Mac, not in git**: `~/.zuvo/bench/`
(~23 MB). Nobody else can run it from a fresh clone. To run it elsewhere, copy the whole directory,
not the scripts alone: the corpus (`judge2/`) is the part you cannot regenerate.

| Path | What |
|---|---|
| `bench-model.sh <lane> <label>` | The whole pipeline: run → judge → evaluate. Every stage resumes |
| `subs/run-{agy,claude,…}.sh` | Per-lane runner: sends the 20 corpus diffs through the driver |
| `judge-model.sh <label> <lane>` | Opus judge: each finding → `REAL` / `FALSE_POSITIVE` + defect slug |
| `evaluate-model.py <label> [ref]` | Precision and **marginal coverage** over the rest of the set |
| `judge2/<id>/CODE.diff` | The corpus: 20 real review diffs |
| `judge2/DEFECT_VOCAB.md` | Shared defect vocabulary, cut per packet |
| `judge2/verdicts-<label>.tsv` | The judge's output for one candidate |
| `subs/results-<label>.tsv` | Per-diff status (`ok`/`empty`/`timeout`), findings, seconds |
| `shim-effort/claude` | Forces `--effort` on the claude lane (the driver does not pass one) |
| `runs-eff/seq-claude.sh` | Sequential runner with a retry pass (claude lane, see below) |

## The number that decides

**Marginal coverage** is the number of real defects the candidate finds that none of the other
providers in the set finds (`dokłada NOWE`). It decides, not the head-to-head score. A model that
finds a lot, but only what the others already find, adds nothing. Precision and latency are
secondary. Reliability counts as well: a reviewer that does not answer has 0 precision whatever it
scores when it does answer.

**The scope is always all 20 diffs.** Counting only the diffs where a model answered flatters it for
the ones it failed on.

## Running it

```bash
cd ~/.zuvo/bench
FROZEN=subs/adversarial-review.frozen
cp ~/.zuvo/adversarial-review "$FROZEN"          # freeze the driver first — see pitfall 1

# Gemini via agy — effort is part of the model name
ADV="$PWD/$FROZEN" ZUVO_AGY_FALLBACK_MODEL="" ZUVO_AGY_SILENT_COOLDOWN=0 \
  bash bench-model.sh agy "Gemini 3.8 Flash (Medium)"

# Claude — model and effort are separate; the label names both
BENCH_MODEL=claude-opus-5-5 BENCH_EFFORT=medium ADV="$PWD/$FROZEN" \
  bash bench-model.sh claude claude-opus-5-5-medium

# OpenRouter
bash bench-model.sh or meta/muse-spark-1.3
```

How each lane sets effort:

| Lane | How effort is set |
|---|---|
| `agy` | In the display name: `Gemini 3.8 Flash (Low/Medium/High)` |
| `claude` | `BENCH_EFFORT=` → `shim-effort/claude` adds `--effort` (the judge does NOT go through the shim) |
| `kimi` | `KIMI_MODEL_THINKING_EFFORT` env (`subs/run-kimi-effort.sh`); verify it in `wire.jsonl` `llm.request` |
| `codex` | `ZUVO_CODEX_EFFORT_{PRIMARY,ALT}` |

Before the full run, send ONE diff through the lane and check that the adversarial log's model
column shows what you asked for. A wrong display name fails silently.

## Pitfalls — every one of these cost a run

1. **Freeze the driver.** Bash reads a script while it runs. When a parallel agent edited
   `scripts/adversarial-review.sh` mid-bench, the running calls died with
   `ock: command not found`, and those diffs got recorded as the model's failures. Always pass
   `ADV=<frozen copy>`.
2. **Disable fallbacks and cooldowns** (`ZUVO_AGY_FALLBACK_MODEL=""`,
   `ZUVO_AGY_SILENT_COOLDOWN=0`). Otherwise a quota-hit Gemini is silently answered by Opus and
   scored as Gemini.
3. **Never `pkill agy`.** The driver reads a killed call as a silent quota exhaustion and writes a
   one-hour cooldown into the SHARED `~/.zuvo/agy-cooldown-*`, which also blocks production
   reviews. If you did it anyway: `rm ~/.zuvo/agy-cooldown-<model>`.
4. **Every scripted `claude -p` needs
   `--mcp-config '{"mcpServers":{}}' --strict-mcp-config`.** Without it:
   - the model sometimes answers with an MCP authorization notice instead of the task, and the
     judge then drops that diff with no error (see 5);
   - every call starts the user's full MCP set, and killing the parent leaves the servers
     orphaned (21 orphaned `sentry-mcp` = 27 GB).
5. **Check `ocenione=N/20` before reading an evaluation.** A judge that returns no TSV now prints
   `!! sędzia NIE zwrócił…`. Before that warning existed, Sonnet 5 went out as "+8, judged" when
   only 11 of 20 diffs had verdicts. Its real result was +21.
6. **The claude lane spends the Claude subscription,** the same pool this session runs on. Five
   parallel runs plus the judge exhausted the limit in about 1.5 h, and every call after that came
   back `exit 1` with empty stderr. Run it **sequentially** after a reset (`runs-eff/seq-claude.sh`,
   two passes: the second retries only failed diffs and missing verdicts).
7. **Separate infrastructure errors from model errors.** `503 UNAVAILABLE`, `exit 1` hitting
   several runs in the same second, and quota errors are retried. A timeout on a hard diff is the
   model's own result and is kept.
8. **The judge is Opus 5.** It may favour `claude-opus-5` findings. Weigh that candidate
   accordingly.
9. **Clean up after the run:** `ps -eo pid,ppid,rss,command | awk '$2==1'`. Kill only your own
   orphans, never processes that belong to other sessions.

## Reading the result — noise is ~±10

The same config measured on different days differs by up to 11 marginal defects: 3.8 Flash
(High) gave +32 on 2026-09-05 and +21 on 2026-09-23. So:

- **Measure every candidate you compare on the same day, in the same conditions.** Re-run the
  reference too; do not compare against an old number.
- A gap under ~10 defects is not a result. Choose on reliability, latency and precision, and say
  in the commit that the gap is inside the noise.

## Recording a decision

1. Change the value in `shared/includes/model-registry.sh`, and write the measurement table into
   the comment above it: date, all candidates, the noise caveat.
2. Update the inline `:-<id>` fallbacks in `scripts/adversarial-review.sh` and the matrix in
   `docs/adversarial-providers.md`.
3. `rt --light bash tests/adversarial/run.sh test-agy-quota-fallback` (or the test for that lane).
4. Commit. The runtime reads `~/.zuvo/model-registry.sh` first, so the change takes effect when
   `./scripts/install.sh` copies the registry there.

## Results so far

| Date | Lane | Candidates → decision |
|---|---|---|
| 2026-09-01 | agy | 3.7 Flash (High) over 3.1 Pro (High): Pro answered 7/20 |
| 2026-09-05 | agy | 3.8 Flash (High) over 3.7: +32 vs +17 |
| 2026-09-23 | agy | **3.8 Flash (Medium)**: Low +14/56%, Medium +25/75%/0 timeouts, High +21/71%/2 timeouts |
| 2026-09-23 | claude | Sonnet 5 +21 / 83% / 43 s. Opus 5 dropped: 4–8.5 min per diff, at the 500 s timeout. Opus 5.5 low/medium/high: in progress |
