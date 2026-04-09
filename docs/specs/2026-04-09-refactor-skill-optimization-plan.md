# Implementation Plan: zuvo:refactor Skill Optimization

**Spec:** docs/specs/2026-04-09-refactor-skill-optimization-spec.md
**spec_id:** 2026-04-09-refactor-skill-optimization-1845
**planning_mode:** spec-driven
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-09
**Tasks:** 13
**Estimated complexity:** 10 standard, 3 complex

## Architecture Summary

4 files modified, 1 external reference updated:
- `skills/refactor/SKILL.md` — main skill (812L → ~650L): mode reduction, phase renumbering, contradiction fixes, CodeSift integration, failure handling
- `skills/refactor/agents/cq-auditor.md` — full rewrite (89L → ~120L): CodeSift workflow, preamble structure, verdict line, prohibitions
- `skills/refactor/agents/dependency-mapper.md` — targeted fixes (86L → ~100L): execution profile, batch query, preamble structure, error handling
- `skills/refactor/agents/existing-code-scanner.md` — targeted fixes (85L → ~100L): execution profile, frequency_analysis, preamble structure, error handling
- `docs/skills.md` — one-line update: remove quick/standard/auto from refactor row

Dependency order: mode removal → phase renumbering → contract schema update. Agent files are independent of each other and of SKILL.md structural changes.

## Technical Decisions

