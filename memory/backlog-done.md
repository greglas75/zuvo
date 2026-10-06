
## Archived from backlog.md on 2026-09-20 (1 completed items moved out)
- [x] B-A20260920-cb8b1c - [B-secaudit-2] pentest SCA preflight (0.5b): snippet is advisory; 4 adversarial rounds fixed real bugs (lockfile-specific tool, exit-non-zero-means-vulns-not-failure, pip-audit env-vs-lockfile, requirements unpinned). Residual: per-lockfile loop in polyglot trees left to agent. conf: 25

## Archived from backlog.md on 2026-09-21 (4 ticked WITHOUT a recorded resolution — the reason was never written down; the tick is the only evidence)
- [x] B-A20260921-42c6e3 - [B-seccorpus-2] tests/security-corpus/registry.test.sh — test robustness: column-scope the CWE assert, detect duplicate finding_type rows, replace substring seed-grep with anchored match, single-source the safe-pattern list from registry rows. Source: execute Task 2 adversarial (6 WARNING, 0 CRITICAL). conf: 35
- [x] B-A20260921-673238 - [B-seccorpus-5] tests/security-corpus/*/clean twins — adversarial WARNINGs for robustness beyond each target class (graphql NODE_ENV gating + complexity, xxe parse-budget, redos type-guard, ldap empty-string). Twins correctly defend their OWN class (corpus contract); broader hardening deferred. conf: 25
- [x] B-A20260921-22a186 - [B-seccorpus-7] GraphQL/serverless detection heuristics: adversarial WARNINGs — 'type Query' matches TS aliases, handler.ts matches *-handler.ts, resolver-args misses destructured {args}. Detection signals are heuristic + agent-confirmed (overlay needs corroborating signals like ApolloServer/serverless.yml). conf: 25
- [x] B-A20260921-2dec6a - [B-review-1] validate-pentest-output.sh — PENTEST_REGISTRY/PENTEST_MANIFEST env-overridable (test affordance) is also a prod-path override; low risk (local CI script, attacker would need env control) but consider a test-only guard. Source: zuvo:review self-review F4. conf: 35

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
