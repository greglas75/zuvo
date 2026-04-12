# Implementation Plan: write-tests Blind Coverage Audit

**Spec:** docs/specs/2026-04-11-write-tests-blind-coverage-audit-spec.md
**spec_id:** 2026-04-11-write-tests-blind-coverage-audit-1735
**planning_mode:** spec-driven
**plan_revision:** 2
**status:** Reviewed
**Created:** 2026-04-11
**Tasks:** 5
**Estimated complexity:** 2 standard, 3 complex

## Architecture Summary

This change is localized to the `write-tests` verification pipeline and adds one new reusable protocol include plus one shipped read-only agent whose runtime use remains optional:

- `shared/includes/blind-coverage-audit.md` — new source-of-truth protocol for production-first coverage mapping
- `skills/write-tests/agents/blind-coverage-auditor.md` — shipped read-only auditor for environments with native sub-agents
- `skills/write-tests/SKILL.md` — orchestrator changes: insert Step 3.5, gate Step 4 on clean audit, and record blind-audit status in `memory/coverage.md` in the same edit

No build-script changes are expected. The current install/build flow already copies `shared/includes/*.md` and `skills/*/agents/*.md`, and Codex/Cursor build logic already emits agent artifacts from skill agent directories.

## Technical Decisions

- **Single source of truth:** Put audit semantics in a shared include, not inline in `SKILL.md`, to prevent drift between the orchestrator and the optional agent path.
- **Orthogonal review:** Keep `test-quality-reviewer` unchanged. It remains the Q-gate scorer. The blind auditor owns behavior inventory and coverage mapping only.
- **Sequential-first execution:** The protocol must work as an inline role-switch checkpoint. Native agent dispatch is an optimization, not a dependency.
- **Strict gating:** `write-tests` may not proceed from Step 3.5 to adversarial review while an owned critical behavior remains `NONE` or `STRUCTURAL_ONLY`.
- **Early packaging signal:** Run a build smoke check before modifying `SKILL.md` so integration failures are caught before the riskiest prompt rewrite lands.
- **Single-PR delivery:** Do not merge Tasks 1-4 independently. Ship Tasks 1-5 as one branch/PR so new artifacts never land without the `SKILL.md` integration and final validation.
- **Vocabulary unification:** One normative mapping table in `SKILL.md` defines blind-audit verdict, allowed Step 4 transition, persisted `coverage.md` value, and resume behavior.

## Quality Strategy

- **Verification style:** This repo is markdown-only. Validation is structural: grep, build scripts, install script, and adversarial review on the changed prompt files.
- **Highest risk:** `skills/write-tests/SKILL.md` step ordering and vocabulary drift. If Step 3.5 and blind-audit persistence land in different commits, the skill can enter an internally contradictory state.
- **Second risk:** false positives on thin delegators, barrels, and orchestrators. The include and agent must share the same owned-vs-delegated rules.
- **Third risk:** packaging/install regressions from new include/agent artifacts. These must be surfaced before final integration, not only at the end.
- **Merge risk:** partial merges are explicitly disallowed; Tasks 1-4 stay branch-local until Task 5 passes.
- **CQ gate posture:** No runtime CQ gates activate here because this is a plugin-doc change. Quality focus is protocol determinism, spec alignment, and cross-platform buildability.

## Task Breakdown

### Task 1: Extract blind coverage audit protocol to a shared include
**Files:** `shared/includes/blind-coverage-audit.md`
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default implementation tier

- [ ] RED: No traditional test. Verification target: `shared/includes/blind-coverage-audit.md` does not exist, and there is no shared protocol that defines production-first blind coverage mapping for `write-tests`.
- [ ] GREEN: Create `shared/includes/blind-coverage-audit.md` as the single source of truth for Spec D4-D7 and the full Proposed Protocol (Steps A-D). The include must expose:
  - production-first, contract-blind execution order
  - behavior inventory categories, including `delegation_contract` and `a11y_output`
  - owned-vs-delegated rules for wrappers, barrels, orchestrators, and thin delegators
  - coverage states `FULL | PARTIAL | NONE | STRUCTURAL_ONLY | N/A`
  - verdict rules `CLEAN | FIX | REWRITE`
  - inventory-table output schema plus prioritized findings / highest-value missing test
  - false-positive guardrails for delegation and accessibility fallbacks
- [ ] Verify: `rg -n "^# Blind Coverage Audit|delegation_contract|a11y_output|STRUCTURAL_ONLY|Highest-value missing test|Owned-vs-delegated|CLEAN \\| FIX \\| REWRITE" shared/includes/blind-coverage-audit.md`
  Expected: one hit for the title line and one hit for each required invariant.
- [ ] Acceptance: Spec AC #4, AC #5, AC #6, AC #8
- [ ] Commit: `add blind coverage audit protocol for write-tests`