- **Structure pattern:** Follow build's canonical ordering (frontmatter → argument parsing → mandatory files → Phase 0-N)
- **Adversarial pattern:** Match build's adversarial block (risk override + meta-review)
- **Agent pattern:** Follow execute/quality-reviewer.md for cq-auditor rewrite (execution profile, dual-path CodeSift, verdict line, prohibitions)
- **Batch mode:** Keep as standalone section after Phase 4 (it's an alternate top-level flow, not a tier variant)
- **GOD_CLASS:** Keep as standalone section after Batch Mode (shared algorithm used by both modes)

## Quality Strategy

- **Verification:** Each task ends with grep/wc commands to confirm changes. No traditional tests (markdown-only project).
- **Highest risk:** Phase renumbering (Risk 1 — 15+ internal references). Mitigated by doing all structural moves BEFORE renumbering.
- **Second highest risk:** cq-auditor rewrite (Risk 3 — pre-existing path bug). Mitigated by grepping for bare path references after rewrite.
- **CQ gates:** Replaced by SQ1-SQ8 skill quality gates (mode entry/exit, conditional branches, agent inputs, approval gate rejection, CodeSift fallbacks, include paths, cross-references, adversarial completeness).

## Task Breakdown

### Task 1: Delete eliminated mode sections
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** none
**Execution routing:** default

- [ ] RED: No traditional test. Verification target: zero occurrences of "Mode Comparison", "QUICK Mode", "STANDARD Mode", "Mode Resolution", "Environment Adaptation" as section headers.
- [ ] GREEN: Delete these sections from SKILL.md (identify by section headers, not line numbers — lines may shift):
  - Section `### Mode Comparison` (from header to next `###`) — the mode comparison table
  - Section `### QUICK Mode` (from header to next `###`)
  - Section `### STANDARD Mode` (from header to next `###`)
  - Section `## Mode Resolution` (from header to next `##`) — the auto-detection logic
  - Section `## IMPROVE_TESTS Workflow` (from header to next `##`) — save content for merge into Phase 2 in Task 5
  - Section starting with "## Environment Adaptation" or equivalent (from header to end) — redundant with env-compat.md
- [ ] Verify: `grep -n "Mode Comparison\|QUICK Mode\|STANDARD Mode\|Mode Resolution\|Environment Adaptation\|IMPROVE_TESTS Workflow" skills/refactor/SKILL.md`
  Expected: zero hits (or only IMPROVE_TESTS as a subsection header if merged into Phase 2)
- [ ] Acceptance: AC1 (partial), AC2
- [ ] Commit: `delete eliminated mode sections and redundant appendices from zuvo:refactor`

### Task 2: Clean up scattered mode references
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Execution routing:** default

- [ ] RED: Verification target: zero occurrences of `quick`, `QUICK`, `standard`, `STANDARD`, `auto` (as mode name), `AUTO` in behavioral context (excluding migration rule text and historical references in contract migration).
- [ ] GREEN: Find and remove/rewrite all scattered one-liner mode conditionals throughout SKILL.md:
  - "skip for QUICK mode" → delete line
  - "in STANDARD mode" → delete line or rewrite without mode reference
  - "unless AUTO or BATCH mode" → simplify to "in batch mode"
  - "if QUICK skip" / "if STANDARD inline" → delete
  - Mode Comparison references in phase descriptions → delete
  - Any "5 modes" or "quick/standard/auto" mentions → update to "2 modes (full + batch)"
- [ ] Verify: `grep -in "quick\|standard\|auto mode\|auto-detection\|5 modes" skills/refactor/SKILL.md | grep -v "migration\|legacy\|upgrade\|silently"`
  Expected: zero hits
- [ ] Acceptance: AC1, AC9
- [ ] Commit: `remove all scattered quick/standard/auto mode references from zuvo:refactor`

### Task 3: Rewrite Argument Parsing and frontmatter
**Files:** `skills/refactor/SKILL.md`, `docs/skills.md`
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: Verification target: Argument Parsing section lists exactly 2 modes (full + batch) and 3 flags (no-commit, plan-only, continue). Frontmatter description references only 2 modes.
- [ ] GREEN:
  - Replace SKILL.md frontmatter description: remove quick/standard/auto, keep "full (default)" and "batch <file>" and flags
  - Rewrite Argument Parsing to:
    - Two-row modes table (full | batch)
    - Control flags table (no-commit | plan-only | continue)
    - Flag priority rules (continue > no-commit > plan-only)
    - Contract migration note: "`continue` on a contract with mode `quick`/`standard`/`auto` silently upgrades to `full` and logs the migration"
  - Update `docs/skills.md` refactor row: remove quick/standard/auto from Key flags
- [ ] Verify: `grep "zuvo:refactor" docs/skills.md` — must NOT contain quick/standard/auto. `head -10 skills/refactor/SKILL.md` — frontmatter must show 2 modes only.
- [ ] Acceptance: AC1, AC15 (partial), AC18, AC19, AC20
- [ ] Commit: `rewrite argument parsing for 2-mode model (full + batch) with contract migration`

### Task 4: Fix C1 — Replace Plan Display with Approval Gate
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 2
**Execution routing:** default

- [ ] RED: Verification target: zero occurrences of "proceed immediately. No approval gate". One occurrence of "APPROVAL GATE" block with cosmetic/material change handling.
- [ ] GREEN:
  - Delete lines 416-418 ("Display the plan, then proceed immediately. No approval gate")
  - Replace with the Approval Gate specification from the spec:
    - Display format: REFACTOR PLAN block with type, scope, extractions, CQ targets, test mode
    - Cosmetic change path: orchestrator recomputes inline, no agent re-dispatch, re-display
    - Material change path: re-dispatch Dependency Mapper + Existing Code Scanner, recompute, re-display
    - "Proceed only after explicit confirmation"
  - Also update the Questions Gate (lines 410-412) to flow into the Approval Gate rather than having its own "HARD STOP" — merge the two into one cohesive gate section
- [ ] Verify: `grep -n "proceed immediately\|No approval gate" skills/refactor/SKILL.md` → zero hits. `grep -c "APPROVAL GATE" skills/refactor/SKILL.md` → exactly 1.
- [ ] Acceptance: AC4, AC8
- [ ] Commit: `fix C1: replace plan-display auto-proceed with explicit approval gate`

### Task 5: Merge phases and renumber (Phase 0-4)
**Files:** `skills/refactor/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1, Task 2, Task 4
**Execution routing:** deep

This is the highest-risk task. Must be done as a single atomic edit.

- [ ] RED: Verification target: exactly 5 phase headers (Phase 0-4). Zero occurrences of "Phase 5". ETAP labels appear only as descriptive text within phases, never as navigation references.
- [ ] GREEN:
  1. Move CONTRACT State File, Sub-Agent Dispatch, ETAP-1A Plan, Questions Gate from current Phase 2 into Phase 1 (after CQ Pre-Audit, before Approval Gate)
  2. Merge IMPROVE_TESTS workflow from deleted appendix into Phase 3 (test handling) as a test mode subsection
  3. Rename phase headers:
     - Phase 0 → Phase 0 (unchanged)
     - Phase 1 → Phase 1: Type Detection + CQ Pre-Audit + Approval Gate
     - Phase 3 (test handling) → Phase 2: Test Handling
     - Phase 4 (execution) → Phase 3: Execution + Post-Audit + Adversarial Review
     - Phase 5 (completion) → Phase 4: Completion
  4. Update ALL internal cross-references:
     - "Phase 2" navigation refs → deleted or merged into Phase 1
     - "Phase 3" refs → "Phase 2"
     - "Phase 4" refs → "Phase 3"
     - "Phase 5" refs → "Phase 4"
     - "ETAP-1A" as navigation → "Phase 1" or descriptive label
     - "ETAP-1B" as navigation → "Phase 2" or descriptive label
     - "ETAP-2" as navigation → "Phase 3" or descriptive label
  5. Update batch mode references: "Phase 4-5" → "Phase 3-4", ETAP labels in pipeline description
  6. Update Zero-Stop Override table: "ETAP-1A plan approval" → "Phase 1 plan approval"
  7. Update conditional files table: "Before ETAP-1B" → "Before Phase 2"
- [ ] Verify: `grep -n "Phase 5\|Phase [6-9]" skills/refactor/SKILL.md` → zero hits. `grep -c "^## Phase" skills/refactor/SKILL.md` → exactly 5. `grep -n "ETAP-[12]" skills/refactor/SKILL.md | grep -v "descriptive\|label\|migration\|was called"` → only in migration table or descriptive context.
- [ ] Acceptance: AC6
- [ ] Commit: `unify phase numbering to Phase 0-4 with ETAP as descriptive labels only`

### Task 6a: Fix C3 — Batch agent ordering and pipeline rewrite
**Files:** `skills/refactor/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 5
**Execution routing:** deep

- [ ] RED: Verification target: batch per-file pipeline step 1 dispatches agents BEFORE planning. Adversarial review is a named step (step 5). Zero approval gates in batch section. Backup branch creation present in full mode.
- [ ] GREEN:
  **C3 fix — batch agent ordering:**
  - Rewrite the Per-File Pipeline to 8 steps (was 7):
    1. Analysis: dispatch Dependency Mapper + Existing Code Scanner + CQ BEFORE + type detect + scope + contract
    2. Test handling per test mode routing
    3. Execution per CONTRACT + verify (type check + tests)
    4. Post-Audit: dispatch CQ Auditor (read-only, **orchestrator** applies FIX-NOW items). CQ AFTER.
    5. Adversarial review on staged diff (NEW — was not a named step)
    6. Commit: one per file (exception: GOD_CLASS multi-commit)
    7. Queue update with CQ scores and commit hash
    8. Backlog: persist DEFER items
  - Update the pipeline enforcement paragraph to match new step ordering
  - Confirm backup branch creation in full mode execution section (retained from original)
  - Confirm zero approval gates in batch mode (Zero-Stop Override table)
- [ ] Verify: `grep -n "Step 1\|step 1" skills/refactor/SKILL.md` in batch section → must show agent dispatch. `sed -n '/Batch Mode/,/^## /p' skills/refactor/SKILL.md | grep -i "approval"` → zero hits (AC5). `grep "backup branch\|backup/refactor" skills/refactor/SKILL.md` → present (AC7).
- [ ] Acceptance: AC5, AC7, AC10, AC30
- [ ] Commit: `fix C3: rewrite batch pipeline with agents before planning and adversarial as named step`

### Task 6b: Fix C4 — Failure handling + GOD_CLASS batch exceptions
**Files:** `skills/refactor/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 6a
**Execution routing:** deep

- [ ] RED: Verification target: Failure Recovery table with 5 rows. PRE_REFACTOR_SHA capture. GOD_CLASS multi-commit exception. GOD_CLASS PARTIAL handling.
- [ ] GREEN:
  **C4 fix — failure handling:**
  - Add Failure Recovery table to Phase 3 (Execution) with 5 rows:
    - tsc fail → fix+retry 3x, then revert extraction / mark BLOCKED
    - test fail → revert to last passing commit, re-analyze
    - lint fail → auto-fix
    - adversarial CRITICAL → fix + re-run 2x max
    - all fail → restore backup branch, mark BLOCKED, report to user
  - Add PRE_REFACTOR_SHA capture at start of Phase 3

  **GOD_CLASS batch exceptions (D6 + D10):**
  - Add multi-commit exception in batch mode (overrides one-commit rule)
  - Add partial failure handling: keep completed extractions, mark contract PARTIAL, mark queue `[!] PARTIAL`
- [ ] Verify: `grep "Failure Recovery\|PRE_REFACTOR_SHA" skills/refactor/SKILL.md` → both present. `grep "PARTIAL" skills/refactor/SKILL.md` → GOD_CLASS partial failure described.
- [ ] Acceptance: AC11, AC12, AC13, AC14
- [ ] Commit: `fix C4: add failure recovery table, PRE_REFACTOR_SHA, and GOD_CLASS batch exceptions`

### Task 7: Add CodeSift integration
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 5, Task 6b
**Execution routing:** default

- [ ] GREEN:
  **Phase 0 pre-scan enhancements:**
  - Add `classify_roles(repo, file_pattern=SCOPE)` with degraded fallback
  - Add `find_circular_deps(repo, file_pattern=SCOPE)` with degraded fallback
  - Update REFACTOR PRE-SCAN output format to 6 lines (add Roles + Cycles)
  - Add pre-scan → plan feed notes (dead/leaf/core/entry guidance)

  **Phase 3 type-specific tools:**
  - RENAME_MOVE → `rename_symbol(repo, old_name, new_name)` with fallback to manual edit
  - BREAK_CIRCULAR → `find_circular_deps` before and after execution
  - Post-execution → `find_unused_imports(repo, file_pattern=SCOPE)` with degraded fallback

  **Phase 3 post-audit CodeSift verification layer:**
  - `review_diff(repo, since=PRE_REFACTOR_SHA, until="STAGED", ...)` with degraded fallback (pass empty machine_checks to CQ Auditor)
  - `impact_analysis(repo, since=PRE_REFACTOR_SHA)` → blast radius vs scope fence
  - `changed_symbols(repo, since=PRE_REFACTOR_SHA)` → API surface verification
  - `diff_outline(repo, since=PRE_REFACTOR_SHA)` → structural diff
  - `check_boundaries(repo, rules=...)` → conditional on project having boundary rules
  - Document machine_checks handoff to CQ Auditor

  **All CodeSift additions include degraded-mode fallback:** "when CodeSift unavailable: skip with `[DEGRADED: tool unavailable]` notice"
- [ ] Verify: `grep -c "classify_roles\|find_circular_deps\|review_diff\|impact_analysis\|changed_symbols\|diff_outline\|check_boundaries\|rename_symbol\|find_unused_imports" skills/refactor/SKILL.md` → ≥9 distinct tool references. `grep "DEGRADED\|degraded\|unavailable" skills/refactor/SKILL.md` → fallback pattern present.
- [ ] Acceptance: AC35, AC36, AC37, AC38, AC39, AC40, AC41
- [ ] Commit: `add CodeSift integration: classify_roles, review_diff, impact_analysis, and 7 more tools`

### Task 8: Update adversarial review block
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 5, Task 6a
**Execution routing:** default

- [ ] GREEN:
  - Add risk-sensitive mode selection: default `--mode code`, `--mode security` when diff touches auth/payment/crypto/PII/migration
  - Add meta-review check: if findings==0 AND diff_lines>150 → false-negative warning
  - Keep existing severity handling (CRITICAL/WARNING/INFO)
  - Keep "pre-existing is NOT a reason to skip" rule
  - Ensure batch mode's adversarial step (added in Task 6) uses the same updated block
- [ ] Verify: `grep -n "mode security\|mode code" skills/refactor/SKILL.md` → security override present. `grep "false-negative\|findings.*0\|150" skills/refactor/SKILL.md` → meta-review present.
- [ ] Acceptance: AC16, AC17
- [ ] Commit: `update adversarial review with --mode security override and zero-findings meta-review`

### Task 9: Update contract schema (v2→v3)
**Files:** `skills/refactor/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 5
**Execution routing:** default

- [ ] GREEN:
  - Update contract JSON example: `"version": 3`, `"stage": "PHASE-1"` (not ETAP-1A)
  - Add stage migration table in `continue` processing:
    - ETAP-1A → PHASE-1
    - ETAP-1B → PHASE-2
    - ETAP-2 → PHASE-3
    - COMPLETE → COMPLETE
  - Add mode migration: quick/standard/auto → full (silently, with log)
  - Update `no-commit` behavior: contract stage set to `EXECUTION_COMPLETE` (not `COMPLETE`)
  - Ensure `continue` description says mode is always `full`
- [ ] Verify: `grep '"version"' skills/refactor/SKILL.md` → shows 3 not 2. `grep "ETAP-1A" skills/refactor/SKILL.md` → only in migration table. `grep "EXECUTION_COMPLETE" skills/refactor/SKILL.md` → present for no-commit.
- [ ] Acceptance: AC15, AC18, AC20
- [ ] Commit: `update contract schema v2→v3 with phase stage names and mode migration`

### Task 10: Rewrite cq-auditor.md
**Files:** `skills/refactor/agents/cq-auditor.md`
**Complexity:** standard
**Dependencies:** Task 7 (cq-auditor must match machine_checks handoff defined in SKILL.md)
**Execution routing:** default

- [ ] GREEN: Full rewrite following execute/quality-reviewer.md pattern:
  1. **Frontmatter:** Keep name/description/model/reasoning/tools. Add execution profile line after frontmatter close.
  2. **Execution profile:** `> Execution profile: read-only analysis | Token budget: 3000 for CodeSift calls`
  3. **What You Receive:** 5 numbered items (modified files, tech stack, orchestrator CQ scores, CODESIFT_AVAILABLE + repo identifier, NEW: review_diff machine_checks)
  4. **Mandatory File Loading:** Fix paths — both use `../../../rules/` prefix: `../../../rules/cq-patterns.md` and `../../../rules/cq-checklist.md`. `[READ | MISSING → STOP]` semantics.
  5. **Tool Discovery:** "Do NOT call list_repos() — orchestrator provides repo identifier." Dual-path: CodeSift (get_file_outline, get_symbol, search_symbols with detail_level, token_budget: 3000) / fallback (Read/Grep/Glob). Source-of-truth annotation: "Apply gate definitions from cq-checklist.md — do NOT use memorized definitions."
  6. **Scoring Protocol:** Keep existing per-file scoring, print all 28 gates, evidence for critical gates at 1, N/A justification, >60% N/A = low-signal flag.
  7. **Output format:** Preamble-conformant:
     ```
     ## CQ Auditor Report
     ### Findings
     [per-file scorecards + DISCREPANCIES vs ORCHESTRATOR]
     VERDICT: [PASS | CONDITIONAL PASS | FAIL]
     FIX-NOW: N | DEFER: N
     ### Summary
     [N files, N discrepancies, overall verdict]
     ### BACKLOG ITEMS
     [DEFER items or "None"]
     ```
  8. **What You Must NOT Do:** ≥7 prohibitions (don't accept orchestrator scores without reading source, don't score from memory, don't exceed 3000 token budget, don't conflate absence-of-evidence with compliance, don't mark PASS without reading files, don't skip gates, don't modify files)
  9. **Error handling:** Empty modified files → STOP. File unreadable → report and skip. All N/A → low-signal flag.
- [ ] Verify: `grep -c "VERDICT:\|FIX-NOW:\|DEFER:\|BACKLOG ITEMS\|What You Must NOT Do\|Token budget.*3000\|../../../rules/" skills/refactor/agents/cq-auditor.md` → all present. `grep "cq-checklist" skills/refactor/agents/cq-auditor.md` → must contain `../../../rules/cq-checklist.md` (no bare reference).
- [ ] Acceptance: AC21, AC22, AC23, AC25, AC26, AC27, AC28, AC29
- [ ] Commit: `rewrite cq-auditor agent: CodeSift workflow, preamble output, verdict line, prohibitions`

### Task 11: Fix dependency-mapper.md and existing-code-scanner.md
**Files:** `skills/refactor/agents/dependency-mapper.md`, `skills/refactor/agents/existing-code-scanner.md`
**Complexity:** standard
**Dependencies:** Task 6a (agent dispatch contract in batch pipeline must exist before rewriting agent inputs)
**Execution routing:** default

- [ ] GREEN:
  **dependency-mapper.md:**
  1. Add execution profile: `> Execution profile: read-only analysis | Token budget: 5000`
  2. Define SCOPE: `SCOPE = directory containing the target file + "/**"`
  3. Fix DIRECT IMPORTERS example: add line numbers (`src/services/order.service.ts:14`)
  4. Replace 4 sequential CodeSift calls with `codebase_retrieval` batch query (outline + references + call_chain + context, token_budget=5000)
  5. Add preamble output structure: `## Dependency Mapper Report → ### Findings → ### Summary → ### BACKLOG ITEMS`
  6. Add error handling: no-exports → "leaf node" report; empty input → STOP; degraded mode → notice at top
  7. Add multi-file clarity note

  **existing-code-scanner.md:**
  1. Add execution profile: `> Execution profile: read-only analysis | Token budget: 3000`
  2. Define SCOPE (same pattern as dependency-mapper)
  3. Add `frequency_analysis(repo, file_pattern=SCOPE, kind="function,method", top_n=20)` in CodeSift workflow
  4. Add timing dependency note: if called before extraction plan finalized, flag `[PROVISIONAL]`
  5. Add preamble output structure: `## Existing Code Scan Report → ### Findings → ### Summary → ### BACKLOG ITEMS`
  6. Add same 3 error handling rules
- [ ] Verify:
  `grep "Execution profile\|Token budget\|SCOPE =\|BACKLOG ITEMS\|empty input\|degraded" skills/refactor/agents/dependency-mapper.md` → all present.
  `grep "codebase_retrieval" skills/refactor/agents/dependency-mapper.md` → batch query present.
  `grep ":14" skills/refactor/agents/dependency-mapper.md` → line number in example.
  `grep "frequency_analysis\|PROVISIONAL\|BACKLOG ITEMS\|Execution profile" skills/refactor/agents/existing-code-scanner.md` → all present.
- [ ] Acceptance: AC21, AC22, AC23, AC24, AC31, AC32, AC33, AC34
- [ ] Commit: `fix dependency-mapper and existing-code-scanner: execution profiles, batch queries, preamble output, error handling`

### Task 12: Final verification and line count gate
**Files:** `skills/refactor/SKILL.md`, all agent files
**Complexity:** standard
**Dependencies:** Task 1-11 (all preceding tasks)
**Execution routing:** default

- [ ] GREEN: Run the full verification suite:
  ```bash
  # Line count gate (AC3)
  wc -l skills/refactor/SKILL.md  # Must be ≤680

  # Phase headers (AC6)
  grep -c "^## Phase" skills/refactor/SKILL.md  # Must be 5

  # No eliminated modes (AC1, AC9)
  grep -in "quick\|standard\|auto mode" skills/refactor/SKILL.md | grep -v "migration\|legacy\|upgrade\|silently"  # Zero hits

  # No Phase 5 (AC6)
  grep "Phase 5" skills/refactor/SKILL.md  # Zero hits

  # Approval gate exists once in full mode (AC4)
  grep -c "APPROVAL GATE" skills/refactor/SKILL.md  # Exactly 1

  # No approval gates in batch mode (AC5)
  sed -n '/^## Batch Mode/,/^## /p' skills/refactor/SKILL.md | grep -i "approval"  # Zero hits

  # Backup branch in full mode (AC7)
  grep "backup branch\|backup/refactor" skills/refactor/SKILL.md  # Present in Phase 3

  # Contract version (AC15)
  grep '"version"' skills/refactor/SKILL.md  # Shows 3

  # Agent preamble structure (AC21)
  for f in skills/refactor/agents/*.md; do
    echo "--- $f ---"
    grep "BACKLOG ITEMS\|Execution profile\|Token budget" "$f"
  done

  # cq-auditor specific (AC26, AC27, AC28)
  grep -c "VERDICT:" skills/refactor/agents/cq-auditor.md  # ≥1
  grep -c "What You Must NOT Do" skills/refactor/agents/cq-auditor.md  # 1
  grep "cq-checklist" skills/refactor/agents/cq-auditor.md  # Must show ../../../rules/ prefix

  # External reference (docs/skills.md)
  grep "zuvo:refactor" docs/skills.md  # No quick/standard/auto

  # Include paths exist
  for f in shared/includes/codesift-setup.md shared/includes/env-compat.md shared/includes/quality-gates.md shared/includes/run-logger.md shared/includes/backlog-protocol.md rules/cq-patterns.md rules/cq-checklist.md; do
    ls "$f" >/dev/null 2>&1 || echo "MISSING: $f"
  done  # No output = all exist
  ```
- [ ] Verify: All commands above produce expected output
- [ ] Acceptance: AC1-AC41 comprehensive verification
- [ ] Commit: no commit (verification only)
