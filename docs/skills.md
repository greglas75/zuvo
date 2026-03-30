# Skills Reference

Zuvo includes 39 skills organized into 9 categories. Each skill is invoked via the Skill tool with the `zuvo:` namespace prefix (e.g., `zuvo:review`). The skill router auto-matches your intent, so explicit invocation is optional.

---

## Pipeline Skills

These enforce a strict sequence for non-trivial features. See [pipeline.md](pipeline.md) for the full flow.

| Skill | Description | When to use |
|-------|-------------|-------------|
| `zuvo:brainstorm` | Explores codebase, researches the problem space, and produces an approved design spec. 3 parallel agents (Code Explorer, Domain Researcher, Business Analyst) followed by collaborative design dialogue. | New feature touching 5+ files, unclear scope, needs design decisions |
| `zuvo:plan` | Decomposes an approved spec into ordered TDD tasks. 3 sequential agents (Architect, Tech Lead, QA Engineer) plus Team Lead synthesis. | After brainstorm produces a spec |
| `zuvo:execute` | Implements a plan task by task with TDD cycle and dual-review gates (spec compliance + quality). | After plan produces a task list |
| `zuvo:worktree` | Isolates work in a git worktree. CREATE mode sets up a new worktree; FINISH mode wraps up with merge/PR/cleanup options. | Branch isolation before executing a plan, or finishing worktree work |
| `zuvo:receive-review` | Processes code review feedback with a 6-step protocol: understand, verify against code, decide fix-or-pushback, implement. | When you receive PR review comments |

---

## Core Skills

Scoped task execution for common development work.

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:build` | Scoped feature development (1-5 files). Runs blast radius and duplication analysis in parallel, then TDD implementation with CQ/Q quality gates. | Small feature with clear scope | `--auto` (skip plan approval), `--auto-commit` |
| `zuvo:review` | Structured code review with parallel audit agents, confidence-scored triage, and optional auto-fix. Tiered output: MUST-FIX / RECOMMENDED / NIT. | After coding, before push | Scope: `staged`, `HEAD~N`, `[path]`, `[commit range]`. Modes: `fix`, `blocking`, `tag`, `batch` |
| `zuvo:refactor` | ETAP workflow (Evaluate, Test, Act, Prove) with resumable CONTRACT and batch processing. | Extracting, splitting, moving, renaming, simplifying code | Modes: `full`, `auto`, `quick`, `standard`, `plan-only`, `continue`, `batch <file>` |
| `zuvo:debug` | Five-phase bug investigation: reproduce, narrow, diagnose, fix, verify. Produces structured report with root cause analysis and regression test. | Any bug, error, or unexpected behavior | `--regression` (git bisect) |

---

## Audit Skills -- Code and Testing

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:code-audit` | Batch audit against CQ1-CQ22 gates and CAP1-CAP14 anti-patterns. Tiered output (A/B/C/D) with evidence-backed scoring. | Periodic health check, before releases, after adding many files | `all`, `[path]`, `[file]`, `--deep`, `--quick`, `--services`, `--controllers` |
| `zuvo:test-audit` | Batch audit against Q1-Q17 gates and AP1-AP29 anti-patterns. Detects orphan tests, phantom mocks, untested public methods, input echo assertions, weak matchers. | After mass test writing, when test quality is uncertain | `all`, `[path]`, `[file]`, `--deep`, `--quick`, `--include-e2e`, `--details` |
| `zuvo:api-audit` | API endpoint integrity across 10 dimensions (D1-D10): validation, payloads, pagination, errors, caching, auth, rate limiting, docs. | Before releases, after adding endpoints | `full`, `[path]`, `--static` |
| `zuvo:security-audit` | OWASP Top 10, auth/authz, secrets, injection, multi-tenant isolation, infrastructure. Sentry 3-tier confidence model. 14 dimensions (S1-S14). | Before releases, after auth/payment changes, quarterly | `[path]`, `full`, `--live-url <url>`, `--static`, `--quick`, `--persist-backlog` |
| `zuvo:pentest` | Hybrid white-box + black-box penetration testing (PT1-PT7). Source-to-sink tracing with optional runtime exploit verification. | After security-audit flags issues, before releases, CMS testing | `[path]`, `--url <url>`, `--from-audit <dir>`, `--cms <type>`, `--quick`, `--verify-live` |

