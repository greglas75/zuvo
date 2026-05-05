---
name: test-audit
description: "Batch audit of test files against Q1-Q19 quality gates and AP1-AP29 anti-patterns. Detects orphan tests, phantom mocks, untested public methods. Tiered output (A/B/C/D) with critical gate enforcement and optional post-audit fix workflow. Flags: zuvo:test-audit all | [path] | [file] | --deep | --quick | --include-e2e | --details | --commit=ask|auto|off"
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree            # discover *.test.* / *.spec.* / __tests__/
    - get_file_outline
    - search_text
    - search_symbols           # untested public methods (production-side)
    - get_symbol
    - get_symbols
    - find_references          # AP6 orphan test, untested public method detection
    - find_dead_code           # AP7 orphan helpers, AP25 unused fixtures
    - find_clones              # AP19 copy-paste tests
    - search_patterns
    - audit_scan
    - scan_secrets             # AP24 hardcoded creds in fixtures
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

# zuvo:test-audit — Test Quality Triage

Systematic evaluation of unit and integration test files through the Q1-Q19 binary checklist and AP anti-pattern catalog. Each test file is paired with its production source, scored against behavioral coverage standards, and assigned a tier.

**Scope:** Unit and integration tests only. E2E tests (`*/e2e/*`, `*.e2e.*`) are excluded by default. Use `--include-e2e` to include them.

**When to use:** After mass test writing, when test quality is uncertain, before releases, when test failures are hard to diagnose, periodic health check.
**Out of scope:** Single-file code review (use `zuvo:review`), writing new tests (use `zuvo:write-tests`), fixing systematic anti-patterns across many files (use `zuvo:fix-tests`).

## Argument Parsing

| Argument | Effect |
|----------|--------|
| `all` | Audit every test file in the project |
| `[path]` | Audit test files under a specific directory |
| `[file]` | Audit a single test file with full evidence (forces deep mode) |
| `--deep` | Collect evidence and fix recommendations for every file |
| `--quick` | Binary pass/fail only, skip evidence |
| `--include-e2e` | Include E2E test files in scope |
| `--details` | Save per-file reports to `audits/test-audit-details/` |
| `--commit=ask\|auto\|off` | Commit behavior after fix workflow (default: `ask`) |

Default: `all --quick --commit=ask`

| Mode | Scope | Depth | Commit | Notes |
|------|-------|-------|--------|-------|
| `all` | Entire project | Standard | `--commit=ask` | Default |
| `[path]` | Directory | Standard | `--commit=ask` | Scoped |
| `[file]` | Single file | Deep | `--commit=ask` | Full evidence |
| `--deep` | Any scope | Full evidence + fixes | Per flag | Thorough |
| `--quick` | Any scope | Binary only | `--commit=off` | Fast triage |
| `--include-e2e` | + E2E files | Standard | Per flag | Expanded scope |
| `--details` | Any scope | + per-file reports | Per flag | Save individual files |

## Mandatory File Loading

Read these files from disk before starting. Print the checklist. Do not proceed from memory.

```
CORE FILES LOADED:
  1. ../../rules/testing.md              -- READ/MISSING
  2. ../../rules/test-quality-rules.md   -- READ/MISSING
  3. ../../shared/includes/env-compat.md -- READ/MISSING
  4. ../../shared/includes/run-logger.md -- READ/MISSING
  5. ../../shared/includes/retrospective.md -- READ/MISSING
  6. ../../shared/includes/no-pause-protocol.md -- READ/MISSING (HARD: no mid-batch pauses)
```


**If any file is missing:** Stop. The quality gate definitions are required for scoring.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking.

## MANDATORY TOOL CALLS — Test Audit Validity Gate

**INVALID if any tool below is skipped when trigger holds.** "DEFERRED", "N/A", "--quick mode" NOT valid reasons.

