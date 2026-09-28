---
name: test-audit
description: "Batch audit of test files against Q1-Q25 quality gates and AP1-AP32 anti-patterns. Detects orphan tests, phantom mocks, untested public methods. Tiered output (A/B/C/D) with critical gate enforcement and optional post-audit fix workflow. Flags: zuvo:test-audit all | [path] | [file] | --deep | --quick | --include-e2e | --details | --commit=ask|auto|off"
category: Code/Test audits
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
    - find_references          # orphan-test + untested-public-method detection (no AP id — this is the
                               #   pre-scan's ORPHAN/untested-methods signal, not an anti-pattern)
    - find_dead_code           # AP17 unused test data declared but never referenced
    - find_clones              # AP18 duplicate test names / copy-pasted test bodies
    - search_patterns
    - audit_scan
    - scan_secrets             # hardcoded credentials in fixtures (no AP id — a security finding,
                               #   reported separately from the AP deduction)
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

# zuvo:test-audit — Test Quality Triage

Systematic evaluation of unit and integration test files through the Q1-Q25 binary checklist and AP anti-pattern catalog. Each test file is paired with its production source, scored against behavioral coverage standards, and assigned a tier.

**Scope:** Unit and integration tests only. E2E tests (`*/e2e/*`, `*.e2e.*`) are excluded by default. Use `--include-e2e` to include them.

**When to use:** After mass test writing, when test quality is uncertain, before releases, when test failures are hard to diagnose, periodic health check.
**Out of scope:** Single-file code review (use `zuvo:review`), writing new tests (use `zuvo:write-tests`), fixing systematic anti-patterns across many files (use `zuvo:fix-tests`).

## Argument Parsing

| Argument | Effect |
|----------|--------|
| `all` | Audit every test file in the project |
| `[path]` | Audit test files under a specific directory |
| `[file]` | Audit a single test file with full evidence (forces deep mode) |
| `[file file2 …]` | Audit exactly the listed test files (space-separated, forces deep mode) — the form the Test Quality Gate (`../../shared/includes/test-quality-gate.md`, called from build/refactor/execute/write-tests/write-e2e) uses to scope to touched files |
| `--deep` | Collect evidence and fix recommendations for every file |
| `--quick` | Binary pass/fail only, skip evidence |
| `--include-e2e` | Include E2E test files in scope |
| `--details` | Save per-file reports to `zuvo/audits/test-audit-details/` |
| `--commit=ask\|auto\|off` | Commit behavior after fix workflow (default: `ask`) |
| `--read-only` | Report only: skip Phases 4-6 (coverage.md/backlog.md writes) and Phase 7; no repo mutation beyond the `zuvo/audits/` report |

Default: `all --quick --commit=ask`

**Dispatch is already authorized — do not ask, and do not substitute.** Invoking this skill IS the
request for the gates it mandates. A session-level instruction like "do not use the Agent tool unless
the user asked" does NOT apply here: the user asked, by invoking this skill. Reading it as a
prohibition and recording a self-scored result is the substituted gate this step forbids — it
happened twice in the field (2026-08-07, 2026-08-08), the second time invented as
`WARN:substituted-inline`, a value no vocabulary defines. If the harness genuinely has no dispatch
capability (Cursor, Antigravity — NOT Codex, which dispatches mechanical workers), follow the ONE documented exception in
`test-quality-gate.md`; otherwise dispatch.


| Mode | Scope | Depth | Commit | Notes |
|------|-------|-------|--------|-------|
| `all` | Entire project | Standard | `--commit=ask` | Default |
| `[path]` | Directory | Standard | `--commit=ask` | Scoped |
| `[file]` | Single file | Deep | `--commit=ask` | Full evidence |
| `[file file2 …]` | Listed files only | Deep | `--commit=ask` | File-list scope (Test Quality Gate callers pass `--read-only --commit=off`) |
| `--deep` | Any scope | Full evidence + fixes | Per flag | Thorough |
| `--quick` | Any scope | Binary only | `--commit=off` | Fast triage |
| `--include-e2e` | + E2E files | Standard | Per flag | Expanded scope |
| `--details` | Any scope | + per-file reports | Per flag | Save individual files |

## Mandatory File Loading

