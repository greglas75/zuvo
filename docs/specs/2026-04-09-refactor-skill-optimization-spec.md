# zuvo:refactor Skill Optimization — Design Specification

> **spec_id:** 2026-04-09-refactor-skill-optimization-1845
> **topic:** Refactor skill structural overhaul — mode reduction, contradiction fixes, agent prompt rewrites
> **status:** Draft
> **created_at:** 2026-04-09T18:45:00Z
> **approved_at:** null
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

The `zuvo:refactor` skill (812 lines, 5 modes, 3 agents) has accumulated structural debt:

1. **5 execution modes** (quick/standard/full/auto/batch) where only 2 are needed. The owner always uses `full` because the savings from quick/standard/auto are marginal (~30s, ~5K tokens). Mode proliferation is the root cause of 6+ documented bugs.
2. **4 critical contradictions** in the skill text — plan approval gate says both "HARD STOP" and "proceed immediately"; batch mode inverts agent dispatch order; GOD_CLASS conflicts with batch's one-commit rule; no failure handling in ETAP-2.
3. **Agent prompts are undertested** — cq-auditor scores 2.75/5 (missing CodeSift workflow, broken output format, no verdict line); all 3 agents miss preamble-required BACKLOG ITEMS structure, error handling, and token budgets.
4. **~60-70 lines of proven redundancy** — duplicated mode criteria, copy-pasted adversarial block, env-compat appendix that reproduces the shared include.

If we do nothing: every new feature added to refactor will interact with 5 mode branches, increasing the bug surface. Agent outputs will continue to silently break the backlog pipeline.

## Design Decisions

### D1: Reduce from 5 modes to 2 (full + batch)

**Chosen:** Merge quick, standard, and auto into full. Keep batch as a separate mode.

**Why:** The owner confirmed they never use anything except full. The token/time savings of quick (~5K tokens) and standard (~3K tokens) are negligible. auto differs from full by exactly one approval gate — not worth a named mode. Eliminating 3 modes removes ~150 lines and fixes 6+ bugs caused by mode interaction (C1, C4, E2, E8, L2, L4).

**Alternatives considered:**
- Keep 4 modes (merge auto into full only) — still leaves quick/standard complexity
- Keep all 5, fix bugs individually — higher maintenance cost, same bugs will recur

### D2: One approval gate after ETAP-1A (type + plan)

**Chosen:** Full mode stops once after showing detected type and refactoring plan. User can confirm, change type, or modify plan. After that — zero stops until completion.

**Why:** The owner wants to verify the agent chose the right refactoring type and plan, but doesn't want interruptions during test writing, execution, or CQ auditing. Batch mode keeps zero stops (autonomous).

**Alternatives considered:**
- Zero gates everywhere — risks executing wrong refactoring type with no recovery
- Plan + test gates (original full mode) — owner explicitly rejected test gate

### D3: Keep cq-auditor role, rewrite prompt

**Chosen:** Independent CQ verification is valuable (catches rubber-stamped gates). The concept stays, the prompt gets a full rewrite.

**Why:** RefAgent research shows dedicated validators improve test pass rate by +64.7% over inline self-eval. The current prompt is an early draft (2.75/5) — missing CodeSift workflow, broken output format, no verdict line. Rewriting brings it to parity with execute/quality-reviewer (the mature version of the same concept).

**Alternatives considered:**
- Remove cq-auditor entirely, rely on adversarial review — loses the orchestrator-vs-auditor comparison that catches self-assessment bias
- Replace with a post-execution validator (compiler + tester) — the orchestrator already runs tsc + tests inline; a separate agent for this adds dispatch cost without new signal

### D8: Integrate underused CodeSift tools throughout the pipeline

**Chosen:** Add `review_diff`, `classify_roles`, `impact_analysis`, `changed_symbols`, `find_circular_deps`, `rename_symbol`, `find_unused_imports`, and `check_boundaries` at specific pipeline stages. Batch agent queries via `codebase_retrieval` where possible.

**Why:** The skill currently uses only 4 CodeSift tools in Phase 0 pre-scan (`analyze_complexity`, `analyze_hotspots`, `find_clones`, `find_dead_code`). At least 10 more tools are directly relevant but unused:

