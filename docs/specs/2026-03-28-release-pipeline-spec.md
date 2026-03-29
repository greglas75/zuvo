# Release Pipeline — Design Specification

> **Date:** 2026-03-28
> **Status:** Approved
> **Author:** zuvo:brainstorm

## Problem Statement

zuvo has 33 skills covering code quality, testing, auditing, design, and refactoring — but zero skills for the post-code lifecycle. After a developer finishes writing code, they manually: run tests, bump versions, write changelog entries, push code, create PRs, merge, trigger deployments, verify production health, and reflect on shipping velocity.

This is zuvo's biggest gap vs competitors (gstack covers the entire lifecycle with `/ship`, `/land-and-deploy`, `/canary`, `/document-release`, `/retro`). No AI coding tool has shipped a complete, CLI-native release pipeline yet — this is a 2026 green field opportunity.

If we do nothing, zuvo remains a "pre-commit only" toolkit. Users leave zuvo's quality ecosystem at the most critical moment — when code meets production.

## Design Decisions

### DD1: Naming — flat, not namespaced
**Chosen:** `zuvo:ship`, `zuvo:deploy`, `zuvo:canary`, `zuvo:release-docs`, `zuvo:retro`
**Why:** All 33 existing skills use flat kebab-case names. Adding a `launch-*` namespace creates a second convention that complicates routing and documentation.
**Rejected:** `zuvo:launch-ship` etc. (namespace prefix — breaks convention)

### DD2: Dual flow — PR-based and direct push
**Chosen:** `ship` auto-detects branch context and routes accordingly:
- Feature branch → creates PR
- Main/master with commits since last tag → tags and pushes directly
- Main/master without changes → "nothing to ship"

**Why:** Solo developers (the primary zuvo user) work directly on main. Forcing PR flow adds friction with zero benefit for solo work. Team users on feature branches get PR flow automatically.
**Rejected:** PR-only flow (excludes solo devs), direct-push-only flow (excludes teams)

### DD3: Cross-skill artifact passing via shared state file
**Chosen:** `ship` writes `memory/last-ship.json` with version, tag, range, branch, PR number, date. Downstream skills (`deploy`, `release-docs`, `retro`) read this file. Fallback to `git describe --tags` if file doesn't exist.
**Why:** Git tags may not exist (first release). PR number is not derivable from git. Consistent with existing `memory/backlog.md` persistence pattern. One small JSON file, zero overhead.
**Rejected:** Git-native only (loses PR number, fails on first release)

### DD4: Auto-scaling review depth by diff size
**Chosen:** `ship` scales its pipeline depth based on LOC changed:
- **<20 LOC:** Fast path — tests + bump + changelog + push (~30s)
- **20-100 LOC:** + lightweight inline review agent
- **100+ LOC:** + full `zuvo:review` + `zuvo:design-review` if frontend files changed
- **300+ LOC:** + coverage check via `zuvo:write-tests --dry-run`

Override flags: `--fast` (force fast path), `--full` (force full pipeline)

**Why:** Follows gstack's pattern — no flags needed for the common case. Small hotfix ships fast, large feature gets full safety net. The diff-based threshold is objective and requires no user judgment.
**Rejected:** Always-full pipeline (too slow for hotfixes), always-light pipeline (unsafe for large changes), manual flags only (requires remembering)

### DD5: `ship` and `deploy` are separate skills
**Chosen:** Two distinct skills with a deliberate pause between them.
**Why:** Ship and deploy are different decision moments. After shipping, a developer may want to: wait for CI, get team review, take a break, or inspect the PR. Combining them removes agency. gstack uses the same split (`/ship` + `/land-and-deploy`).
**Rejected:** Single `ship --deploy` combined flow (removes decision pause)

### DD6: `ship` uses inline agents, not full skill invocation
**Chosen:** When `ship` needs review/test/design-review capabilities, it dispatches lightweight inline agents (same pattern as `zuvo:execute`) rather than invoking the full skills via the router.
**Why:** Full skill invocation means redundant CodeSift setup, file loading, and verbose output for each sub-skill. Inline agents share the parent's initialization context and return focused reports.
**Rejected:** Full skill delegation via router (3x initialization overhead, verbose)

## Solution Overview

Five new skills forming the **Release** category in the zuvo routing table:

```
zuvo:ship  →  memory/last-ship.json  →  zuvo:deploy
                                     →  zuvo:release-docs
                                     →  zuvo:retro
                                     →  zuvo:canary (after deploy)
```

