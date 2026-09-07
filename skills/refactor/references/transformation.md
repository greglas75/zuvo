## Phase 3: Execution + Post-Audit + Adversarial Review

### Backup Branch (FULL mode)

Create a backup branch before making changes:

```bash
git checkout -b backup/refactor-[target]-[date]
git checkout -  # return to original branch
```

### Execute Refactoring

Apply the frozen plan in a fresh mechanical executor when delegation is permitted by the
resolved execution policy. Supply only the contract, caller/reuse findings, target paths,
verification commands and applicable CQ requirements. The coordinator retains ownership of
review and completion. Record the actual executor and its context isolation; a new thread with
the same model is not an independent review.

When delegation is forbidden or unavailable, apply the plan inline and record that isolation
was unavailable, citing the governing instruction or actual unavailable-tool result from the
resolved policy. The executor cannot invent a restriction to certify its own isolation. Do not claim a fresh context, request an unnecessary new conversation or
invent a capability restriction. A wait timeout is an observation, not cancellation: check the
existing worker before starting another. Missing callers or uncovered moved units return to
planning/characterization; they do not authorize new behavior. All verification and review
requirements still apply.

Record `PRE_REFACTOR_SHA = $(git rev-parse HEAD)` at the start of Phase 3, before any changes.

Apply the planned changes according to the extraction list, following these rules:

1. One extraction at a time. Verify tests pass after each extraction before starting the next. "Tests pass" here means a test that **actually exercises the extracted unit** — guaranteed by the Phase 2 coverage gate, which has already characterized every moved unit. If you reach an extraction whose unit has no exercising test, stop and go back to CHARACTERIZE_GAP; do not lean on build/type-check to wave it through.
2. Update all imports affected by each extraction (use the Dependency Mapper results).
3. Maintain behavioral equivalence -- the refactored code must produce identical outputs for identical inputs.
4. Follow CQ patterns from `cq-patterns.md` in all new code.
5. Respect file size limits throughout. If an extraction creates a file that exceeds the limit, split further.
6. **Leaves first, entry file last.** For a multi-file split, create every leaf module BEFORE
   rewiring anything. New leaves are unreferenced until wired, so the repo keeps compiling with the
   original entry file fully intact — then the entry file becomes ONE switch-over edit. The failure
   this prevents is specific: half-rewired imports when a run is interrupted (context compaction, a
   killed session, a timeout) leave a tree that neither builds nor reverts cleanly. Ordering the work
   this way makes every intermediate state a valid one.

**Behavioral equivalence is scoped to the MOVE, not the whole run.** Rule 3 means the *extraction/move* produces identical outputs — that is what the unchanged-tests-still-pass proof certifies. It does NOT mean "any bug you discover stays in the file." Bugs surfaced by the audits below are fixed in **Phase 3.5 (Bug Remediation)** within this same run, as a SEPARATE commit. A refactor that tidies a file but leaves its bugs is half a job — it forces a second pass over the same code later. "I must preserve behavior, so I'll backlog the bug" is the exact rationalization to avoid: preserve behavior in commit 1, fix the bug in commit 2, same session.

**Type-specific CodeSift tools (when available):**

| Refactor type | CodeSift tool | Use |
|---------------|--------------|-----|
| RENAME_MOVE | `rename_symbol(repo, old_name, new_name)` | LSP-based cross-file rename. Fallback: manual edit with grep. |
| BREAK_CIRCULAR | `find_circular_deps(repo)` before + after | Verify cycles are broken. Fallback: skip verification. |
| Any (post-execution) | `find_unused_imports(repo, file_pattern=SCOPE)` | Clean stale imports. Fallback: skip. |

### Failure Recovery

| Failure | Action |
|---------|--------|
| tsc/type-check fails | Fix type errors. Retry up to 3 times. If still failing: revert current extraction, mark in contract as BLOCKED, proceed to next extraction (GOD_CLASS) or stop (single extraction). |
| Tests fail after extraction | Revert to `LAST_PASSING_SHA` (updated after each successful extraction commit). Re-analyze: was the extraction incorrect, or does the test need updating? If test is testing internal implementation (not behavior): update test. If extraction broke behavior: revert extraction and try a different approach. |
| Lint fails | Fix lint issues. This should never block — lint is auto-fixable in most cases. |
| Adversarial CRITICAL | Fix immediately. Re-run adversarial on the fix. Max 2 iterations. |
| All verifications fail | Restore from backup branch. Mark contract as BLOCKED. Report to user. |

### Split-File Audit Rule

**After any refactoring that creates new files:** Run CQ self-eval on EACH extracted module, not just the orchestrator. The bugs move with the code. CQ failures (CQ5, CQ8, CQ9, CQ17, CQ19) live in the modules where the actual logic resides.

