---
name: env-audit
description: >
  Environment variable and configuration audit. 8 dimensions (ENV1-ENV8):
  variable completeness, unused vars, startup validation, secret exposure,
  environment parity, type safety, default values, and documentation. Supports
  Node.js (.env/process.env), Python (os.environ/settings), and framework-specific
  patterns (Vite import.meta.env, Next.js NEXT_PUBLIC_).
  Switches: zuvo:env-audit full | [path] | --secrets-only | --parity
---

# zuvo:env-audit

Audit environment variable management for completeness, safety, and consistency
across development, staging, and production environments. Single-pass execution.

**When to use:** After adding new env vars, before production deploy, when
debugging config-related incidents, onboarding new environments, periodic check.
**When NOT to use:** Secret scanning in source code (`/security-audit`), CI
pipeline config (`zuvo:ci-audit`), infrastructure (`/security-audit`).

## Mandatory File Loading

Read every file below before starting. Print the checklist.

```
CORE FILES LOADED:
  1. {plugin_root}/shared/includes/codesift-setup.md   -- [READ | MISSING -> STOP]
  2. {plugin_root}/shared/includes/env-compat.md        -- [READ | MISSING -> STOP]
  3. {plugin_root}/shared/includes/run-logger.md        -- [READ | MISSING -> STOP]
```

If any file is MISSING, STOP. Do not proceed from memory.

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All 8 dimensions, scope = project root |
| `[path]` | Scope to a directory (monorepo package, module) |
| `--secrets-only` | ENV4 only -- focus on secret exposure |
| `--parity` | ENV5 only -- compare environment configurations |

---

## Safety Gates

### GATE 1 -- Read-Only

This audit is **read-only**. The only write target is `audits/`.

FORBIDDEN:
- Modifying any `.env`, config, or source file
- Creating or deleting environment variables
- Accessing external secret managers (analyze config references only)

### GATE 2 -- PII and Secret Censorship

When including env var values in the report:
- Replace actual values with `***`
- Show only variable names, never values
- Exception: `.env.example` placeholder values can be shown as-is

---

## Phase 0: Detect and Scope

### 0.1 Target Resolution

Set `TARGET_ROOT` from arguments. All subsequent commands use this path.

### 0.2 Stack Detection

Detect which env access patterns to search for:

| Signal | Stack | Access Pattern |
|--------|-------|----------------|
| `package.json` | Node.js | `process.env.VAR`, `process.env['VAR']` |
| `vite.config.*` | Vite | `import.meta.env.VITE_VAR` |
| `next.config.*` | Next.js | `process.env.NEXT_PUBLIC_VAR` (client-safe) |
| `requirements.txt`, `pyproject.toml` | Python | `os.environ['VAR']`, `os.getenv('VAR')`, `os.environ.get('VAR')` |
| `wrangler.toml` | Cloudflare Workers | `env.VAR` (binding) |
| `docker-compose.*` | Docker Compose | `environment:` / `env_file:` directives |

### 0.3 Variable Name Extraction

Build a comprehensive inventory by scanning code for all env access patterns
detected in 0.2. Collect unique variable names (not values).

### 0.4 Inventory

Cross-reference all sources:
1. Variables defined in `.env*` files (names only)
2. Variables accessed in code (from extraction)
3. Variables in Docker Compose, CI config, or cloud deployment files

Print:

```
ENV VAR INVENTORY
------------------------------------
Target:          [TARGET_ROOT]
Config sources:  [.env, .env.example, .env.local, ...]
Stack:           [Node.js / Python / Vite / Next.js]
Vars defined:    [N]
Vars used in code: [N]
------------------------------------
```

---

## Phase 1: Dimension Analysis (ENV1-ENV8)

Single-pass inline execution. No sub-agents required.

### ENV1: Variable Completeness -- Weight 15, Max 15, Critical Gate

Are all required env vars defined and documented?

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Code vs example coverage | All used vars listed in `.env.example` | Var used in code but missing from `.env.example` | CRITICAL |
| Required vars guarded | Startup fails fast on missing required var | App starts, crashes later when var accessed | CRITICAL |
| .env.example exists | Yes, with all vars and placeholder values | No `.env.example` at all | HIGH |
| Stale vars | No vars in `.env.example` that are unused in code | Accumulated dead config | MEDIUM |

**Detection approach:** Compare the set of variables found in code against the
set defined in `.env.example`. Report both directions: used-but-undocumented
and documented-but-unused.

Critical gate: ENV1=0 (no `.env.example` OR multiple critical vars
undocumented) triggers FAIL.

