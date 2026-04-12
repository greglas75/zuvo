---
name: context-audit
description: "Context health monitoring. Analyzes include loading trends from context-metrics.log, audits CLAUDE.md/rules/settings for bloat, scores setup health. Modes: trend (default), full (with /context data), baseline (save snapshot)."
---

# zuvo:context-audit — Context Health Monitor

Tracks what fills your context window over time and flags waste. Two data sources:
1. **Auto-collected** — `~/.zuvo/context-metrics.log` (populated by `track-includes.sh` hook on every skill run)
2. **Manual** — `/context` output (optional, for full system-level audit)

## Argument Parsing

| Flag | Effect |
|------|--------|
| `--full` | Full audit: requires `/context` data. Audits MCP, CLAUDE.md, settings, permissions |
| `--baseline` | Save current state as baseline for future delta comparisons |
| `--since N` | Show trend for last N days (default: 7) |
| _(no flags)_ | Trend mode: analyze context-metrics.log, show include loading patterns |

## Mandatory File Loading

Read these files:

```
CORE FILES LOADED:
  1. ../../shared/includes/run-logger.md       -- READ
  2. ../../shared/includes/retrospective.md    -- READ
```

## Phase 0: Collect Data

### Metrics data (always available)

Read `~/.zuvo/context-metrics.log`:

```bash
METRICS_LOG="$HOME/.zuvo/context-metrics.log"
```

If the file doesn't exist or has <3 entries: print "Not enough data yet. Run a few zuvo skills first — metrics are collected automatically after each skill run." and exit.

Parse TSV fields: `DATE, SKILL, PROJECT, INCLUDES_COUNT, INCLUDES_BYTES, INCLUDES, TIER`

Also read `~/.zuvo/runs.log` for skill invocation context (field 12 INCLUDES if available).

### /context data (--full mode only)

Check conversation history for `/context` output. If not found:

"Run `/context` in this session and let me know when you're done. I need the token breakdown to audit your full setup."

**STOP HERE in --full mode.** Do not proceed until the user provides /context data.

In default trend mode: skip this step entirely, proceed with metrics data.

## Phase 1: Trend Analysis (default mode)

Parse `context-metrics.log` for the `--since` period (default 7 days).

### 1.1 Include Loading Frequency

Count how many times each include was loaded across all skill runs:

```
TOP INCLUDES (last 7 days, N skill runs)

  # INCLUDE              LOADS   AVG_SIZE   CUMULATIVE
  1 env-compat.md        N/N     1.5K       NK
  2 codesift-setup.md    N/N     1.5K       NK
  3 run-logger.md        N/N     4.4K       NK
  4 cq-patterns.md       N/N     27.0K      NK
  ...
```

Flag includes with cumulative >100K as `⚠ HIGH CUMULATIVE COST`.

### 1.2 Heaviest Runs

Find the top 3 skill runs by `INCLUDES_BYTES`:

```
HEAVIEST RUNS

  1. refactor @ project — 14 includes / 82K
  2. review @ project — 10 includes / 58K
  3. execute @ project — 12 includes / 71K
```

### 1.3 Tier Distribution

Per-skill breakdown of tier usage (from TIER field):

```
TIER DISTRIBUTION

  review:      tier-0: 5  tier-1: 3  tier-2: 8  tier-3: 2
  write-tests: LIGHT: 4  STANDARD: 8  HEAVY: 2
  build:       LIGHT: 3  STANDARD: 5  DEEP: 1
```

### 1.4 Week-over-Week Delta

If enough data exists (>14 days), compare this week vs last week:

```
TREND (this week vs last)

  Avg includes/run:  7.2 → 6.8  ↓ 6%
  Avg bytes/run:     42K → 38K  ↓ 10%
  Total skill runs:  23 → 19    ↓ 17%
```

### 1.5 Recommendations

Based on the data, generate actionable recommendations:

| Condition | Recommendation |
|-----------|----------------|
| Any include with cumulative >200K | "Consider splitting [file] — loaded N times at XK each" |
| Any run with >100K includes bytes | "[skill] runs are heavy — check if all includes are necessary at its tier" |
| Same include loaded by >80% of runs | "Consider inlining [file] essentials into env-compat or making it a hook" |
| Include that grew >20% since baseline | "[file] grew from XK to YK — review recent additions" |

## Phase 2: Full Audit (--full mode only)

Only runs when `--full` flag is provided AND /context data is available.

### 2.1 MCP Servers

From `/context` output, count MCP servers and their tool counts. Flag:
- Servers with >30 tools (high token cost per definition)
- Servers with CLI alternatives (playwright → npx playwright, github → gh)

