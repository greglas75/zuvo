---
name: tests-performance
description: >
  Test suite performance audit and optimization. Measures baseline timing,
  audits runner configuration against TP1-TP17 checklist, identifies the
  slowest tests, and produces an impact-ranked action plan. Modes: full
  audit (default), baseline (measure only), verify (compare to saved
  baseline), --no-run (config audit only), --path <dir> (monorepo scope).
---

# zuvo:tests-performance — Test Suite Performance Audit

Measurement-driven optimization of the test suite. Establishes a baseline, audits the runner configuration, identifies slow tests, and ranks fixes by expected impact.

**Scope:** Test suite speed and runner configuration. Reducing wall-clock time of the test suite.
**Out of scope:** Test quality (use `zuvo:test-audit`), flaky test investigation (use `zuvo:fix-tests`), CI pipeline optimization (use `zuvo:ci-audit`), test correctness issues (use `zuvo:fix-tests`).

## Core Principles

1. **Measure before and after.** No measurement means no improvement claim.
2. **Config changes before code changes.** A 5-minute config fix often outperforms a 2-hour test rewrite.
3. **Rank by impact, not effort.** Present changes in expected-speedup order.
4. **Runner-specific, not generic.** Jest advice for Vitest projects causes harm.
5. **Recommended values are hypotheses.** Impact ranges are starting points -- always verify with before/after measurement.

---

## Argument Parsing

| Argument | Behavior |
|----------|----------|
| _(empty)_ | Full audit: baseline + config audit + slow scan + action plan |
| `baseline` | Phase 1 only: measure and save baseline |
| `verify` | Phase 5 only: re-measure and compare to saved baseline |
| `--no-run` | Skip test execution, audit config only (Phase 2-4) |
| `--path <dir>` | Scope runner detection and test execution to a specific directory |

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for progress tracking and user interaction patterns.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 3 | Test file inventory | `get_file_tree(repo, name_pattern="*.test.*")` | `find` + `wc -l` |
| 3 | Test structure per file | `get_file_outline(repo, file_path)` | Read the file |
| 3 | Batch-read setup blocks | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |
| 3 | Detect slow patterns | `search_text(repo, query="setTimeout|sleep|waitFor", regex=true, file_pattern="*.test.*")` | Grep |
| 3 | Heavy setup detection | `search_text(repo, query="beforeEach.*prisma|beforeAll.*seed", regex=true, file_pattern="*.test.*")` | Grep |
| 3 | Trace expensive setup calls | `trace_call_chain(repo, symbol_name=<setup_fn>, direction="callees", depth=2)` | Skip |

---

## Phase 0: Detect Runner

One runner per audit. If the project uses multiple runners, run this skill once per runner.

### Detection Priority

1. If `--path <dir>` provided, scope detection to that directory only
2. Check the directory containing the nearest `package.json` to cwd
3. Fall back to nearest config file to the search root
4. If multiple runners at the same depth, list them and ask which to audit

### Runner Signals

| Signal | Runner |
|--------|--------|
| `vitest.config.*` or `vitest.workspace.*` | Vitest |
| `jest.config.*` or `jest` key in `package.json` | Jest |
| `pytest.ini`, `setup.cfg`, or `[tool.pytest]` in `pyproject.toml` | pytest |

```bash
# Detection script (scope-aware)
SEARCH_ROOT="${path_arg:-.}"
find "$SEARCH_ROOT" -maxdepth 5 -not -path "*/node_modules/*" -not -path "*/.git/*" \
  \( -name "vitest.config.*" -o -name "jest.config.*" -o -name "pytest.ini" \) 2>/dev/null
```

If multiple configs found, warn: `WARNING: N runner configs found. Use --path <dir> to target a specific package.`

### Read Config File

Read the detected config file fully. Extract current values for all TP items. Record which settings are explicitly set versus defaulted.

---

## Phase 1: Baseline Measurement

