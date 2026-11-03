# Tooling follow-ups from owner-attention session

Filed at the owner's request after reviewing the2026-11-01..03 session. These are process improvements, not instructions to edit live plugin installations. Existing unrelated dirty files in the main checkout were preserved.

- **B-codesift-setup-PROCESS-52478a0e** — Do not report a clean review when CodeSift scans zero files in a nonempty changed source scope. Evidence: Multiple review_diff calls returned pass100/0files after scoped indexing0files and one120s timeout; this session treated them as inconclusive manually. Remedy: Propagate zero-scope/incomplete status through skill preflight and require bounded native fallback; add regression fixture.
- **B-env-compat-PROCESS-c8b646fe** — Document and enforce followup_task to resume completed Codex workers. Evidence: send_message to completed worker did not restart work; session waited before noticing; followup_task resumed it. Tool descriptions distinguish the two. Remedy: Use explicit agent state and followup_task for new actionable task; send_message only informative to active worker.
- **B-SKILL-PROCESS-6e61a3b5** — Deploy skill must retain session authorization and honor repository branch-retention rules. Evidence: Installed deploy Phase2 repeats confirmation and proposes --delete-branch despite explicit no-branch-deletion user rule; session used pinned-SHA REST merge without deletion. Remedy: Make prior user authorization authoritative; never auto-add deletion; preserve sole-deployer coordination.
- **B-runlog-archive-side-effects-PROCESS-5b5e8672** — Separate logging a skill run from unsolicited backlog archive mutations. Evidence: append-runlog moved5entries in private plan worktree after several completed runs; restored only wrapper writes. Existing B-append-runlog-sweep-splits-heading-entry and B-append-runlog-BUG-d7474c1b cover corruption/wrongcwd, not permission to mutate on logging. Remedy: Make archive an explicit command or opt-in, report exact writes; logging should preserve backlog bytes by default.
- **B-review-provider-envelope-dispositions-PROCESS-2c5e73c2** — Normalize nested provider findings so every reviewed ID can receive a recorded disposition. Evidence: Session aggregate review contained64 IDs;22 AGY findings inside JSON response were not registered by parser and helper refused their dispositions. Raw report was read and manual disposition retained. Existing VERIFY-AUDIT-VACUOUS-PASS concerns a different report parser. Remedy: Normalize provider JSON response before ID extraction, test real redacted envelope shape, fail incomplete accounting instead of reporting zero findings.

Related existing entries: append-runlog wrong-CWD archive (`B-append-runlog-BUG-d7474c1b`) and heading-split corruption are distinct from unsolicited mutation; VERIFY-AUDIT-VACUOUS-PASS concerns a different report parser. Do not mark these resolved merely because this session worked around them.

<!-- Evidence Map
| Topic | Source |
| Index validity | shared/includes/codesift-setup.md; recorded0-file scans in session |
| Worker resume | shared/includes/env-compat.md; collaboration tool behavior in session |
| Deploy authorization | skills/deploy/SKILL.md Phase2; session global no-branch-deletion rule |
| Run logging | scripts/zuvo-home/append-runlog; session wrapper output moving5entries |
| Finding ingestion | session aggregate review64IDs,22AGY IDs not registered; manual report retained |
-->
