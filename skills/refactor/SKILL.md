---
name: refactor
description: >
  Structured refactoring runner with ETAP workflow, resumable CONTRACT, and
  batch processing. Use when restructuring code, extracting methods, splitting
  files, breaking circular dependencies, or cleaning up god classes. NOT for
  new features (use zuvo:build). Execution modes: full (default), batch <file>
  (queue processing). Control flags: plan-only, no-commit, continue.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols
    - get_symbol
    - get_symbols
    - get_file_outline
    - find_references          # KEY — impact analysis before changing signatures
    - trace_call_chain         # downstream effect of refactor
    - rename_symbol            # KEY — cross-file rename without manual Edit
    - find_dead_code           # remove what becomes unused after refactor
    - find_unused_imports      # post-refactor cleanup
    - find_clones              # extract-method opportunities
    - find_circular_deps       # break cycles is a common refactor goal
    - search_text
  by_stack:
    typescript: [get_type_info, resolve_constant_value]
    javascript: []
    python: [python_audit, analyze_async_correctness, resolve_constant_value]
    php: [php_project_audit, php_security_scan, resolve_php_namespace]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_middleware, astro_svg_components]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders, analyze_context_graph, trace_component_tree]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service, trace_php_event, find_php_views]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:refactor

A senior architect executing a structured refactoring workflow. Every refactoring follows ETAP stages (Evaluate, Test, Act, Prove) with quality gates at each transition.

## Definition of Done (non-negotiable — read before you start)

A refactor is **BLOCKED until proven**, and the proof is the **CONTRACT**, not your say-so. The
canonical order is **Prove → record in CONTRACT → Gate → Commit (LAST)**. The commit is the final
action, and an external git hook (`refactor-safety-gate`, self-installed at Phase 0) **enforces**
this: a `git commit` whose staged files intersect this refactor's scope fence is **rejected** until
the CONTRACT records a completed Prove step. There is **no condensed / light / "5-step" path** that
skips this — git hooks fire on every harness, so it cannot be narrated past.

The four **SAFETY** gates — never skippable, never reducible by "user scope", never "looks small so I skipped it":
1. **Characterization coverage** of every moved unit, green on the PRE-refactor code (before touching it).
2. **Independent CQ Auditor** (blind audit) → record `prove.blind_audit ∉ {skipped,not_run}`.
3. **Adversarial review** on the final diff → record `prove.adversarial ∉ {skipped,not_run}`.
4. **Remediation**: in-fence bugs the audit/adversarial surface are FIXED in this run (staged before
   the gated commit), NOT backlogged. Only out-of-fence / user-declined items defer (each documented).

**TELEMETRY** (CONTRACT, retro, run-log) is cheap — always do it. **BUILD SCOPE** (targeted vs full
`turbo build`) the user MAY narrow, but only by DECLARING it. Skipping a SAFETY gate, or running it
and parking its findings, = the run is `BLOCKED(unsafe)`. Full stop. Everything below is HOW; this is WHAT.

## Mandatory File Loading

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
  2. ../../shared/includes/no-pause-protocol.md   -- [READ | MISSING -> WARN] (HARD: no mid-batch pauses)
