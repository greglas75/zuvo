# Implementation Plan: write-tests Reviewer Model Routing

**Spec:** inline -- no spec
**spec_id:** none
**planning_mode:** inline
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-12
**Tasks:** 5
**Estimated complexity:** 2 standard, 3 complex

## Architecture Summary

This change is a runtime routing feature with one bounded rollout target:

- `skills/write-tests/SKILL.md` owns Step 3.5 orchestration and is the only place that can choose a reviewer based on the writer's current model.
- `skills/write-tests/agents/blind-coverage-auditor*.md` provide the isolated read-only audit instructions; they must become lane-addressable rather than statically pinned to one model.
- `shared/includes/env-compat.md` is the shared policy surface for environment-specific reviewer dispatch and degraded behavior.
- `scripts/reviewer-model-route.sh` becomes the single deterministic resolver for `writer -> reviewer` routing.
- `scripts/install.sh`, `scripts/build-codex-skills.sh`, `scripts/build-cursor-skills.sh`, and `scripts/build-antigravity-skills.sh` must materialize abstract reviewer lanes into real platform model names.

The rollout is intentionally limited to `write-tests` blind coverage audit. The routing primitive should be reusable later for `test-quality-reviewer`, `plan-reviewer`, `quality-reviewer`, and other read-only reviewer agents, but those integrations are out of scope for this first implementation.

## Technical Decisions

- **Runtime, not build-time, is the source of truth.** "Different from writer" cannot be solved by build scripts alone because the writer model is only known at execution time.
- **Use abstract reviewer lanes.** Source artifacts should stop hardcoding `sonnet`/`opus` for reviewer roles. Use two abstract lanes instead:
  - `review-primary` = strongest preferred reviewer for that platform
  - `review-alt` = strongest alternate reviewer that is different from the writer when `review-primary` would match the writer
- **Keep one deterministic resolver.** Put the routing matrix in `scripts/reviewer-model-route.sh`, not duplicated inline across skills and build scripts.
- **First rollout only on Step 3.5.** Do not expand this plan to all reviewer agents yet. That would turn a bounded `write-tests` improvement into infra churn across the whole repo.
- **Cursor/other sequential environments must degrade explicitly.** If the environment cannot honor an alternate reviewer model, the skill should record `same-model-fallback` or equivalent degraded routing status rather than pretending the review was cross-model.
- **Print the actual reviewer choice.** Step 3.5 output should expose the chosen reviewer lane and concrete model so users can see whether the audit was cross-model or fallback.
- **Preserve strict blind-audit semantics.** Reviewer model routing improves independence, but it does not replace the existing requirement for isolated production-first blind audit.

## Quality Strategy

- **Primary regression target:** model-selection drift between `write-tests`, agent artifacts, and build/install transforms.
- **Primary automated check:** a dedicated Bats suite for `scripts/reviewer-model-route.sh` covering Claude, Codex, and degraded environments.
- **Packaging validation:** every build target must prove that no abstract reviewer lanes remain in emitted artifacts, and packaging logic should have its own small automated harness instead of relying only on one-off shell checks.
- **Prompt quality validation:** `skills/write-tests/SKILL.md` must keep Step 3.5 ordering and strict-audit gates intact after routing logic is added.
- **Integration checkpoint:** before editing Step 3.5, run one routed happy-path case and one degraded fallback case against emitted artifacts so runtime/build mismatches surface early.
- **Highest risk areas:**
  - `skills/write-tests/SKILL.md` claiming cross-model routing without actually selecting a different reviewer
  - `scripts/install.sh` leaving unresolved abstract model lanes in Claude cache
  - `scripts/build-cursor-skills.sh` collapsing both lanes to the same runtime while the skill still claims a different model was used
- **CQ posture:** this is markdown + shell infrastructure work. Quality focus is determinism, buildability, and truthful degraded states, not runtime business-logic CQ gates.

## Task Breakdown

