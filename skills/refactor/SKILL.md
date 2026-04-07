---
name: refactor
description: >
  Structured refactoring runner with ETAP workflow, resumable CONTRACT, and
  batch processing. Use when restructuring code, extracting methods, splitting
  files, breaking circular dependencies, or cleaning up god classes. NOT for
  new features (use zuvo:build). Execution modes: full (default), auto (skip
  test approval), quick (small scope), standard (moderate, no agents), batch
  <file> (queue processing). Control flags: plan-only, no-commit, continue.
---

# zuvo:refactor

A senior architect executing a structured refactoring workflow. Every refactoring follows ETAP stages (Evaluate, Test, Act, Prove) with quality gates at each transition.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `../../shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `../../shared/includes/quality-gates.md` -- CQ1-CQ28 and Q1-Q19 condensed reference
4. `../../rules/cq-patterns.md` -- NEVER/ALWAYS code pairs
5. `../../rules/cq-checklist.md` -- Full CQ1-CQ28 evaluation criteria and evidence standards
6. `../../shared/includes/run-logger.md` -- Run logging protocol

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
  3. quality-gates.md    -- [READ | MISSING -> STOP]
  4. cq-patterns.md      -- [READ | MISSING -> STOP]
  5. cq-checklist.md     -- [READ | MISSING -> STOP]
  6. run-logger.md       -- [READ | MISSING -> STOP]
```

If any file is missing, STOP. Do not proceed from memory.

### Conditional Files (loaded at the phase that needs them)

| File | Load when | Skip when |
|------|-----------|-----------|
| `../../rules/testing.md` | Before ETAP-1B (test writing phase) | Test mode is RUN_EXISTING or VERIFY_COMPILATION |
| `../../rules/test-quality-rules.md` | Before ETAP-1B when test mode is WRITE_NEW or IMPROVE_TESTS | Test mode is RUN_EXISTING or VERIFY_COMPILATION |
| `../../rules/file-limits.md` | Phase 0 (stack detection) | If unavailable, use defaults: 300L service, 200L component |
| `../../rules/security.md` | When refactoring touches auth, input validation, or secrets | No security-sensitive code in scope |

Print status when loading each conditional file:

```
ETAP-1B: testing.md -- READ
ETAP-1B: test-quality-rules.md -- READ
```

---

## Argument Parsing

### Execution Modes (mutually exclusive)

```
$ARGUMENTS = empty         -> FULL mode (approval gates at plan + test phase)
$ARGUMENTS = "full"        -> FULL mode (explicit)
$ARGUMENTS = "auto"        -> AUTO mode (approval gate at plan only)
$ARGUMENTS = "quick"       -> QUICK mode (lightweight, no agents, no stops)
$ARGUMENTS = "standard"    -> STANDARD mode (contract state + ETAP, no agents)
$ARGUMENTS = "batch <file>"-> BATCH mode (process queue file, zero stops)
$ARGUMENTS = other         -> task description, FULL mode
```

### Control Flags (modify behavior of the selected mode)

```
"no-commit"                -> Apply to current mode: skip auto-commits (show diff + proposed message)
"plan-only"                -> Apply to current mode: ETAP-1A only, stop after plan
"continue"                 -> RESUME: scan .zuvo/contracts/refactor-*.json, resume active contract
"continue <path>"          -> RESUME: user passes readable file path (e.g., src/services/order.service.ts), skill computes hash internally to find .zuvo/contracts/refactor-{hash}.json
```

**Flag priority rules:**
- `continue` has highest priority: it overrides the execution mode (the mode is restored from the contract state file). All other flags except `no-commit` are ignored when `continue` is active. Example: `zuvo:refactor standard continue` ignores `standard` and resumes from the contract's recorded mode.
- `no-commit` and `plan-only` combine freely with any mode: `zuvo:refactor standard no-commit` runs STANDARD mode without committing.
- `plan-only` and `continue` are mutually exclusive (continue resumes past the plan phase).

### Mode Comparison

