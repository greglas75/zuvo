---
name: dependency-audit
description: >
  Dependency health and internal coupling audit for Node.js/TypeScript projects.
  10 dimensions: supply chain vulnerabilities, freshness, dead dependencies,
  license compliance, bundle weight, circular dependencies, coupling metrics,
  architecture boundary violations, barrel file health, and change coupling.
  Tiered tooling with graceful degradation.
  Switches: zuvo:dependency-audit full | [path] | --supply-chain | --coupling | --dead | --bundle | --lock-in
---

# zuvo:dependency-audit

Audit external dependency health and internal module coupling. Scores 10
dimensions with tiered tooling -- gracefully degrades when specialized tools
are unavailable.

**Scope:** Node.js / TypeScript projects (npm, pnpm, yarn, bun).
**When to use:** Before releases, after adding many dependencies, periodic
health check, after monorepo restructuring, before lock-in reviews.
**When NOT to use:** Code quality (`zuvo:review`), DB-specific
(`zuvo:db-audit`), full-stack performance (`zuvo:performance-audit`), OWASP
(`/security-audit`).

## Known Limitations

- Node.js/TypeScript only. Python, Go, Rust, and Java are not supported.
- `npm query` selectors are npm-specific. pnpm/yarn/bun fall back to lockfile
  analysis.
- D5 (bundle impact) uses Bundlephobia API for triage -- not precise without
  actual build statistics.
- D7 (instability metrics) requires dependency-cruiser for Ca/Ce/I. Without it,
  only fan-in/fan-out via grep.
- D10 (change coupling) requires 3+ months of git history.
- Monorepo workspace scoping is partial -- tools operate on workspace root
  unless filtered.

## Mandatory File Loading

Read every file below before starting. Print the checklist.

```
CORE FILES LOADED:
  1. {plugin_root}/shared/includes/codesift-setup.md   -- [READ | MISSING -> STOP]
  2. {plugin_root}/shared/includes/env-compat.md        -- [READ | MISSING -> STOP]
  3. {plugin_root}/rules/cq-patterns.md                 -- [READ | MISSING -> STOP]
  4. {plugin_root}/shared/includes/auto-docs.md          -- READ/MISSING
  5. {plugin_root}/shared/includes/session-memory.md     -- READ/MISSING
```

If any file is MISSING, STOP. Do not proceed from memory.

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All 10 dimensions, scope = project root |
| `[path]` | Scope to a package or directory (see scope rules below) |
| `--supply-chain` | D1 only |
| `--coupling` | D6, D7, D8, D9 only |
| `--dead` | D3 only |
| `--bundle` | D5 only |
| `--lock-in` | D7 vendor lock-in focus |
| `--no-api` | Skip Bundlephobia and OpenSSF API calls |

**Path scope rules:**

| Path points to | Manifest found? | D1-D5 (external) | D6-D10 (internal) |
|----------------|-----------------|-------------------|---------------------|
| Package root (own `package.json`) | Yes | Score for this package | Score within path |
| Subdirectory within a package | Inherited from parent | Mark INHERITED | Score within path |
| No `package.json` above | No | Mark SKIPPED | Score within path |

---

## Safety Gate

This audit is **read-only**. The only write target is `audits/`. Do not
install, uninstall, or modify any dependency. Do not run `npm audit fix` or
equivalent automatically.

---

## Phase 0: Preflight

### 0.1 Manifest and Lockfile

```
Step 1: Find package.json at TARGET_ROOT, walk up to project root if needed.
        If not found -> STOP: "No package.json. This skill requires Node.js."

Step 2: Find lockfile (package-lock.json, pnpm-lock.yaml, yarn.lock, bun.lockb).

Step 3: Validate package manager works: <pm> ls --json 2>&1

Decision matrix:
  | Manifest | Lockfile | node_modules | Action |
  |----------|----------|-------------|--------|
  | Yes | Yes | Yes | Full audit D1-D10 |
  | Yes | Yes | No | STOP: "Run <pm> install first." |
  | Yes | No | Yes | D1 capped at 6/15. D1.5 = CRITICAL. |
  | Yes | No | No | STOP: "No lockfile and no node_modules." |
  | No | -- | -- | STOP: "No package.json found." |
```