### 2.2 Memory Files

Read all files listed in `/context` Memory section. For each, apply 5 filters:

| Filter | Flag when... |
|--------|-------------|
| Default | Claude already does this without being told |
| Contradiction | Conflicts with another rule in same or different file |
| Redundancy | Repeats something already covered elsewhere |
| Bandaid | Added to fix one bad output, not improve outputs generally |
| Vague | Interpreted differently every time ("be natural") |

Count total lines. Flag if >200 lines combined.

### 2.3 Skills

From `/context` Skills section, for each skill >120 tokens:
- Flag as "consider trimming description"
- Check for restated goals or synonymous instructions

### 2.4 Settings

Check the global and project settings files (e.g., `settings.json`):

| Setting | Flag if | Recommended |
|---------|---------|-------------|
| autocompact_percentage_override | Missing or >80 | 75 |

### 2.5 File Permissions

Check `settings.json` for `permissions.deny` rules. If missing, check whether bloat directories exist:

| If exists... | Should deny... |
|--------------|---------------|
| package.json | node_modules, dist, build, .next, coverage |
| Cargo.toml | target |
| go.mod | vendor |
| pyproject.toml | __pycache__, .venv |

## Phase 3: Score and Report

### Scoring (--full mode)

Score starts at 100. Deduct per issue:

| Issue | Points |
|-------|--------|
| Memory files >200 lines total | -10 |
| Memory files >500 lines total | -20 |
| Per 5 rules flagged by filters | -5 |
| Contradictions between files | -10 |
| Missing autocompact override | -10 |
| Skill >120 tokens | -3 each |
| Per MCP server | -3 each |
| No deny rules + bloat dirs exist | -10 |

Floor at 0. Labels: 90-100 `CLEAN`, 70-89 `NEEDS WORK`, 50-69 `BLOATED`, 0-49 `CRITICAL`.

### Scoring (trend mode)

Score based on metrics data:

| Condition | Points |
|-----------|--------|
| Avg bytes/run <30K | +20 |
| Avg bytes/run 30-60K | +10 |
| Avg bytes/run >60K | 0 |
| Week-over-week improving (↓) | +10 |
| Week-over-week stable | +5 |
| Week-over-week degrading (↑ >10%) | -10 |
| No include >200K cumulative | +10 |
| Any include >200K cumulative | -5 per file |

Base 50 + adjustments. Same labels.

### Output Format

```
# Context Audit

Score: {N}/100 [{CLEAN|NEEDS WORK|BLOATED|CRITICAL}]
Mode: {trend|full}
Period: {last N days} ({M skill runs})

## Include Loading

{Phase 1.1 table}

## Heaviest Runs

{Phase 1.2 table}

## Tier Distribution

{Phase 1.3 table}

## Trend

{Phase 1.4 delta, or "Not enough data for trend"}

## Issues Found

### [{CRITICAL|WARNING|INFO}] {Category}
{What's wrong}
Fix: {One-line actionable fix}

## Recommendations

{Phase 1.5 or Phase 2 recommendations, ranked by impact}

## Top 3 Fixes

1. {Highest-impact fix}
2. {Second}
3. {Third}
```

## Phase 4: Baseline (--baseline mode)

Save current metrics snapshot to `~/.zuvo/context-baseline.json`:

```json
{
  "date": "2026-04-12",
  "avg_includes_per_run": 7.2,
  "avg_bytes_per_run": 38000,
  "total_runs": 23,
  "top_includes": {
    "env-compat": {"loads": 23, "size": 1500},
    "cq-patterns": {"loads": 8, "size": 27000}
  },
  "include_sizes": {
    "env-compat.md": 1500,
    "codesift-setup.md": 1500,
    "cq-patterns.md": 27000
  }
}
```

Print: "Baseline saved. Run `zuvo:context-audit` again after your next changes to see the delta."

## Phase 5: Offer to Fix (--full mode only)

After the report:

"Want me to fix any of these? I can:
- Show you a cleaned-up CLAUDE.md with the flagged rules removed
- Add the missing settings.json configs
- Add permissions.deny rules for build artifacts"

Auto-apply settings.json and permissions.deny (safe, reversible).
Show diffs for CLAUDE.md — let the user confirm before modifying instruction files.

### Retrospective (REQUIRED)

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

## Output

```
Run: <ISO-8601-Z>	context-audit	<project>	-	-	<VERDICT>	-	<mode>	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

After appending the Run: line, collect context metrics:

```bash
bash "${CLAUDE_PLUGIN_ROOT}/hooks/collect-context-metrics.sh" "context-audit" "<project>" "-"
```
