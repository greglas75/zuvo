---
name: code-audit
description: "Batch audit of production files against CQ1-CQ29 quality gates and CAP1-CAP19 anti-patterns. Tiered output (A/B/C/D), critical gate enforcement, evidence-backed scoring, cross-file pattern analysis, and prioritized execution plan. Flags: zuvo:code-audit all | [path] | [file] | --deep | --quick | --services | --controllers"
---

# zuvo:code-audit — Production Code Quality Triage

Systematic evaluation of production source files through the CQ1-CQ29 binary checklist and CAP anti-pattern catalog. Every file receives a tier classification based on its score, critical gate status, and detected anti-patterns. The output is a prioritized report with actionable fix plans.

**When to use:** Periodic health checks, before major releases, after adding many production files, when onboarding a new codebase, when code quality feels inconsistent.
**Out of scope:** Single-file code review (use `zuvo:review`), refactoring (use `zuvo:refactor`), test quality assessment (use `zuvo:test-audit`), feature development (use `zuvo:build`).

## Argument Parsing

| Argument | Effect |
|----------|--------|
| `all` | Audit every production file in the project |
| `[path]` | Audit production files under a specific directory |
| `[file]` | Audit a single file with full evidence (forces deep mode) |
| `--deep` | Collect per-gate evidence and fix recommendations for every file |
| `--quick` | Binary pass/fail only, skip evidence gathering |
| `--services` | Restrict scope to service and business logic files |
| `--controllers` | Restrict scope to controller, handler, and route files |

Default behavior: `all --quick`

| Mode | Scope | Depth | Batch Size | Notes |
|------|-------|-------|------------|-------|
| `all` | Entire project | Standard | 6 files/batch | Default |
| `[path]` | Directory tree | Standard | 6 files/batch | Scoped |
| `[file]` | One file | Deep (full evidence) | 1 | Single-file deep dive |
| `--deep` | Any scope | Full evidence | 6 files/batch | Slower, thorough |
| `--quick` | Any scope | Binary only | 10 files/batch | Fast triage |
| `--services` | Service files | Standard | 6 | Filter by file type |
| `--controllers` | Controller files | Standard | 6 | Filter by file type |

## Mandatory File Loading

### PHASE 0 — Bootstrap (always, before reading any input)

```
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
```

This is the ONLY file loaded before reading the audit target files.

### PHASE 0.5 — Classify (read target files, determine domain)

After CodeSift setup, read the target file(s). Classify the primary domain:
- **data:** touches DB queries, transactions, ORMs, migrations
- **async:** touches promises, streams, workers, event emitters
- **security:** touches auth, input validation, secrets, crypto
- **general:** none of the above (or mixed)

Print: `[CLASSIFIED] Domain: {data|async|security|general}`

### PHASE 1 — Conditional Load (based on domain)

| Include | data | async | security | general |
|---------|------|-------|----------|---------|
| `../../rules/cq-checklist.md` | Full | Full | Full | Full |
| `../../shared/includes/env-compat.md` | Full | Full | Full | Full |
| `../../rules/cq-patterns.md` | CQ6,7,9,16,17 focus | CQ15,17 focus | CQ4,5 focus | Full |
| `../../rules/security.md` | **SKIP** | **SKIP** | Full | **SKIP** |
| `../../rules/file-limits.md` | **SKIP** | **SKIP** | **SKIP** | Full |

Print loaded files:
```
PHASE 1 — LOADED:
  [list with READ/SKIP status per file]
```

### DEFERRED — Load at completion

```
  ../../shared/includes/run-logger.md        -- [READ at final step]
  ../../shared/includes/retrospective.md        -- [READ at final step]
```

**If PHASE 0 file missing:** STOP. The plugin installation is incomplete.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

CodeSift setup completed in PHASE 0. Use CodeSift tools for all discovery and analysis when available. If not found, fall back to Grep/Read/Glob and inform the user once.

