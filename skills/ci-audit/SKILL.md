---
name: ci-audit
description: >
  CI/CD pipeline audit for speed, cost, reliability, and security. 10 dimensions
  (CI1-CI10): caching, parallelism, conditional execution, artifacts, secret
  handling, action pinning, timeouts, Docker optimization, test integration,
  and pipeline speed. Primary support: GitHub Actions. Detection-level: GitLab CI,
  CircleCI.
  Switches: zuvo:ci-audit full | [path] | --speed-only | --security-only
---

# zuvo:ci-audit

Audit CI/CD pipelines for wasted time, insecure practices, and reliability
gaps. Single-pass execution, no sub-agents needed.

**Primary support:** GitHub Actions (full coverage of all 10 dimensions).
**Detection-level:** GitLab CI, CircleCI (adapted patterns, unsupported checks
scored as N/A).

**When to use:** After changing CI workflows, when pipelines are slow, before
release hardening, when CI costs are high, quarterly optimization.
**When NOT to use:** Application security (`/security-audit`), test quality
(`/test-audit`), test runner config (`/tests-performance`).

## Mandatory File Loading

Read every file below before starting. Print the checklist.

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md   -- [READ | MISSING -> STOP]
  2. ../../shared/includes/env-compat.md        -- [READ | MISSING -> STOP]
  3. ../../shared/includes/run-logger.md        -- [READ | MISSING -> STOP]
  4. ../../shared/includes/retrospective.md        -- [READ | MISSING -> STOP]
