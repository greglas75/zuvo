---
name: refactor
description: >
  Structured refactoring runner with ETAP workflow, resumable CONTRACT, and
  batch processing. Use when restructuring code, extracting methods, splitting
  files, breaking circular dependencies, or cleaning up god classes. NOT for
  new features (use zuvo:build). Execution modes: full (default), batch <file>
  (queue processing). Control flags: plan-only, no-commit, continue.
---

# zuvo:refactor

A senior architect executing a structured refactoring workflow. Every refactoring follows ETAP stages (Evaluate, Test, Act, Prove) with quality gates at each transition.

## Mandatory File Loading

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
```

This is the ONLY file loaded before reading the refactor target.

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
"continue"                 -> RESUME: scan .zuvo/contracts/refactor-*.json, resume active contract
"continue <path>"          -> RESUME: user passes readable file path (e.g., src/services/order.service.ts), skill computes hash internally to find .zuvo/contracts/refactor-{hash}.json
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

Before displaying the plan, run CQ1-CQ28 on the target file. Print ALL 28 gates:

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

Create a resumable state file per target. The path is scoped so batch mode can track multiple targets without overwriting:

| Mode | Contract path |
|------|---------------|
| Single-file (full) | `.zuvo/contracts/refactor-{target-hash}.json` |
| Batch | `.zuvo/contracts/refactor-{target-hash}.json` (one per queue entry) |

Where `{target-hash}` is the first 8 chars of SHA-1 of the relative target path (e.g., `sha1("src/services/order.service.ts")[:8]`).

**Resume contract:**
- `continue <path>`: compute hash from relative path, load `.zuvo/contracts/refactor-{hash}.json`.
- `continue` (no argument): scan `.zuvo/contracts/refactor-*.json` for `stage != "COMPLETE"`. 0 active: stop. 1 active: resume. 2+: list candidates, ask user to pick (do NOT auto-pick "most recent").

```json
{
  "version": 3,
  "file": "src/services/order.service.ts",
  "type": "EXTRACT_METHODS",
  "mode": "full",
  "stage": "PHASE-1",
  "queue_file": null,
  "queue_entry": null,
  "cq_before": { "score": "11/18", "critical_failures": ["CQ4", "CQ5"] },
  "scope_fence": ["src/services/order.service.ts", "src/services/order-helpers.ts"],
  "backup_branch": "backup/refactor-order-service-2026-03-27",
  "plan": {},
  "test_mode": "",
  "progress": []
}
```

**Contract migration (v2 → v3):** When `continue` loads a legacy contract:
- Mode migration: `quick`/`standard`/`auto` → `full` (silently, with log)
- Stage migration: `ETAP-1A` → `PHASE-1`, `ETAP-1B` → `PHASE-2`, `ETAP-2` → `PHASE-3`, `COMPLETE` → `COMPLETE`
- Version: bump to 3

In batch mode, `queue_file` and `queue_entry` are set so resume can map back to the queue:

```json
{
  "queue_file": "refactor-queue.md",
  "queue_entry": 3
}
```

Update this file after each phase completes. If the session is interrupted, `zuvo:refactor continue` picks up from the last recorded stage.

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
   -----------------------------------------------
   ```

   Steps:
   a. Search for test file: co-located `.test.*` / `.spec.*`, `__tests__/` directory, grep for imports of target
   b. If test file found: read it, run quick Q-audit on 3 critical gates only (Q7=error-path coverage, Q11=branch coverage, Q13=imports actual production function). This is a partial triage, not a full Q1-Q19 audit.
   c. Record `test_audit_before` in contract state: `{ "test_file": "...", "q7": 0|1, "q11": 0|1, "q13": 0|1 }`
   d. If no test file found: record `{ "test_file": null }`

6. **Test mode routing** -- Route based on test discovery results. Evaluate top-to-bottom, first match wins:

| Priority | Condition | Test mode |
|----------|-----------|-----------|
| 1 | Target is a type file (`.d.ts`, `.types.ts`) or config (`.config.*`, `.*rc`) | VERIFY_COMPILATION |
| 2 | No test file found (test_file = null) | WRITE_NEW |
| 3 | Test found AND Q7=1 AND Q11=1 AND Q13=1 | RUN_EXISTING |
| 4 | Test found AND (Q7=0 OR Q11=0 OR Q13=0) | IMPROVE_TESTS |

