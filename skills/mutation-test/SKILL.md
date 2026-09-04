---
name: mutation-test
description: >
  Mutation testing with two engines. Uses the project's NATIVE mutation runner
  (StrykerJS / Infection / mutmut / PIT / cargo-mutants) when one is configured —
  installing it on explicit consent when it is not — for a reproducible, comparable
  score; and an LLM-guided engine for the mutation classes native mutators cannot
  express: error-path removal, state mutation, async hazards, and security guard
  removal. Generates mutations, executes them against the relevant tests, and FIXES
  the tests whose gaps let a mutation survive — surviving mutants are closed in-run,
  not handed to another skill. Emits the cross-tool
  stryker-mutator.io/report.schema.json report alongside its own artifact.
  Flags: [path] (scope), full, --max N, --category, --runner auto|native|llm|hybrid,
  --break N, --no-install, --dry-run, --quick, --report-only.
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

Parse `$ARGUMENTS` as: `[path | full | continue] [--max N] [--category CATEGORY] [--runner MODE] [--break N] [--no-install] [--dry-run] [--quick] [--report-only]`

| Flag | Env equivalent | Effect |
|------|----------------|--------|
| `[path]` | — | Scope to a specific directory or file |
| `continue` | — | Resume an interrupted run from its checkpoint (Phase 3.0). Re-runs nothing already resolved. |
| `full` | — | All production files that have test coverage |
| `--max N` | — | Max total LLM mutations to execute (default: 50). Does not bound the native runner, which mutates exhaustively by design. |
| `--category CATEGORY` | — | Only generate LLM mutations of this category: `BOUNDARY`, `LOGIC`, `NULL`, `ERROR`, `STATE`, `ASYNC`, `SECURITY` |
| `--runner MODE` | `ZUVO_MUTATION_RUNNER` | `auto` (default) / `native` / `llm` / `hybrid` — see 0.1d |
| `--break N` | `ZUVO_MUTATION_BREAK` | Fail the run when the final `score_triaged` is below N% (4.2c — evaluated after the 4.2b fix loop, not at 4.1). The flag overrides the env value; both are recorded with their source. |
| `--no-install` | `ZUVO_MUTATION_NO_INSTALL=1` or `ZUVO_NO_INSTALL=1` | Never offer to install a mutation runner (disables the 0.1c consent gate). Detection still runs. |
| `--dry-run` | — | Generate mutations and show the plan, but do not execute any. Also suppresses 0.1c entirely. |
| `--quick` | — | Max 3 LLM mutations per file, max 20 total |
| `--report-only` | — | Report the score; do NOT fix surviving gaps (skips 4.2b). The only way to skip the fix loop. |

Flags can be combined: `zuvo:mutation-test src/services/ --max 30 --category SECURITY`

Default (no arguments): **the CHANGED production files**, not the whole project —
`git diff --name-only $(git merge-base HEAD <default-branch>)..HEAD` plus uncommitted production
files, filtered to those that have tests. Then `--max 50 --runner auto`. If that set is empty, say
so and stop; do NOT silently widen to everything.

`full` still exists and still means every covered production file — it just has to be asked for.

**Why the default moved.** Measured 2026-08-28 across the local fleet: the median mutation run is
**1 minute** and normal scoped runs top out around **31 minutes**, but 32 runs exceeded an hour and
the longest reached **258 minutes** — all from a main checkout, all unscoped, mutating a 2,784-file
test suite to answer a question about one module. Nothing was learned in those four hours that the
scoped one-minute run would not have said, and each one occupied a farm slot. A default that costs
four hours when the user meant "check what I just changed" is a defect in the default, not in the
farm that ran it.

**Callers must pass a scope.** `zuvo:refactor` and `zuvo:write-tests` probe mutation per file
(`--mutate <file>`) and are unaffected. Any skill invoking this one must name its file set; an
unscoped invocation from another skill is a bug in that skill.

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
  7. ../../shared/includes/terminal-state.md -- READ/MISSING (HARD: no completion over a live runner)