After editing any file: `index_file(path="/absolute/path/to/file")`

### CodeSift-Accelerated Discovery

When CodeSift is available, run these checks before the manual CQ evaluation to pre-populate deterministic findings:

1. `find_dead_code(repo, file_pattern=SCOPE)` -- Pre-populate CQ13 (unused exports). Mark as TOOL_VERIFIED.
2. `search_patterns(repo, "empty-catch")` -- Pre-populate CQ8 (swallowed errors). Mark as TOOL_VERIFIED.
3. `find_clones(repo, min_similarity=0.8)` -- Pre-populate CQ14 (duplicated logic blocks >10 lines). Mark as TOOL_VERIFIED.

TOOL_VERIFIED findings have deterministic HIGH confidence and bypass the confidence gate. They go directly to the report.

Manual CQ1-CQ29 evaluation still runs for all 29 gates. CodeSift pre-scan accelerates 3 of 29 checks.

### Degraded Mode (CodeSift unavailable)

| CodeSift tool | Fallback | Lost capability |
|---------------|----------|-----------------|
| `find_dead_code` | Skip CQ13 pre-scan | No automated dead code detection |
| `search_patterns("empty-catch")` | `Grep` for `catch\s*\(` with empty body | Less precise pattern matching |
| `find_clones` | Skip CQ14 pre-scan | No automated clone detection |
| `get_file_tree` | `find` command | Slower, no symbol counts |
| `get_file_outline` | `Read` each file | More tokens consumed |
| `trace_call_chain` | `Grep` for imports | No transitive caller analysis |
| `search_symbols` | `Grep` for function names | Less precise results |

---

## Phase 0: Discovery and Classification

### 0.1 Locate Production Files

When CodeSift is available: `get_file_tree(repo, name_pattern="*.ts")` (adjust extension per stack) with path filters excluding `node_modules`, `.next`, `dist`, `__tests__`.

When unavailable:

```bash
find . \( -name "*.ts" -o -name "*.tsx" -o -name "*.js" -o -name "*.jsx" -o -name "*.py" \) \
  ! -name "*.test.*" ! -name "*.spec.*" ! -name "test_*" ! -name "*_test.*" \
  ! -path "*/node_modules/*" ! -path "*/.next/*" ! -path "*/dist/*" ! -path "*/build/*" \
  ! -path "*/__pycache__/*" ! -path "*/migrations/*" | sort
```

If the file count exceeds 80 and `--deep` was not explicitly requested, auto-switch to `--quick` mode. An explicit `--deep` flag always takes precedence.

### 0.2 Prioritize by Risk

When file count is large, process in this order:

1. **CRITICAL:** Guards, middleware, auth files + controllers, handlers, routes (public attack surface)
2. **HIGH:** Services, repositories, orchestrators, external API callers (business logic and data)
3. **MEDIUM:** ORM entities, models, components with logic >100 lines (data handling and UI)
4. **LOW:** Utilities, helpers, pure functions (least risk)

### 0.3 Classify Each File

Assign a **code type** to each file. This determines which CQ gates are high-risk and which conditional gates activate.

| Signal | Code Type | High-Risk CQs | Conditional Gates |
|--------|-----------|---------------|-------------------|
| `*.service.*`, `*.repository.*` | SERVICE | CQ1,3,4,8,14,16,17,18,20 | CQ16 if money fields, CQ19 if external calls |
| `*.controller.*`, `*.handler.*`, `route.*` | CONTROLLER | CQ3,4,5,12,13,19 | CQ19 always (API boundary) |
| `*.guard.*`, `*.middleware.*`, auth in name | GUARD/AUTH | CQ4,5 | -- |
| `*.tsx`, `*.jsx` (>50 lines) | REACT | CQ6,10,11,13,15 | -- |
| `*.entity.*`, `*.model.*`, schema in name | ORM/DB | CQ6,7,9,10,17,20 | CQ20 if dual fields |
| orchestrat, workflow, pipeline in name | ORCHESTRATOR | CQ6,8,9,14,15,17,18 | CQ18 if multi-store |
| `use*.ts`/`use*.tsx`, useState/useEffect + hook export | HOOK | CQ6,8,10,11,15,22 | CQ22 always, CQ19 if fetches data |
| `*.utils.*`, `*.helpers.*`, lib/ | PURE | CQ1,2,10,12,16 | CQ16 if money functions |
| Calls external API (fetch, axios, http) | API-CALL | CQ3,5,8,15,17,19 | CQ19 always |