| Tool | Trigger | Skip allowed? |
|------|---------|---------------|
| `find_dead_code` | Always | **NO** — AP6 orphan tests + AP7 orphan helpers |
| `find_clones` | Always | **NO** — AP19 copy-paste tests |
| `find_references` | Always | **NO** — untested public methods detection |
| `search_patterns` | Always | **NO** — Q-checklist anti-patterns |
| `audit_scan` | Always | **NO** — compound check |
| `scan_secrets` | Always | **NO** — AP24 hardcoded creds in fixtures |
| Stack-specific tools | Framework/language detected | **NO** when matches |

Forbidden: `find_dead_code: skipped`, `codesift: unavailable` (when deferred), `retrospective: skipped` — all REJECTED.

POSTAMBLE: report on disk → retro appended → `~/.zuvo/append-runlog` exit 0. Every Q-fail/AP finding needs `path/to/file.ext:LINE` (verify-audit gate).

```
Mandatory-tools-acknowledgment: I will run find_dead_code + find_clones + find_references + search_patterns + audit_scan + scan_secrets + stack-specific tools for this test audit. Every finding will cite a `path/to/file.ext:LINE` resolving in the current tree.
```

---

## CodeSift Integration

**Use the deterministic preload helper FIRST.** Run `~/.zuvo/compute-preload test-audit "$PWD"` before any ToolSearch. Copy `[CodeSift matching trace]` verbatim, issue printed `ToolSearch(query="select:...")`. Math gate enforced.

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift for file discovery and production code analysis when available. If unavailable, fall back to standard tools.

### CodeSift Optimizations

| Task | CodeSift | Fallback |
|------|----------|----------|
| Find test files | `get_file_tree(repo, name_pattern="*.test.*")` | `find` command |
| Understand test structure | `get_file_outline(repo, file_path)` | `Read` each file |
| Batch-read test cases | `get_symbols(repo, symbol_ids=[...])` | Multiple `Read` calls |
| Find production file for test | `search_symbols(repo, query, kind="function")` | Path-based heuristic |
| Verify test imports | `find_references(repo, symbol_name)` | `Grep` for imports |
| Pre-scan for weak assertions | `search_text(repo, "toBeTruthy\|toBeDefined", file_pattern="*.test.*")` | `Grep` |

### Degraded Mode (CodeSift unavailable)

All steps fall back to `find`/`Read`/`Grep`/`Glob`. File discovery is slower and production file pairing relies on path conventions rather than symbol resolution.

---

## Phase 0: Discovery and Pairing

### 0.1 Locate Test Files

When CodeSift is available: `get_file_tree(repo, name_pattern="*.test.*")` with path filters excluding `node_modules`, `.next`, `e2e` (unless `--include-e2e`).

When unavailable:

```bash
find . \( -name "*.test.ts" -o -name "*.test.tsx" -o -name "*.spec.ts" -o -name "*.spec.tsx" \
  -o -name "test_*.py" -o -name "*_test.py" \) \
  ! -path "*/node_modules/*" ! -path "*/.next/*" ! -path "*/__pycache__/*" ! -path "*/e2e/*" | sort
```

If count exceeds 50 and `--deep` was not explicitly requested, auto-switch to `--quick`. Explicit `--deep` always takes precedence.

### 0.2 Pair with Production Files

For each test, identify its production counterpart:
- `__tests__/api/projects/[id]/route.test.ts` -> `app/api/projects/[id]/route.ts`
- `tests/unit/services/bar.test.ts` -> `lib/services/bar.ts`

If production file not found: flag as ORPHAN (test without source).

When CodeSift is available, use `search_symbols` or `find_references` for more reliable pairing in non-standard project layouts.

### 0.3 Pre-Batch Grouping

Before splitting into batches, group test files by production file. If multiple test files target the same production code (`foo.test.ts` + `foo.errors.test.ts`), they MUST go into the same batch so suite-aware Q7/Q11 scoring works correctly.

### 0.4 Golden File Calibration (recommended for first audit)

If this is the first audit of a project or agent scores seem inconsistent:
1. Pick 2-3 test files with known quality (one good, one bad, one mid)
2. Run a single calibration agent on those files
3. Compare scores to expectations. If drift >2 points, adjust prompt wording
4. Proceed with full evaluation