### 0.2 Package Manager Detection

| Signal | PM |
|--------|----|
| `package-lock.json` | npm |
| `pnpm-lock.yaml` | pnpm |
| `yarn.lock` | Yarn (detect version: `yarn --version`, 1.x = Classic, 2+ = Berry) |
| `bun.lockb` or `bun.lock` | Bun |

### 0.3 Framework Detection (for D8 layer rules)

| Signal | Framework | Layer Pattern |
|--------|-----------|---------------|
| `next.config.*` | Next.js App Router | app/ (server) -> lib/ -> components/ (client) |
| `nest-cli.json` or `@nestjs/core` | NestJS | controllers -> services -> repositories |
| `vite.config.*` + no SSR | Vite SPA | pages -> features -> shared |
| `express` in deps | Express | routes -> middleware -> services |

### 0.4 Tool Availability

Run in parallel:

```bash
# Tier 1 -- PM built-in
<pm> audit --json 2>/dev/null
<pm> ls --json 2>/dev/null
<pm> outdated --json 2>/dev/null

# Tier 2 -- npx (no install)
npx knip --reporter json 2>/dev/null
npx license-checker --json --production 2>/dev/null

# Tier 3 -- check availability
npx depcruise --version 2>/dev/null
npx madge --version 2>/dev/null
```

Record which tools are available. Missing tools degrade specific dimensions
but do not block the audit.

---

## Phase 1: Data Collection

### 1.1 External Dependency Data

**PM audit output:** Vulnerability report with severity levels.

**PM outdated output:** Current vs latest version for each dependency.

**Lockfile analysis:**
- Install scripts (`postinstall`, `preinstall`)
- Git dependencies (`git+`, `github:`)
- Lockfile integrity (uncommitted changes, drift from manifest)

**Manifest analysis:** Read `package.json` -- count prod/dev deps, version
specifier types (`^`, `~`, exact), overrides, resolutions.

### 1.2 Internal Dependency Graph

**With dependency-cruiser:**
```bash
npx depcruise --no-config --output-type json --metrics TARGET_ROOT
```

**With madge (fallback):**
```bash
npx madge --json TARGET_ROOT
npx madge --circular --json --ts-config tsconfig.json TARGET_ROOT
npx madge --orphans --json TARGET_ROOT
```

**Grep fallback (always available):**
Search for import/export statements to build an approximate dependency graph.

---

## Phase 2: Dimension Analysis (D1-D10)

### Agent Dispatch

Refer to `env-compat.md` for the dispatch pattern.

**When parallel dispatch is available:**

| Agent | Dimensions | Input |
|-------|-----------|-------|
| Supply Chain Scanner | D1, D4 | PM audit, lockfile, license data |
| Coupling Analyzer | D6, D7, D8, D9 | dep-cruiser/madge output |
| Freshness Checker | D2, D3, D5 | PM outdated, knip output |

**D10 (Change Coupling)** runs in the lead agent (requires git log).

**Without parallel dispatch:** Execute all dimensions sequentially.

### D1: Supply Chain and Vulnerabilities -- Weight 15, Max 15, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Known CVEs | Zero critical/high CVEs in production deps | Unpatched critical CVE | CRITICAL |
| Install scripts | Only trusted packages run postinstall | Unknown package with postinstall | HIGH |
| Signature verification | Lockfile signatures verified | No signature verification | MEDIUM |
| Git dependencies | Zero git deps in production | `git+` URLs bypass registry auditing | HIGH |
| Lockfile integrity | Committed, matches manifest, reproducible | Missing or diverged lockfile | HIGH |

Critical gate: D1=0 (known exploit-grade CVE in production) triggers FAIL.

### D2: Freshness and Maintenance Health -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Major version lag | Within 1 major version of latest | 3+ major versions behind | HIGH |
| Maintenance status | Active maintainer, recent releases | Abandoned (no release > 2 years) | HIGH |
| Deprecated packages | Zero deprecated deps | Using packages with `npm deprecate` notice | MEDIUM |

### D3: Dead Dependencies -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Unused production deps | Zero unused in `dependencies` | Package in manifest, never imported | HIGH |
| Phantom dependencies | All imports resolve to declared deps | Import works only because of hoisting | MEDIUM |
| Duplicate functionality | One library per task (date, HTTP, validation) | lodash + underscore + ramda all installed | MEDIUM |