```

If any file is MISSING, STOP. Do not proceed from memory.

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All 10 dimensions, auto-detect CI config |
| `[path]` | Audit specific workflow file or CI config directory |
| `--speed-only` | CI1, CI7, CI9, CI10 only -- focus on pipeline duration |
| `--security-only` | CI5, CI6 only -- focus on secret handling and action pinning |

---

## Safety Gate

This audit is **read-only**. The only write target is `audits/`.

FORBIDDEN:
- Modifying any workflow or pipeline file
- Running CI pipelines or triggering builds
- Modifying secrets or environment variables
- Installing CI plugins or actions

---

## Phase 0: Detect and Scope

### 0.1 Platform Detection

Detect the CI platform and set scan targets.

| Signal | Platform |
|--------|----------|
| `.github/workflows/*.yml` or `uses:` pattern | GitHub Actions |
| `.gitlab-ci.yml` or `stages:` / `include:` pattern | GitLab CI |
| `.circleci/config.yml` or `orbs:` / `jobs:` pattern | CircleCI |

If a `[path]` argument is provided:
- File: scan that file, detect platform from content
- Directory: find CI config within, detect platform

If no argument: auto-detect from project root.

If no CI config found: report error and suggest checking file locations.

### 0.2 Workflow Inventory

List all CI workflows/jobs with their trigger events.

Print:

```
CI PIPELINE INVENTORY
------------------------------------
Platform:    [GitHub Actions / GitLab CI / CircleCI]
Scope:       [auto-detected / user-specified path]
Workflows:   [N]
Total jobs:  [N]
Docker builds: [Y/N]
------------------------------------
```

---

## Phase 1: Dimension Analysis (CI1-CI10)

Single-pass inline execution. No sub-agents required.

### CI1: Caching Strategy -- Weight 15, Max 15

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Dependency cache | Cache configured for package manager | No caching, full install every run | HIGH |
| Cache key includes lockfile hash | Key derived from lockfile content (`hashFiles`) | Static key or no key | MEDIUM |
| Build cache | Turbo/nx cache, Docker layer cache | Rebuild from scratch every run | HIGH |
| Cache restore fallback | Fallback keys for partial cache hits | Cache miss = full rebuild | LOW |

**What to search for:**
- GitHub Actions: `actions/cache`, `setup-node` with `cache:`, `hashFiles`, `restore-keys`
- GitLab CI: `cache:` sections, `key:` with `$CI_COMMIT` or lockfile reference
- CircleCI: `save_cache` / `restore_cache`, `checksum`

Score 0-15 based on coverage.

### CI2: Parallelism and Job Structure -- Weight 12, Max 12

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Independent jobs in parallel | Jobs without dependencies run simultaneously | Everything sequential | HIGH |
| Matrix strategy | Multi-version/platform via matrix | Duplicated jobs per version | MEDIUM |
| Fan-out/fan-in | Parallel test shards with final merge | Single monolithic test job | MEDIUM |

**What to search for:**
- `needs:` / `dependencies:` / `requires:` chains
- `strategy:` / `matrix:` / `parallel:` blocks

### CI3: Conditional Execution -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Path filters | Triggers filtered by changed files | Every push triggers every workflow | HIGH |
| Skip conditions | Draft PRs and skip labels handled | Draft PRs run full pipeline | MEDIUM |
| Reusable workflows | Shared logic via templates | Copy-paste across workflows | MEDIUM |
| Concurrency control | Cancel stale runs on new push | Duplicate runs pile up | MEDIUM |

**What to search for:**
- `paths:` / `paths-ignore:`, `only:` / `except:` / `rules:`, `filters:`
- `if:` conditions, `workflow_call` (reusable)
- `concurrency:` with `cancel-in-progress`, `interruptible:`

### CI4: Artifact Management -- Weight 5, Max 5

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Selective uploads | Only needed artifacts uploaded | Everything uploaded | MEDIUM |
| Retention policy | Short retention days configured | Default retention (90 days) | LOW |
| Download scope | Jobs download only what they need | All artifacts pulled into every job | LOW |

### CI5: Secret Handling -- Weight 12, Max 12, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Secret access | Secrets referenced via `env:` block | Secrets interpolated directly in `run:` scripts | HIGH |
| Environment scoping | Secrets scoped to environment (prod/staging) | All secrets available to all jobs | MEDIUM |
| OIDC usage | Keyless auth where possible (cloud providers) | Long-lived credentials | MEDIUM |
| Permissions | Minimal `permissions:` declared | Default write-all permissions | HIGH |
| Hardcoded secrets | Zero hardcoded secrets | Secrets in workflow YAML | CRITICAL |

Critical gate: CI5=0 (hardcoded secrets or secrets likely logged) triggers FAIL.

**Verification:** For each secret reference found, read the surrounding step
to check whether it is set via `env:` block (safe) or inlined in `run:` script
(can leak to logs).

### CI6: Action Pinning -- Weight 10, Max 10, Critical Gate

**GitHub Actions only.** GitLab CI / CircleCI: score N/A.

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| SHA pinning | All actions pinned to commit SHA | Actions pinned to `@main` or `@master` | CRITICAL |
| Trusted sources | Only `actions/*` namespace or verified publishers | Unknown third-party actions | HIGH |
| Dependabot | Dependabot configured for `github-actions` updates | No automated update mechanism | MEDIUM |
| Tag pinning | First-party actions at `@vN` (acceptable) | Third-party at `@vN` (risky) | MEDIUM |

Critical gate: CI6=0 (unverified actions from unknown sources) triggers FAIL.

### CI7: Timeout and Resource Config -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Job timeouts | Every job has `timeout-minutes` | No timeouts, stuck jobs run until cancelled | HIGH |
| Runner sizing | Appropriate runner labels for workload | Oversized runners for simple tasks | MEDIUM |
| Resource limits | Self-hosted runners have resource constraints | Self-hosted without limits | MEDIUM |

### CI8: Docker Optimization -- Weight 8, Max 8, N/A if no Docker

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Multi-stage builds | Separate build and runtime stages | Single-stage with build tools in prod image | HIGH |
| .dockerignore | Exists with meaningful exclusions | Missing or empty | HIGH |
| Base image pinning | Specific version tag or digest | `FROM node:latest` | HIGH |
| Layer caching in CI | `cache-from` / `cache-to` configured | Full rebuild on every push | MEDIUM |

### CI9: Test Integration -- Weight 12, Max 12, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Tests in pipeline | Test command runs in CI | No tests in CI at all | CRITICAL |
| Coverage gate | Threshold enforced, build fails below minimum | Coverage reported but not gated | HIGH |
| Lint/typecheck separation | Lint and typecheck run as separate early steps | Mixed into test step or absent | MEDIUM |
| Test sharding | Large suites split across parallel runners | Single long-running test job | MEDIUM |

**Coverage gate detection:** Finding `codecov` or `coveralls` alone is NOT a
gate -- it is just reporting. A gate requires a threshold that fails the build
(e.g., `--coverageThreshold`, `fail_under`, Codecov `threshold` in config).

Critical gate: CI9=0 (no tests in CI) triggers FAIL.

### CI10: Pipeline Speed -- Weight 10, Max 10

Evaluated from workflow structure analysis, not by running pipelines.

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Critical path depth | <= 3 sequential jobs | > 5 sequential job chain | HIGH |
| Repeated installs | Shared setup step, cached deps | `npm install` in every job | HIGH |
| Trigger scope | Heavy jobs only on merge to main | Everything runs on every push | MEDIUM |
| Stale cancellation | `cancel-in-progress: true` | Duplicate runs stack up | MEDIUM |

**Critical path estimation:** Trace the longest chain of `needs:` dependencies.
Each link adds one sequential step.

---

## Phase 2: Scoring

```
CI1  = [0-15]   Caching Strategy
CI2  = [0-12]   Parallelism
CI3  = [0-8]    Conditional Execution
CI4  = [0-5]    Artifact Management
CI5  = [0-12]   Secret Handling              (critical gate)
CI6  = [0-10]   Action Pinning               (critical gate, N/A if not GHA)
CI7  = [0-8]    Timeout & Resources
CI8  = [0-8]    Docker Optimization          (N/A if no Docker)
CI9  = [0-12]   Test Integration             (critical gate)
CI10 = [0-10]   Pipeline Speed
```

**N/A handling:** CI6 = N/A if not GitHub Actions. CI8 = N/A if no Docker.
Excluded from both score and max.

**Score = sum / applicable_max x 100**

**Critical gates:** CI5=0 OR CI6=0 (GHA only) OR CI9=0 triggers FAIL.

| Grade | Percentage |
|-------|-----------|
| HEALTHY | >= 80% |
| NEEDS ATTENTION | 60-79% |
| AT RISK | 40-59% |
| CRITICAL | < 40% |

---

## Phase 3: Report

Save to: `audits/ci-audit-[YYYY-MM-DD].md`

### Report Structure

```markdown
# CI/CD Pipeline Audit Report

## Metadata
| Field | Value |
|-------|-------|
| Project | [name] |
| Date | [YYYY-MM-DD] |
| Platform | [GitHub Actions / GitLab CI / CircleCI] |
| Scope | [auto / user path] |
| Workflows | [N] |
| Total jobs | [N] |

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
| CI1 | Caching | [N] | 15 | |
| CI2 | Parallelism | [N] | 12 | |
| CI3 | Conditional Execution | [N] | 8 | |
| CI4 | Artifacts | [N] | 5 | |
| CI5 | Secret Handling | [N] | 12 | |
| CI6 | Action Pinning | [N] | 10 | |
| CI7 | Timeouts & Resources | [N] | 8 | |
| CI8 | Docker | [N] | 8 | |
| CI9 | Test Integration | [N] | 12 | |
| CI10 | Pipeline Speed | [N] | 10 | |
| **Total** | | **[N]** | **[M]** | |

## Findings (sorted by severity)
[Per finding: dimension, severity, file:line, description, fix]

## Optimization Roadmap

### Quick Wins (< 1 hour)
### Short-term (1 day)
### Medium-term (1 week)
```

### Report Validation

After writing, verify:
- Dimension scores sum to total in Executive Summary
- Finding counts match Executive Summary
- All workflow files from inventory are covered

---

## Phase 4: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
CI5 CRITICAL (secrets)    -> /security-audit --static
CI9 = 0 (no tests)       -> add test step to pipeline
CI6 = 0 (unpinned actions)-> pin all actions to SHA + add Dependabot
CI1 < 5 (no caching)     -> add dependency + build caching
Score < 60%              -> prioritize quick wins, re-audit in 1 week
Score >= 80%             -> schedule next audit in 3 months
------------------------------------
```

---

## CI-AUDIT COMPLETE

Score: [N] / 100 -- [grade]
Platform: [GitHub Actions / GitLab CI / CircleCI]
Dimensions: [N scored] | Critical gates: [PASS/FAIL]
Findings: [N critical] / [N total]
Run: <ISO-8601-Z>	ci-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>


### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).

---

## Execution Notes

- Single-pass inline execution, no sub-agents required
- All search commands use the resolved CI target path from Phase 0
- GitHub Actions: full coverage of all 10 dimensions
- GitLab CI: CI1-CI5, CI7-CI10 supported; CI6 = N/A
- CircleCI: CI1-CI5, CI7-CI10 supported; CI6 = N/A
- Dimensions checking project-root files (Dockerfile, .dockerignore,
  dependabot.yml) reference the project root explicitly
- If `gh run list` is accessible, pipeline speed analysis can be supplemented
  with actual run durations
- CodeSift is not heavily used in this skill (CI files are YAML, not code),
  but `codesift-setup.md` is still loaded for consistency with other audit skills
