---
name: write-tests
description: >
  Write tests for existing production code. Scans coverage gaps, classifies
  code types (11 categories), selects patterns per type, and writes tests
  with Q1-Q20 quality gates. Supports single file, directory, and auto-loop
  modes. Modes: [path] (specific target), auto (discover and loop until
  done), --dry-run (preview plan without writing).
---

# zuvo:write-tests — Test Writing Workflow

Generate high-quality tests for production code that lacks coverage. Analyzes each target file, classifies its code type, selects the correct test patterns, and writes tests that pass Q1-Q20 gates.

**Scope:** Existing production files with missing or partial test coverage.
**Out of scope:** New feature tests during development (use `zuvo:build`), mass repair of the same anti-pattern across many files (use `zuvo:fix-tests`), auditing existing test quality without writing (use `zuvo:test-audit`).

**Boundary rule:** If this skill discovers quality issues in existing tests for target files (auto-fail patterns, weak assertions, untested branches), fix them directly. Do not delegate to `zuvo:fix-tests` unless the same anti-pattern spans 10+ files outside the current target set.

## Argument Parsing

Parse `$ARGUMENTS` as: `[path | auto] [--dry-run]`

| Input | Behavior |
|-------|----------|
| `[file.ts]` | Write tests for one production file |
| `[directory/]` | Write tests for all production files in the directory |
| `auto` | Discover uncovered files, write tests in batches of 15, loop until zero UNCOVERED/PARTIAL remain |
| `--dry-run` | Run analysis and produce the plan, but do not write any test files |

## Mode Table

| Mode | Approval gate | User questions | Sub-agents | Loops |
|------|--------------|----------------|------------|-------|
| `[path]` | Plan approval before writing | Up to 4 | Scanner + Selector | No |
| `auto` | None | None | Scanner + Selector | Yes (15 files per batch) |
| `--dry-run` | N/A | None | Scanner + Selector | No |

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 1 | Production file inventory | `get_file_tree(repo, name_pattern="*.ts")` | `Glob("**/*.ts")` |
| 1 | Exported symbols per file | `get_file_outline(repo, file_path)` | `Read` the file |
| 1 | Check if a symbol has tests | `search_text(repo, query=<export_name>, file_pattern="*.test.*")` | Grep |
| 1 | Classify code type from signatures | `get_file_outline(repo, file_path)` | Read the file |
| 1.5 | Read multiple methods at once | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |
| 1.5 | Find production code + its references | `find_and_show(repo, query=<fn_name>, include_refs=true)` | Grep + Read |
| 2 | Assemble context for test writing | `assemble_context(repo, query=<fn_name>, token_budget=4000)` | Multiple Read calls |
| 4 | Find existing test patterns | `search_text(repo, query=<pattern>, file_pattern="*.test.*")` | Grep |

---

## Auto-Loop Protocol

After each batch, read `memory/coverage.md`. If UNCOVERED or PARTIAL files remain, start the next batch immediately. Do not declare completion until zero gaps remain. One batch does not equal done.

**Loop ownership by environment:**

| Environment | Who owns the loop | Agent behavior |
|-------------|------------------|----------------|
| Claude Code | Agent (Phase 5) | Finish batch, check coverage.md, continue if needed |
| Codex | External loop | Finish one batch, stop. Loop restarts if gaps remain |
| Cursor | External hook | Finish one batch, stop. Hook restarts if gaps remain |

If no external loop or hook is installed, fall back to self-loop (same as Claude Code).

---

## Agent Routing

| Agent | Purpose | Model | Type | Phase |
|-------|---------|-------|------|-------|
| Coverage Scanner | Inventory production files, find untested exports, rank by risk | Haiku | Explore | 1 (background) |
| Pattern Selector | Read target files, classify code types, select G-*/P-* patterns | Haiku | Explore | 1 (background) |
| Test Quality Auditor | Run Q1-Q20 on written tests, produce evidence-backed score | Sonnet | Explore | 4 (after writing) |

All agents are read-only (Explore type).

---

## Mandatory File Reading

Before starting any work, read each file below. Print the checklist. If any REQUIRED file is missing, STOP.

