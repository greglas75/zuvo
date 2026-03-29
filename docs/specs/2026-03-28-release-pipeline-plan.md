# Implementation Plan: Release Pipeline

**Spec:** `docs/specs/2026-03-28-release-pipeline-spec.md`
**Created:** 2026-03-28
**Tasks:** 10
**Estimated complexity:** 3 complex (ship, deploy, platform-detection), 7 standard

## Architecture Summary

8 new files, 5 modified files. All markdown. No production code, no tests. The skill file convention follows `skills/build/SKILL.md` as the canonical template: YAML frontmatter (`name`, `description`), numbered phases, `$ARGUMENTS` table, named output block, shared include references via `../../shared/includes/`, run-logger append.

**Dependency order:**
1. `shared/includes/platform-detection.md` — used by deploy + canary
2. `skills/ship/agents/review-light.md` + `coverage-check.md` — dispatched by ship
3. `skills/ship/SKILL.md` — produces `memory/last-ship.json`
4. `skills/deploy/SKILL.md` — consumes last-ship.json + platform-detection
5. `skills/canary/SKILL.md` — consumes platform-detection
6. `skills/release-docs/SKILL.md` — consumes last-ship.json, delegates to zuvo:docs
7. `skills/retro/SKILL.md` — consumes last-ship.json + runs.log + backlog.md
8. Routing table + manifests — wiring

## Technical Decisions

- **Template:** All SKILL.md files follow `skills/build/SKILL.md` structure
- **Agent files:** Follow `skills/brainstorm/agents/` pattern with YAML frontmatter
- **Platform detection:** Procedural include with 5-step algorithm, not just a data table
- **release-docs:** Full delegation to `zuvo:docs changelog [range]` — no re-implementation
- **No new dependencies:** All tools (git, gh, curl, platform CLIs) are external; no npm packages

## Quality Strategy

- **No TDD:** This is a markdown-only project. TDD protocol exceptions apply (documentation/configuration changes).
- **Verification:** Structural checks per file — frontmatter, phases, includes, output blocks, flag tables, edge case coverage. QA Engineer's grep-verifiable checklist is the acceptance gate.
- **CQ-adjacent safety rules:** E16 (`git add -A` prohibition) must be an unmissable standalone rule in ship. E15 (tagPushed) must appear in both ship and deploy. env-compat hard rule must be referenced in ship + deploy.
- **Cross-file consistency:** Routing table entries must match file existence. Skill counts must match across 4 manifest files. `last-ship.json` schema must be consistent between writer (ship) and readers (deploy, release-docs, retro).

---

## Task Breakdown

### Task 1: Create shared platform detection include

**Files:** `shared/includes/platform-detection.md`
**Complexity:** complex
**Dependencies:** none
**Model routing:** Opus

**What to write:**

Create a procedural shared include that deploy and canary will read. Must contain:

1. **Platform detection table** — 7 rows from spec (Vercel, Fly, Netlify, Railway, Render, GHA, Unknown)
2. **5-step detection algorithm:**
   - Step 1: Scan project root for config files in priority order
   - Step 2: If multiple detected, use first match in priority order, log all
   - Step 3: Verify CLI installed (`which <cli>`). If missing, downgrade to manual
   - Step 4: If GHA only, parse workflow YAML for deploy job name + trigger
   - Step 5: Render special case — no CLI, prompt for webhook URL or skip
3. **Output object definition:** `{ platform, cli, healthCmd, rollbackCmd }`
4. **Rollback commands table** — 6 rows from spec (Vercel, Fly, Netlify, Railway, GHA, Unknown/git-native)

**Key constraint:** This is a shared include, not a SKILL.md — no YAML frontmatter, no H1 skill heading, no phases. Use H1 heading like other includes (e.g., `# Platform Detection`). Format as numbered procedural steps that calling skills follow.

- [ ] Write: Create `shared/includes/platform-detection.md` with all 4 sections above
- [ ] Verify: `grep -c "vercel\|fly\|netlify\|railway\|render\|github" shared/includes/platform-detection.md` — expect ≥ 7 matches
- [ ] Verify: `grep "rollbackCmd\|rollback" shared/includes/platform-detection.md` — confirm rollback table present
- [ ] Commit: "add platform detection shared include for deploy and canary skills"

---

### Task 2: Create ship inline agent — review-light

**Files:** `skills/ship/agents/review-light.md`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

**What to write:**

Create the lightweight review agent per spec's "Inline Agent Contracts" section. Must contain:

1. **Purpose:** Quick code review focused on ship-blocking issues only
2. **Scope — checks:** Security (CQ5 timing-safe, CQ6 unbounded), data integrity (CQ3 atomicity, CQ21 TOCTOU), error handling (CQ8 swallowed errors), obvious bugs (null access, missing await)
3. **Scope ��� does NOT check:** Style, naming, duplication, performance, docs
4. **Input:** Git diff of staged changes
5. **Output format:** Exact `REVIEW-LIGHT REPORT` block from spec (Files reviewed, Ship-blockers, Warnings, Verdict)
6. **Verdict logic:** Any ship-blocker = BLOCK (pause ship, ask to fix or override). Warnings only = PASS.

**Key constraint:** Must be self-contained. Include explicit "read these rules" at top referencing `../../../shared/includes/agent-preamble.md`. Output format must match exactly what ship parses.

- [ ] Write: Create `skills/ship/agents/review-light.md`
- [ ] Verify: `grep "REVIEW-LIGHT REPORT" skills/ship/agents/review-light.md` — confirm output block
- [ ] Verify: `grep "BLOCK\|PASS" skills/ship/agents/review-light.md` — confirm verdict logic
- [ ] Commit: "add review-light inline agent for ship skill"

---

### Task 3: Create ship inline agent — coverage-check

**Files:** `skills/ship/agents/coverage-check.md`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

**What to write:**

Create the coverage audit agent per spec's "Inline Agent Contracts" section. Must contain:

1. **Purpose:** Check if changed production files have corresponding tests
2. **Input:** List of changed production files (excluding test files)
3. **Discovery heuristic:** `foo.ts` → `foo.test.ts`, `foo.spec.ts`, `__tests__/foo.ts`
4. **Output format:** Exact `COVERAGE-CHECK REPORT` block (Production files changed, With tests, Without tests, Coverage %, GAP entries, Verdict)
5. **Verdict thresholds:** PASS ≥80%, WARN 50-79%, FAIL <50%
6. **Critical rule:** "Coverage check is informational at all thresholds — it never blocks ship."

- [ ] Write: Create `skills/ship/agents/coverage-check.md`
- [ ] Verify: `grep "never blocks ship" skills/ship/agents/coverage-check.md` — confirm non-blocking rule
- [ ] Verify: `grep "COVERAGE-CHECK REPORT" skills/ship/agents/coverage-check.md` — confirm output block
- [ ] Commit: "add coverage-check inline agent for ship skill"

---

### Task 4: Create zuvo:ship skill

**Files:** `skills/ship/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 2, Task 3
**Model routing:** Opus

**What to write:**

The most complex file (est. 280-320 lines). Follow `skills/build/SKILL.md` template. Must contain:

**Frontmatter:**
```yaml
---
name: ship
description: >
  Pre-merge release pipeline: run tests, auto-scaled code review, version bump,
  changelog generation, git tag, push or PR. Auto-detects branch context (direct
  push on main, PR on feature branch). Scales review depth by diff size.
  Flags: --fast, --full, --no-bump, --no-tag, --dry-run, patch/minor/major.
