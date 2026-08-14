---
name: mutation-test
description: >
  LLM-guided mutation testing. Instead of random mutations, the LLM intelligently
  selects mutations that test meaningful behavior: boundary conditions, logic
  inversions, null returns, error path removals, state mutations, async hazards,
  and security guard removals. Generates mutations, executes them against the
  relevant tests, and FIXES the tests whose gaps let a mutation survive — surviving
  mutants are closed in-run, not handed to another skill.
  Flags: [path] (scope), full, --max N, --category, --dry-run, --quick, --report-only.
category: Testing
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
    php: [php_project_audit, php_security_scan, resolve_php_namespace]
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

Intelligent mutation testing that targets meaningful behavioral gaps rather than random code changes. For each production file, the LLM generates mutations in 7 categories (boundary, logic, null, error, state, async, security), runs only the tests that cover that file, and closes the gaps it finds: every survivor is triaged
as a real gap or an equivalent mutant, and each real gap gets the missing assertion added and
re-probed in the same run.

**Scope:** Production files that have associated test files. Measures how well existing tests detect real behavioral changes.
**When to use:** After writing tests, before releases, when mutation score is unknown, when test suite feels shallow despite high line coverage.
**Out of scope:** Writing a test suite from scratch (use `zuvo:write-tests`), fixing systematic test
anti-patterns across many files (use `zuvo:fix-tests`), auditing test quality without execution (use
`zuvo:test-audit`), code quality review (use `zuvo:review`). Adding the single missing assertion that
a surviving mutant exposes is IN scope — that is the point of finding it.

## Argument Parsing

Parse `$ARGUMENTS` as: `[path | full | continue] [--max N] [--category CATEGORY] [--dry-run] [--quick] [--report-only]`

| Flag | Effect |
|------|--------|
| `[path]` | Scope to a specific directory or file |
| `continue` | Resume an interrupted run from its checkpoint (Phase 3.0). Re-runs nothing already resolved. |
| `full` | All production files that have test coverage |
| `--max N` | Max total mutations to execute (default: 50) |
| `--category CATEGORY` | Only generate mutations of this category: `BOUNDARY`, `LOGIC`, `NULL`, `ERROR`, `STATE`, `ASYNC`, `SECURITY` |
| `--dry-run` | Generate mutations and show the plan, but do not execute any |
| `--quick` | Max 3 mutations per file, max 20 total |
| `--report-only` | Report the score; do NOT fix surviving gaps (skips 4.2b). The only way to skip the fix loop. |

Flags can be combined: `zuvo:mutation-test src/services/ --max 30 --category SECURITY`

Default (no arguments): equivalent to `full --max 50`.

## Mandatory File Loading

Read these files from disk before starting. Print the checklist. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../rules/testing.md                -- READ/MISSING
  2. ../../rules/testing.md (M1-M5 + Assertion Strength + Self-Eval Evidence) -- READ/MISSING
  3. ../../shared/includes/env-compat.md   -- READ/MISSING
  4. ../../shared/includes/run-logger.md   -- READ/MISSING
  5. ../../shared/includes/retrospective.md   -- READ/MISSING
  6. ../../shared/includes/report-output-location.md -- READ/MISSING (canonical $ZUVO_DIR for 4.3b)
