---
name: performance-audit
description: >
  Full-stack performance health check across 12 dimensions. Rendering, bundles,
  assets, API/network, algorithms, memory, database, caching, Web Vitals,
  backend runtime, concurrency, and framework-specific pathologies. Evidence-based
  Impact Models with confidence tiers and a prioritized optimization roadmap.
  Switches: zuvo:performance-audit full | [path] | [file] | --frontend | --backend | --db | --bundle
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - analyze_complexity       # KEY — algorithmic hot spots
    - analyze_hotspots         # KEY — git-churn × complexity
    - audit_scan               # compound (incl. find_perf_hotspots-equivalent)
    - search_patterns          # n-plus-one-django, await-in-loop, sync-fs etc.
    - find_clones              # repeated work patterns
    - get_file_tree
    - get_file_outline
    - search_text
    - search_symbols
    - get_symbol
    - get_symbols
    - find_references
    - trace_call_chain         # waterfall tracing
  by_stack:
    typescript: [get_type_info, resolve_constant_value]
    javascript: []
    python: [python_audit, analyze_async_correctness, resolve_constant_value]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit, astro_image_audit, astro_svg_components]
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

# zuvo:performance-audit

Measure, score, and prioritize performance across the entire stack. Every finding
carries an Impact Model (estimated savings, blast radius, confidence level) so
the team can act on data instead of hunches.

**When to use:** Periodic health check, before major release, after heavy feature
work, when users report slowness, before scaling infrastructure.
**When NOT to use:** Code quality (`zuvo:review`), security (`/security-audit`),
test quality (`/test-audit`).

## Guiding Principles

1. Performance claims without measurement are opinions, not findings.
2. "Slow" without a baseline and a target is meaningless.
3. Optimization without profiling is premature optimization.
4. When evidence is absent, report INSUFFICIENT DATA -- never guess.

## Mandatory File Loading

Read every file below before starting. Print the checklist.

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md   -- [READ | MISSING -> STOP]
  2. ../../shared/includes/env-compat.md        -- [READ | MISSING -> STOP]
  3. ../../rules/cq-patterns.md                 -- [READ | MISSING -> STOP]
  4. ../../shared/includes/run-logger.md        -- [READ | MISSING -> STOP]
  5. ../../shared/includes/retrospective.md        -- [READ | MISSING -> STOP]