Use `knip` output when available. Otherwise grep for import statements and
cross-reference against `package.json` dependencies.

### D4: License Compliance -- Weight 8, Max 8, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Copyleft in production | Zero GPL/AGPL in bundled code | GPL dependency in production app | CRITICAL |
| Unknown licenses | All deps have declared licenses | Missing license field | MEDIUM |
| License compatibility | All licenses compatible with project license | Conflicting license chain | HIGH |

Critical gate: D4=0 (GPL in production closed-source app) triggers FAIL.

### D5: Bundle and Weight Impact -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Heavy dependencies | Alternatives exist for large deps (moment -> dayjs, lodash -> native) | 500 KB+ dep used for one function | HIGH |
| Tree-shaking support | `sideEffects: false` in dep, ESM exports | CommonJS-only dep in frontend bundle | MEDIUM |
| Duplicate versions | Single version in bundle | 3 versions of the same package | MEDIUM |

### D6: Circular Dependencies -- Weight 12, Max 12, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Runtime cycles | Zero circular dependency chains at runtime | Module A imports B, B imports A | CRITICAL |
| Type-only cycles | Type-only imports (`import type`) are acceptable | Type cycle causes runtime initialization bug | LOW |
| Cycle depth | N/A | 4+ module cycle chain | HIGH |

Critical gate: D6=0 (runtime circular dependency causing initialization bug)
triggers FAIL.

### D7: Coupling Metrics -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Instability (I = Ce/(Ca+Ce)) | Balanced: stable foundations, unstable leaves | Core module with I > 0.8 (depends on everything) | HIGH |
| Fan-out | Module imports < 10 direct dependencies | Single file imports 30+ modules | HIGH |
| Fan-in | Shared module is aware of its consumers | Utility used by 50+ files, fragile to change | MEDIUM |
| Vendor lock-in | Adapter pattern around vendor SDKs | Vendor SDK calls spread across 20+ files | MEDIUM |

### D8: Architecture Boundary Violations -- Weight 12, Max 12, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Layer enforcement | UI -> Services -> Data, never backward | Component imports from data layer directly | HIGH |
| Secret in client | Server-only vars never imported in client code | Client bundle imports `process.env.SECRET` | CRITICAL |
| Domain boundaries | Features do not cross-import internal modules | Feature A reaches into Feature B internals | MEDIUM |

Critical gate: D8=0 (secret leaked to client bundle) triggers FAIL.

### D9: Barrel File Health -- Weight 7, Max 7

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Re-export scope | Barrel re-exports < 5 symbols, public API only | `export *` pulling in 50+ symbols | HIGH |
| Circular risk | Barrel does not create import cycles | Barrel creates cycle between modules | HIGH |
| Tree-shake impact | `sideEffects: false` set, named exports | Barrel defeats tree-shaking | MEDIUM |

### D10: Change Coupling -- Weight 8, Max 8

Analyze git history (last 6 months) for files that always change together:

```bash
git log --name-only --pretty=format:"---COMMIT---" --since="6 months ago" -- TARGET_ROOT
```

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Co-change clusters | Related files change together (test + impl) | Unrelated modules always change together | HIGH |
| Shotgun surgery | Feature change touches 1-3 files | Every feature touches 10+ files | HIGH |
| God module churn | Hot files are small and well-tested | Largest file is also most-changed | CRITICAL |

---

## Phase 3: Verification and Scoring

### False Positive Filters

| Pattern | Skip When |
|---------|-----------|
| Install script flagged | Well-known build tool (esbuild, sharp, prisma, @swc/core) |
| Unused dep | Framework plugin loaded via config (knip handles 139+ but misses some) |
| Circular dep | Type-only cycle (`import type`) with `isolatedModules` |
| Floating `^` version | Lockfile present and committed |
| Layer violation in Next.js | Server component IS the server layer |
| Barrel flagged | < 5 re-exports AND no circular deps caused |
| `export *` | `sideEffects: false` is set in the package |

### Scoring

**Critical gates:** D1=0, D4=0, D6=0, D8=0 -- any triggers FAIL.