- `review_diff(until="STAGED")` runs 9 parallel static analysis checks (secrets, breaking changes, coupling, complexity, dead-code, blast-radius, bug-patterns, test-gaps, hotspots) in ~200ms — covers ~40% of CQ gates automatically
- `classify_roles` classifies symbols as entry/core/utility/dead/leaf — dead = delete before refactoring, leaf = safe to move, core = handle with care
- `impact_analysis(since="HEAD~1")` after execution verifies blast radius matches scope fence
- `changed_symbols` + `diff_outline` verify API surface preservation (behavioral equivalence)
- `rename_symbol` is LSP-based cross-file rename — eliminates manual edit-all-imports for RENAME_MOVE type
- `find_circular_deps` is native cycle detection — essential for BREAK_CIRCULAR type
- `find_unused_imports` cleans up stale imports after code movement
- `check_boundaries` verifies no architectural boundary violations after extraction
- `frequency_analysis` groups functions by AST shape — finds duplication invisible to `find_clones`

**Agent impact:**
- dependency-mapper: batch queries via single `codebase_retrieval` call instead of 4 sequential calls
- existing-code-scanner: add `frequency_analysis` for AST-level deduplication
- cq-auditor: consume `review_diff` output as machine-verified baseline, focus manual audit on domain-specific gates (CQ5 PII, CQ9 transactions, CQ19 validation) that CodeSift cannot check

### D4: Unify phase numbering

**Chosen:** Single numbering system: Phase 0-4. Use ETAP stage names as descriptive labels within phases, not as a parallel numbering scheme.

**Why:** Dual numbering (Phase N + ETAP-N) confuses readers. Phase 2 = ETAP-1A, Phase 3 = ETAP-1B, Phase 4 = ETAP-2 — the mapping is non-obvious. Build and review use only phase numbers.

### D5: Fix batch mode agent ordering

**Chosen:** In batch per-file pipeline, run Dependency Mapper + Existing Code Scanner in step 1 (before planning), not in step 4 (after execution).

**Why:** These agents exist to inform the plan. Running them after execution defeats their purpose. CQ Auditor stays post-execution (that is its correct position).

### D6: GOD_CLASS exception in batch mode

**Chosen:** Document explicit exception: GOD_CLASS files in batch produce multiple commits (one per extracted responsibility). This overrides the general "one commit per file" rule.

**Why:** GOD_CLASS requires iterative decomposition by design. Forcing single-commit would require extracting all responsibilities at once, which the GOD_CLASS protocol explicitly forbids ("Do NOT extract all responsibilities at once").

### D7: Add failure handling to ETAP-2 execution

**Chosen:** Define explicit recovery paths for tsc failure, test failure, and lint failure during execution.

**Why:** Currently the skill goes silent on any Phase 4 failure. The backup branch is created but never referenced in failure paths.

### D9: Migrate existing contract state files

**Chosen:** When `continue` loads a contract with `"mode": "quick"`, `"mode": "standard"`, or `"mode": "auto"`, silently upgrade it to `"mode": "full"` and proceed. Log the migration.

**Why:** Existing `.zuvo/contracts/refactor-*.json` files may contain eliminated mode names. Without a migration rule, `continue` on an old contract has undefined behavior.

### D10: GOD_CLASS partial failure in batch mode

**Chosen:** If a GOD_CLASS extraction fails mid-sequence in batch mode, keep all previously committed extractions (they are atomic and tested). Mark the contract as `PARTIAL` with a list of completed and remaining extractions. Mark the queue entry as `[!] PARTIAL` with details.

**Why:** GOD_CLASS multi-commit exception (D6) interacts with batch failure policy. Reverting all extractions when only the last one failed would destroy valid work.

## Solution Overview

### SKILL.md restructure

```
Phase 0: Stack Detection + CodeSift Setup + Pre-Scan
Phase 1: Type Detection + CQ Pre-Audit
  → APPROVAL GATE: show type + plan, wait for OK
Phase 2: Test Handling (write/verify/improve)
Phase 3: Execution + CQ Post-Audit + Adversarial Review
  → Failure handling with backup branch recovery
Phase 4: Completion (commit, contract, backlog, knowledge)
```

