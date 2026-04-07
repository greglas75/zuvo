---
name: incident
description: >
  Incident response and postmortem generation from git/deploy context. When something
  breaks in production, this skill builds a timeline, identifies the probable cause,
  and generates a structured postmortem document. Flags: --since, --service, --sev,
  --revert, --comms, --dry-run.
---

# zuvo:incident — Incident Response & Postmortem

A structured framework for production incident investigation. Builds a timeline from git history, CI/CD deploys, and error tracking, identifies suspect commits, assesses impact, recommends remediation, and generates a blameless postmortem document.

**Scope:** Production incidents where something is broken, degraded, or behaving unexpectedly. Investigation, root cause analysis, and postmortem generation.
**Out of scope:** Actually applying fixes (use `zuvo:debug` or `zuvo:build`), code quality sweeps (`zuvo:code-audit`), performance investigation without an active incident (`zuvo:performance-audit`).

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `[description]` | What happened (free text) |
| `--since [time]` | When the incident started (ISO-8601, relative like `2h`, or natural language like `yesterday 3pm`). Default: `24h` ago |
| `--service [name]` | Affected service, endpoint, or component |
| `--sev [1-4]` | Override auto-detected severity (1=critical, 4=low) |
| `--revert` | Include revert recommendation with exact command |
| `--comms` | Generate communication templates (internal + customer-facing) |
| `--dry-run` | Analyze only, do not create postmortem file |

Flags can be combined: `zuvo:incident payments returning 500 --since 2h --service /api/payments --sev 1 --revert --comms`

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Key tools for incident response:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 2 | Blast radius of suspect commits | `impact_analysis(repo, since="[suspect]")` | Grep for imports of changed files |
| 2 | Callers of changed code | `trace_call_chain(repo, symbol, direction="callers")` | Repeated Grep for function name |
| 2 | Symbol-level changes | `changed_symbols(repo, since="[timeframe]")` | `git diff --stat` |
| 2 | Compact change summary | `diff_outline(repo, since="[timeframe]")` | `git log --oneline` |
| 3 | Understand affected function | `get_context_bundle(repo, symbol_name)` | Read the entire file |
| Any | Batch 3+ lookups | `codebase_retrieval(repo, queries=[...])` | Sequential Grep/Read |

## Mandatory File Loading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md      -- READ/MISSING
  2. ../../shared/includes/codesift-setup.md   -- READ/MISSING
  3. ../../shared/includes/run-logger.md       -- READ/MISSING
```

**If any CORE file is missing:** Proceed in degraded mode. Note "DEGRADED -- [file] unavailable" in the output.

---

## Safety Rules

This skill is **READ-ONLY** except for writing the postmortem document (Phase 5).

- **NEVER** execute `git revert`, `git reset`, or any destructive git command
- **NEVER** push to remote
- **NEVER** modify production code, configuration, or infrastructure
- **NEVER** restart services or trigger deploys
- Suggest fixes and reverts with exact commands, but do NOT apply them
- When `--dry-run` is set, do not create any files at all

---

## Phase 0: Incident Triage

### 0.1 Parse Context

Extract from `$ARGUMENTS`:
- **What happened:** The incident description (free text)
- **When:** Parse `--since` or default to 24 hours ago. Convert to ISO-8601.
- **What service/endpoint:** From `--service` or infer from the description
- **Severity override:** From `--sev` if provided

If the description is empty or insufficient, ask the user:
> Describe what is happening. Include: the error message or symptom, which service or endpoint is affected, and approximately when it started.

### 0.2 Sentry Integration (if available)

Check if Sentry MCP tools are available. If so:

1. `list_issues` -- pull recent issues sorted by first-seen, filtered to the timeframe
2. For the top 3 relevant issues:
   - Stack traces
   - Affected users count
   - First-seen and last-seen timestamps
   - Event frequency (is it increasing?)
3. `list_events` -- recent events for correlation with deploy timeline

If Sentry is not available, note: `Sentry: unavailable -- using git history only`

### 0.3 Determine Severity

Auto-classify severity based on signals. `--sev` overrides this.

| Severity | Criteria | Examples |
|----------|----------|----------|
| **SEV-1 (CRITICAL)** | Service down, data loss, security breach, all users affected | 500 on all requests, DB corruption, auth bypass |
| **SEV-2 (HIGH)** | Major feature broken, significant user impact, revenue affected | Payment processing failing, search returning no results |
| **SEV-3 (MEDIUM)** | Partial degradation, workaround exists, subset of users affected | Slow responses on one endpoint, export feature broken |
| **SEV-4 (LOW)** | Minor issue, cosmetic, low impact, no data loss | UI glitch, wrong label, non-critical notification failure |

Output:

```
INCIDENT TRIAGE
  Description:  [what happened]
  Severity:     SEV-[N] ([CRITICAL/HIGH/MEDIUM/LOW]) [AUTO / OVERRIDE]
  Since:        [ISO-8601 timestamp]
  Service:      [affected service/endpoint]
  Sentry:       [N issues found / unavailable]