```

If any file is MISSING, STOP. Do not proceed from memory.

### Conditional Files

| File | Load when |
|------|-----------|
| `../../rules/cq-checklist.md` | Scoring cross-cutting CQ overlap (CQ6 resources, CQ7 unbounded, CQ17 N+1) |

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All applicable dimensions across the entire project |
| `[path]` | Scope to a directory or module |
| `[file]` | Deep single-file audit (algorithms, memory, complexity) |
| `--frontend` | D1-D3, D10 only |
| `--backend` | D4-D5, D7-D8, D11-D12 only |
| `--db` | D7 only (database queries and schema) |
| `--bundle` | D2 only (bundle weight analysis) |

---

## Safety Gate

This audit is **read-only**. The only write target is `audits/`. Do not modify
source files, configs, build output, or runtime environments. Tooling probes
(bundle analysis, Lighthouse) may be invoked but must not alter the build.

---

## MANDATORY TOOL CALLS — Performance Audit Validity Gate

**This audit is INVALID if any tool below is skipped when its trigger condition holds.** "DEFERRED", "N/A", "--frontend only" are NOT valid reasons for tools relevant to the scoped scope.

| Tool | Trigger | Reason | Skip allowed? |
|------|---------|--------|---------------|
| `analyze_complexity` | Always | KEY — algorithmic hot spots, CC distribution, outliers | **NO** |
| `analyze_hotspots` | Always | KEY — git-churn × complexity (last 90d) | **NO** |
| `audit_scan` | Always | Compound including find_perf_hotspots-equivalent | **NO** |
| `search_patterns(n-plus-one-django\|await-in-loop\|sync-fs)` | Always | D-dim anti-patterns | **NO** |
| `find_clones` | Always | Repeated-work patterns | **NO** |
| `trace_call_chain` | Any HIGH/MEDIUM finding cites a function | Waterfall + downstream impact | **NO** when condition holds |
| `analyze_renders` + `analyze_hooks` | React detected | D-frontend gates | **NO** when React |
| Stack-specific (analyze_prisma_schema/explain_query/python_audit/etc.) | Framework/ORM detected | Stack-specific perf gates | **NO** when matches |

### Forbidden escape hatches: `analyze_complexity: skipped`, `analyze_hotspots: N/A`, `codesift: unavailable` (when deferred), `retrospective: skipped` — all REJECTED.

### Required POSTAMBLE: report on disk → retro appended → `~/.zuvo/append-runlog` exit 0. Every HIGH/MEDIUM finding needs `path/to/file.ext:LINE` (verify-audit gate).

### Mandatory acknowledgment (REQUIRED — print verbatim before Phase 0)

```
Mandatory-tools-acknowledgment: I will run analyze_complexity + analyze_hotspots + audit_scan + search_patterns(n+1, await-in-loop) + find_clones + trace_call_chain (on cited functions) + analyze_renders/analyze_hooks (when React) + stack-specific tools for this performance audit. Every HIGH/MEDIUM finding will cite a `path/to/file.ext:LINE` resolving in the current tree.
```

### CodeSift preload

**Use the deterministic preload helper FIRST.** Run `~/.zuvo/compute-preload performance-audit "$PWD"` before any ToolSearch. Copy `[CodeSift matching trace]` verbatim, issue printed `ToolSearch(query="select:...")`. Math gate enforced.

---

## Phase 0: Detect and Prepare

### 0.1 Technology Stack Detection

Detect framework, bundler, backend, ORM, and deployment model before analysis.
Different stacks exhibit different pathologies.

**Frontend signals:**
- `next.config.*` -- Next.js (SSR + RSC + client)
- `vite.config.*` -- Vite (SPA or SSR)
- `webpack.config.*` -- Webpack
- `svelte.config.*` -- SvelteKit
- React / Vue / Angular in dependencies

**Dormant-frontend detection:** flag as a D2 finding (unused deps) + D9 finding
(architectural debt) when any of these are true:
- `webpack.config.*` returns `[]` or `{}` (empty entry)
- `package.json` declares React/Vue/Webpack but the source tree has zero
  `*.tsx`/`*.jsx`/`*.vue` files
- `assets/` directory is empty and referenced only by dead build scripts

Dormant frontends are a silent cost: install weight, lockfile churn, and CI
time for code that never ships. Call them out even when the profile is
backend-heavy.

**Backend signals:**
- `@nestjs/core` or `nest-cli.json` -- NestJS
- `express` in deps -- Express
- `fastify` in deps -- Fastify
- `FastAPI` or `APIRouter` in Python files -- FastAPI
- `gin-gonic` in Go files -- Gin
- `composer.json` has `yiisoft/yii2` -- Yii2 (PHP)
- `composer.json` has `laravel/framework` -- Laravel (PHP)
- `composer.json` has `symfony/framework-bundle` -- Symfony (PHP)

**ORM / database signals:**
- `prisma/schema.prisma` -- Prisma
- `@Entity` decorators -- TypeORM
- `from sqlalchemy` -- SQLAlchemy
- `mongoose` / `mongodb` -- MongoDB

**Deployment signals:**
- `vercel.json`, `netlify.toml` -- Serverless edge
- `wrangler.toml` -- Cloudflare Workers
- `Dockerfile` -- Containerized
- `serverless.yml` -- AWS Lambda

Print detection results:

```
PERFORMANCE STACK
------------------------------------
Frontend:  [React / Next.js / Vue / SvelteKit / none]
Bundler:   [Vite / Webpack / Turbopack / none]
Backend:   [NestJS / Express / FastAPI / Gin / none]
ORM:       [Prisma / TypeORM / SQLAlchemy / none]
Deploy:    [Serverless / Container / Traditional]
------------------------------------
```

### 0.2 Profile Selection

| Profile | Stack | Active Dimensions |
|---------|-------|-------------------|
| A | Full-stack JS/TS (Next.js + Node + DB) | D1-D12 |
| B | Backend-only (Python/Go + DB) | D4-D9, D11-D12 |
| C | Frontend SPA (React/Vue + API calls) | D1-D3, D9-D10 |
| D | Static / JAMstack | D1-D3, D10 |
| E | Monorepo | Per-package profile, weighted merge |
| F | PHP full-stack (Yii2/Laravel/Symfony + MySQL/Postgres) | D2, D4-D9, D11-D12 (D11 = opcache, JIT, FPM tuning) |

Profile E: detect workspace packages, assign profile per package, audit
individually, merge into a weighted final report.

Profile F: load `rules/yii2.md` (if Yii2 detected) for framework-specific
performance checks. D11 Runtime pivots from Node.js event-loop checks to
opcache/JIT/FPM pool tuning. Apply `rules/php.md` for general PHP patterns.

### 0.3 Tooling Probe

Check which measurement tools are available before declaring audit confidence.

**Frontend tools:**
- Build output with source maps (`dist/`, `.next/`, `build/`)
- Bundle analyzer (`source-map-explorer`, `vite-bundle-visualizer`, `@next/bundle-analyzer`)
- Lighthouse CLI

**Backend tools:**
- Node.js profiler (`clinic`, `0x`)
- Python profiler (`py-spy`, `cProfile`)
- Go profiler (`pprof`)
- Load tester (`autocannon`, `wrk`, `k6`)

**Database tools:**
- `psql` for EXPLAIN ANALYZE (PostgreSQL)
- `mongosh` for explain plans (MongoDB)

Print the checklist with installed/missing status and install commands for
anything missing.

### 0.4 Audit Confidence Tier

| Tools Available | Tier | Max Confidence |
|-----------------|------|----------------|
| Profiler + bundle analyzer + Lighthouse | FULL | HIGH |
| Bundle analyzer OR Lighthouse (not both) | STANDARD | MEDIUM |
| Code inspection only | PARTIAL | LOW |
| No tools, no build output | MINIMAL | LOW |

For PARTIAL/MINIMAL audits, include a Prerequisites section in the report
listing what is needed to upgrade to FULL.

---

## Phase 1: Hot Path Identification

Performance audits focus on hot paths, not the entire codebase. Identify them
before dimension analysis.

### 1.1 Entry Points

Discover API handlers, page components, middleware, cron jobs, and queue
workers. Use CodeSift (`search_symbols`, `trace_route`) when available,
otherwise grep for framework-specific decorators and route patterns.

### 1.2 Traffic Estimation

Rank entry points by expected traffic:

| Signal | Weight |
|--------|--------|
| Public-facing page / API route | HIGH |
| Authenticated user route | MEDIUM |
| Admin-only route | LOW |
| Cron / queue worker | BY FREQUENCY |

### 1.3 Call Depth Scan

For each high-traffic entry point, trace the call chain (CodeSift
`trace_call_chain` or grep-based import tracing) to find:
- Database queries (N+1, unbounded, missing index)
- External API calls (no timeout, no retry)
- Heavy computation (nested loops, serialization, regex)
- Memory accumulation (unbounded arrays, no streaming)

### 1.4 Sync I/O Scan

Search for synchronous operations on the event loop:

```
readFileSync, writeFileSync, execSync, crypto.pbkdf2Sync
```

These block the thread and are CRITICAL in request handlers, LOW in build
scripts or CLI tools.

---

## Phase 2: Dimension Analysis (D1-D12)

### Agent Dispatch

Refer to `env-compat.md` for the dispatch pattern.

**When parallel dispatch is available:**

| Agent | Dimensions | Focus |
|-------|-----------|-------|
| Frontend Analyst | D1, D2, D3, D10 | Rendering, bundles, assets, Web Vitals |
| Backend Analyst | D4, D5, D11, D12 | API, algorithms, runtime, concurrency |
| Data Layer Analyst | D6, D7, D8, D9 | Memory, database, caching, framework |

**Without parallel dispatch:** Execute all dimensions sequentially.

Each agent receives the detected stack, hot path list, and tooling checklist.

### D1: Rendering Performance -- Weight 12, Max 12

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Unnecessary re-renders | Components memoized where needed, deps arrays correct | Parent re-render cascades through deep tree | HIGH |
| Virtualization | Large lists use windowing (`react-window`, `tanstack-virtual`) | 1000+ items rendered to DOM | HIGH |
| Lazy loading | Route-level code splitting, dynamic imports for heavy modules | Entire app in one bundle | MEDIUM |
| Server components | Data-fetching components are server-side (Next.js RSC) | Client components fetch everything | MEDIUM |

Score 0-12 based on evidence.

### D2: Bundle Size -- Weight 12, Max 12

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Total JS size | < 200 KB gzipped main bundle | > 500 KB gzipped | CRITICAL |
| Tree shaking | `sideEffects: false`, named imports from large libs | `import _ from 'lodash'` (full lib) | HIGH |
| Duplicate dependencies | Single version of each library in bundle | Multiple React/moment copies | MEDIUM |
| Dynamic imports | Heavy features loaded on demand | Everything in initial chunk | MEDIUM |

If bundle analyzer is available, parse the output for precise measurements.
Otherwise score from `package.json` dependency analysis and import patterns.

### D3: Asset Optimization -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Image format | WebP/AVIF with fallbacks, `next/image` or equivalent | Unoptimized PNG/JPG served directly | HIGH |
| Font loading | `font-display: swap`, subset fonts, preload critical | Flash of invisible text, full font files | MEDIUM |
| Compression | Brotli/gzip on all text assets | No compression configured | MEDIUM |
| Preloading | Critical resources preloaded, non-critical deferred | Everything loaded eagerly | LOW |

### D4: API and Network -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Request waterfall | Parallel fetches, batched queries | Sequential requests that could be parallel | HIGH |
| Payload size | Selective fields, pagination, gzip | Full objects returned, no pagination | HIGH |
| Timeout + retry | AbortSignal on every outbound call, exponential backoff | No timeout, infinite hang on failure | CRITICAL |
| Cache headers | `Cache-Control`, `ETag`, `stale-while-revalidate` | No caching headers on stable resources | MEDIUM |

### D5: Algorithm Complexity -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Loop complexity | O(n) or O(n log n) for hot paths | O(n^2) find() inside loop, nested iterations | HIGH |
| Data structures | Map/Set for lookups, indexed access | Array.find() in loops (O(n^2)) | HIGH |
| Regex safety | Anchored patterns, no catastrophic backtracking | User input in unanchored regex | CRITICAL |
| String concatenation | Template literals or array join | Repeated `+=` in loops | LOW |

### D6: Memory Management -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Leak prevention | useEffect cleanup, removeEventListener, clearInterval | Missing cleanup in components/services | CRITICAL |
| Accumulation bounds | Arrays capped, streams used for large data | Unbounded push() in loops | HIGH |
| Closure capture | Refs for mutable values in callbacks, weak references | Stale closure over entire component state | MEDIUM |
| GC pressure | Object pooling for hot paths, avoid allocations in tight loops | New object per iteration | LOW |

### D7: Database Performance -- Weight 12, Max 12, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| N+1 queries | Eager loading (`include`), batched IDs (`where: { id: { in } }`) | Query inside loop | CRITICAL |
| Unbounded queries | `take`/`LIMIT` on every query, pagination | `findMany()` without limit | CRITICAL |
| Index coverage | Indexes on filter/sort columns, composite indexes for common queries | Sequential scan on large tables | HIGH |
| Connection pooling | Configured pool with limits, singleton client | New client per request, no pool | HIGH |

Critical gate: D7=0 (N+1 in hot path) triggers audit FAIL.

### D8: Caching Strategy -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Application cache | Redis/Memcached for expensive queries, TTL configured | No caching, every request hits DB | HIGH |
| HTTP cache | Immutable assets with hash, revalidation for dynamic | No cache headers anywhere | MEDIUM |
| Memoization | `useMemo`/`useCallback` for expensive computations, correct deps | Memoize everything (or nothing) | MEDIUM |
| Cache invalidation | Event-driven or TTL with jitter, no stale-forever | Manual cache clear, no strategy | MEDIUM |

### D9: Framework-Specific -- Weight 8, Max 8

Patterns depend on detected stack. Examples:

**Next.js:** missing `loading.tsx`, client components fetching data, no
`generateStaticParams`, ISR not configured.

**NestJS:** missing interceptors for response transform, no request scoping
for heavy services, guards running expensive queries.

**FastAPI:** sync endpoint handlers, missing `async def`, no connection pooling
in `Depends`.

**React:** prop drilling causing re-renders, context value unstable reference,
uncontrolled form re-renders.

### D10: Web Vitals / Core Metrics -- Weight 10, Max 10

| Metric | Good | Needs Improvement | Poor |
|--------|------|-------------------|------|
| LCP | < 2.5s | 2.5-4.0s | > 4.0s |
| INP | < 200ms | 200-500ms | > 500ms |
| CLS | < 0.1 | 0.1-0.25 | > 0.25 |

If Lighthouse is available, run it and extract scores. Otherwise evaluate from
code patterns:
- LCP: largest visible element loading strategy, image optimization, font loading
- INP: event handler complexity, main thread blocking
- CLS: explicit dimensions on images/embeds, font swap strategy

### D11: Backend Runtime -- Weight 6, Max 6

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Sync I/O on event loop | All I/O async in request handlers | readFileSync in API handler | CRITICAL |
| Worker threads | CPU-heavy tasks offloaded to workers or queues | Crypto/PDF in main thread | HIGH |
| Startup time | Lazy module loading, minimal bootstrap | Heavy initialization blocks first request | MEDIUM |

### D12: Concurrency and Throughput -- Weight 6, Max 6

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Fan-out limiting | `pLimit` or similar for parallel external calls | Unbounded Promise.all on user-sized input | CRITICAL |
| Queue usage | Background jobs for heavy work (email, PDF, analytics) | Synchronous heavy work in request handler | HIGH |
| Connection limits | Pool sizes configured per downstream service | Default unlimited connections | MEDIUM |

---

## Phase 3: Verification and Impact Models

### 3.1 False Positive Filters

| Pattern | Skip When |
|---------|-----------|
| Missing memo | Component renders once (no parent re-render path) |
| Large bundle | Dev-only dependency (`devDependencies`) |
| No cache | Data changes on every request (real-time feed) |
| Sync I/O | Build script, CLI tool, or migration (not request handler) |
| N+1 query | Loop is bounded AND documented as intentional |
| Missing index | Table known to be small (< 1000 rows) |

### 3.2 Impact Model Format

Every finding above LOW severity must include an Impact Model:

```
FINDING: [ID] [SEVERITY] [dimension] -- [description]
  File: [path:line]
  Impact Model:
    Estimated savings: [X ms / X KB / X% CPU -- with reasoning]
    Blast radius:      [N requests/sec affected | N page loads/day]
    Effort:            [S/M/L -- with specific change description]
    Confidence:        [HIGH (measured) | MEDIUM (heuristic) | LOW (estimate)]
    Priority score:    Impact / Effort = [N]