First resolve `../../shared/includes/execution-policy.md` and
`../../shared/includes/evidence-reuse.md`. Reuse the parent policy and verified evidence for
a nested stage. Load only the rules needed now, with the read-once receipt protocol.

Load the applicable definitions using the read-once protocol. Defer logging/retro includes until completion.

```
CORE FILES LOADED:
   1. ../../rules/testing.md              -- READ/MISSING
   2. ../../shared/includes/test-edge-cases.md   -- READ/MISSING
   3. ../../shared/includes/env-compat.md -- READ/MISSING
   4. ../../shared/includes/run-logger.md -- READ/MISSING
   5. ../../shared/includes/retrospective.md -- READ/MISSING
   6. ../../shared/includes/no-pause-protocol.md -- READ/MISSING (HARD: no mid-batch pauses)
   7. ../../shared/includes/test-quality-gate.md -- READ/MISSING (carries the dispatch-authorization rule)
   8. ../../shared/includes/test-metrics.md -- READ/MISSING (frozen quality/cost/speed formulas — cite TIER_DIST/ECHO_COUNT, never restate)
   9. ../../shared/includes/test-audit-batch-prompt.md -- READ/MISSING (the Phase 1 batch agent prompt template)
```


**If any file is missing:** Stop. The quality gate definitions are required for scoring.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking.

## MANDATORY TOOL CALLS — Test Audit Validity Gate

**INVALID if any tool below is skipped when trigger holds.** "DEFERRED", "N/A", "--quick mode" NOT valid reasons.

| Tool | Trigger | Skip allowed? |
|------|---------|---------------|
| `find_dead_code` | Always | **NO** — AP17 unused test data |
| `find_clones` | Always | **NO** — AP18 duplicate test names / copy-pasted bodies |
| `find_references` | Always | **NO** — orphan tests + untested public methods (no AP id) |
| `search_patterns` | Always | **NO** — Q-checklist anti-patterns |
| `audit_scan` | Always | **NO** — compound check |
| `scan_secrets` | Always | **NO** — hardcoded credentials in fixtures (security, not an AP) |
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
mkdir -p zuvo/audits/.test-audit-batch
```

The orchestrator saves each batch agent's returned report here. Cleaned up after the final report.

---

## Phase 1: Batch Evaluation

Split grouped files into batches of 8-10. For each batch, spawn a Task agent or process inline.

Each Task agent dispatch:
```
Agent: Test Quality Auditor (per batch)
  model: "sonnet"
  type: "general-purpose"  # read-only: no Edit/Write; may run read-only verification commands (tests, lint) — never modifies the repo (Explore lacks mcp__codesift__*)
  instructions: evaluate test files against Q1-Q25 and AP anti-patterns (see the Agent Prompt in `../../shared/includes/test-audit-batch-prompt.md`)
  input: batch file list with paired production files, CODESIFT_AVAILABLE