```

**If any file is missing:** Proceed in degraded mode. Note "DEGRADED -- [file] unavailable" in the final report.

## Environment Compatibility

**Dispatch is already authorized — do not ask, do not downgrade.** Invoking this skill IS the
request for every agent and gate it mandates, so a session rule about unprompted Agent use does not
apply here. Only a harness with NO dispatch capability takes the documented single-agent fallback,
and it still runs every gate inline — see `../../shared/includes/env-compat.md`. Skipping a mandated
agent and self-scoring the result is a substituted gate, not a degraded run.

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across all supported platforms.

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

### 0.1b Native mutation runner — DETECTION (read-only)

Every stack this skill supports has a maintained mutation runner. A project that already
configured one has a reproducible score this skill must READ rather than re-derive; the
LLM engine measuring a repo that ships `stryker.conf.json` with its own hand-rolled
mutants was the gap this step closes.

**Detection touches nothing.** It reads config files and manifests. No install, no write,
no command execution beyond a `--version` probe.

| Stack | Runner | Config signals (any one) | Scoped run | Machine-readable report |
|-------|--------|--------------------------|------------|--------------------------|
| TS / JS | StrykerJS ≥ 10 | `stryker.conf.{json,js,mjs,cjs}`, `stryker` key in `package.json`, `@stryker-mutator/core` in devDependencies | `npx stryker run --incremental --mutate <files>` | `--reporters json` |
| PHP | Infection ≥ 0.35 | `infection.json`, `infection.json5`, `infection.json.dist`, `infection/infection` in `composer.json` require-dev | `vendor/bin/infection --threads=max -- <paths>` (POSITIONAL — `--filter` is deprecated since 0.34) | `logs.json` key in `infection.json` (there is no `--logger-json` CLI flag) |
| Python | mutmut ≥ 3.7 | `[tool.mutmut]` in `pyproject.toml`, `[mutmut]` in `setup.cfg` | `mutmut run` — **whole project only**, see the mutmut note below | `mutmut results` |
| JVM (Java, Kotlin) | PIT ≥ 1.25 | pitest plugin in `pom.xml` / `build.gradle{,.kts}` | `mvn test-compile org.pitest:pitest-maven:mutationCoverage` (the `test-compile` phase is required — a bare goal has no compiled classes to mutate) or `./gradlew pitest` | `outputFormats=XML` |
| Rust | cargo-mutants ≥ 27 | `.cargo/mutants.toml`, or `cargo mutants --version` succeeds | `cargo mutants -f <file>` | `--json` (`mutants.out/`) |
| .NET / Scala | Stryker.NET / Stryker4s | `stryker-config.{json,yaml}` | per tool docs | Stryker JSON |

**mutmut 3.x cannot scope a run from the CLI.** `--paths-to-mutate` was a mutmut 2.x flag and was
REMOVED in 3.x — the error message still suggests it, which is how it survives in documentation
that was never re-tested. In 3.x the mutated paths come only from `[tool.mutmut] paths_to_mutate`
in `pyproject.toml` / `setup.cfg`. Consequences, and they are not cosmetic:

- A scoped native run on Python means **editing the project's mutmut config**, which is a write
  outside test files and therefore belongs to the 0.1c consent gate — not to a per-file loop.
  Until that is wired, treat Python native runs as **whole-project only**: run `mutmut run` as the
  project configures it, and take the score for the whole project rather than claiming a per-file
  number the tool cannot produce.
- `test-mutation-probes.md`'s per-file native path is therefore **unavailable for mutmut**. That
  include says so explicitly; a Python project falls back to the hand-picked probes there.

**Shell-quote every interpolated path.** These run commands are templates with `<file>`
placeholders, and a repository controls its own filenames — a path holding a space, a quote or a
`;` becomes argument injection the moment a template is pasted into a shell. Quote the
substitution (`--mutate '<file>'`) or pass the file list as separate argv entries; never build
the command by string concatenation and hand it to `bash -c`.

Versions are MINIMUMS, not pins — an older configured runner is still used, with its
version recorded. A runner present but BELOW the minimum is used and flagged
`native_runner.state: detected (below-minimum <ver>)`; do not silently upgrade a project's
tooling to satisfy a floor written here.

Record on the run and in the 4.3b artifact:

```
native_runner: { name, version, config_path, state }
state ∈ detected | installed | absent | declined | unsupported_stack | failed
```

### 0.1c Consent-gated install (skipped by `--no-install`, either no-install env var, and `--dry-run`)

> Mirrors the DD-3 consent gate in `skills/infra-audit/SKILL.md` — offer, consent, log with
> the uninstall command, degrade loudly on decline. The wording is deliberately parallel so
> the two can later be extracted into one shared include; they are not shared today, and
> unifying them is a separate change to a separate skill.
>
> `ZUVO_MUTATION_NO_INSTALL=1` is this skill's own switch. `ZUVO_NO_INSTALL=1` is honoured
> as a broader user policy, but **only this skill reads it today** — do not describe it to a
> user as a machine-wide guarantee.

Fires only when ALL hold: no runner detected, the stack HAS one, none of the suppressors above
is set, **and the engine is not `llm`**. `--runner llm` says the run will not touch a native
runner at all — prompting to install one it has already declined to use is a prompt for nothing,
and a consent prompt that appears when it cannot matter is how consent stops being read.
**One prompt per run — never per file.**

This is the only step in this skill that writes outside test files, so it is fenced
harder than anything else here:

1. **Print both commands before asking.** The exact install command AND the exact
   uninstall command, verbatim, so the consent is informed and reversible in one line.
2. **Dev scope only, and use the project's OWN package manager.** Never a runtime dependency,
   never `-g`/global for a project-scoped manager. Detect the manager from its lockfile
   (`pnpm-lock.yaml` → pnpm, `yarn.lock` → yarn, `package-lock.json` → npm) and use the matching
   row — running `npm i` in a pnpm or yarn workspace writes a competing `package-lock.json` and a
   nested `node_modules`, which is a lasting mess left behind by a tool that was only measuring:

   | Manager | Install | Uninstall |
   |---------|---------|-----------|
   | npm | `npm i -D @stryker-mutator/core @stryker-mutator/<jest\|vitest\|mocha>-runner` (pick the plugin matching the framework detected in 0.1) | `npm rm @stryker-mutator/core @stryker-mutator/<…>-runner` |
   | pnpm | `pnpm add -D @stryker-mutator/core @stryker-mutator/<…>-runner` | `pnpm remove @stryker-mutator/core @stryker-mutator/<…>-runner` |
   | yarn | `yarn add --dev @stryker-mutator/core @stryker-mutator/<…>-runner` | `yarn remove @stryker-mutator/core @stryker-mutator/<…>-runner` |
   | composer | `composer require --dev infection/infection` | `composer remove --dev infection/infection` |
   | uv | `uv add --dev mutmut` | `uv remove --dev mutmut` |
   | pip | `pip install mutmut` | `pip uninstall -y mutmut` |
   | cargo | `cargo install cargo-mutants` — **user-global toolchain, NOT the project's `Cargo.toml`.** Say that in the prompt. | `cargo uninstall cargo-mutants` |

3. **JVM is MANUAL and is never installed.** PIT is a build-plugin edit to `pom.xml` /
   `build.gradle.kts` — a change to how the project builds, not a dev dependency. Print
   the exact snippet, do NOT edit the build file, and record
   `state: absent (manual wiring required)`. A skill that edits a build file to measure
   test quality has exceeded its mandate.
4. **Config:** generate a MINIMAL config only when none exists, only for the consented
   tool, and only enough to run — no opinionated thresholds, no ignore-lists.
5. **Everything written is reported.** `installed_this_run[]` in the 4.3b artifact carries
   `{tool, version, command, uninstall, files_touched[]}`, and the completion block prints
   the uninstall line. A manifest or lockfile modified without appearing there is a bug.
6. **Failure and decline are loud, never silent.** Declined → `state: declined`. Install
   command exits non-zero → `state: failed` with its stderr. Both fall back to the LLM
   engine and label the run `native: skipped (<reason>)`. A run that wanted native and got
   LLM must never report as if it had a native score.

**Consent is a human decision and must stay one.** `--no-install` only ever makes a run
*more* conservative, so an agent may set it freely; there is deliberately no flag that
grants consent, because a flag an agent can type is not consent
(`no-agent-typable-bypass`). Non-interactive hosts therefore take the `declined` path.

### 0.1d Engine selection (`--runner`)

| Mode | Behaviour |
|------|-----------|
| `auto` (default) | Native if detected or installed; otherwise LLM. |
| `native` | Native only. Unavailable → **ABORT** with `BLOCKED_NO_NATIVE_RUNNER` naming why. Never silently falls back — that is the whole point of asking for it. |
| `llm` | The LLM engine only. This is the guaranteed floor and is unchanged from previous versions. |
| `hybrid` | Native for the score, PLUS LLM mutations restricted to `ERROR`, `STATE`, `ASYNC`, `SECURITY` — the classes syntactic mutators do not generate. Report both numbers separately; **never average them**, they measure different mutant populations over the same code. |

Two invariants hold in every mode:

- **Phase 4.2b still runs.** A native survivor is triaged and closed in-run exactly like an
  LLM survivor. A native runner's HTML report is a hand-off, and handing off is the drift
  this skill exists to stop.
- **The LLM engine is never removed.** It is the fallback for `absent`, `declined`,
  `failed`, and `unsupported_stack`, and it is the only engine for the four categories
  above.

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
  Native runner: [name vX.Y | none] ([detected <path> | installed | absent | declined | failed | unsupported_stack])
  Engine: [auto->native | auto->llm | native | llm | hybrid]
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

### 1.3 Send the TIER 1 loop to the farm as ONE invocation — never per-mutant, never local

**Wrap the LOOP, not each mutant.** The wrapper's cost is a fixed per-invocation charge
(mirror sync + queue), and Tier 1 makes N short invocations — so wrapping each one multiplies
the charge by N, while wrapping the loop pays it once:

    rt --light bash -c '<the whole mutant loop>'

An earlier version of this section concluded "therefore run Tier 1 locally". That was the
wrong lesson from a correct measurement, and 2026-08-29 measured what it costs: 109 local test
processes at 421% CPU, load 34, macOS suspending the workstation with `Dark Wake Thermal
Emergency`, and a native mutation run dying ten minutes in when a concurrent worktree pulled
shared `node_modules` out from under it — while the farm sat idle with ~18 free slots. Nothing
runs on the workstation.

Measured 2026-08-10 on the same single test file:

| Invocation | Wall clock |
|---|---|
| `npx vitest run <file>` | **1.4 s** (2.2 s cold) |
| `rt npx vitest run <file>` | **103.4 s** |

~50-75x, and a single wrapped call alone exceeds the whole run budget below. A
10-mutant plan that would finish in ~20 s locally cannot complete a single mutant
through the wrapper. Wrap the LOOP once instead and the same ten mutants pay one charge.
If the farm is unreachable (`rt` exits 21), this skill is not usable for that run — say so
and stop; never move the loop to the workstation, and never report a wrapper timeout as a
test-quality result.

**Tier 2 is the opposite case, and the ban used to swallow it.** A Tier 2 pass is ONE
long full-suite run — exactly the shape the global `rt` rule was written for — and the
budget formula in 1.3b already accounts for it separately (`TIER2_RUNS * BASELINE_TIME`,
never `PER_RUN`). The routing rule simply did not follow its own split. Measured
2026-08-17 on `rs_be`, same suite, same commit:

| Tier 2 full suite | Wall clock |
|---|---|
| local, 4 passes in one run | 673 s + 270 s + 323 s + 312 s = **1578 s** |
| farm, warm mirror + cache hit | **142–264 s** per pass (deps 2–4 s, setup < 0.8 s) |

**Route Tier 2 by `BASELINE_TIME`, measured in 1.2, not by habit:**

- `BASELINE_TIME >= 120s` → run Tier 2 through `rt` (`rt --light` when the suite needs no
  services). The one-time mirror/queue charge is amortised across a run that long, and it
  takes the heaviest load off the workstation that is also running the Tier 1 loop.
- `BASELINE_TIME < 120s` → keep Tier 2 local. Below that the wrapper's fixed cost is a
  large fraction of the run and the farm wins nothing.

Record which side the run took and why: `tier2_runner: "rt (baseline 187s)"` or
`tier2_runner: "local (baseline 41s)"`. A Tier 2 result whose runner is unstated cannot be
compared against the next run's.

**Three rules that do not relax when Tier 2 goes to the farm:**

1. **Restoration stays local and unconditional.** The farm run is read-only with respect to
   the working tree: `rt` ships the tree as it stands (mutation applied) and the verdict comes
   back, but the `cp` restore in 3.2 step 4 and the hash verify in step 5 happen here, on this
   machine, exactly as before. Never let a remote step own the restore.
2. **A wrapper failure is not a mutation result.** `rt` exiting non-zero for a queue timeout,
   an evicted run, or an unreachable host means the mutation was **not measured** — it is
   neither killed nor survived. Re-run it on the farm once; if that also fails, the mutant is
   `NOT_EXECUTED` and the plan is incomplete under 3.3, not scored around.
3. **`TEST_RAN` discipline applies to the farm too.** A farm run that is evicted or never
   scheduled exits 0 having run nothing, and "0 failures" from a suite that did not execute
   reads as a SURVIVED mutation — the single most expensive misread this skill can make. Require
   a summary line proving the suite executed before recording any Tier 2 verdict.

**Off-tailnet, `rt` refuses with exit 21** rather than running locally. That is a routing
failure, not a test result: fall back to a local Tier 2 pass for the rest of the run and note
`tier2_runner: "local (rt unreachable)"`.

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
  Runner:        rt (farm)   (the whole loop in ONE invocation — see 1.3)
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

1. **Require cleanliness only where it actually matters: the files that will be MUTATED.**
   `git status --porcelain -- <each production file in scope>` must be empty. Those are the only
   files where the post-run hash check cannot tell a leftover mutant from an edit of yours, which
   is the entire hazard this step exists for.
   - Dirty scoped file → `BLOCKED_DIRTY_TREE`, naming it. Do not mutate it.
   - **Uncommitted changes ANYWHERE ELSE are not a blocker.** Record their sha256 with the rest of
     the pre-run snapshot and proceed. Demanding a globally clean tree blocked runs on the
     pipeline's OWN output — the test file `zuvo:write-tests` had just written and
     `memory/coverage.md` — which is a gate firing on the work it was invoked to measure.
   - **Never stop to ask permission to commit.** If this run authored those files, the auto-commit
     policy already covers them; if they are the user's, they are none of this skill's business.
     A question here costs a whole turn and the answer is always the same.
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

### 3.2b Native runner execution (`--runner native` / `hybrid` / `auto` when one is available)

The native runner replaces the 3.2 loop for the mutants it generates; it does not replace
any rule around that loop. Run it scoped to the SAME file set built in 0.2, and inherit
every constraint below without exception:

1. **ON THE FARM, in an isolated checkout — reversed 2026-08-29 by measurement.** This rule
   used to say "local, always", and following it is what produced the incident below. A native
   run is the single heaviest thing this repo starts: one long-lived process re-running the
   suite once per mutant, 730 mutants and ~24 minutes in the case that broke.

   What actually happened when it ran locally: the worktree's `node_modules` was shared with
   another worktree, the other run moved underneath it, and Stryker died ten minutes in on
   vanished dependencies (`mutation-testing-report-schema`, `balanced-match`) — a crash that
   looks like a test failure and is not. At the same moment the laptop carried 109 local test
   processes at 421% CPU and load 34, macOS was putting it to sleep with `Dark Wake Thermal
   Emergency`, and the farm sat idle with ~18 free slots.

   The old justification was 1.3's per-invocation wrapper overhead — real, and it does not
   apply here. 1.3 measures a wrapper charge paid PER SHORT CALL; a native run pays it ONCE
   across twenty-plus minutes, where it rounds to nothing. Send it to the farm:

       rt npx stryker run <config>          # or the project's own native runner

   **Generate `<config>` with the helper — do NOT hand-roll it and do NOT rely on `--mutate`.**

       bash "$ZUVO_BASE/scripts/stryker-scoped-config.sh" \
         --file <f1> --file <f2> ...        # or --files-from <list>, from the 0.2 scope set

   It prints `config_path`, `report_path`, `temp_dir`, `test_runner`, `coverage_analysis`,
   `mutate_count` and a ready `run_command`. `mutate_count` is a check, not decoration: Stryker
   reports an empty mutate set as a **successful run with a 100% score**, so a typo in the scope
   set is indistinguishable from a perfect suite unless the count is read.

   "Scoped Stryker config" is the most re-invented artifact in this fleet's retro log (~30 names
   for one thing), because it is five decisions that each fail SILENTLY:

   - **`--mutate` alone does not scope the run.** Stryker still loads the project config, which
     routinely carries a repo-wide `mutate` array, its own reporters, its own `tempDirName`. The
     CLI flag merges over one key; the rest still applies.
   - **`.stryker-tmp` is shared by every run in the repo.** Two scoped runs on one box corrupt
     each other's sandbox, and it surfaces as dependencies vanishing mid-run
     (`Cannot find module 'balanced-match'`) — which reads as a test failure and is not. This is
     the same incident rule 1 above was reversed for; the config is the other half of the fix.
   - **`coverageAnalysis: perTest` mismarks module-level ("static") mutants as SURVIVED**, because
     per-test coverage cannot attribute code that ran at import time. The helper defaults to
     `off` for that reason. That default REDUCES the number of false survivors; it does not make
     4.2's re-probe optional, which is unconditional for every native survivor regardless of this
     setting — a project's own config, an incremental run, or a test filter can each produce a
     survivor the tests would in fact kill.
   - **The report must land outside the sandbox**, or a farm run discards the only copy of the
     measurement along with its checkout.
   - **next/jest and vitest need different wiring**, and the wrong one fails at startup with an
     error naming the test framework rather than the config.

   Two consequences that are not optional:
   - **The farm gives it the isolation the laptop cannot.** A farm run ships the tree as it
     stands into its own checkout, so a concurrent worktree cannot pull dependencies out from
     under it. That is not a nicety here — it is the failure that was observed.
   - **Rule 4's tree verification still happens on THIS machine**, against the pre-run hash,
     exactly as before. A farm run is read-only with respect to your working tree, which makes
     that check simpler, not harder.

   Record `tier2_runner: "rt (native)"`. The only local escape is `TF_ALLOW_LOCAL=1` with a
   stated reason — the farm unreachable, or debugging the farm itself — and it must appear in
   the report, because a local native run is what this rule exists to prevent.
2. **Budget it in 1.3b terms.** A native run is one long invocation, so it is budgeted like
   a Tier 2 pass (`BASELINE_TIME`-scaled), never like `MUTATION_COUNT * PER_RUN`. If the
   budget cannot hold one full native pass, shrink the SCOPE (fewer files) — never the
   budget, and never report a killed native run as a score.
3. **Reap it.** `terminal-state.md` governs: record the PID at launch, and on EVERY exit
   path — completion, budget abort, user interrupt — `wait` for it or terminate it and say
   how. `runners.launched` must equal `runners.reaped`. This is the shape that once left a
   Jest process alive for 679 minutes, and a native runner is strictly more likely to
   produce it.
4. **Take a full backup BEFORE it starts, and NEVER auto-restore afterwards.**
   - **Before:** the 3.1 per-file temp copies are not enough — a whole-project runner can mutate
     files outside the 0.2 scope, and those have no temp copy at all. Snapshot the **whole tree**
     instead: `git stash create` (a commit object, not a stash entry — nothing to pop, nothing to
     consume) and record the SHA, or `cp -a` the working tree to a temp dir when the project is
     not a git repo. Record the pre-run sha256 of every scoped file too.
   - **After (every path, including abort):** re-hash. Clean the runner's own debris first —
     `.stryker-tmp/`, `mutants.out/`, `.mutmut-cache/`, generated HTML reports — then compare.
   - **On mismatch: STOP. Do not restore anything automatically.** A native run is long-lived, and
     a hash mismatch cannot distinguish a leftover mutant from the user saving a file in their
     editor, a formatter, or a `git pull` that landed mid-run. Overwriting from an hours-old
     snapshot would destroy real work to tidy up after a measurement. Emit `BLOCKED_DIRTY_TREE`
     naming each differing file and the exact recovery command
     (`git restore --source=<stash-sha> -- <file>`), and let the human choose. Do not score, do
     not `git checkout --`, do not `git stash pop`.
5. **A crashed runner is not a result — and neither is a partial one.** Require ALL of: exit code
   0, a report file that exists and parses, a non-zero mutant count, AND coverage of every scoped
   file from 0.2. A runner killed by OOM/SIGKILL/disk-full can leave a well-formed report over a
   fraction of the scope; scoring that yields a reproducible-looking number computed on whichever
   subset happened to finish, which `--break` and the grade would then treat as the whole. Any
   condition unmet → `native_runner.state: failed`, fall back per 0.1d, and label it.

**Read the report in the runner's OWN format — not all of them emit JSON.** 0.1b's last column
names the format per runner: Stryker and cargo-mutants produce JSON, PIT produces XML, Infection
writes JSON only when `logs.json` is configured, mutmut reports as text. Parse the format that
runner actually produces and map it inward; expecting JSON universally would mark healthy Java and
Python runs `failed` and fall back to the LLM engine for no reason.

Map its mutants into this skill's records: each becomes a survivor or a kill with its own
`mutatorName` preserved (do not re-label them into the seven LLM categories — they are a different
taxonomy and flattening them destroys the distinction `hybrid` exists to make). Survivors then
enter 4.2 triage and 4.2b gap-closing unchanged.

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

0. **Reap the runner BEFORE writing anything.** The abort path is where the 679-minute Jest
   process came from (safety rule 5): the loop stopped issuing mutations while a Tier 2 pass it
   had already launched was still running, and nothing went back for it. For every PID recorded
   this run, `kill -0` it; if alive, terminate it and record how. Then restore the mutated file,
   then write the partial report. A `PARTIAL` report published over a still-running suite is
   describing a tree that is still changing underneath it.

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

**Under `--runner hybrid` this formula is WRONG and must not be used.** Native and LLM mutants
are two different populations over the same code — the native runner enumerates its mutators
exhaustively, the LLM engine samples up to `--max` deliberately-chosen ones — so pooling them
produces a number whose value depends on the ratio between two sample sizes, not on the tests.
0.1d says "never average them"; this is where that is enforced rather than merely asserted.

In `hybrid`, compute and report TWO scores, each over its own population:

```
score_native = killed_native / (killed_native + survived_native) * 100
score_llm    = killed_llm    / (killed_llm    + survived_llm)    * 100
```

- Grade, verdict, and `--break` (4.2c) require **BOTH halves to clear the bar** — the hybrid
  verdict is the WORSE of the two, never the native one alone. Gating on `score_native` by itself
  would be the failure hybrid exists to prevent: the LLM half is the only engine generating the
  error-path, state, async and security-guard mutants, so a suite that ignores exactly those
  would pass on an inflated native number while the mutants that matter survived unexamined.
- Both numbers are reported, separately labelled. They are never combined into a third figure —
  "worse of the two" is a selection, not an average.
- A `hybrid` run whose native half failed (`native_runner.state: failed`) is not a hybrid run: it
  degrades to `engine: llm`, `score_llm` becomes the graded score, and the report says so.

In `native` and `llm` modes there is one population and the single formula above is correct.

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

**A NATIVE runner's survivor is a candidate, not a finding — re-probe it physically first.**
A survivor from the LLM engine was already produced by executing the mutation, so it needs no
re-probe. A survivor from Stryker/PIT/Infection may be an artifact of the run's own settings:
under `coverageAnalysis: perTest` a module-level ("static") mutant is reported SURVIVED because
per-test coverage cannot attribute code that executed at import time — the tests may kill it
perfectly well. Settle it by running it, not by reasoning about the report:

```bash
bash "$ZUVO_BASE/scripts/mutation-survivor-reprobe.sh" \
  --label MUT-007 --file <production file> \
  --original '<exact current text>' --mutated '<mutated text>' \
  --test-cmd '<the mapped tests for that file>'