| Aspect | quick | standard | full | auto | batch |
|--------|-------|----------|------|------|-------|
| Contract state file | No | Yes | Yes | Yes | Per-file |
| Sub-agents | None | None | 2-6 | 2-6 | 2-6 |
| ETAP stages | Inline | 1A + 2 | 1A + 1B + 2 | 1A + 1B + 2 | 1A + 1B + 2 |
| CQ before/after | Quick eval | Printed | Agent-verified | Agent-verified | Agent-verified |
| Test rewrite (1B) | Skip | Verify only | Write if needed | Write if needed | Write if needed |
| Backup branch | No | No | Yes | Yes | No |
| Backlog persistence | No | No | Yes | Yes | Yes |
| Approval stops | None | Plan only | Plan + test | Plan only | None |

### QUICK Mode

For small, low-risk refactors.

**Auto-detection criteria:** File <=120L, <=1 file changed, type is one of EXTRACT_METHODS / SIMPLIFY / RENAME_MOVE / DELETE_DEAD, no GOD_CLASS or security or API or migration involvement.

**Flow:** Stack detect -> Type detect -> Inline CQ audit -> Quick Plan (inline scope + extraction list, no approval stop) -> Baseline tests -> Execute -> Verify (tsc + tests + CQ self-eval) -> Commit.

Skips: sub-agents, backup branch, contract state file, multi-phase ETAP, backlog, metrics, all approval stops.

### STANDARD Mode

For moderate refactors that need structure but not full agent overhead.

**Auto-detection criteria:** File 120-400L, 1-3 files changed, type is NOT GOD_CLASS / security / API-contract / migration.

**Flow:** Stack detect -> Type detect -> CQ pre-audit (inline) -> contract state file -> ETAP-1A plan -> APPROVAL STOP -> Baseline tests -> Execute -> CQ post-audit (inline) -> Verify -> Commit.

Includes: contract state file for resumability, CQ before/after scoring, ETAP stages. Skips: sub-agents, backup branch, backlog, ETAP-1B test rewrite.

### no-commit Mode

Identical to FULL except: after execution, show `git diff --staged` and a proposed commit message. The user controls git history.

---

## Mode Resolution (when no explicit mode given)

If the user passed an explicit mode (`full`, `quick`, `standard`, `auto`, `batch`), use it. Otherwise, resolve the mode **after** reading the target file (requires line count and type):

```
1. Read target file -> count lines, detect type (Phase 1)
2. Apply auto-detection criteria:

   QUICK if ALL:
     - lines <= 120
     - scope <= 1 file
     - type in {EXTRACT_METHODS, SIMPLIFY, RENAME_MOVE, DELETE_DEAD}
     - NOT GOD_CLASS, NOT security/API/migration involvement

   STANDARD if ALL:
     - lines 121-400
     - scope 1-3 files
     - type NOT in {GOD_CLASS, security, API-contract, migration}

   FULL otherwise (default)

3. Print resolution:
   MODE RESOLUTION: [selected_mode]
   Reason: [criteria matched] (e.g., "142L, EXTRACT_METHODS, 2 files -> STANDARD")

4. If selected_mode is QUICK: skip contract state file creation (QUICK has no contract).
   Otherwise: record selected_mode in contract state file.
```

The user can override auto-detection at the plan approval stop by saying "use full" or "use quick". Override is only possible in modes that have a plan approval stop (standard, full, auto). In quick and batch modes there is no approval stop, so no override opportunity.
This applies only to modes with a plan approval stop (standard, full, auto).

---

## Phase 0: Stack Detection and CodeSift Setup

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

Follow `codesift-setup.md`:

1. Check whether CodeSift tools are available in the current environment
2. `list_repos()` once to cache the repo identifier
3. If not indexed: `index_folder(path=<project_root>)`

### Pre-Scan (STANDARD, FULL, AUTO, BATCH modes; skipped in QUICK)

Run 4 analysis calls to understand WHAT to refactor before planning HOW:

1. `analyze_complexity(repo, top_n=10, file_pattern=SCOPE)` -- Is the target among the most complex files? Which functions are worst?
2. `analyze_hotspots(repo, since_days=90)` -- Is the target a churn hotspot? Changed often + complex = high-value refactor.
3. `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` -- Copy-paste blocks with other files? DRY extraction candidates.
4. `find_dead_code(repo, file_pattern=SCOPE)` -- Unused exports in scope. Delete BEFORE refactoring (less code to move).

Print:

```
REFACTOR PRE-SCAN
------------------------------------
Complexity: target ranks #N/10 (cyclomatic X, function: Y)
Hotspot:    changed N times in 90 days (rank in repo)
Clones:     N blocks (X% similar) with [file:lines]
Dead code:  N unused exports ([names])
------------------------------------
```

Feed pre-scan data into the extraction plan:
- Clone blocks -> extract to shared module
- Dead exports -> delete before refactoring
- Highest-complexity functions -> prioritize splitting these first
- Hotspot confirmation -> validates this refactor is high-value

If CodeSift not available: skip pre-scan. If mode is QUICK: skip pre-scan.

---

## Phase 1: Type Detection

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

Showing only failures hides false positives in the 1s. The user needs to see all 28 scores.

Display detected type and wait for confirmation (unless AUTO or BATCH mode).

---

## Phase 2: CONTRACT and Planning (ETAP-1A)

### CONTRACT State File

Create a resumable state file per target. The path is scoped so batch mode can track multiple targets without overwriting:

| Mode | Contract path |
|------|---------------|
| Single-file (full/standard/auto) | `.zuvo/contracts/refactor-{target-hash}.json` |
| Batch | `.zuvo/contracts/refactor-{target-hash}.json` (one per queue entry) |

Where `{target-hash}` is the first 8 chars of SHA-1 of the relative target path (e.g., `sha1("src/services/order.service.ts")[:8]`).

**Resume contract:**

- `continue <path>`: the user passes the readable target file path (e.g., `zuvo:refactor continue src/services/order.service.ts`). The skill computes the hash internally from the relative path and loads `.zuvo/contracts/refactor-{hash}.json`.
- `continue` (no argument): scan `.zuvo/contracts/refactor-*.json` for files with `stage != "COMPLETE"`.
  - **0 active:** print "No active refactoring contracts found." and stop.
  - **1 active:** resume it automatically.
  - **2+ active:** print a numbered list of candidates (file, type, stage, last modified) and ask the user to pick one. Do NOT auto-pick "most recent".

```json
{
  "version": 2,
  "file": "src/services/order.service.ts",
  "type": "EXTRACT_METHODS",
  "mode": "full",
  "stage": "ETAP-1A",
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

In batch mode, `queue_file` and `queue_entry` are set so resume can map back to the queue:

```json
{
  "queue_file": "refactor-queue.md",
  "queue_entry": 3
}
```

Update this file after each ETAP stage completes. If the session is interrupted, `zuvo:refactor continue` picks up from the last recorded stage.

### Sub-Agent Dispatch (FULL and AUTO modes)

Refer to `env-compat.md` for the correct dispatch pattern per environment.

The orchestrator passes the following to each agent: **target file**, **CODESIFT_AVAILABLE** flag, and **repo identifier** (from the orchestrator's own `list_repos()` call in Phase 0). Agents must NOT call `list_repos()` themselves — the orchestrator owns that call.

Dispatch two agents in parallel (background) to inform the plan:

#### Agent 1: Dependency Mapper

**Execution profile:** default analysis tier

**Type:** Explore (read-only)

**Task:** Trace all importers and callers of the target file. Build a dependency map showing:
- Direct importers (files that import from the target)
- Transitive dependents (one level up)
- Exported symbols and where each is consumed
- Risk assessment: which dependents will break if the refactoring changes exports

**CodeSift (if available):** Use `find_references(repo, symbol_name)` for each exported symbol and `trace_call_chain(repo, symbol_name, direction="callers", depth=2)` for critical functions.

**Fallback:** `grep -r 'import.*[module]'` and `grep -r 'from.*[module]'` to find importers.

#### Agent 2: Existing Code Scanner

**Execution profile:** lightweight analysis tier

**Type:** Explore (read-only)

**Task:** Search the codebase for existing helpers, utilities, or patterns similar to what the refactoring plans to extract. Prevents creating duplicates.

**CodeSift (if available):** Use `find_clones(repo, min_similarity=0.7, file_pattern=SCOPE)` and `search_symbols(repo, query, detail_level="compact")`.

**Fallback:** Grep for function names and patterns matching the planned extraction targets.

### ETAP-1A Plan

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

If there is genuine uncertainty after planning, present questions to the user (max 4). Update the CONTRACT with answers, then HARD STOP for plan approval.

In AUTO and BATCH mode: skip questions, proceed with the safest default.

### Plan Display

Display the plan, then proceed immediately. No approval gate — the user invoked the skill to get the work done.

---

## Phase 3: Test Handling (ETAP-1B)

Skip for QUICK mode and VERIFY_COMPILATION test mode.

### Load Conditional Files

```
ETAP-1B: testing.md -- READ
ETAP-1B: test-quality-rules.md -- READ (WRITE_NEW or IMPROVE_TESTS only)
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