```

These files are loaded before reading the refactor target.

### PHASE 0 — Commit-gate self-install (run this bash; ungated, fail-open)

Export the AI-run marker and ensure the external refactor commit-gate is active for this repo. The
gate is the bind that makes the Definition of Done real — an agent cannot skip a git hook. It no-ops
when the repo has no active refactor CONTRACT, fail-opens if anything is missing (never blocks setup).

```bash
export ZUVO_AI_RUN=1
_GATE=$(ls "$HOME"/.claude/hooks/refactor-safety-gate.sh \
        "$HOME"/.claude/plugins/cache/zuvo-marketplace/zuvo/*/hooks/refactor-safety-gate.sh 2>/dev/null | head -1)
_INST=$(ls "$HOME"/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/install-refactor-gate.sh \
        "$HOME"/.claude/hooks/install-refactor-gate.sh 2>/dev/null | head -1)
if [ -n "$_GATE" ] && [ -n "$_INST" ]; then
  sh "$_INST" "$_GATE" "$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
else
  echo "[refactor-gate] gate/install script not found — in-skill self-check still applies"
fi
```

### PHASE 0.5 — Classify (read target, determine refactor type)

After CodeSift setup, read the target file(s). Determine refactor type:
- **RENAME:** symbol rename, file move
- **EXTRACT:** extract function/class/module
- **SPLIT:** split large file into smaller modules
- **INLINE:** consolidate/inline scattered logic
- **RESTRUCTURE:** architectural change (module boundaries, dependency direction)

Print: `[CLASSIFIED] Refactor type: {RENAME|EXTRACT|SPLIT|INLINE|RESTRUCTURE}`

### PHASE 1 — Conditional Load (based on refactor type)

| Include | RENAME | EXTRACT/SPLIT | INLINE | RESTRUCTURE |
|---------|--------|---------------|--------|-------------|
| `../../shared/includes/env-compat.md` | Full | Full | Full | Full |
| `../../shared/includes/quality-gates.md` | **SKIP** | CQ section only | CQ section only | Full |
| `../../rules/cq-patterns.md` | **SKIP** | **SKIP** | Full | Full |
| `../../rules/cq-checklist.md` | **SKIP** | **SKIP** | **SKIP** | Full |
| `../../rules/file-limits.md` | **SKIP** | Full | **SKIP** | Full |
| `../../rules/testing.md` | If tests affected | If tests affected | If tests affected | Full |
| `../../rules/test-quality-rules.md` | **SKIP** | If tests affected | **SKIP** | If tests affected |
| `../../rules/security.md` | **SKIP** | **SKIP** | **SKIP** | If security-sensitive |

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file]
```

### DEFERRED — Load at completion

```
  ../../shared/includes/run-logger.md        -- [READ at final step]
  ../../shared/includes/retrospective.md     -- [READ at final step]
  ../../shared/includes/documentation-mandate.md -- [READ at final step]
  ../../shared/includes/knowledge-prime.md   -- [READ at start if available | MISSING -> degraded]
  ../../shared/includes/knowledge-curate.md  -- [READ at final step if available | MISSING -> degraded]
```

If any PHASE 0 file missing, STOP. The plugin installation is incomplete.

---

## Argument Parsing

### Execution Modes (mutually exclusive)

```
$ARGUMENTS = empty         -> FULL mode (default)
$ARGUMENTS = "full"        -> FULL mode (explicit)
$ARGUMENTS = "batch <file>"-> BATCH mode (process queue file, zero stops)
$ARGUMENTS = other         -> task description, FULL mode
```

### Control Flags

```
"no-commit"                -> Skip auto-commits (show diff + proposed message instead)
"plan-only"                -> Stop after the approval gate (Phase 1). Do not enter Phase 2 or Phase 3.
"continue"                 -> RESUME: scan zuvo/contracts/refactor-*.json, resume active contract
"continue <path>"          -> RESUME: user passes readable file path (e.g., src/services/order.service.ts), skill computes hash internally to find zuvo/contracts/refactor-{hash}.json
```

**Flag priority rules:**
- `continue` has highest priority: it overrides flags (except `no-commit`). Mode is always `full` — if the contract was created with a legacy mode (`quick`/`standard`/`auto`), silently upgrade to `full` and log the migration.
- `no-commit` and `plan-only` combine freely: `zuvo:refactor no-commit` runs full mode without committing. Contract stage is set to `EXECUTION_COMPLETE` (not `COMPLETE`) so `continue` can resume from the uncommitted state.
- `plan-only` and `continue` are mutually exclusive (continue resumes past the plan phase).

---

## Phase 0: Stack Detection and CodeSift Setup

### Knowledge Prime

Run `knowledge-prime.md`: `WORK_TYPE = "implementation"`, `WORK_KEYWORDS = <target file/module names>`, `WORK_FILES = <files to refactor>`.

### Tech Stack

Detect the project's tech stack from config files:

| Signal | Stack | Rules to load |
|--------|-------|--------------|
| `tsconfig.json` | TypeScript | `../../rules/typescript.md` |
| `package.json` with `next` | Next.js | `../../rules/react-nextjs.md` |
| `package.json` with `@nestjs/core` | NestJS | `../../rules/nestjs.md` |
| `pyproject.toml` or `.py` files | Python | `../../rules/python.md` |
| `vitest.config.*` | Vitest test runner | |
| `jest.config.*` | Jest test runner | |

Print: `STACK: [language] | RUNNER: [test runner]`

### CodeSift Setup

Follow `codesift-setup.md`: check availability, `list_repos()` once (cache identifier), `index_folder(path=<root>)` if not indexed.

### Pre-Scan

Run 6 analysis calls to understand WHAT to refactor before planning HOW:

1. `analyze_complexity(repo, top_n=10, file_pattern=SCOPE)` -- Is the target among the most complex files? Which functions are worst?
2. `analyze_hotspots(repo, since_days=90)` -- Is the target a churn hotspot? Changed often + complex = high-value refactor.
3. `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` -- Copy-paste blocks with other files? DRY extraction candidates.
4. `find_dead_code(repo, file_pattern=SCOPE)` -- Unused exports in scope. Delete BEFORE refactoring (less code to move).
5. `classify_roles(repo, file_pattern=SCOPE)` -- Symbol role classification: dead/leaf/core/entry
6. `find_circular_deps(repo, file_pattern=SCOPE)` -- Cycle detection for BREAK_CIRCULAR type

Print:

```
REFACTOR PRE-SCAN
------------------------------------
Complexity: target ranks #N/10 (cyclomatic X, function: Y)
Hotspot:    changed N times in 90 days (rank in repo)
Clones:     N blocks (X% similar) with [file:lines]
Dead code:  N unused exports ([names])
Roles:      N dead symbols (delete first), N leaf (safe to move), N core (careful)
Cycles:     [N cycles detected | no cycles]
------------------------------------
```

Feed pre-scan data into the extraction plan:
- Clone blocks -> extract to shared module. Dead exports -> delete before refactoring.
- Highest-complexity functions -> prioritize splitting these first. Hotspot confirmation -> validates high-value.
- `classify_roles`: dead = delete before refactoring, leaf = safe extraction, core = careful handling, entry = do not move without re-export.

When CodeSift unavailable: skip pre-scan. Log `[DEGRADED: classify_roles/find_circular_deps unavailable]`.

---

## Phase 1: Type Detection + CQ Pre-Audit + Approval Gate

### Test File Auto-Detection

If the target is a test file (`.test.*`, `.spec.*`, `__tests__/*`), auto-set type to IMPROVE_TESTS. Skip keyword detection and use Q1-Q19 as the primary audit framework.

### Keyword-Based Detection (production files)

| Keywords in user description | Type |
|-----------------------------|------|
| extract, split, helper | EXTRACT_METHODS |
| split file, god class | SPLIT_FILE |
| circular, cycle | BREAK_CIRCULAR |
| move, relocate | MOVE |
| rename | RENAME_MOVE |
| interface, DIP, decouple | INTRODUCE_INTERFACE |
| error handling, empty catch | FIX_ERROR_HANDLING |
| dead code, unused | DELETE_DEAD |
| simplify, reduce complexity | SIMPLIFY |

Default when no keywords match: EXTRACT_METHODS.

### GOD_CLASS Auto-Escalation

After keyword detection, ALWAYS check the target file for GOD_CLASS thresholds:

- File exceeds 600 lines AND has 5+ distinct responsibilities (groups of related public methods with separate concerns)

If thresholds are met, override the detected type to GOD_CLASS and display:

```
GOD_CLASS DETECTED: [filename] ([N]L, [M] responsibilities)
Escalating to extended splitting protocol.
```

The GOD_CLASS protocol uses iterative decomposition: extract one responsibility at a time, verify tests pass after each extraction, then repeat. Do not attempt to split all responsibilities in one pass.

### CQ Pre-Audit

Before displaying the plan, run CQ1-CQ29 on the target file. Print ALL 28 gates:

```
CQ PRE-AUDIT: [filename] ([N]L)
CQ1=1 CQ2=0 CQ3=N/A CQ4=0 CQ5=0 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=0
CQ11=1 CQ12=0 CQ13=1 CQ14=0 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=0
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=0 CQ25=1 CQ26=N/A CQ27=1 CQ28=0
Score: 13/24 applicable -> FAIL
Critical gates: CQ4=0(no orgId:42) CQ5=0(PII:54,82)
Fix targets: CQ5, CQ14, CQ19, CQ10, CQ12
```

Showing only failures hides false positives in the 1s. All 28 scores must be visible.

### CONTRACT State File

The CONTRACT JSON schema (v3) and the v2->v3 migration rules live in
`../../shared/includes/refactor-reference.md` -> "CONTRACT State File". Create
`zuvo/contracts/refactor-{target-hash}.json` per that schema (`{target-hash}` = first 8 chars of
SHA-1 of the relative target path). It now includes the `prove` block the commit-gate reads.
Update it after each phase; `continue` resumes from the last recorded `stage`.

### Sub-Agent Dispatch (FULL mode)

Refer to `env-compat.md` for the correct dispatch pattern per environment.

The orchestrator passes the following to each agent: **target file**, **CODESIFT_AVAILABLE** flag, and **repo identifier** (from the orchestrator's own `list_repos()` call in Phase 0). Agents must NOT call `list_repos()` themselves — the orchestrator owns that call.

Dispatch two agents in parallel (background) to inform the plan:

```
Agent 1: Dependency Mapper
  model: "sonnet"
  type: "Explore"
  instructions: trace all importers and callers of the target file (see details below)
  input: target file, CODESIFT_AVAILABLE, repo identifier

Agent 2: Existing Code Scanner
  model: "sonnet"
  type: "Explore"
  instructions: search codebase for helpers/utilities similar to planned extractions (see details below)
  input: target file, CODESIFT_AVAILABLE, repo identifier, planned extraction list
```

#### Agent 1: Dependency Mapper (default tier, read-only)

Trace all importers and callers of the target file. Build a dependency map: direct importers, transitive dependents (one level up), exported symbols and where each is consumed, risk assessment for export changes.

**CodeSift:** `find_references(repo, symbol_name)` for each export, `trace_call_chain(repo, symbol_name, direction="callers", depth=2)` for critical functions. **Fallback:** grep for imports.

#### Agent 2: Existing Code Scanner (lightweight tier, read-only)

Search the codebase for existing helpers, utilities, or patterns similar to planned extractions. Prevents creating duplicates.

**CodeSift:** `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` and `search_symbols(repo, query, detail_level="compact")`. **Fallback:** grep for function names and patterns.

### Phase 1 Planning

Produce the refactoring plan incorporating sub-agent results (when available):

1. **Scope freeze** -- List every file that may be modified. No file outside this list may be touched during execution.
2. **Extraction list** -- For each function or block to extract: source location, destination, new signature.
3. **Dependency impact** -- From the Dependency Mapper: which files need import updates, which tests need adjustment.
4. **Existing code reuse** -- From the Existing Code Scanner: existing utilities that can replace planned extractions.
5. **Test discovery** -- Before routing, find and evaluate existing tests. **Skip this step entirely if the target is a type file or config file** (route directly to VERIFY_COMPILATION at step 6, priority 1).

   ```
   TEST DISCOVERY: [target file]
   -----------------------------------------------
   Test file:  [path or NONE]
   Found via:  [co-located .test.* / .spec.* / __tests__/* / grep import]
   Q-triage:   Q7=[0|1] Q11=[0|1] Q13=[0|1]
   Coverage:   units_total=[N] units_covered=[M] gap=[N-M]
   -----------------------------------------------
   ```

   Steps:
   a. Search for test file: co-located `.test.*` / `.spec.*`, `__tests__/` directory, grep for imports of target
   b. If test file found: read it, run quick Q-audit on 3 critical gates only (Q7=error-path coverage, Q11=branch coverage, Q13=imports actual production function). This is a partial triage, not a full Q1-Q19 audit.
   c. **Coverage of the refactoring surface (CRITICAL — separate from Q-triage).** Q-triage measures how *good* the found test is; coverage measures whether it actually *exercises the code being moved*. A test can score Q7=Q11=Q13=1 and still touch only one of many units. Compute:
      - `units_total` = the count of independent units this refactor will move/extract/relocate. For SPLIT_FILE / GOD_CLASS / EXTRACT_CLASS: every top-level component/function/class that lands in a new module. For EXTRACT_METHODS: the public methods whose internals change. Get this from the planned extractions, not a guess.
      - `units_covered` = how many of those units the existing test **actually executes at runtime** (rendered/called with real input and asserted on — not merely imported, and not landing in an empty-state/early-return branch). When unsure whether a unit is truly exercised, count it as NOT covered.
      - `coverage_gap = units_total - units_covered`, and list the uncovered unit names.
   d. Record `test_audit_before` in contract state: `{ "test_file": "...", "q7": 0|1, "q11": 0|1, "q13": 0|1, "units_total": N, "units_covered": M, "uncovered_units": [...] }`
   e. If no test file found: record `{ "test_file": null, "units_total": N, "units_covered": 0, "uncovered_units": [...] }`

6. **Test mode routing** -- Route based on test discovery results. Evaluate top-to-bottom, first match wins:

| Priority | Condition | Test mode |
|----------|-----------|-----------|
| 1 | Target is a type file (`.d.ts`, `.types.ts`) or config (`.config.*`, `.*rc`) | VERIFY_COMPILATION |
| 2 | No test file found (test_file = null) | WRITE_NEW |
| 3 | **`coverage_gap > 0`** (one or more units being moved are NOT exercised by any test) | **CHARACTERIZE_GAP** |
| 4 | Test found AND Q7=1 AND Q11=1 AND Q13=1 AND `coverage_gap = 0` | RUN_EXISTING |
| 5 | Test found AND (Q7=0 OR Q11=0 OR Q13=0) AND `coverage_gap = 0` | IMPROVE_TESTS |

Note: priority 1 (VERIFY_COMPILATION) is checked **before** test discovery runs. If the target is a type/config file, skip test discovery entirely.

**Why priority 3 outranks RUN_EXISTING (the failure this prevents):** a single test that passes Q7/Q11/Q13 can still exercise only one of N units being relocated. `RUN_EXISTING` would then go green while proving nothing about the other N−1 units — the refactor "verifies" against a test that never touches most of the moved code. Whenever `coverage_gap > 0`, you MUST write characterization tests for the uncovered units **before** touching production code. Build success, type-check, and static import resolution are NOT substitutes — they prove the code links, not that behavior is preserved. This gate is non-negotiable for SPLIT_FILE / GOD_CLASS / EXTRACT_CLASS, where moving unexercised units is the whole job.

7. **CQ gate targets** -- Which CQ failures from the pre-audit should be fixed during this refactoring.

### Questions Gate

If there is genuine uncertainty after planning, present questions to the user (max 4). Update the CONTRACT with answers, then proceed to the approval gate.

In BATCH mode: skip questions, proceed with the safest default.

### Approval Gate (full mode only; skipped in batch)

Display the plan:

```
REFACTOR PLAN: [filename] ([N]L)
Type: [EXTRACT_METHODS / SPLIT_FILE / ...]
Scope: [N] files
Extractions: [summary of planned changes]
CQ targets: [which CQ failures to fix]
Test mode: [RUN_EXISTING / CHARACTERIZE_GAP / WRITE_NEW / IMPROVE_TESTS / VERIFY_COMPILATION]
Coverage: units_total=[N] units_covered=[M] gap=[N-M]
```

Wait for user input. If the user changes the type or plan:

**Cosmetic change** (wording, extraction names, minor scope adjustments within same files):
1. The orchestrator recomputes scope, extractions, and test mode inline.
2. Sub-agents are NOT re-dispatched — their analysis remains valid.
3. Re-display the updated plan. Wait for confirmation again.

**Material change** (different type, new files added to scope, fundamentally different extraction strategy):
1. Re-dispatch Dependency Mapper and Existing Code Scanner with updated inputs.
2. Recompute plan incorporating new agent results.
3. Re-display. Wait for confirmation again.

Proceed only after explicit confirmation. In `plan-only` mode: stop here (do not proceed to Phase 2).

---

## Phase 2: Test Handling

Skip for VERIFY_COMPILATION test mode.

### Load Conditional Files

```
Phase 2: testing.md -- READ
Phase 2: test-quality-rules.md -- READ (WRITE_NEW, IMPROVE_TESTS, or CHARACTERIZE_GAP)
```

### Test Mode Execution

**RUN_EXISTING:** Run the existing test suite. Verify all tests pass. This establishes the behavioral baseline. If any test fails, investigate before proceeding -- the refactoring must not start from a broken state.

**CHARACTERIZE_GAP:** The existing test does not exercise every unit being moved (`coverage_gap > 0`). Close the gap BEFORE any production edit:
1. For **each** uncovered unit in `uncovered_units`, write a characterization (pin-down) test that executes it with a representative input and asserts on real output — mount/render the component, or call the function, with a payload that reaches actual logic (not an empty-state/early-return path). Source representative inputs from existing fixtures, sample data, or recover them from git history (e.g. `git show <sha>:<path>`) when they were deleted; never invent shapes the code never sees.
   - The bar is "fails loudly if behavior changes," not full Q1-Q19. A smoke test that mounts the unit and asserts `does not throw` + a stable output snapshot is the minimum; prefer a value assertion where the unit returns something checkable.
   - A parameterized table over the units (one case per unit) is the canonical shape for SPLIT_FILE / GOD_CLASS.
2. Run the new tests against the **pre-refactor** code and confirm they pass. This is the lock — they must be green on the OLD code, or they are not characterizing current behavior. If a unit genuinely cannot be exercised (truly dead), record it in the contract as `dead:<unit>` with evidence and exclude it from the move; do not silently skip it.
3. Apply Q1-Q19 self-eval on the new tests. Only after `coverage_gap` reaches 0 (every moved unit now exercised, or proven dead) does execution proceed.
4. Record `test_audit_after` with the closed gap. The completion checklist gates on this.

**WRITE_NEW:** Write tests for the target file before refactoring. The tests capture the current behavior so that the refactoring can be verified against them. Apply Q1-Q19 self-eval on the new tests. Same coverage bar as CHARACTERIZE_GAP: every unit being moved must be exercised, not just the file's entry point.

**IMPROVE_TESTS:** When the refactoring type is IMPROVE_TESTS (target is a test file):
1. Run Q1-Q19 self-eval on the existing tests to identify gaps
2. Classify gaps and plan improvements
3. Execute structural cleanup first, then assertion strengthening
4. Re-score -- gate: improvement of at least 2 points (or reach 16+/19)

### Test Results Display

Show the test results, then proceed to execution. No approval gate.

---

## Phase 3: Execution + Post-Audit + Adversarial Review

### Backup Branch (FULL mode)

Create a backup branch before making changes:

```bash
git checkout -b backup/refactor-[target]-[date]
git checkout -  # return to original branch
```

### Execute Refactoring

Record `PRE_REFACTOR_SHA = $(git rev-parse HEAD)` at the start of Phase 3, before any changes.

Apply the planned changes according to the extraction list, following these rules:

1. One extraction at a time. Verify tests pass after each extraction before starting the next. "Tests pass" here means a test that **actually exercises the extracted unit** — guaranteed by the Phase 2 coverage gate, which has already characterized every moved unit. If you reach an extraction whose unit has no exercising test, stop and go back to CHARACTERIZE_GAP; do not lean on build/type-check to wave it through.
2. Update all imports affected by each extraction (use the Dependency Mapper results).
3. Maintain behavioral equivalence -- the refactored code must produce identical outputs for identical inputs.
4. Follow CQ patterns from `cq-patterns.md` in all new code.
5. Respect file size limits throughout. If an extraction creates a file that exceeds the limit, split further.

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

1. List ALL files created or modified during the refactoring
2. Run CQ1-CQ29 self-eval on EACH file
3. Any CQ critical gate failure (CQ3/4/5/6/8/14 = 0) in ANY module blocks the commit

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

When CodeSift unavailable: skip machine verification. Pass empty `machine_checks` to CQ Auditor. Log `[DEGRADED: CodeSift unavailable — machine verification skipped]`.

### CQ Post-Audit

Run CQ1-CQ29 on every modified and created file. Print ALL 28 gates per file:

```
CQ POST-AUDIT: order.service.ts (132L)
CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=1
CQ11=1 CQ12=1 CQ13=1 CQ14=1 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=1
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=1 CQ25=1 CQ26=N/A CQ27=1 CQ28=N/A
Score: 24/24 applicable -> PASS
```

Post-audit score must not be lower than pre-audit. Any regression is a bug in the refactoring.

### Verification

**If running in a secondary worktree, bootstrap dependencies and scope the suite first** — see `env-compat.md` → "Secondary Worktree Bootstrap". A worktree does not inherit `node_modules`; verify the toolchain matches the main checkout, reuse the root install (never a partial package-local one), then scope type-check/tests to the **touched package(s)** (`--filter=<pkg>`). A pre-existing failure in an unrelated package is `pre-existing-out-of-scope`, not a blocker — do not burn the run rediscovering errors that were red before you started.

Run the verification suite (scoped per above when in a worktree):

1. Type checking (tsc, mypy, or equivalent)
2. Test suite — scoped to touched package(s) in a worktree; full suite in the primary checkout
3. Lint (if configured)
4. CQ self-eval on all modified files
5. Q1-Q19 on all modified test files

> ⛔ **This 5-item suite is NOT the finish line — it is a mid-pipeline checkpoint.** Reaching the end of it does NOT mean the refactor is verified, done, or committable. **There is no "condensed", "light", or "5-step" refactor path in FULL mode** — if you find yourself treating this list as the whole workflow, you are mid-pipeline, not done. The Independent CQ Auditor (blind audit, next section), the CQ1-CQ29 pre/post audit, and the Adversarial Review are part of the SAME non-optional sequence. Do **not** commit-as-done, do **not** report `COMPLETE`, and **never** defer the blind audit or adversarial review to a "user decision" / "awaiting approval" — they are HARD GATES that run automatically without asking. A refactor that stopped here is **BLOCKED, not done** (see Completion Gate Check).

### Independent CQ Auditor (FULL mode — HARD GATE, non-skippable, default tier, read-only)

After the lead's post-audit, dispatch an independent CQ Auditor agent. Run CQ1-CQ29 independently on ALL modified/created files. Does NOT trust the lead's scores. Catches N/A abuse and rubber-stamped gates.

**This is a HARD GATE, not best-effort.** The lead's own CQ post-audit is NOT a substitute — the whole point is a second, independent pass that never sees the lead's scores. In FULL mode (single and batch), the run CANNOT reach `COMPLETE`/PASS without it. Allowed telemetry values for `blind_audit` are `clean:strict` or `clean:degraded` (findings applied or deferred). **`skipped` and `not_run` are pipeline FAILURES, not neutral states** — if the auditor genuinely cannot be dispatched in this environment, mark the run `BLOCKED` and say so loudly; never claim PASS/WARN with the blind audit absent. A self-rolled lighter pass reported as "done" is forbidden — run the real independent pass or report BLOCKED.

**CodeSift availability does NOT gate the auditor.** The auditor is an LLM agent that reads the full source + CQ checklist itself; CodeSift only enriches the optional `machine_checks` input. When CodeSift is unavailable, pass empty `machine_checks` and record `blind_audit: clean:degraded` — **but still RUN it.** "CodeSift unavailable" is never a reason to skip the blind audit. (This is the exact regression seen in the field: `codesift:unavailable` was being conflated with `blind_audit:skipped`.)

**Input:** Full source of each file, CQ checklist, CQ patterns, tech stack, `machine_checks` from CodeSift (if available).

The **orchestrator** applies FIX-NOW items in Phase 3.5 (as the separate fix commit). Only items whose fix needs files OUTSIDE the scope fence, or that require a behavior/product decision the user declined, go to the backlog — deferral is a fix-SCOPE decision, never a severity or size one.

### Adversarial Review (MANDATORY — do NOT skip)

**Risk-sensitive mode selection:**
- Default: `--mode code`
- If diff touches auth, payment, crypto, PII, or migration files: `--mode security`

**Staging:** Stage ONLY files within the scope fence — not `git add -u` (which misses new files and may include unrelated changes):
```bash
git add [specific files from scope fence]
```

**Iterative review with `--rotate`:** Run adversarial passes sequentially, one random provider per pass. Each pass sees the FIXED code from previous passes — so fixes themselves get reviewed. Early exit when a pass returns 0 findings.

**Context-enriched input:** Prepend refactoring context + full source files so the provider can verify behavioral equivalence, not just diff syntax:

```bash
(echo "CONTEXT: refactor [TYPE] [TARGET] scope:[N files]";
 echo "CQ-PRE: [pre-audit score]. CQ-POST: [post-audit score]. Critical: [gates]";
 echo "SCOPE-FENCE: [file list]";
 echo "MOVED_VERBATIM: [files moved without changes]. Focus on new/changed logic. Verbatim-moved code is out of scope unless the move itself creates an issue.";
 echo "---ORIGINAL SOURCE---";
 cat [target file before refactoring];
 echo "---NEW/MODIFIED FILES---";
 cat [each new or modified file in scope fence];
 echo "---DIFF---";
 git diff --staged) | adversarial-review --rotate --mode [code|security]
```

The provider receives: (1) original file — can check nothing was lost in extraction, (2) new files in full — can evaluate as standalone modules, (3) diff — sees exact changes. This prevents false positives on moved-verbatim code while catching real issues like dropped branches, changed signatures, or broken re-exports.

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

**Pass count by diff size:**

| Diff size | Max passes | Rationale |
|-----------|-----------|-----------|
| < 50 lines | 2 | Small extraction — quick sanity check |
| 50-200 lines | 3 | Standard refactor — most issues found in 2-3 passes |
| > 200 lines or GOD_CLASS | 4 | Large split — fixes on fixes need full depth |

**Per-pass fix policy (disposition by fix-SCOPE, never by line count):**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING — real bug, one clearly-correct fix** | Fix it in Phase 3.5 (the fix commit). **Size is irrelevant** — a 40-line mechanical bug is still fix-now. Never park a bug just because the fix is large. |
| **WARNING — needs a behavior/product DECISION** (e.g. on total failure: partial result vs hard error) | Not a bug, a choice. Interactive → ask the user (Phase 3.5 decision gate, ≤1 question). Batch/`--auto`/`no-pause` → pick the safe default, log `[DECISION-DEFAULT: …]`, surface in report. |
| **WARNING — fix needs files OUTSIDE the scope fence** | Backlog with file:line — genuinely out of this contract's reach. |
| **INFO** | Known concerns (max 3, one line each). |
| **0 findings** | Early exit — stop passes, code is clean. |

The old "WARNING > 10 lines → backlog" rule is gone: line count is not a proxy for scope. A big mechanical fix is still a fix; a one-line product decision is still a decision.

**Meta-review:** If pass 1 returns 0 findings AND diff_lines > 150: add false-negative warning — large diffs with zero findings suggest insufficient review depth. Run pass 2 regardless.

Do NOT discard findings based on confidence alone. "Pre-existing" is NOT a reason to skip — if the issue is in a file you are editing, fix it now.

---

## Phase 3.5: Bug Remediation + Commit (in-process — leave the file CORRECT, not just tidier)

The point of a refactor is that the file ends up **better AND correct**, in one sitting — not tidier-but-still-buggy, forcing you back into the same code later. So real bugs surfaced by the CQ auditor and adversarial passes are fixed HERE, in this run. The behavior-preserving guarantee is kept via **stacked commits inside the one run**, not by deferring the fix: commit 1 proves the move changed nothing; commit 2 is the fix. One process for the user; clean, bisectable history underneath.

This phase OWNS all committing (Phase 4 no longer commits — it records).

**Disposition (the line is fix-SCOPE, not severity or size):**

| Finding | Disposition |
|---------|-------------|
| Real bug, one clearly-correct fix (any size) | **Fix now** (commit 2). Mechanical correctness has one answer — don't park it. |
| Real bug, fix needs files OUTSIDE the scope fence | Backlog with file:line — genuinely out of this contract's reach. |
| Behavior/product DECISION (partial vs hard error on failure; swallow vs surface a cost; etc.) | **Not a bug — a choice.** Interactive: ask the user (≤1 question), apply the chosen fix into commit 2. Batch/`--auto`/`no-pause`: pick the safe, conservative default, log `[DECISION-DEFAULT: …]`, surface in the report; backlog only if the user later declines. |

**Procedure:**

0. **Record the Prove step in the CONTRACT — BEFORE you commit (the external gate reads it).** After the blind audit + adversarial passes (Phase 3), write their outcomes into the contract's `prove`: `prove.blind_audit` = the blind-audit telemetry (`clean:strict` / `clean:degraded` / `fix:N`, never `skipped`/`not_run`); `prove.adversarial` = `clean` / `Nfindings` / `Nfindings:preserved`. The `refactor-safety-gate` hook reads these on `git commit` — if either is still `skipped`/`not_run`/empty and the staged files are in this refactor's scope fence, the commit is **rejected**. That is the bind: you literally cannot commit a refactor whose Prove step you skipped.
1. **Commit the pure refactor (always).** Stage scope-fence files → `git commit -m "refactor([scope]): [what moved]"`. This is the behavior-preserving proof: the Phase-2 characterization/existing tests, UNCHANGED, still pass. Record `REFACTOR_SHA`. (no-commit mode: show the diff + message, don't commit.)
2. **Triage** the CQ-auditor + adversarial findings into the table above.
3. **If fix-now items exist:**
   a. Apply every fix-now fix.
   b. Behavior now CHANGES, so update the characterization test that pinned the OLD (buggy) behavior to assert the NEW correct behavior, and add a regression test that is **red on `REFACTOR_SHA`, green on the fix**.
   c. Re-verify: type-check + full suite + ONE adversarial pass over the fix diff (`adversarial-review --mode code`) — must converge (no new CRITICAL).
   d. **Commit separately:** `git commit -m "fix([scope]): [bug summary]"` (`feat`/`perf` if that fits better). NEVER fold the fix into the refactor commit — that erases the move-vs-change boundary that makes commit 1 trustworthy.
   Else: print `[REMEDIATION: none — no fixable bugs surfaced]`.
4. **Decisions:** resolve per the table (ask / safe-default+log). Out-of-scope-fence items → backlog (Phase 4).

**Why two commits and not one:** a single mixed commit can't be bisected — if prod breaks you can't tell "moved the code" from "changed the logic." Two commits in one run cost you nothing and keep that boundary. (If you genuinely want one commit, that's the only thing to override here — the in-run fixing stays either way.)

---

## Phase 4: Completion

### Commits (recorded — committing happened in Phase 3.5)

Phase 3.5 has already committed: the pure refactor (`REFACTOR_SHA`), and — when fix-now bugs existed — a separate `fix(…)` commit. Record BOTH SHAs in the contract and the Post-Completion Summary. If no bugs surfaced, there is just the one refactor commit.

In no-commit mode: Phase 3.5 showed both diffs + proposed messages instead of committing; nothing to record here beyond the proposed messages.

### Update Contract State

Mark contract: `"stage": "COMPLETE"`, `"cq_after": { "score": "18/18", "critical_failures": [] }`, `"commits": ["abc1234"]`.

### CodeSift Index Update

After committing: `index_file(path=<changed-file>)` for every changed file.

### Backlog Persistence (FULL mode)

Read `../../shared/includes/backlog-protocol.md`. Persist ONLY the items Phase 3.5 deferred — fixes needing files outside the scope fence, and behavior decisions the user declined. **Mechanical bugs were already fixed in Phase 3.5; they do NOT belong in the backlog.** Persist to `memory/backlog.md`. Fingerprint: `file|rule-id|signature`. Source: `zuvo:refactor` or `zuvo:refactor/cq-auditor`. Deduplicate per `backlog-protocol.md`.

### Content-keyed review artifact (on success only)

A refactor that completed its in-skill review layer (CQ post-audit + blind audit + adversarial)
has ALREADY reviewed the production files it changed. Record that so the pipeline-entry gates
do not demand a redundant standalone review: write `memory/reviews/<base7>..<head7>-<slug>.md`
with the `range:`/`files:` header per `../../shared/includes/review-artifact.md`, listing the
production files this refactor touched (range head = the refactor/fix commit). Coverage is
content-keyed (by blob), so this only vouches for the exact reviewed content. Skip in no-commit
mode (nothing committed to vouch for).

### Aggregate Review Hand-off (single FULL mode)

A single refactor is fully reviewed by its in-skill layer (CQ post-audit + independent blind audit + adversarial). That layer is scoped to ONE contract's scope fence. When several refactors run back-to-back as separate invocations (a refactor sweep — the common real-world case), nothing reviews their **combined** blast radius: a symbol renamed in refactor A and consumed by refactor B's new module, two extractions that now duplicate each other, a re-export chain broken across several commits.

Do NOT auto-run `zuvo:review` after every single refactor — that is redundant ceremony the in-skill layer already covers. Instead, **detect a series and hand off once.** At completion:

1. Determine the session merge-base from the worktree's own repo: `repo_root=$(git rev-parse --show-toplevel); MERGE_BASE=$(git -C "$repo_root" merge-base HEAD <main-branch>)`. The `<MERGE_BASE>..HEAD` range is content-SHA-portable across worktrees, so the surfaced command diffs correctly from any checkout — a worktree/CWD reset is never a reason to drop the hand-off.
2. Scan `zuvo/contracts/refactor-*.json` for sibling contracts with `stage == "COMPLETE"` whose commits are ahead of `MERGE_BASE` on the current branch (i.e., landed this session, not yet reviewed together).
3. If 2 or more sibling refactor commits exist (including this one), surface:

```
AGGREGATE REVIEW RECOMMENDED
  N refactor commits this session not yet reviewed together: <sha7 list>
  Run: zuvo:review <MERGE_BASE>..HEAD   (cross-refactor integration check)
```

Print this in the Post-Completion Summary. If this refactor was invoked under an orchestrator running a known sweep, the orchestrator SHOULD run that single `zuvo:review` once after the LAST refactor — not after each one. (In `batch <file>` mode the series is known, so this becomes the MANDATORY aggregate review in Batch Completion, not a recommendation.)

### Knowledge Curation

Run `knowledge-curate.md`: `WORK_TYPE = "implementation"`, `CALLER = "zuvo:refactor"`, `REFERENCE = <commit SHA>`.

### Documentation (REQUIRED — no silent skip)

Follow `documentation-mandate.md`. A pure internal refactor with no behavior/API/contract
change is the COMMON case here — but it must still be DECLARED, not silently skipped:
`[DOC: N/A — internal-only refactor, no behavior/API/contract change]`. If the refactor
DID change public surface (moved a module, renamed an exported symbol, split a package,
changed an import path others use) → update the architecture/onboarding note + CHANGELOG.
Record the doc paths (or the N/A line) for the Post-Completion Summary.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to output.

## Completion Gate Check

**A refactor is BLOCKED until proven COMPLETE — and proof is an ARTIFACT, not a self-assessment.** Each gate below leaves evidence: a file, a telemetry row, a log line. "I did it" / "dependency impact = 0, so I skipped the scanner" / "I went with the condensed flow" without the artifact = it did NOT happen = verdict is `BLOCKED`. This gate runs AFTER the code change, so **if you already committed the code, that commit is provisional** — the run is not finished, and you may not present it as done, until every item below has its artifact. Skipping a HARD GATE because the change "looks small/safe" is exactly the failure this gate exists to catch: triviality is an output of the gates, not an excuse to skip them.

```
COMPLETION GATE CHECK
[ ] Refactor type classified and printed: [RENAME/EXTRACT/SPLIT/INLINE/RESTRUCTURE]
[ ] CQ pre-audit printed on target file (all gates before changes)
[ ] Coverage gate: `units_total`/`units_covered` printed; if gap > 0, characterization tests were written for EVERY uncovered moved unit and ran green on the PRE-refactor code (build/type-check/static-resolution do NOT satisfy this item)
[ ] Baseline test suite ran green before first change
[ ] After each change: tests ran and green (not just at the end)
[ ] CQ post-audit printed — score must not regress
[ ] Independent CQ Auditor (blind audit) RAN — telemetry is clean:strict or clean:degraded, NOT skipped/not_run (HARD GATE; if it could not be dispatched the verdict is BLOCKED, never PASS/WARN — CodeSift being unavailable does NOT excuse skipping it)
[ ] Adversarial review ran on final diff
[ ] Bug remediation (Phase 3.5): every fix-now bug fixed + tested IN THIS RUN as a separate fix commit; nothing parked by size; only out-of-scope-fence items or user-declined decisions deferred. If bugs were fixed, the run has 2 commits (refactor, then fix)
[ ] Aggregate review hand-off evaluated: if 2+ sibling refactor commits this session, the `zuvo:review <range>` line is surfaced (per Aggregate Review Hand-off)
[ ] Documentation updated if public surface changed, else explicit [DOC: N/A — internal-only] (per documentation-mandate.md)
[ ] Run: line printed and appended to log
```

**Do not conflate three different things** — the verifier separates them, and so must you:
- **SAFETY gates** — blind-audit (Independent CQ Auditor), adversarial review, characterization coverage. These prove the refactor did not break behavior. **Never skippable, never reducible by user scope, never "looks small so I skipped it."** Skipping one = the code is *unsafe* = `BLOCKED`. **Running a gate and then parking its findings is the same failure** — an adversarial pass that surfaces 8 bugs and backlogs them (instead of fixing the in-fence ones in Phase 3.5) is `BLOCKED(unsafe)`, not done. The gate's value is the remediation, not the ceremony of having run it.
- **BUILD SCOPE** — targeted package type-check/tests vs full `turbo build/test --force`. The user *may* legitimately narrow this ("just type-check + targeted tests"), but only if you **declare it**: `[SCOPE: user-reduced — targeted type-check+tests; full build skipped per user]`. Silent narrowing is not allowed; declared narrowing is fine.
- **TELEMETRY** — retro, run-log, CONTRACT, review artifact. These don't make the code safer, but they are the durable PROOF the gates ran and the history the skill improves from (losing them is exactly how months of retros vanished). Cheap; always do them. Missing telemetry ⇒ the run is *unrecorded* (`INCOMPLETE`), not necessarily unsafe — but it is **not done** either.

**Run this verifier verbatim and paste its output — cross-harness (plain shell, no MCP; Claude/Codex/Cursor/Antigravity):**

```bash
# REFACTOR SELF-CHECK — mirrors the external refactor-safety-gate (the real bind).
# Reads the CONTRACT prove fields — the SAME artifact the git hook reads at commit time —
# so this self-check and the hook can never disagree. Single source of truth = the CONTRACT
# (not a global ~/.zuvo log tail, not a commit range; the commit is LAST, gated by the hook).
C=$(ls -t zuvo/contracts/refactor-*.json 2>/dev/null | head -1)
if [ -z "$C" ]; then
  echo "GATE: N/A — no CONTRACT found (trivial/aborted refactor). If this WAS a real production refactor, that itself is the bug: create the CONTRACT (Phase 1) and run the pipeline."
else
  g=0
  ba=$(sed -n 's/.*"blind_audit"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  av=$(sed -n 's/.*"adversarial"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  fd=$(sed -n 's/.*"findings_disposition"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$C" | head -1)
  case "$ba" in skipped|not_run|"") echo "BLOCK(unsafe): prove.blind_audit='$ba' — run the Independent CQ Auditor and record it in $C"; g=1 ;; esac
  case "$av" in skipped|not_run|"") echo "BLOCK(unsafe): prove.adversarial='$av' — run the adversarial review and record it in $C"; g=1 ;; esac
  # findings parked? adversarial recorded N>0 findings (not ':preserved') but disposition unresolved
  case "$av" in *findings) case "$fd" in pending|unresolved|"") echo "BLOCK(unsafe): prove.adversarial='$av' but findings_disposition='$fd' — FIX the in-fence bugs in Phase 3.5 (or document each as out-of-fence/declined/false-positive/preserved). 'Moved verbatim' / 'infra was down' are NOT valid defers."; g=1 ;; esac ;; esac
  [ "$g" = 0 ] \
    && echo "GATE: PASS — CONTRACT prove complete (blind_audit=$ba adversarial=$av disposition=$fd); the refactor-safety hook will allow the commit." \
    || echo "GATE: BLOCKED(unsafe) — resolve the BLOCK lines above (RUN the gate / FIX the findings). The git hook will reject the commit until prove is complete; never relabel BLOCKED→PASS, never park a HARD GATE as 'awaiting user decision'."
fi
```

This self-check reads the CONTRACT — the SAME `prove` fields the external `refactor-safety-gate` hook reads on `git commit`. So if the self-check says `BLOCKED(unsafe)`, the hook will reject the commit too; they cannot disagree. `BLOCKED(unsafe)` → run the missing safety gate (or fix the parked findings) and record it in the CONTRACT; never relabel `BLOCKED→PASS`, never park a HARD GATE as "awaiting user decision." `GATE: N/A` is only for a genuinely trivial/aborted run with no CONTRACT — for a real production refactor, no CONTRACT is itself the bug. Only `GATE: PASS` is `COMPLETE`. (This whole gate exists because in one day five field refactors failed: three skipped the SAFETY gates and self-reported done; a fourth ran them but skipped telemetry; a fifth ran adversarial, surfaced 8 production bugs incl. 2 CRITICAL races, and **backlogged all of them** — the worst case, gate ran and verdict discarded. Prose said MANDATORY in 24 places and was ignored; the external hook is what finally makes it true.)

### Post-Completion Summary

```
REFACTORING COMPLETE
------------------------------------
Type: [TYPE] | Target: [filename]
Files modified: [N] | Files created: [N]
CQ: [before] -> [after] | Tests: [status] | Commits: refactor [sha7][ + fix [sha7] (N bugs fixed in-run)]

Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
------------------------------------
```

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion. Printing the markdown retro section without executing the bash leaves all three log files empty.

Field hints — VERDICT: PASS/WARN/FAIL/BLOCKED/ABORTED. CQ: post-audit score. Q: test score or `-`. TASKS: files modified+created. DURATION: phase reached (e.g., `phase-3`). NOTES: type + target (max 80 chars).

---

## Batch Mode (batch <file>)

The full batch-mode protocol — queue parse/triage + PriorityScore ordering, the per-file
pipeline, zero-stop overrides, the anti-rationalization gate, the mandatory aggregate review,
and batch completion — lives in `../../shared/includes/refactor-reference.md` -> "Batch Mode".
Load it when `$ARGUMENTS` begins with `batch`. The same Definition of Done + external commit-gate
apply to every file; per-file Prove is recorded in each file's CONTRACT before its commit.

## GOD_CLASS Protocol

When GOD_CLASS is detected (>600L, 5+ responsibilities):

1. **Identify:** List public methods grouped by responsibility. Map internal dependencies. Extract the group with the FEWEST internal dependencies first.
2. **Decompose iteratively:** For each responsibility: create new module, delegate from original, update imports, run tests, verify equivalence, commit. Repeat until original is under size limit with single responsibility.
3. **Size gate:** After each extraction check original file, new module, and all modules (CQ self-eval via Split-File Audit Rule). Continue if any exceeds limit.

---