### Task 2: Add a blind coverage auditor agent artifact
**Files:** `skills/write-tests/agents/blind-coverage-auditor.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: No traditional test. Verification target: `skills/write-tests/agents/blind-coverage-auditor.md` does not exist, so `write-tests` has no dedicated shipped agent artifact for production-first coverage mapping.
- [ ] GREEN: Create `skills/write-tests/agents/blind-coverage-auditor.md` following the local agent pattern:
  - frontmatter with `name`, `description`, `model`, and read-only tools
  - inputs limited to production file + test file (+ optional CodeSift availability/repo id)
  - explicit instruction to read production first, then test
  - explicit prohibition on reading the writer's test contract, self-eval block, or adversarial findings before verdict
  - output format matching the include's inventory table and verdict block
  - fallback path for environments without CodeSift
  - keep the filename exactly `blind-coverage-auditor.md` so Codex/Cursor build outputs derive the expected shipped artifact names
- [ ] Verify: `head -20 skills/write-tests/agents/blind-coverage-auditor.md && rg -n "read production file first|must NOT read the test contract|Coverage verdict|Inventory:" skills/write-tests/agents/blind-coverage-auditor.md`
  Expected: valid frontmatter plus hits for the production-first and contract-blind rules.
- [ ] Acceptance: Spec AC #2, AC #3, AC #4, AC #8
- [ ] Commit: `add blind coverage auditor agent for write-tests`

### Task 3: Run an early packaging smoke check for the new include and agent
**Files:** none
**Complexity:** complex
**Dependencies:** Task 1, Task 2
**Execution routing:** default implementation tier

- [ ] RED: No traditional RED. Validation target: the new include and agent must survive Codex/Cursor packaging before `SKILL.md` wiring begins.
- [ ] GREEN: Run a minimal smoke sequence with diagnostics:
  1. `bash scripts/build-codex-skills.sh >/tmp/zuvo-blind-codex-smoke.log 2>&1 || { cat /tmp/zuvo-blind-codex-smoke.log; exit 1; }`
  2. `test -f dist/codex/skills/write-tests/agents/blind-coverage-auditor.md`
  3. `rg -n 'name = "write-tests-blind-coverage-auditor"' dist/codex/agents/write-tests-blind-coverage-auditor.toml`
  4. `bash scripts/build-cursor-skills.sh >/tmp/zuvo-blind-cursor-smoke.log 2>&1 || { cat /tmp/zuvo-blind-cursor-smoke.log; exit 1; }`
  5. `test -f dist/cursor/agents/write-tests-blind-coverage-auditor.md`
  6. `cp skills/write-tests/SKILL.md /tmp/write-tests-blind-audit-spike.md && perl -0pi -e 's/### Step 4: Adversarial Review/### Step 3.5: Blind Coverage Audit\\n\\n[BLIND AUDIT PLACEHOLDER]\\n\\n### Step 4: Adversarial Review/' /tmp/write-tests-blind-audit-spike.md`
- [ ] Verify: `bash scripts/build-codex-skills.sh >/tmp/zuvo-blind-codex-smoke-verify.log 2>&1 || { cat /tmp/zuvo-blind-codex-smoke-verify.log; exit 1; }; test -f dist/codex/skills/write-tests/agents/blind-coverage-auditor.md; rg -n 'name = "write-tests-blind-coverage-auditor"' dist/codex/agents/write-tests-blind-coverage-auditor.toml; bash scripts/build-cursor-skills.sh >/tmp/zuvo-blind-cursor-smoke-verify.log 2>&1 || { cat /tmp/zuvo-blind-cursor-smoke-verify.log; exit 1; }; test -f dist/cursor/agents/write-tests-blind-coverage-auditor.md; cp skills/write-tests/SKILL.md /tmp/write-tests-blind-audit-spike-verify.md && perl -0pi -e 's/### Step 4: Adversarial Review/### Step 3.5: Blind Coverage Audit\\n\\n[BLIND AUDIT PLACEHOLDER]\\n\\n### Step 4: Adversarial Review/' /tmp/write-tests-blind-audit-spike-verify.md; rg -c '^### Step 3\\.5: Blind Coverage Audit$' /tmp/write-tests-blind-audit-spike-verify.md | grep -qx '1'; awk '/^### Step 3: Verify$/{a=NR} /^### Step 3.5: Blind Coverage Audit$/{b=NR} /^### Step 4: Adversarial Review$/{c=NR} END{exit !(a && b && c && a < b && b < c)}' /tmp/write-tests-blind-audit-spike-verify.md; echo OK`
  Expected: print `OK` only after packaging checks pass and the scratch `SKILL.md` spike proves the Step 3 -> 3.5 -> 4 ordering is viable.
- [ ] Acceptance: packaging drift is surfaced before any `skills/write-tests/SKILL.md` edit lands
- [ ] Commit: none -- smoke validation only

### Task 4: Integrate Step 3.5 and blind-audit persistence in one coherent SKILL.md edit
**Files:** `skills/write-tests/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 3
**Execution routing:** deep implementation tier