```

**If any file is missing:** Proceed in degraded mode. Note "DEGRADED -- [file] unavailable" in the final report.

## Environment Compatibility

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates, so a session rule about unprompted Agent use does not
apply here. Only a harness with NO dispatch capability takes the documented single-agent fallback,
and it still runs every gate inline — see `../../shared/includes/env-compat.md`. Skipping a mandated
agent and self-scoring the result is a substituted gate, not a degraded run.

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

### 1.3 Run the tests LOCALLY — never through a remote-runner wrapper

**Do not prefix any command in this skill with `rt` (or any other offload wrapper.)**
A global rule of the form "prefix test commands with `rt`" is correct for one long
suite run and inverts here: the wrapper's cost is a fixed per-invocation charge
(mirror sync + queue), and this skill makes N short invocations in a tight loop.

Measured 2026-08-10 on the same single test file:

| Invocation | Wall clock |
|---|---|
| `npx vitest run <file>` | **1.4 s** (2.2 s cold) |
| `rt npx vitest run <file>` | **103.4 s** |

~50-75x, and a single wrapped call alone exceeds the whole run budget below. A
10-mutant plan that would finish in ~20 s locally cannot complete a single mutant
through the wrapper. If a project genuinely cannot run its tests locally, this skill
is not usable there — say so and stop; do not run it wrapped and report the timeout
as a test-quality result.

### 1.3b Calculate Timeouts — budget per-invocation cost, not suite time

**Measure the real per-invocation cost first.** Run the mapped tests for the first
target file ONCE, unmutated, and record wall clock as `PER_RUN`. That number carries
runner startup, transform and setup — which dominate a short targeted run and are
paid again for every mutation. The full-suite baseline time does NOT predict it.

```
PER_RUN        = measured wall clock of one unmutated targeted run
TIER2_RUNS     = expected survivors (unknown up front — budget 30% of MUTATION_COUNT)
BUDGET         = MUTATION_COUNT * PER_RUN * 1.5          # tier 1, +50% slack
               + TIER2_RUNS * BASELINE_TIME * 1.5        # tier 2 full-suite passes
Per-file timeout = max(10s, 3 * PER_RUN)
```

The old formula was `3 * baseline, minimum 60s` — it budgeted three suite runs while
the loop actually spends `N * (startup + short run)`. With a 5 s suite the budget was
60 s regardless of whether the plan had 5 mutants or 50, so a plan was aborted
mid-way on a limit that had nothing to do with its size. Reported by a user on
2026-08-10: 7 of 10 mutants dropped, budget consumed by invocation overhead.

**If `BUDGET` looks unreasonable, shrink the PLAN, not the budget** — lower `--max`
or use `--quick`, and say which. Silently truncating a plan produces a mutation score
computed over a sample the report presents as the whole plan.

Output:
```
BASELINE
  Tests: [N] passing | [N] suites
  Baseline time: [N]s        (full suite, once)
  Per-run cost:  [N]s        (one targeted run — what each mutation actually costs)
  Runner:        local       (never rt/remote — see 1.3)
  Plan:          [N] mutations -> budget [N]s
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

### 2.3b Anchor every mutation to CONTENT, not to a line number

`line` is a hint that expires. It is recorded before Phase 3 runs, and by the time a mutation is
applied — or re-applied on resume — the file may have moved underneath it: Phase 4.2b writes tests
and can touch production code, a fix commit lands between passes, or a resumed run meets a file
edited since the plan was made. Applying `mutated` at a stale line number does not fail loudly; it
corrupts a DIFFERENT statement and the run then measures a mutation nobody designed.

So each mutation carries an anchor that survives movement:

- `symbol`: the enclosing function/method/class name (from CodeSift `get_file_outline`, or the
  nearest preceding definition line when unavailable).
- `original_norm`: `original` with leading/trailing whitespace stripped per line and internal runs
  of whitespace collapsed to one space. This is what you MATCH on — never the raw text, because
  a formatter run would otherwise invalidate every anchor in the plan.
- `occurrence`: 1-based index of `original_norm` **within `symbol`**, for the case where the same
  statement appears more than once in one function.
- `file_sha`: `git hash-object <file>` at plan time.

**Resolve before applying, every time:**

1. If `git hash-object <file>` still equals `file_sha`, the plan is current — apply at `line`.
2. Otherwise re-locate: find `symbol`, then the `occurrence`-th match of `original_norm` inside it.
   Exactly one match → apply there and record `anchor: relocated(<old-line> → <new-line>)`.
3. Zero matches, or more than one after the occurrence filter → **SKIP this mutation** and record
   `anchor: lost (<reason>)`. A skipped mutation is `not_run`, and per Phase 3.3 a plan that did
   not run in full is not a score — it must be reported as such, never averaged away.

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