---

## Audit Skills -- Infrastructure

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:performance-audit` | Full-stack performance across 12 dimensions: rendering, bundles, assets, API, algorithms, memory, DB, caching, Web Vitals, runtime, concurrency. | Before releases, after heavy features, when users report slowness | `full`, `[path]`, `[file]`, `--frontend`, `--backend`, `--db`, `--bundle` |
| `zuvo:db-audit` | Database performance and safety across 12 dimensions (DB1-DB12). 60+ checks. Code-level for all ORMs, optional live analysis via PostgreSQL/MySQL. | After schema changes, before optimizing queries | `full`, `[path]`, `[file]`, `--schema`, `--queries`, `--connections`, `--live <conn>` |
| `zuvo:dependency-audit` | Dependency health and coupling across 10 dimensions: supply chain, freshness, dead deps, licenses, bundle weight, circular deps, architecture violations. | Before releases, when adding major dependencies | `full`, `[path]`, `--supply-chain`, `--coupling`, `--dead`, `--bundle`, `--lock-in` |
| `zuvo:ci-audit` | CI/CD pipeline optimization across 10 dimensions (CI1-CI10): caching, parallelism, secrets, action pinning, Docker, test integration. Primary: GitHub Actions. | After changing CI workflows, when pipelines are slow | `full`, `[path]`, `--speed-only`, `--security-only` |
| `zuvo:env-audit` | Environment config across 8 dimensions (ENV1-ENV8): completeness, unused vars, validation, secret exposure, parity, type safety. | After adding env vars, before deploy, config-related debugging | `full`, `[path]`, `--secrets-only`, `--parity` |

---

## Audit Skills -- Structure and SEO

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:structure-audit` | Codebase organization across 13 dimensions (SA1-SA13): naming, depth, colocation, file size, dead code, complexity, duplication, hotspots. Tool-driven with CodeSift primary and CLI fallbacks. | When codebase feels messy, before major restructuring | `full`, `[path]`, `--naming`, `--size`, `--dead-code`, `--duplication`, `--hotspots`, `--quick`, `--fix` |
| `zuvo:seo-audit` | SEO/GEO audit across 13 dimensions with 6 critical gates. 59 checks across 13 dimensions on meta tags, structured data, AI crawlers, content, performance. Framework-aware. | Before launches, when SEO ranking drops | `full`, `[path]`, `--live-url <url>`, `--quick`, `--content-only`, `--geo`, `--persist-backlog` |
| `zuvo:seo-fix` | Apply SEO audit fixes with 3-tier safety model (SAFE/MODERATE/DANGEROUS). Reads audit JSON, applies framework-specific templates. | After seo-audit, to auto-fix findings | `--auto`, `--all`, `--dry-run`, `--fix-type`, `--finding` |
| `zuvo:architecture` | Three modes: review existing architecture (A1-A9), create ADRs, or design new systems. Uses CodeSift for module discovery and dependency mapping. | Architecture health check, documenting decisions, system design | `--mode review [path]`, `--mode adr`, `--mode design` |

---