The pipeline is **not mandatory sequential**. Each skill works standalone. `deploy` can run without prior `ship` (reads git tags). `retro` can run anytime (reads git log). The `memory/last-ship.json` artifact enriches but is not required by downstream skills.

### `zuvo:ship` — Prepare and push a release
Runs tests, optionally reviews code (auto-scaled by diff size), bumps version, generates changelog, creates git tag, pushes to GitHub (direct or via PR depending on branch context).

### `zuvo:deploy` — Deploy to production and verify
Reads `last-ship.json` or git tags. Merges PR if applicable. Detects deployment platform from config files. Waits for CI. Triggers deploy. Runs health check. Offers rollback on failure.

### `zuvo:canary` — Post-deploy monitoring
Browser-based (or degraded HTTP-only) monitoring loop. Checks console errors, performance, page load. Configurable duration and interval. Baseline-relative alerting. Reports HEALTHY/DEGRADED/BROKEN.

### `zuvo:release-docs` — Sync documentation with release
Diff-driven docs update. Delegates to `zuvo:docs changelog [range]` for changelog and `zuvo:docs update [file]` for staleness detection. Only touches docs whose source files changed. Writes release tag to `memory/last-ship.json`.

### `zuvo:retro` — Engineering retrospective
Git-derived metrics: deployment frequency, change lead time, churn hotspots, backlog growth/resolution rate. Reads `~/.zuvo/runs.log` for skill usage trends. Outputs narrative report with actionable items. Supports period comparison.

## Detailed Design

### Data Model

**New file: `memory/last-ship.json`**
```json
{
  "version": "1.2.0",
  "previousVersion": "1.1.0",
  "tag": "v1.2.0",
  "range": "v1.1.0..v1.2.0",
  "branch": "main",
  "flow": "direct",
  "pr": null,
  "sha": "abc1234",
  "date": "2026-03-28T14:30:00Z",
  "tests": "pass",
  "reviewDepth": "light",
  "diffLOC": 47
}
```

When `flow` is `"pr"` — all fields are present, with `pr` and `targetBranch` added:
```json
{
  "version": "1.2.0",
  "previousVersion": "1.1.0",
  "tag": "v1.2.0",
  "range": "v1.1.0..v1.2.0",
  "branch": "feat/new-feature",
  "targetBranch": "main",
  "flow": "pr",
  "pr": 42,
  "sha": "def5678",
  "date": "2026-03-28T14:30:00Z",
  "tests": "pass",
  "reviewDepth": "full",
  "diffLOC": 247
}
```

**Non-interactive environments (E15):** When `ship` runs on Codex/Cursor, tag push is skipped per `env-compat.md` hard rule. In this case `last-ship.json` is still written with `tag` set to the computed tag name (e.g., `"v1.2.0"`) and a new field `"tagPushed": false`. Downstream skills treat `tagPushed: false` as "tag exists locally but not on remote." `deploy` will push the tag as its first step (with interactive confirmation if available).

**Platform detection signals** (shared include: `shared/includes/platform-detection.md`):

| File/pattern | Platform | Deploy CLI | Health check |
|---|---|---|---|
| `vercel.json` or `.vercel/` | Vercel | `vercel --prod` | `curl` prod URL |
| `fly.toml` | Fly.io | `fly deploy` | `fly status` |
| `netlify.toml` | Netlify | `netlify deploy --prod` | `curl` prod URL |
| `railway.json` or `railway.toml` | Railway | `railway up` | `curl` prod URL |
| `render.yaml` | Render | webhook (no CLI) | `curl` prod URL |
| `.github/workflows/*deploy*` | GitHub Actions | `gh workflow run` | `gh run view` |
| None detected | Unknown | manual instructions | manual |

Priority: explicit platform file > GHA workflow > unknown.

**Platform detection algorithm** (procedural steps for `shared/includes/platform-detection.md`):
1. Scan project root for platform config files in priority order (top of table first).
2. If multiple config files detected: use the first match in priority order. Log all detected platforms.
3. Verify the platform CLI is installed: `which vercel`, `which fly`, etc. If CLI missing, downgrade to "manual instructions" for that platform.
4. If only `.github/workflows/*deploy*` matched: parse the workflow YAML to extract the deploy job name and trigger event. Use `gh workflow run <name>` as the deploy command.
5. If `render.yaml` matched (no CLI): note webhook-only and prompt user for the deploy hook URL, or skip automated deploy.
6. Surface the detected platform to the calling skill as: `{ platform: "vercel"|"fly"|...|"unknown", cli: "vercel --prod"|null, healthCmd: "curl ..."|null, rollbackCmd: "vercel rollback"|null }`.