### Task 1: Add a shared reviewer-model resolver and routing contract
**Files:** `/Users/greglas/DEV/zuvo-plugin/shared/includes/env-compat.md`, `/Users/greglas/DEV/zuvo-plugin/scripts/reviewer-model-route.sh`, `/Users/greglas/DEV/zuvo-plugin/scripts/tests/reviewer-model-route.bats`
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED 1a: Add a Bats test file for reviewer routing. It must fail initially because `scripts/reviewer-model-route.sh` does not exist and `env-compat.md` has no reviewer-lane contract. Cover at minimum:
  - `CLAUDE_MODEL=haiku` -> `review-primary` / `opus`
  - `CLAUDE_MODEL=sonnet` -> `review-primary` / `opus`
  - `CLAUDE_MODEL=opus` -> `review-alt` / `sonnet`
  - `ZUVO_CODEX_MODEL=gpt-5.4-mini` -> `review-primary` / `gpt-5.4`
  - `ZUVO_CODEX_MODEL=gpt-5.4` -> `review-alt` / `gpt-5.3-codex`
  - `ZUVO_CODEX_MODEL=gpt-5.3-codex` -> `review-primary` / `gpt-5.4`
  - unknown or unsupported environment -> degraded same-model fallback status
- [ ] GREEN 1b: Create `scripts/reviewer-model-route.sh` as the single routing source of truth. It should resolve:
  - platform
  - detected writer model string
  - writer lane (`small`, `strong_primary`, `strong_alt`, or `unknown`)
  - reviewer lane (`review-primary`, `review-alt`, or `same-model-fallback`)
  - concrete reviewer model string
  - routing status (`ok`, `same-model-fallback`, `unknown-writer-model`)
  Extend `shared/includes/env-compat.md` with a concise "Reviewer Model Routing" section that explains these lanes and the degraded behavior policy.
- [ ] Verify: `bats scripts/tests/reviewer-model-route.bats`
  Expected: all routing cases pass and the resolver emits deterministic output for Claude and Codex plus explicit degraded fallback for unsupported environments.
- [ ] Acceptance: the repo has one authoritative writer->reviewer routing matrix instead of ad hoc inline logic.
- [ ] Commit: `add reviewer model routing resolver`