```

### 3.3 Severity Classification

| Level | Criteria |
|-------|----------|
| CRITICAL | User-visible latency > 3s, OOM risk, thread blocking, data loss |
| HIGH | Measurable degradation (> 500ms), scalability wall, resource waste |
| MEDIUM | Suboptimal pattern, future scaling concern, missed optimization |
| LOW | Best practice gap, marginal improvement, future-proofing |

---

## Phase 4: Cross-Cutting Analysis

Flag compound patterns that are worse than individual findings:

| Pattern | Dimensions | Impact |
|---------|-----------|--------|
| N+1 on unindexed column | D5+D7 | Exponential degradation under load |
| Unbounded query result accumulated in memory | D6+D7 | OOM on production data volumes |
| External API in transaction without timeout | D4+D7+D12 | Connection pool exhaustion |
| Barrel re-exports defeating tree shaking | D2+D9 | Bundle bloat from dead code |
| Missing cleanup + missing virtualization | D1+D6 | Memory leak on long-lived pages |
| Sync I/O + no worker threads | D11+D12 | Event loop blocked, throughput collapse |

---

## Phase 5: Report

Save to: `audits/performance-audit-[YYYY-MM-DD].md`

**REQUIRED:** emit the Tool Availability Block (template in `../../shared/includes/codesift-setup.md`) at the top of the report, after the title and before findings. Auditing degraded runs depends on this — do NOT skip it.

### Report Structure

```markdown
# Performance Audit Report