---
```

**Argument Parsing table:** All 7 flags from spec: `--fast`, `--full`, `--no-bump`, `--no-tag`, `--dry-run`, `patch`/`minor`/`major`.

**Mandatory file loading checklist:** env-compat.md, codesift-setup.md, run-logger.md

**Phase structure (guideline):**
- Phase 0: Pre-flight — detect branch (main vs feature), check `gh auth status` (E3), check for changes since last tag (E2)
- Phase 1: Tests — run project test suite, stop on failure
- Phase 2: Review scaling — compute diff LOC, dispatch agents per DD4 thresholds (<20/20-100/100+/300+). Reference `skills/ship/agents/review-light.md` and `skills/ship/agents/coverage-check.md`.
- Phase 3: Version bump — detect version file (7-ecosystem table from spec), detect conventional commits (E4), bump version, update CHANGELOG.md (E6)
- Phase 4: Stage + tag + push — **CRITICAL:** explicit `git add` with named files only (E16), never `-A`. Tag creation. Branch-aware push: direct flow = `git push origin main && git push --tags`; PR flow = `git push -u origin <branch> && gh pr create`. Non-interactive (E15): skip tag push, write `tagPushed: false`.
- Phase 5: Artifact + output — write `memory/last-ship.json` (full schema with all fields including `tagPushed`, `reviewDepth`, `diffLOC`), produce SHIP COMPLETE block, append run log.

**Safety rules (must be standalone, unmissable):**
- E16: "**NEVER** use `git add -A` or `git add .`. Stage ONLY these files by name: [version file], CHANGELOG.md, memory/last-ship.json."
- E15: "In non-interactive environments (Codex, Cursor): default to `patch` bump. Skip `git push --tags`. Write `tagPushed: false` in last-ship.json."
- env-compat hard rule: "Never push to remote without explicit user confirmation."

**Output block:** SHIP COMPLETE with all 11 fields from spec.

- [ ] Write: Create `skills/ship/SKILL.md`
- [ ] Verify: `grep "git add -A" skills/ship/SKILL.md` — must appear as prohibition
- [ ] Verify: `grep "tagPushed" skills/ship/SKILL.md` — confirm E15 handling
- [ ] Verify: `grep "SHIP COMPLETE" skills/ship/SKILL.md` — confirm output block
- [ ] Verify: `grep "\-\-fast\|\-\-full\|\-\-no-bump\|\-\-no-tag\|\-\-dry-run" skills/ship/SKILL.md` — all 5 flags present
- [ ] Verify: `grep "review-light\|coverage-check" skills/ship/SKILL.md` — agent references present
- [ ] Verify: `grep "env-compat\|run-logger" skills/ship/SKILL.md` — shared includes referenced
- [ ] Commit: "add zuvo:ship skill — pre-merge release pipeline with auto-scaled review"

---

### Task 5: Create zuvo:deploy skill

**Files:** `skills/deploy/SKILL.md`
**Complexity:** complex
**Dependencies:** Task 1, Task 4
**Model routing:** Opus

**What to write:**

Follow `skills/build/SKILL.md` template. Est. 200-240 lines. Must contain:

**Frontmatter:**
```yaml
---
name: deploy
description: >
  Deploy to production and verify health. Reads ship state, merges PR if applicable,
  detects platform (Vercel/Fly/Netlify/Railway/Render/GHA), waits for CI, triggers
  deploy, runs health check, offers rollback on failure.
  Flags: --url, --skip-ci-wait, --skip-health, #<number>.
---
```

**Argument Parsing table:** 4 flags from spec.

**Phase structure:**
- Phase 0: Read `memory/last-ship.json` (fallback: `git describe --tags`). If `tagPushed: false`, push tag first (with interactive confirmation or skip on Codex/Cursor per DD7/E15).
- Phase 1: Pre-merge checks (PR flow only) — `gh pr view --json mergeable` (E8), base branch CI status via `gh run list --branch main --limit 1` (E7)
- Phase 2: Merge — `gh pr merge --squash --delete-branch` (PR flow) or skip (direct flow)
- Phase 3: Platform detection — read `../../shared/includes/platform-detection.md`, follow algorithm
- Phase 4: CI wait — poll with `gh run view` or platform-specific, 15m timeout. On timeout: present 3 options (wait longer, skip, abort).
- Phase 5: Deploy — trigger platform CLI from detection result. If no platform detected (E9): print manual checklist, verdict PARTIAL.
- Phase 6: Health check — `curl -s -o /dev/null -w "%{http_code}" <url>`. If fail (E10): present rollback option with platform-specific command from detection result. "Offer rollback, do not auto-execute."
- Phase 7: Output — DEPLOY COMPLETE block (6 fields), run log.

**Safety rules:**
- Never `git push --force`
- Never auto-rollback without user consent
- env-compat push confirmation rule

- [ ] Write: Create `skills/deploy/SKILL.md`
- [ ] Verify: `grep "platform-detection" skills/deploy/SKILL.md` — shared include referenced
- [ ] Verify: `grep "tagPushed" skills/deploy/SKILL.md` — E15/DD7 handling present
- [ ] Verify: `grep "DEPLOY COMPLETE" skills/deploy/SKILL.md` — output block present
- [ ] Verify: `grep "rollback" skills/deploy/SKILL.md` — rollback option present
- [ ] Verify: `grep "15 min\|15m\|timeout" skills/deploy/SKILL.md` — CI timeout specified
- [ ] Commit: "add zuvo:deploy skill — platform-aware deployment with health check and rollback"

---

### Task 6: Create zuvo:canary skill

**Files:** `skills/canary/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 1
**Model routing:** Sonnet

**What to write:**

Est. 160-190 lines. Must contain:

**Frontmatter:**
```yaml
---
name: canary
description: >
  Post-deploy monitoring with browser or degraded HTTP mode. Checks console errors,
  performance, page load. Configurable duration (1m-30m) and interval.
  Reports HEALTHY/DEGRADED/BROKEN. Flags: --duration, --interval, --quick, --max-errors.
---
```

**Argument Parsing:** URL (required), 4 flags from spec.

**Phase structure:**
- Phase 0: Validate URL argument (halt if absent). Detect browser tools (`mcp__playwright__*` or `mcp__chrome-devtools__*`). If absent: degraded mode (E11) with `[DEGRADED: no browser tools]` annotation. On Codex/Cursor: one-shot mode (E12) with `[AUTO-DECISION]: one-shot mode`.
- Phase 1: Platform detection (optional) — read `../../shared/includes/platform-detection.md` for platform-specific health commands
- Phase 2: Monitoring loop — every `--interval` seconds for `--duration`. Each check: HTTP status + response time (always), console errors + screenshot (full mode only). Or single check if `--quick` or one-shot mode.
- Phase 3: Output — CANARY COMPLETE block (7 fields), screenshots to `audit-results/canary-{ISO-timestamp}/`, run log.

**Verdict logic:**
- HEALTHY: all checks pass, console errors below threshold
- DEGRADED: warnings present but no critical failures
- BROKEN: page load failure, critical console errors, or errors exceed `--max-errors`

- [ ] Write: Create `skills/canary/SKILL.md`
- [ ] Verify: `grep "DEGRADED: no browser tools" skills/canary/SKILL.md` — exact annotation
- [ ] Verify: `grep "AUTO-DECISION.*one-shot" skills/canary/SKILL.md` — E12 handling
- [ ] Verify: `grep "CANARY COMPLETE" skills/canary/SKILL.md` — output block
- [ ] Verify: `grep "\-\-duration\|\-\-interval\|\-\-quick\|\-\-max-errors" skills/canary/SKILL.md` — all 4 flags
- [ ] Commit: "add zuvo:canary skill — post-deploy monitoring with browser and HTTP modes"

---

### Task 7: Create zuvo:release-docs skill

**Files:** `skills/release-docs/SKILL.md`
**Complexity:** standard
**Dependencies:** Task 4
**Model routing:** Sonnet

**What to write:**

Simplest skill (est. 130-160 lines). Delegates core work to `zuvo:docs`. Must contain:

**Frontmatter:**
```yaml
---
name: release-docs
description: >
  Diff-driven documentation sync after a release. Determines what source files
  changed, delegates changelog to zuvo:docs, updates only docs whose source changed.
  Flags: --dry-run, explicit range argument.
---
```

**Phase structure:**
- Phase 0: Determine release range from `memory/last-ship.json` (field: `range`) or `git describe --tags` fallback. If no range derivable: ask user for explicit range.
- Phase 1: Diff analysis — `git diff --name-only <range>`. Classify changed files as source vs docs. If no docs-adjacent source files changed: exit with "No documentation updates required for this release" and PASS verdict.
- Phase 2: Changelog — invoke `Skill(skill="zuvo:docs", args="changelog <range>")`.
- Phase 3: Doc updates — for each doc file whose corresponding source changed, invoke `Skill(skill="zuvo:docs", args="update <doc-file>")`. Every doc claim must reference a source file (iron rule).
- Phase 4: Debt detection — flag source files that changed but have no corresponding docs section.
- Phase 5: Output — RELEASE-DOCS COMPLETE block (5 fields from spec), run log.

- [ ] Write: Create `skills/release-docs/SKILL.md`
- [ ] Verify: `grep "zuvo:docs" skills/release-docs/SKILL.md` — delegation present
- [ ] Verify: `grep "RELEASE-DOCS COMPLETE" skills/release-docs/SKILL.md` — output block
- [ ] Verify: `grep "No documentation updates required" skills/release-docs/SKILL.md` — early exit
- [ ] Commit: "add zuvo:release-docs skill — diff-driven documentation sync"

---

### Task 8: Create zuvo:retro skill

**Files:** `skills/retro/SKILL.md`
**Complexity:** standard
**Dependencies:** none (reads artifacts but works standalone)
**Model routing:** Sonnet

**What to write:**

Est. 180-210 lines. Must contain:

**Frontmatter:**
```yaml
---
name: retro
description: >
  Engineering retrospective from git metrics. Reports deployment frequency,
  change lead time, churn hotspots, backlog health. Outputs narrative report
  with 3+ actionable items. Flags: --since, --path, explicit range argument.
---
```