```
CORE FILES LOADED:
  1. {plugin_root}/rules/testing.md                -- [READ | MISSING -> STOP]
  2. {plugin_root}/rules/test-quality-rules.md     -- [READ | MISSING -> STOP]
  3. {plugin_root}/rules/file-limits.md            -- [READ | MISSING -> STOP]
  4. {plugin_root}/shared/includes/quality-gates.md -- [READ | MISSING -> STOP]
  5. {plugin_root}/shared/includes/auto-docs.md     -- [READ | MISSING -> SKIP auto-docs]
  6. {plugin_root}/shared/includes/session-memory.md -- [READ | MISSING -> SKIP session memory]
```

### Conditional Files (loaded when needed)

| File | Load when | Skip when |
|------|-----------|-----------|
| `{plugin_root}/rules/cq-patterns.md` | Target has test files with production patterns to validate | No production patterns in scope |
| `{plugin_root}/rules/security.md` | Code type is CONTROLLER, GUARD, or API-CALL | Not security-sensitive code |
| Domain test patterns (NestJS, Redux, etc.) | Pattern Selector detects domain code | No domain-specific code detected |

---

## Phase 0: Context Gathering

1. Read project CLAUDE.md and `.claude/rules/` for conventions (test runner, file locations, mock patterns)
2. Detect stack from config files: `package.json`, `tsconfig.json`, `pyproject.toml`
3. Note domain-specific test patterns needed (NestJS controllers, Redux slices, etc.)
4. **Discover existing test patterns in the project (MANDATORY for non-trivial code):**
   Search for how THIS project already tests hard-to-mock code. Reuse established patterns.
   ```
   Search for:
   - Integration tests with DB: grep for transaction, beginTransaction, rollBack, fixtures, $this->tester->create
   - Reflection-based mocking: grep for ReflectionClass, ReflectionProperty, disableOriginalConstructor
   - Factory helpers: grep for createMock.*willReturnCallback, getMockBuilder
   - DI container overrides: grep for TestingModule, overrideProvider, useValue
   ```
   Log:
   ```
   PROJECT TEST PATTERNS:
     DB integration: [file:line — describe pattern] or "none found"
     Reflection mocking: [file:line — describe pattern] or "none found"
     Factory helpers: [file:line — describe pattern] or "none found"
   ```
   **These patterns are your toolkit.** When Phase 1.5b classifies a file as NEEDS_INTEGRATION, use the pattern you found here.
5. Read `memory/backlog.md` if it exists -- check for related open items in target files
6. Read `memory/coverage.md` if it exists -- use as cached state to skip re-scanning known files
   - If `memory/` directory does not exist, create it: `mkdir -p memory`
   - If `memory/coverage.md` does not exist, create it with an empty table header

Output:

```
STACK: [language] | RUNNER: [test runner] | DOMAIN PATTERNS: [nestjs/redux/none]
TARGET: [file | directory | auto-discover]
BACKLOG: [N open items in target files, or "none"]
```

### Phase 0.5: Baseline Test Run

Run the existing test suite before writing anything to establish a known state:

```bash
[test runner] [target path if scoped]
```

Record:

```
BASELINE: [N] tests, [N] passing, [N] failing
PRE-EXISTING FAILURES: [list, or "none"]
```

Pre-existing failures are ignored during Phase 4 verification. If the baseline run fails on infrastructure (missing deps, no runner), note it and proceed.

---

## Phase 1: Analysis

### Explicit mode (file or directory target)

Spawn Coverage Scanner and Pattern Selector in parallel. Both receive the target file list.

**Coverage Scanner** identifies which exports lack test coverage, categorizes each file as UNCOVERED, PARTIAL, or COVERED, and assigns a risk ranking.

**Pattern Selector** reads each target file and classifies its code type from the 11-type system (see Code-Type Gate below). It outputs the correct G-* patterns to follow and P-* patterns to avoid.

Wait for both agents before starting Phase 2.

### Auto mode (discovery)

Execute sequentially: Scanner first (discovers files), then Selector (classifies the top 30 candidates).

1. Scanner discovers all production files, classifies coverage status
2. Pass the top 30 UNCOVERED + PARTIAL files (by risk) to Pattern Selector
3. Selector classifies code types for those candidates

Merge results and apply priority:

| Priority | Criteria |
|----------|----------|
| 1 (highest) | UNCOVERED + SERVICE, CONTROLLER, GUARD |
| 2 | UNCOVERED + HOOK, ORCHESTRATOR, API-CALL |
| 3 | UNCOVERED + PURE, COMPONENT, ORM |
| 4 | PARTIAL (below 50% method coverage) |
| 5 (lowest) | PARTIAL (50%+ method coverage) |

