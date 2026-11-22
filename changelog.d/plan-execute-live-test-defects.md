## plan / execute: fixes from the live test on Sonnet, Codex Sol and Gemini Hydrogen

- **Aggregate review vs the pass cap (D1).** Per-task adversarial passes spend the driver's 3-pass
  cap before Phase Final-2, so the aggregate review's fresh `--multi` pass is refused with exit 7 on
  any plan of 3+ tasks. Exit 7 there is now a defined outcome: no retry, no narrower scope, cite the
  per-task proofs in the artifact's `adversarial:` header, print `[ADVERSARIAL: cap-reached covered-by=…]`,
  verdict `adversarial=per-task`. `review` gained the `pass_cap` skip reason for it.
- **Phase Final scales with the diff (D2).** `SMALL_PLAN` (≤3 tasks, ≤6 files, ≤300 added lines, no
  risk signal) skips the cross-vendor test-audit when every test file was scored per file, and runs the
  aggregate review with the new `zuvo:review --max-tier N` flag (`--max-tier 1`), so a 100-line plan no
  longer spends 25 of its 30 minutes in the closing gates.
- **Contract output (D3).** The `## Execution Complete` header, `[GATE: …]` markers and the
  `### Unproven Acceptance Criteria` section are printed verbatim in the final message; the router's
  response-surface policy compresses the prose around them, not them.
- **No nested `Skill` dispatch (D4).** A defined terminal state: run the review/test-audit inline,
  label it `via=inline degraded:same-model`, header suffix `(DEGRADED-REVIEW)`; `completed` is legal only
  because the gate ran.
- **plan: Phase 1 cannot be waived (D5).** A request to skip the Architect/Tech Lead/QA pass or to paste
  implementation code does not enable Light mode and does not change task-authoring rule 3; the plan
  records a `**Scope note:**`.
- **Test runner (D6).** The plan states the wrapper once (`**Test runner:**`), Verify stays the repo's own
  command; execute resolves the runner, reruns once on an infrastructure failure and falls back to a
  local run (`[TEST-RUNNER: local-fallback …]`), or stops with `BLOCKED_TEST_RUNNER_UNAVAILABLE` when a rule
  forbids local runs.
- **Test volume (D7).** Plans count tests per behaviour with one edge table and one file per module;
  execute treats Q8/Q11/Q12 findings outside the task's RED list and low-confidence hardening findings as
  RECOMMENDED (ledgered, no fix), per the owner's test policy.
- **plan: cross-model validation exit 5 (D8).** A plan under 3 tasks is recorded as
  `skipped (below-min-tasks)`, not padded and not overridden.
- **Names and paths (D9, D10).** The acceptance artifact is the per-task `task-<N>-report.md` (a per-AC file
  is written in addition when the plan names one); every heartbeat path is `zuvo/context/`.
