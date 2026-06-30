# Implementation Plan: close the two enforcement gaps the v1.4.0 self-review exposed

**Spec:** inline — no spec
**spec_id:** none
**planning_mode:** inline
**source_of_truth:** inline brief (the two gaps flagged in `feedback_plan_then_execute_always`)
**plan_revision:** 2
**status:** Approved
**Created:** 2026-06-30
**Tasks:** 7 (+1 spike, +1 smoke)
**Estimated complexity:** complex (two new cross-harness enforcement behaviors on the git-hook layer)

## Problem (why this)

The v1.4.0 self-review found that NOTHING caught a substantial, unreviewed, hand-rolled change
shipped to main — because:
- **Gap 1:** after `zuvo:plan` produces an Approved plan (`zuvo/plans/active-plan.md`, `status: pending`),
  no gate stops an agent from **ignoring it and hand-rolling** the execution (skipping `zuvo:execute`
  and its per-task review). That is exactly the `no-gate-substitution` failure I committed.
- **Gap 2:** the pipeline-entry pre-push gate is **opt-in per repo** (`scripts/install.sh` ~L373) and
  the `zuvo-plugin` repo itself never opted in (no `.git/hooks/pre-push`), so zuvo does not dogfood
  its own gate — its own substantial unreviewed push to main was caught by nothing.

## Architecture Summary

Reuse the refactor commit-gate machinery built in v1.4.0 (`hooks/refactor-safety-gate.sh` entry +
`hooks/lib/refactor-gate-lib.sh` + `scripts/install-refactor-gate.sh` self-install). Both gaps are
git-hook work on the same layer.

1. **Gap 1 — plan→execute bind (new gate check).** Add `plan_execute_gate_check` to the gate lib: if
   `zuvo/plans/active-plan.md` exists with `status: pending` (Approved but execute NOT started) AND the
   staged/pushed production files intersect the plan's declared `**Files:**`, BLOCK with "Approved plan
   pending — run `zuvo:execute`, do not hand-roll." Lifecycle (verified in `skills/execute/SKILL.md`):
   `pending` (plan) → `in-progress` (execute sets it at :235, before any task commit) → `completed` (:855).
   So the gate only fires on `pending` (hand-roll before execute); execute's own commits run under
   `in-progress` and pass. The existing entry (`refactor-safety-gate.sh`) calls BOTH checks (refactor
   CONTRACT + plan-execute) so it reuses the self-install + fail-open + human/stale bypass already there.

2. **Gap 2 — dogfood the pipeline gate (VERSIONED wiring).** `.git/hooks/` is NOT tracked, so wiring it
   would only gate the author's local clone (cross-model CRITICAL — both providers). Instead commit a
   **tracked `.githooks/` dir** (`.githooks/pre-push`, `.githooks/pre-commit`) whose hooks call the repo's
   OWN `hooks/pre-push-gate.sh` (pipeline-entry) + `hooks/refactor-safety-gate.sh` (work-gate) by repo-root
   path — self-contained, every clone gets them. `scripts/setup-dev-hooks.sh` performs the ONE per-clone
   activation: `git config core.hooksPath .githooks` (idempotent, fail-open). A fresh clone is gated after
   running setup once; the hooks themselves are versioned and reviewable. (`core.hooksPath` lives in
   `.git/config` which git cannot version — the single setup step is unavoidable and is the opt-in, DC4.)

Both inherit the v1.4.0 safety properties: fail-OPEN (never brick git), human-committer + stale bypass,
never mutate a tracked hooksPath, `ZUVO_ALLOW_ADHOC=1` logged escape, no-op when nothing applies.

## Technical Decisions

- **Reuse, don't fork.** `plan_execute_gate_check` goes in `hooks/lib/refactor-gate-lib.sh` (rename the
  file's header to "zuvo work-gate lib"); the entry runs both checks. One self-install covers both.
- **Plan-file source.** The gate extracts `**Files:**` lines from the plan doc that `active-plan.md`
  points to (jq-free, `grep`/`sed`), and intersects with the staged set using the SAME hardened matching
  as the v1.4.0 fix (`grep -Fq --`, `--no-renames`, `--name-only`, `set -f`).
- **Status gate.** Only `status: pending` blocks. `in-progress`/`completed`/absent → allow. This is what
  makes execute's own commits pass and hand-rolling fail.
- **Gap 2 is repo-local + opt-in by design** (we do NOT auto-wire every user repo — that is the user's
  choice). `setup-dev-hooks.sh` is the explicit opt-in; we run it for zuvo-plugin and document it.
- **No new threat-model claims.** Like the refactor-gate, these are process-discipline gates for
  cooperating agents, not security boundaries.