### ENV2: Unused Variables -- Weight 5, Max 5

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Defined but never used | All defined vars referenced in code | Stale vars accumulate | MEDIUM |
| Dead config sections | Removed features cleaned up | Config references removed features | LOW |

**Detection approach:** Check each var in `.env.example` against code access
patterns. A var referenced only in comments or documentation counts as unused.

### ENV3: Startup Validation -- Weight 15, Max 15, Critical Gate

Does the app fail fast on missing or invalid configuration?

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Schema validation | Zod/Joi/Pydantic/envalid validates all vars at startup | No validation, raw access everywhere | CRITICAL |
| Fail-fast behavior | App throws before serving requests on missing var | Starts, breaks when var first accessed | CRITICAL |
| Type coercion | Parsed and validated (parseInt, Number, schema) | Port used as string in numeric context | HIGH |

**What to search for:**
- Validation libraries: `z.object`, `Joi.object`, `BaseSettings`, `envalid`,
  `envsafe`, `convict`, `cleanEnv`, `ConfigModule`, `@IsString`
- Fail-fast patterns: `throw` with env/config message, `process.exit` on
  missing env
- Raw usage: `process.env.VAR` without validation wrapper
- NestJS: `ConfigModule.forRoot()` with `validationSchema`

Critical gate: ENV3=0 (no validation anywhere) triggers FAIL.

### ENV4: Secret Exposure -- Weight 15, Max 15, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| .env in .gitignore | `.env` and `.env.local` listed in .gitignore | .env committed to repository | CRITICAL |
| Client-side exposure | Only `NEXT_PUBLIC_`/`VITE_` vars are non-sensitive | API keys in `NEXT_PUBLIC_*` variables | CRITICAL |
| Hardcoded secrets | Secrets only in env vars or secret manager | API keys hardcoded in config files | CRITICAL |
| Docker image leakage | `.env` listed in .dockerignore | .env copied into Docker image | HIGH |
| Git history | No .env files in git history | Past .env commits (secrets may still be in history) | HIGH |

**Detection approach:**
- Check `.gitignore` for `.env` patterns
- `git ls-files` for committed `.env` files
- Search for `NEXT_PUBLIC_*KEY`, `NEXT_PUBLIC_*SECRET`, `VITE_*KEY` etc.
- Search for hardcoded secrets: `(api_key|secret|password|token)\s*[:=]\s*['"][^'"{}$]`
  excluding test/mock/example files
- Check `.dockerignore` for `.env`

Critical gate: ENV4=0 (secrets committed or API keys in client-side vars)
triggers FAIL.

### ENV5: Environment Parity -- Weight 10, Max 10

Are dev/staging/production environments consistent?

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Same var set across envs | All environments define the same variables | Prod has vars dev lacks | HIGH |
| Docker Compose alignment | `docker-compose` env matches app config | Docker sets vars not in `.env.example` | MEDIUM |
| Feature flag documentation | Feature flags documented per environment | Undocumented per-env behavior | MEDIUM |

**Detection approach:** Compare variable sets across all `.env*` files found
at the target root. Check Docker Compose `environment:` sections against the
`.env.example` inventory.

### ENV6: Type Safety -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Central config module | Typed config with validated accessors | Raw `process.env.X` scattered across 50+ files | HIGH |
| Boolean parsing | `=== 'true'` or schema-parsed | `if (process.env.FLAG)` (any string is truthy) | HIGH |
| Number parsing | `parseInt` with NaN check or schema | Port used as string | MEDIUM |
| Access centralization | < 3 files access `process.env` directly | 20+ files with raw env access | MEDIUM |

**Detection approach:** Count per-file occurrences of raw env access. Search
for boolean truthy gotchas (`if (process.env.VAR)`). Check for number
conversion patterns.

### ENV7: Default Values -- Weight 7, Max 7

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Dev-friendly defaults | `PORT ?? 3000` for local development | App crashes without complete `.env` | MEDIUM |
| No secret defaults | Secret vars always required, no fallback | `JWT_SECRET ?? 'default-secret'` | CRITICAL |
| Documented defaults | `.env.example` shows which vars have defaults | Developer cannot tell required vs optional | LOW |

**Detection approach:**
- Search for `??` and `||` operators after env access (Node.js)
- Search for `os.getenv('VAR', 'default')` patterns (Python)
- Flag any default on SECRET/KEY/PASSWORD/TOKEN variables

### ENV8: Documentation -- Weight 5, Max 5

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Inline comments | Each var in `.env.example` has a comment explaining purpose | Bare variable names only | MEDIUM |
| Required vs optional | Marked with `# Required` / `# Optional (default: 3000)` | No indication which vars are needed | MEDIUM |
| Setup instructions | README covers env setup | New developer has to guess | LOW |