Note: priority 1 (VERIFY_COMPILATION) is checked **before** test discovery runs. If the target is a type/config file, skip test discovery entirely.

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
Test mode: [RUN_EXISTING / WRITE_NEW / IMPROVE_TESTS / VERIFY_COMPILATION]
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
Phase 2: test-quality-rules.md -- READ (WRITE_NEW or IMPROVE_TESTS only)
```

### Test Mode Execution

**RUN_EXISTING:** Run the existing test suite. Verify all tests pass. This establishes the behavioral baseline. If any test fails, investigate before proceeding -- the refactoring must not start from a broken state.

**WRITE_NEW:** Write tests for the target file before refactoring. The tests capture the current behavior so that the refactoring can be verified against them. Apply Q1-Q19 self-eval on the new tests.

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

1. One extraction at a time. Verify tests pass after each extraction before starting the next.
2. Update all imports affected by each extraction (use the Dependency Mapper results).
3. Maintain behavioral equivalence -- the refactored code must produce identical outputs for identical inputs.
4. Follow CQ patterns from `cq-patterns.md` in all new code.
5. Respect file size limits throughout. If an extraction creates a file that exceeds the limit, split further.

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
2. Run CQ1-CQ28 self-eval on EACH file
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

Run CQ1-CQ28 on every modified and created file. Print ALL 28 gates per file:

```
CQ POST-AUDIT: order.service.ts (132L)
CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=1
CQ11=1 CQ12=1 CQ13=1 CQ14=1 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=1
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=1 CQ25=1 CQ26=N/A CQ27=1 CQ28=N/A
Score: 24/24 applicable -> PASS
```

Post-audit score must not be lower than pre-audit. Any regression is a bug in the refactoring.

### Verification

Run the full verification suite:

1. Type checking (tsc, mypy, or equivalent)
2. Full test suite
3. Lint (if configured)
4. CQ self-eval on all modified files
5. Q1-Q19 on all modified test files

### Independent CQ Auditor (FULL mode, default tier, read-only)

After the lead's post-audit, dispatch an independent CQ Auditor agent. Run CQ1-CQ28 independently on ALL modified/created files. Does NOT trust the lead's scores. Catches N/A abuse and rubber-stamped gates.

**Input:** Full source of each file, CQ checklist, CQ patterns, tech stack, `machine_checks` from CodeSift (if available).

The **orchestrator** applies FIX-NOW items before committing. DEFER items go to the backlog.

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

**Per-pass fix policy:**

| Finding | Action |
|---------|--------|
| **CRITICAL** | Fix immediately. Re-run tests. |
| **WARNING (< 10 lines)** | Fix immediately. |
| **WARNING (> 10 lines)** | Add to backlog with file:line. |
| **INFO** | Known concerns (max 3, one line each). |
| **0 findings** | Early exit — stop passes, code is clean. |

**Meta-review:** If pass 1 returns 0 findings AND diff_lines > 150: add false-negative warning — large diffs with zero findings suggest insufficient review depth. Run pass 2 regardless.

Do NOT discard findings based on confidence alone. "Pre-existing" is NOT a reason to skip — if the issue is in a file you are editing, fix it now.

---

## Phase 4: Completion

### Commit

Stage and commit the changes:

```bash
git add [specific files from scope fence]
git commit -m "refactor([scope]): [description of what changed]"
```

In no-commit mode: show `git diff --staged` and the proposed message instead.

### Update Contract State

Mark contract: `"stage": "COMPLETE"`, `"cq_after": { "score": "18/18", "critical_failures": [] }`, `"commits": ["abc1234"]`.

### CodeSift Index Update

After committing: `index_file(path=<changed-file>)` for every changed file.

### Backlog Persistence (FULL mode)

Read `../../shared/includes/backlog-protocol.md`. Persist CQ Auditor DEFER items and out-of-scope issues to `memory/backlog.md`. Fingerprint: `file|rule-id|signature`. Source: `zuvo:refactor` or `zuvo:refactor/cq-auditor`. Deduplicate per `backlog-protocol.md`.

### Knowledge Curation

Run `knowledge-curate.md`: `WORK_TYPE = "implementation"`, `CALLER = "zuvo:refactor"`, `REFERENCE = <commit SHA>`.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to output.

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Refactor type classified and printed: [RENAME/EXTRACT/SPLIT/INLINE/RESTRUCTURE]
[ ] CQ pre-audit printed on target file (all gates before changes)
[ ] Baseline test suite ran green before first change
[ ] After each change: tests ran and green (not just at the end)
[ ] CQ post-audit printed — score must not regress
[ ] Adversarial review ran on final diff
[ ] Run: line printed and appended to log
```