When a file matches multiple types, use the most specific one.

### 0.4 Detect Global Error Handling Infrastructure

Before batch evaluation, search for project-wide error handling. This prevents systematic overcounting of CQ8 failures.

- **NestJS:** `@Catch()` decorator, `AllExceptionsFilter`, `APP_FILTER` provider
- **Express:** `app.use((err, req, res, next)` error middleware
- **Next.js:** `error.tsx` / `global-error.tsx` boundary
- **Fastify:** `setErrorHandler`
- **Python:** `@app.exception_handler`, middleware with try/except

If found, note in the report header and pass as PROJECT_CONTEXT to every batch agent. Services that let errors propagate to the global handler = CQ8 PASS. Only CQ8=0 when errors are swallowed (empty catch, catch-and-return-null, catch-without-rethrow).

### 0.5 Semgrep Pre-Scan (optional)

If `semgrep` is installed and the project has `.semgrep/` config:

```bash
npx semgrep --config .semgrep/ --json --quiet 2>/dev/null
```

Semgrep findings auto-score the matching CQ as 0 for affected files (deterministic = HIGH confidence). Exception: CQ4 findings from semgrep need dataflow verification before auto-scoring. LLM evaluation still runs full CQ1-CQ29 but skips deep analysis on CQs already flagged.

If semgrep unavailable: skip silently. This enhances the audit but does not gate it.

---

## Phase 1: Batch Evaluation

Split files into batches of 6-8 (10 in `--quick` mode). For each batch, spawn a Task agent or process inline depending on environment (see `env-compat.md`).

Each Task agent dispatch:
```
Agent: Code Quality Auditor (per batch)
  model: "sonnet"
  type: "Explore"
  instructions: evaluate files against CQ1-CQ29 checklist (see Agent Prompt below)
  input: batch file list, PROJECT_CONTEXT, CODESIFT_AVAILABLE
```

### Agent Prompt (provided to each batch agent)