### 3.0 Checkpoint — write it after EVERY mutation, not at the end

A mutation run is a long loop of expensive, individually-meaningful results, and until now it kept
all of them in context only. Anything that ended the run — an API error, a 137, a timeout, the user
stopping it — threw away every mutation already executed and left the next attempt to redo the lot.
Worse, Phase 3.1 restores the file from a temp copy after each mutation, so a run killed mid-apply
can leave a MUTATED file on disk with nothing on record saying so.

State file: `zuvo/context/mutation-<target-hash>.json` (`<target-hash>` = first 8 of the SHA-1 of
the scope argument, so concurrent runs on different scopes do not collide).

```json
{
  "version": 1,
  "scope": "src/services/",
  "baseline": { "passed": 412, "failed": 0, "sha7": "a1b2c3d" },
  "applied_to": null,
  "mutations": [
    { "id": "MUT-001", "file": "src/x.ts", "symbol": "calcTax", "line": 88,
      "original_norm": "if (n > 0) {", "occurrence": 1, "file_sha": "e4f5…",
      "status": "killed|survived|fixed|not_run|lost", "anchor": "exact|relocated(88→91)|lost(<reason>)" }
  ]
}
```

**BEFORE anything else — including on a FRESH run — load any existing state file for this scope and
honour its `applied_to`.** Writing a new plan first would overwrite the only record that a previous
run died with a mutation on disk, and that mutated file then stays in the working tree, silently
poisoning every later baseline in a way that looks like a real regression. `continue` is not the
only path into a crashed run; the far more likely one is a user who re-runs the same command.

Write it at three moments, and the middle one is the one that matters:

1. **After the plan is generated** — the full list at `status: not_run`. Only after the recovery
   above has run and `applied_to` is back to `null`.
2. **`applied_to: "<file>"` BEFORE writing a mutation, back to `null` AFTER restoring it.** This is
   the crash-safety record: a non-null `applied_to` on startup means the previous run died with a
   mutation on disk. Restore that file from its temp copy (or `git checkout` it if the copy is gone
   and the file is tracked and otherwise clean) BEFORE doing anything else, and say so.
3. **After each mutation resolves** — its `status`, immediately, not batched at the end.

**`continue` mode:** load the state file, restore any `applied_to` leftover, then execute only
mutations whose `status` is `not_run`, re-resolving each anchor per 2.3b (the tree has moved since
the plan — that is why you are resuming). Print what you skipped and why:

```
[MUTATION] resumed from checkpoint: 31/50 already resolved (24 killed, 5 survived, 2 fixed)
[MUTATION] restored a mutated file left by the interrupted run: src/x.ts
[MUTATION] 19 remaining
```

If no state file exists for the scope, say so and start fresh — never silently treat `continue` as
a new full run, because the score of a partial resume and the score of a fresh run are different
numbers and only one of them answers the question that was asked.

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

### 3.3 Early Termination — a truncated plan is NOT a score

Stop execution early if:
- Budget exceeded (1.3b)
- 5 consecutive restore failures
- User interrupts

**"Report results for mutations completed so far" was the whole bug.** A run that
executed 3 of 10 mutants and then printed a mutation score presented a sample as the
answer — the number looked like every complete run's number, with nothing marking it
as covering under a third of the plan. Reported by a user on 2026-08-10 after exactly
that: 7 of 10 dropped on the budget, a score printed anyway.

On early termination:

1. **`result` is `PARTIAL`, never PASS/WARN/FAIL.** A grade over an unfinished plan is
   not a grade. The JSON sets `"result": "PARTIAL"` and `"plan_completed": false`.
2. **Lead with what is missing**, before any number:
   ```
   MUTATION RUN INCOMPLETE — <executed>/<planned> mutants executed
     stopped by: <budget | restore-failures | user-interrupt>
     not executed: MUT-004..MUT-010 (7)
     measured per-run cost: <N>s   budget was: <N>s
     partial score over the <executed> that ran: <N>% — NOT the file's mutation score
   ```