## Metadata
| Field | Value |
|-------|-------|
| Project | [name] |
| Date | [YYYY-MM-DD] |
| Profile | [A/B/C/D/E] |
| Stack | [detected stack] |
| Audit tier | [FULL / STANDARD / PARTIAL / MINIMAL] |
| Scope | [full / path] |

## Executive Summary

**Score: [N] / [MAX]** -- [grade]

| Metric | Count |
|--------|-------|
| CRITICAL findings | N |
| HIGH findings | N |
| MEDIUM findings | N |
| LOW findings | N |

[2-3 sentence summary with top optimization opportunity and estimated savings]

## Dimension Scores

| # | Dimension | Score | Max | Confidence | Key Finding |
|---|-----------|-------|-----|------------|-------------|
| D1 | Rendering | [N] | 12 | [H/M/L] | |
| D2 | Bundle Size | [N] | 12 | | |
| D3 | Assets | [N] | 8 | | |
| D4 | API/Network | [N] | 10 | | |
| D5 | Algorithms | [N] | 10 | | |
| D6 | Memory | [N] | 10 | | |
| D7 | Database | [N] | 12 | | |
| D8 | Caching | [N] | 8 | | |
| D9 | Framework | [N] | 8 | | |
| D10 | Web Vitals | [N] | 10 | | |
| D11 | Runtime | [N] | 6 | | |
| D12 | Concurrency | [N] | 6 | | |
| **Total** | | **[N]** | **[M]** | | |