### 0.5 Batch Output Directory

```bash
mkdir -p audits/.test-audit-batch
```

Each batch agent writes results here. Cleaned up after the final report.

---

## Phase 1: Batch Evaluation

Split grouped files into batches of 8-10. For each batch, spawn a Task agent or process inline.

Each Task agent dispatch:
```
Agent: Test Quality Auditor (per batch)
  model: "sonnet"
  type: "Explore"
  instructions: evaluate test files against Q1-Q19 and AP anti-patterns (see Agent Prompt below)
  input: batch file list with paired production files, CODESIFT_AVAILABLE
```

### Agent Prompt (provided to each batch agent)

```
You are a test quality auditor. Evaluate each test file below against Q1-Q19.

RED FLAG PRE-SCAN (do FIRST, before full evaluation):
- Tests with zero expect() calls (AP13) -> AUTO TIER-D. RTL exception: getByRole/getByText/getByLabelText are implicit assertions.
- Fixture:assertion ratio > 20:1 (AP16) -> AUTO TIER-D
- 50%+ of tests use toBeTruthy()/toBeDefined() as sole assertion (AP14) -> AUTO TIER-D

QUICK HEURISTICS:
- 0 CalledWith in entire file -> likely score <=4
- 10+ DI providers in test setup -> likely score <=5
- Tests calling __privateMethod() directly -> likely score <=5

POSITIVE INDICATORS:
- Factory with named overrides -> likely >=8
- Regression anchor in test name -> mature suite
- it.each with table-driven data -> Q8+Q9+Q11 likely pass

PRODUCTION CODE ANALYSIS (do BEFORE scoring):
Read the production file and extract:
1. Public API surface: all exported functions/methods
2. Branch map: all if/else, switch, ternary with line numbers
3. Enum/union values with their members
4. Error handling: try/catch, thrown errors, rejected promises
5. Complexity: THIN (<50 LOC, <=3 branches), STANDARD (50-200 LOC), COMPLEX (>200 LOC or >10 branches)

COMPLEXITY EXPECTATIONS:
| Complexity | Expected tests | Q11 depth | Edge case scope |
|------------|---------------|-----------|-----------------|
| THIN | 8-15 | cache/wiring only | null/undefined on params |
| STANDARD | 15-40 | all branches | full edge case checklist |
| COMPLEX | 40-80 (split files) | all branches + combos | full checklist + matrix |

CHECKLIST (score 1=YES, 0=NO):
Q1:  Every test name describes expected behavior?
Q2:  Tests grouped in logical describe blocks?
Q3:  Every mock has CalledWith + not.toHaveBeenCalled?
Q4:  Assertions use exact matchers (toEqual/toBe, not toBeTruthy)?
Q5:  Mocks are typed (no `as any`)?
Q6:  Mock state fresh per test (beforeEach, no shared mutable)?
Q7:  CRITICAL -- Every error-throwing path tested with specific type+message?
Q8:  Null/empty/edge inputs tested?
Q9:  Repeated setup (3+ tests) extracted to helper/factory?
Q10: No magic values -- test data is self-documenting?
Q11: CRITICAL -- All code branches exercised?
Q12: Symmetric: "does X when Y" has "does NOT do X when not-Y"?
Q13: CRITICAL -- Tests import actual production function?
Q14: Behavioral assertions (not just mock-was-called)?
Q15: CRITICAL -- Content/values assertions, not just counts/shape?
Q16: Cross-cutting isolation: change to A verified not to affect B?
Q17: CRITICAL -- Assertions verify COMPUTED output, not input echo?

ANTI-PATTERNS (each unique AP = -1 from score, max -5):
AP1:  try/catch in test swallowing errors
AP2:  Conditional assertions (if/else in test)
AP3:  Re-implementing production logic in test
AP4:  Snapshot as only test for component
AP5:  `as any` -> `as never` bypassing types
AP6:  Testing CSS classes instead of behavior
AP7:  .catch(() => {}) swallowing errors
AP8:  document.querySelector bypassing Testing Library
AP9:  Always-true assertion (expect(true).toBe(true))
AP10: Tautological mock (call mock -> verify mock called, no production code)
AP11: vi.mocked(vi.fn()) -- mock targeting fresh fn
AP12: waitForTimeout(N) hardcoded delays
AP13: Test with zero expect() calls -- AUTO TIER-D
AP14: toBeTruthy()/toBeDefined() as sole assertion on complex object
AP15: Testing private methods directly
AP16: Fixture:assertion ratio > 20:1 -- AUTO TIER-D
AP17: Unused test data declared but never used
AP18: Duplicate test names (copy-paste indicator)
AP19: expect.anything() hiding callback contract
AP20: Mock returns same data for ALL methods
AP21: .calls[N] magic index (fragile)
AP22: CSS selector in test
AP23: Inline mockRestore() with afterEach present (redundant)
AP24: consoleSpy typed as `any`
AP25: Mocking own code that could be instantiated with real implementation
AP26: Real timers in time-dependent tests (Date.now/setTimeout without useFakeTimers)

N/A HANDLING: N/A items excluded from both numerator and denominator. Score = passed / applicable.
Q16 N/A: score N/A when test covers single function/hook with no shared mutable state.
Q17 PASS-THROUGH: For thin controllers that are pure delegation, `expect(result).toEqual(mockReturn)` with CalledWith on service mock = Q17=1.

CRITICAL GATE: Q7, Q11, Q13, Q15, Q17 -- any = 0 -> capped at Tier B.

SCORING MATH:
  Applicable = 17 - N/A-count
  Score = yes-count / applicable (percentage)
  AP deduction: each unique AP = -1 from yes-count (max -5)
  Thresholds: PASS >= 82%, FIX 53-81%, BLOCK < 53%. Critical gates still override.

FOR AUTO TIER-D FILES, use SHORT format:
### [filename]
Production file: [path or ORPHAN]
Red flags: [AP13/AP14/AP16] -> AUTO TIER-D
Phantom mocks: [list mocked modules not called by production code, or "none"]
Reason: [brief]
Top 3 gaps: [brief]

FOR ALL OTHERS, use FULL format:
### [filename]
Production file: [path or ORPHAN]
Complexity: [THIN/STANDARD/COMPLEX] ([LOC] LOC, [N] branches)
Red flags: ["none"]
Phantom mocks: [list or "none"]
Untested methods: [list of public methods with no test coverage, or "all covered"]
Score: Q1=[0/1] Q2=[0/1] ... Q17=[0/1]
Anti-patterns: [AP IDs found, or "none"]
Total: [yes]/[applicable] ([%]) - [AP count] = [adjusted%]
Critical gate: Q7=[0/1] Q11=[0/1] Q13=[0/1] Q15=[0/1] Q17=[0/1] -> [PASS/FAIL]
Tier: [A/B/C/D]
Top 3 gaps: [brief]

TIER CLASSIFICATION:
  A (>=16, critical gate PASS): No action needed
  B (10-15, or critical gate FAIL with score >=10): Fix gaps -- 2-5 targeted fixes
  C (5-8): Major rewrite needed
  D (<5 or AUTO TIER-D red flag): Delete and rewrite from scratch

IMPORTANT:
- Read BOTH the test file AND its production file
- Red flag pre-scan first
- COVERAGE COMPLETENESS: List all public methods in production file. For each, check if test exercises it. Flag untested methods. Exclude control flow keywords, built-ins, SQL keywords. API endpoint exception: test calling client.get("/path") IS testing the handler. Page component exception: render(<Component />) IS testing the export. Re-export exception: only test functions DEFINED in the file, not re-exports.
- PHANTOM MOCK DETECTION: List all mocked modules in test. For each: does production code actually call it? Unused mock = phantom mock.
- SUITE-AWARE MODE: Sibling test files for same production file -- evaluate Q7/Q11 at suite level.
- Q17 ECHO vs COMPUTED: mock returns X, test asserts X = echo (Q17=0). Mock returns raw data, test asserts transformation = computed (Q17=1).
- Q15 API ROUTE CALIBRATION: Status code checks, error body checks, response field checks, auth guard verification all count as Q15=1 for API routes.
- AP21 CALIBRATION: `.mock.calls[N]` = fragile (AP21). `.toHaveBeenNthCalledWith(N, ...)` = Jest API, not AP21.

Write complete output to: audits/.test-audit-batch/batch-{N}.md

Files to audit:
[BATCH FILE LIST]
```

