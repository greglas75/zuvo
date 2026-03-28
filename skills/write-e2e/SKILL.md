---
name: write-e2e
description: >
  Generate Playwright E2E tests from codebase analysis. Discovers routes,
  scores user flows by criticality, generates .spec.ts with page objects
  and quality gates. Code-first with optional browser validation.
  Modes: [path] (scoped), --live (browser-assisted), --auto (no
  interaction), --flows (discover only), --max-flows N, --dry-run.
---

# zuvo:write-e2e — E2E Test Generation

Generate Playwright E2E tests by scanning the codebase for testable surfaces. Discovers routes and user flows, ranks them by criticality, generates .spec.ts files with quality gates, and optionally validates against a running application.

**Scope:** Web applications with routes, forms, and user interactions that need browser-level test coverage.
**Out of scope:** Unit/integration tests (use `zuvo:write-tests`), auditing existing E2E quality (use `zuvo:test-audit`), fixing flaky E2E tests (use `zuvo:fix-tests`).

Generated tests are starting points for human review -- not production-ready without verification.

## Argument Parsing

Parse `$ARGUMENTS` as: `[path] [--live [url]] [--auto] [--flows] [--max-flows N] [--dry-run]`

| Argument | Mode | Description |
|----------|------|-------------|
| _(empty)_ | FULL | Discover, plan, user selects, generate |
| `[path]` | SCOPED | Generate E2E for a specific page or route |
| `--live` | LIVE | Browser-assisted: locator validation and test execution |
| `--live [url]` | URL | Navigate to URL, snapshot DOM, generate for that page only |
| `--auto` | AUTO | Skip user selection, take top N flows by score |
| `--flows` | DISCOVER | Phase 0-1 only -- show scored flow list, no generation |
| `--max-flows N` | LIMIT | Cap generation at N flows (default: 20) |
| `--dry-run` | PREVIEW | Show what would be generated, write no files |

Flags compose freely. Example: `zuvo:write-e2e --live --auto --max-flows 5` runs live mode, auto-selects the top 5 flows.

Defaults: `MAX_FLOWS=20`, `LIVE=false`, `AUTO=false`, `DRY_RUN=false`, `FLOWS_ONLY=false`.

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch and path resolution.

Non-interactive environments (Codex, Cursor) always behave as `--auto`.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for initialization.

**Key tools for this skill:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 0 | Route inventory | `get_file_tree(repo, path_prefix="app")` | `Glob("app/**/*.{tsx,ts}")` |
| 0 | Interactive components | `search_symbols(repo, "Form|Modal|Dialog")` | Grep |
| 0 | API endpoints | `trace_route(repo, "/api/*")` | `Grep("POST|PUT|DELETE|@Get|@Post")` |
| 0 | Auth detection | `codebase_retrieval(repo, queries=[{type:"semantic", query:"authentication flow"}])` | Grep for auth packages |
| 1 | Mutation detection | `search_text(repo, "useMutation|onSubmit", file_pattern="*.tsx")` | Grep |

---

## Mandatory File Reading

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-patterns.md            -- [READ | MISSING -> STOP]
  2. {plugin_root}/rules/file-limits.md             -- [READ | MISSING -> STOP]
  3. {plugin_root}/rules/testing.md                 -- [READ | MISSING -> STOP]