Within the same priority, sort by file size descending. Take the top 15 for this batch.

---

## Code-Type Gate (11 Types)

Every target file receives a code-type classification. The classification drives minimum test count, required patterns, and mock strategy.

| Code Type | Detection Signals | Min Tests Formula |
|-----------|------------------|-------------------|
| VALIDATOR | Zod schemas, `validate*`, class-validator decorators | Fields x 3 (valid + invalid + boundary) |
| SERVICE | Injectable class with DB/HTTP calls, business logic methods | Methods x 3 |
| CONTROLLER | Route decorators, request/response handlers | Endpoints x 4 (happy + auth + validation + error) |
| HOOK | `use*` functions, React hooks with side effects | States x 3 + lifecycle tests |
| PURE | No I/O, no side effects -- transforms, formatters, calculators | Functions x 4 + property-based |
| COMPONENT | React/Vue component with props and render logic | Render states x 2 + interaction tests |
| GUARD | Auth guards, permission checks, middleware | Rules x 3 (allow + deny + edge) |
| API-CALL | HTTP client wrappers, SDK calls | Methods x 3 (success + error + timeout) |
| ORCHESTRATOR | Coordinates multiple services, saga/workflow logic | Steps x 2 + full-flow integration |
| STATE-MACHINE | Finite states with transitions, event-driven reducers | Transitions x 2 + States x 1 + lifecycle flow |
| ORM/DB | Repository pattern, query builders, migrations | Queries x 3 (success + empty + constraint violation) |

**Mixed files:** When a file combines types (e.g., a SERVICE with PURE helper functions inside it), apply both classifications. Sum the minimum test counts.

**PURE_EXTRACTABLE detection:** After classifying the file, scan for non-exported pure helper functions within non-pure files. Mark them for property-based testing. If 3+ such helpers exist, recommend extraction to a `[file].utils.ts` module.

---

## Phase 1.5: Production Code Read (Non-Negotiable)

For every target file, read the production code fully before planning tests. This is the primary quality driver.

For each file:

1. Read the entire production file (use `get_file_outline` + `get_symbols` for efficient reads when CodeSift is available)
2. List all branches: if/else, switch, ternary, nullish coalescing, early return, try/catch
3. Classify what the file OWNS (internal computations, branching decisions) versus what it DELEGATES (pass-through calls to dependencies)
4. Assign complexity:

| Classification | Criteria | Test depth |
|---------------|----------|------------|
| THIN | Under 50 LOC, no owned branching, pure delegation | Wiring correctness + error propagation. Skip edge case checklist. 5-12 tests. |
| STANDARD | 50-200 LOC, moderate branching (3-10 branches) | Full edge case checklist per parameter. 15-40 tests. |
| COMPLEX | Over 200 LOC or more than 10 branches | Split test files by concern. Full coverage. 40-80 tests. |

5. Log per file:

```
[path]: [N] LOC, [N] branches, [N] owned / [N] delegated -> [THIN|STANDARD|COMPLEX]
  Owned logic: [brief description]
  Key branches: [list the if/switch requiring both-side testing]
```

6. If time-dependent code is found (`Date.now()`, `setTimeout`, `setInterval`), flag: `FAKE TIMERS REQUIRED`

### Phase 1.5b: Testability Decision (MANDATORY — BLOCKING)

**After classifying complexity, decide HOW to test each file.** This prevents agents from writing `assertIsBool`/`markTestSkipped` stubs when code is hard to mock.

For each file, classify testability:

| Classification | Signal | Strategy |
|---------------|--------|----------|
| **UNIT_MOCKABLE** | All deps injected, no static DB/ORM calls | Standard unit test with mocks |
| **UNIT_REFLECTION** | Protected/private properties, constructor does DI but also creates internal deps | Partial mock + `disableOriginalConstructor()` + inject via reflection (use project pattern from Phase 0 step 4) |
| **NEEDS_INTEGRATION** | Static ORM calls (`Model::findOne`, `Model::find`), framework singletons, global state | Integration test with real DB -- use project's DB test pattern (transaction rollback, fixture helpers) |
| **MIXED** | Some methods unit-testable, some need DB | Split: unit tests for injectable methods, integration tests for static-call methods |