---

## Phase 2: Aggregate Results

Read all batch files from `audits/.test-audit-batch/`:

1. Glob for `audits/.test-audit-batch/batch-*.md`
2. Parse summary tables for tier counts
3. Parse per-file blocks for detailed analysis
4. If any batch file is missing (agent failure), log the gap

Build the summary report:

```markdown
# Test Quality Audit Report

Date: [date]
Project: [name]
Files audited: [N]
Total tests: [count from test runner]

## Summary by Tier

| Tier | Count | % | Action |
|------|-------|---|--------|
| A (>=16) | [N] | [%] | No action |
| B (10-15) | [N] | [%] | Fix gaps |
| C (5-8) | [N] | [%] | Major rewrite |
| D (<5 or red flag) | [N] | [%] | Delete + rewrite |
| ORPHAN | [N] | [%] | Verify or delete |

## Critical Gate Failures

| File | Score | Failed Qs | Top Gap |
|------|-------|-----------|---------|

## Red Flag Summary (Auto Tier-D)

| File | Red Flag | Details |
|------|----------|---------|

## Untested Public Methods

| File | Untested Methods | Impact |
|------|-----------------|--------|

## Top Failed Questions (across all files)

| Question | Fail count | % of files | Pattern |
|----------|-----------|------------|---------|

## Anti-pattern Hot Spots

| Anti-pattern | Files affected | Instances |
|-------------|---------------|-----------|

## Tier D -- Rewrite Queue
## Tier C -- Major Fix Queue
## Tier B -- Targeted Fix Queue
## Tier A -- No Action
```

