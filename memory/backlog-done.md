
## Archived from backlog.md on 2026-09-20 (1 completed items moved out)
- [x] B-A20260920-cb8b1c - [B-secaudit-2] pentest SCA preflight (0.5b): snippet is advisory; 4 adversarial rounds fixed real bugs (lockfile-specific tool, exit-non-zero-means-vulns-not-failure, pip-audit env-vs-lockfile, requirements unpinned). Residual: per-lockfile loop in polyglot trees left to agent. conf: 25

## Archived from backlog.md on 2026-09-21 (4 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-A20260921-42c6e3 - [B-seccorpus-2] tests/security-corpus/registry.test.sh — test robustness: column-scope the CWE assert, detect duplicate finding_type rows, replace substring seed-grep with anchored match, single-source the safe-pattern list from registry rows. Source: execute Task 2 adversarial (6 WARNING, 0 CRITICAL). conf: 35
- [x] B-A20260921-673238 - [B-seccorpus-5] tests/security-corpus/*/clean twins — adversarial WARNINGs for robustness beyond each target class (graphql NODE_ENV gating + complexity, xxe parse-budget, redos type-guard, ldap empty-string). Twins correctly defend their OWN class (corpus contract); broader hardening deferred. conf: 25
- [x] B-A20260921-22a186 - [B-seccorpus-7] GraphQL/serverless detection heuristics: adversarial WARNINGs — 'type Query' matches TS aliases, handler.ts matches *-handler.ts, resolver-args misses destructured {args}. Detection signals are heuristic + agent-confirmed (overlay needs corroborating signals like ApolloServer/serverless.yml). conf: 25
- [x] B-A20260921-2dec6a - [B-review-1] validate-pentest-output.sh — PENTEST_REGISTRY/PENTEST_MANIFEST env-overridable (test affordance) is also a prod-path override; low risk (local CI script, attacker would need env control) but consider a test-only guard. Source: zuvo:review self-review F4. conf: 35

## Archived from backlog.md on 2026-10-05 (1 completed items moved out)
- [x] B-20261005-BENCH-RUNBOOK-STALE [MEDIUM][doc][conf 90]: `docs/runbook/model-benchmark.md` has no row for the
  2026-10-04 session and none of its pitfalls: exact raw-file names (glob collision above), findings followed by
  `NO ISSUES FOUND`, CLI outputs wrapped in the driver header, an empty answer with 0/0 token usage = provider
  failure (re-run, not a model result), `sakana/*` 403 "not available in your region", the deleted
  `adversarial-inputs` diffs, and the model-bench page + `build.py` as the place results are read. Source: session. [FIXED 6de91d9f] — runbook: scripts/bench paths, pitfalls 10-15, 2026-10-04 results row.

## Archived from backlog.md on 2026-10-05 (4 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261005-OPENROUTER-NEW-MODELS-UNBENCHED: OpenRouter models added since the last OpenRouter
  bench (2026-09-09) and never benchmarked for adversarial coverage — cheap: xiaomi/mimo-v2.6-flash,
  mimo-v2.6-pro, nex-agi/nex-n2.5-pro + -mini, upstage/solar-mini4, z-ai/glm-5.3-flashx,
  inclusionai/ling-3.1-flash, cohere/command-a-plus; costlier: x-ai/grok-4.7,
  qwen/qwen3.8-max-prime, z-ai/glm-5.3-prime, aion-labs/aion-3.5, sakana/fugu-max, fireworks/ember-1.
  Skip stealth/free models (provider may log the diffs) without owner consent. The owner was asked
  whether to run the first batch and has not answered. Run sequentially on a frozen driver copy; the
  Opus judge uses the Claude subscription. | severity: low | category: Dependency | conf: 90 — OBSOLETE — filed in error: the parallel 2026-10-04/05 bench session had already benchmarked every listed model (~/.zuvo/bench/judge2/verdicts-*.tsv, page zuvo-plugin/model-bench); the filing session checked only the stale or/summary.tsv of 09-09.
- [x] B-20261005-BENCH-MUSE13-JUDGED-ON-WRONG-FILES [HIGH][bench][conf 70]: `meta/muse-spark-1.3` (judged
  2026-09-05) may have been scored on another label's answers. The old `judge-model.sh` picked the raw file with
  `ls "$SAFE"-*-"$id".txt | head -1`, and `or/raw/` also holds `meta_muse-spark-1.3-contributor-…` files, which
  sort BEFORE `-fail-`/`-ok-`. The same glob made `inception/mercury-2.5` see `-preview` files and
  `aion-labs/aion-3.5` see `-mini` files (both caught and fixed 2026-10-04 before judging). Fix: check which file
  each `verdicts-meta_muse-spark-1.3.tsv` packet came from (compare finding text), re-judge with the fixed judge,
  re-run `evaluate-model.py`; the model-bench page then needs `build.py`. Source: session scan 2026-10-05. WONTFIX — not affected, verified 2026-10-05: its verdicts were written 2026-09-05 01:41, the `-contributor` files appeared 2026-09-09, and 19/19 judged packets match the model's OWN files (row counts and reason tokens).
- [x] B-20261005-BENCH-TRAILING-NO-ISSUES-UNJUDGED [MEDIUM][bench][conf 90]: the old judge skipped any answer that
  contained a line starting `NO ISSUES FOUND`, even after real findings (mercury-2.5 appends it after 3 findings).
  9 packets in older sessions were never judged for that reason: minimax-m2.7 (1788097281-9996), minimax-m2.5
  (1788097281-9996, 1788097410-31705), tp-glm-5.2 (1788094825-87461, 1788096892-49590, 1788097361-16842),
  muse-spark-1.2 (1788097361-16842), nemotron-3-nano-30b-a3b (1788094825-87461, 1788097416-32992). Their published
  scores are undercounted. Fix: re-run `judge-model.sh <label>` for those 6 labels (it judges only missing packets;
  tp-* use judge-lane.sh / Fable to keep the judge constant), then rebuild the page. Source: session scan. [FIXED 6de91d9f] — all 9 packets re-judged 2026-10-05 (minimax-m2.7 → 16/20, m2.5 → 18/20, nemotron → 20/20, muse-1.2 → 19/20, tp-glm-5.2 → 19/20 with Fable); judge.sh now treats findings + NO ISSUES as findings.
- [x] B-20261005-BENCH-HARNESS-OUTSIDE-GIT [MEDIUM][bench][conf 85]: every harness fix of this session lives only in
  HOME-local `~/.zuvo/bench` — unreviewed, unversioned, lost on a machine move: `judge-model.sh` (exact
  `<label>-{ok,fail}-<id>` file, clean = NO ISSUES *without* any SEVERITY), `evaluate-model.py` (same exact glob in
  the missed-review counter), `subs/run-lane.sh` (`ADV=` override for a frozen driver). The OR runner fixes exist
  only in the one-off copy `or/.bench-1004.py`; `or/bench.py` itself still (a) builds prompts with the LIVE repo
  driver (runbook pitfall 1), (b) crashes because `~/.zuvo/adversarial-inputs/*.diff` no longer exist (needs the
  `judge2/<id>/CODE.diff` fallback), (c) retries a 900 s timeout 4 times as "transient" (`JSONDecodeError` after
  903 s) — ~1 h per timed-out call for nex-n2.5-pro, (d) runs 4 workers. Also: `evaluate-model.py kimi` reads
  `verdicts-kimi.tsv` (09-24) while OTHERS uses the round-1 packet `kimi`, so that label is compared with itself.
  Fix: move the harness (minus the corpus) into the repo, e.g. `scripts/bench/`, port the fixes, test the judge's
  file selection and clean-detection. Source: session. [FIXED 6de91d9f] — scripts/bench/ (5 scripts) + tests/benchmark-suite/test-bench-harness.sh (21 groups, 6a0c60d2); two adversarial passes, 31 findings fixed.
