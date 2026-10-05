
## Archived from backlog.md on 2026-09-20 (1 completed items moved out)
- [x] B-A20260920-cb8b1c - [B-secaudit-2] pentest SCA preflight (0.5b): snippet is advisory; 4 adversarial rounds fixed real bugs (lockfile-specific tool, exit-non-zero-means-vulns-not-failure, pip-audit env-vs-lockfile, requirements unpinned). Residual: per-lockfile loop in polyglot trees left to agent. conf: 25

## Archived from backlog.md on 2026-09-21 (4 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-A20260921-42c6e3 - [B-seccorpus-2] tests/security-corpus/registry.test.sh — test robustness: column-scope the CWE assert, detect duplicate finding_type rows, replace substring seed-grep with anchored match, single-source the safe-pattern list from registry rows. Source: execute Task 2 adversarial (6 WARNING, 0 CRITICAL). conf: 35
- [x] B-A20260921-673238 - [B-seccorpus-5] tests/security-corpus/*/clean twins — adversarial WARNINGs for robustness beyond each target class (graphql NODE_ENV gating + complexity, xxe parse-budget, redos type-guard, ldap empty-string). Twins correctly defend their OWN class (corpus contract); broader hardening deferred. conf: 25
- [x] B-A20260921-22a186 - [B-seccorpus-7] GraphQL/serverless detection heuristics: adversarial WARNINGs — 'type Query' matches TS aliases, handler.ts matches *-handler.ts, resolver-args misses destructured {args}. Detection signals are heuristic + agent-confirmed (overlay needs corroborating signals like ApolloServer/serverless.yml). conf: 25
- [x] B-A20260921-2dec6a - [B-review-1] validate-pentest-output.sh — PENTEST_REGISTRY/PENTEST_MANIFEST env-overridable (test affordance) is also a prod-path override; low risk (local CI script, attacker would need env control) but consider a test-only guard. Source: zuvo:review self-review F4. conf: 35

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