**Rollback commands per platform:**

| Platform | Rollback command | Notes |
|---|---|---|
| Vercel | `vercel rollback` | Rolls back to previous deployment |
| Fly.io | `fly deploy --image <previous>` | Requires previous image ref from `fly releases` |
| Netlify | `netlify deploy --prod --dir <prev-deploy>` | Or rollback via Netlify dashboard |
| Railway | `railway up --detach` + redeploy previous | No native rollback CLI |
| GitHub Actions | Re-run previous successful workflow | `gh run rerun <run-id>` |
| Unknown / manual | `git revert <merge-sha> && git push` | Git-native fallback |

**Version file detection** (in `ship`):

| File | Ecosystem | Version field |
|---|---|---|
| `package.json` | Node.js | `.version` |
| `pyproject.toml` | Python | `[project].version` or `[tool.poetry].version` |
| `Cargo.toml` | Rust | `[package].version` |
| `go.mod` | Go | git tags only (no file bump) |
| `composer.json` | PHP | `.version` |
| `VERSION` | Generic | entire file content |
| None found | — | offer to create `VERSION` or skip |

### API Surface

#### `zuvo:ship`

**Arguments:**
| Flag | Effect |
|---|---|
| (no flags) | Auto-scaled pipeline based on diff size |
| `--fast` | Force fast path: tests + bump + push only |
| `--full` | Force full pipeline: tests + review + design-review + coverage + bump + push |
| `--no-bump` | Skip version bumping (hotfixes, chores) |
| `--no-tag` | Skip git tag creation |
| `--dry-run` | Show what would happen without executing |
| `patch` / `minor` / `major` | Explicit bump type (overrides auto-detection) |

**Output: SHIP COMPLETE block**
```
SHIP COMPLETE
  Branch:      main
  Flow:        direct (solo)
  Version:     1.1.0 → 1.2.0
  Tag:         v1.2.0
  Diff:        47 LOC (fast path)
  Tests:       PASS (23 passed, 0 failed)
  Review:      light (inline agent)
  Changelog:   CHANGELOG.md updated
  Push:        origin/main ✓
  PR:          — (direct flow)
  Artifact:    memory/last-ship.json written

  Next: zuvo:deploy (when ready)
```

#### `zuvo:deploy`

**Arguments:**
| Flag | Effect |
|---|---|
| (no flags) | Auto-detect from `last-ship.json` or git tags |
| `--url <url>` | Override production URL for health check |
| `--skip-ci-wait` | Don't wait for CI (manual check) |
| `--skip-health` | Skip health check after deploy |
| `#<number>` | Specific PR number to merge |

**Output: DEPLOY COMPLETE block**
```
DEPLOY COMPLETE
  Version:     v1.2.0
  Platform:    Vercel (detected from vercel.json)
  CI:          PASS (GitHub Actions, 2m 14s)
  Deploy:      SUCCESS (deployed in 45s)
  Health:      PASS (200 OK, 1.2s load time)
  URL:         https://myapp.vercel.app

  Next: zuvo:canary https://myapp.vercel.app (optional monitoring)
```

#### `zuvo:canary`

**Arguments:**
| Flag | Effect |
|---|---|
| `<url>` | Production URL to monitor (required) |
| `--duration <time>` | Monitoring duration (default: 10m, range: 1m-30m) |
| `--interval <time>` | Check interval (default: 60s) |
| `--quick` | Single health check, no loop |
| `--max-errors <n>` | Error threshold for FAIL verdict (default: 3) |

**Output: CANARY COMPLETE block**
```
CANARY COMPLETE
  URL:         https://myapp.vercel.app
  Duration:    10m (10 checks)
  Mode:        full (Playwright available)
  Console:     0 errors, 2 warnings
  Performance: avg 1.3s (baseline: 1.1s, +18%)
  Screenshots: audit-results/canary-2026-03-28T1430/
  Verdict:     HEALTHY
```

#### `zuvo:release-docs`

**Arguments:**
| Flag | Effect |
|---|---|
| (no flags) | Auto-detect range from `last-ship.json` or git tags |
| `<range>` | Explicit git range (e.g., `v1.1.0..v1.2.0`) |
| `--dry-run` | Show proposed changes without writing |