Flags retained: `no-commit`, `plan-only`, `continue`.

Batch mode: Phase 0 (parse + triage queue) → per-file pipeline (Phase 0-4, zero stops, GOD_CLASS multi-commit exception).

### Agent prompt rewrites

All 3 agents get:
- Execution profile header with token budget
- Preamble-conformant output (`## Report → ### Findings → ### Summary → ### BACKLOG ITEMS`)
- Error handling (empty input, missing files, degraded mode notice)
- SCOPE placeholder definition

cq-auditor additionally gets:
- Full CodeSift workflow (when available / not available)
- Machine-parseable `VERDICT: PASS | CONDITIONAL PASS | FAIL` line
- "What You Must NOT Do" section (7 prohibitions)
- Consistent file path notation

## Detailed Design

### SKILL.md changes

#### Sections to remove (~170 lines saved)

| Section | Lines | Reason |
|---------|-------|--------|
| Mode Comparison table | ~15L | Only 2 modes remain; table unnecessary |
| QUICK Mode description | ~10L | Mode eliminated |
| STANDARD Mode description | ~10L | Mode eliminated |
| Mode Resolution logic | ~30L | No auto-detection needed; full is default, batch is explicit |
| Environment Adaptation appendix | ~14L | Redundant with env-compat.md |
| IMPROVE_TESTS appendix | ~10L | Merged into Phase 2 (test handling) |
| Conditional mode logic throughout | ~80L | Scattered `if QUICK skip` / `if STANDARD inline` branches removed |

#### Sections to add (~30 lines)

| Section | Lines | Content |
|---------|-------|---------|
| ETAP-2 failure handling | ~15L | tsc fail → fix+retry(3x), test fail → revert to last passing extraction, backup branch fallback |
| Adversarial `--mode` risk override | ~4L | If diff touches auth/payment/crypto/PII/migration → `--mode security` |
| GOD_CLASS batch exception | ~5L | Multi-commit override in batch with explicit documentation |
| GOD_CLASS partial failure in batch | ~5L | Keep completed extractions, mark contract PARTIAL |
| Adversarial zero-findings meta-review | ~3L | If findings==0 AND diff>150 lines → false-negative warning |
| Contract mode migration | ~3L | Silently upgrade old quick/standard/auto modes to full on `continue` |
**Net result: ~812L → ~650L** (20% reduction)

#### Explicit deletions (contradiction resolution)

These specific lines/sections from the current SKILL.md must be deleted or rewritten:

| Contradiction | Current text to delete | Replacement |
|---------------|----------------------|-------------|
| C1 (Plan Display blanket "no gate") | Lines 416-418: "Display the plan, then proceed immediately. No approval gate" | Replace with the Approval Gate specification below |
| C2 (STANDARD approval stop) | Lines 117-119: STANDARD mode flow with "APPROVAL STOP" | Delete entirely (STANDARD mode eliminated) |
| C3 (batch agent ordering) | Lines 674 step 4: agents after execution | Reorder per batch pipeline spec below (agents in step 1) |
| C4 (missing failure handling) | Lines 501-509: verification list with no failure actions | Replace with Failure Recovery table below |

#### Phase renaming

Current Phase 5 (Completion) becomes Phase 4. All internal references updated:

| Current | New | Description |
|---------|-----|-------------|
| Phase 0 | Phase 0 | Stack Detection + CodeSift Setup + Pre-Scan |
| Phase 1 | Phase 1 | Type Detection + CQ Pre-Audit + APPROVAL GATE |
| Phase 2 | (removed) | CONTRACT and Planning — merged into Phase 1 |
| Phase 3 | Phase 2 | Test Handling |
| Phase 4 | Phase 3 | Execution + Post-Audit + Adversarial Review |
| Phase 5 | Phase 4 | Completion |

#### Approval gate specification