```

**Agent Prompt (provided to each batch agent):** the orchestrator passes the FENCED BODY ONLY from
`../../shared/includes/test-audit-batch-prompt.md` (loaded above under Mandatory File Loading) —
the text between that include's opening and closing ``` fences, never the `### Agent Prompt`
heading or the fences themselves. Before dispatch, the orchestrator substitutes BOTH placeholders:
`[BATCH FILE LIST]` with this batch's file list, and `[VERIFICATION CONTEXT]` with `shell
available` (this in-harness Agent path always substitutes that value; a future subprocess-dispatch
path would substitute `read-only reviewer, no shell` there instead).

The batch agent returns its report as its final message. The orchestrator saves that returned
report to `zuvo/audits/.test-audit-batch/batch-{N}.md` only if it contains a `### [filename]`
section (the include's own FULL/SHORT format heading, path exactly as listed in the batch) for
every test file in the batch; a return missing any file's section is not saved, and that batch
then counts as a missing batch file under
Phase 2's incomplete-batch rule (step 4 logs the gap, step 5 counts it INCOMPLETE).

---

## Phase 2: Aggregate Results

Read all batch files from `zuvo/audits/.test-audit-batch/`:

1. Glob for `zuvo/audits/.test-audit-batch/batch-*.md`
2. Parse summary tables for tier counts
3. Parse per-file blocks for detailed analysis
4. If any batch file is missing (agent failure), log the gap
5. Count INCOMPLETE files separately; exclude them from numeric tier averages and passing totals, and keep the overall audit INCOMPLETE until their evaluation is resolved

Build the summary report:

```markdown
# Test Quality Audit Report

Date: [date]
Project: [name]
Files audited: [N]
Total tests: [count from test runner]
Checkout: [absolute branch/worktree path]
Tree: [branch, commit, dirty-tree identity if applicable]
Verification: [commands + cwd + run IDs/artifacts + exit/result summaries; skips and unrun checks]
Evidence map: [per production file/symbol → test branch citations → matching coverage/mutation artifact scope]

## Summary by Tier

| Tier | Count | % | Action |
|------|-------|---|--------|
| A (>=82% of applicable) | [N] | [%] | No action |
| B (>= 53% and < 82% of applicable) | [N] | [%] | Fix gaps |
| C (<53% of applicable OR any critical gate = 0) | [N] | [%] | Major rewrite |
| D (auto Tier-D red flag) | [N] | [%] | Delete + rewrite |
| INCOMPLETE (no tier) | [N] | [%] | Finish missing evaluation |
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

Save to: `zuvo/audits/test-quality-audit-[date].md` — at the **project root** (`zuvo/` resolves via `git rev-parse --show-toplevel`; override `$ZUVO_OUTPUT_DIR`. See `../../shared/includes/report-output-location.md`).
If `--details` flag: also save per-file reports to `zuvo/audits/test-audit-details/`

## Phase 3: Cleanup Batch Files

```bash
rm -rf zuvo/audits/.test-audit-batch
```

## Phase 3b: Adversarial Review on Audit Report (MANDATORY — do NOT skip)

After the audit report is generated, run cross-model validation to catch Q-score inflation and coverage theater. Runs on ALL audits (not just --deep).

```bash
~/.zuvo/adversarial-review --mode tests --files "zuvo/audits/test-quality-audit-[date].md"
```

If `adversarial-review` is not in PATH: `~/.zuvo/adversarial-review` (stable; the versioned cache path breaks after any release)

Wait for complete output. Verify each actionable finding against the actual source/test branches
and artifact scope before changing scores. Record rejected false positives with source evidence;
severity alone does not establish validity. Then, for confirmed findings:
- **CRITICAL** (passing Q-score contradicted by evidence) → fix in report before delivery
- **WARNING** (coverage theater not flagged) → correct affected evidence, scores and tier; record unresolved gaps explicitly
- **INFO** → ignore

Apply validated corrections to the audit report, including per-file scores, aggregate counts and
evidence attribution, before delivery. Do not start a recursive review loop of report corrections
unless the user requested one. The existing mandatory review is one bounded review of the report;
record its findings and dispositions. Link the actual branch/worktree files so reviewers can open
the source that was audited.

## Phase 4: Coverage Registry Update

Under `--read-only`: skip Phases 4-6 entirely and present the report (Phase 7 fix workflow is also off).

Read `memory/coverage.md`. If it does not exist, create it now.

For each audited test file, find its production file row in coverage.md:

| Audit Tier | Coverage Status | Rationale |
|-----------|----------------|-----------|
| A (>=82% of applicable, critical gates PASS) | COVERED | Tests are solid |
| B (>=53% and <82% of applicable, critical gates PASS) | PARTIAL-QUALITY | Has tests but quality issues |
| C (<53% of applicable OR any critical gate = 0) | PARTIAL-QUALITY | Major quality gaps |
| D (auto Tier-D red flag) | PARTIAL | Effectively untested |
| INCOMPLETE (no tier) | Leave existing row unchanged | Evaluation unavailable; never register as COVERED |

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
   - Q1-Q25 self-eval on each fixed file
   - Tier improvement confirmed (D->C+, C->B+, B->A)
4. **Commit** -- behavior per `--commit` flag (ask/auto/off)
5. **Re-audit** -- optionally re-run on fixed files to verify improvement

## Next-Action Routing

| Finding | Action | Command |
|---------|--------|---------|
| Tier D files (any AUTO TIER-D red flag, or a critical Q gate = 0) | Rewrite tests | `zuvo:write-tests [path]` |
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
[ ] Report saved to zuvo/audits/
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
printf '%b\n' "$RUN_LINE" | ~/.zuvo/append-runlog
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
