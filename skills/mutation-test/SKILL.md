---
name: mutation-test
description: >
  LLM-guided mutation testing. Instead of random mutations, the LLM intelligently
  selects mutations that test meaningful behavior: boundary conditions, logic
  inversions, null returns, error path removals, state mutations, async hazards,
  and security guard removals. Generates mutations, executes them against the
  relevant tests, and reports which mutations survived (tests need strengthening).
  Flags: [path] (scope), full, --max N, --category, --dry-run, --quick.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_symbols           # find functions to mutate
    - get_symbol
    - get_symbols
    - get_file_outline
    - find_references          # which tests cover this fn
    - search_patterns          # mutation candidates (boundary, null returns, async)
    - search_text
    - audit_scan
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders]
    django: [analyze_django_settings, effective_django_view_security, taint_trace]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service]
    prisma: [analyze_prisma_schema]
    drizzle: []
    sql: [sql_audit]
    postgres: [migration_lint]
---

# zuvo:mutation-test -- LLM-Guided Mutation Testing

Intelligent mutation testing that targets meaningful behavioral gaps rather than random code changes. For each production file, the LLM generates mutations in 7 categories (boundary, logic, null, error, state, async, security), runs only the tests that cover that file, and reports which mutations survived -- revealing exactly where tests need strengthening.

**Scope:** Production files that have associated test files. Measures how well existing tests detect real behavioral changes.
**When to use:** After writing tests, before releases, when mutation score is unknown, when test suite feels shallow despite high line coverage.
**Out of scope:** Writing new tests (use `zuvo:write-tests`), fixing systematic test anti-patterns (use `zuvo:fix-tests`), auditing test quality without execution (use `zuvo:test-audit`), code quality review (use `zuvo:review`).

## Argument Parsing

Parse `$ARGUMENTS` as: `[path | full] [--max N] [--category CATEGORY] [--dry-run] [--quick]`

| Flag | Effect |
|------|--------|
| `[path]` | Scope to a specific directory or file |
| `full` | All production files that have test coverage |
| `--max N` | Max total mutations to execute (default: 50) |
| `--category CATEGORY` | Only generate mutations of this category: `BOUNDARY`, `LOGIC`, `NULL`, `ERROR`, `STATE`, `ASYNC`, `SECURITY` |
| `--dry-run` | Generate mutations and show the plan, but do not execute any |
| `--quick` | Max 3 mutations per file, max 20 total |

Flags can be combined: `zuvo:mutation-test src/services/ --max 30 --category SECURITY`

Default (no arguments): equivalent to `full --max 50`.

## Mandatory File Loading

Read these files from disk before starting. Print the checklist. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../rules/testing.md                -- READ/MISSING
  2. ../../rules/test-quality-rules.md     -- READ/MISSING
  3. ../../shared/includes/env-compat.md   -- READ/MISSING
  4. ../../shared/includes/run-logger.md   -- READ/MISSING
  5. ../../shared/includes/retrospective.md   -- READ/MISSING
```

**If any file is missing:** Proceed in degraded mode. Note "DEGRADED -- [file] unavailable" in the final report.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Key tools for this skill:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 0 | Find production files | `get_file_tree(repo, file_pattern=<detected_ext>)` | `Glob` with detected extension |
| 0 | Find test files | `get_file_tree(repo, name_pattern=<detected_test_pattern>)` | `Glob` with detected test pattern |
| 0 | Understand file structure | `get_file_outline(repo, file_path)` | `Read` the file |
| 0 | Detect complexity hotspots | `analyze_complexity(repo, top_n=20)` | Line count heuristic |
| 2 | Read production code for mutation targeting | `get_symbol(repo, symbol_id)` | `Read` the file |
| 2 | Batch-read multiple functions | `get_symbols(repo, symbol_ids=[...])` | Multiple `Read` calls |
| 2 | Find references to identify test coverage | `find_references(repo, symbol_name)` | `Grep` for imports |

---

## Phase 0: Discovery

Detect the project's test infrastructure and build the production-to-test file map.

### 0.1 Framework Detection

Detect the test framework and runner from config files:

| Signal | Framework | Runner command |
|--------|-----------|----------------|
| `jest.config.*` or `"jest"` in package.json | Jest | `npx jest` |
| `vitest.config.*` or `"vitest"` in package.json | Vitest | `npx vitest run` |
| `pytest.ini`, `pyproject.toml [tool.pytest]`, `conftest.py` | Pytest | `pytest` |
| `phpunit.xml` | PHPUnit | `vendor/bin/phpunit` |
| `_test.go` files | Go testing | `go test` |
| `*_spec.rb` files | RSpec | `bundle exec rspec` |
| `*.test.rs` or `#[cfg(test)]` | Rust | `cargo test` |

