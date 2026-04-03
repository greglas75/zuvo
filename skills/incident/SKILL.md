---
name: incident
description: "Structured production incident post-mortem analysis. Builds a timeline from git history, error traces, deployment markers, and configuration changes. Identifies root cause via 5-Whys technique, assesses impact, and produces an actionable incident report with prevention measures and backlog items. Supports severity classification (SEV1-SEV3) and configurable investigation windows."
---

# zuvo:incident — Production Incident Post-Mortem

A structured post-mortem workflow for production incidents. Collects evidence from multiple sources (git log, error traces, deployment history, configuration diffs), reconstructs a chronological timeline, performs root cause analysis using the 5-Whys technique, and produces an actionable incident report with prevention measures.

**Scope:** Production incidents, outages, data corruption or loss events, performance degradation events, security breaches with production impact.
**Out of scope:** Active debugging of live issues (use `zuvo:debug`), general code review (use `zuvo:review`), performance optimization without an incident (use `zuvo:performance-audit`), security posture assessment (use `zuvo:security-audit`).

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Argument | Effect |
|----------|--------|
| `[description or error]` | Incident description, error message, or issue tracker ID (e.g., Sentry issue) |
| `--since [date/commit]` | Start of investigation window (default: 24 hours before current time) |
| `--severity [SEV1/SEV2/SEV3]` | Incident severity level (auto-classified in Phase 3 if not provided) |
| `--output [path]` | Save report to specific path (default: `docs/incidents/YYYY-MM-DD-slug.md`) |
| _(empty)_ | Ask the user: "Describe the incident. Share error messages, affected service, and approximate timeline." |

Severity definitions:

| Level | Definition | Examples |
|-------|-----------|----------|
| **SEV1** | Full outage or data loss affecting all users | Service down, database corruption, auth system failure |
| **SEV2** | Degraded service or partial outage affecting a subset of users | Payment failures for specific flow, elevated error rates, slow responses |
| **SEV3** | Minor issue with limited user impact, caught early | Edge case error, cosmetic bug in production, non-critical feature broken |

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

**Interaction behavior is governed entirely by env-compat.md.** This skill does not override env-compat defaults. Specifically:
- Report output path confirmation follows env-compat rules for the detected environment.
- Backlog persistence follows env-compat rules.

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Key tools for incident investigation:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 0 | Identify changed symbols in window | `changed_symbols(repo, since="[commit]")` | `git log --oneline` + `git diff` |
| 0 | Blast radius of recent changes | `impact_analysis(repo, since="[commit]", depth=3)` | Grep for imports of changed files |
| 0 | Compact change summary | `diff_outline(repo, since="[commit]")` | `git diff --stat` |
| 1 | Trace deployment-related changes | `search_text(repo, "deploy\|release\|version", file_pattern="*.yml")` | Grep CI/CD config files |
| 2 | Trace call chain from error source | `trace_call_chain(repo, symbol_name, direction="callers", depth=3)` | Repeated Grep for function name |
| 2 | Understand failing function with context | `get_context_bundle(repo, symbol_name)` | Read the entire file |
| 2 | Find where the error originates | `search_text(repo, query="error message", regex=true)` | Grep |
| Any | Batch 3+ lookups | `codebase_retrieval(repo, queries=[...])` | Sequential Grep/Read |

### Degraded Mode (CodeSift unavailable)

| CodeSift tool | Fallback | Lost capability |
|---------------|----------|-----------------|
| `changed_symbols` | `git log --oneline` + `git diff` | No symbol-level granularity |
| `impact_analysis` | Grep for imports of changed files | No transitive dependency detection |
| `trace_call_chain` | Grep for function name | No multi-level caller analysis |
| `get_context_bundle` | Read file manually | Higher token cost |
| `diff_outline` | `git diff --stat` | No symbol-level diff summary |

## Mandatory File Reading

Read each file below before starting work. Print the checklist with status.

```
CORE FILES LOADED:
  1. {plugin_root}/shared/includes/auto-docs.md       -- READ/MISSING
  2. {plugin_root}/shared/includes/session-memory.md   -- READ/MISSING
  3. {plugin_root}/shared/includes/env-compat.md       -- READ/MISSING
  4. {plugin_root}/shared/includes/codesift-setup.md   -- READ/MISSING
```