```
You are a production code quality auditor. Evaluate each file below against the CQ1-CQ29 binary checklist.

PROJECT_CONTEXT:
[INSERT: global error handler info, or "No global error handler detected"]

RED FLAG PRE-SCAN (do this FIRST, before full checklist):
Scan for these. If any found, use TIER-D SHORT FORMAT and skip full CQ1-CQ29:
- Hardcoded secret (API key, password, token in source) -> AUTO TIER-D
- SQL string concatenation with user input -> AUTO TIER-D
- eval() / new Function() with non-literal input -> AUTO TIER-D
- dangerouslySetInnerHTML without DOMPurify -> AUTO TIER-D

TIER-D SHORT FORMAT:
### [filename]
Code type: [TYPE]
Lines: [count]
Red flags: [CAP5/CAP6/CAP7/CAP8] -> AUTO TIER-D
Details: [what was found, line number]
Tier: D

QUICK HEURISTICS (not Tier-D triggers, but predict score):
- 5+ `as any` casts -> likely score <= 10
- File > 400 lines -> likely CQ11=0
- 0 try/catch with DB/API calls -> likely CQ8=0
- parseFloat on money field -> likely CQ16=0
- await inside for/forEach loop -> likely CQ17=0

CLASSIFY the file first (SERVICE / CONTROLLER / GUARD / HOOK / REACT / ORM / ORCHESTRATOR / PURE / API-CALL).

CHECKLIST (score 1=YES, 0=NO, N/A=not applicable with justification):
CQ1:  No string/number where union/enum/branded type appropriate?
CQ2:  All public function return types explicit? No implicit any?
CQ3:  CRITICAL -- Boundary validation complete? Required fields, format/range, runtime schema?
CQ4:  CRITICAL -- Guards reinforced by query-level filtering? Guard NOT sole defense?
CQ5:  CRITICAL -- No sensitive data in logs/errors/responses?
CQ6:  CRITICAL -- No unbounded memory from external data? Pagination/streaming?
CQ7:  DB queries bounded? LIMIT/cursor present? Slim payloads?
CQ8:  CRITICAL -- Infra failures handled? Timeouts on outbound? No empty catch?
CQ9:  Multi-table mutations in transactions? FK order correct?
CQ10: Nullable values handled? No silent null propagation? No unsafe array[0]/.find()?
CQ11: Functions <= 50 lines? Single responsibility?
CQ12: No magic strings/numbers? No duplicate config keys?
CQ13: No dead code? No commented-out blocks?
CQ14: CRITICAL -- No duplicated logic (>10 lines repeated)?
CQ15: Every async awaited or fire-and-forget with .catch()? No dropped promises?
CQ16: Money uses exact arithmetic (Decimal/integer-cents)? No float for money?
CQ17: No sequential await in loops where batch/parallel works?
CQ18: Cross-system data consistency? Multi-store writes handle partial failures?
CQ19: API request AND response validated by runtime schema?
CQ20: Each data point ONE canonical source? No dual fields?
CQ21: CONDITIONAL -- No TOCTOU? State machine transitions use CAS? Mutations idempotent?
CQ22: CONDITIONAL -- All listeners/timers/subscriptions cleaned up on unmount?
CQ23: CONDITIONAL -- Cache has TTL or explicit invalidation? No stale-forever entries?
CQ24: CONDITIONAL -- API changes additive only? Breaking changes have deprecation path?
CQ25: New code follows existing project patterns? No special snowflakes?
CQ26: Structured logger with context (requestId, userId), not plain console.log?
CQ27: Log levels correct? `error` for infra failures only, not validation?
CQ28: CONDITIONAL -- Timeout hierarchy correct? client < server < DB?
CQ29: Workspace path alias (@/, ~/, #/) used for imports >=3 hops deep when alias is configured? N/A if no alias in workspace.

ANTI-PATTERNS (each found = noted, severity attached):
CAP1:  Empty catch block -- HIGH
CAP2:  Plain `console.log` in production -- MEDIUM. `console.warn`/`console.error` allowed ONLY when paired with Sentry.captureMessage/captureException on the same code path; otherwise MEDIUM.
CAP3:  `as any` / `as unknown as X` without validation -- MEDIUM (x5+ = HIGH). `as unknown as <DomainType>` after Prisma/ORM queries = HIGH (silent contract bypass).
CAP4:  @ts-ignore without justification -- MEDIUM
CAP5:  Hardcoded secret -- AUTO TIER-D
CAP6:  Unsanitized HTML reaching DOM or persistence -- AUTO TIER-D. Covers `dangerouslySetInnerHTML` without DOMPurify, `editor.commands.setContent(rawHtml)`/raw-HTML mode without pre-save sanitization, paste-as-HTML, programmatic raw HTML writes. Display-time sanitization alone is INSUFFICIENT if persistence path is unsanitized.
CAP7:  eval() / new Function() with dynamic input -- AUTO TIER-D
CAP8:  SQL string concatenation OR `$queryRaw`/`$executeRawUnsafe` against tenant tables without organizationId in WHERE -- AUTO TIER-D
CAP9:  File exceeds type limit (service <=450, controller <=300, hook <=250, component <=200, helper <=100) OR inline sub-component >=50 LOC nested in a parent component file -- HIGH (2x file limit = AUTO TIER-D)
CAP10: Function > 100 lines (2x the 50L limit) -- HIGH
CAP11: parseFloat/Number() on money field -- HIGH
CAP12: await inside for/while without batch alternative -- MEDIUM
CAP13: 7+ useState in one component, OR >=3 mutually-exclusive dialog/modal boolean flags (collapse to discriminated union `dialog: { kind: '...' } | null`), OR state mirroring URL params managed via local useState (use router query API) -- MEDIUM
CAP14: Business logic >10 lines in component body that has no DOM dependency -- MEDIUM
CAP15: API URL built without `encodeURIComponent` on dynamic path segments, OR hardcoded base URL string-concat (`` `${BASE}/api/foo/${id}` ``), OR unencoded user-controlled token in URL path/query -- HIGH. MUST use a single `buildApiUrl(path, pathParams)` helper and validate enum-typed segments against an allowlist before interpolation.
CAP16: Client auth-token plumbing race (deferred-promise wait for provider, token injected mid-flight, no readiness gate before first request), OR missing 401-> refresh-> retry-once on REST clients while tRPC has it (or vice versa), OR unsigned/dev-only tokens accepted as auth credentials in any environment -- HIGH
CAP17: `error.message` rendered directly to UI/DOM without a curated `userMessageFor(error)` mapping -- HIGH. Leaks server stack/PII; map known error types to safe messages and fall back to a generic "Something went wrong".
CAP18: `throw new Error(...)` from a service/injectable/handler -- MEDIUM. Use a typed exception class instead (BadRequestException, NotFoundException, custom DomainError); bare Error loses HTTP status mapping and can leak the original message into 5xx response bodies.
CAP19: Mutating endpoint, AI/expensive operation (LLM call, export, generation), webhook receiver, or tRPC procedure without a rate limiter (ThrottlerGuard, custom limiter, queue with concurrency cap) -- HIGH. tRPC bypassing the project-wide ThrottlerGuard = always violation.

N/A HANDLING: N/A items are excluded from both numerator and denominator. Score = passed / applicable. N/A requires justification.

STATIC CRITICAL GATE: CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 -- any = 0 -> capped at Tier C.
CONDITIONAL CRITICAL GATE:
- CQ16 -> critical if file handles money (prices, costs, discounts, invoices)
- CQ19 -> critical if CONTROLLER or API-CALL type. Thin controller exception: if only returns typed service data, gate does not activate.
- CQ20 -> critical if file defines entities with dual fields
- CQ21 -> critical if concurrent mutations on same resource
- CQ22 -> critical if creates subscriptions, timers, observers
- CQ23 -> critical if uses Redis, Memcached, or in-memory cache
- CQ24 -> critical if modifies existing API endpoint signatures
- CQ28 -> critical if defines timeouts at 2+ architectural layers

CQ8 NOTE: Check PROJECT_CONTEXT. If global error handler exists, services that let errors propagate = CQ8 PASS. Only CQ8=0 when errors are swallowed.
CQ15 NOTE: `return somePromise` inside async function is NOT a missing await -- async auto-flattens. Only flag when promise is neither returned nor awaited.
CQ19 NOTE: Thin controllers that only return typed service data get gate cap = B, not C.

OUTPUT FORMAT per file:
### [filename]
Code type: [TYPE]
Lines: [count]
Red flags: [CAP5/6/7/8 = auto Tier-D; or "none"]
Score: CQ1=[0/1] CQ2=[0/1] ... CQ29=[0/1/N/A]
Anti-patterns: [CAP IDs found, or "none"]
Total: [passed]/[applicable] ([%]) -- N/A excluded
Static gate: CQ3=... CQ4=... CQ5=... CQ6=... CQ8=... CQ14=... -> [PASS/FAIL]
Conditional gate: [which activated] -> [PASS/FAIL/none]
Evidence (critical gates scored 1): [CQ=evidence pairs, file:line]
Tier: [A/B/C/D]
Top 3 issues: [brief]

TIER CLASSIFICATION:
  A (>=25/29, all active gates PASS): Production-ready
  B (22-24, all active gates PASS): Conditional pass
  C (17-21, or any critical gate FAIL with score >=17): Significant rework
  D (<17 or AUTO TIER-D red flag): Critical -- immediate fix

IMPORTANT:
- Read the FULL file before scoring
- Do red flag pre-scan first
- For CQ3: check for DTO/schema at entry point. "Validation exists somewhere" = 0.
- For CQ4: look for ownership check followed by query WITHOUT that owner in WHERE. In --deep mode for SERVICE files, read the associated controller to verify.
- For CQ11: count lines per function. Limits vary by type (see file-limits.md).
- For CQ14: list methods >20 lines. Compare pairs for structural similarity.
- For CQ16: search for parseFloat/Number() on price/cost/amount fields.
- For CQ17: search for await inside loops. Check if batch alternative exists.
- For CQ19: check both request DTO AND response shape validation.
- For CQ20: search for field_id + field_name pairs.
- Evidence REQUIRED for --deep mode (all CQs). For --quick: evidence required only for critical gates scored 1.
- GATE N/A REPORTING: N/A gates are skipped, not converted to 1.

Files to audit:
[BATCH FILE LIST]
```