If framework cannot be detected: ask the user for the test runner command.

### 0.2 File Mapping

Build a map of production files to their test files. **Discovery patterns are language-aware** — use the detected framework from 0.1:

| Language | Production ext | Test patterns |
|----------|---------------|---------------|
| TypeScript/JavaScript | `*.ts`, `*.tsx`, `*.js`, `*.jsx` | `*.test.*`, `*.spec.*`, `__tests__/*` |
| Python | `*.py` | `test_*`, `*_test.py`, `tests/` |
| PHP | `*.php` | `*Test.php`, `tests/` |
| Go | `*.go` (non-test) | `*_test.go` |
| Ruby | `*.rb` | `*_spec.rb`, `spec/` |
| Rust | `*.rs` (non-test) | `#[cfg(test)]` blocks, `tests/` |

For each detected language:
1. Scan for all test files using the language-specific patterns
2. For each test file, identify the production file it covers:
   - By import/require statements in the test
   - By naming convention (`foo.ts` -> `foo.test.ts`, `foo.py` -> `test_foo.py`)
   - By directory convention (`src/foo.ts` -> `__tests__/foo.test.ts`)
3. Build the map: `{ production_file: [test_file_1, test_file_2, ...] }`
4. Exclude production files with no test coverage (nothing to validate mutations against)

If no language matches or discovery produces 0 files: ask the user for the file patterns.

### 0.3 Prioritization

Order files for mutation testing by priority:

1. **Critical paths first:** Files matching keywords: `auth`, `login`, `session`, `token`, `payment`, `billing`, `charge`, `transaction`, `password`, `encrypt`, `decrypt`, `sanitize`, `validate`, `permission`, `role`, `access`
2. **High complexity:** Files with the most functions, branches, or cyclomatic complexity
3. **Recent changes:** Files with commits in the last 30 days (active development = higher risk)
4. **Everything else:** Alphabetical

If `--category SECURITY` is set, promote files matching security-related keywords to the top.

Output:
```
DISCOVERY
  Framework: [name] | Runner: [command]
  Production files with tests: [N]
  Files excluded (no tests): [N]
  Priority order: [top 5 files listed]
  Scope: [path or "full project"]
  Max mutations: [N]
```

If `--quick`: reduce max mutations per file to 3, total to 20.

---

## Phase 1: Baseline

Establish that all tests pass before introducing mutations.

### 1.1 Run Full Test Suite

Execute the detected test runner command against the scoped files:

```bash
# Examples:
npx jest --passWithNoTests          # Jest
npx vitest run                      # Vitest
pytest                              # Pytest
go test ./...                       # Go
```

### 1.2 Validate Baseline

- **All tests pass:** Record the total execution time. Proceed to Phase 2.
- **Any test fails:** STOP immediately. Do not proceed with mutation testing.

If tests fail:
```
BASELINE FAILED
  [N] test(s) failing
  Cannot run mutation testing against a failing test suite.
  Suggestion: run zuvo:fix-tests to repair failing tests first.
```

### 1.3 Calculate Timeouts

- **Per-file timeout:** 3x the baseline time divided by number of test files, minimum 10 seconds
- **Total timeout:** 3x the full baseline time, minimum 60 seconds

Output:
```
BASELINE
  Tests: [N] passing | [N] suites
  Baseline time: [N]s
  Per-file timeout: [N]s
  Total timeout: [N]s
```

---

## Phase 2: Mutation Generation

For each production file (in priority order from Phase 0), generate intelligent mutations.

### 2.1 Read Production Code

Read the full production file. Identify:
- Functions, methods, and their signatures
- Conditional branches (if/else, switch, ternary)
- Guard clauses and validation
- Error handling (try/catch, throw, reject)
- State mutations and assignments
- Async operations (await, Promise, callback)
- Security-relevant code (auth checks, sanitization, access control)

### 2.2 Generate Mutations

For each file, generate 5-10 mutations across these categories:

| Category | Tag | Mutation type | Example |
|----------|-----|--------------|---------|
| Boundary | `BOUNDARY` | Off-by-one, `<` vs `<=`, `>=` vs `>`, `+1`/`-1` on limits | `i < arr.length` -> `i <= arr.length` |
| Logic | `LOGIC` | `true` -> `false`, `&&` -> `\|\|`, negate condition | `if (isValid)` -> `if (!isValid)` |
| Null/empty | `NULL` | Return `null` instead of value, empty array instead of data | `return users` -> `return []` |
| Error path | `ERROR` | Remove try/catch, swap error types, skip validation | Remove `if (!input) throw` guard |
| State | `STATE` | Remove state update, swap assignment values | `count += 1` -> `count += 0` |
| Async | `ASYNC` | Remove `await`, swap resolve/reject | `await save()` -> `save()` (fire-and-forget) |
| Security | `SECURITY` | Remove auth check, skip validation, remove sanitization | Remove `if (!user.isAdmin) return 403` |