### Task 2: Add lane-based blind-audit reviewer artifacts
**Files:** `/Users/greglas/DEV/zuvo-plugin/skills/write-tests/agents/blind-coverage-auditor.md`, `/Users/greglas/DEV/zuvo-plugin/skills/write-tests/agents/blind-coverage-auditor-alt.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] Baseline: Verify the current repo has only one blind-audit reviewer artifact pinned to a static model and no alternate lane for "different from writer".
- [ ] GREEN: Convert the existing `blind-coverage-auditor.md` to the primary reviewer lane and add `blind-coverage-auditor-alt.md` for the alternate lane.
  - `blind-coverage-auditor.md` should use abstract reviewer lane metadata for the primary reviewer model.
  - `blind-coverage-auditor-alt.md` should carry the same body and strict blind-audit instructions, but use the alternate reviewer lane metadata.
  - Keep the instruction bodies aligned except for `name`, `description`, and reviewer-lane model metadata.
- [ ] Verify: `rg -n "^name: blind-coverage-auditor(-alt)?$|^model: review-primary$|^model: review-alt$|Audit mode: strict" skills/write-tests/agents/blind-coverage-auditor*.md`
  Expected: one primary reviewer lane artifact, one alternate reviewer lane artifact, and identical strict-audit semantics in both.
- [ ] Acceptance: `write-tests` has an alternate blind-audit reviewer artifact available for cross-model routing.
- [ ] Commit: `add blind audit reviewer lanes`

### Task 3: Teach platform packaging to materialize reviewer lanes
**Files:** `/Users/greglas/DEV/zuvo-plugin/scripts/install.sh`, `/Users/greglas/DEV/zuvo-plugin/scripts/build-codex-skills.sh`, `/Users/greglas/DEV/zuvo-plugin/scripts/build-cursor-skills.sh`, `/Users/greglas/DEV/zuvo-plugin/scripts/build-antigravity-skills.sh`
**Complexity:** complex
**Dependencies:** Task 1, Task 2
**Execution routing:** deep implementation tier

- [ ] RED: After Task 2, build output would still leak abstract `review-primary` / `review-alt` model lanes because the packagers only know `sonnet` / `opus` / `haiku`.
- [ ] GREEN: Update each packaging path:
  - `scripts/install.sh` (Claude cache) maps `review-primary -> opus`, `review-alt -> sonnet`
  - `scripts/build-codex-skills.sh` maps `review-primary -> gpt-5.4`, `review-alt -> gpt-5.3-codex`
  - `scripts/build-cursor-skills.sh` maps both reviewer lanes to `inherit`, because Cursor cannot select a different reviewer model today
  - `scripts/build-antigravity-skills.sh` maps `review-primary -> gemini-3.1-pro-high`, `review-alt -> gemini-3.1-pro-low`
  - each build/install path fails loudly if unresolved reviewer lanes remain in emitted artifacts
- [ ] Verify 3a: Add or extend a small Bats harness for packaging transforms. It must assert per-platform lane materialization from the emitted blind-audit artifacts, not just source text presence.
  - Codex output resolves to `gpt-5.4` / `gpt-5.3-codex`
  - Cursor output resolves both lanes to `inherit`
  - Antigravity output resolves to `gemini-3.1-pro-high` / `gemini-3.1-pro-low`
- [ ] Verify 3b: `bash scripts/build-codex-skills.sh >/tmp/reviewer-codex.log 2>&1 || { cat /tmp/reviewer-codex.log; exit 1; }; bash scripts/build-cursor-skills.sh >/tmp/reviewer-cursor.log 2>&1 || { cat /tmp/reviewer-cursor.log; exit 1; }; bash scripts/build-antigravity-skills.sh >/tmp/reviewer-antigravity.log 2>&1 || { cat /tmp/reviewer-antigravity.log; exit 1; }; ! rg -n 'review-primary|review-alt' dist/codex dist/cursor dist/antigravity; rg -n 'model = \"gpt-5.4\"|model = \"gpt-5.3-codex\"' dist/codex/agents/write-tests-blind-coverage-auditor*.toml; rg -n '^model: inherit$' dist/cursor/agents/write-tests-blind-coverage-auditor*.md; rg -n 'model: gemini-3.1-pro-(high|low)' dist/antigravity/agents/write-tests-blind-coverage-auditor*.md`
  Expected: builds pass, emitted artifacts contain concrete model names only, and no abstract reviewer lanes survive packaging.
- [ ] Integration checkpoint: before touching `skills/write-tests/SKILL.md`, run two resolver-driven smoke checks against emitted artifacts:
  - happy path: a writer model that should choose the alternate reviewer lane cleanly
  - degraded path: an unsupported or collapsed environment that must emit `same-model-fallback` or `unknown-writer-model`
  Record the expected `writer / reviewer / lane / status` tuples in the task notes so Task 4 has a concrete runtime target.
- [ ] Acceptance: every supported build target can ship the new reviewer lanes without unresolved model placeholders.
- [ ] Commit: `map reviewer lanes in platform builds`

### Task 4: Wire Step 3.5 to the strongest available reviewer that differs from the writer
**Files:** `/Users/greglas/DEV/zuvo-plugin/skills/write-tests/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Current Step 3.5 only names a single `blind-coverage-auditor` artifact and has no runtime selection based on the writer's current model.
- [ ] GREEN: Update `skills/write-tests/SKILL.md` so Step 3.5:
  - resolves the current writer model using environment hints (`CLAUDE_MODEL`, `ZUVO_CODEX_MODEL`, or future-safe unknown fallback)
  - calls `scripts/reviewer-model-route.sh`
  - selects the primary or alternate blind-audit reviewer lane based on the resolver output
  - prints a routing line before the audit starts, for example: `Reviewer routing: writer=<model>, reviewer=<model>, lane=<review-primary|review-alt>, status=<ok|same-model-fallback|unknown-writer-model>`
  - keeps strict isolated blind-audit requirements unchanged
  - never labels the result as cross-model if the resolver returned a degraded same-model fallback
  - records degraded fallback behavior explicitly for sequential/no-agent environments instead of silently implying a different reviewer was used