```markdown
## APPROVAL GATE (full mode only; skipped in batch)

After Phase 1 completes, display:

    REFACTOR PLAN: [filename] ([N]L)
    Type: [EXTRACT_METHODS / SPLIT_FILE / ...]
    Scope: [N] files
    Extractions: [summary of planned changes]
    CQ targets: [which CQ failures to fix]
    Test mode: [RUN_EXISTING / WRITE_NEW / IMPROVE_TESTS / VERIFY_COMPILATION]

    [Confirm / change type / modify plan]

Wait for user input. If the user changes the type or plan:
1. The orchestrator (not agents) recomputes scope, extractions, and test mode inline.
2. Sub-agents are NOT re-dispatched — their analysis (dependency map, existing code scan) remains valid.
3. Re-display the updated plan.
4. Wait for confirmation again.
Proceed only after explicit confirmation.
```

#### ETAP-2 failure handling specification

```markdown
### Failure Recovery (Phase 3)

| Failure | Action |
|---------|--------|
| tsc/type-check fails | Fix type errors. Retry up to 3 times. If still failing after 3 attempts: revert current extraction, mark in contract as BLOCKED, proceed to next extraction (GOD_CLASS) or stop (single extraction). |
| Tests fail after extraction | Revert to the last passing commit. Re-analyze: was the extraction incorrect, or does the test need updating? If test is testing internal implementation (not behavior): update test. If extraction broke behavior: revert extraction and try a different approach. |
| Lint fails | Fix lint issues. This should never block — lint is auto-fixable in most cases. |
| Adversarial CRITICAL | Fix immediately. Re-run adversarial on the fix. Max 2 iterations. |
| All verifications fail | Restore from backup branch. Mark contract as BLOCKED. Report to user. |
```

#### Adversarial review update

```markdown
### Adversarial Review (MANDATORY — do NOT skip)

**Risk-sensitive mode selection:**
- Default: `--mode code`
- If diff touches auth, payment, crypto, PII, or migration files: `--mode security`

```bash
git add -u && git diff --staged | adversarial-review --json --mode [code|security]
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. Verify first if confidence is low.
- **WARNING** — fix if localized (< 10 lines). Larger fixes → backlog with file:line.
- **INFO** — known concerns (max 3, one line each).

**Meta-review:** If findings == 0 AND diff_lines > 150: add false-negative warning — large diffs with zero findings suggest insufficient review depth.

Do NOT discard findings based on confidence alone. "Pre-existing" is NOT a reason to skip — if the issue is in a file you are editing, fix it now.
```

#### Batch mode agent ordering fix

```markdown
### Per-File Pipeline (batch mode)

Steps (ALL mandatory, in order):

1. **Analysis:** Read file → dispatch Dependency Mapper + Existing Code Scanner (parallel) → CQ1-CQ28 BEFORE (all 28 gates) → type detect → scope freeze → create contract
2. **Test handling:** Write/verify tests per test mode routing
3. **Execution:** Execute fixes per CONTRACT → verify (type check + tests)
4. **Post-Audit:** Dispatch CQ Auditor (independent verification, read-only). The **orchestrator** applies FIX-NOW items returned by the auditor (the auditor itself never modifies files). Print CQ1-CQ28 AFTER (all 28 gates).
5. **Adversarial:** Run adversarial review on staged diff.
6. **Commit:** ONE commit for this file only (exception: GOD_CLASS → multi-commit per extracted responsibility).
7. **Queue update:** Update line with CQ before/after and commit hash.
8. **Backlog:** Persist DEFER items.
```

### CodeSift integration (D8)

#### Phase 0 Pre-Scan — Enhanced

Current 4 calls stay. Add 2 new calls:

```
EXISTING (keep):
  analyze_complexity(repo, top_n=10, file_pattern=SCOPE)
  analyze_hotspots(repo, since_days=90)
  find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)
  find_dead_code(repo, file_pattern=SCOPE)

NEW:
  classify_roles(repo, file_pattern=SCOPE)           # → dead/leaf/core/entry classification
  find_circular_deps(repo, file_pattern=SCOPE)        # → for BREAK_CIRCULAR type detection