## Quality Strategy

- Lib + scripts are POSIX shell ⇒ genuine TDD (block/allow assertions in a temp repo).
- The v1.4.0 review's lessons are baked in from task 1: hardened path matching (`-F`/`--no-renames`/`set -f`),
  full pre-push range, fail-open, human/stale bypass — these are REQUIREMENTS, not rediscoveries.
- Risk: false-blocking unrelated commits → mitigated by the plan-file intersection + `pending`-only trigger.

## Coverage Matrix

| Row ID | Authority item | Type | Primary task(s) | Notes |
|--------|----------------|------|-----------------|-------|
| G1 | plan→execute bind: pending plan + plan-file commit ⇒ blocked | goal | Task 2, 3 | the bind I lacked |
| G2 | zuvo-plugin dogfoods the pipeline-entry pre-push gate | goal | Task 4, 5 | repo wiring |
| DC1 | reuse v1.4.0 gate infra (entry/self-install/lib), don't fork | constraint | Task 2 | |
| DC2 | inherit all v1.4.0 safety: fail-open, human/stale bypass, never clobber, ALLOW_ADHOC | constraint | Task 1, 2, 4 | |
| DC3 | hardened matching from the v1.4.0 fix (`-F`/`--no-renames`/`set -f`/full range) | constraint | Task 1, 2 | no regression |
| DC4 | Gap 2 stays opt-in (do not auto-wire arbitrary user repos) | constraint | Task 4 | |

## Review Trail
- Phase 1: direct (Light — shell/markdown on a just-deep-worked indexed repo; execute active-plan lifecycle + pipeline-gate opt-in verified by reading `skills/execute/SKILL.md` + `scripts/install.sh`). Explore sub-agents lack CodeSift and would re-explore weaker.
- Plan reviewer: rev 1 -> direct (Light); rev 2 -> cross-model fixes applied
- Cross-model validation: rev 1 -> executed (codex-5.3 + gemini), findings applied in rev 2:
  - CRITICAL (both providers) Task 5 wired untracked `.git/hooks` → only the author's clone gated. FIXED: tracked `.githooks/` + `core.hooksPath=.githooks` (versioned, every clone; one setup step).
  - CRITICAL (codex) Task 6 didn't assert the built artifacts ship `setup-dev-hooks.sh`. FIXED: per-harness grep of both artifacts.
  - WARNING (both) verification theater (bare "ALL PASS"). FIXED: every Verify now asserts exact exit code + specific stdout/stderr token.
  - WARNING (gemini) Task 7 mapped to non-existent AC9. FIXED: maps to G1+G2.
  - WARNING (gemini) happy-path-only `active-plan.md` parsing. FIXED: Task 1+2 add explicit fail-OPEN cases (missing plan doc, empty `**Files:**`).
- Status gate: Reviewed (reviewer direct + cross-model executed/recorded). Awaiting user Approval.

## Task Breakdown

### Task 1: Spike — plan-execute gate mechanism (de-risk)
**Files:** scratchpad temp repo
**Surface:** integration
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: in a temp repo, prove SIX cases with a throwaway hook reading `zuvo/plans/active-plan.md` + a plan doc with `**Files:** app.ts`: (1) `status: pending` + staged `app.ts` (a plan file) + AI run → commit BLOCKED (exit 1, stderr token `zuvo:execute`); (2) `status: in-progress` → ALLOWED (exit 0); (3) `status: pending` + staged `other.ts` (not a plan file) → ALLOWED (no intersect); (4) no active-plan → ALLOWED; (5) **fail-OPEN**: `active-plan.md` references a plan doc that does not exist → ALLOWED (exit 0, no crash); (6) **fail-OPEN**: plan doc present but has NO `**Files:**` block → ALLOWED (exit 0). Each case asserts an exact exit code.
- [ ] GREEN: minimal `plan_execute_gate_check`: read `active-plan.md` status; if `pending`, extract `**Files:**` from the referenced plan doc, intersect (hardened: `grep -Fq --`), block on hit. Decide: how `active-plan.md` references the plan doc (the `plan:` field), and the exact `**Files:**` extraction.
- [ ] Verify: `bash <scratch>/spike-pe/run.sh`
  Expected: `BLOCK | ALLOW(in-progress) | ALLOW(no-intersect) | ALLOW(no-plan)` 4/4
- [ ] Acceptance Proof: AC-SPIKE · integration · scripted temp-repo commits · exit 1/0/0/0 · `zuvo/proofs/task-1-pe-spike.txt`
- [ ] Commit: none (carry the proven status+file-extraction into Task 2). Record `[DECISION: plan-ref-field, files-extraction]` in Review Trail.