## Phase 4: Execution (ETAP-2)

### Backup Branch (FULL and AUTO modes)

Create a backup branch before making changes:

```bash
git checkout -b backup/refactor-[target]-[date]
git checkout -  # return to original branch
```

### Execute Refactoring

Apply the planned changes according to the extraction list, following these rules:

1. One extraction at a time. Verify tests pass after each extraction before starting the next.
2. Update all imports affected by each extraction (use the Dependency Mapper results).
3. Maintain behavioral equivalence -- the refactored code must produce identical outputs for identical inputs.
4. Follow CQ patterns from `cq-patterns.md` in all new code.
5. Respect file size limits throughout. If an extraction creates a file that exceeds the limit, split further.

### Split-File Audit Rule

**After any refactoring that creates new files (SPLIT_FILE, EXTRACT_METHODS with new module, SIMPLIFY with delegation):**

Run CQ self-eval on EACH extracted module, not just the orchestrator. The bugs move with the code.

"Split file into 4 modules" means audit 4 modules. The orchestrator is clean by construction (it just delegates). The CQ failures (CQ5 PII in logs, CQ8 missing try/catch, CQ9 no transaction, CQ17 N+1, CQ19 no validation) live in the modules where the actual logic resides.

**Procedure:**
1. List ALL files created or modified during the refactoring
2. Run CQ1-CQ28 self-eval on EACH file
3. Any CQ critical gate failure (CQ3/4/5/6/8/14 = 0) in ANY module blocks the commit

### CQ Post-Audit

After execution completes, run CQ1-CQ28 on every modified and created file. Print ALL 28 gates for each file:

```
CQ POST-AUDIT: order.service.ts (132L)
CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=1 CQ9=1 CQ10=1
CQ11=1 CQ12=1 CQ13=1 CQ14=1 CQ15=1 CQ16=N/A CQ17=1 CQ18=N/A CQ19=1
CQ20=N/A CQ21=1 CQ22=N/A CQ23=1 CQ24=1 CQ25=1 CQ26=N/A CQ27=1 CQ28=N/A
Score: 24/24 applicable -> PASS

CQ POST-AUDIT: order-helpers.ts (85L)
CQ1=1 CQ2=1 CQ3=N/A CQ4=N/A CQ5=1 ...
```

Compare before and after scores. The post-audit score must not be lower than the pre-audit score. Any regression is a bug in the refactoring.

### Verification

Run the full verification suite:

1. Type checking (tsc, mypy, or equivalent)
2. Full test suite
3. Lint (if configured)
4. CQ self-eval on all modified files
5. Q1-Q19 on all modified test files

### Independent CQ Auditor (FULL and AUTO modes)

After the lead's post-audit, dispatch an independent CQ Auditor agent to verify the results.

**Execution profile:** default analysis tier

**Type:** Explore (read-only)

**Task:** Run CQ1-CQ28 independently on ALL files created or modified during the refactoring. Does NOT trust the lead's scores. Catches N/A abuse and rubber-stamped gates. Returns findings that must be addressed before committing.

**Input:** Full source of each file, CQ checklist reference, CQ patterns reference, tech stack.

Apply any FIX-NOW items from the auditor before committing. DEFER items go to the backlog.

### Adversarial Review (MANDATORY — do NOT skip)

