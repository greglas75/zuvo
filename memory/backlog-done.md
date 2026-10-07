
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