### Task 2: `plan_execute_gate_check` in the gate lib + wire into the entry
**Files:** `hooks/lib/refactor-gate-lib.sh`, `hooks/refactor-safety-gate.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 1

- [ ] RED: `tests/hooks/test-plan-execute-gate.sh` asserts `plan_execute_gate_check` returns BLOCK/ALLOW for all 6 spike cases (incl. the two fail-OPEN: missing referenced plan doc, and empty/absent `**Files:**` block — each exit 0, no crash even under `set -u`) + human-bypass (no AI env → ALLOW) + `ZUVO_ALLOW_ADHOC=1` escape; and that the entry runs BOTH checks — a refactor CONTRACT violation still blocks AND a plan-execute violation also blocks (assert each with exact exit code + a specific stderr token, not a bare "PASS").
- [ ] GREEN: implement `plan_execute_gate_check` reusing the hardened matching helpers; the entry calls refactor check then plan-execute check (block if EITHER blocks); update the lib/entry headers to "zuvo work-gate".
- [ ] Verify: `bash tests/hooks/test-plan-execute-gate.sh`
  Expected: `ALL PASS`
- [ ] Acceptance Proof: AC-G1 · integration · the test suite · pending plan blocks, in-progress/no-plan allow, both checks active · `zuvo/proofs/task-2-pe-gate.txt`
- [ ] Commit: `feat(hooks): plan→execute bind — pending Approved plan + plan-file commit is blocked`

### Task 3: Regression — the exact v1.4.0 hand-roll scenario is now caught
**Files:** `tests/hooks/test-plan-execute-gate.sh` (extend)
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 2

- [ ] RED: reproduce the v1.4.0 failure in a temp repo — write an Approved plan + `active-plan.md status: pending`, then attempt to commit one of the plan's production files WITHOUT running execute (status stays pending) → must BLOCK. Then flip status to `in-progress` and the same commit → ALLOWED (execute path).
- [ ] GREEN: any adjustment needed to make the scenario pass.
- [ ] Verify: `bash tests/hooks/test-plan-execute-gate.sh`
  Expected: includes `hand-roll blocked` + `execute-path allowed`, ALL PASS
- [ ] Acceptance Proof: AC-G1 · integration · scenario test · the v1.4.0 hand-roll is blocked, the execute path passes · `zuvo/proofs/task-3-handroll.txt`
- [ ] Commit: `test(hooks): the v1.4.0 hand-roll-past-execute scenario is now gated`

### Task 4: tracked `.githooks/` + `scripts/setup-dev-hooks.sh` (versioned, every clone)
**Files:** `.githooks/pre-push`, `.githooks/pre-commit`, `scripts/setup-dev-hooks.sh`
**Surface:** integration
**Complexity:** complex
**Dependencies:** Task 2

- [ ] RED: `tests/hooks/test-setup-dev-hooks.sh` — in a temp repo that has a `.githooks/` dir, running setup sets `core.hooksPath=.githooks` (assert `git config --get core.hooksPath` == `.githooks`, exit 0); re-running is idempotent (config unchanged, exit 0); the committed `.githooks/pre-push` invokes `hooks/pre-push-gate.sh` by repo-root path and the gate's block path returns non-zero with stderr containing `pipeline`; fail-OPEN if `hooks/pre-push-gate.sh` is absent (exit 0, no crash). Each assertion checks an EXACT exit code + a specific stdout/stderr token (no bare "PASS").
- [ ] GREEN: author `.githooks/{pre-push,pre-commit}` (resolve repo root via `git rev-parse --show-toplevel`; call the repo's own `hooks/pre-push-gate.sh` + `hooks/refactor-safety-gate.sh`; fail-open if absent) + `setup-dev-hooks.sh` (sets `core.hooksPath=.githooks` idempotently).
- [ ] Verify: `bash tests/hooks/test-setup-dev-hooks.sh; echo "exit=$?"`
  Expected: final line `exit=0` AND output contains `core.hooksPath=.githooks set`, `idempotent`, `pre-push invokes pipeline gate`, `fail-open(no gate)`
- [ ] Acceptance Proof: AC-G2 (DC4) · integration · the test (exact exit codes + tokens) · versioned hooks, one-step activation, fail-open · `zuvo/proofs/task-4-setup.txt`
- [ ] Commit: `feat: tracked .githooks + setup-dev-hooks — versioned, per-clone pipeline+work gating`

### Task 5: Dogfood — activate `.githooks/` in zuvo-plugin + a tracked guard
**Files:** `scripts/setup-dev-hooks.sh` (run it), `tests/hooks/test-dogfood-wired.sh`
**Surface:** integration
**Complexity:** standard
**Dependencies:** Task 4

- [ ] RED: `tests/hooks/test-dogfood-wired.sh` — clone-simulation: in a fresh checkout of the repo's tracked tree (the `.githooks/` dir is present), run `setup-dev-hooks.sh`, then assert that a substantial unreviewed push is REJECTED (the pipeline-entry gate fires, exit non-zero, stderr contains `pipeline`/`review`). This proves the systemic gap is closed for ANY clone, not just the author's. Uses exact exit code + stderr token.
- [ ] GREEN: run `setup-dev-hooks.sh` in the live zuvo-plugin repo (sets its `core.hooksPath=.githooks`); the guard test (tracked) verifies the versioned hooks gate a clone.
- [ ] Verify: `bash tests/hooks/test-dogfood-wired.sh; echo "exit=$?"` AND `git -C . config --get core.hooksPath`
  Expected: `exit=0`, stderr token present; `core.hooksPath` == `.githooks` in the live repo
- [ ] Acceptance Proof: AC-G2 · integration · clone-simulation guard test (exact exit + token) · any clone is gated after one setup · `zuvo/proofs/task-5-dogfood.txt`
- [ ] Commit: `chore: dogfood the pipeline-entry gate — activate .githooks in zuvo-plugin + guard`

### Task 6: Build + install integration
**Files:** `scripts/install.sh`
**Surface:** config
**Complexity:** standard
**Dependencies:** Task 2, Task 4

- [ ] RED: `./scripts/install.sh` does not yet ship `setup-dev-hooks.sh`; the updated lib/entry must reach all four harness caches intact.
- [ ] GREEN: ship `setup-dev-hooks.sh` + the updated work-gate lib/entry; verify Codex/Cursor/Antigravity builds pass (no untransformed paths, awk/regex intact).
- [ ] Verify: `./scripts/install.sh; echo "exit=$?"` AND grep EACH built harness for both artifacts: `grep -lq plan_execute_gate_check ~/.codex/.../hooks/lib/refactor-gate-lib.sh` and `ls ~/.codex/.../scripts/setup-dev-hooks.sh` (and Cursor/Antigravity equivalents)
  Expected: `exit=0`, 4 providers, `plan_execute_gate_check` present in built lib AND `setup-dev-hooks.sh` shipped in each harness output
- [ ] Acceptance Proof: AC-DC1 · config · install run + per-harness grep of BOTH artifacts · gate + setup shipped intact everywhere · `zuvo/proofs/task-6-install.txt`
- [ ] Commit: `build: ship setup-dev-hooks + the plan→execute work-gate to all harnesses`

### Task 7: Docs (always-run gate task)
**Files:** `docs/pipeline.md`, `CLAUDE.md`
**Surface:** docs
**Complexity:** standard
**Dependencies:** Task 2, Task 4, Task 5

- [ ] RED: `grep -i 'plan.*execute.*gate\|setup-dev-hooks' docs/pipeline.md` — not yet documented.
- [ ] GREEN: document the plan→execute bind + `setup-dev-hooks.sh` (dev-setup step that dogfoods the gate); print `[DECISION: version bump = minor — new enforcement behavior] → COMPLETE`.
- [ ] Verify: `grep -i 'plan→execute\|setup-dev-hooks' docs/pipeline.md` matches AND decision marker printed
  Expected: documented + version decision explicit
- [ ] Acceptance Proof: G1 + G2 · docs · grep + marker · plan→execute bind + setup-dev-hooks documented + version decided · `zuvo/proofs/task-7-docs.txt`
- [ ] Commit: `docs(pipeline): plan→execute bind + setup-dev-hooks (dogfood the gate)`

## Whole-feature Smoke Proofs

- **SMOKE1 — end-to-end: hand-rolling an Approved plan is blocked, the execute path passes**
  - Preconditions: temp repo with the work-gate self-installed + an Approved plan + `active-plan.md status: pending`.
  - Proof: stage a plan production file and `git commit` (status pending); then set status `in-progress` and commit again.
  - Expected: first commit REJECTED ("run zuvo:execute"); second ALLOWED.
  - Artifact: `zuvo/proofs/smoke-plan-execute-bind.txt`
- **SMOKE2 — dogfood: a substantial unreviewed push in a zuvo-plugin clone is gated**
  - Preconditions: a clone of zuvo-plugin with `setup-dev-hooks.sh` run.
  - Proof: make a substantial unreviewed production change and `git push`.
  - Expected: pipeline-entry pre-push gate REJECTS it (no review coverage) — the v1.4.0 gap closed.
  - Artifact: `zuvo/proofs/smoke-dogfood-gate.txt`