**Mutation quality rules:**
- Each mutation must change observable behavior (not just cosmetic)
- Skip trivial mutations: comments, whitespace, logging-only statements, console.log
- Skip mutations in generated code, type definitions, and pure configuration
- Each mutation targets one specific behavioral change
- Prefer mutations at decision points (branches, guards, returns)

**If `--category` is set:** Only generate mutations of the specified category.

### 2.3 Mutation Plan

For each mutation, record:
- `MUT-NNN`: Sequential ID
- `file`: Production file path
- `line`: Line number
- `category`: One of BOUNDARY, LOGIC, NULL, ERROR, STATE, ASYNC, SECURITY
- `original`: Original code (1-3 lines)
- `mutated`: Mutated code (1-3 lines)
- `rationale`: Why a test should catch this (1 sentence)
- `test_files`: Which test file(s) to run

Cap at `--max` total mutations (default 50). If more mutations are possible, prioritize by:
1. SECURITY mutations (most important to catch)
2. ERROR mutations (error paths are commonly under-tested)
3. BOUNDARY mutations (off-by-one errors are common and subtle)
4. LOGIC, NULL, STATE, ASYNC (remaining categories)

**If `--dry-run`:** Print the mutation plan and STOP. Do not execute.

```
MUTATION PLAN (--dry-run)
  Files: [N]
  Mutations: [N] total
  [list each mutation with ID, file, line, category, original, mutated, rationale]
  
  To execute: zuvo:mutation-test [same args without --dry-run]
```

---

## Phase 3: Mutation Execution

For each mutation in the plan, apply it, run tests, and record the result.

### 3.1 Safety Protocol

Before starting execution:

1. Verify the working directory is clean (`git status` shows no uncommitted changes)
   - If uncommitted changes exist: STOP and ask user to commit or stash first
2. **Restoration strategy (temp copy — NOT stash):**
   - For each production file being mutated, copy the original to a temp location: `cp [file] /tmp/zuvo-mutation-[hash]-[filename]`
   - After each mutation: restore from the temp copy: `cp /tmp/zuvo-mutation-[hash]-[filename] [file]`
   - After ALL mutations complete (or on error): verify every original is restored, then delete temp copies
   - **Do NOT use `git stash`** (pop consumes the stash on first iteration)
   - **Do NOT use `git checkout -- [file]`** (destructive to local changes)
3. NEVER commit a mutated file. NEVER leave a mutation in place after execution.

### 3.2 Execution Loop

For each mutation `MUT-NNN`:

```
1. APPLY: Write the mutated code to the production file
2. RUN (two-tier strategy):
   TIER 1 — Run mapped test files first (fast, targeted):
   - Jest: npx jest [test_file_1] [test_file_2] --no-coverage
   - Vitest: npx vitest run [test_file_1] [test_file_2]
   - Pytest: pytest [test_file_1] [test_file_2] -x
   - Go: go test [package] -run [test_pattern]
   
   TIER 2 — If TIER 1 passes (mutation survived), run the FULL test suite:
   - This catches integration tests, black-box tests, and indirect callers
   - If full suite fails -> mutation KILLED (integration test caught it)
   - If full suite passes -> mutation truly SURVIVED

   --quick mode: skip TIER 2 (only mapped tests). Mark survivors as
   "SURVIVED (mapped tests only)" with a warning that score may be optimistic.

3. RECORD result:
   - Test FAILED (tier 1) -> mutation KILLED (good: direct test caught it)
   - Test FAILED (tier 2) -> mutation KILLED-INDIRECT (good: integration test caught it)
   - Test PASSED (both tiers) -> mutation SURVIVED (bad: no test caught it)
   - Test TIMEOUT (>per-file timeout) -> mutation TIMEOUT (counts as killed)
   - Test ERROR (crash/compile error) -> mutation KILLED (counts as killed)
4. RESTORE: Copy original from temp location back to production file
5. VERIFY: Diff check to confirm restoration is clean
```

**Error recovery:** If restoration fails for any reason:
1. Copy from temp file: `cp /tmp/zuvo-mutation-[hash]-[filename] [file]`
2. If temp file missing: `git checkout HEAD -- [file]` (safe: working dir was clean at start)
3. If both fail, STOP execution and alert the user

**Progress tracking:** After every 10 mutations, print a progress line:
```
PROGRESS: [N]/[total] mutations executed | [killed] killed | [survived] survived
```