**N/A handling:** Exclude dimensions with INSUFFICIENT DATA, SKIPPED, or
INHERITED from both numerator and denominator.

| Grade | Percentage |
|-------|-----------|
| A | >= 85% |
| B | 70-84% |
| C | 50-69% |
| D | < 50% |

---

## Phase 4: Report

Save to: `audits/dependency-audit-[YYYY-MM-DD].md`

### Report Structure

```markdown
# Dependency & Coupling Audit Report

## Metadata
| Field | Value |
|-------|-------|
| Project | [name] |
| Date | [YYYY-MM-DD] |
| Package Manager | [npm/pnpm/yarn/bun] |
| Scope | [full / path] |
| Total prod deps | [N] |
| Total dev deps | [N] |

## Executive Summary

**Score: [N] / [MAX]** -- [A/B/C/D or FAIL]

| Metric | Count |
|--------|-------|
| CRITICAL findings | N |
| HIGH findings | N |
| MEDIUM findings | N |

[2-3 sentence summary]

## Dimension Scores

| # | Dimension | Score | Max | Tool Used | Notes |
|---|-----------|-------|-----|-----------|-------|
| D1 | Supply Chain | [N] | 15 | <pm> audit | |
| D2 | Freshness | [N] | 10 | <pm> outdated | |
| D3 | Dead Deps | [N] | 10 | knip / grep | |
| D4 | Licenses | [N] | 8 | license-checker | |
| D5 | Bundle Weight | [N] | 8 | Bundlephobia | |
| D6 | Circular Deps | [N] | 12 | dep-cruiser / madge | |
| D7 | Coupling Metrics | [N] | 10 | dep-cruiser / grep | |
| D8 | Architecture | [N] | 12 | dep-cruiser / grep | |
| D9 | Barrel Health | [N] | 7 | grep | |
| D10 | Change Coupling | [N] | 8 | git log | |
| **Total** | | **[N]** | **[M]** | | |

## Critical Gate Status
[D1, D4, D6, D8 -- PASS/FAIL per gate]

## Delete These Tomorrow
[Unused deps that can be removed with zero code changes]

## Findings (sorted by severity)
[Per finding: ID, severity, dimension, description, fix]

## Cross-Cutting Patterns

| Pattern | Dims | Impact |
|---------|------|--------|
| Barrel causing circular deps | D9+D6 | Fix barrel, cycles disappear |
| God module + high churn | D7+D10 | Max blast radius on hot code |
| Unused dep with known CVE | D3+D1 | Dead code + security risk |

## Remediation Roadmap

### Quick Wins (< 1 hour)
### Short-term (1 day)
### Medium-term (1 week)
```

---

## Phase 5: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
D1 CRITICAL (CVE)           -> npm audit fix or manual upgrade
D4 GPL in production        -> replace with MIT/Apache alternative
D6 runtime circular dep     -> zuvo:refactor [module path]
D8 boundary violation       -> zuvo:refactor [violating file]
D9 barrel causing cycles    -> zuvo:refactor [barrel file]
D10 high change coupling    -> zuvo:refactor [coupled files]
Score < 60%                 -> prioritize "Delete These Tomorrow" list first
Score >= 85%                -> schedule next audit in 3 months
------------------------------------
```

---

## Execution Notes

- All commands use the resolved `TARGET_ROOT` from argument parsing
- CodeSift integration follows `codesift-setup.md`
- Agent dispatch follows `env-compat.md`
- Tool unavailability degrades individual dimensions, not the entire audit
- Yarn version detection is critical: Classic (1.x) and Berry (2+) have
  different command syntax
- `npm query` selectors are npm-only; pnpm/yarn/bun use lockfile grep as
  fallback
- `--no-api` flag skips Bundlephobia and OpenSSF calls for air-gapped or
  rate-limited environments

---

## Auto-Docs

After completing the skill output, update per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the dependency audit scope, key findings, and verdict.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with dependency audit summary and verdict.

---

## Run Log

Log this run to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`:
- SKILL: `dependency-audit`
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: PASS/WARN/FAIL from findings
- TASKS: number of dependencies audited
- DURATION: `-`
- NOTES: scope summary (max 80 chars)
