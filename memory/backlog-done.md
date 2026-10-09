
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

## Archived from backlog.md on 2026-10-06 (4 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261005-ADVLOG-HEADER-MISMATCH [MEDIUM][code][conf 80]: `~/.zuvo/adversarial.log` header has 14 columns
  (`date run_id mode provider model input_chars …`) but recent rows have 17 fields with the MODEL in column 4 and
  the PROVIDER in column 14 — the header no longer describes the rows. Reading by header gives wrong numbers
  (see docs/runbook/operating.md §10). Found by `build.py`, which had to hard-code positions. Fix the header writer
  in `scripts/adversarial-review.sh` (or version the format) and the readers that trust the header.
  Source: session. WONTFIX — not a defect: the driver appends a `#schema` line whenever the columns change (init_log_header; the live log's line 152292 describes the 17-column rows) and keeps the first line for old readers. The reader that hard-coded positions was model-bench build.py.
- [x] B-20261005-UI-DESIGN-TEAM-DISPATCH-BLOCKED [MEDIUM][skill][conf 90]: `skills/ui-design-team/SKILL.md` Step 2
  agent prompts name no CodeSift tool, and the global subagent hook rejects general-purpose prompts without one —
  all 4 specialist dispatches failed on the first try. Same class likely in every skill that dispatches read-only
  general-purpose reviewers on non-code targets (check the class, not just this skill). Two more retro proposals
  from that run: a "decision audit" in Agent 1 for dashboards (one baseline per metric; recommendations the data
  supports), and a rebuild path in Step 5 when P0s are structural. Source: retro ui-design-team / tgm-mockup
  2026-10-04. [FIXED 1558624a] — class fix in shared/includes/env-compat.md (Agent Dispatch → Claude Code): the prompt must name its CodeSift tools; the 'decision audit' / Step-5 rebuild proposals stay retro proposals.
- [x] B-20261005-FARM-HOOK-FALSE-POSITIVES [LOW][hooks][conf 85]: `hooks/farm-no-local-tests.sh` blocked two
  non-test commands this session: `npm view … version` / `npm install -g @qwen-code/qwen-code@latest`
  ("ambiguous package-manager command") and a `python3 - <<'P'` heredoc whose payload contained JS template text
  `${…}` ("shell substitution <test command>"). Workarounds cost extra turns (patch scripts written to files).
  Fix: treat `npm view|install -g|outdated` as non-test, and do not pattern-match inside quoted heredoc bodies.
  Source: session. [FIXED 5e372557] — npm maintenance/query subcommands allowed; substitutions scanned after non-shell heredoc bodies are stripped. Kept by design: `TF_ALLOW_LOCAL=1 cmd | tail` stays refused (an opt-out may not carry separators).
- [x] B-20261005-TEST-AUDIT-AP13-SHELL [MEDIUM][skill][conf 90]: `shared/includes/test-audit-batch-prompt.md`
  defines AP13 as "Test with zero expect() calls -> AUTO TIER-D" with only an RTL exception, so EVERY bash/shell
  test file is auto Tier D whatever it asserts. Measured 2026-10-05 on tests/benchmark-suite/test-bench-harness.sh
  (50+ assert_*/fail checks): two cross-vendor audits (codex gpt-6-sol) returned AUTO TIER-D while writing "it does
  contain shell assertions"; the build's test-quality gate therefore can only end WARN for any shell test, and the
  ~150 tests/hooks + benchmark-suite files of this repo would all audit as D. Fix: define the assertion forms per
  stack (bash: assert_*, `|| fail`, `[ … ] || exit`, exit-code checks; pytest: assert; go: t.Error/require), and add
  a fixture test that a bash file with assertions is not AP13. Source: zuvo:build 4.6b gate, report
  zuvo/audits/test-quality-audit-2026-10-05-bench-harness.md. WONTFIX — duplicate: already fixed in the repo by 6a1dbebb (AP13 counts each runner's own assertions); the audit ran on the installed 1.6.80 copy, which predates it — needs install/release only.

## Archived from backlog.md on 2026-10-06 (1 completed items moved out)
- [x] B-20261005-CP-PRS [done 2026-10-05: cut as pr-cp/01..12; the write-tests and mutation-test wiring split off to pr-cp/13, see B-20261005-CP-BENCH]: cut the stacked PRs. The plan's "## PR Sequence" predates the 15 Phase Final commits.
  - Proposed stack, each PR ≤1000 lines:
    1. the plan
    2. T7 + T6 + d7c7ed44
    3. T1
    4. T2
    5. T3
    6. T4
    7. T5 + T8
    8. T9 + a26d67e6
    9. 894c0ff5 (1136 lines; split it by file at cherry-pick)
    10. e9df2fa5 + 91463f4d + 9b5202e2 + 6b9e0120
    11. 0f93dcad + 759bbbec
    12. 7b93e271 + b68bb3b1 + df113a35 + 6e16dbbe + 978ad713
  - Before the first push, fix the branch upstream: `feat/comment-pass` tracks `origin/main`.

## Archived from backlog.md on 2026-10-06 (1 completed items moved out)
- [x] B-20261005-PARTIAL-RUN-WINS [P2][correctness][conf 70] — FIXED 2026-10-06 on test/backlog-write-tests (e3cfaf04, 26e67a23): pull picks the newest COMPLETE run (every batch number 0..of-1), names an incomplete newer run on stderr; client-side, so it holds whatever the collector server does. Regression tests in tests/hooks/test_backlog_collector.py.
  **Fingerprint:** scripts/zuvo-home/backlog|pull|newest-run-not-complete
  **What:** `pull()` keeps the run with the newest `received_at` per host
  (scripts/zuvo-home/backlog:313) and never checks that ALL its batches arrived. A push that fails on
  batch k/N (scripts/zuvo-home/backlog-collect.py:240) or is killed by sync's 300 s timeout
  (scripts/zuvo-home/backlog:354) leaves batches 1..k-1 under a NEW run_id with newer timestamps, so
  the next pull serves that host's backlog TRUNCATED and reports success. Every payload already
  carries `batch`/`batches`.
  **Why deferred:** seen while triaging adversarial pass 3 (cursor-agent: a timeout leaves the
  landing ambiguous); only the message was fixed. Not verified whether the collector server drops
  incomplete runs — check that first (conf 70 for that reason).
  **Fix:** per (host, run) count distinct `batch` values and treat the run as complete only when the
  count equals `batches`; pick the newest COMPLETE run per host and name hosts whose newest run is
  incomplete. RED test: two runs for one host, the newer one missing a batch.

## Archived from backlog.md on 2026-10-06 (1 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261005-FULL-SUITE-AFTER-MERGES [P2][verification][conf 95] — RAN 2026-10-06 on origin/main 27381da2 (locally: hook tests are invalid on the farm, testing.md §5): 185 PASS / 5 FAIL, none in this session's files — filed as B-20261006-ORIGIN-MAIN-REDS.
  **What:** d979fca9 and 7f2b7fa8 went to origin/main checked only by the targeted suites
  (backlog-collector-ssh, runlog-collect, backlog-headings, archive-dedup, python-lint, shellcheck).
  The full suite (tests/run-all) did not run after either merge, although this session's own retro
  (2026-10-02) recorded that targeted verification missed two regressions only the full suite found.
  **Why deferred:** time; the merged files were disjoint from the suites skipped.
  **Fix:** the full suite through `rt` on current main; triage any red with docs/runbook/testing.md §5.

## Archived from backlog.md on 2026-10-06 (3 completed items moved out)
- [x] B-20261005-TRACKED-TEST-TMP [P3][hygiene][conf 90] — FIXED 2026-10-06 (218edb6c): removed from the index; .gitignore already covered it.
  **What:** 164 files under tests/adversarial/.tmp/ are tracked in git and rewritten by every test
  run, so the main checkout is permanently dirty and every session must step around them by hand.
  **Fix:** `git rm -r --cached tests/adversarial/.tmp` + a .gitignore entry, after confirming no test
  reads a committed fixture from there (move any that do to tests/fixtures/).
- [x] B-20261005-APPEND-RETRO-ENUMS [P4][telemetry][conf 70] — FIXED 2026-10-06 (10391aeb): SCRIPT code type; multi-pass `Npasses:Mfindings` already fit *findings, now pinned by a test.
  **What:** ~/.zuvo/append-retro rejected `--code-type=INFRA_SCRIPT` and `--adversarial=4passes`, so
  the retro for review@d979fca was filed as ORCHESTRATOR / "9findings" — an approximation: four
  passes produced about 30 severity records, ~12 fixed, the rest rejected. Retro mining reads the
  wrong shape for shell/infra reviews.
  **Fix:** a SCRIPT/INFRA code type and a multi-pass adversarial form (`Npasses:Mfindings`) in
  scripts/zuvo-home/append-retro and the append-runlog gate together.

confidence:85 source:session-sweep-2026-10-05 (collected from the merge-main review report, the four adversarial passes' rejected lists, and the session retros)
- [x] B-20261006-ORIGIN-MAIN-REDS [P2][verification][conf 95] — FIXED 2026-10-06 (f7123329): install-wiring, retro-loop-docs, shellcheck, python-lint green; refactor-radar was already green at f06cc97d.
  **What:** the full suite on origin/main 27381da2 (2026-10-06, local run — testing.md §5) is 185/5. None from the
  backlog work; all from other sessions' merges:
  - tests/hooks/test-install-wiring.sh (8) and tests/hooks/test-retro-loop-docs.sh — "hardcoded IP in
    zuvo_host_id.py" (scripts/zuvo-home/zuvo_host_id.py, the host-id rework).
  - tests/hooks/test-shellcheck.sh — SC2010 `ls | grep` at tests/hooks/test-install-host-ownership.sh:388.
  - tests/hooks/test-python-lint.sh — ruff 21 (scripts/bench/bench-or.py, scripts/install.d/claude_settings.py,
    scripts/zuvo-home/zuvo_backlog_agent.py F401) + 1 mypy error, against a ratchet of 0.
  - tests/gates/test-refactor-radar.sh — 3 radar contract/CLI failures (bundle preservation, symlinked target).
  **Fix:** each owner's session; attribute with a standalone run before calling any of them environmental.

## Archived from backlog.md on 2026-10-06 (2 completed items moved out)
- [x] B-20261005-MAIN-RED-HOSTID-IP: [FIXED c9b602e0 — the example is written 192.168.x.y; test-install-wiring and test-retro-loop-docs pass] tests/hooks/test-install-wiring.sh (8) "versioned helper names a host
  address" FAILs on scripts/zuvo-home/zuvo_host_id.py — red on a clean main checkout (40a17543): its comments
  quote a measured LAN address (`192.168.0.124`, lines 11 and 114) as an example of an unstable host name.
  The rule exists so no versioned helper carries a fleet address; write it as `192.168.x.y`. Found while
  verifying the adversarial-review split's merge of main, outside its fence. | conf: 95 |
  source: zuvo:refactor (merge verification) | seen:2 | 2026-10-05
  Re-observed 2026-10-05 by zuvo:build (review-queue retirement): the same address also turns
  tests/hooks/test-retro-loop-docs.sh red ("hardcoded IP in zuvo_host_id.py") — two of the three files a full farm
  `tests/run-all.sh` fails on main; B-28's backlog-collect.py/runlog-collect.py no longer trip check (8), so B-28 may
  be closeable once test-retro-loop-docs is re-checked.
- [x] B-20261005-MAIN-RED-SC2010: [FIXED c9b602e0 — find instead of ls | grep] tests/hooks/test-shellcheck.sh is red on a clean main checkout (40a17543):
  one new warning against a ratchet of 0 — tests/hooks/test-install-host-ownership.sh:388 (SC2010,
  `ls -A "$H/.codex" | grep -v '^hooks.json$'`). Fix with a glob or
  `find "$H/.codex" -mindepth 1 -maxdepth 1 ! -name hooks.json`. Found while verifying the adversarial-review
  split's merge of main, outside its fence. | conf: 95 | source: zuvo:refactor (merge verification) | seen:1
  | 2026-10-05

## Archived from backlog.md on 2026-10-06 (5 completed items moved out)
- [x] B-20261005-EFE4C5B5-UNREVIEWED [P3][verification][conf 80] — CLOSED 2026-10-06: efe4c5b5's inlined helper no longer exists; f3b86e6c replaced it with the shared zuvo_host_id module, reviewed in memory/reviews/7079545..f4035cb-merge-main-host-id.md.
  **What:** efe4c5b5 (stable collector host tag) went out in 7f2b7fa8 below the gate threshold
  (2 files, ~50 lines) with only a diff read: no zuvo:review, no adversarial pass, and at the time no
  test of the ZUVO_HOST_TAG -> ~/.zuvo/host-id -> gethostname() precedence in either collector.
  Later host-id commits from another session (889fc39e, ea9f5206, f4035cbf) reworked this code.
  **Fix:** confirm memory/reviews/7079545..f4035cb-merge-main-host-id.md covers the original
  behaviour; if the precedence is untested, add the test.
- [x] B-20261005-PUSH-ONLY-STALENESS [P3][observability][conf 75] — FIXED 2026-10-06 (99886adb): index age printed, stderr warning past 7 days.
  **What:** on a push-only host `sync` exits 0 with "index: not refreshed on this host"
  (scripts/zuvo-home/backlog:376) on every run, forever. Cron output is discarded, so if the data
  dir's permissions regress the local index goes stale silently — a softer replay of the 3-week
  "0 items" incident. Raised by kimi (pass 3, INFO), not acted on.
  **Fix:** print the local index age beside the message, and warn loudly (or fail) past a threshold,
  e.g. no refresh for 7 days.
- [x] B-20261005-PULL-GLOB-ARGMAX [P4][scalability][conf 60] — FIXED 2026-10-06 (99886adb): one gzip per file, each status checked.
  **What:** the remote pull expands every `*.jsonl` into one argv for gzip
  (scripts/zuvo-home/backlog:285). Past ARG_MAX it fails with E2BIG — by name, never as a short
  index. Rejected twice this session as "pre-existing, the fleet is a handful of files".
  **Fix:** not `find | xargs cat | gzip` (it loses the read status — see the comment at that line);
  gzip per file appended to one stream, with a status check per file.
- [x] B-20261005-COLLECTOR-ENV-SOURCED [P4][security-hardening][conf 50] — FIXED 2026-10-06 (99886adb): the token is read with awk, never sourced.
  **What:** the token fetch sources `collector.env` on the collector (scripts/zuvo-home/backlog:341),
  so any shell in that file runs as the ssh user; DATA and COLLECTOR_ENV are also interpolated into
  the remote command unquoted. Rejected this session as "by design, operator-owned constants" — an
  injection needs write access to the collector, so this is hardening, not a hole.
  **Fix:** read the value with `sed -n 's/^CODESIFT_COLLECTOR_TOKEN=//p'` (then the ZUVO_ name)
  instead of sourcing; `shlex.quote` both paths.
- [x] B-20261005-CHMOD-TESTS-SKIP-AS-ROOT [P4][test-coverage][conf 70] — FIXED 2026-10-06 (99886adb): the unreadable answer is also driven by the remote status, root-independent.
  **What:** the three unreadable-dir cases in tests/hooks/test-backlog-collector-ssh.sh
  (:100, :125, :141) SKIP when chmod 000 is not honoured (root, some filesystems); the push-only
  branch and the ancestor walk then go untested while the suite still says ALL PASS.
  **Fix:** count SKIPs into the result line, or drive the unreadable branch through the fake ssh
  stub (return UNREADABLE_RC directly) so it never depends on the account.

## Archived from backlog.md on 2026-10-06 (1 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261005-REVIEW-DEGRADED-NO-CODESIFT [P3][verification][conf 90]
  **What:** the review of the local-main merge (memory/reviews/2026-10-03-merge-local-main.md) ran
  with CodeSift disconnected: review_diff, changed_symbols, impact_analysis, scan_secrets and
  search_patterns were replaced by a manual diff read + ruff + shellcheck. The report says so, but
  those mandatory checks never ran on 85b19024..7f2b7fa8 for scripts/zuvo-home/backlog and
  backlog-collect.py.
  **Fix:** with CodeSift up, `review_diff` + `scan_secrets` + `search_patterns` over
  85b19024..7f2b7fa8 for those two files; file anything new.
  **Resolved 2026-10-06:** CodeSift back. review_diff/scan_secrets/changed_symbols are absent from this
  host's cached tool list (reveal_ineffective), so the documented substitutes ran: audit_scan on both files —
  backlog-collect.py 0 findings, the backlog family only CQ13 "unused outside defining file" on in-file CLI
  commands of backlog-*.py (out of scope, not dead); impact_analysis 85b19024..7f2b7fa8 (14 files, 20 symbols);
  search_patterns empty-catch + shell=True/eval/exec/verify=False/bare except: no matches; a secret-pattern scan
  of the range's added lines in both files: 0 candidates. Nothing new to file.

## Archived from backlog.md on 2026-10-06 (1 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261006-BACKLOG-TESTS-BELOW-A [P3][test-quality][conf 85]
  **What:** zuvo:test-audit after 2 fix iterations (zuvo/audits/test-quality-audit-2026-10-06.md, cross-vendor
  codex/gpt-6-sol): tests/hooks/test_backlog_collector.py B 71% (AP21 indexed fake-call lists; AP26 the lock test
  observes "blocked" with a bounded join), tests/hooks/test-backlog-collector-ssh.sh B 55% (AP2 shared mutable shell
  fixtures, AP26 a 1 s timeout probe), tests/skill-suite/test_coverage_gate_polyglot.py C (Q7/Q11 judged against all
  of scripts/test-coverage-gate.py although the file targets detect_language only).
  **Fix:** collector — assert fake calls by content, not index; ssh suite — per-case fixtures (or retire the cases the
  unit specs now cover); polyglot — pair the gate's other functions with their own suites in the audit, or add their
  negative paths here.
  **Resolved 2026-10-06 (test/backlog-tests-to-a):** collector specs find fake calls by content
  (FakeRun.one_ssh/one_push), the lock test waits on an observed would-block flock instead of a 1 s window
  (kills a no-lock mutant); the ssh suite gives every case its own sandbox (three cases had silently
  inherited an earlier case's token/data dir) and hangs on a FIFO, not a sleep; the polyglot spec declares
  detect_language as its unit (other gate functions: their own suites) and covers its remaining branches.

## Archived from backlog.md on 2026-10-07 (1 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261005-GATE-PATCH-ID-TWINS [P3][gate][conf 80]
  **What:** at push the pipeline-entry gate counted 26bef0d5/0eba8782 as unreviewed although their
  content was byte-identical to origin's already-reviewed 99035e07/a7224dc0. It cleared only after
  copying another session's artifact (85b1902..a7224dc-stryker-diff-scope.md) into the pushing
  worktree.
  **Fix:** in hooks/lib/pipeline-gate-lib.sh treat a commit whose `git patch-id --stable` matches a
  commit already on the remote as covered; test with a cherry-picked twin.
  **Resolved 2026-10-06 (fix/gate-patch-id-twins):** _pgl_unpushed_commits drops un-pushed non-merge commits
  whose patch-id matches a remote commit outside the tip's history (window bounded by the oldest un-pushed author
  date); pg_changed_production and pg_changed_lines walk that set. TWINS tests in test-pipeline-gate-lib.sh.

## Archived from backlog.md on 2026-10-06 (1 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261005-ADV-SPLIT-TQ-RESCORE: the split's test-quality audit
  (zuvo/audits/test-quality-audit-2026-10-04.md in its worktree) scored 15 of its 19 suites on the degraded
  in-family route (claude/sonnet): the cross-vendor batch auditor had flagged them `AP13 -> AUTO TIER-D` for
  "no expect() calls" although each asserts through shell helpers. That cause is fixed on main by 6a1dbebb
  (AP13 counts each runner's own assertions); the split's 15 tiers were never re-scored cross-vendor. Re-run
  zuvo:test-audit on those suites after the branch is merged. | conf: 85 | source: zuvo:refactor (Phase 3.6)
  | seen:1 | 2026-10-05 — RESOLVED 2026-10-06: re-scored cross-vendor in the branch itself (all 5 batches
  codex/gpt-6-sol, prompt from main's 6a1dbebb; zuvo/audits/test-quality-audit-2026-10-06.md in the worktree); what is
  left is B-20261006-ADV-SPLIT-TQ-WARN.

## Archived from backlog.md on 2026-10-06 (1 completed items moved out)
- [x] B-20261005-REVIEW-QUEUE-STILL-WRITTEN: scripts/claude-home/scripts/post-commit-review-backlog.sh [FIXED 1c23d67d]
  (installed byte-identical as ~/.claude/scripts/) still has "Part 2: Project-local docs/review-queue.md"
  and writes that file into every checkout with a docs/ dir — every linked worktree included, where it
  sits untracked after each commit (seen in adversarial-review-split). install.sh's CLAUDE HOME comment
  says the opposite: "It does NOT write docs/review-queue.md — that file was removed 2026-07-28 as a dead
  artifact". Fix: delete Part 2 (zuvo:review uses memory/reviews/), or correct the comment if the file is
  still wanted; tests/skill-suite/test-dev-push-gate.sh:106 already records it leaking from a test. A
  retirement is in flight on the local branch chore/retire-review-queue (not on main at cc419552) — close
  this entry with that merge. Seen again 2026-10-01/02 by the hook-perf session: untracked
  docs/review-queue.md in two more worktrees. | conf: 90 | source: zuvo:refactor | seen:2 | 2026-10-05

## Archived from backlog.md on 2026-10-08 (3 completed items moved out)
- [x] B-20261005-ADV-SPLIT-UNFINISHED: [FIXED — pushed and merged through PR #54 on 2026-10-07 after the merges
  of origin/main 30e7fad2/50f95150, reviews p22-p34, run-all 200/0/1 and the contract re-characterized 51/51 on
  04773417 (GATE PASS); released as v1.6.82] branch `refactor/adversarial-review-split` (worktree
  `~/DEV/zuvo-plugin-worktrees/adversarial-review-split`, contract `zuvo/contracts/refactor-dedc3165.json`)
  is NOT pushed and NOT merged. State on 2026-10-06: the refactor contract is COMPLETE (`check` PASS;
  quality WARN, mutation 45/45). origin/main 88c7f160 was merged in at ba08d815: main's driver hunks were
  ported into the modules, and the branch's installer code moved into scripts/install.d/. The merge was
  checked with the 51-suite characterization package and run-all, and tests/lib/install-manifest.sh shows
  the same installer effect as main plus the driver modules. The p12 cross-model review of the merge and
  the comment pass was fixed at b4ebc456 (21 findings fixed, 44 rejected with reasons, in the findings
  ledger). Reviews p13–p20 of each later fix delta followed, through 75d1d330. The driver has not changed since
  88f29462, and p17–p20 found no defect in it. The push-gate artifact
  memory/reviews/88c7f16..75d1d33-adversarial-review-split.md covers every production file (pg_uncovered_files
  is empty), and is archived in ~/.zuvo/review-archive. Then two whole-file mutation runs, at the owner's request:
  the driver plus modules (234 mutants, 36 gaps closed, 2 equivalent), and the other changed files (66
  mutants, 16 gaps closed). Both are 100% triaged; see zuvo/audits/mutation-test-2026-10-06-2/-3. On
  9822f29f: bats 213/213, ruff clean. run-all has three reds and none is the branch's:
  - blind-audit-panel: B-20261006-BAP-SIGNAL-FLAKE;
  - test-audit dispatch: B-20261006-DISPATCH-ZSH;
  - python-lint: fixed at 9822f29f.
  The ruff line-length fix has its own review artifact (70ed06e..9822f29). Left: push, PR and merge, with the
  owner's go-ahead. Tick when the branch is merged.
  | conf: 100 | source: zuvo:refactor | seen:3 | 2026-10-05
- [x] B-20261006-BAP-SIGNAL-FLAKE: [FIXED eeb79bb7 — main's own fix ("signal cases no longer race the host's
  speed"), in the branch since its merge of 30e7fad2; green in run-all on the merged tree, 2026-10-07]
  tests/hooks/test-blind-audit-panel.sh "signal INT/TERM: bap_merge's own exit
  status is 130/143" is a race. On the sessions host under load (~7) it went red 0, 1 or 2 times in four
  alternating runs, on both 70ed06e5 and b08afb6c (rc 1 instead of 130/143). The 0.2 s margin after mktemp is
  not enough when bap_merge finishes or fails before the signal lands. Fix: hand-shake on a state the merge
  cannot pass (e.g. a fifo it blocks on) instead of a sleep. | conf: 85 | source: zuvo:mutation-test (final
  run-all) | seen:1 | 2026-10-06
- [x] B-20261006-DISPATCH-ZSH: [FIXED 8eb61def — main's release-gate fix (bash_block no longer SIGPIPEs printf;
  the shell is passed by absolute path); every [zsh] case green in run-all on the merged tree with
  ~/.local/bin/zsh on PATH, 2026-10-07] tests/skill-suite/test-test-audit-subprocess-dispatch.sh fails once zsh is on PATH
  (~/.local/bin/zsh, installed on the sessions host 2026-10-06 21:52). Three FAILs: "1a setup bash block
  extracted", "a call block is … ONE ~/.zuvo/test-audit-batch command", "the execution harness ran". With
  ~/.local/bin off PATH it passes 300/300 and SKIPs its [zsh] leg. Same on b08afb6c, so the branch did not
  cause it. Find what the zsh leg changes for the extraction, and make the suite pass with zsh present (the
  owner's Mac has zsh as the default shell). | conf: 90 | source: zuvo:mutation-test (final run-all) | seen:1
  | 2026-10-06

## Archived from backlog.md on 2026-10-08 (2 completed items moved out)
- [x] B-20261007-CPM-CACHE-INPLACE-COPY [P2][install][conf 90] [FIXED 64c6c524 — every host's script copies go through install_files_atomic; hooks and bin follow in B-20261008-INSTALL-INPLACE-HOOKS]: `install.sh` overwrites the scripts in each Claude plugin cache dir in place.
  - **What:** `scripts/install.d/claude.sh:224` copies `scripts/*.sh` into every `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/` through `cp_warn`, which runs a plain `cp` (`scripts/install.d/output.sh:76`). That truncates and rewrites the inode a running `bash adversarial-review.sh` is reading. docs/runbook/operating.md §5 says this can make the script resume in the middle of another line. The Codex copy of the same driver already goes through a temp file and `mv`.
  - **Seen:** 2026-10-06 07:5xZ: another session was running four `adversarial-review.sh` processes from the cache while the PR #40 install was due. I waited for them to finish (scratchpad wait loop) instead of fixing it.
  - **Fix:** write cache scripts through `install_file_atomic` (temp file plus rename), the same as the Codex driver. Add a test that holds a reader on the old inode across an install.
- [x] B-20261007-GATE-MERGED-IN-BLOB: WONTFIX — duplicate of B-20261007-GATE-FLAGS-UPSTREAM-BLOBS (same defect, filed the
  same day by another session; this sighting is recorded there). hooks/lib/pipeline-gate-lib.sh — the pre-push gate (@unpushed) lists every
  production file any un-pushed commit touched, then demands a review artifact for the file's TIP blob. A file the
  branch edited early and that a later merge of main replaced wholesale ends at main's pushed blob, yet it still
  blocks: refactor/adversarial-review-split was blocked on scripts/install.sh, blob f897dd8d identical to
  origin/main 50f95150's, because six pre-merge commits had touched the old monolithic installer. That content is on
  the remote and passed the gate there, the same reason the twin rule (_pgl_unpushed_commits) exists. Fix: a file
  whose tip blob equals its blob on the remote default branch is covered; test it beside the TWINS cases. Worked
  around honestly here by a real whole-file review of install.sh (pass p34), not a bypass. | conf: 90 |
  source: zuvo:refactor (push) | seen:1 | 2026-10-07

## Archived from backlog.md on 2026-10-09 (1 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-20261006-GPT61SOL-EFFORT-NONE: `gpt-6.1-sol` rejects `reasoning.effort=none` — HTTP 400
  "Unsupported value: 'none' is not supported with the 'gpt-6.1-sol' model. Supported values are: 'low',
  'medium', 'high', 'xhigh', and 'max'" (`~/.zuvo/adversarial-failures/1791272945-63453`). The codex-5.3
  lane's production effort is `none` (`ZUVO_CODEX_EFFORT_PRIMARY`), so any host that points that lane at
  gpt-6.1-sol gets nothing. The CI runners do exactly that: `/home/gha/.zuvo/adversarial.log` on ryzen-tf
  has 9,893 `gpt-6.1-sol` rows since 2026-09-30 and waw-tf 4,378, with ZERO counted findings (75% of
  answers under 100 chars, ~16 s on ~28k-char diffs) — the CI codex lane has reviewed nothing for a
  week. Not yet confirmed which CI job sets gpt-6.1-sol and whether it passes `none` (no driver in
  `/home/gha/.zuvo`; the job runs zuvo from its checkout). Fix: find the CI setting; the driver should
  refuse/bump an effort the model does not accept instead of logging `ok`/`empty`. Bench at `low`:
  +3 / 100%, "no issues" on 7/20 — weak either way. | severity: high | category: Infrastructure | conf: 85 — WONTFIX — filed on a misread: the "zero findings" came from reading column 8 (critical) instead of 7 (findings); the log header no longer matches its rows. Recount 2026-10-08: gpt-6.1-sol in CI = 3,566 findings over 10,414 calls on ryzen-tf (25% of reviews with findings), 1,794 over 4,711 on waw-tf. CI runs it at effort high (scripts/ci/bb-ai-review.sh in tgmdev/rdesigner), which the API accepts; only effort none is rejected, and nothing in production uses it with gpt-6.1-sol. A local reproduction of the CI call (--json --context, read access) on 5 benchmark diffs gave 0–2 findings each, the same with and without the context.

## Archived from backlog.md on 2026-10-09 (1 completed items moved out)
- [x] B-20261007-CPM-ARCHIVE-WORKTREE-REPO [P3][tooling][conf 85] [FIXED b4c5e18d — owner decision 2026-10-09: a backlog git tracks belongs to its checkout (zuvo_backlog_io.backlog_root); untracked keeps the main-checkout rule]: `backlog-archive.py --repo <linked worktree>` reads and writes the main checkout's backlog.
  - **What:** from the `comment-pass-merge` worktree, `backlog-archive.py status --repo .` reported `/Users/greglas/DEV/zuvo-plugin/memory/backlog.md` and "nothing resolved left". The branch's own backlog.md had a ticked `B-20261005-CP-PRS`, which turned test-backlog-grooming-smoke (A19b) red on the farm. Running `archive` from there would have written into the main checkout, which other agents share.
  - **Workaround used:** copied the branch's two backlog files into a scratch `git init` repo, ran `archive --repo <scratch>`, and copied the result back (commit 4f6c7d40).
  - **Fix:** when `--repo` names a worktree explicitly, operate on that tree's tracked `memory/backlog.md`, or refuse and name both paths. Never write silently into a different checkout.