1. List the files to audit = the **scope-fence** files, INCLUDING the new modules this split created. A split EXTENDS its own scope-fence to the files it extracts — those new modules are in-fence by definition, so "audit every extracted module" and "stay inside the scope-fence" are the SAME set, not a contradiction. A file modified OUTSIDE the scope-fence is a fence VIOLATION to surface (backlog / ask), never an extra audit-and-ship target.
2. Run CQ1-CQ40 self-eval on EACH of those scope-fence files (orchestrator + every extracted module — the bugs move with the code)
3. Any CQ critical gate failure (CQ3/4/5/6/8/14 = 0) in ANY module blocks the commit — **when the failure is in code this refactor moved, touched, or created**. A PRE-EXISTING critical failure confined to UNTOUCHED units of an in-fence file (e.g. CQ8 in `persist()` while you extract `calculateTax`) is NOT a commit-blocker: it is identical before and after the diff, fixing it usually needs its own characterization tests + product decisions, and blocking on it would make incremental extraction of legacy god-files impossible. Disposition: verify it is byte-identical pre/post (no regression), disclose it loudly in the post-audit (`pre-existing, out-of-fence-unit`), and backlog it per Phase 3.5/Phase 4 — never silently, never as an excuse for a failure your diff introduced. (Both 2026-07-09 skill-eval executors independently hit this ambiguity and resolved it this way; this paragraph makes that the written rule.)

4. **Record the list.** Write the new modules into the CONTRACT as `modules_created` (repo-relative
   paths) the moment they land — not reconstructed at the end from memory or from `git status`,
   which by then also carries the fix commits. This list is already in your hand at step 1; it is
   the denominator the per-module coverage gate in Phase 3.6 divides by.

### CodeSift Post-Audit Verification (when CodeSift available)

After execution completes, stage all scope-fence files (`git add [specific files]`) first, then run:
```
review_diff(repo, since=PRE_REFACTOR_SHA, until="STAGED",
            checks="breaking-changes,test-gaps,dead-code,complexity,blast-radius",
            token_budget=10000)
impact_analysis(repo, since=PRE_REFACTOR_SHA)
changed_symbols(repo, since=PRE_REFACTOR_SHA)
diff_outline(repo, since=PRE_REFACTOR_SHA)
```

- **Scope fence:** If `impact_analysis` returns affected files OUTSIDE the scope fence → WARNING: unintended blast radius.
- **Behavioral equivalence:** REMOVED symbol consumed externally → CRITICAL: breaking change. MODIFIED signature → WARNING: verify callers updated.
- **CQ Auditor integration:** Pass `review_diff` output as `machine_checks` input. Auditor uses machine checks as baseline and focuses on domain-specific gates (CQ5, CQ8, CQ9, CQ14, CQ19, CQ25).
- **Boundaries:** If `check_boundaries` rules exist: run `check_boundaries(repo, rules=PROJECT_RULES)`. Otherwise skip.

**CLI-only CodeSift: an empty result is NOT a clean result.** The calls above pass `until="STAGED"`;
the CodeSift *CLI* does not necessarily support comparing against the staged tree. When only the CLI
is available, first determine whether staged comparison is supported. If it is not, do **NOT** fall
back to a commit-only diff command and read its empty output as "no problems found" — the staged
changes were never examined, and an empty answer to the wrong question is the most dangerous
possible input to a safety gate. Instead:

1. Record `machine_checks=degraded:cli-no-staged-diff` (it flows to the CQ Auditor and the report).
2. Refresh the structural index for the changed files (`index_file` per file — not a full re-index).
3. Substitute what the CLI *can* do on staged content: `git diff --staged --check` for whitespace/
   conflict damage, plus symbol-reference scans over the moved/renamed symbols to catch dropped
   consumers.

Never spend a second round trip re-issuing the unsupported form once it has failed.

When CodeSift unavailable: skip machine verification. Pass empty `machine_checks` to CQ Auditor. Log `[DEGRADED: CodeSift unavailable — machine verification skipped]`.

### CQ Post-Audit

Run CQ1-CQ40 on every modified and created file. Print ALL 40 gates per file:

```
CQ POST-AUDIT: order.service.ts (132L)
CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=1
CQ11=1 CQ12=1 CQ13=1 CQ14=1 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=1
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=1 CQ25=1 CQ26=N/A CQ27=1 CQ28=N/A
Score: 24/24 applicable -> PASS
```

Post-audit score must not be lower than pre-audit. Any regression is a bug in the refactoring.

**A tool response is not the audit.** `audit_scan`, `python_audit`, `framework_audit` and friends
answer a handful of checks each; printing their result and calling it `Score: 29/29` claims 29
evaluated gates when five ran. Every gate in the printed line must be one of: `1`/`0` (you
evaluated it), or `N/A` **with a reason** — a gate no tool covered and you did not read for is
neither, so evaluate it or record it as unevaluated and say the audit is partial. Report the
denominator honestly per `../../../shared/includes/gate-registry.md`: `score` over the full set,
`applicable_score` over what applied, and never a total larger than what was actually checked.

### Verification

**If running in a secondary worktree, bootstrap dependencies and scope the suite first** — see `env-compat.md` → "Secondary Worktree Bootstrap". A worktree does not inherit `node_modules`; verify the toolchain matches the main checkout, reuse the root install (never a partial package-local one), then scope type-check/tests to the **touched package(s)** (`--filter=<pkg>`). A pre-existing failure in an unrelated package is `pre-existing-out-of-scope`, not a blocker — do not burn the run rediscovering errors that were red before you started.