```

---

## Phase 1: Timeline Construction

Build a chronological timeline of events leading to and during the incident.

### 1.1 Recent Deploys

```bash
git log --since="[incident time - 24h]" --oneline --format="%h %ai %s"
```

For each commit, note:
- Hash (short)
- Timestamp
- Author
- Message
- Files changed: `git diff --stat [commit]~1 [commit]`

### 1.2 CI/CD History

Cross-reference with CI/CD to identify actual deploys (not just commits):

**GitHub Actions:**
```bash
gh run list --limit 20 --json conclusion,createdAt,headBranch,name,status,databaseId
```

Filter to runs that completed successfully within the timeframe. These represent actual deploys.

**Vercel:** Check for `vercel.json` or `.vercel/` metadata. If found, note deployment context.

**Other platforms:** Check for deployment config files (`fly.toml`, `netlify.toml`, `render.yaml`, `railway.json`, `Procfile`). Note the platform but do not attempt to query deployment APIs without explicit user configuration.

### 1.3 Sentry Correlation (if available)

If Sentry data was gathered in Phase 0:
- Map first-seen timestamps of relevant issues to the deploy timeline
- Identify which deploy likely introduced each error
- Note error frequency trends (increasing, stable, decreasing)

### 1.4 Build Timeline

Assemble all data into a chronological timeline:

```
TIMELINE
------------------------------------------------------
[T-24h]  Deploy: abc1234 "feat: add payment retry" (author)
[T-18h]  Deploy: def5678 "fix: update rate limiter" (author)
[T-4h]   CI: deploy pipeline succeeded (branch: main)
[T-2h]   First error reported (Sentry issue #1234 / user report)
[T-1h]   Error rate increasing (Sentry: 50 events/hr -> 200 events/hr)
[T-0]    Incident declared
------------------------------------------------------
```

Use relative timestamps (`T-Nh`) anchored to the incident declaration time. Include absolute timestamps in parentheses when available.

---

## Phase 2: Root Cause Analysis

### 2.1 Identify Suspect Commits

Determine the window of suspect commits:
- **Last known good:** The most recent point where the system was confirmed working (last successful deploy before errors, or user-reported "it worked at [time]")
- **First error:** The earliest error signal (Sentry first-seen, first user report, or first failed health check)

List all commits between last-known-good and first-error:

```bash
git log --format="%H %ai %an %s" [last-good]..[first-error]
```

If the window is unclear, use all commits in the 24h before the incident.

### 2.2 Analyze Each Suspect

For each suspect commit:

1. **Read the diff:**
   ```bash
   git show [commit] --stat
   git show [commit] -- [relevant files]
   ```

2. **Classify risk area:**
   - AUTH: authentication, authorization, access control, tokens, sessions
   - PAYMENT: billing, payment processing, money calculations, subscriptions
   - DATA: database schema, migrations, data transformations, ORM changes
   - API: endpoint contracts, request/response shapes, middleware, routing
   - CONFIG: environment variables, feature flags, deployment config
   - INFRA: networking, caching, rate limiting, connection pools
   - LOGIC: business logic, state management, calculation changes

3. **Check overlap with affected service:**
   Does this commit touch the same files, endpoints, or code paths as the affected service/endpoint?

4. **CodeSift analysis (if available):**
   - `impact_analysis(repo, since="[suspect commit]")` -- blast radius
   - `trace_call_chain(repo, symbol, direction="callers")` -- who calls the changed code
   - `changed_symbols(repo, since="[suspect commit]")` -- symbol-level changes

### 2.3 Correlate and Rank

Score each suspect commit on three dimensions:

| Dimension | Signal |
|-----------|--------|
| **Temporal proximity** | How close is this commit to the first error? Closer = higher probability |
| **Code area overlap** | Does this commit touch the same service, endpoint, or module? Direct overlap = higher probability |
| **Risk signal match** | Does the risk area match the incident type? (e.g., auth change + auth error) Match = higher probability |

Rank suspects by combined probability:

```
SUSPECT COMMITS
------------------------------------------------------
#1  abc1234  [LIKELY]    "fix: update rate limiter"
    Risk: INFRA | Overlap: YES (touches rate-limit middleware)
    Proximity: 2h before first error
    Blast radius: 12 callers via middleware chain

#2  def5678  [POSSIBLE]  "feat: add payment retry"
    Risk: PAYMENT | Overlap: PARTIAL (same service, different endpoint)
    Proximity: 18h before first error
    Blast radius: 3 direct callers
------------------------------------------------------
```

If no clear candidate emerges, state: "Root cause unclear -- multiple candidates with similar probability. Manual investigation recommended."

---

## Phase 3: Impact Assessment

Quantify the incident impact across these dimensions:

### 3.1 User Impact

| Source | Method |
|--------|--------|
| Sentry (if available) | Affected users count from issue details |
| Error rate | Compare error rate in incident window vs. baseline |
| Estimation | If no data: estimate from service criticality and duration |

### 3.2 Duration

- **Start:** First error signal (Sentry first-seen, first user report)
- **End:** Resolution time (if resolved) or current time (if ongoing)
- **Total duration:** End - Start
- **Time to detect:** First error - Last deploy
- **Time to respond:** Incident declared - First error

### 3.3 Data Impact

Assess whether the incident caused:
- **Data corruption:** Were records modified incorrectly?
- **Data loss:** Were records deleted or failed to persist?
- **Data exposure:** Was data leaked or accessible to unauthorized users?
- **None:** No data impact detected

Base this on the code changes in suspect commits and the nature of the errors.

### 3.4 Financial Impact

If the affected service involves payments, billing, or revenue:
- Estimate transactions affected (from error count and duration)
- Note whether failed transactions are recoverable (retryable) or lost

If not payment-related: "Financial impact: indirect (user trust, potential churn)"

### 3.5 SLA Impact

Check for SLA commitments:
- Uptime SLA: was the service unavailable? For how long?
- Response time SLA: were response times degraded beyond thresholds?
- If no SLA information available: "SLA impact: unknown -- no SLA documentation found"

Output:

```
IMPACT ASSESSMENT
------------------------------------------------------
Users affected:    ~[N] (source: [Sentry / estimation])
Duration:          [Xh Ym] ([start] to [end/ongoing])
Time to detect:    [Xm]
Time to respond:   [Xm]
Data impact:       [none / corrupted / lost / exposed]
Financial impact:  [none / estimated $X / indirect]
SLA impact:        [none / breached: [detail] / unknown]
------------------------------------------------------
```

---

## Phase 4: Remediation

### 4.1 Immediate Actions

Based on the root cause analysis:

**If root cause is identified with high confidence:**

1. **Revert (if applicable and `--revert` is set):**
   Provide the exact revert command but DO NOT execute it:
   ```
   SUGGESTED REVERT (do NOT execute without user confirmation):
   git revert [commit-hash] --no-edit
   ```
   Note whether the revert is safe (no dependent commits that would conflict).

2. **Hotfix:** If a revert is not practical (dependent commits, data migration):
   Outline the minimal fix in pseudocode or a description. Suggest dispatching `zuvo:build` or `zuvo:debug` for the actual implementation.

3. **Config change:** If the issue is configuration-related, specify exactly what to change and where.

**If root cause is unclear:**

1. Suggest specific investigation steps (which logs to check, which endpoints to test)
2. Suggest rollback to last known good deploy with exact commands
3. Suggest enabling additional monitoring or logging

### 4.2 Post-Fix Monitoring

Regardless of the fix approach, recommend what to watch:

```
MONITORING CHECKLIST
------------------------------------------------------
[ ] Error rate on [endpoint/service] returns to baseline
[ ] Response time on [endpoint/service] returns to baseline
[ ] No new Sentry issues in the affected area (next 1h)
[ ] [Specific metric relevant to the incident]
------------------------------------------------------
```

---

## Phase 5: Postmortem Document

Skip this phase if `--dry-run` is set. Instead, print: `[DRY RUN] Postmortem would be saved to docs/incidents/incident-[date]-[slug].md`

### 5.1 Generate Slug

Derive a URL-safe slug from the incident description:
- Lowercase, hyphen-separated, max 40 characters
- Examples: `payments-500-errors`, `auth-service-down`, `search-timeout`

### 5.2 Create Directory

```bash
mkdir -p docs/incidents
```

### 5.3 Write Postmortem

Save to: `docs/incidents/incident-[YYYY-MM-DD]-[slug].md`

Use this exact format:

```markdown
# Incident Report: [Title]

## Metadata
| Field | Value |
|-------|-------|
| Date | [YYYY-MM-DD] |
| Severity | SEV-[1-4] |
| Duration | [Xh Ym] |
| Affected service | [service/endpoint] |
| Root cause | [1-line summary] |
| Status | [RESOLVED / MITIGATED / INVESTIGATING] |

## Summary
[2-3 sentence executive summary -- what happened, who was affected, how it was resolved]

## Timeline
| Time (UTC) | Event |
|------------|-------|
| [timestamp] | [event] |

## Root Cause
[Detailed explanation of what went wrong and why. Reference specific commits, files, lines.]

### Suspect Commits
| Commit | Author | Message | Risk | Probability |
|--------|--------|---------|------|-------------|
| [hash] | [author] | [msg] | [HIGH/MED] | [likely/possible] |

## Impact
| Metric | Value |
|--------|-------|
| Users affected | [count or estimate] |
| Duration | [time] |
| Data impact | [none / corrupted / lost] |
| Revenue impact | [none / estimated $X] |

## Resolution
[What was done to fix it. Revert? Hotfix? Config change?]

## Action Items
| # | Action | Owner | Priority | Due |
|---|--------|-------|----------|-----|
| 1 | [action] | [TBD] | P0 | [date] |
| 2 | [action] | [TBD] | P1 | [date] |
| 3 | [action] | [TBD] | P2 | [date] |

## Lessons Learned
- What went well: [what helped during response]
- What went poorly: [what slowed down response]
- Where we got lucky: [things that could have been worse]

## Prevention
- [ ] [Specific change to prevent recurrence]
- [ ] [Monitoring/alerting improvement]
- [ ] [Process change]
```

Action items must be specific and actionable. Each should reference a file, endpoint, or system component. Assign P0 to items that prevent recurrence, P1 to detection improvements, P2 to process improvements.

---

## Phase 6: Communication (optional, requires `--comms`)

Skip this phase unless `--comms` was passed.

Generate communication templates for two audiences:

### 6.1 Internal Team Communication

```
Subject: [Incident] [Service] -- SEV-[N] [Status]

Team,

We experienced [issue description] affecting [scope] from [start time] to
[end time / ongoing].

Root cause: [technical explanation -- appropriate detail for engineering team].

Suspect commit: [hash] "[message]" by [author].

Current status: [RESOLVED / MITIGATED / INVESTIGATING]
[If resolved: fix was [revert/hotfix/config change] applied at [time]]
[If investigating: next steps are [specific actions]]

Action items:
1. [P0 item]
2. [P1 item]

Postmortem: docs/incidents/incident-[date]-[slug].md

[Your name]
```

### 6.2 Customer-Facing Communication

```
Subject: [Service] -- [Status Update]

Hi,

We experienced [plain-language issue description] affecting [user-visible scope]
from [start] to [end].

Root cause was [brief, non-technical explanation]. We have [resolved/mitigated]
the issue by [plain-language action].

We are implementing [prevention measures] to prevent recurrence.

We apologize for any inconvenience. If you experienced any issues during this
window, please contact [support channel].

[Team/Company name]
```

Adjust tone:
- Internal: technical, specific, action-oriented
- Customer: empathetic, plain language, forward-looking
- Both: honest about what happened, clear about status

---

## Completion

```
INCIDENT RESPONSE COMPLETE
----------------------------------------------------
Incident:      [description]
Severity:      SEV-[N] ([CRITICAL/HIGH/MEDIUM/LOW])
Status:        [RESOLVED / MITIGATED / INVESTIGATING]
Duration:      [Xh Ym]
Suspects:      [N commits analyzed, top suspect: hash "message"]
Root cause:    [1-line summary or "under investigation"]
Impact:        [N users affected, data: none/corrupted/lost]
Postmortem:    [file path or "DRY RUN -- not created"]
Comms:         [generated / not requested]

Run: <ISO-8601-Z>	incident	<project>	SEV-<N>	<duration>	<STATUS>	-	<N>-suspects	<NOTES>	<BRANCH>	<SHA7>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

STATUS: RESOLVED, MITIGATED, INVESTIGATING
DURATION: incident duration (e.g., `2h15m`) or `ongoing`
NOTES: 1-line incident summary (max 80 chars)

Next steps:
  zuvo:debug [suspect-file]   -- investigate and fix root cause
  zuvo:build [fix]            -- implement a hotfix
  git revert [commit]         -- revert suspect commit (if recommended)
----------------------------------------------------
```