**Detection rules:**
- Static ORM/AR: `ClassName::findOne`, `::find`, `::findAll`, `DB::table`, `Yii::$app->db` → NEEDS_INTEGRATION
- Constructor injection with `$this->dep = $dep` → UNIT_MOCKABLE or UNIT_REFLECTION
- Both in same file → MIXED (decide per method)

**HARD RULES:**
1. **NEVER write `assertIsBool`/`assertIsInt`/`assertInstanceOf` as sole assertion when real testing is possible.** If reaching for these → wrong testability decision → go back and choose NEEDS_INTEGRATION.
2. **NEVER write `markTestSkipped` + TODO comment as a test.** Either write the real test (integration if needed) or skip the file and add a backlog item.
3. **NEVER write `assertTrue(true)` as a real assertion.** Only valid for "verify no exception thrown".
4. **Test file MUST test the class it's named after.** `FooServiceTest` tests `FooService`, not `BarHelper` constants.

Log per file:
```
[path]: TESTABILITY = [UNIT_MOCKABLE | UNIT_REFLECTION | NEEDS_INTEGRATION | MIXED]
  Static calls: [list or "none"]
  Project pattern to use: [from Phase 0 step 4]
```

---

## Phase 2: Plan

Produce a plan with these mandatory sections before writing any tests.

### Scope

| File | Status | Untested methods | Risk |
|------|--------|-----------------|------|

Files to SKIP must satisfy ALL three: 100% method coverage, zero auto-fail patterns, no untested branches. Cite evidence for each skip.

Files to FIX (covered but weak): not skipped, goes through Phase 3 with action=FIX.

### Test Files

| Production file | Test file | Action |
|----------------|-----------|--------|
| foo.service.ts | foo.service.test.ts | CREATE |
| bar.service.ts | bar.service.test.ts | ADD TO (partial) |
| baz.service.ts | baz.service.test.ts | FIX (100% coverage, auto-fail patterns) |

Rules:
- ADD TO: never delete or replace existing tests. New describe/it blocks only. Modification of imports, beforeEach, shared helpers is allowed when needed by new tests.
- FIX: replace auto-fail assertions with behavioral tests. This is the only action that modifies existing test logic.
- If estimated total LOC exceeds 400 lines, plan split files.

### Strategy Per File

For each file, state:
- **Testability: [UNIT_MOCKABLE | UNIT_REFLECTION | NEEDS_INTEGRATION | MIXED]** (from Phase 1.5b -- MANDATORY)
- Complexity classification (from Phase 1.5)
- Code type (from Code-Type Gate)
- Target test count with math: `[code type]: [units] x [factor] = [minimum]`
- Patterns to follow (G-* IDs) and patterns to avoid (P-* IDs)
- Mock hazards and required mock patterns
- Time-dependent code flags
- Describe block outline with it() descriptions
- Lifecycle/flow tests for STATE-MACHINE and ORCHESTRATOR types
- Security tests for CONTROLLER, API-CALL, and GUARD types

### Approval Gate

- In explicit mode: present the plan and wait for user approval before Phase 3
- In auto mode: proceed without approval
- In --dry-run mode: print the plan and STOP. Do not write files.

---

## Phase 3: Write Tests

For each target file in the plan, write the test file following the plan exactly.

### Pre-Write Blocklist (BLOCKING — check BEFORE writing a single line)

Before writing, verify you are NOT about to produce any of these. If you catch yourself reaching for one, STOP and reconsider testability classification:

| Blocked Pattern | Why | Do Instead |
|----------------|-----|------------|
| `assertIsBool` / `assertIsInt` / `assertIsString` as sole assertion | Tests TYPE not VALUE — accepts both correct and wrong results | `assertEquals`/`assertFalse`/`assertTrue` with specific expected value |
| `assertInstanceOf` as sole assertion (except factory/DI tests) | Existence test, not behavior | Test a method call and verify its output |
| `markTestSkipped('Requires database')` + no real assertion | Stub test, inflates coverage with zero value | Write integration test with transaction rollback, or skip file + backlog item |
| `assertTrue(true)` as primary assertion | Always-true, passes regardless of production behavior | Let test pass naturally (no exception = pass) or use `expectNotToPerformAssertions()` |
| TODO comment as test body ("With DB fixtures: create X, verify Y") | Recipe, not a test | Write the actual test or add backlog item |
| Testing a different class than the test file name | `FooServiceTest` testing `BarHelper` constants | Create `BarHelperTest` for BarHelper |
| `canConnectToDb()` guard wrapping most tests | Mixing unit and integration | Choose one strategy per file |