Save to: `audits/test-quality-audit-[date].md`
If `--details` flag: also save per-file reports to `audits/test-audit-details/`

## Phase 3: Cleanup Batch Files

```bash
rm -rf audits/.test-audit-batch
```

## Phase 3b: Adversarial Review on Audit Report (MANDATORY — do NOT skip)

After the audit report is generated, run cross-model validation to catch Q-score inflation and coverage theater. Runs on ALL audits (not just --deep).

```bash
adversarial-review --mode tests --files "audits/test-quality-audit-[date].md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** (passing Q-score contradicted by evidence) → fix in report before delivery
- **WARNING** (coverage theater not flagged) → append to Known Gaps section
- **INFO** → ignore

## Phase 4: Coverage Registry Update

Read `memory/coverage.md`. If it does not exist, create it now.

For each audited test file, find its production file row in coverage.md:

| Audit Tier | Coverage Status | Rationale |
|-----------|----------------|-----------|
| A (>=16, gate PASS) | COVERED | Tests are solid |
| B (10-15 or gate FAIL >=10) | PARTIAL-QUALITY | Has tests but quality issues |
| C (5-8) | PARTIAL-QUALITY | Major quality gaps |
| D (<5 or red flag) | PARTIAL | Effectively untested |

Only downgrade coverage status, never upgrade. If production file is not yet in coverage.md, add it.

Output: `COVERAGE UPDATE: [N] rows updated ([N] downgraded, [N] confirmed, [N] new)`

## Phase 5: Backlog Persistence

Persist findings to `memory/backlog.md`:

1. Read `memory/backlog.md`. If missing, create with template.
2. Fingerprint each finding: `file|Q/AP-id|signature`. Dedup: existing = increment `Seen`.
3. Delete resolved items.

Full protocol: `../../shared/includes/backlog-protocol.md`.

**What to persist:**
- **Tier C/D files:** all findings. Source: `test-audit/{date}`. Category: Test.
- **Tier B critical gate failures** (Q7/Q11/Q13/Q15/Q17=0): separate item per gate
- **Auto Tier-D red flags** (AP13/AP14/AP16): always persist as HIGH

## Phase 6: Persistence Verification

Before presenting the report, verify all writes completed:

```
PERSISTENCE VERIFICATION
  coverage.md updated: [N] rows ([N] downgraded, [N] confirmed, [N] new)
  backlog.md updated:  [N] entries ([N] new, [N] deduped)
  batch files cleaned: [yes/no]