```

---

## Phase 0 Pre: Tool Detection

Check tool availability once at start:

1. **CodeSift:** Check whether CodeSift tools are available in the current environment. If available, use them. Otherwise fall back to Grep + Glob.

2. **Playwright browser tooling:** Check whether browser automation tools are available in the current environment. If available, set `PLAYWRIGHT_AVAILABLE=true`. If not and `--live` was requested, warn and fall back to code-only mode.

Print status:

```
TOOL STATUS
-----
CodeSift:       [available | grep fallback]
Playwright MCP: [available | --live disabled]
Mode:           [FULL | DEGRADED]
-----
```

---

## Agent Routing

| Agent | Purpose | Model | Type | Phase |
|-------|---------|-------|------|-------|
| Route Discoverer | Scan routes, components, API endpoints, auth patterns | Sonnet | Explore | 0 (parallel) |
| Coverage Analyzer | Inventory existing E2E files, map covered flows | Haiku | Explore | 0 (parallel) |
| Flow Planner | Score and rank candidate flows | Sonnet | Explore | 1 |
| Test Writer | Generate .spec.ts files per flow batch | Sonnet | Code | 2-3 (up to 3 parallel) |

---

## Stack Detection

Detect the web framework and auth provider before discovery.

### Framework

| Signal | Framework | Dev server |
|--------|-----------|-----------|
| `next.config.*` + `app/` dir | Next.js App Router | localhost:3000 |
| `next.config.*` + `pages/` dir | Next.js Pages Router | localhost:3000 |
| `vite.config.*` | Vite/React | localhost:5173 |
| `nest-cli.json` or `@nestjs/core` | NestJS API | API-only, use request context |
| `nuxt.config.*` | Nuxt | localhost:3000 |
| `angular.json` | Angular | localhost:4200 |
| Existing `playwright.config.*` | Any | Read existing config, do not overwrite |

### Auth Provider

| Signal | Provider | Fixture strategy |
|--------|----------|-----------------|
| `@clerk/nextjs` | Clerk | API-based login, storageState |
| `next-auth` | NextAuth | Session cookie injection |
| `@supabase/auth-helpers` | Supabase | signInWithPassword, storageState |
| `passport` | Passport.js | Form-based login via page helper |
| Custom `/api/auth/*` | Custom | Auto-detect from handler |
| None detected | Skip | No auth fixture generated |

Print: `STACK: [framework] | AUTH: [provider or none] | E2E DIR: [path or "will create"]`

---

## Phase 0: Discover

Scan the codebase for testable surfaces. Produce two layers: raw artifacts (routes, components, endpoints) and candidate flows (testable user journeys inferred from artifacts).

### Discovery Targets

| Target | What to find |
|--------|-------------|
| Routes | Every navigable path from app/, pages/, src/routes/ |
| Interactive components | Page-level forms, modals, dialogs |
| API endpoints | Route handlers, especially POST/PUT/DELETE mutations |
| Auth system | Login route, guard patterns, session management |
| Existing E2E | Inventory of flows already covered by test files |

Spawn Route Discoverer and Coverage Analyzer in parallel. Wait for both before Phase 1.

### Confidence Assignment

Every candidate flow gets a confidence level:

| Level | Criteria |
|-------|---------|
| HIGH | Route confirmed, data-testid attributes present, clear user interaction |
| MEDIUM | Route exists, component found, but interaction pattern unclear |
| LOW | API-only endpoint with no UI reference |
| CONDITIONAL | Feature-flagged or permission-gated flow |

---

## Phase 1: Score and Rank

Score each candidate flow on five weighted signals:

| Signal | Weight | Detection |
|--------|--------|-----------|
| Mutation type | 30 | POST/PUT/DELETE handler, form onSubmit, useMutation |
| Auth requirement | 20 | withAuth, @UseGuards, auth middleware |
| Data sensitivity | 20 | Keywords: payment, billing, password, delete, admin |
| User traffic proxy | 15 | Nav links, route depth, linked-from count |
| Existing coverage | 15 | Has E2E test? yes=0, no=15 |

### Score Tiers

| Range | Tier | Behavior |
|-------|------|----------|
| 70-100 | CRITICAL | Generate first |
| 40-69 | IMPORTANT | Generate if within max-flows |
| 15-39 | NICE-TO-HAVE | Generate only with --auto or explicit selection |
| 0-14 | SKIP | Static pages, dev-only routes |

### User Selection

Present the ranked list:

```
DISCOVERED FLOWS ([N] candidates)
-----
  Score  Confidence  Flow
  92     HIGH        auth/login (form submit -> session)
  88     HIGH        projects/create (form -> POST -> redirect)
  72     MEDIUM      settings/profile (form -> PUT)
-----
Generate which? (all / top N / select by name / --auto = top 20)
```

`--auto` or non-interactive environments: take top N by score without asking.

### Exit Points

- `--flows` mode: print scored flow list and STOP.
- `--dry-run` mode: continue to scaffold plan, then STOP before writing files.

---

## Failure Handling (Phase 0-1)

| Condition | Response |
|-----------|----------|
| No routes found | `ABORT: No routes detected. Is this a web application?` |
| Routes but no interactive flows | `WARNING: Found N routes, 0 interactive flows. Generate navigation tests? (y/n)` |
| Auth detected but not automatable | `WARNING: No programmatic login path found. Tests will not include auth.` |
| Monorepo without --path | `Multiple apps detected: [list]. Use [path] to scope to one.` |
| Zero flows selected | `Nothing selected. Use --auto for score-ranked generation.` |

---

## Phase 2: Scaffold

Generate supporting infrastructure for selected flows.

### Write Policy

| Action | Rule |
|--------|------|
| Create new files | Write directly |
| Modify playwright.config.ts | Propose diff, require confirmation |
| Modify existing test files | Never -- report only |
| Overwrite generated files | Ask first |

Generated files carry this header:

```typescript
// Generated by zuvo:write-e2e -- YYYY-MM-DD
// Flow: [name] | Score: [N] | Confidence: [level]
// Human review recommended before committing
```

### Output Structure

```
e2e/
  pages/           # POM files (only when 3+ reused interactions justify it)
  fixtures/
    auth.setup.ts
    test-data.ts
  flows/
    auth/
    crud/
    api/
  playwright.config.ts  # Proposed, not auto-written
```

### Page Object Model Decision

If a flow has 3+ interactions on the same page AND those interactions are reused across flows, generate a POM file (`pages/X.page.ts`). Otherwise, inline locators directly in the spec.

**Locator priority (strict order):** data-testid, role, aria-label, text, css (last resort).

### Auth Fixture

Generate `fixtures/auth.setup.ts` using the storageState pattern, adapted to the detected auth provider. If the provider is ambiguous, skip and note in output.

### TestID Suggestions

Scan components for interactive elements without data-testid. Print suggestions but do NOT modify production code:

```
SUGGESTED TESTID ADDITIONS:
  src/components/LoginForm.tsx:24  <button>  -> data-testid="login-submit"
  src/components/LoginForm.tsx:18  <input>   -> data-testid="login-email"
```

---

## Phase 3: Generate

For each selected flow, generate a .spec.ts file with:

| Category | Content | When |
|----------|---------|------|
| Happy path | Complete user journey: navigate, interact, assert outcome | Always |
| Error paths | Form validation errors, unauthorized, server error | If flow has form or auth |
| Edge cases | Empty state, boundary values, max-length inputs | If flow handles user data |
| API flows | Request context tests: status code + business fields | If flow is API-only |

### Quality Gates (E2E-Q1 through E2E-Q10)

After generating each spec, run the quality gate check:

| Gate | What it checks | Critical | Auto-fixable |
|------|---------------|----------|-------------|
| E2E-Q1 | No hardcoded waits (waitForTimeout) | Yes | Yes -- replace with waitForSelector/waitForResponse |
| E2E-Q2 | Stable locators (no nth(), no CSS path) | Yes | Yes -- use data-testid/role |
| E2E-Q3 | Test independence (no shared mutable state) | Yes | Yes -- extract to beforeEach/fixtures |
| E2E-Q5 | Auth via storageState (not login-per-test) | Yes | Yes -- redirect to fixture |
| E2E-Q4 | User-visible assertions | No | Flag only |
| E2E-Q6 | External API mocking | No | Provide route.fulfill template |
| E2E-Q7 | Error paths tested | No | Generate missing paths |
| E2E-Q8 | User journey test names | No | Flag only |
| E2E-Q9 | API field validation | No | Flag only |
| E2E-Q10 | Cleanup after destructive tests | No | Provide afterEach template |

Critical gates: auto-fix immediately. Non-critical: flag in output.

---

## Phase 4: Validate (--live only)

**Gate:** Only runs when `--live` is set and Playwright MCP is available. Otherwise: `VALIDATION SKIPPED -- requires --live flag and Playwright MCP.`

Run generated specs against the live application:

```bash
npx playwright test [generated specs] --reporter=json
```

Categorize each failure:

| Category | Signal | Recommendation |
|----------|--------|----------------|
| locatorMiss | Element not found, strict mode violation | Check data-testid in production code |
| timing | Not visible, waitFor timeout | Add waitForLoadState or waitForResponse |
| data | Assertion failed on expected value | Check test data factory |
| auth | 401/403, redirect to login | Check auth.setup.ts and storageState |
| backend | 500, connection refused | Backend issue, not a test problem |

Print categorized results. V1 diagnoses only -- does not auto-fix failures.

---

## Artifact Contract

Phase outputs persist to `memory/e2e-coverage.md`:

```
# E2E Coverage Registry
| Flow ID | Name | Score | Confidence | Status | Spec File | Last Updated |
|---------|------|-------|------------|--------|-----------|--------------|
```

Status progression: DISCOVERED -> PLANNED -> GENERATED -> VALIDATED / FAILED

---

## Completion Report

```
WRITE-E2E COMPLETE
-----
Flows generated:    [N] ([M] high, [K] medium confidence)
Files created:      [X] (.spec.ts) + [Y] (pages/fixtures)
Quality gates:      [N]/[N] passed ([M] auto-fixed)
TestID suggestions: [P] elements in [Q] files
Validation:         [N/M passed | skipped (no --live)]
-----
Human review recommended before committing.
```

---

## Decision Rules

1. Prefer existing Playwright config over inferred defaults.
2. Prefer additive generation over modifying existing files.
3. Prefer inline locators over POM unless the reuse threshold is met.
4. Skip LOW confidence flows in default mode.
5. Never generate auth fixture if the login strategy is ambiguous.
6. In monorepo, require scope to one app root.
7. Prefer sensible defaults over interactive questions.