**Argument Parsing:** `<range>`, `--since <tag>`, `--path <dir>` (NOTE: no `--until` per spec).

**Phase structure:**
- Phase 0: Determine window from `memory/last-ship.json` (fallback: last two git tags, fallback: last 30 commits). Count commits in window — if <10 (E13): qualitative-only report from `memory/backlog.md`. Detect monorepo (E14): if `turbo.json`/`nx.json`/`pnpm-workspace.yaml` exists and no `--path`, stop and ask.
- Phase 1: Git metrics — deployment frequency (count tags in window), change lead time (branch create → tag, derived from `git log`), churn hotspots (files most frequently changed via `git log --name-only`).
- Phase 2: Backlog health — read `memory/backlog.md`, count open/resolved/added items.
- Phase 3: Skill usage trends — read `~/.zuvo/runs.log` (if exists), aggregate by skill. Define the TSV parse format from `run-logger.md`.
- Phase 4: Actionable items — generate 3+ specific actions with zuvo commands (e.g., `zuvo:write-tests src/orders/`).
- Phase 5: Report — write `audit-results/retro-YYYY-MM-DD.md` using the 6-section template from spec. Print RETRO COMPLETE terminal block. If prior retro exists (`audit-results/retro-*.md`): include comparison section.
- Phase 6: Run log.

- [ ] Write: Create `skills/retro/SKILL.md`
- [ ] Verify: `grep "RETRO COMPLETE" skills/retro/SKILL.md` — output block
- [ ] Verify: `grep "backlog.md\|runs.log" skills/retro/SKILL.md` — data sources referenced
- [ ] Verify: `grep "monorepo\|turbo\|nx\|pnpm-workspace" skills/retro/SKILL.md` — E14 detection
- [ ] Verify: `grep "\-\-since\|\-\-path" skills/retro/SKILL.md` — flags present (no --until)
- [ ] Commit: "add zuvo:retro skill — engineering retrospective from git metrics"

---

### Task 9: Update routing table

**Files:** `skills/using-zuvo/SKILL.md`
**Complexity:** standard
**Dependencies:** Tasks 4-8
**Model routing:** Sonnet

**What to write:**

Add a new **Priority 5 — Release** section between current Priority 4 (Utility) and the Pipeline Enforcement section. Contains:

```markdown
### Priority 5 — Release (post-code lifecycle)

| User intent | Skill |
|-------------|-------|
| Ship a release, push code, create PR, bump version | `zuvo:ship` |
| Deploy to production, merge PR, verify health | `zuvo:deploy` |
| Monitor production after deploy, check for regressions | `zuvo:canary` |
| Sync documentation with a release | `zuvo:release-docs` |
| Engineering retrospective, shipping velocity | `zuvo:retro` |
```

Also update the Priority Resolution section to add:
```
5. **Release** — Ship, deploy, monitor, document, reflect.
```

- [ ] Write: Edit `skills/using-zuvo/SKILL.md` to add Priority 5 section
- [ ] Verify: `grep "ship\|deploy\|canary\|release-docs\|retro" skills/using-zuvo/SKILL.md` — all 5 present
- [ ] Verify: routing table has no duplicate skill names
- [ ] Commit: "add release skills to routing table — Priority 5"

---

### Task 10: Update manifests and docs

**Files:** `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`, `package.json`, `docs/skills.md`
**Complexity:** standard
**Dependencies:** Task 9
**Model routing:** Sonnet

**What to write:**

1. `.claude-plugin/plugin.json` — update description: "27 domain-specific task skills" → "32 domain-specific task skills"
2. `.codex-plugin/plugin.json` — update description: "33 skills" → "38 skills"
3. `package.json` — update description: "27 domain-specific task skills" → "32 domain-specific task skills". Add keywords: `"ship"`, `"deploy"`, `"canary"`, `"release"`, `"retro"`.
4. `docs/skills.md` — add a "Release" category section with 5 skill rows. Update total count.

- [ ] Write: Edit all 4 files
- [ ] Verify: `grep "32" .claude-plugin/plugin.json` — count updated
- [ ] Verify: `grep "38" .codex-plugin/plugin.json` �� count updated
- [ ] Verify: `grep "32" package.json` — count updated
- [ ] Verify: `grep "ship\|deploy\|canary\|release-docs\|retro" docs/skills.md` — all 5 present
- [ ] Commit: "update manifests and docs with 5 new release skills"