# exit 0 = KILLED (run artifact, drop it) · 1 = SURVIVED (real gap) · 3 = ERROR (no verdict)
```

It is content-anchored (2.3b), refuses an ambiguous or missing anchor, refuses a dirty target
file, restores on every exit path including signals, and verifies the restore by hash before
reporting. A timeout returns ERROR, never KILLED — a suite that never finished says nothing
about whether it would have caught the mutant, and reading its non-zero exit as a kill
manufactures coverage out of an infrastructure failure.

Record `reprobe: killed|survived|error|n/a (llm engine)` per native survivor. A native survivor
that has not been re-probed may not enter triage below, may not be counted as a `gap`, and may
not appear in 4.2b's fix loop. This step is what the retro log's largest single burn
(140 turns in one session) was spent inventing from scratch.

**How each outcome folds into the score** (state it, or two runs of the same code report
different numbers):

| `reprobe` | Effect on `score_triaged` | Rationale |
|---|---|---|
| `killed` | counts as **KILLED** (numerator and denominator) | the physical re-run proved the suite kills it; the report's SURVIVED was the artifact |
| `survived` | stays a survivor, enters triage as `gap` or `equivalent` | confirmed by execution |
| `error` | **excluded from both** — and named in the report | no verdict exists; counting it either way invents one |
| `n/a (llm engine)` | unchanged — the LLM engine already executed it | no native report to correct |

Carry the counts in the 4.3b artifact as `reprobe: { killed, survived, error }` alongside
`score_raw`, so a reader can see how much of the triaged score came from correcting the native
report rather than from the tests changing.

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

### 4.2c Break threshold (`--break N` / `ZUVO_MUTATION_BREAK`)

Evaluated HERE and nowhere earlier. `score_triaged` is not final until 4.2b has run, so a
break checked at 4.1 would fail runs on a number the run was about to improve — the
phase-boundary rule: enforce a field after the phase that fills it, not before.

No threshold set → this step is a no-op; say nothing.

**Skip this step entirely when `result == PARTIAL` (3.3).** A break check is a grade, and 3.3 is
explicit that a truncated plan gets `PARTIAL`, never PASS/WARN/FAIL. Without this guard a run can
emit `"result": "PARTIAL"` and `VERDICT: FAIL` in the same artifact — failing a suite on a score
computed over the three mutants that happened to fit in the budget. Print instead:

```
MUTATION BREAK: not evaluated — plan incomplete (<executed>/<planned>, stopped by <reason>)
  a threshold cannot grade a sample. Re-run with a larger budget or a smaller --max.