### Writing Protocol

1. Create or extend the test file per the plan's Action column
2. Write tests in describe/it blocks matching the plan's outline
3. Apply the correct patterns from the Code-Type Gate
4. For PURE_CANDIDATE files, add property-based tests alongside example-based tests
5. For STATE-MACHINE types, include lifecycle flow tests (init, interact, verify, cleanup, re-init)
6. For time-dependent code, use fake timers (`vi.useFakeTimers()` or `jest.useFakeTimers()`)

### Mock Safety Rules

- Every mock verified with `toHaveBeenCalledWith` (positive) and `not.toHaveBeenCalled` (negative)
- No `as any` or `as never` casts on mocks -- use typed factories
- Reset all mocks in `beforeEach`
- Async generators: mock with `async function*` or iterable factory
- Streams: mock with readable stream from string
- External services: mock at the boundary, test real logic

### Edge Case Checklist (STANDARD and COMPLEX only)

Apply per parameter type: string (empty, whitespace, unicode, max-length), number (0, negative, NaN, Infinity, MAX_SAFE_INTEGER), array (empty, single, duplicates, very large), object (empty, missing keys, extra keys, null prototype), boolean (truthy/falsy coercion traps), Date (invalid, epoch, timezone edge), optional (undefined, null, missing key vs present-null), enum (each value + invalid value + undefined).

THIN wrappers skip this checklist -- test wiring correctness and error propagation only.

---

## Phase 4: Verification

### 4.1 Run Tests

Execute the test suite:

```bash
[test runner] [target test files]
```

All new tests must pass. Pre-existing failures from Phase 0.5 are ignored. If new tests fail, fix them before proceeding.

### 4.2 Q1-Q20 Self-Evaluation

Run the Q1-Q20 checklist against every written or modified test file. Print the scorecard:

```
Self-eval: Q1=1 Q2=1 Q3=0 Q4=1 ...
  Score: [N]/17 -> PASS | FIX | REWRITE
  Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]
```

Any critical gate at 0: fix immediately and re-score. Target: PASS (14+/17 with all critical gates satisfied).

### 4.3 Test Quality Auditor (Optional Agent)

If sub-agent dispatch is available, spawn the Test Quality Auditor (Sonnet, Explore) to independently verify Q1-Q20 scores with evidence. Compare the agent's scores with the self-evaluation. Discrepancies are resolved by checking the evidence.

---

## Phase 5: Completion

### 5.1 Update Coverage Tracking

Write results to `memory/coverage.md`. Each file gets a row: file path, coverage status, test count, quality score, date.

### 5.2 Backlog Persistence

Read `{plugin_root}/shared/includes/backlog-protocol.md`.

Persist any issues discovered but not fixed (quality problems in production code, architectural concerns noticed during testing) to `memory/backlog.md`.

### 5.3 Completion Report

```
WRITE-TESTS COMPLETE
-----
Files tested:  [N] ([M] new, [K] extended, [J] fixed)
Tests written: [N] (target: [M], actual: [N])
Q gates:       [N]/17 avg (critical gates: all pass)
Failures:      [pre-existing: N, new: 0]
-----
```

### 5.4 Auto-Loop Check (auto mode only)

Read `memory/coverage.md`. If UNCOVERED or PARTIAL files remain, go back to Phase 1 for the next batch. Do not print "WRITE-TESTS COMPLETE" until all files are covered.

---

## Principles

1. Read the production code before planning tests. Every test assertion must trace to real behavior in the source.
2. Test depth matches file complexity. A 25-line wrapper does not need 30 edge-case tests.
3. Test what the code OWNS, mock what it DELEGATES.
4. Fake timers for time-dependent code. Real implementations for pure functions.
5. Quality gates are not optional. Q1-Q20 evaluation happens on every test file, every time.

---

## Auto-Docs

After completing the skill output, update per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the test generation scope, key findings, and verdict.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with test generation summary and verdict.

---

## Run Log

Log this run to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`:
- SKILL: `write-tests`
- CQ_SCORE: `-`
- Q_SCORE: `Q score from written tests`
- VERDICT: PASS if tests generated and passing
- TASKS: number of test files created
- DURATION: `-`
- NOTES: scope summary (max 80 chars)