```

Print enhanced pre-scan:

```
REFACTOR PRE-SCAN
------------------------------------
Complexity: target ranks #N/10 (cyclomatic X, function: Y)
Hotspot:    changed N times in 90 days
Clones:     N blocks (X% similar) with [file:lines]
Dead code:  N unused exports ([names])
Roles:      N dead symbols (delete first), N leaf (safe to move), N core (careful)
Cycles:     [N cycles detected | no cycles]
------------------------------------
```

`classify_roles` output directly informs the extraction plan:
- `dead` symbols → delete before refactoring (reduce scope)
- `leaf` symbols → safe extraction targets (low blast radius)
- `core` symbols → handle with extra care (high fan-out)
- `entry` symbols → do not move without re-export

#### Phase 3 Execution — Type-specific CodeSift tools

| Refactor type | CodeSift tool | Use |
|---------------|--------------|-----|
| RENAME_MOVE | `rename_symbol(repo, old_name, new_name)` | LSP-based cross-file rename — replaces manual edit-all-imports |
| BREAK_CIRCULAR | `find_circular_deps(repo)` before + after | Verify cycles are broken |
| Any (post-execution) | `find_unused_imports(repo, file_pattern=SCOPE)` | Clean stale imports after code movement |

#### Phase 3 Post-Audit — CodeSift verification layer

After execution, before CQ Auditor agent and adversarial review, run:

```
# Machine verification (CodeSift)
review_diff(repo, since="HEAD~1", until="STAGED",
            checks="breaking-changes,test-gaps,dead-code,complexity,blast-radius",
            token_budget=10000)

impact_analysis(repo, since="HEAD~1")               # blast radius vs scope fence
changed_symbols(repo, since="HEAD~1")                # API surface change detection
diff_outline(repo, since="HEAD~1")                   # structural diff
check_boundaries(repo, rules=PROJECT_RULES)           # arch boundary check (if rules defined)
```

**`review_diff` integration with CQ Auditor:**
- Pass `review_diff` output to CQ Auditor agent as `machine_checks` input
- CQ Auditor uses machine checks as verified baseline for: test-gaps (maps to CQ coverage), dead-code (CQ dead exports), complexity (CQ complexity gates), breaking-changes (CQ24 backward compat)
- CQ Auditor focuses manual effort on domain-specific gates CodeSift cannot check: CQ5 (PII in logs), CQ8 (error strategy), CQ9 (transactions), CQ14 (shared helpers), CQ19 (input validation), CQ25 (pattern consistency)

**`impact_analysis` integration with scope fence:**
- If `impact_analysis` returns affected files OUTSIDE the scope fence → WARNING: refactoring has unintended blast radius. Either expand scope fence or fix the leak.

**`changed_symbols` integration with behavioral equivalence:**
- If any REMOVED symbol was consumed externally (cross-reference with dependency-mapper output) → CRITICAL: breaking change detected.
- If any MODIFIED symbol changed its signature → WARNING: verify all callers updated.

#### Agent CodeSift batching

**dependency-mapper** — Replace 4 sequential calls with one batch:

```
codebase_retrieval(repo, queries=[
  {type: "outline", file_path: "target.ts"},
  {type: "references", symbol_name: "exportA"},
  {type: "references", symbol_name: "exportB"},
  {type: "call_chain", symbol_name: "criticalFn", direction: "callers"},
  {type: "context", file_path: "target.ts"}
], token_budget=5000)
```

**existing-code-scanner** — Add `frequency_analysis` for AST-level deduplication:

```
frequency_analysis(repo, file_pattern=SCOPE, kind="function,method", top_n=20)
```

Groups functions by normalized AST shape — finds structural duplication that `find_clones` (text-similarity) misses. If a planned extraction has an AST-similar function elsewhere → flag as EXTEND candidate.

**cq-auditor** — Receives `review_diff` output from orchestrator:

```
## What You Receive (updated)

