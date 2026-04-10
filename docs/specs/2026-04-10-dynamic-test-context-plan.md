# Implementation Plan: Lazy Include Loading + Dynamic Test Context

**Spec:** docs/specs/2026-04-10-dynamic-test-context-spec.md
**spec_id:** 2026-04-10-dynamic-test-context-1430
**planning_mode:** spec-driven
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-10
**Tasks:** 9
**Estimated complexity:** 8 standard + 1 complex (write-tests Phase 0 restructure)

## Architecture Summary

6 independent SKILL.md file edits + 1 validation task. All changes are markdown-only — no compiled code, no new files, no dependencies. Each skill gets the same 3-phase pattern (PHASE 0 bootstrap → PHASE 0.5 classify → PHASE 1 conditional load) with skill-specific classification dimensions and include maps.

**Component map:**
- `skills/write-tests/SKILL.md` — highest value, most complex (4 loading tiers + CodeSift queries + contract output)
- `skills/build/SKILL.md` — already has tiering, minimal change (add Phase labels)
- `skills/review/SKILL.md` — heavy upfront loader, needs diff-based classification
- `skills/refactor/SKILL.md` — 7 upfront files, needs ETAP-aligned conditional loading
- `skills/code-audit/SKILL.md` — consolidate codesift-setup from prose to Phase 0
- `skills/debug/SKILL.md` — no conditional loading today, needs bug-type classification

**Zero blast radius to shared includes** — no files under `shared/includes/` are modified.

## Technical Decisions

- **Pattern:** 3-phase Mandatory File Loading template standardized across all skills
- **Selective reading:** Heading-based section instructions (e.g., "Read from ## Q1-Q19 to end") — no file splitting
- **Implementation order:** write-tests first (Tasks 1-2) as spike, then build → review → refactor → code-audit → debug
- **Spike gate:** Tasks 3-7 are gated on Task 2 completing successfully — write-tests validates the pattern works before applying to other skills
- **Validation:** `./scripts/adversarial-review.sh --mode spec` on each diff, cross-skill validation at end
- **Rollback:** Each task edits one file. Rollback = `git checkout HEAD~1 -- <file>`. Global rollback = revert all commits in this series.
- **Classification fallback:** When classification is ambiguous, default to STANDARD tier (loads more includes than LIGHT, less than HEAVY). Never skip includes due to low-confidence classification.

## Quality Strategy

- **Primary risk:** Agent silently loads conditional file before classification (undetectable without live run)
- **Mitigation:** Each skill prints classification BEFORE conditional load checklist — adversarial review checks structural ordering
- **CQ gates relevant:** CQ13 (no dead instructions), CQ14 (no duplicate load references), CQ20 (single source of truth for phase ordering)
- **Verification per task:** `adversarial-review --mode spec --files <skill>` on the changed file

## Task Breakdown

### Task 1: write-tests — restructure Mandatory File Loading to 3-phase pattern
**Files:** `skills/write-tests/SKILL.md`
**Complexity:** complex
**Dependencies:** none
**Execution routing:** deep implementation tier

- [ ] RED: Current Phase 0 loads 5 files (test-contract, test-blocklist, quality-gates, testing.md, codesift-setup) before reading the production file. Spec requires: ONLY codesift-setup in Phase 0. The rest moves to Phase 1 (after classification). Identify exact lines 29-57 that need restructuring.
- [ ] GREEN: Rewrite the Mandatory File Loading section to 3-phase pattern:
  - PHASE 0 — BOOTSTRAP: codesift-setup.md ONLY (1 file)
  - PHASE 0.5 — CLASSIFY: read production file → classify code type + complexity + testability → determine loading tier (LIGHT/STANDARD/HEAVY/COMPONENT)
  - PHASE 1 — CONDITIONAL: load includes per tier using the include map from spec DD6
  - DEFERRED: run-logger.md, retrospective.md at Step 5
  
  Add tier assignment rules:
  ```
  IF code_type IN (PURE, VALIDATOR) AND complexity == THIN → LIGHT
  IF code_type IN (COMPONENT, HOOK) → COMPONENT
  IF code_type IN (CONTROLLER, ORCHESTRATOR) → HEAVY
  IF complexity == COMPLEX → HEAVY
  ELSE → STANDARD
  ```
  
  Add selective reading instructions:
  - quality-gates.md: "Read from ## Q1-Q19: Test Quality Gates to end of file"
  - test-code-types.md: "Read only the ### {CODE_TYPE} section matching classification"
  
  Remove duplicate items 9-10 (lines 53-56) that appear in both Phase 0 and Step 1 blocks.
  
  Add print instruction: `[CLASSIFIED] {file}: {type} {complexity} → tier {TIER}`
  
  Also apply DD8: change test contract from printed output to internal checklist. Add instruction: "Do NOT print the full contract to conversation. Use as internal checklist. Show user only: branch coverage table + test outline + planned test count."

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/write-tests/SKILL.md"`
  Expected: No CRITICAL findings related to phase ordering or missing includes