```bash
git add -u && git diff --staged | adversarial-review --json --mode code
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Handle findings by severity:
- **CRITICAL** — fix immediately, regardless of confidence. If confidence is low, verify first (check the code), then fix if confirmed.
- **WARNING** — fix if localized (< 10 lines). If fix is larger, add to backlog with specific file:line.
- **INFO** — known concerns (max 3, one line each).

Do NOT discard findings based on confidence alone. Confidence measures how sure the reviewer is, not how important the issue is. A CRITICAL with low confidence means "verify this — if true, it's serious."

---

## Phase 5: Completion

### Commit

Stage and commit the changes:

```bash
git add [specific files from scope fence]
git commit -m "refactor([scope]): [description of what changed]"
```

In no-commit mode: show `git diff --staged` and the proposed message instead.

### Update Contract State

Mark the contract as completed:

```json
{
  "stage": "COMPLETE",
  "cq_after": { "score": "18/18", "critical_failures": [] },
  "commits": ["abc1234"]
}
```

### CodeSift Index Update

After committing, update the CodeSift index for every changed file:

```
index_file(path="/absolute/path/to/changed-file.ts")
```

### Backlog Persistence (FULL and AUTO modes)

Read `../../shared/includes/backlog-protocol.md` before persisting.

Persist any deferred findings to `memory/backlog.md`:
- CQ Auditor DEFER items
- Issues identified but out of scope for this refactoring

**Fingerprint contract:** `file|rule-id|signature` (e.g., `order.service.ts|CQ8|no-try-catch`). Source: `zuvo:refactor` or `zuvo:refactor/cq-auditor` for agent findings. Deduplicate by exact fingerprint match per `backlog-protocol.md`.

### Post-Completion Summary

```
REFACTORING COMPLETE
------------------------------------
Type: [EXTRACT_METHODS / SPLIT_FILE / ...]
Target: [filename]
Files modified: [N]
Files created: [N]

CQ: [before score] -> [after score]
Tests: [status]
Commit: [hash] -- [message]

Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS / WARN / FAIL / BLOCKED / ABORTED only.
CQ: CQ post-audit score (e.g., `18/18`).
Q: Q score from test evaluation (or `-` if VERIFY_COMPILATION).
TASKS: number of files modified + created.
DURATION: ETAP stage reached (e.g., `etap-2`).
NOTES: refactoring type + target file (max 80 chars).
------------------------------------
```

---

## Batch Mode (batch <file>)

Process a queue of files through the full ETAP pipeline autonomously. Zero interactive stops, one commit per file, failure logging in the queue file.

### Phase 0: Parse Queue and Triage

1. Read the queue file. Parse lines:
   - Blank lines and lines starting with `#`: skip (comments)
   - `- [x]`: skip (completed, resume mode)
   - `- [!]`: skip (failed, needs human decision)
   - `- [ ]`: process (pending)
   - Bare file paths: process (first run)
2. Validate each file exists. Non-existent files: mark `[!] FILE NOT FOUND`, skip.
3. For each pending file: quick CQ1-CQ28 pre-scan, detect type.
4. Compute **PriorityScore** for ordering (range 0.00–1.00):

   ```
   PriorityScore = 0.4 * complexity_rank + 0.3 * hotspot_rank + 0.3 * cq_gap
   ```

   Where:
   - `complexity_rank` = file's rank in `analyze_complexity` top-10, normalized to 0–1 (rank 1 = 1.0, not in top 10 = 0.0)
   - `hotspot_rank` = file's rank in `analyze_hotspots`, normalized to 0–1
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

For each `[ ]` entry, run the LITERAL ETAP pipeline -- not a shortcut:

**Pipeline enforcement:** "Full pipeline" means running ETAP-1A -> 1B -> 2 -> Phase 4-5 as defined in this skill. "Read file, fix obvious things, commit" is a shortcut that violates batch mode. Every file gets: its own contract state file (`.zuvo/contracts/refactor-{target-hash}.json`), CQ BEFORE eval, fixes, CQ AFTER eval, sub-agents (in FULL modes), one commit.

**Steps (ALL mandatory, in order):**