```

and leave the verdict as `PARTIAL`. The threshold was not met and was not missed; it was not asked.

```
if result == PARTIAL:  skip (see above)
elif score_triaged < N:
    1. write the 4.3 report AND both 4.3b artifacts FIRST   # never lose the evidence
    2. run 4.3a terminal-state gate                          # never leave a runner alive
    3. print MUTATION BREAK instead of MUTATION TEST COMPLETE
    4. run-log VERDICT = FAIL
```

```
MUTATION BREAK — score_triaged <N>% is below the configured threshold <N>%
  threshold source: <env ZUVO_MUTATION_BREAK | flag --break | default>
  gap-unfixed survivors: <N>   equivalent: <N>
  report: <path>
```

**Record where the threshold came from.** `break_threshold: {value, source}` in the
artifact. A threshold is a bar someone set; an agent that picks its own N and then clears
it has measured nothing, and the `source` field is what makes that visible rather than
invisible (`no-agent-typable-bypass`). An agent MAY lower N or omit it — that only makes
the run report more — but a run whose `source` is `flag` when a stricter env value existed
must say so.

### 4.3a Terminal-state gate (before ANY completion banner)

Print this with the evidence filled in. It is not a checkbox that is always ticked:

```
[ ] Terminal state A (terminal-state.md): runners launched = N, still alive = 0   (PIDs + how each ended)
[ ] Terminal state B: external checks triggered = N, unconcluded = 0   (run IDs + conclusions)
[ ] Terminal state C: artifacts created = N, not landed = 0   (PR/branch/tag + its state)
```

Any non-zero count means `MUTATION TEST INCOMPLETE` naming what is outstanding, never the banner
below. Shape A is the one this skill produces most: a Tier 2 full suite launched for a surviving
mutant and left running. Measured 2026-08-16/17 — a Jest process stayed alive **679 minutes**
after the task reported done, burning cores against the global worker cap for eleven hours.

### 4.3 Report Output

```
MUTATION TEST COMPLETE
===============================================
Project: [name]
Date: [ISO-8601 date]
Engine: [native <name> v<ver> | llm | hybrid]  ([detected <path> | installed | absent | declined | failed | unsupported_stack])
Score:  [N]%  [under hybrid ONLY: native [N]% (graded) | llm [N]% (reported, not graded)]
Installed this run: [none | <tool> — remove with: <uninstall command>]
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