N/A dimensions excluded from both score and max.

## Critical Gates
[D7=0 triggers FAIL. List gate status.]

## Findings (sorted by priority score)

[Per finding: ID, severity, dimension, description, Impact Model, fix]

## Cross-Cutting Patterns

[Compound patterns found]

## Optimization Roadmap

### Quick Wins (< 1 hour, high impact)
[Items with highest Priority score = Impact / Effort]

### Short-term (1 day)
[Moderate effort, measurable gains]

### Medium-term (1 week)
[Architectural improvements, caching infrastructure]

### Long-term (1 month+)
[Infrastructure changes, major refactors]

## Prerequisites for Higher Confidence
[If PARTIAL/MINIMAL: what tools to install, what data to collect]
```

### Scoring

Weighted total across active dimensions. N/A dimensions excluded from both
numerator and denominator.

| Grade | Percentage |
|-------|-----------|
| A | >= 85% |
| B | 70-84% |
| C | 50-69% |
| D | < 50% |

Critical gate: D7=0 (N+1 in hot path) overrides to FAIL regardless of total.

### Backlog Integration

For each HIGH+ finding, propose a backlog entry:

```
/backlog add PERF-D7: N+1 in OrderService.list() -- findMany inside forEach.
Fix: eager load with include or batch with where { id: { in: ids } }
```

---

## Phase 6: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
D7 CRITICAL (N+1)        -> zuvo:refactor [service file]
D2 > 500 KB bundle       -> tree-shake + code-split (direct fix)
D11 sync I/O on event loop -> zuvo:refactor [handler file]
D4 no timeouts           -> direct fix (add AbortSignal)
Score < 60%              -> prioritize quick wins, re-audit in 2 weeks
Score >= 85%             -> schedule next audit in 3 months
------------------------------------
```