1. Modified files list
2. Tech stack
3. Orchestrator's CQ scores (self-eval)
4. CODESIFT_AVAILABLE + repo identifier
5. **NEW: review_diff output** — machine-verified checks on the staged diff
```

### Agent prompt changes

#### cq-auditor.md — Full rewrite

Key additions:
1. **Execution profile:** `> Execution profile: read-only analysis | Token budget: 3000 for CodeSift calls`
2. **CodeSift workflow:** Dual-path (when available / not available) with specific tool calls: `get_file_outline`, `get_symbol`, `search_symbols` with `detail_level="compact"`. Consume `review_diff` output for machine-verified gates.
3. **Mandatory file loading:** Fix path notation — both paths use `../../../rules/` prefix consistently with `[READ | MISSING → STOP]` semantics
4. **Output format:** Preamble-conformant structure:
   ```
   ## CQ Auditor Report
   ### Findings
   [per-file CQ scorecards + DISCREPANCIES vs ORCHESTRATOR]
   VERDICT: [PASS | CONDITIONAL PASS | FAIL]
   FIX-NOW: N | DEFER: N
   ### Summary
   [N files audited, N discrepancies, overall verdict]
   ### BACKLOG ITEMS
   [DEFER items in backlog format, or "None"]
   ```
5. **"What You Must NOT Do" section:** 7 explicit prohibitions (don't accept orchestrator scores without reading source, don't score from memory, don't exceed token budget, don't conflate absence-of-evidence with compliance, etc.)
6. **Error handling:** Empty modified files list → STOP. File unreadable → report and skip. All N/A → flag as low-signal.

#### dependency-mapper.md — Targeted fixes

1. **Execution profile:** Add `> Execution profile: read-only analysis | Token budget: 3000`
2. **Output format:** Add line numbers to DIRECT IMPORTERS example (`src/services/order.service.ts:14 — uses: functionA`)
3. **SCOPE definition:** Add note: `SCOPE = directory containing the target file. For src/services/order.service.ts, SCOPE = "src/services/**"`
4. **Error handling:** Add 3 rules: no-exports → "leaf node" report; empty input → STOP; degraded mode → notice at top of report
5. **Preamble alignment:** Wrap output in `## Dependency Mapper Report → ### Findings → ### Summary → ### BACKLOG ITEMS`
6. **Multi-file clarity:** Add note on whether to run once per file or once per refactor scope

#### existing-code-scanner.md — Targeted fixes

1. **Execution profile:** Add `> Execution profile: read-only analysis | Token budget: 3000`
2. **SCOPE definition:** Same as dependency-mapper
3. **Timing dependency:** Add note: if called before extraction plan is finalized, flag provisional extractions with `[PROVISIONAL]`
4. **Error handling:** Same 3 rules as dependency-mapper
5. **Preamble alignment:** Wrap output in `## Existing Code Scan Report → ### Findings → ### Summary → ### BACKLOG ITEMS`

## Acceptance Criteria

### Mode and structure

1. SKILL.md has exactly 2 execution modes: `full` (default) and `batch <file>`. No references to `quick`, `standard`, or `auto` modes remain in the skill text.
2. Mode Comparison table, QUICK Mode section, STANDARD Mode section, and Mode Resolution section are deleted.
3. SKILL.md line count is ≤680 (from 812).
4. Full mode has exactly 1 approval gate after Phase 1 (type + plan display). No other approval gates exist.
5. Batch mode has 0 approval gates.
6. Phase numbering uses a single system (Phase 0-4). Current Phase 5 is renamed to Phase 4. ETAP names appear as descriptive labels within phases only.
7. Backup branch is created in full mode (retained from original design).

### Contradiction resolution

8. C1 resolved: The "proceed immediately. No approval gate" text (current lines 416-418) is replaced with the Approval Gate specification from D2.
9. C2 resolved: All STANDARD mode references are removed (mode eliminated per D1).
10. C3 resolved: Batch per-file pipeline dispatches Dependency Mapper + Existing Code Scanner in step 1 (before planning), not step 4.
11. C4 resolved: Phase 3 (Execution) has explicit failure handling table for tsc, test, lint, adversarial, and total failure scenarios. Backup branch is referenced as the last-resort recovery.

### Failure handling and edge cases

12. Phase 3 failure recovery table covers: tsc fail (fix+retry 3x), test fail (revert to last passing), lint fail (auto-fix), adversarial CRITICAL (fix + re-run 2x), total failure (restore backup branch).
13. GOD_CLASS in batch mode is documented as a multi-commit exception overriding the one-commit-per-file rule.
14. GOD_CLASS partial failure in batch mode: completed extractions are kept, contract marked PARTIAL, queue entry marked `[!] PARTIAL` with details of completed vs remaining extractions.
15. `continue` on a contract with eliminated mode name (`quick`/`standard`/`auto`) silently upgrades to `full` and logs the migration.