**Skip if `--no-run` was specified.**

### Run Suite (3x Normal, 2x for Slow Suites)

Run the full test suite 3 times. The first run warms caches; use the median of all 3.

**Slow suite escape hatch:** If the first run exceeds 60 seconds, run exactly 2 total (1 warmup + 1 measured). Mark baseline as `runs: 2`. Never accept a single run.

| Runner | Command | Per-file timing |
|--------|---------|----------------|
| Vitest | `npx vitest run --reporter=json` | JSON includes per-file duration |
| Jest | `npx jest --json` | JSON includes testResults[].perfStats |
| pytest | `python -m pytest --durations=0 -q` | --durations=0 lists all test times |

Redirect stderr to `memory/tests-performance.stderr.log` for diagnostic review. Create `memory/` first if needed.

### Baseline Summary

```
BASELINE
-----
  Median total time: X.Xs (min: X.Xs, max: X.Xs, stddev: X.Xs)
  Stability: STABLE | UNSTABLE (stddev > 15% of median)
  Test count: N
  Per-test avg: X.Xms
  Top 5 slowest files:
    1. path/to/slow.test.ts -- X.Xs (N tests)
    2. ...
-----
```

If stddev exceeds 15% of median, mark as UNSTABLE with warning.

### Save Baseline

Save to `memory/tests-performance-baseline.<runner>.json` in the project root. If `memory/` does not exist, create it.

**If argument is `baseline`: stop here. Print baseline summary and exit.**

---

## Phase 2: Config Audit (TP1-TP17)

Read the runner config file. Score each TP item as 1 (optimal), 0 (suboptimal), or N/A.

### TP Checklist

| TP | Item | What optimal looks like |
|----|------|------------------------|
| TP1 | Transform efficiency | Jest: @swc/jest or esbuild-jest. Vitest: native (always 1). pytest: N/A. |
| TP2 | Default environment | `node` globally, `jsdom` only per-file where needed |
| TP3 | DOM engine (Vitest only) | happy-dom instead of jsdom for DOM tests |
| TP4 | Worker/concurrency strategy | Jest: maxWorkers 50%. Vitest: pool threads + maxConcurrency 20. pytest: xdist + -n auto. |
| TP5 | Test isolation (Vitest only) | isolate: false if tests are side-effect-free |
| TP6 | Test timeout | Effective timeout at or below 10 seconds |
| TP7 | Suite split | Separate configs or markers for unit/integration/e2e |
| TP8 | Coverage thresholds [GOV] | Thresholds set (governance, not speed) |
| TP9 | Cache enabled | Cache enabled and persisted across runs |
| TP10 | Fail-fast [CI] | bail: 1 in CI only (economics, not speed) |
| TP11 | Collection scope | testMatch or testpaths restricted to source directories |
| TP12 | Dependency pre-bundling | Vitest: deps.optimizer enabled. Jest: transformIgnorePatterns tuned. |
| TP13 | Module path aliases | Path aliases consistent between app and test configs |
| TP14 | Coverage tool | v8 (fast) over istanbul (accurate but slower) |
| TP15 | Console noise | No uncontrolled console.log in tests (spy + suppress) |
| TP16 | Memory degradation | No memory leaks across runs (stable heap after 3 runs) |
| TP17 | Type-check separation | Type checking runs separately from test execution |

### Scoring Rules

- TP8 [GOV] and TP10 [CI] are governance/economics items, NOT performance items. Score them in the report but exclude from the weighted performance score and action plan impact estimates.
- TP5 (isolate: false) has HIGH risk. Score as N/A if uncertain about side effects. Never recommend without a guard-rail protocol.
- For each scored item, record: current value, optimal value, expected impact range, and required change.

---

## Phase 3: Slow Test Scan

Identify the slowest tests and classify why they are slow.

### 3.1 Per-File Analysis

From baseline JSON data, extract the top 10 slowest files. For each:

1. Read the test file
2. Count tests and compute per-test average
3. Classify the slow cause:

| Classification | Signal | Typical fix |
|---------------|--------|-------------|
| SETUP_HEAVY | beforeEach with DB seed, API calls, heavy object construction | Shared fixtures, lighter setup |
| REAL_TIMERS | setTimeout, setInterval, Date.now without fakes | vi.useFakeTimers() or jest.useFakeTimers() |
| DOM_HEAVY | Multiple render() calls per describe block | Single render with targeted assertions |
| LARGE_FIXTURES | Inline fixture objects exceeding 50 lines | Extract to factory function |
| SEQUENTIAL_ASYNC | Multiple sequential await calls that could parallelize | Promise.all where safe |
| RECOMPUTATION | Same expensive computation repeated across tests | beforeAll with cached result |

### 3.2 Pattern Scan

Scan all test files for slow patterns:

```bash
# Real timers in test files
grep -rn "setTimeout\|sleep\|waitFor" --include="*.test.*" | wc -l

# Heavy setup
grep -rn "beforeEach.*prisma\|beforeAll.*seed\|beforeEach.*render" --include="*.test.*" | wc -l

# Explicit waits
grep -rn "waitForTimeout\|sleep(" --include="*.test.*" | wc -l
```

---

## Phase 4: Action Plan

Rank all findings by expected impact. Separate config changes from code changes.

### Impact Ranking

```
ACTION PLAN (ranked by expected impact)
-----
  #  Type    TP   Change                          Impact
  1  config  TP1  Switch to @swc/jest              40-70% faster transforms
  2  config  TP4  Set pool: 'threads'              10-30% total suite
  3  config  TP12 Enable deps.optimizer            30-50% collection phase
  4  config  TP2  Set env: 'node' globally         20-40% on non-DOM files
  5  code    --   Extract shared setup in auth/    ~3s saved (top-5 slow file)
  ...

  Excluded from ranking (governance/economics):
    TP8  Coverage thresholds: not set (no speed impact)
    TP10 Fail-fast: not set (only helps on red suites)
-----
```

### Rollout Sequence

For config changes, propose a safe rollout order:

1. Changes with zero risk of breaking tests (TP1, TP9, TP11, TP12)
2. Changes that need verification (TP2, TP4, TP7)
3. Changes with side-effect risk (TP5 -- requires isolation audit first)

For each change, provide the exact config diff:

```
TP4 (worker strategy):
  Current:  pool: 'forks' (default)
  Proposed: pool: 'threads', poolOptions: { threads: { maxThreads: 8 } }
  File:     vitest.config.ts
  Risk:     Low (threads is default in Vitest 2.x+)
```

---

## Phase 5: Verify

**Only runs when argument is `verify` or after applying changes from Phase 4.**

Re-run the test suite with the same protocol as Phase 1 (3 runs, median). Load the saved baseline from `memory/tests-performance-baseline.<runner>.json`.

Compare:

```
VERIFICATION
-----
  Baseline:  X.Xs (N tests)
  Current:   Y.Ys (N tests)
  Delta:     -Z.Zs (P% faster)
  Stability: [STABLE | UNSTABLE]

  Per-change impact (if individual changes were applied):
    TP1 (@swc/jest):     X.Xs -> Y.Ys (-Z%)
    TP4 (threads):       X.Xs -> Y.Ys (-Z%)
-----
```

If the current time is slower than baseline, warn: `REGRESSION: Suite is X% slower than baseline. Revert recent changes and investigate.`

---

## Completion Report

```
TESTS-PERFORMANCE COMPLETE
-----
  Runner:      [runner] ([config path])
  Baseline:    X.Xs (N tests)
  TP Score:    [N]/17 optimal ([M] suboptimal, [K] N/A)
  Slow tests:  [N] files classified
  Action plan: [N] items ([M] config, [K] code)
  Top impact:  [description of #1 change] -> expected [P]% improvement
-----
```