Write all three files to the canonical output dir per `report-output-location.md`:

- `$ZUVO_DIR/audits/mutation-test-YYYY-MM-DD.md` — the block above
- `$ZUVO_DIR/audits/mutation-test-YYYY-MM-DD.json` — the zuvo contract below
- `$ZUVO_DIR/audits/mutation-test-YYYY-MM-DD.report.json` — the CROSS-TOOL report (4.3c)

Auto-increment `-2`, `-3` for same-day runs, like every other audit.

**This exists because Q21 had no input.** `gate-registry.md` Q21 asks whether changed
production files reach a mutation score >= 70%, and `test-audit` scores it — but until
2026-08-09 this skill wrote nothing to disk at all. The report went to chat and vanished,
so the only honest answers an auditor could give were a guess or `N/A`. A gate whose
input nobody produces is not a gate.

Q21's registry row now names this artifact as its input, so the two are no longer
independent sentences free to drift apart: move this file, or rename `score_triaged` /
`plan_completed` / `commit`, and the Q21 row must change with it. Nothing mechanical
enforces that pairing — this paragraph is the reminder that it exists.

```json
{
  "version": "1.0",
  "skill": "mutation-test",
  "timestamp": "<ISO-8601>",
  "project": "<basename of git root>",
  "commit": "<HEAD sha7 — the code these numbers describe>",
  "scope": "<path or 'full'>",
  "tier2_ran": true,
  "tier2_runner": "local",
  "engine": "hybrid",
  "native_runner": {
    "name": "stryker",
    "version": "10.0.0",
    "config_path": "stryker.conf.json",
    "state": "detected"
  },
  "installed_this_run": [],
  "break_threshold": { "value": 70, "source": "env" },
  "baseline_time_s": 41.2,
  "runners": { "launched": 4, "reaped": 4, "terminated_at_abort": 0 },
  "fix_loop_ran": true,
  "result": "COMPLETE",
  "plan_completed": true,
  "mutations_planned": 8,
  "mutations_executed": 8,
  "per_run_cost_s": 1.4,
  "score_raw": 75,
  "score_triaged_before": 86,
  "score_triaged": 100,
  "scores_by_engine": {
    "native": { "score_triaged": 100, "killed": 41, "survived_gap": 0, "survived_equivalent": 2 },
    "llm":    { "score_triaged": 92,  "killed": 11, "survived_gap": 1, "survived_equivalent": 0 }
  },
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
  means the Tier 1 loop was routed through a remote/offload wrapper, which 1.3 forbids.
  Diagnosing that from a bare "timeout" took a user a whole run.
- **`tier2_runner`** — `local` or `rt`, with the `BASELINE_TIME` that decided it (1.3). Two
  Tier 2 results measured on different runners are not comparable wall-clock, and a survivor
  confirmed by an evicted farm run is not a survivor at all.
- **`runners`** — `launched` must equal `reaped` (safety rule 5). This field exists because the
  count was invisible: a run that left a full suite alive for 679 minutes produced a report
  indistinguishable from a clean one. `reaped < launched` makes the artifact self-invalidating.
- **`engine` + `native_runner`** — WHICH engine produced these mutants, and whether the number
  is reproducible by anyone else. A score from a configured StrykerJS can be re-derived by a
  colleague running `npx stryker run`; a score from the LLM engine cannot, because the mutant
  population is regenerated each time. Two scores are comparable only when their `engine` and
  `native_runner.name` match. `state` also records the honest reason for an LLM fallback —
  `declined` and `failed` are different facts and neither may be reported as `absent`.
- **`installed_this_run`** — every tool this run added to the project, with the command that
  removes it again. This is the ONLY field in the artifact that describes a write outside test
  files, which is exactly why it is mandatory and why the completion block repeats it: a
  manifest or lockfile changed by a measurement skill must never be something the user
  discovers from `git status`.
- **`scores_by_engine`** — present ONLY under `engine: hybrid`, `null` otherwise. It exists because
  `score_triaged` is a single field and hybrid has two populations that must not be pooled (4.1):
  without somewhere else to put the second number, the schema itself would force the averaging
  0.1d forbids. Under hybrid, `score_triaged` at the top level MIRRORS `scores_by_engine.native`
  — the graded, reproducible half — and never a blend of the two.
- **`break_threshold`** — `{value, source}` where source is `env` / `flag` / `default`. The value
  alone is not enough: an agent that sets its own bar and then clears it has proved nothing, and
  only the source makes that legible. `null` when no threshold was configured.

### 4.3c Cross-tool report (`*.report.json`) — the comparability artifact

The zuvo JSON above is zuvo's own shape and nothing else reads it. The mutation-testing
ecosystem has ONE shared format, `http://stryker-mutator.io/report.schema.json` (JSON Schema
draft-07), and its `framework.name` examples name Stryker, Stryker4s, Stryker.NET, Infection
PHP and Pitest — five tools across five stacks. Emitting it is what makes a zuvo score
comparable with a score produced by any of them, and what lets an existing mutation-report
viewer open our output.

