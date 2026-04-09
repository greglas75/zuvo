# Implementation Plan: zuvo:review Full Revision

**Spec:** docs/specs/2026-04-09-review-skill-revision-spec.md
**spec_id:** 2026-04-09-review-revision-1445
**planning_mode:** spec-driven
**plan_revision:** 2
**status:** Approved
**Created:** 2026-04-09
**Tasks:** 8 (1-6 independent, 7a→7b sequential, 8 final)
**Estimated complexity:** 5 standard, 3 complex

## Architecture Summary

This is a markdown-only project. No TypeScript, no npm, no test framework. All deliverables are `.md` files.

**Files to create (6):**
- `skills/review/agents/behavior-auditor.md` (~70L)
- `skills/review/agents/structure-auditor.md` (~60L)
- `skills/review/agents/cq-auditor.md` (~70L)
- `skills/review/agents/confidence-rescorer.md` (~55L)
- `shared/includes/fix-loop.md` (~50L)
- `memory/reviews/.gitkeep` (empty, placeholder for report persistence — inferred from D8/AC 12, not in spec's New Files table)

**Files to modify (2):**
- `skills/review/SKILL.md` (full rewrite: 920L → ~550L)
- `shared/includes/severity-vocabulary.md` (add footnote)

**No changes needed to:** `scripts/install.sh`, `scripts/build-codex-skills.sh`, `scripts/build-cursor-skills.sh`, `skills/using-zuvo/SKILL.md`. Build scripts already handle `agents/` subdirectories and `shared/includes/*.md` globs.

**Explicitly deferred:** `docs/review-queue.md` — spec marks as "post-implementation documentation follow-up." Not blocking.

## Technical Decisions

- Agent template: follow `quality-reviewer.md` structure (frontmatter with tools, numbered workflow, output template, calibration examples, "What You Must NOT Do")
- Agent preamble: all 4 agents include `Read and follow the agent preamble at ../../../shared/includes/agent-preamble.md`
- CodeSift degraded mode: borrow the pattern from `code-explorer.md` (explicit fallback section per agent)
- fix-loop.md: extract generic loop from current SKILL.md lines 582-671; review-specific wrapper (tag, stash, post-execute block) stays in SKILL.md Phase 4
- Confidence Re-Scorer: TIER 2+ only (spec is clear: "TIER 0-1: Lead scores inline")

## Quality Strategy

- **Structural verification:** `wc -l`, `ls`, `grep` checks for ACs 1-3, 11, 15, 18, 25 (7 auto-verifiable ACs)
- **Build verification:** `./scripts/install.sh` must complete without errors; verify agents appear in Claude Code cache and Codex/Cursor build output
- **No TDD:** This is a markdown-only project. Verification = structural checks + manual skill invocation
- **Backward compatibility:** MUST-FIX/RECOMMENDED/NIT severity labels unchanged. `ship` and `pentest` parse these — no format change = no breakage

## Task Breakdown

### Task 1: Create behavior-auditor.md
**Files:** `skills/review/agents/behavior-auditor.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Write: Create agent file following quality-reviewer.md template. Content from spec "Agent 1: Behavior Auditor" section. Include: YAML frontmatter (name, description, model: sonnet, reasoning: false, tools: Read/Grep/Glob), agent preamble reference, "What You Receive" (6 items from spec), Tool Discovery (CodeSift + degraded fallback from code-explorer.md pattern), Workflow (6 numbered steps from spec), Specific checks (CQ3/5/6/8/9/10 from spec), Output format (BEHAV-N template with Quality Wins section), Calibration examples (2 from spec: confidence 92 and 35), Degraded mode paragraph, "What You Must NOT Do" (5 items from spec).
- [ ] Verify: `wc -l skills/review/agents/behavior-auditor.md` — expect 60-80 lines
  Verify: `head -6 skills/review/agents/behavior-auditor.md` — expect YAML frontmatter with name/description/model/tools
  Verify: `grep -c "What You Must NOT Do" skills/review/agents/behavior-auditor.md` — expect 1
- [ ] Acceptance: AC 2, AC 26 (behavior auditor portion)
- [ ] Commit: `feat: add behavior-auditor agent for review skill — logic correctness, error handling, async safety checks`

### Task 2: Create structure-auditor.md
**Files:** `skills/review/agents/structure-auditor.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Write: Create agent file. Content from spec "Agent 2: Structure Auditor" section. Include: YAML frontmatter, agent preamble reference, "What You Receive" (6 items), Tool Discovery, Workflow (6 numbered steps), Output format (STRUCT-N template + File Metrics table + Quality Wins), Calibration examples (3 from spec: confidence 88, 32, 15), Degraded mode, "What You Must NOT Do" (4 items).
- [ ] Verify: `wc -l skills/review/agents/structure-auditor.md` — expect 50-65 lines
  Verify: `grep "file-limits.md" skills/review/agents/structure-auditor.md` — expect 1+ (references file limits)
- [ ] Acceptance: AC 2, AC 26 (structure auditor portion)
- [ ] Commit: `feat: add structure-auditor agent for review skill — naming, imports, file limits, SRP, coupling`

### Task 3: Create cq-auditor.md
**Files:** `skills/review/agents/cq-auditor.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Write: Create agent file. Content from spec "Agent 3: CQ Auditor" section. Include: YAML frontmatter, agent preamble reference, "What You Receive" (7 items — critically including PROJECT_CONTEXT as item 5), Tool Discovery, Workflow (3 numbered steps with substeps), Output format (CQ AUDIT per-file template + Cross-File Patterns + BACKLOG ITEMS), Calibration examples (3 from spec: CQ8=N/A correct, CQ8=0 correct, CQ8=0 WRONG), Degraded mode, "What You Must NOT Do" (5 items — including the CQ8 PROJECT_CONTEXT rule).
- [ ] Verify: `wc -l skills/review/agents/cq-auditor.md` — expect 60-75 lines
  Verify: `grep "PROJECT_CONTEXT" skills/review/agents/cq-auditor.md` — expect 3+ (in What You Receive, Workflow, What You Must NOT Do)
- [ ] Acceptance: AC 2, AC 7, AC 26 (CQ auditor portion)
- [ ] Commit: `feat: add cq-auditor agent for review skill — independent CQ1-CQ28 evaluation with PROJECT_CONTEXT`

### Task 4: Create confidence-rescorer.md
**Files:** `skills/review/agents/confidence-rescorer.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Write: Create agent file. Content from spec "Agent 4: Confidence Re-Scorer" section. Include: YAML frontmatter, agent preamble reference, "What You Receive" (6 items), Tool Discovery (minimal — mostly works from finding data), Workflow (6 numbered steps), Scoring factors table (10 rows from spec, including adversarial CRITICAL = 100 override), Output format (Dispositions table with ID/Severity/Confidence/Disposition/Rationale columns), Calibration examples (3 from spec: confidence 92, 28, 100), Degraded mode, "What You Must NOT Do" (4 items — critically including "never override adversarial CRITICAL bypass").
- [ ] Verify: `wc -l skills/review/agents/confidence-rescorer.md` — expect 45-60 lines
  Verify: `grep "CRITICAL.*bypass\|bypass.*CRITICAL" skills/review/agents/confidence-rescorer.md` — expect 1+ (adversarial bypass rule)
- [ ] Acceptance: AC 2, AC 8, AC 26 (confidence rescorer portion)
- [ ] Commit: `feat: add confidence-rescorer agent for review skill — scoring with adversarial CRITICAL bypass`

### Task 5: Create fix-loop.md
**Files:** `shared/includes/fix-loop.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Write: Create shared include. Content from spec "Shared Include: fix-loop.md" section. Extract the generic fix loop from current SKILL.md lines 582-671. Include: Input section (FINDINGS, SCOPE_FENCE, MODE), Execution Strategy table (sequential vs parallel), Fix Loop steps (5 steps), Execute Verification Checklist (7 Y/N items), Commit section (git add specific files, structured message, interactive/non-interactive handling), High-Risk Fix Policy.
  Do NOT include: review-specific git tag, post-execute banner, stash management, backlog persistence, auto-fix zuvo:build dispatch — these stay in SKILL.md wrapper.
- [ ] Verify: `wc -l shared/includes/fix-loop.md` — expect 40-55 lines
  Verify: `grep -c "git tag" shared/includes/fix-loop.md` — expect 0 (review-specific, not in shared include)
  Verify: `grep "SCOPE_FENCE" shared/includes/fix-loop.md` — expect 1+
- [ ] Acceptance: AC 15
- [ ] Commit: `feat: extract fix-loop.md shared include — wired to review, build adoption deferred`

### Task 6: Update severity-vocabulary.md
**Files:** `shared/includes/severity-vocabulary.md`
**Complexity:** standard
**Dependencies:** none

- [ ] Write: Add footnote after Rule 4 (line 57-58). The footnote clarifies that the existing "adversarial loop" row (CRITICAL/WARNING/INFO → S1/S2/S4) covers all adversarial-review.sh output regardless of which skill invokes it. Add: "Within `/review`, CRITICAL findings bypass the confidence gate (D7 — effective confidence = 100)."
- [ ] Verify: `grep "bypass the confidence gate" shared/includes/severity-vocabulary.md` — expect 1
  Verify: `wc -l shared/includes/severity-vocabulary.md` — expect ~62 (was 58, +4 for footnote)
- [ ] Acceptance: AC 25
- [ ] Commit: `fix: add D7 adversarial bypass footnote to severity-vocabulary.md`

### Task 7a: Rewrite SKILL.md — Sections 1-6 (Preamble through Phase 0.5)
**Files:** `skills/review/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 5 (fix-loop.md must exist for Phase 4 reference validation)
**Execution routing:** deep implementation tier

First half of the SKILL.md rewrite. **Read the current SKILL.md fully before starting** — git has history but the implementer needs the original content as reference for sections being rewritten. Write sections 1-6 (~260 lines) as the new file content.

**NO COMMIT after this task.** The file is in a WIP state (only sections 1-6). Task 7b appends sections 7-12 and commits the complete file. Do NOT run `install.sh` between 7a and 7b.

- [ ] Write: Write sections 1-6 of the new SKILL.md:

  **Section 1 — Frontmatter + Intro (~10L):** Keep existing frontmatter. Update intro to match spec line 12.

  **Section 2 — Mandatory File Loading (~40L):** Implement tiered loading from spec. Split CORE (STOP) vs OPTIONAL (degraded) vs CONDITIONAL. Key change: `cq-patterns.md` is conditional (TIER 2+), `cq-patterns-core.md` at TIER 1 only. Add `cross-provider-review.md` to conditional (always loaded).

  **Section 3 — Argument Parsing (~45L):** Copy scope table from current (lines 62-80). Update mode table: add `auto-fix` and `--depth N` rows. Update `new` scope resolution: replace hardcoded `main` with `DEFAULT_BRANCH` detection (spec bash snippet).

  **Section 4 — Tier System (~90L):** Include updated Tier Capabilities table (from spec — 13 rows). Add edge case rows: empty diff, binary-only, binary+code, merge commit (with non-interactive fallback). Add deployment risk scoring with B12 fix (hotspot factor = 0 at TIER 0-1). Keep intent adjustments and FIX-ALL blockers.

  **Section 5 — Phase 0: Setup (~45L):** Keep Knowledge Prime, CodeSift Setup, Hotspot Detection (TIER 2+), Blast Radius (TIER 2+), Dead Code Scan. Add stack-specific rule loading (F3, spec's stack indicator table). Add default branch detection.

  **Section 6 — Phase 0.5: CodeSift Pre-Compute (~30L):** NEW section from spec. TIER 0 optional, TIER 1 three queries, TIER 2-3 five queries. Include "What each agent receives" table. Include PRECOMPUTED_DATA description. Note degraded mode (CodeSift unavailable → agents use Read/Grep fallback per their own degraded-mode sections).

- [ ] Verify: `grep "cq-patterns-core.md" skills/review/SKILL.md` — expect 1+ (AC 5)
  Verify: `grep "auto-fix" skills/review/SKILL.md` — expect 2+ (AC 11)
  Verify: `grep "DEFAULT_BRANCH\|symbolic-ref" skills/review/SKILL.md` — expect 1+ (AC 14)
  Verify: `grep "0 files changed\|No changes to review\|empty diff" skills/review/SKILL.md` — expect 1+ (AC 10)
  Verify: `grep "\-\-depth" skills/review/SKILL.md` — expect 1+ (AC 18)
  Verify: `grep "PRECOMPUTED_DATA\|codebase_retrieval\|Phase 0.5" skills/review/SKILL.md` — expect 2+ (AC 6)
  Verify: `grep "cross-provider-review.md" skills/review/SKILL.md` — expect 1+
- [ ] Acceptance: AC 5, 6, 10, 11, 14, 18, 22
- [ ] Commit: **NO COMMIT** — WIP state. Task 7b commits the complete file.

### Task 7b: Rewrite SKILL.md — Sections 7-12 + directory setup
**Files:** `skills/review/SKILL.md`, `memory/reviews/.gitkeep`, `.gitignore`
**Complexity:** complex
**Dependencies:** Task 7a, Task 1, Task 2, Task 3, Task 4 (agents must exist for dispatch references)
**Execution routing:** deep implementation tier

Second half of the SKILL.md rewrite. Appends sections 7-12 (~290 lines) to the file written in Task 7a. Also creates `memory/reviews/` directory and ensures `.gitignore` coverage. Total SKILL.md should be ≤600 lines. **This task makes the single commit for the full SKILL.md rewrite.**

- [ ] Write: Append sections 7-12:

  **Section 7 — Phase 1: Audit (~80L):** Two flow variants (standard and --thorough) from spec. Merged banner (D9) replaces 4 blocks. Agent dispatch: TIER 0-1 no agents, TIER 2 Behavior+CQ, TIER 3 all 3 — reference `agents/*.md` files. Inline audit for TIER 0-1. CQ self-eval (TIER 1+). Q1-Q19 (if test files). Adversarial: bash script at ALL tiers with failure modes. Self-review escalation. Multi-pass + adversarial interaction paragraph. Pre-existing issue reporting.

  **Section 8 — Phase 2: Confidence Gate (~25L):** Dispatch logic (TIER 0-1 inline, TIER 2+ agent). New disposition table (0-25 EXCLUDE, 26-50 EXCLUDE, 51-100 KEEP). Backlog write timing (AFTER Phase 4, not during). Adversarial CRITICAL bypass (D7).

  **Section 9 — Phase 3: Report (~80L):** New 14-section report order with QUESTIONS at position 4. Questions Gate integrated (pause in FIX modes, re-evaluate findings). Severity tiers table. NIT visual subordination. Report persistence to `memory/reviews/`. QUALITY WINS specification. NEXT STEPS block with Run: log line. Knowledge curation.

  **Section 10 — Phase 4: Execute (~30L):** Reference `../../shared/includes/fix-loop.md`. Mode dispatch (FIX-ALL, FIX-BLOCKING, AUTO-FIX). Review-specific wrapper: git tag, Post-Execute block, backlog persistence. Staged+fix stash management (B5) with finally-block recovery. Closed-loop auto-fix (dispatch zuvo:build, max 1 cycle).

  **Section 11 — Batch Mode (~60L):** Keep input format, enrichment, per-commit loop. Fix B10: TIER 3 in batch runs full review inline (sequential agents). Keep resume logic and completion block.

  **Section 12 — Utility Modes (~35L):** Keep tag, mark-reviewed, status. Add `--depth N` to status (B11, default 100).

- [ ] Verify: `wc -l skills/review/SKILL.md` — expect ≤600 lines (AC 1)
  Verify: `grep -c "agents/behavior-auditor.md\|agents/structure-auditor.md\|agents/cq-auditor.md" skills/review/SKILL.md` — expect 3+ (agent references)
  Verify: `grep -c "adversarial-review" skills/review/SKILL.md` — expect 2+ (bash script call)
  Verify: `grep -c "Adversarial Auditor" skills/review/SKILL.md` — expect 0 (removed, AC 3)
  Verify: `grep "fix-loop.md" skills/review/SKILL.md` — expect 1+ (AC 15)
  Verify: `grep "memory/reviews/" skills/review/SKILL.md` — expect 1+ (AC 12)
  Verify: `grep "QUESTIONS FOR AUTHOR" skills/review/SKILL.md` — expect 1+ near section 4 of report (AC 13)
  Verify: `grep "QUALITY WINS" skills/review/SKILL.md` — expect 1+ (AC 20)
  Verify: `grep "stash" skills/review/SKILL.md` — expect 2+ (AC 16)
  Verify: `grep "TIER 3 in batch\|sequential agent" skills/review/SKILL.md` — expect 1+ (AC 17)
  Verify: `grep "CRITICAL.*bypass\|bypass.*confidence" skills/review/SKILL.md` — expect 1+ (AC 8)
  Verify: `grep "backlog.*AFTER\|after.*execute\|Phase 4.*backlog" skills/review/SKILL.md` — expect 1+ (AC 9)
- [ ] Setup: `mkdir -p memory/reviews && touch memory/reviews/.gitkeep`
  If `.gitignore` does not contain `memory/`: append `memory/reviews/`
- [ ] Acceptance: AC 1, 3, 4, 8, 9, 12, 13, 16, 17, 19, 20, 21, 23, 24
- [ ] Commit: `feat: rewrite zuvo:review — phase restructure, tiered loading, adversarial at all tiers, token optimization`

### Task 8: Install and verify
**Files:** none (verification only)
**Complexity:** complex
**Dependencies:** Task 1, 2, 3, 4, 5, 6, 7a, 7b

- [ ] Run: `./scripts/install.sh` — expect exit code 0. If non-zero, capture output and diagnose.
- [ ] Verify static ACs:
  `wc -l skills/review/SKILL.md` — ≤600 (AC 1)
  `ls skills/review/agents/*.md | wc -l` — 4 (AC 2)
  `wc -l shared/includes/fix-loop.md` — 40-55 (AC 15)
  `grep -c "Adversarial Auditor" skills/review/SKILL.md` — 0 (AC 3)
  `grep "PRECOMPUTED_DATA" skills/review/SKILL.md` — 1+ (AC 6)
  `grep "PROJECT_CONTEXT" skills/review/agents/cq-auditor.md` — 3+ (AC 7)
  `grep "CRITICAL.*bypass" skills/review/SKILL.md` — 1+ (AC 8)
  `grep "bypass" shared/includes/severity-vocabulary.md` — 1+ (AC 25)
- [ ] Verify install artifacts:
  `ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/skills/review/agents/*.md 2>/dev/null | wc -l` — 4+ files
  `ls ~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/shared/includes/fix-loop.md 2>/dev/null | wc -l` — 1+ file
  `test -d memory/reviews` — directory exists
  `grep "memory" .gitignore` — entry present
- [ ] Behavioral verification scenarios (run in a new Claude Code session after install):
  **Scenario 1 — TIER 0 happy path (covers ACs 4, 10, 19, 21):**
    Make a 5-line change to any file. Run `zuvo:review`.
    Expected: merged banner (single block), adversarial-review.sh executes, NITs collapsed, PASS verdict.
  **Scenario 2 — Empty diff (covers AC 10):**
    Clean working tree. Run `zuvo:review`.
    Expected: "No changes to review." message and STOP.
  **Scenario 3 — TIER 2+ with findings (covers ACs 8, 9, 12, 13, 20, 23):**
    Make a 200-line change with at least one CQ violation. Run `zuvo:review`.
    Expected: agents dispatched, QUESTIONS before FINDINGS in report, report saved to memory/reviews/, QUALITY WINS section present, all findings in backlog.
  **Scenario 4 — staged + fix (covers AC 16):**
    Stage a file with a known issue. Run `zuvo:review staged fix`.
    Expected: stash management visible in output, fix committed separately from staged changes.
- [ ] Acceptance: All 26 ACs. Scenarios 1-4 cover the 10 behavioral ACs. Remaining ACs verified by static checks.
- [ ] Commit: none (verification only)
