# Model Benchmark Runbook — choosing a model or effort for an adversarial lane

How to decide which model, and which effort, an `adversarial-review` lane runs. Read this before
changing any value in `shared/includes/model-registry.sh` or any provider default in
`scripts/adversarial-review.sh`. **A model change without a benchmark behind it is a guess**, and
the registry comments exist to record the measurement that justified the current value.

## Where it lives

The **scripts** are in this repo, `scripts/bench/` (since 2026-10-05; before that they existed only
in `~/.zuvo/bench`, and every fix made there was unreviewed and unversioned). The **data** — corpus,
answers, verdicts — is HOME-local on the owner's Mac: `~/.zuvo/bench/` (`$BENCH_HOME`, ~25 MB).
To run it elsewhere, copy that directory; the corpus (`judge2/`) is the part you cannot regenerate.
The old copies in `~/.zuvo/bench/*.sh` are superseded by the repo scripts; do not edit them.

| Path | What |
|---|---|
| `scripts/bench/bench-model.sh or\|cli …` | The whole pipeline: run → judge → evaluate. Every stage resumes |
| `scripts/bench/bench-or.py --models …` | OpenRouter runner: `[label=]vendor/model[@effort]`, `--plan` without network |
| `scripts/bench/run-lane.sh <label> <provider> [ENV=v …]` | Any driver lane (cursor, codex, kimi, qwen, byteplus, claude, agy, muse) |
| `scripts/bench/judge.sh <label> --source or\|cli` | Judge (`--judge-model`, default Opus 5): each finding → `REAL` / `FALSE_POSITIVE` + defect slug |
| `scripts/bench/evaluate-model.py <label> [ref]` | Precision, missed reviews and **marginal coverage** over the rest of the set |
| `judge2/<id>/CODE.diff` | The corpus: 20 real review diffs |
| `judge2/raw/<judge-model>/` | Every judge answer, cached before parsing; reused instead of a new paid call |
| `or/results.tsv`, `or/raw/<SAFE>-<grp>-<id>.txt` | OpenRouter answers (bench-or.py) |
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
B=~/DEV/zuvo-plugin/scripts/bench
F=~/.zuvo/bench/frozen-$(date +%F); mkdir -p "$F/lib"
cp ~/DEV/zuvo-plugin/scripts/adversarial-review.sh "$F/"; cp ~/DEV/zuvo-plugin/scripts/lib/*.sh "$F/lib/"
export ADV="$F/adversarial-review.sh"     # REQUIRED; the live driver is refused — see pitfall 1

# OpenRouter — one or many models; a tag keeps a same-day re-run apart from the first run
bash $B/bench-model.sh or xiaomi/mimo-v2.6-flash
python3 $B/bench-or.py --models 'xiaomi/mimo-v2.6-flash~r2=xiaomi/mimo-v2.6-flash' 'vendor/model@low' --plan

# A driver lane — the label names model AND effort
bash $B/bench-model.sh cli cursor-grok-4.7-high cursor-agent ZUVO_CURSOR_MODEL=grok-4.7-high
bash $B/bench-model.sh cli sol-light codex-5.3 ZUVO_MODEL_CODEX_PRIMARY=gpt-6-sol ZUVO_CODEX_EFFORT_PRIMARY=none
bash $B/bench-model.sh cli tp-qwen3.8-max qwen ZUVO_ADV_QWEN=1 ZUVO_QWEN_MODEL=qwen3.8-max
bash $B/bench-model.sh cli "gemini-3.8-flash-medium" agy "ZUVO_MODEL_AGY=Gemini 3.8 Flash (Medium)" \
  ZUVO_AGY_FALLBACK_MODEL= ZUVO_AGY_SILENT_COOLDOWN=0
# Claude effort goes through the shim (the driver passes none): PATH=~/.zuvo/bench/shim-effort:$PATH BENCH_EFFORT=medium

# Judge only / evaluate only
bash $B/judge.sh tp-glm-5.2 --source cli --judge-model claude-fable-5-1
python3 $B/evaluate-model.py xiaomi/mimo-v2.6-flash
```

Then refresh the decision page: `python3 ~/DEV/tgm-mockup/projects/zuvo-plugin/model-bench/build.py`
and publish it (its README) — <https://tgm-mockups.pages.dev/v/zuvo-plugin/model-bench>.

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
   accordingly. A reviewer that says "no issues" also triggers the `!!` no-TSV warning: that
   diff was clean, not lost, so read the text after the warning before re-judging.
9. **Clean up after the run:** `ps -eo pid,ppid,rss,command | awk '$2==1'`. Kill only your own
   orphans, never processes that belong to other sessions.
10. **Match answer files EXACTLY.** The old judge took `<label>-*-<id>.txt | head -1`, which also
    matches a neighbouring label and picks it when it sorts first: `aion-3.5` → `aion-3.5-mini-ok-…`,
    `mercury-2.5` → `mercury-2.5-preview-…`. `judge.sh` and `evaluate-model.py` now take
    `<SAFE>-{ok,fail}-<id>` only (2026-10-04).
11. **"NO ISSUES FOUND" after findings is not a clean answer.** Some models (mercury-2.5) list
    findings and then close with that line; the old judge skipped such answers whole, and 9 packets
    in 6 labels were never judged (re-judged 2026-10-05). Clean = no finding at all.
12. **CLI answers are wrapped in the driver's report header.** A wrapped "NO ISSUES FOUND." is ~490 B
    and does not start with the phrase, so sol/luna showed 0 empty answers instead of 4–9 of 20.
    The evaluator strips the wrapper before deciding.
13. **An empty answer with 0/0 token usage is the provider, not the model** — it never ran the request
    (mercury, fugu-max on the largest diff). `bench-or.py` retries it; a timeout it does NOT retry
    (the old runner retried a 900 s timeout four times, ~1 h per call).
14. **Provider-side refusals are infrastructure.** `sakana/*` answers 403 "not available in your
    region" intermittently; record the packet as missing, do not score it as a model miss.
15. **`~/.zuvo/adversarial-inputs/*.diff` are rotated away.** The runners fall back to
    `judge2/<id>/CODE.diff`, the corpus's real home.

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
| 2026-09-24 | claude | Opus 5.5 **high** +40 / 88% / 91 s · medium +35 / 84% / 73 s · low +26 / 84% / 85 s · Sonnet 5 +21 / 83% / 43 s. Opus 5 dropped: 4–8.5 min per diff, at the 500 s timeout. Fable 5.1 not measured (cost). All 20/20 judged. Opus 5.5 is the strongest single reviewer measured, but it CANNOT review Opus 5.5-authored code (self-review): Sonnet 5 stays the reviewer for an Opus 5.5 author |
| 2026-10-04 | 17 new (16 OpenRouter + grok-4.7 via the cursor login) | Single run, no decision yet (same-day r2 re-run in progress). Marginal / precision / s per diff / $ per review: **mimo-v2.6-flash +23 / 92% / 319 s / $0.0063** (best value) · aion-3.5 +20 / 82% / $0.10 · fugu-max +19 / 83% / $0.14 · grok-4.7-high +19 / 95% / 637 s (2 timeouts, subscription) · glm-5.3-flashx +18 / 83% / 170 s / $0.025 · ling-3.1-flash +16 / 77% (free, 429s) · ember-1 +16 / 85% / $0.19 · mimo-v2.6-pro +14 · glm-5.3-prime +12 / $0.28 · qwen3.8-max-prime +8 / $0.33 — the "prime" tiers add less than their cheap siblings. mercury-2.5 and solar-mini4 fast but 33% / 20% precision; command-a-plus 18%; pareto "no issues" on 5/20; nex-n2.5-pro 9/20 timeouts; nex-n2.5-mini and aion-3.5-mini burn the whole output budget on reasoning (empty on 17 and 14 of 20). Page: tgm-mockups model-bench |
| 2026-10-05/06 | same-day r2 of the top candidates + the production lanes | Marginal / precision, r1 → r2: mimo-v2.6-flash +23/92% → +17/83% · fugu-max +19/83% → +22/76% · glm-5.3-flashx +18/83% → +18/88% · aion-3.5 +20/82% → +12/80% · grok-4.7-high +19/95% → +19/86% (600–750 s, 2/20 timeouts both runs) · Token Plan qwen3.8-max +28/75% → +20/72% vs qwen3.8-flash (production `qwen`) +19/71% → +16/72% · production `codex-5.3` (gpt-6-sol light) +5/93% → +5/81% · gpt-oss-120b +11 → +10 (32–34%) · mercury-2.5-preview +9 → +9 (28–29%). BytePlus Coding Plan through the driver: dola-seed-2.0-code (`byteplus-3`) +14/52%; glm-5.3-flash (`byteplus`) on the streaming driver 20/20 answered (≈25% before the fix), +17/83%, mean 456 s, **7/20 over the 500 s lane timeout**. Lane decisions pending with the owner: byteplus budget vs effort, qwen flash → max, the three in-noise lanes (codex-5.3, openrouter-3/4) |
| 2026-10-06 | 6 OpenRouter + Sonnet 5.5 + gpt-6.1-sol | Single run, reference 215. Marginal / precision / missed: **nemotron-3-ultra-550b +19 / 48% / 2/20 (~52 s, $0.5/$2.2)** · inkling +16 / 63% / 2/20 (~401 s) · seed-2-1-turbo +9 / 60% / 6/20 · pareto-26.10-preview +9 / 97% / 6/20 · nemotron-3.5-lightning +7 / 33% · solar-pro4 +6 / 28%. sakana-namazu not measurable: its only OpenRouter endpoint trains on paid data, refused by the account's data policy (HTTP 404). **Claude Sonnet 5.5 +27 / 91% / 1/20 (~45 s)** vs production Sonnet 5 +21 / 83% (09-24; gap inside the noise, precision +8). **gpt-6.1-sol rejects `reasoning.effort=none`** (HTTP 400 "Supported values are: low, medium, high, xhigh, max") — the codex lane's production effort → 20/20 empty; at `low` +3 / 100%, "no issues" on 7/20 (~31 s). Decisions pending with the owner: Sonnet 5 → 5.5, an r2 of nemotron-3-ultra before any lane change |
| 2026-09-24 | kimi | **k3-256k high** 86 real / 83% / 84 s · k3 high 75 / 77% / 236 s · k3 low 74 / 69% / 43 s · k3-256k low 73 / 70% / 60 s · K2.8 Preview high 68 / 72% / 159 s (1 timeout) · low 63 / 66% / 175 s. Marginal 16–22 for all six = inside the noise, so decided on precision and latency. Low effort costs 7–13 precision points on every model. K2.7 Highspeed high 64 / 63% / 119 s, low 61 / 61% / 244 s — weakest model, not faster |