**Output: RELEASE-DOCS COMPLETE block**
```
RELEASE-DOCS COMPLETE
  Range:       v1.1.0..v1.2.0
  Changelog:   CHANGELOG.md updated (Added: 3, Fixed: 1)
  Docs updated: README.md (API section), docs/config.md
  Docs skipped: docs/architecture.md (no source changes)
  Debt found:  1 file (src/auth/ changed, no docs section exists)
  Verdict:     PASS
```

#### `zuvo:retro`

**Arguments:**
| Flag | Effect |
|---|---|
| (no flags) | Range from last two git tags, or last 30 commits |
| `<range>` | Explicit range (e.g., `v1.0.0..v1.2.0`) |
| `--since <tag>` | Start of retrospective window |
| `--path <dir>` | Scope to directory (required for monorepos) |

**Output: RETRO COMPLETE terminal block**
```
RETRO COMPLETE
  Window:      v1.1.0..v1.2.0 (14 days, 47 commits)
  Releases:    2 in period (frequency: 1 per week)
  Lead time:   avg 3.2 days (branch create → tag)
  Hotspots:    src/orders/service.ts (12 changes), src/auth/guard.ts (8 changes)
  Backlog:     +5 added, -3 resolved, 12 open (2 critical)
  Report:      audit-results/retro-2026-03-28.md

  Actions:
  1. zuvo:write-tests src/orders/ — high-churn, low coverage
  2. zuvo:refactor src/auth/guard.ts — 8 changes suggest instability
  3. zuvo:backlog fix BD-007 — critical debt item open 21 days
```

**Retro report file structure** (`audit-results/retro-YYYY-MM-DD.md`):
```markdown
# Engineering Retrospective — YYYY-MM-DD

## Summary
[Tweetable one-liner: period, commits, releases, key metric]

## Shipping Velocity
- Deployment frequency: N releases in period
- Change lead time: avg N days (branch → tag)
- Commits: N total, N/day average

## Churn Hotspots
[Top 5 most-changed files with change count and test coverage status]

## Backlog Health
- Open items: N (N critical, N high)
- Added this period: N
- Resolved this period: N
- Oldest unresolved: [item ID, age]

## Quality Trends
- CQ scores from ~/.zuvo/runs.log (if available)
- Test coverage direction (improving/declining/stable)

## Actionable Items
1. [Specific action + zuvo command]
2. [Specific action + zuvo command]
3. [Specific action + zuvo command]

## Comparison vs Prior Retro
[Delta table if prior retro exists, or "First retro — run again next period for trends"]
```

### Integration Points

**Existing skills orchestrated by `ship`:**
- `zuvo:review` — invoked as inline agent at 100+ LOC diff
- `zuvo:design-review` — invoked as inline agent at 100+ LOC diff when frontend files detected (`.tsx`, `.jsx`, `.css`, `.scss`, `.html`)
- `zuvo:write-tests` — invoked as `--dry-run` inline agent at 300+ LOC diff

**Existing skills delegated to by `release-docs`:**
- `zuvo:docs changelog [range]` — changelog generation
- `zuvo:docs update [file]` — staleness detection and fix

**Existing infrastructure used by all 5 skills:**
- `shared/includes/codesift-setup.md` — CodeSift discovery
- `shared/includes/env-compat.md` — Codex/Cursor compatibility
- `shared/includes/run-logger.md` — append to `~/.zuvo/runs.log`
- `shared/includes/backlog-protocol.md` — persist findings to `memory/backlog.md`

**New shared include:**
- `shared/includes/platform-detection.md` — deployment platform auto-detection (used by `deploy` and `canary`)

**Files modified:**
- `skills/using-zuvo/SKILL.md` — new "Release" section in routing table
- `.claude-plugin/plugin.json` — skill count update
- `.codex-plugin/plugin.json` — skill count update
- `package.json` — skill count and keywords update
- `docs/skills.md` — 5 new rows in skills reference table

**Files created:**
```
skills/ship/SKILL.md
skills/ship/agents/review-light.md
skills/ship/agents/coverage-check.md
skills/deploy/SKILL.md
skills/canary/SKILL.md
skills/release-docs/SKILL.md
skills/retro/SKILL.md
shared/includes/platform-detection.md
```

### Inline Agent Contracts

#### `skills/ship/agents/review-light.md` — Lightweight Pre-Ship Review

**Purpose:** Quick code review focused on ship-blocking issues only. NOT a full `zuvo:review` — skips style, naming, and optimization concerns.