- [ ] RED: Current `skills/write-tests/SKILL.md` goes directly from `### Step 3: Verify` to `### Step 4: Adversarial Review`; there is no mandatory production-first coverage audit between them, and `memory/coverage.md` persistence has no `Blind Audit` field.
- [ ] GREEN: Update `skills/write-tests/SKILL.md` in one task so the per-file loop becomes:
  - Step 3: Verify (anti-tautology + Q-score)
  - **Step 3.5: Blind Coverage Audit**
  - Step 4: Adversarial Review

  In the same edit:
  - reference `shared/includes/blind-coverage-audit.md` as the source of truth
  - require production-first, contract-blind execution
  - support two execution paths:
    - default inline role-switch checkpoint
    - optional `blind-coverage-auditor` agent in agent-capable environments
  - define pass budget: max 2 blind-audit passes per file
  - add one normative mapping table: blind-audit verdict -> Step 4 transition -> `memory/coverage.md` value -> resume behavior
  - block Step 4 unless verdict is `CLEAN`, or the file is explicitly marked `FAILED`
  - state that thin delegators are audited on forwarding contract, not downstream implementation
  - keep Q-scoring and adversarial responsibilities distinct
  - change coverage schema to `| File | Status | Tests | Q Score | Blind Audit | Adversarial | Date |`
  - define valid blind-audit values: `clean`, `fix:<n>`, `rewrite`, `skipped`
  - include blind-audit status in the per-file summary line
  - clarify that a file cannot be treated as fully complete without both blind-audit and adversarial status recorded
- [ ] Verify: `rg -c '^### Step 3\\.5: Blind Coverage Audit$' skills/write-tests/SKILL.md | grep -qx '1'; rg -c '^### Step 4: Adversarial Review$' skills/write-tests/SKILL.md | grep -qx '1'; rg -c '^\\| File \\| Status \\| Tests \\| Q Score \\| Blind Audit \\| Adversarial \\| Date \\|$' skills/write-tests/SKILL.md | grep -qx '1'; awk '/^### Step 3: Verify$/{a=NR} /^### Step 3.5: Blind Coverage Audit$/{b=NR} /^### Step 4: Adversarial Review$/{c=NR} END{exit !(a && b && c && a < b && b < c)}' skills/write-tests/SKILL.md; rg -n "contract-blind|production file first|fix:<n>|rewrite|skipped" skills/write-tests/SKILL.md`
  Expected: one Step 3.5 header, one Step 4 header, one coverage schema row, correct ordering, and required blind-audit vocabulary.
- [ ] Acceptance: Spec AC #1, AC #2, AC #3, AC #5, AC #6, AC #7, AC #8
- [ ] Commit: none -- hold the `SKILL.md` commit until Task 5 validation passes

### Task 5: Validate packaging, install flow, and prompt quality after integration
**Files:** none
**Complexity:** complex
**Dependencies:** Task 4
**Execution routing:** default implementation tier

- [ ] RED: No traditional RED. Validation target: the new include and agent must survive Codex/Cursor builds and local install without breaking existing prompt packaging, and the final prompt files must pass adversarial review with no CRITICAL findings and no unresolved WARNING findings.
- [ ] GREEN: Run the full validation sequence:
  1. `bash scripts/build-codex-skills.sh >/tmp/zuvo-blind-codex.log 2>&1 || { cat /tmp/zuvo-blind-codex.log; exit 1; }`
  2. `test -f dist/codex/skills/write-tests/agents/blind-coverage-auditor.md && rg -n 'name = "write-tests-blind-coverage-auditor"' dist/codex/agents/write-tests-blind-coverage-auditor.toml`
  3. `bash scripts/build-cursor-skills.sh >/tmp/zuvo-blind-cursor.log 2>&1 || { cat /tmp/zuvo-blind-cursor.log; exit 1; }`
  4. `test -f dist/cursor/agents/write-tests-blind-coverage-auditor.md`
  5. `./scripts/install.sh >/tmp/zuvo-blind-install.log 2>&1 || { cat /tmp/zuvo-blind-install.log; rm -rf dist/codex dist/cursor; exit 1; }`
  6. `./scripts/adversarial-review.sh --mode spec --files "skills/write-tests/SKILL.md shared/includes/blind-coverage-audit.md skills/write-tests/agents/blind-coverage-auditor.md" | tee /tmp/zuvo-blind-spec-review.log`
- [ ] Verify:
  - commands 1-5 exit 0
  - command 6 produces no `SEVERITY: CRITICAL`
  - any `SEVERITY: WARNING` finding is either fixed before completion or explicitly triaged as non-blocking in the validation notes
  - if any validation command fails, clean `dist/codex` and `dist/cursor` before retrying
  - if Task 4 changes are implicated, restore the working-tree version of `skills/write-tests/SKILL.md` to `HEAD` before retrying the integration edit
- [ ] Acceptance: Spec AC #4, AC #7, AC #8 plus cross-platform packaging remains intact
- [ ] Commit: `integrate blind coverage audit and persistence into write-tests`