---

## Phase 2: Scoring

```
ENV1 = [0-15]   Variable Completeness    (critical gate)
ENV2 = [0-5]    Unused Variables
ENV3 = [0-15]   Startup Validation       (critical gate)
ENV4 = [0-15]   Secret Exposure          (critical gate)
ENV5 = [0-10]   Environment Parity
ENV6 = [0-8]    Type Safety
ENV7 = [0-7]    Default Values
ENV8 = [0-5]    Documentation
```

**Score = sum / 80 x 100**

**Critical gates:** ENV1=0 OR ENV3=0 OR ENV4=0 triggers FAIL.

| Grade | Percentage |
|-------|-----------|
| HEALTHY | >= 80% |
| NEEDS ATTENTION | 60-79% |
| AT RISK | 40-59% |
| CRITICAL | < 40% |

---

## Phase 3: Report

Save to: `audits/env-audit-[YYYY-MM-DD].md`

### Report Structure

```markdown
# Environment & Configuration Audit Report

## Metadata
| Field | Value |
|-------|-------|
| Project | [name] |
| Date | [YYYY-MM-DD] |
| Scope | [TARGET_ROOT or full project] |
| Stack | [Node.js / Python / Vite / Next.js] |
| Config sources | [.env, .env.example, config.ts, ...] |
| Vars defined | [N] |
| Vars used in code | [N] |

## Executive Summary

**Score: [N] / 100** -- [HEALTHY / NEEDS ATTENTION / AT RISK / CRITICAL]

| Metric | Count |
|--------|-------|
| CRITICAL findings | N |
| HIGH findings | N |
| MEDIUM findings | N |

[2-3 sentence summary]

## Dimension Scores

| # | Dimension | Score | Max | Notes |
|---|-----------|-------|-----|-------|
| ENV1 | Variable Completeness | [N] | 15 | |
| ENV2 | Unused Variables | [N] | 5 | |
| ENV3 | Startup Validation | [N] | 15 | |
| ENV4 | Secret Exposure | [N] | 15 | |
| ENV5 | Environment Parity | [N] | 10 | |
| ENV6 | Type Safety | [N] | 8 | |
| ENV7 | Default Values | [N] | 7 | |
| ENV8 | Documentation | [N] | 5 | |
| **Total** | | **[N]** | **80** | |

## Variable Coverage Matrix

| Variable | .env.example | Code Usage | Validated | Type | Default | Secret? |
|----------|-------------|------------|-----------|------|---------|---------|
| DATABASE_URL | Y | Y (3 files) | Y (Zod) | string | none (required) | Y |
| PORT | Y | Y (1 file) | N (raw) | number | 3000 | N |
| ... | | | | | | |

## Findings (sorted by severity)
[Per finding: dimension, severity, file:line, description, fix]

## Remediation Roadmap

### Quick Wins (< 1 hour)
### Short-term (1 day)
### Medium-term (1 week)
```

### Report Validation

After writing, verify:
- Dimension scores sum to total
- Finding counts match Executive Summary
- Variable Coverage Matrix includes all discovered vars
- No actual secret values appear anywhere in the report (Gate 2)

---

## Phase 4: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
ENV4 CRITICAL (secrets exposed)  -> /security-audit --static
ENV3 = 0 (no validation)        -> add config schema (Zod/Joi/Pydantic)
ENV1 = 0 (no .env.example)      -> create .env.example from code usage
ENV7 secret defaults             -> remove default values from secret vars
Score < 60%                      -> fix critical gates, re-audit
Score >= 80%                     -> schedule next audit in 3 months
------------------------------------
```

---

## ENV-AUDIT COMPLETE

Score: [N] / 100 -- [grade]
Stack: [Node.js / Python / Vite / Next.js]
Dimensions: [N scored] | Critical gates: [PASS/FAIL]
Findings: [N critical] / [N total]
Run: <ISO-8601-Z>	env-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).

---

## Execution Notes

- Single-pass inline execution, no sub-agents required
- All commands use the resolved `TARGET_ROOT` from argument parsing
- Stack detection auto-selects the correct env access patterns (Node.js,
  Python, Vite, Next.js)
- NestJS projects: check `ConfigModule.forRoot()` and `ConfigService` usage
  patterns specifically
- Docker Compose: check both `environment:` and `env_file:` directives
- Monorepos: use `[path]` argument to scope to a specific package
- CodeSift is minimally used in this skill (env patterns are best found via
  grep), but `codesift-setup.md` is loaded for consistency
- The boolean truthy gotcha (`if (process.env.FLAG)` -- always true for any
  non-empty string) is a common source of production bugs; flag it prominently