---

## Phase 2: Aggregate Results

Collect all agent outputs and build the summary report.

### Summary Table

```markdown
# Code Quality Audit Report

Date: [date]
Project: [name]
Files audited: [N]
Mode: [quick/deep]

## Summary by Tier

| Tier | Count | % | Action |
|------|-------|---|--------|
| A (>=25/29) | [N] | [%] | Production-ready |
| B (21-23) | [N] | [%] | Targeted fixes before merge |
| C (16-20) | [N] | [%] | Significant rework |
| D (<16 or red flag) | [N] | [%] | Critical -- immediate fix |

## Summary by Code Type

| Type | Files | Avg Score | Worst CQ | Notes |
|------|-------|-----------|----------|-------|
| SERVICE | [N] | [avg] | [most failed CQ] | |
| CONTROLLER | [N] | [avg] | | |

## Critical Gate Failures

| File | Score | Failed CQs | Impact |
|------|-------|------------|--------|

## Conditional Gate Failures

| File | Score | Failed CQs | Why Activated | Impact |
|------|-------|------------|---------------|--------|

## Red Flag Summary (Auto Tier-D)

| File | Red Flag | Details |
|------|----------|---------|

## Top Failed CQs (across all files)

| CQ | Category | Fail count | % of files | Pattern |
|----|----------|-----------|------------|---------|

## Anti-pattern Hot Spots

| Anti-pattern | Severity | Files affected | Instances |
|-------------|----------|---------------|-----------|

## Tier D -- Critical Fix Queue (worst first)
## Tier C -- Rework Queue
## Tier B -- Targeted Fix Queue
## Tier A -- Production Ready
```