**Input:** Git diff of staged changes (from `git diff --cached` or `git diff HEAD~1`).

**Scope:** Only check for:
- Security issues (CQ5: timing-safe comparisons, CQ6: unbounded queries, hardcoded secrets)
- Data integrity (CQ3: atomicity, CQ21: TOCTOU upserts)
- Error handling regressions (CQ8: swallowed errors, missing catch)
- Obvious bugs (null access, missing await, infinite loops)

**Does NOT check:** Style, naming, duplication, performance optimization, documentation.

**Output format:**
```
REVIEW-LIGHT REPORT
  Files reviewed: N
  Ship-blockers:  N (or "none")
  Warnings:       N

  [If blockers found:]
  BLOCKER: <file>:<line> — <issue description>

  [If warnings only:]
  WARN: <file>:<line> — <issue description>

  Verdict: PASS / BLOCK
```

**Verdict logic:** Any ship-blocker = BLOCK (ship pauses, asks user to fix or override). Warnings only = PASS with warnings shown.

#### `skills/ship/agents/coverage-check.md` — Pre-Ship Coverage Audit

**Purpose:** Check if the changed code has corresponding tests. Does NOT write tests — only reports gaps.

**Input:** List of changed production files (from git diff, excluding test files).

**Scope:** For each changed production file:
1. Search for a corresponding test file (e.g., `foo.ts` → `foo.test.ts`, `foo.spec.ts`, `__tests__/foo.ts`)
2. If test file exists: check if it imports/references the changed symbols
3. If no test file: flag as uncovered

**Output format:**
```
COVERAGE-CHECK REPORT
  Production files changed: N
  With tests:    N (list)
  Without tests: N (list)
  Coverage:      N% of changed files

  [If gaps found:]
  GAP: src/orders/service.ts — no test file found
  GAP: src/auth/guard.ts — test exists but doesn't cover newMethod()

  Verdict: PASS (≥80%) / WARN (50-79%) / FAIL (<50%)
```

**Verdict logic:** Coverage check is informational at all thresholds — it never blocks ship. The verdict is included in the SHIP COMPLETE block as context.

### Edge Cases

| # | Edge case | Handling |
|---|---|---|
| E1 | `ship` on main branch | **Allowed** — solo dev flow. Direct tag + push. |
| E2 | `ship` on main with no changes since last tag | "Nothing to ship" — exit clean with message. |
| E3 | `gh` CLI not installed or not authenticated | Ship does everything except PR creation. Prints manual instructions. Verdict: WARN. |
| E4 | No conventional commits (<50% prefixed) | Fallback: list raw commit messages in changelog. Ask user for bump type (patch/minor/major). Codex/Cursor: default to `patch` with `[AUTO-DECISION]`. |
| E5 | No VERSION/package.json/pyproject.toml | Offer to create `VERSION` file or skip versioning with user consent. |
| E6 | No CHANGELOG.md exists | Create from scratch using Keep-a-Changelog format with current release section. |
| E7 | `deploy` — CI already failing on base branch | Check `gh run list --branch main --limit 1` before merge. If failing, stop and report. User decides. |
| E8 | `deploy` — merge conflicts on PR | Check `gh pr view --json mergeable` before merging. If not mergeable, stop with conflict list. |
| E9 | `deploy` — no deployment platform detected | Print manual deployment checklist. Skip automated deploy. Verdict: PARTIAL. |
| E10 | `deploy` — health check fails | Present rollback option: identify previous stable tag, offer `git revert` or platform rollback. |
| E11 | `canary` — no browser tools (MCP unavailable) | Degraded mode: `curl` HTTP status + response time. Annotate `[DEGRADED: no browser tools]`. |
| E12 | `canary` — on Codex/Cursor (no polling loop) | One-shot health check instead of loop. Annotate `[AUTO-DECISION]: one-shot mode`. |
| E13 | `retro` — repo with <10 commits in window | "Insufficient history" — qualitative-only report from `memory/backlog.md` open items. |
| E14 | `retro` — monorepo detected | Require `--path` argument. If not provided, list packages and ask user to pick. |
| E15 | `ship` — version bump on Codex/Cursor (no AskUserQuestion) | Default to `patch` with `[AUTO-DECISION]` annotation. Never push tags without interactive confirmation — skip tag push in non-interactive envs. |
| E16 | `ship` — `git add -A` prevention | Never use `git add -A`. Stage only: version files, CHANGELOG.md, `memory/last-ship.json`. Explicit file list always. |

## Acceptance Criteria