1. **ETAP-1A:** Read file -> CQ1-CQ28 BEFORE (print ALL 28 gates) -> type detect -> scope freeze -> create contract state file
2. **ETAP-1B:** Write/verify tests per test mode routing
3. **ETAP-2:** Execute fixes per CONTRACT -> verify (type check + tests)
4. **Post-Audit:** Run sub-agents (Dependency Mapper, Existing Code Scanner, CQ Auditor). Apply FIX-NOW items from CQ Auditor. Print CQ1-CQ28 AFTER (all 28 gates).
5. **Commit:** ONE commit for this file only. `git add` only files within this file's scope fence.
6. **Queue update:** Update the line with CQ before/after scores and commit hash.
7. **Backlog:** Persist any DEFER items.

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
| ETAP-1A plan approval | Skipped -- agent proceeds autonomously |
| ETAP-1B test approval | Skipped |
| Questions Gate | Skipped -- agent makes best judgment, logs uncertainty |
| Post-completion prompt | Skipped -- proceed to next queue entry |
| GOD_CLASS confirmation | Skipped -- auto-proceed with iterative decomposition |

### Failure Policy

- **Never stop.** Log the failure in the queue file, revert uncommitted changes for the current file, move to the next entry.
- **Actionable descriptions:** Not "failed" but WHY and what partial progress was made (e.g., "BLOCKED: test fail pricing.spec.ts -- expects old return shape after Decimal removal | CQ16 fixed, CQ17 open").
- **Revert scope:** Only revert the current file's uncommitted changes. Previous file commits are preserved.
- **Partial progress:** If some phases committed before failure, note which commits landed.

### Resume

Running `zuvo:refactor batch queue.md` on a file with existing progress:

| Marker | Action |
|--------|--------|
| `[x]` | Skip (completed) |
| `[!]` | Skip (needs human decision) |
| `[ ]` | Process |
| Bare path | Process (triage will enrich) |

Session-crash safe: uncommitted files stay `[ ]`, resume picks them up.

### Batch Completion

```
BATCH COMPLETE
Total: N | Completed: X | Failed: Y | Skipped: Z
Queue: [path to queue file]

Run: <ISO-8601-Z>\trefactor\t<project>\t<CQ>\t-\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS / WARN / FAIL / BLOCKED / ABORTED only.
CQ: aggregate CQ score across batch (e.g., `avg 16/18`), or `-` if mixed.
TASKS: number of files completed in batch.
DURATION: `batch-N` where N is total queue entries.
NOTES: `batch X/N completed Y failed` (max 80 chars).
```

---

## GOD_CLASS Protocol

When GOD_CLASS is detected (>600L, 5+ responsibilities):

### Identification

1. List all public methods grouped by responsibility (e.g., "order creation", "pricing", "notification", "validation")
2. Map internal dependencies between responsibility groups
3. Determine extraction order: extract the group with the FEWEST internal dependencies first

### Iterative Decomposition

Do NOT extract all responsibilities at once. For each responsibility group:

1. Create the new module file with the extracted methods
2. Update the original file to delegate to the new module
3. Update all imports in dependent files
4. Run the full test suite
5. Verify behavioral equivalence
6. Commit this single extraction

Repeat until the original file is under the size limit and has a single clear responsibility.

### Size Gate

After each extraction, check:
- Original file: is it under the limit? If not, continue extracting.
- New module: is it under the limit? If not, it may need further splitting.
- All modules: run CQ self-eval on each (Split-File Audit Rule).

---

## IMPROVE_TESTS Workflow

When the target is a test file:

1. **ETAP-1A:** Run Q1-Q19 self-eval to identify gaps. Classify each gap. Record the BEFORE score in the contract state file.
2. **ETAP-1B:** Structural cleanup (test organization, describe blocks, mock setup). Commit.
3. **ETAP-2:** Assertion strengthening (exact values, error path tests, branch coverage). Re-score Q1-Q19. Commit.
4. **Gate:** Score must improve by at least 2 points, or reach 16+/19.

---

## Environment Adaptation

Refer to `env-compat.md` for dispatch patterns:

- **Claude Code:** Use the Task tool for parallel agent dispatch. Set model and type per agent.
- **Codex:** Agents are TOML configs. Skills reference agents by name.
- **Cursor:** No agent spawning. Execute each agent's analysis sequentially yourself, maintaining the same output format and quality standards.

Progress tracking:
- **Claude Code:** Use TaskCreate/TaskUpdate for structured progress.
- **Codex / Cursor:** Print inline: `STEP: ETAP-1A [START]` ... `STEP: ETAP-1A [DONE]`

User interaction:
- **Interactive environments:** Ask the user at approval gates.
- **Non-interactive environments:** At approval stops, proceed with the safest default and document the choice.