## Phase 3: Cross-File Analysis

After per-file scoring, run these cross-cutting checks:

1. **Cross-file duplication** -- If CQ14=0 in multiple files in the same module, check for shared duplicated logic between those files
2. **Inconsistent patterns** -- If some services use transactions (CQ9=1) and structurally similar ones do not (CQ9=0), flag the inconsistency
3. **Validation chain gaps** -- If a controller has CQ3=1 but the service it calls has CQ3=N/A ("internal"), verify the service is truly never called from another entry point
4. **Money handling inconsistency** -- If some files use Decimal (CQ16=1) and others use float for the same domain, flag project-wide drift

Add findings under a `## Cross-File Issues` section.

## Phase 3b: Adversarial Review on Audit Report (MANDATORY — do NOT skip)

After the audit report is generated, run cross-model validation to catch score inflation and gate inconsistency. Runs on ALL audits (not just --deep).

```bash
adversarial-review --mode audit --files "audits/code-quality-audit-[date].md"
```

If `adversarial-review` is not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

Wait for complete output. Then:
- **CRITICAL** (FAIL gate not in verdict, severity mismatch) → fix in report before delivery
- **WARNING** (N/A abuse, skipped check) → append to Known Gaps section
- **INFO** → ignore

## Phase 4: Report and Execution Plan