Required roots: `schemaVersion`, `thresholds{high,low}`, `files{}`. Also emit `framework`
(`{name: "zuvo:mutation-test", version: <zuvo version>}`) and `performance`.

```json
{
  "schemaVersion": "1",
  "thresholds": { "high": 80, "low": 60 },
  "projectRoot": "<abs path to git root>",
  "framework": { "name": "zuvo:mutation-test", "version": "<zuvo version>" },
  "files": {
    "lib/services/proofreading/grouping/resync-units.ts": {
      "language": "typescript",
      "source": "<full file source>",
      "mutants": [
        { "id": "MUT-004", "mutatorName": "zuvo:BOUNDARY", "replacement": "count >= bestCount",
          "location": { "start": { "line": 208, "column": 9 }, "end": { "line": 208, "column": 28 } },
          "status": "Killed" }
      ]
    }
  }
}
```

Three rules that make it honest rather than decorative:

1. **Map, do not invent.** `status` is a closed enum of EIGHT values — `Killed`, `Survived`,
   `NoCoverage`, `CompileError`, `RuntimeError`, `Timeout`, `Ignored`, `Pending`. Map this
   skill's outcomes onto it exactly:

   | This skill | Schema status | Why |
   |------------|---------------|-----|
   | killed / killed-indirect | `Killed` | — |
   | survived (`gap`) | `Survived` | — |
   | survived (`equivalent`) | `Ignored` | `Ignored` means excluded from scoring with a reason — which is what an equivalent-mutant triage IS. Never `Killed`. |
   | TIMEOUT | `Timeout` | counted as killed in 4.1, but the schema keeps it distinct |
   | mutation did not compile | `CompileError` | — |
   | mutation crashed the runner at test time | `RuntimeError` | distinct from `CompileError`; without this row an agent mis-files a crash as one of the other two |
   | `not_run` from a truncated plan (3.3) | `Pending` | the honest status for a mutant the budget never reached — do NOT omit it, or the report silently shrinks the denominator |