### `zuvo:ship`

**Must have:**
1. Detect current branch; on main: direct flow (tag+push); on feature branch: PR flow.
2. On main with no changes since last tag: exit with "nothing to ship" message.
3. Run project's test suite; stop on failure requiring explicit override.
4. Detect version file from stack signals; if none found, offer `VERSION` or skip.
5. Auto-detect conventional commits; if <50%, fall back to raw messages + manual bump type.
6. Generate or update CHANGELOG.md in Keep-a-Changelog format.
7. Never use `git add -A`; stage only modified files by explicit name.
8. Auto-scale review depth by diff LOC (<20/20-100/100+/300+).
9. Write `memory/last-ship.json` on completion.
10. Produce SHIP COMPLETE summary block.
11. Write run log entry to `~/.zuvo/runs.log`.

**Should have:**
1. `--fast` / `--full` / `--no-bump` / `--no-tag` / `--dry-run` flags.
2. Detect frontend file changes for conditional design review trigger.
3. Check `gh auth status` as pre-flight; degrade gracefully if unavailable.

### `zuvo:deploy`

**Must have:**
1. Read `memory/last-ship.json` or fall back to `git describe --tags`.
2. If PR flow: check `gh pr view --json mergeable` before merging.
3. If PR flow: check base branch CI status before merging.
4. Detect deployment platform from config signals.
5. If platform detected: trigger deploy, poll status with 15m timeout. If CI has not completed within 15 minutes, stop with timeout message and present options: wait longer, skip CI check, or abort.
6. Run HTTP health check on production URL.
7. If health check fails: present rollback option with platform-specific rollback command (see rollback table in Data Model).
8. Produce DEPLOY COMPLETE summary block.

**Should have:**
1. `--url`, `--skip-ci-wait`, `--skip-health` flags.
2. Version drift detection (deployed version matches expected tag).

### `zuvo:canary`

**Must have:**
1. Accept URL as required argument.
2. Detect browser tool availability; run degraded HTTP-only mode if absent.
3. Configurable `--duration` and `--interval`.
4. On Codex/Cursor: one-shot mode instead of polling loop.
5. Report console errors by severity.
6. Save at least one screenshot per run (full mode only).
7. Produce CANARY COMPLETE summary with HEALTHY/DEGRADED/BROKEN verdict.

**Should have:**
1. `--quick` flag for single check.
2. `--max-errors` threshold.
3. Baseline comparison against prior canary runs.

### `zuvo:release-docs`

**Must have:**
1. Determine release range from `last-ship.json` or git tags.
2. If no docs-adjacent files changed: exit with "no updates required".
3. Delegate changelog to `zuvo:docs changelog [range]`.
4. Update only sections whose source files changed.
5. Every doc claim references a source file.

**Should have:**
1. `--dry-run` flag.
2. Flag documentation debt (changed source, no corresponding docs).

### `zuvo:retro`

**Must have:**
1. If <10 commits in window: qualitative-only report.
2. Detect monorepo; require `--path` if detected.
3. Derive window from git tags or `last-ship.json`.
4. Report: deployment frequency, change lead time, churn hotspots, backlog growth/resolution.
5. Output to `audit-results/retro-YYYY-MM-DD.md`.
6. Include 3+ actionable items with suggested zuvo skill commands.

**Should have:**
1. Compare against prior retro if `audit-results/retro-*.md` exists.
2. `--since` / `--until` / `--path` flags.

## Out of Scope

- **Monorepo multi-package releases** — each package gets its own `ship` invocation. No coordinated multi-package release.
- **npm/PyPI/crates.io publishing** — `ship` creates git tags and GitHub releases. Registry publishing is project-specific and out of scope.
- **Continuous monitoring** — `canary` runs for a bounded duration (max 30m). Permanent monitoring is a separate tool (Checkly, Datadog, etc.).
- **Team management / permissions** — `deploy` does not handle branch protection rules or required reviewers. It respects whatever GitHub enforces.
- **Rollback automation** — `deploy` offers rollback as an option and provides the command. It does not auto-rollback without user consent.
- **CI/CD pipeline creation** — `deploy` detects existing pipelines but does not create new ones. Use `zuvo:ci-audit` for pipeline improvement.

## Open Questions

None. All design questions resolved in Phase 2, including:
- DD7 (resolved): Non-interactive tag push behavior — E15 specifies: skip tag push on Codex/Cursor, write `tagPushed: false` to `last-ship.json`, `deploy` pushes the tag as its first step.