---

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] Profile selected and printed (A/B/C/D/E) with active dimensions
[ ] Audit confidence tier declared (FULL/STANDARD/PARTIAL/MINIMAL)
[ ] Hot path identification ran
[ ] Every HIGH+ finding has Impact Model with estimated savings
[ ] D7 critical gate printed (N+1 in hot path)
[ ] Report saved to audits/ with optimization roadmap
[ ] Run: line printed and appended to log
```

## PERFORMANCE-AUDIT COMPLETE

Score: [N] / [MAX] -- [grade]
Profile: [A/B/C/D/E] | Audit tier: [FULL/STANDARD/PARTIAL/MINIMAL]
Dimensions: [N scored] | Critical gates: [PASS/FAIL]
Findings: [N critical] / [N total]

### Validity Gate (REQUIRED — print BEFORE Run line, AFTER retro append + append-runlog)

```
VALIDITY GATE
  triggers_held: language=<X> framework=<X> react=<yes|no> orm=<prisma|drizzle|none>
  required_tool_calls:
    analyze_complexity: [<max_cc> max | NOT_CALLED — VIOLATES_TRIGGER]
    analyze_hotspots: [<top_N> hotspots | NOT_CALLED — VIOLATES_TRIGGER]
    audit_scan: [<N> findings | NOT_CALLED — VIOLATES_TRIGGER]
    search_patterns: [<N> hits | NOT_CALLED — VIOLATES_TRIGGER]
    find_clones: [<N> clusters | NOT_CALLED — VIOLATES_TRIGGER]
    trace_call_chain: [<N> chains | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    analyze_renders/analyze_hooks: [<N> | not_required (no React) | NOT_CALLED — VIOLATES_TRIGGER]
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

Run: <ISO-8601-Z>	performance-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).

---

## Execution Notes

- All commands use the resolved `TARGET_ROOT` from argument parsing
- CodeSift integration follows `codesift-setup.md` -- use indexed search when
  available, fall back to Grep/Read/Glob when not
- Agent dispatch follows `env-compat.md` -- parallel when supported, sequential
  otherwise
- Impact Models are the primary decision tool -- findings without an Impact
  Model are informational only
- Confidence levels are strict: only profiler/Lighthouse/EXPLAIN output earns
  HIGH confidence; code inspection maxes out at MEDIUM