2. **`mutatorName` is namespaced by origin.** LLM mutants carry `zuvo:<CATEGORY>`; native
   mutants keep the runner's own name verbatim (`BooleanLiteral`, `ArithmeticOperator`, …). A
   reader must be able to tell which engine produced a mutant, and a flattened taxonomy destroys
   exactly the distinction `hybrid` exists to make.
3. **A native run's report is MERGED, not re-derived.** When the native runner already wrote a
   conforming report, read it and merge this run's LLM mutants into its `files` map — do not
   regenerate its entries from our own records. Re-deriving would silently replace the runner's
   ground truth with our transcription of it.

`thresholds.low`/`high` come from the 4.1 grade bands (60 / 80), NOT from `--break` — the break
threshold is a run verdict, the schema thresholds are report colouring, and conflating them makes
the report lie about the project's standard.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

**Append via wrapper (REQUIRED).** Never `>>` directly to `~/.zuvo/runs.log` — the wrapper is the gate that verifies a retro entry exists for this run. Order: retro bash executed → wrapper invoked → completion claimed.

```bash
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
```

Expected stdout: `OK: appended to runs.log (retro verified for <skill> on <project>)`. If exit 2 with `RETRO_REQUIRED` — go execute the retro bash from `retrospective.md` first; never bypass with `ZUVO_SKIP_RETRO_GATE=1`. After the wrapper succeeds, print a `Logs:` evidence line (`tail -1 ~/.zuvo/retros.log`, `grep -c "^<!-- RETRO -->" ~/.zuvo/retros.md`, `tail -1 ~/.zuvo/runs.log`) before claiming completion. Printing the markdown retro section without executing the bash leaves all three log files empty.