**When the full suite fails only in files this refactor never touched**, do not silently widen the
fence and do not wave it through either. Do all three: (a) record each failing file and its error,
(b) re-run the SCOPED suite plus type-check/build to show the touched surface is green, (c) re-run
the failing files alone — local parallelism and shared fixtures produce timeout flakes that vanish
when they are not competing. Then report **WARN with that evidence attached**, not PASS. Expand the
scope fence only if the failure reproduces through a dependency path this refactor actually changed
— that makes it a regression, and the fence was wrong. Otherwise it is pre-existing or
environmental, and the honest record says which one and how you told them apart.

Run the verification suite (scoped per above when in a worktree):

1. Type checking (tsc, mypy, or equivalent)
2. Test suite — scoped to touched package(s) in a worktree; full suite in the primary checkout
3. Lint (if configured)
4. CQ self-eval on all modified files
5. Q1-Q25 on all modified test files

> ⛔ **This 5-item suite is NOT the finish line — it is a mid-pipeline checkpoint.** Reaching the end of it does NOT mean the refactor is verified, done, or committable. **There is no "condensed", "light", or "5-step" refactor path in FULL mode** — if you find yourself treating this list as the whole workflow, you are mid-pipeline, not done. The Independent CQ Auditor (blind audit, next section), the CQ1-CQ40 pre/post audit, and the Adversarial Review are part of the SAME non-optional sequence. Do **not** commit-as-done, do **not** report `COMPLETE`, and **never** defer the blind audit or adversarial review to a "user decision" / "awaiting approval" — they are HARD GATES that run automatically without asking. A refactor that stopped here is **BLOCKED, not done** (see Completion Gate Check).

### Independent CQ Auditor (FULL mode — HARD GATE, non-skippable, default tier, read-only)

After the lead's post-audit, dispatch an independent CQ Auditor agent. Run CQ1-CQ40 independently on ALL modified/created files. Does NOT trust the lead's scores. Catches N/A abuse and rubber-stamped gates.

**This is a HARD GATE, not best-effort.** The lead's own CQ post-audit is NOT a substitute — the whole point is a second, independent pass that never sees the lead's scores. In FULL mode (single and batch), the run CANNOT reach `COMPLETE`/PASS without it. Allowed telemetry values for `blind_audit` are `clean:strict` or `clean:degraded[:<reason>]` (findings applied or deferred) — the optional `:<reason>` suffix (`:no-machine-checks` when CodeSift is offline, `:same-model` under a single-agent lock) records *why* it was degraded and is still a PASS value, just lower-confidence; it never blocks on its own. **`skipped` and `not_run` are pipeline FAILURES, not neutral states** — if the auditor genuinely cannot be dispatched in this environment, mark the run `BLOCKED` and say so loudly; never claim PASS/WARN with the blind audit absent. A self-rolled lighter pass reported as "done" is forbidden — run the real independent pass or report BLOCKED.

**CodeSift availability does NOT gate the auditor.** The auditor is an LLM agent that reads the full source + CQ checklist itself; CodeSift only enriches the optional `machine_checks` input. When CodeSift is unavailable, pass empty `machine_checks` and record `blind_audit: clean:degraded:no-machine-checks` — **but still RUN it.** "CodeSift unavailable" is never a reason to skip the blind audit. (This is the exact regression seen in the field: `codesift:unavailable` was being conflated with `blind_audit:skipped`.)

**Review roles run INLINE on Codex — not because it cannot dispatch, but because a codex thread
reviewing a codex author is the same model. Run the auditor role INLINE, do not BLOCK.** Where the harness forbids sub-agent dispatch (Codex's single-agent lock — see `env-compat.md`), "cannot dispatch a separate agent" is NOT the "cannot run it at all" case above. Run the CQ Auditor role inline as a distinct blind pass: re-read the full source against the CQ1-CQ40 checklist WITHOUT consulting the lead's scores, and record `blind_audit: clean:degraded:same-model` (a distinct marker from the CodeSift-offline `clean:degraded:no-machine-checks` case, so downstream can tell weaker same-model independence apart from a merely un-enriched cross-model run). Cross-model independence is then carried by the adversarial-review gate below **when rotation selects a different model family** — so under the single-agent lock, ensure the rotation pool includes a provider outside the orchestrator's own family; if it cannot, record `adversarial: …:degraded:same-family` rather than implying independence that did not happen. `BLOCKED` is reserved for when neither an inline nor a dispatched blind pass can run at all — the single-agent lock is not that case.

**Input:** Full source of each file, CQ checklist, CQ patterns, tech stack, `machine_checks` from CodeSift (if available).

The **orchestrator** applies FIX-NOW items in Phase 3.5 (as the separate fix commit). Only items whose fix needs files OUTSIDE the scope fence, or that require a behavior/product decision the user declined, go to the backlog — deferral is a fix-SCOPE decision, never a severity or size one.