### Post-Completion Summary

```
REFACTORING COMPLETE
------------------------------------
Type: [TYPE] | Target: [filename]
Files modified: [N] | Files created: [N]
CQ: [before] -> [after] | Tests: [status] | Commit: [hash]

Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
------------------------------------
```

Append the `Run:` line to log file per `run-logger.md`. VERDICT: PASS/WARN/FAIL/BLOCKED/ABORTED. CQ: post-audit score. Q: test score or `-`. TASKS: files modified+created. DURATION: phase reached (e.g., `phase-3`). NOTES: type + target (max 80 chars).

---

## Batch Mode (batch <file>)

Process a queue of files through the full pipeline autonomously. Zero interactive stops, one commit per file (exception: GOD_CLASS), failure logging in the queue file.

### Phase 0: Parse Queue and Triage

1. Read the queue file. Parse lines:
   - Blank lines and lines starting with `#`: skip (comments)
   - `- [x]`: skip (completed, resume mode)
   - `- [!]`: skip (failed, needs human decision)
   - `- [ ]`: process (pending)
   - Bare file paths: process (first run)
2. Validate each file exists. Non-existent files: mark `[!] FILE NOT FOUND`, skip.
3. For each pending file: quick CQ1-CQ28 pre-scan, detect type.
4. Compute **PriorityScore** for ordering (range 0.00-1.00):

   ```
   PriorityScore = 0.4 * complexity_rank + 0.3 * hotspot_rank + 0.3 * cq_gap
   ```

   Where:
   - `complexity_rank` = file's rank in `analyze_complexity` top-10, normalized to 0-1 (rank 1 = 1.0, not in top 10 = 0.0)
   - `hotspot_rank` = file's rank in `analyze_hotspots`, normalized to 0-1
   - `cq_gap` = `1 - (cq_score / cq_applicable)` (e.g., 11/18 = gap 0.39)

   If CodeSift pre-scan is unavailable: `PriorityScore = cq_gap` (fallback). The queue is still sorted by PriorityScore descending even when using the fallback formula.

5. Rewrite the queue file with enriched format, sorted by PriorityScore descending:

```markdown
# Refactor Batch -- YYYY-MM-DDTHH:MM:SS
# Total: N | Completed: 0 | Failed: 0 | Pending: N
# PriorityScore = 0.4*complexity + 0.3*hotspot + 0.3*cq_gap

- [ ] path/to/file.ts | EXTRACT_METHODS | CQ: 11/18 | Score: 0.61
```

6. Proceed immediately (no approval stop).

### Per-File Pipeline

For each `[ ]` entry, run the full pipeline -- not a shortcut:

**Pipeline enforcement:** "Full pipeline" means running Phase 1 planning → Phase 2 test handling → Phase 3 execution → Phase 4 completion as defined in this skill. "Read file, fix obvious things, commit" is a shortcut that violates batch mode. Every file gets: its own contract state file (`.zuvo/contracts/refactor-{target-hash}.json`), CQ BEFORE eval, fixes, CQ AFTER eval, one commit.

**Steps (ALL mandatory, in order):**

1. **Analysis:** Dispatch Dependency Mapper + Existing Code Scanner (parallel) → CQ1-CQ28 BEFORE (all 28 gates) → type detect → scope freeze → create contract
2. **Test handling:** Write/verify tests per test mode routing
3. **Execution:** Execute fixes per CONTRACT → verify (type check + tests)
4. **Post-Audit:** Dispatch CQ Auditor (read-only; the **orchestrator** applies FIX-NOW items). Print CQ1-CQ28 AFTER (all 28 gates).
5. **Adversarial:** Run iterative adversarial review (`--rotate`) on staged diff with context-enriched input (same protocol as Phase 3). Pass count by diff size.
6. **Commit:** ONE commit for this file only (exception: GOD_CLASS → multi-commit per extracted responsibility).
7. **Queue update:** Update line with CQ before/after and commit hash.
8. **Backlog:** Persist DEFER items.