- [ ] Acceptance: AC #1 (only codesift-setup before reading), AC #2 (classification before includes), AC #3 (tier printed), AC #4 (READ/SKIP checklist)
- [ ] Commit: `feat: write-tests lazy include loading — classify first, load matching tier`

### Task 2: write-tests — align CodeSift retrieval with new phase structure
**Files:** `skills/write-tests/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default implementation tier

- [ ] RED: Current CodeSift retrieval dimensions (D1-D4) run in Phase 0 Step 2, before classification. After Task 1, classification happens in Phase 0.5. The retrieval dimensions should run AFTER classification (in Phase 1) since code type affects which dimensions to run (PURE skips D2-D4, COMPONENT skips D2-D3).
- [ ] GREEN: Move CodeSift retrieval from Phase 0 Step 2 to Phase 1 (after classification, alongside conditional include loading). Ensure:
  - D1 (exemplar) runs for all tiers
  - D2 (import mocks) conditional: skip for LIGHT tier
  - D3 (test setup) conditional: skip if exemplar covers it
  - D4 (hub signatures) conditional: skip for LIGHT tier
  
  Update print output to include tier: `[CONTEXT] Tier: {TIER}, exemplar={path}, {N} import mocks, {N} signatures`

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/write-tests/SKILL.md"`
  Expected: No CRITICAL findings
  Additionally verify: CodeSift queries use `token_budget` params (D1: 2000, D2: 1500, D4: 1000) → total max ~4.5K tokens (satisfies AC #9 <6K). Timing (AC #8) verified during live validation in Task 9.
- [ ] Acceptance: AC #7 (4 dimensions when CodeSift available), AC #8 (timing — verified live), AC #9 (token budget enforced by params), AC #10 (legacy fallback works)
- [ ] Commit: `feat: write-tests CodeSift retrieval aligned with lazy loading phases`

### Task 3: build — restructure to 3-phase lazy loading
**Files:** `skills/build/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2 (spike gate — write-tests validates pattern works)
**Execution routing:** default implementation tier

- [ ] RED: Current structure: CORE block (6 files loaded unconditionally) + Deferred section. codesift-setup.md is referenced in prose (line ~61), not in the checklist. Spec requires 3-phase pattern with codesift-setup as Phase 0 item 1.
- [ ] GREEN: Restructure Mandatory File Reading section using build's ACTUAL current includes:
  - PHASE 0 — BOOTSTRAP: codesift-setup.md ONLY (move from inline prose at line ~61 to Phase 0 checklist)
  - PHASE 0.5 — CLASSIFY: after Phase 0 context gathering, classify into tier (already exists as "Tiering Model" section at line ~71 — add Phase 0.5 label, ensure it runs BEFORE conditional loading)
  - PHASE 1 — CONDITIONAL (based on tier): load per tier using build's current deferred-loading items:
    - ALL tiers: cq-patterns.md, file-limits.md
    - STANDARD+: code-contract.md, testing.md, test-quality-rules.md
    - DEEP: + cq-checklist.md, test-contract.md, quality-gates.md (Q1-Q19 for test eval)
  - DEFERRED: run-logger.md, retrospective.md, knowledge-prime/curate
  
  Note: build's include map follows what the skill CURRENTLY loads (cq-patterns, file-limits, code-contract, testing, test-quality-rules, cq-checklist, test-contract) reorganized by tier. The spec's DD9 build include map table is illustrative — the actual includes are determined by what the skill needs.

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/build/SKILL.md"`
  Expected: No CRITICAL findings
- [ ] Acceptance: AC #5 (build restructured to 3-phase), AC #16 (token cost reduction)
- [ ] Commit: `feat: build lazy include loading — tier-based conditional loading`

### Task 4: review — restructure to 3-phase lazy loading
**Files:** `skills/review/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2 (spike gate)
**Execution routing:** default implementation tier

- [ ] RED: Current structure: Core (5 files unconditional) + Optional (2) + Conditional table (7). quality-gates.md loaded unconditionally (~144 lines) even when diff is test-only. run-logger.md and retrospective.md loaded in Core but not needed until final output.
- [ ] GREEN: Restructure Mandatory File Loading:
  - PHASE 0 — BOOTSTRAP: codesift-setup.md ONLY
  - PHASE 0.5 — CLASSIFY: read the diff, classify content type:
    - prod-only: diff touches production files only
    - test-only: diff touches test files only
    - mixed: both
  - PHASE 1 — CONDITIONAL:
    - ALWAYS: env-compat.md (needed for agent dispatch), cross-provider-review.md (adversarial runs at all tiers — currently line 41 "Always")
    - prod-only: quality-gates.md (CQ1-CQ28 section only), cq-patterns (per code type), cq-checklist
    - test-only: quality-gates.md (Q1-Q19 section only), testing.md
    - mixed: quality-gates.md (full), cq-patterns (per code type), testing.md
    - security signals: security.md
  - DEFERRED: run-logger.md, retrospective.md, knowledge-prime/curate
  
  Note: env-compat.md and cross-provider-review.md are in the review skill's CURRENT loading (lines 21, 41). They are not in the spec's simplified review include map but are legitimate — env-compat is needed for agent dispatch, cross-provider-review is marked "Always" for adversarial.
  
  Preserve existing conditional table but reframe under Phase 1.

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/review/SKILL.md"`
  Expected: No CRITICAL findings
- [ ] Acceptance: AC #5 (review restructured to 3-phase), AC #15 (token cost reduction)
- [ ] Commit: `feat: review lazy include loading — diff-based conditional loading`

### Task 5: refactor — restructure to 3-phase lazy loading
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2 (spike gate)
**Execution routing:** default implementation tier

- [ ] RED: Current structure: 7 unconditional files (including cq-patterns.md ~8.4K and cq-checklist.md) + conditional table. cq-patterns loaded unconditionally even for simple renames. Spec requires classification-based loading.
- [ ] GREEN: Restructure Mandatory File Loading:
  - PHASE 0 — BOOTSTRAP: codesift-setup.md ONLY
  - PHASE 0.5 — CLASSIFY: read target, determine refactor type:
    - RENAME: symbol rename, file move
    - EXTRACT: extract function/class/module
    - SPLIT: split large file
    - INLINE: consolidate/inline
    - RESTRUCTURE: architectural change
  - PHASE 1 — CONDITIONAL:
    - RENAME: env-compat.md only (minimal ceremony)
    - EXTRACT/SPLIT: + quality-gates.md (CQ section), file-limits.md
    - INLINE: + cq-patterns.md (to verify no duplicate logic)
    - RESTRUCTURE: + cq-patterns.md, cq-checklist.md, quality-gates.md (full)
    - IF tests affected: + testing.md, test-quality-rules.md
  - DEFERRED: run-logger.md, retrospective.md

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/refactor/SKILL.md"`
  Expected: No CRITICAL findings
- [ ] Acceptance: AC #5 (refactor restructured to 3-phase)
- [ ] Commit: `feat: refactor lazy include loading — refactor-type-based conditional loading`

### Task 6: code-audit — restructure to 3-phase lazy loading
**Files:** `skills/code-audit/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2 (spike gate)
**Execution routing:** default implementation tier

- [ ] RED: Current structure: CORE block (6 files) + codesift-setup in separate prose section (lines 59-65). codesift-setup is NOT in the checklist. No conditional loading. Spec requires codesift-setup as Phase 0 item 1 and domain-based conditional loading.
- [ ] GREEN: Restructure Mandatory File Loading:
  - PHASE 0 — BOOTSTRAP: codesift-setup.md ONLY (move from prose to checklist)
  - PHASE 0.5 — CLASSIFY: read target file(s), classify domain:
    - data: touches DB, queries, transactions
    - async: touches promises, streams, workers
    - security: touches auth, input, secrets
    - general: none of the above
  - PHASE 1 — CONDITIONAL:
    - ALWAYS: cq-checklist.md, env-compat.md
    - data: + cq-patterns.md (CQ6, CQ7, CQ9, CQ16, CQ17 focus)
    - async: + cq-patterns.md (CQ15, CQ17 focus)
    - security: + security.md, cq-patterns.md (CQ4, CQ5 focus)
    - general: + cq-patterns.md (full), file-limits.md
  - DEFERRED: run-logger.md

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/code-audit/SKILL.md"`
  Expected: No CRITICAL findings
- [ ] Acceptance: AC #5 (code-audit restructured to 3-phase)
- [ ] Commit: `feat: code-audit lazy include loading — domain-based conditional loading`

### Task 7: debug — restructure to 3-phase lazy loading
**Files:** `skills/debug/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2 (spike gate)
**Execution routing:** default implementation tier

- [ ] RED: Current structure: 8 files loaded unconditionally, no classification, no conditional loading. codesift-setup missing from checklist entirely. Most significant restructure needed.
- [ ] GREEN: Restructure Mandatory File Reading:
  - PHASE 0 — BOOTSTRAP: codesift-setup.md ONLY (add to checklist)
  - PHASE 0.5 — CLASSIFY: read error/file/stack trace, classify bug category:
    - logic: wrong output, off-by-one, condition error
    - async: race condition, unhandled rejection, deadlock
    - data: wrong query, missing join, constraint violation
    - integration: API contract, version mismatch, env config
    - test-failure: existing test broke, flaky test
  - PHASE 1 — CONDITIONAL:
    - logic: cq-patterns.md, cq-checklist.md
    - async: cq-patterns.md (CQ15, CQ21 focus)
    - data: cq-patterns.md (CQ6, CQ7, CQ9 focus)
    - integration: cq-patterns.md (CQ8, CQ19 focus)
    - test-failure: testing.md, test-quality-rules.md
    - ALL: knowledge-prime.md (if available)
  - DEFERRED: run-logger.md, retrospective.md, knowledge-curate.md

- [ ] Verify: `./scripts/adversarial-review.sh --mode spec --files "skills/debug/SKILL.md"`
  Expected: No CRITICAL findings
- [ ] Acceptance: AC #5 (debug restructured to 3-phase)
- [ ] Commit: `feat: debug lazy include loading — bug-category-based conditional loading`

### Task 8: Cross-skill adversarial validation
**Files:** All 6 SKILL.md files (read-only validation)
**Complexity:** standard
**Dependencies:** Tasks 1-7
**Execution routing:** default implementation tier

- [ ] RED: After all 6 skills restructured, verify cross-skill consistency:
  - codesift-setup.md is Phase 0 item 1 in ALL skills
  - quality-gates.md selective reading instructions are consistent across write-tests, review, refactor
  - run-logger.md and retrospective.md are DEFERRED in ALL skills
  - No skill loads a shared include in two different phases
- [ ] GREEN: Run adversarial review across all 6 files in one pass. Fix any CRITICAL or WARNING findings.
  ```
  ./scripts/adversarial-review.sh --mode spec --files "skills/write-tests/SKILL.md skills/build/SKILL.md skills/review/SKILL.md skills/refactor/SKILL.md skills/code-audit/SKILL.md skills/debug/SKILL.md"
  ```
- [ ] Verify: Adversarial review returns 0 CRITICAL findings across all 6 files
  Expected: PASS or WARN-only (no CRITICAL)
- [ ] Acceptance: AC #5 (all 6 skills restructured), AC #6 (no quality regression)
- [ ] Commit: `fix: cross-skill consistency for lazy include loading`

### Task 9: Live validation — success criteria verification
**Files:** None (validation-only, run skills on real projects)
**Complexity:** standard
**Dependencies:** Tasks 1-8
**Execution routing:** default implementation tier

- [ ] RED: Success criteria AC #11-16 require measuring real-world impact: token cost reduction, Q score no regression, CQ25 improvement, exemplar pattern match rate. These cannot be verified structurally — only by running the skills.
- [ ] GREEN: Run write-tests on 3 files of different types (PURE, SERVICE, ORCHESTRATOR) in a real project. Verify from print output:
  1. AC #11: Compare include tokens loaded (from PHASE 1 checklist) vs baseline ~27K. Target: >= 50% reduction.
  2. AC #12: Record Q self-eval scores → median >= 16/19
  3. AC #8: CodeSift retrieval timing — [CONTEXT] print should appear within 20s of [CLASSIFIED] print
  4. AC #13-14: Record adversarial pass 1 findings for CQ25 and mock pattern match
  
  Run review on one diff and build on one task to verify AC #15-16 (token cost reduction >= 30%).
  
  Note: This is a manual validation task. If live runs are not possible in this session, document the validation checklist for the user to run post-release.

- [ ] Verify: Print output from live runs confirms phase ordering and token budgets
  Expected: All print statements appear in correct order: [CLASSIFIED] before [CONTEXT] before test output
- [ ] Acceptance: AC #8, AC #11, AC #12, AC #13, AC #14, AC #15, AC #16
- [ ] Commit: `docs: validation results for lazy include loading`