### Adversarial review

16. Adversarial review block includes `--mode` risk override: `--mode security` when diff touches auth, payment, crypto, PII, or migration files.
17. Adversarial review block includes meta-review check: if findings==0 AND diff>150 lines → false-negative warning.

### Flags

18. `no-commit`: identical to full mode except shows `git diff --staged` + proposed message instead of committing. Contract stage set to `EXECUTION_COMPLETE` (not `COMPLETE`).
19. `plan-only`: stops after the approval gate. Does not enter Phase 2 (test handling) or Phase 3 (execution).
20. `continue`: resumes from contract state file. Mode field is always `full` (old mode values migrated per AC15).

### Agent prompts — all agents

21. All 3 agent files produce output conforming to agent preamble structure (`## Report → ### Findings → ### Summary → ### BACKLOG ITEMS`).
22. All 3 agent files have execution profile header with token budget: `> Execution profile: read-only analysis | Token budget: 3000 tokens (per-call limit for CodeSift)`.
23. All 3 agent files have error handling: empty input → STOP; file unreadable → report and skip; degraded mode → notice at top.
24. dependency-mapper and existing-code-scanner define SCOPE placeholder: `SCOPE = directory containing the target file + "/**"`.

### Agent prompts — cq-auditor

25. cq-auditor has CodeSift dual-path workflow (when available / not available) with specific tool calls.
26. cq-auditor output includes machine-parseable `VERDICT: PASS | CONDITIONAL PASS | FAIL` line with `FIX-NOW: N | DEFER: N` counts.
27. cq-auditor has "What You Must NOT Do" section with ≥7 explicit prohibitions.
28. cq-auditor mandatory file loading uses consistent `../../../rules/` path notation with `[READ | MISSING → STOP]`.
29. cq-auditor receives `review_diff` output as `machine_checks` input from the orchestrator.
30. Batch post-audit step explicitly states: "The **orchestrator** applies FIX-NOW items (auditor is read-only)."

### Agent prompts — dependency-mapper

31. dependency-mapper output examples include line numbers in DIRECT IMPORTERS section.
32. dependency-mapper uses `codebase_retrieval` batch query instead of sequential tool calls (when CodeSift available).

### Agent prompts — existing-code-scanner

33. existing-code-scanner uses `frequency_analysis` for AST-level deduplication (when CodeSift available).
34. existing-code-scanner documents timing dependency: if called before extraction plan is finalized, flags provisional extractions with `[PROVISIONAL]`.

### CodeSift integration

35. Phase 0 pre-scan includes `classify_roles` and `find_circular_deps` (when CodeSift available).
36. Phase 3 post-audit runs `review_diff(until="STAGED")` before CQ Auditor dispatch.
37. Phase 3 post-audit runs `impact_analysis` + `changed_symbols` + `diff_outline` for blast radius and API surface verification.
38. RENAME_MOVE type uses `rename_symbol` for cross-file rename (when CodeSift available).
39. BREAK_CIRCULAR type uses `find_circular_deps` before and after execution.
40. Post-execution cleanup includes `find_unused_imports` on all modified files.

## Out of Scope

- **Adding a 4th agent** (post-execution validator) — research suggests value but current 3-agent design is adequate with the cq-auditor rewrite. Revisit after measuring rewritten agent quality.
- **CQ delta display** (showing only changed gates instead of all 28) — good UX improvement but separate from structural overhaul. Track in backlog.
- **Batch `--preview` flag** (queue-wide risk table before execution) — valuable but additive. Can be added after the core restructure.
- **ETAP-1B dependency-breaking micro-step** for tightly coupled code — niche case, not blocking.
- **Contract `started_at` timestamp** in multi-contract disambiguation — minor UX improvement, separate PR.
- **`--mode migrate` for adversarial review** — additive feature for database schema/migration diffs. Not tied to any existing bug. Add after core restructure if needed.

## Open Questions

None — all questions resolved during design dialogue.