3. **Downstream must refuse it.** `test-audit` scoring Q21 treats
   `plan_completed: false` the same as stale data: `N/A (mutation run incomplete —
   <executed>/<planned>)`. A partial score must never satisfy a coverage gate.
4. **Name the fix, since it is nearly always the budget and not the tests.** If the
   stop was `budget`, print the per-run cost next to it — a wrapped/remote runner shows
   up immediately as a per-run cost 50x the local one (see 1.3).

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
| >= 60% and < 80% | B |
| >= 40% and < 60% | C |
| < 40% | D |

Bands are stated as explicit inequalities, not as `60-79%`: a real score of 79.6% falls in no band under the
hyphenated form, and rounding it into one silently changes the grade.

**Verdict mapping (for run log):**
| Score | Verdict |
|-------|---------|
| >= 80% | PASS |
| >= 60% and < 80% | WARN |
| < 60% | FAIL |

### 4.2 Survived Mutation Analysis

For each SURVIVED mutation, analyze:
1. **What changed:** The specific mutation applied
2. **Why it matters:** What behavioral gap this reveals
3. **Which test file:** The test file(s) that should have caught it
4. **Suggested test:** A 1-3 line description of the test to add (not full code)

**Triage each survivor as `gap` or `equivalent` — this is not optional.** An
*equivalent mutant* changes the source without changing any observable behavior, so no
test can kill it and counting it against the score punishes the suite for something it
cannot fix. Establish equivalence by tracing how the mutated value is consumed, and
record that trace as the reason — never assert it from intuition.

Measured example (translation-qa `resync-units.ts`, 2026-08-09): dropping the
`s.entryId !== null` guard survived. `segByEntryId` is only ever `.set()` and
`.get(<numeric id>)` — never iterated, never `.keys()` — so a null-keyed entry is
unreachable and the mutation is `equivalent`. In the same run, flipping
`count > bestCount` to `>=` also survived and IS a `gap`: it changes which unit wins a
tie, and the test file's own header names "a wrong primary-unit pick silently scatters a
proofreader's work" as the top risk. Raw score 75%, triaged 86% — the difference decides
whether Q21 passes.

`score_triaged` (below) is the number downstream consumers read. A gate that reads the
raw score punishes suites for unkillable mutants, and a gate people cannot satisfy is a
gate people learn to ignore.

### 4.2b Close the gaps IN THIS RUN (default — not a hand-off)

**For every survivor triaged `gap`, strengthen the test here and prove the fix.** Do not
end the run by naming the gap and pointing at another skill.