VERDICT: PASS (>= 80%), WARN (>= 60% and < 80%), FAIL (< 60%). A configured `--break N` that
the run misses forces FAIL regardless of band (4.2c) — the threshold is a stricter bar someone
chose, so it may only lower the verdict, never raise it.
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
2. **A MUTATION never modifies a test file** — and this skill never edits production code
   *(one carve-out: the 0.1c consent-gated write to a dependency manifest / lockfile / runner
   config, spelled out in Guarantee 7. Stated here because 4.2b sends readers to this
   guarantee in isolation, where an unqualified absolute would be a lie)*. Mutations apply only to production code —
   mutating a test to make it pass would invert the entire measurement. The 4.2b fix loop
   DOES edit test files, deliberately and separately: it runs only after Phase 3 has
   reverted every mutation and verified production byte-identical, and it never touches
   production. Stating both halves because "never modify test files" read alone would
   forbid the step that closes the gaps this skill exists to find.
3. **Always verify restoration.** After each mutation, confirm the original file is intact.
4. **Timeout protection.** No single mutation test can run longer than 3x baseline per file.
5. **Clean state on exit — files AND processes.** If the skill is interrupted, restore through the Phase 3.1 temp-copy path — `cp /tmp/zuvo-mutation-[hash]-[filename] [file]` for every file still mutated, then delete the temp copies. Do **not** reach for `git stash pop` or `git checkout -- [file]`: §3.1 forbids both (pop consumes the stash on the first iteration; a bare `checkout --` discards uncommitted work that is not this skill's to destroy). `git checkout HEAD -- [file]` is the last resort named in §3.2 error recovery, valid only because Phase 3.1 verified the tree was clean at start — and it needs the user's go-ahead, since it is a destructive git operation.

   **And reap every runner you started** — see `../../shared/includes/terminal-state.md`. This rule
   used to cover files only, and a Tier 2 full suite launched by an aborted run stayed alive for
   **679 minutes** after the skill reported done (measured 2026-08-17): the loop stopped issuing
   mutations on the budget and never went back for the process it had already started. Record each
   runner's PID at launch, and on EVERY exit path — completion, budget abort, restore-failure abort,
   user interrupt — either `wait` for it or terminate it (`kill -TERM`, then `-KILL` after a grace
   period) and say so in the report. Never `pkill -f jest`/`vitest`: this is a workstation running
   ~40 repos and a name match kills other people's runs.
6. **No side effects.** Mutations that would affect databases, external APIs, or file system state outside the project are not generated.
7. **The consent gate is the ONLY write outside test files, and it is never implicit.** 0.1c is
   the single step that may add a dev dependency, a lockfile entry, or a runner config. It
   requires an explicit human yes for that run, prints the uninstall command before asking, and
   records everything in `installed_this_run[]`. There is deliberately **no flag that grants
   consent** — a flag an agent can type is not consent, so a non-interactive host declines and
   runs the LLM engine. `--no-install` and either no-install env var suppress the offer
   entirely. Build files (`pom.xml`, `build.gradle*`) are never edited under any consent: the
   JVM path prints its snippet and stops.
8. **A native runner mutates the tree itself, so the tree is verified after it.** The 3.1
   temp-copy protocol only covers mutations this skill wrote. Every scoped production file is
   sha256-compared against its pre-run hash after the native runner exits, on every path
   including abort. A mismatch is `BLOCKED_DIRTY_TREE` — restore, report, do not score.