Save the report to: `audits/code-quality-audit-[date].md`
If `--deep` mode: also save per-file detail to `audits/code-audit-details/[filename].md`

### Execution Plan (appended to report)

```markdown
## Recommended Execution Plan

### Goal
- Raise score from [current avg]/29 to min [target]/29
- Close all critical gate FAILs
- Add regression tests for every P0/P1 change

### Priority Order
1. P0 (production blockers): [Tier D red flags + critical gate FAILs]
2. P1 (high risk / stability): [remaining Tier C issues]
3. P2 (maintenance / readability): [Tier B gaps]

### Fix Plan (per issue)

| Priority | CQ/CAP | Where (file:line) | What to change | Tests needed | Est. |
|----------|--------|-------------------|----------------|-------------|------|

### Project-Wide Patterns
- [N] files missing input validation (CQ3) -- consider global validation pipe
- [N] files using float for money (CQ16) -- adopt Decimal project-wide

### Re-audit Expected Deltas

| CQ/CAP | Before | After | Files affected |
|--------|--------|-------|----------------|

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Domain classified and printed: [data/async/security/general]
[ ] Red flag pre-scan ran on every batch
[ ] Global error handler detection ran
[ ] Adversarial review ran on audit report (--mode audit)
[ ] Cross-file analysis section present
[ ] Report saved to audits/
[ ] Backlog updated for deferred findings
[ ] Run: line printed and appended to log
```

## CODE AUDIT COMPLETE

Run: <ISO-8601-Z>\tcode-audit\t<project>\t<N-critical>\t<N-total>\t<VERDICT>\t-\t<N>-dimensions\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).
```

## Phase 5: Backlog Persistence

Persist findings to `memory/backlog.md`:

1. Read `memory/backlog.md`. If missing, create with template.
2. Fingerprint each finding: `file|CQ-id|signature`. Dedup: existing = increment `Seen`. New = append `B-{N}`.
3. Delete resolved items (Tier A files with open items).

Full protocol: `../../shared/includes/backlog-protocol.md`.

**Which findings to persist:**
- **Tier D** (red flags, <16): ALL findings -- CRITICAL severity
- **Tier C** (critical gate FAIL or 16-20): ALL critical gate failures -- HIGH severity
- **Tier B** (21-23): only critical gate near-misses -- MEDIUM severity
- **Tier A** (>=24): do NOT persist. Delete any open backlog items for Tier A files.

## Phase 6: Next-Action Routing

After the report, propose what to do next:

| Audit Result | Suggested Action | Reason |
|--------------|-----------------|--------|
| Tier D files exist | "Fix Tier D files" | Security/critical issues first |
| CQ14=0 in 2+ files (shared duplication) | `zuvo:refactor` on shared module | Duplication across files = structural problem |
| Same CQ fails in 3+ files | "Fix [CQ] across all affected files" | Pattern fix |
| CQ18=0 (multi-store sync) | `zuvo:build` to add sync mechanism | New infrastructure needed |
| Structural issues (wrong layers, circular deps) | `zuvo:architecture review [path]` | Needs architectural view first |
| Only Tier B/C with varied issues | "Fix top 3 critical gate failures" | Highest ROI |
| All Tier A | No action needed | Everything is production-ready |

## Execution Notes

- Use **Sonnet** for all batch agents in QUICK and STANDARD modes
- Use **Opus** for DEEP mode batch agents
- Process batches sequentially in Cursor/Codex. Claude Code may parallelize with up to 6 Task agents.
- Read the project's AGENTS.md or CLAUDE.md first for stack-specific conventions
- Estimated durations: QUICK ~2 min for 50 files, DEEP ~15 min for 50 files