Until 2026-08-09 this skill finished with "Recommended Next Steps: `zuvo:write-tests`
[file]". That is the drift `no-silent-backlog-deferral` names: the finding is already
localized to one assertion in one test file, the fix is two lines, and handing it to
another skill means re-running discovery, re-reading the file, and hoping the next run
targets the same mutation. `write-tests` closes its own probe gaps in-run
(`test-mutation-probes.md`: "add the missing behavioral assertion, re-run, and
re-probe — do not close the file with a surviving probe"). Standalone mutation-test
was the one path that surfaced a gap and walked away.

**Ordering is a safety property, not a preference.** Phase 3 must be fully complete
first: every mutation reverted, every production file verified byte-identical against
its temp copy. Only then does this step touch anything, and it touches **test files
only**. Production code is never edited by this skill — that guarantee is unchanged
(see Safety Guarantees 2).

Per `gap` survivor:

```
1. Add the missing assertion to the covering test file. Smallest change that
   would fail on the mutated behaviour — not a rewrite of the test.
2. Run the mapped tests unmutated. They must still PASS (a fix that breaks the
   green suite is reverted, not shipped).
3. Re-apply THAT ONE mutation, run the mapped tests, revert, verify byte-identical.
   The mutation must now be KILLED.
4. If it still survives after 2 attempts: stop attempting, leave the test change
   ONLY if step 2 stayed green, and record the survivor as `gap-unfixed` with what
   was tried. Two attempts, then honesty — not a third guess.
```

Record per survivor: `fixed` (killed on re-probe), `gap-unfixed` (cap reached), or
`equivalent` (never entered this loop).

`--report-only` skips this step entirely — for when you want the number and nothing
else. It is the ONLY way to skip it; "the fix looked big" is not one, and if a fix
genuinely spans several files it is a `gap-unfixed` with that stated as the reason.

Re-run the score after this step. The report and JSON below carry the POST-fix numbers,
with `score_triaged_before` kept alongside so the run's own effect is visible rather
than hidden by improving the thing being measured.

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

- [only if any `gap-unfixed` remains] zuvo:write-tests [file] -- the gap needed more than
  an assertion; name the mutation ID so the next run targets it
- [only if score is still low AFTER 4.2b] zuvo:fix-tests -- systematic anti-patterns, not
  single missing assertions (those were already fixed in this run)
- zuvo:mutation-test [file] --category [weakest] -- widen coverage to a category not sampled
Print NOTHING here when every gap was fixed and nothing is left — an empty next-steps list
is the honest output of a run that finished its own work.

Run: <ISO-8601-Z>	mutation-test	<project>	<score>%	<killed>/<total>	<VERDICT>	-	<N>-files	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

### 4.3b Machine-readable artifact (REQUIRED — not optional, and not for humans)

Write both files to the canonical output dir per `report-output-location.md`:

- `$ZUVO_DIR/audits/mutation-test-YYYY-MM-DD.md` — the block above
- `$ZUVO_DIR/audits/mutation-test-YYYY-MM-DD.json` — the contract below

Auto-increment `-2`, `-3` for same-day runs, like every other audit.

**This exists because Q21 had no input.** `gate-registry.md` Q21 asks whether changed
production files reach a mutation score >= 70%, and `test-audit` scores it — but until
2026-08-09 this skill wrote nothing to disk at all. The report went to chat and vanished,
so the only honest answers an auditor could give were a guess or `N/A`. A gate whose
input nobody produces is not a gate.

```json
{
  "version": "1.0",
  "skill": "mutation-test",
  "timestamp": "<ISO-8601>",
  "project": "<basename of git root>",
  "commit": "<HEAD sha7 — the code these numbers describe>",
  "scope": "<path or 'full'>",
  "tier2_ran": true,
  "fix_loop_ran": true,
  "result": "COMPLETE",
  "plan_completed": true,
  "mutations_planned": 8,
  "mutations_executed": 8,
  "per_run_cost_s": 1.4,
  "score_raw": 75,
  "score_triaged_before": 86,
  "score_triaged": 100,
  "tests_strengthened": ["__tests__/.../resync-units.test.ts"],
  "totals": { "generated": 8, "killed": 6, "survived_gap": 0, "survived_equivalent": 1, "gap_unfixed": 0 },
  "files": [
    {
      "path": "lib/services/proofreading/grouping/resync-units.ts",
      "killed": 6,
      "survived_gap": 1,
      "survived_equivalent": 1,
      "score_triaged": 86
    }
  ],
  "survivors": [
    {
      "id": "MUT-004",
      "file": "lib/services/proofreading/grouping/resync-units.ts",
      "line": 208,
      "category": "BOUNDARY",
      "triage": "gap",
      "outcome": "fixed",
      "reason": "ties pick the last unit instead of the first; no test constructs a tie",
      "fix": "added a two-unit tie case asserting the first-seen unit wins; re-probed KILLED"
    },
    {
      "id": "MUT-006",
      "file": "lib/services/proofreading/grouping/resync-units.ts",
      "line": 161,
      "category": "NULL",
      "triage": "equivalent",
      "reason": "segByEntryId is only .set()/.get(numeric); a null key is unreachable"
    }
  ]
}
```

Field notes, each earning its place:

- **`score_triaged` is the number consumers read.** `score_raw` is kept for comparison, not
  for gating — see 4.2.
- **`commit`** — these numbers describe one tree. A consumer reading a JSON whose `commit`
  is not the current HEAD must treat it as STALE and say so, not silently score against it.
  This is the same rule the review artifacts use, for the same reason.
- **`tier2_ran`** — `false` under `--quick`, where survivors were never checked against the
  full suite. A consumer must not treat a `--quick` score as equivalent coverage; label it.
- **`survived_equivalent`** must carry a `reason` naming how the value is consumed. Without
  it, "equivalent" becomes the escape hatch that turns any inconvenient survivor into a
  free pass.
- **`score_triaged_before` vs `score_triaged`** — the run improves the thing it measures, so
  the final number alone would hide its own effect. `before` is the score as found;
  `score_triaged` is after 4.2b. A consumer gating on quality reads `score_triaged`; a
  consumer asking "how good were the tests when we arrived" reads `before`.
- **`fix_loop_ran`** — `false` under `--report-only`, where `before` == `score_triaged` by
  construction. `gap_unfixed` counts survivors the loop tried and could not kill within its
  2-attempt cap; those are the only ones that belong in Recommended Next Steps.
- **`plan_completed` / `mutations_planned` vs `mutations_executed`** — the field a consumer
  checks BEFORE reading any score. `false` means the plan was truncated (3.3) and the score
  covers a sample; `result` is then `PARTIAL` and no gate may accept it. Without this a
  3-of-10 run is indistinguishable from a 10-of-10 run in the JSON.
- **`per_run_cost_s`** — the measured cost of one targeted run. It is in the artifact because
  it is the single number that explains a truncated plan: a value ~50x the local baseline
  means the tests were routed through a remote/offload wrapper, which this skill forbids
  (1.3). Diagnosing that from a bare "timeout" took a user a whole run.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion. Printing the markdown retro section without executing the bash leaves all three log files empty.

VERDICT: PASS (>= 80%), WARN (>= 60% and < 80%), FAIL (< 60%).
CQ_SCORE field: `<score>%` (the overall mutation score).
Q_SCORE field: `<killed>/<total>` (killed count / total mutations).
TASKS: `<N>` — the count of test files strengthened by the 4.2b fix loop; `-` under
`--report-only` or when every survivor was equivalent. It used to be hardcoded `-`
("no file modifications"), which stopped being true the moment the fix loop existed.
DURATION: `<N>-files` (number of production files tested).
NOTES: `mutation-test [scope] [grade]` (max 80 chars).

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
2. **A MUTATION never modifies a test file.** Mutations apply only to production code —
   mutating a test to make it pass would invert the entire measurement. The 4.2b fix loop
   DOES edit test files, deliberately and separately: it runs only after Phase 3 has
   reverted every mutation and verified production byte-identical, and it never touches
   production. Stating both halves because "never modify test files" read alone would
   forbid the step that closes the gaps this skill exists to find.
3. **Always verify restoration.** After each mutation, confirm the original file is intact.
4. **Timeout protection.** No single mutation test can run longer than 3x baseline per file.
5. **Clean state on exit.** If the skill is interrupted, restore through the Phase 3.1 temp-copy path — `cp /tmp/zuvo-mutation-[hash]-[filename] [file]` for every file still mutated, then delete the temp copies. Do **not** reach for `git stash pop` or `git checkout -- [file]`: §3.1 forbids both (pop consumes the stash on the first iteration; a bare `checkout --` discards uncommitted work that is not this skill's to destroy). `git checkout HEAD -- [file]` is the last resort named in §3.2 error recovery, valid only because Phase 3.1 verified the tree was clean at start — and it needs the user's go-ahead, since it is a destructive git operation.
6. **No side effects.** Mutations that would affect databases, external APIs, or file system state outside the project are not generated.