- [ ] Verify 4a: `rg -n "reviewer-model-route.sh|blind-coverage-auditor-alt|Reviewer routing:|same-model-fallback|unknown-writer-model|CLAUDE_MODEL|ZUVO_CODEX_MODEL" skills/write-tests/SKILL.md && awk '/^### Step 3\\.5: Blind Coverage Audit$/{a=NR} /^### Step 4: Adversarial Review/{b=NR} END{exit !(a && b && a < b)}' skills/write-tests/SKILL.md`
  Expected: Step 3.5 contains explicit runtime routing, degraded-state language, and still preserves the blind-audit gate ordering ahead of Step 4.
- [ ] Verify 4b: run at least two concrete resolver-driven assertions for the Step 3.5 contract:
  - one writer model that must produce `status=ok` with a reviewer different from the writer
  - one degraded environment that must produce `status=same-model-fallback` or `status=unknown-writer-model`
  The verify step must assert the emitted `lane / reviewer / status` tuple, not just string presence in `SKILL.md`.
- [ ] Acceptance:
  - `write-tests` chooses the strongest available reviewer that differs from the writer whenever the environment can honor it.
  - Step 3.5 ordering stays ahead of Step 4.
  - strict blind-audit gates remain unchanged by the routing work.
- [ ] Commit: none -- hold until full validation passes

### Task 5: Validate end-to-end routing, packaging, and install behavior
**Files:** none
**Complexity:** complex
**Dependencies:** Task 4
**Execution routing:** default implementation tier

- [ ] RED: No traditional failing test. Validation target: ensure the new resolver, reviewer lanes, and `write-tests` orchestration all agree on actual emitted models and truthful degraded states.
- [ ] GREEN: Run the full validation sequence:
  1. `bats scripts/tests/reviewer-model-route.bats`
  2. `bash scripts/build-codex-skills.sh >/tmp/reviewer-final-codex.log 2>&1 || { cat /tmp/reviewer-final-codex.log; exit 1; }`
  3. `bash scripts/build-cursor-skills.sh >/tmp/reviewer-final-cursor.log 2>&1 || { cat /tmp/reviewer-final-cursor.log; exit 1; }`
  4. `bash scripts/build-antigravity-skills.sh >/tmp/reviewer-final-antigravity.log 2>&1 || { cat /tmp/reviewer-final-antigravity.log; exit 1; }`
  5. `./scripts/install.sh >/tmp/reviewer-install.log 2>&1 || { cat /tmp/reviewer-install.log; exit 1; }`
  6. `! rg -n 'review-primary|review-alt' "$HOME/.claude/plugins/cache/zuvo-marketplace/zuvo"/*/skills/write-tests/agents/blind-coverage-auditor*.md`
  7. `./scripts/adversarial-review.sh --mode code --files "skills/write-tests/SKILL.md shared/includes/env-compat.md scripts/reviewer-model-route.sh skills/write-tests/agents/blind-coverage-auditor.md skills/write-tests/agents/blind-coverage-auditor-alt.md"`
- [ ] Verify:
  - steps 1-5 exit 0
  - step 6 shows no unresolved reviewer-lane placeholders in Claude cache
  - deterministic assertions from Tasks 3 and 4 pass before relying on adversarial review output
  - step 7 is advisory: CRITICAL findings must be investigated, but final completion is gated primarily by the deterministic checks above
  - if the local machine lacks Claude cache directories, re-run install verification with the available targets and record the degraded validation note honestly
- [ ] Acceptance:
  - the routing contract is enforced consistently across source, build outputs, and installed artifacts
  - the rollout leaves an observable `Reviewer routing:` line that future audits can use to count `ok` vs degraded fallback cases
- [ ] Commit: `route write-tests blind audit to strongest available reviewer model`