### 3.3 Early Termination

Stop execution early if:
- Total timeout exceeded
- 5 consecutive restore failures
- User interrupts

On early termination, report results for mutations completed so far.

---

## Phase 4: Analysis & Report

### 4.1 Score Calculation

**Per-file mutation score:**
```
score = killed / (killed + survived) * 100
```

Note: TIMEOUT and ERROR count as killed (the mutation was detected).

**Overall mutation score:** Sum of all killed / sum of all (killed + survived).

**Grade:**
| Score | Grade |
|-------|-------|
| >= 80% | A |
| 60-79% | B |
| 40-59% | C |
| < 40% | D |

**Verdict mapping (for run log):**
| Score | Verdict |
|-------|---------|
| >= 80% | PASS |
| 60-79% | WARN |
| < 60% | FAIL |

### 4.2 Survived Mutation Analysis

For each SURVIVED mutation, analyze:
1. **What changed:** The specific mutation applied
2. **Why it matters:** What behavioral gap this reveals
3. **Which test file:** The test file(s) that should have caught it
4. **Suggested test:** A 1-3 line description of the test to add (not full code)

### 4.3 Report Output

```
MUTATION TEST COMPLETE
===============================================
Project: [name]
Date: [ISO-8601 date]
Files tested: [N]
Mutations generated: [N]
Mutations killed: [N] ([X]%)
Mutations survived: [N] ([Y]%)

MUTATION SCORE: [N]% -- Grade [A/B/C/D]
===============================================

## Per-File Scores

| File | Mutations | Killed | Survived | Score | Grade |
|------|-----------|--------|----------|-------|-------|
| [path] | [N] | [N] | [N] | [N]% | [A-D] |

## Survived Mutations (tests need strengthening)

### MUT-001: [file:line] -- [CATEGORY]
  Mutation: [original] -> [mutated]
  Expected: test should fail because [reason]
  Gap: [test_file] missing [what kind of test]
  Suggest: [1-line test description]

### MUT-002: [file:line] -- [CATEGORY]
  ...

## Mutation Categories

| Category | Generated | Killed | Survived | Kill Rate |
|----------|-----------|--------|----------|-----------|
| BOUNDARY | [N] | [N] | [N] | [N]% |
| LOGIC | [N] | [N] | [N] | [N]% |
| NULL | [N] | [N] | [N] | [N]% |
| ERROR | [N] | [N] | [N] | [N]% |
| STATE | [N] | [N] | [N] | [N]% |
| ASYNC | [N] | [N] | [N] | [N]% |
| SECURITY | [N] | [N] | [N] | [N]% |

## Recommended Next Steps

- zuvo:write-tests [file] -- for files with <60% mutation score
- zuvo:fix-tests -- for files where tests exist but don't catch mutations
- zuvo:mutation-test [file] --category [weakest] -- retest after fixes

Run: <ISO-8601-Z>	mutation-test	<project>	<score>%	<killed>/<total>	<VERDICT>	-	<N>-files	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `../../shared/includes/run-logger.md`.

VERDICT: PASS (>=80%), WARN (60-79%), FAIL (<60%).
CQ_SCORE field: `<score>%` (the overall mutation score).
Q_SCORE field: `<killed>/<total>` (killed count / total mutations).
TASKS: `-` (no file modifications).
DURATION: `<N>-files` (number of production files tested).
NOTES: `mutation-test [scope] [grade]` (max 80 chars).
===============================================
```

### 4.4 Dry-Run Report

If `--dry-run` was specified, replace the execution sections with:

```
MUTATION TEST PLAN (DRY RUN)
===============================================
Project: [name]
Date: [ISO-8601 date]
Files to test: [N]
Mutations planned: [N]

## Mutation Plan

### [file_path] -- [N] mutations planned
  MUT-001 [CATEGORY] line [N]: [original] -> [mutated]
  MUT-002 [CATEGORY] line [N]: [original] -> [mutated]
  ...

## Category Distribution

| Category | Count | % of Total |
|----------|-------|------------|
| BOUNDARY | [N] | [N]% |
| ...

To execute: zuvo:mutation-test [same args without --dry-run]
===============================================
```

---

## Safety Guarantees

These are non-negotiable:

1. **Never commit mutations.** All mutations are temporary. Original code is always restored.
2. **Never modify test files.** Mutations apply only to production code.
3. **Always verify restoration.** After each mutation, confirm the original file is intact.
4. **Timeout protection.** No single mutation test can run longer than 3x baseline per file.
5. **Clean state on exit.** If the skill is interrupted, ensure `git checkout -- [file]` or `git stash pop` is run.
6. **No side effects.** Mutations that would affect databases, external APIs, or file system state outside the project are not generated.