Where `{plugin_root}` is resolved per `env-compat.md`.

**If any file is missing:** Proceed in degraded mode. Note "DEGRADED -- [file] unavailable" in the incident report.

---

## Phase 0: Gather Evidence

Collect from all available sources. Run independent searches in parallel where the environment supports it.

### 0.1 Determine Investigation Window

```
if --since provided:
  window_start = parse(--since)   # date, commit hash, or relative ("3d", "48h")
else:
  window_start = 24 hours before current time
```

### 0.2 Git History

Collect recent commits within the investigation window:

```bash
git log --since="[window_start]" --oneline --format="%h %ai %an — %s"
```

If `--since` is a commit hash, use `git log [hash]..HEAD` instead.

Flag commits that touch:
- Error-related files (from description or stack trace)
- Configuration files (`.env*`, `config/`, feature flags)
- CI/CD files (`.github/workflows/`, `Dockerfile`, deployment configs)
- Database migrations

### 0.3 Deployment Markers

Search for deployment evidence: recent tags (`git tag --sort=-creatordate | head -10`), CI/CD artifacts (`.github/workflows/`, `Jenkinsfile`, `deploy.sh`), release notes (`CHANGELOG.md`, GitHub releases).

### 0.4 Error Context

From the user-provided description, extract stack traces (file paths, line numbers, function names), error messages (search codebase for origin), and affected code paths (trace from error to entry point).

### 0.5 Code Changes (CodeSift or fallback)

1. `changed_symbols(repo, since="[window_start]")` -- what symbols changed
2. `impact_analysis(repo, since="[window_start]", depth=3)` -- blast radius
3. For each changed file, note the author and commit message

### 0.6 Configuration Changes

```bash
git diff [window_start]..HEAD -- "*.env*" "config/" "*.yml" "*.yaml" "*.toml" "*.json"
```

Check for:
- Environment variable additions or removals
- Feature flag changes
- Infrastructure configuration changes
- Dependency version changes (`package.json`, `requirements.txt`, etc.)

### 0.7 Evidence Summary

Print:

```
EVIDENCE GATHERED
  Commits:        [N] commits in investigation window
  Deployments:    [N] deployment markers found
  Code changes:   [N] symbols changed across [M] files
  Config changes: [N] configuration files modified
  Error traces:   [N] stack traces / error messages analyzed
  Window:         [start] → [now]
```

---

## Phase 1: Build Timeline

Construct a chronological timeline from all evidence sources. Use git log timestamps, tag dates, CI/CD run times, and user-provided timestamps.

### 1.1 Collect and Sort Events

For each evidence item, create a timestamped event with type (CODE_CHANGE, DEPLOYMENT, ERROR, CONFIG_CHANGE, REPORT). Sort chronologically. Express times relative to incident declaration (T-0):

```
INCIDENT TIMELINE
----------------------------------------------------
  [T-48h] CODE_CHANGE  commit abc123 — "Add discount calculation" (author: dev1)
  [T-36h] CODE_CHANGE  commit def456 — "Update payment service error handling" (author: dev2)
  [T-24h] DEPLOYMENT   tag v1.4.2 deployed to production
  [T-18h] CONFIG_CHANGE .env.production — added DISCOUNT_ENABLED=true
  [T-12h] ERROR        First error logged: NullPointerException in PaymentService.calculateTotal()
  [T-6h]  ERROR        Error rate spikes 10x — [N] occurrences in 6 hours
  [T-2h]  REPORT       User reports: "Payment fails for discounted orders"
  [T-0]   REPORT       Incident declared
----------------------------------------------------
```

### 1.2 Identify Suspect Window

The **suspect window** is the period between the last known-good state and the first error. List commits and config changes within this window.

---

## Phase 2: Root Cause Analysis

### 2.1 Five Whys

Apply the "5 Whys" technique starting from the user-visible symptom. Each "why" must be supported by evidence from Phase 0 and Phase 1.