### GOD_CLASS Batch Exception

GOD_CLASS files in batch mode produce multiple commits (one per extracted responsibility). This overrides the general "one commit per file" rule. GOD_CLASS requires iterative decomposition by design — forcing a single commit would require extracting all responsibilities at once, which the GOD_CLASS protocol explicitly forbids.

**Partial failure in GOD_CLASS batch:** If a GOD_CLASS extraction fails mid-sequence, keep all previously committed extractions (they are atomic and tested). Mark the contract as `PARTIAL` with a list of completed and remaining extractions. Mark the queue entry as `[!] PARTIAL` with details.

### CQ Before/After (Non-Negotiable)

Every file in the batch gets a full CQ1-CQ28 evaluation, even if the agent believes it is already fixed. No file gets `[x]` without proof.

```
- [x] path | TYPE | CQ: 12/18->17/18 | CQ3,CQ21 fixed | commit: abc1234
- [x] path | VERIFY | CQ: 18/18 PASS | no changes needed
- [!] path | PARTIAL | CQ: 10/18->14/18 | CQ8 fixed, CQ19=0 CQ21=0 remain (cross-file)
```

### Anti-Rationalization Gate

The agent MUST NOT use these escape patterns:

| Escape | Rule |
|--------|------|
| "Already fixed" | Forbidden without CQ BEFORE eval proving all gates pass. Print the scores. |
| "Audit misclassification" | Forbidden without specific counter-evidence (file:line proving the audit was wrong). |
| "Out of scope" for the target file | Forbidden. The file IS the refactoring target. "Out of scope" is valid only for fixes requiring files not in the queue. |
| Partial fix (fix easy CQ, ignore rest) | If CQ AFTER still has fixable CQ=0 gates, mark `[!] PARTIAL`, not `[x]`. |
| "N/A" without justification | Each N/A needs a one-sentence explanation. >60% N/A triggers a low-signal flag. |

`[x]` means ALL in-scope CQ gates pass. If any fixable CQ=0 remains, use `[!] PARTIAL`.

### Zero-Stop Override

Batch mode overrides ALL interactive stops:

| Standard stop | Batch behavior |
|---------------|----------------|
| Phase 1 plan approval | Skipped -- agent proceeds autonomously |
| Phase 2 test approval | Skipped |
| Questions Gate | Skipped -- agent makes best judgment, logs uncertainty |
| Post-completion prompt | Skipped -- proceed to next queue entry |
| GOD_CLASS confirmation | Skipped -- auto-proceed with iterative decomposition |

### Failure Policy

- **Never stop.** Log failure in queue file, revert current file's uncommitted changes, move to next entry.
- **Actionable descriptions:** WHY + partial progress (e.g., "BLOCKED: test fail pricing.spec.ts -- expects old return shape | CQ16 fixed, CQ17 open").
- **Revert scope:** Only current file. Previous commits preserved. Note which commits landed if partial.

### Resume

Running `zuvo:refactor batch queue.md` on a file with existing progress: `[x]` skip (completed), `[!]` skip (needs human), `[ ]` process, bare path: process (triage enriches). Session-crash safe: uncommitted files stay `[ ]`.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check -> structured questions -> TSV emit -> markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed to output.

### Batch Completion

```
BATCH COMPLETE
Total: N | Completed: X | Failed: Y | Skipped: Z
Queue: [path to queue file]
Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t-\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
```

Append `Run:` line to log per `run-logger.md`. CQ: aggregate (e.g., `avg 16/18`) or `-`. TASKS: files completed. DURATION: `batch-N`. NOTES: `batch X/N completed Y failed` (max 80 chars).

---

## GOD_CLASS Protocol

When GOD_CLASS is detected (>600L, 5+ responsibilities):

1. **Identify:** List public methods grouped by responsibility. Map internal dependencies. Extract the group with the FEWEST internal dependencies first.
2. **Decompose iteratively:** For each responsibility: create new module, delegate from original, update imports, run tests, verify equivalence, commit. Repeat until original is under size limit with single responsibility.
3. **Size gate:** After each extraction check original file, new module, and all modules (CQ self-eval via Split-File Audit Rule). Continue if any exceeds limit.

---