```

If any step is incomplete, go back and finish it before continuing.

## Phase 7: Post-Audit Fix Workflow

After presenting the report, the user may request fixes:

1. **Fix** -- rewrite test files following the quality rules
2. **Test** -- run the test suite to confirm all tests pass
3. **Verify** -- for each fixed file:
   - Only test files modified (no production code changes)
   - Full test suite green
   - All modified test files <= 400 lines
   - Q1-Q19 self-eval on each fixed file
   - Tier improvement confirmed (D->C+, C->B+, B->A)
4. **Commit** -- behavior per `--commit` flag (ask/auto/off)
5. **Re-audit** -- optionally re-run on fixed files to verify improvement

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| Tier D files (score < 10) | Rewrite tests | `zuvo:write-tests [path]` |
| Same AP across 10+ files | Batch fix | `zuvo:fix-tests --pattern [AP-ID]` |
| Tier B-C with Q7=0 | Add error tests | `zuvo:write-tests [path]` |
| Coverage gaps (methods untested) | Write missing tests | `zuvo:write-tests [path]` |
| Test infra issues (runner config) | Optimize runner | `zuvo:tests-performance` |

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Red flag pre-scan ran on every batch
[ ] Phantom mock detection ran: unused mocks listed
[ ] Untested public methods listed per file
[ ] Adversarial review ran on audit report
[ ] Coverage registry updated: memory/coverage.md rows written
[ ] Backlog updated for critical gate failures
[ ] Report saved to audits/
[ ] Run: line printed and appended to log
```

## TEST AUDIT COMPLETE

### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  triggers_held: language=<X> framework=<X> test_runner=<X>
  required_tool_calls:
    find_dead_code: [<N> orphan helpers | NOT_CALLED — VIOLATES_TRIGGER]
    find_clones: [<N> dup tests | NOT_CALLED — VIOLATES_TRIGGER]
    find_references: [<N> ref-checks | NOT_CALLED — VIOLATES_TRIGGER]
    search_patterns: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    audit_scan: [<N> findings | NOT_CALLED — VIOLATES_TRIGGER]
    scan_secrets: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    stack_specific: [<result> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
  postamble:
    retros_log_appended: [yes(bytes_added=N) | NOT_APPENDED]
    retros_md_appended: [yes(entry_count=N) | NOT_APPENDED]
    verify_audit_pass: [yes(<verified>/<total>) | NOT_RUN | REJECTED]
  gate_status: [PASS | FAIL — <which gates missing>]
```

If `gate_status = FAIL` → VERDICT = INCOMPLETE.

Append the Run line via the retro-gated wrapper (NOT direct `>> runs.log`):

```bash
echo -e "$RUN_LINE" | ~/.zuvo/append-runlog
```

Run: <ISO-8601-Z>\ttest-audit\t<project>\t<N-critical>\t<N-total>\t<VERDICT>\t-\t<N>-dimensions\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).

---

## Execution Notes

- Use **Sonnet** for batch agents in both QUICK and DEEP modes
- Process batches sequentially in Cursor/Codex. Claude Code may parallelize with up to 6 Task agents.
- Run the project's test suite first to confirm baseline passes. Auto-detect runner from config files.
- Estimated durations: QUICK ~2 min for 50 files, DEEP ~10 min for 50 files