```
ROOT CAUSE ANALYSIS (5 Whys)
----------------------------------------------------
1. Why did [symptom]?
   → [direct cause] — Evidence: [file:line, error message, test result]

2. Why did [direct cause]?
   → [deeper cause] — Evidence: [commit hash, code path, config change]

3. Why did [deeper cause]?
   → [process gap] — Evidence: [missing test, review gap, no monitoring]

4. Why did [process gap] exist?
   → [systemic cause] — Evidence: [no CQ gate, no checklist, no alert]

5. Why?
   → [root organizational/process cause]
----------------------------------------------------
```

Stop before 5 if a deeper "why" would be speculative. Mark the deepest evidence-backed level as the actionable root cause.

### 2.2 Classify Findings

From the 5-Whys analysis, identify three categories:

| Category | Description | Example |
|----------|------------|---------|
| **Root cause** | The actual bug or change that triggered the incident | Missing null check in discount calculation (commit abc123) |
| **Contributing factors** | Process gaps that allowed the root cause to ship | No test for null discount scenario, review missed edge case |
| **Detection gap** | Why monitoring or alerting did not catch it sooner | No alerting on payment error rate spike, no null-safety CQ gate |

### 2.3 Trace the Fix (if already resolved)

If the incident has been resolved, identify the fix:

1. Which commit(s) fixed it?
2. Was the fix a revert, a patch, or a workaround?
3. Is the fix permanent or temporary?

If not yet resolved, note: `RESOLUTION: pending — [what is needed]`

---

## Phase 3: Impact Assessment

Assess the incident impact across five dimensions. Use evidence from Phase 0 and Phase 1.

### 3.1 Duration

| Metric | Value |
|--------|-------|
| **Time to first error** | Time from root cause deployment to first error |
| **Detection gap** | Time from first error to incident declaration |
| **Time to resolution** | Time from declaration to fix deployed (or "ongoing") |
| **Total duration** | First error to resolution |

### 3.2 User Impact

Estimate from error counts, affected code path traffic, user reports, and affected data (rows/records/transactions). If precise numbers are unavailable, provide a range with confidence level.

### 3.3 Data Impact

Assess: **Data corrupted** (Yes/No), **Data lost** (Yes/No, recoverable?), **Data exposure** (Yes/No, what data?).

### 3.4 Financial Impact

If calculable: failed transaction value, SLA breach penalties, recovery cost. Otherwise: `Financial impact: not quantifiable from available data`.

### 3.5 Severity Classification

If `--severity` was provided, validate it against the evidence. If not provided, classify:

| Level | Criteria |
|-------|----------|
| **SEV1** | Full outage OR data loss OR security breach OR >50% users affected |
| **SEV2** | Degraded service OR partial outage OR 5-50% users affected |
| **SEV3** | Minor issue OR <5% users affected OR caught before significant impact |

```
SEVERITY: SEV[N] — [one-line justification]
  Duration:     [total hours] ([detection gap] detection gap)
  Users:        ~[N] affected
  Data impact:  [none / corrupted / lost / exposed]
```

---

## Phase 4: Generate Incident Report

### 4.1 Determine Output Path

```
if --output provided:
  report_path = --output
else:
  slug = slugify(incident description, max 40 chars)
  report_path = docs/incidents/YYYY-MM-DD-{slug}.md
```

Create `docs/incidents/` directory if it does not exist.

### 4.2 Write Report

Save the incident report to `report_path` with these sections:

```markdown
# Incident Report: [Title]

**Date:** YYYY-MM-DD  |  **Severity:** SEV[N]  |  **Status:** Resolved / Ongoing / Mitigated
**Duration:** [total hours] (detection gap: [hours])
**Impact:** ~[N] users affected, [summary of impact]

## Summary
[2-3 sentences: what happened, what was affected, how it was resolved]

## Timeline
| Time | Event | Details |
|------|-------|---------|
| [T-Nh] | CODE_CHANGE / DEPLOYMENT / ERROR / REPORT | [details] |

## Root Cause
5-Whys analysis (each "why" with evidence), then a 1-3 sentence root cause summary.
**Commit:** [hash] — [message] — [author]  |  **File:** [file:line]

## Contributing Factors
- [process gaps that allowed root cause to ship]

## Detection Gap
- [why monitoring/alerting did not catch it sooner]

## Impact Assessment
| Dimension | Assessment |
|-----------|-----------|
| Duration / Users / Data / Financial | [values from Phase 3] |

## Resolution
[Fix description]  |  **Fix commit:** [hash]  |  **Type:** revert / patch / config / workaround
**Permanent:** Yes / No — [if no, what permanent fix is needed]

## Action Items
| # | Action | Owner | Priority | Due | Status |
|---|--------|-------|----------|-----|--------|
| 1 | [P0 immediate fix] | - | P0 | immediate | [done/open] |
| 2 | [P0 test gap] | - | P0 | immediate | [done/open] |
| 3 | [P1 monitoring/process] | - | P1 | this sprint | open |
| 4 | [P2 broader fix] | - | P2 | next sprint | open |

## Lessons Learned
### What went well / What went poorly / What to change
- [bullet points for each subsection]
```