## Design Skills

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:design` | Intent-first UI design with traceable decisions. Persists design system in `.interface-design/`. Domain exploration, component construction with checkpoints, craft validation. | Creating new UI, building design systems | `init`, `[component]`, `improve [path]`, `extract [path]`, `status`, `--quick`, `--dry-run` |
| `zuvo:design-review` | UI/UX consistency audit with DX1-DX20 checklist. Code-based + optional visual audit via chrome-devtools + WCAG accessibility via axe-core. DAP1-DAP12 anti-patterns. | After adding UI views, when UI feels inconsistent | `[path]`, `visual`, `--fix-critical`, `--dry-run`, `--max-files`, `--quick`, `loop` |
| `zuvo:ui-design-team` | Multi-agent UI review with 4 specialists: UX Researcher, Visual Designer, i18n/Multilingual QA, Accessibility/Performance Auditor. Lead Designer synthesizes into prioritized fixes. | Comprehensive UI review from multiple perspectives | `[file/path]`, `--screenshot`, `--mobile`, `--fix` |

---

## Testing Skills

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:write-tests` | Write tests for existing production code. Scans coverage gaps, classifies code types (11 categories), selects patterns per type, enforces Q1-Q17 gates. | Existing code lacking tests | `[path]`, `auto` (discover and loop), `--dry-run` |
| `zuvo:fix-tests` | Batch repair of systematic test anti-patterns. Targets one pattern at a time across all matching files with production context. | Same anti-pattern across many test files | `--triage`, `--pattern [ID] [path]`, `--dry-run`, `--bundle-gates` |
| `zuvo:write-e2e` | Generate Playwright E2E tests from codebase analysis. Discovers routes, scores flows by criticality, generates .spec.ts with page objects and quality gates. | Web apps needing browser-level test coverage | `[path]`, `--live`, `--auto`, `--flows`, `--max-flows N`, `--dry-run` |
| `zuvo:tests-performance` | Test suite speed audit. Measures baseline, audits runner config (TP1-TP17), identifies slow tests, ranks fixes by impact. | When test suite feels slow, after adding many tests | `full`, `baseline`, `verify`, `--no-run`, `--path <dir>` |

---

## Release Skills

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:ship` | Pre-merge release pipeline with auto-scaled review by diff size. Tests, version bump, changelog, tag, push or PR. | Code is ready to ship | `--fast`, `--full`, `--no-bump`, `--dry-run`, `patch`/`minor`/`major` |
| `zuvo:deploy` | Platform-aware deployment with health check and rollback. Detects Vercel, Fly, Netlify, Railway, GHA. | After ship, ready for production | `--url`, `--skip-ci-wait`, `--skip-health`, `#<number>` |
| `zuvo:canary` | Post-deploy monitoring with browser or HTTP mode. Configurable duration and interval. | After deploy, to verify production health | `--duration`, `--interval`, `--quick`, `--max-errors` |
| `zuvo:release-docs` | Diff-driven documentation sync. Delegates to zuvo:docs for changelog and staleness fixing. | After shipping, to keep docs current | `--dry-run`, `<range>` |
| `zuvo:retro` | Engineering retrospective from git metrics. Deployment frequency, lead time, churn, backlog health. | Periodically, or after a release cycle | `--since`, `--path`, `<range>` |

---

## Utility Skills

| Skill | Description | When to use | Key flags |
|-------|-------------|-------------|-----------|
| `zuvo:backlog` | Manage tech debt backlog. Supports add, list, fix, wontfix, delete, prioritize, and suggest. Used by audit and review skills to persist findings. | Viewing or managing accumulated tech debt | `list [category]`, `add [desc]`, `fix B-{N}`, `wontfix B-{N}`, `stats`, `prioritize`, `suggest` |
| `zuvo:docs` | Write and update documentation from actual codebase analysis. README, API reference, runbook, onboarding guide, changelog. Update mode patches stale sections. | After building features, when docs are outdated | `readme [path]`, `api [path]`, `runbook [topic]`, `onboarding`, `update [file]`, `changelog [range]` |
| `zuvo:presentation` | Generate PowerPoint (PPTX) presentations using python-pptx. Consistent theming, speaker notes, visual variety. | Creating slide decks | `[topic]`, `from [file]`, `--slides N`, `--theme dark\|light\|corporate`, `--outline-only` |
| `zuvo:using-zuvo` | Meta-skill router, always loaded at session start. Routes user intent to the correct skill. | Automatic -- you never invoke this directly |

---

## Skill count by category

| Category | Count |
|----------|-------|
| Pipeline | 5 |
| Core | 4 |
| Code/Test audits | 5 |
| Infra audits | 5 |
| Structure/SEO/Arch | 4 |
| Design | 3 |
| Testing | 4 |
| Release | 5 |
| Utility | 4 |
| **Total** | **39** |