### 4.3 Print Report Location

```
REPORT SAVED: [report_path]
```

---

## Phase 5: Create Prevention Items

### 5.1 Persist Action Items to Backlog

For each action item from Phase 4.2 (except items already marked "done"):

1. Read `memory/backlog.md`. If missing, create it with standard template.
2. Add each action item as a high-severity backlog entry:

```markdown
- B-{N} | {file-or-area} | incident-action | {description} | seen:1 | confidence:90 | source:incident/{date} | {date}
```

3. Deduplicate: if the same `file|description` combo already exists, increment `seen:N` and update date.

### 5.2 Offer Follow-Up Skills

Based on findings, suggest (do not auto-invoke): `zuvo:build` for code fixes, `zuvo:write-tests` for test gaps, `zuvo:code-audit` for broader review, `zuvo:security-audit` for security implications, `zuvo:performance-audit` for performance root causes.

---

## Completion

After Phase 5:

```
INCIDENT REPORT COMPLETE
----------------------------------------------------
Report:      [report_path]
Severity:    SEV[N]
Root cause:  [one-line root cause summary]
Duration:    [total hours] ([detection gap] detection gap)
Impact:      ~[N] users affected
Actions:     [N] items added to backlog ([M] already resolved)
Resolution:  [resolved / ongoing / mitigated]

Next steps:
  zuvo:build [fix description]     — implement prevention fix
  zuvo:write-tests [affected area] — add regression test coverage
  zuvo:code-audit [module]         — review affected code paths
----------------------------------------------------
```

---

## Auto-Docs

After printing the INCIDENT REPORT COMPLETE block, update project documentation per `shared/includes/auto-docs.md`:

- **project-journal.md**: Log the incident with severity, root cause summary, duration, and action item count.
- **architecture.md**: Update if the incident revealed an undocumented dependency or architectural weakness.
- **api-changelog.md**: Update if the fix changed any API endpoint behavior or error responses.

Use context already gathered during the investigation -- do not re-read source files. If auto-docs fails, log a warning and proceed to Session Memory.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with incident severity, root cause summary, action count, verdict.
- **Active Work**: Update if the incident spawned follow-up work.
- **Backlog Summary**: Recount from `memory/backlog.md` after action items were persisted.

If `memory/project-state.md` doesn't exist, create it (full Tech Stack detection + all sections).

---

## Run Log

Append one TSV line to `memory/zuvo-runs.log` per `shared/includes/run-logger.md`. All fields are mandatory:

| Field | Value |
|-------|-------|
| DATE | ISO 8601 timestamp |
| SKILL | `incident` |
| PROJECT | Project directory basename (from `pwd`) |
| CQ_SCORE | `-` (no code quality evaluation in post-mortem) |
| Q_SCORE | `-` (no test quality evaluation in post-mortem) |
| VERDICT | `PASS` if root cause identified, `WARN` if inconclusive, `FAIL` if no root cause found |
| TASKS | Number of action items created |
| DURATION | `5-phase` |
| NOTES | `SEV[N] [one-line incident summary]` (max 80 chars) |

---

## Tips for Better Input

- **Share the full stack trace**, not just the error message. The root cause is often several frames deep.
- **Include timestamps** -- "started failing around 3pm yesterday" helps narrow the investigation window.
- **Mention recent deployments** -- "we deployed v1.4.2 yesterday" immediately focuses the suspect window.
- **Link issue tracker IDs** -- Sentry issue IDs, PagerDuty incident IDs, or Jira tickets provide additional context.
- **Note what changed** -- "we enabled feature flag X" or "we updated dependency Y" shortens root cause analysis significantly.
