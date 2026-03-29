---
name: retro
description: >
  Engineering retrospective from git metrics. Reports deployment frequency,
  change lead time, churn hotspots, backlog health. Outputs narrative report
  with 3+ actionable items. Flags: --since, --path, explicit range argument.
---

# zuvo:retro

Generate an engineering retrospective from git history, backlog state, and skill usage trends. Produces a narrative report with actionable items.

**Scope:** Post-release or periodic retrospective covering shipping velocity, code churn, backlog health, and quality trends.
**Out of scope:** Actually fixing issues (use the suggested zuvo commands in the Actionable Items section).

## Argument Parsing

| Input | Action |
|-------|--------|
| _(empty)_ | Auto-detect window from `memory/last-ship.json` or last two git tags |
| `<range>` | Explicit git range, e.g., `v1.0.0..v1.2.0` |
| `--since <tag>` | Start of retrospective window (open-ended, through HEAD) |
| `--path <dir>` | Scope git analysis to a subdirectory (required for monorepos) |

---

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## Mandatory File Loading

```
CORE FILES LOADED:
  1. ../../shared/includes/env-compat.md    -- READ
  2. ../../shared/includes/run-logger.md    -- READ
```

Both files must be read before proceeding. If either is missing, note "DEGRADED -- [file] unavailable" in the report and continue with reduced capability.

---

## Phase 0: Window Detection

Determine the retrospective window in this priority order:

1. **Explicit argument** — if `<range>` was provided (e.g., `v1.0.0..v1.2.0`), use it directly.
2. **`--since <tag>`** — if provided, window is `<tag>..HEAD`. No `--until` flag is defined.
3. **`memory/last-ship.json`** — read the file if it exists. Use the `range` field (e.g., `"v1.1.0..v1.2.0"`).
4. **Last two git tags** — run `git describe --tags --abbrev=0` twice (with `--exclude` on first result) to derive `<prev-tag>..<latest-tag>`.
5. **Fallback** — if fewer than two tags exist, use the last 30 commits: derive range as `HEAD~30..HEAD`.

**Count commits in window:**
```bash
git log --oneline <range> | wc -l
```

### Edge Case E13 — Insufficient History

If commit count is **< 10**: output "Insufficient history for statistical metrics" and produce a qualitative-only report. Skip Phases 1 and 3 (no git metrics, no skill trends to aggregate). Use Phase 2 (backlog health) as the sole data source. Still produce Phase 4 actionable items and Phase 5 report.

### Edge Case E14 — Monorepo Detection

Check for monorepo signals in the project root:
- `turbo.json`
- `nx.json`
- `pnpm-workspace.yaml`

If any of these files exist AND no `--path` argument was provided: **stop immediately** and list the detected packages (from `turbo.json` `packages` field, `nx.json` `projects`, or `pnpm-workspace.yaml` `packages`). Ask the user to re-run with `--path <package-dir>`.

If `--path` was provided: scope all `git log` commands with `-- <path>` and note the scope in the report.

---

## Phase 1: Git Metrics

Run these commands against the resolved `<range>` (append `-- <path>` if `--path` was provided).

### Deployment Frequency

Count git tags within the window:
```bash
git tag --sort=-creatordate --merged HEAD | while read tag; do
  git log -1 --format="%ci" "$tag"
done
```
Filter to tags within the window date range. Report as: N releases in period (frequency: 1 per X days/weeks).

### Change Lead Time

Estimate average time from first commit in a branch to the tag date:
```bash
git log --format="%ai %H" <range>
```
Use the earliest commit date in the window as the window start. Use the tag date as the end. Report as: avg N days (branch create → tag). Note: this is an approximation; exact branch creation dates require reflog.

### Churn Hotspots

Find the top 5 most-changed files in the window:
```bash
git log --name-only --pretty=format: <range> | sort | uniq -c | sort -rn | head -5
```
Filter out empty lines. Report as a ranked list: filename (N changes).

---

## Phase 2: Backlog Health

Read `memory/backlog.md` if it exists.

If the file **does not exist**: note "No backlog tracked. Run `zuvo:review` or `zuvo:code-audit` to populate." Skip all backlog metrics.

If the file **exists**, count:
- **Open items** — rows where Status = `OPEN`
- **Critical items** — OPEN rows where Severity = `CRITICAL`
- **Resolved in window** — rows where Status = `RESOLVED` and Added date falls within the window
- **Added in window** — rows where Added date falls within the retrospective window

Also identify the oldest unresolved item (earliest Added date among OPEN rows) and report its ID and age in days.

---

## Phase 3: Skill Usage Trends

Read `~/.zuvo/runs.log` if it exists.

If the file **does not exist**: note "No skill usage history found." Skip this section.

If the file **exists**, parse each line as TSV with this column order:
```
DATE  SKILL  PROJECT  CQ_SCORE  Q_SCORE  VERDICT  TASKS  DURATION  NOTES
```

Filter to entries where:
- `PROJECT` matches the current project directory basename
- `DATE` falls within the retrospective window

From the filtered entries, aggregate:
- **Most-used skills** — rank by frequency
- **Average CQ score** — parse `CQ_SCORE` field, skip `-` entries, average the numerator/denominator separately
- **Average Q score** — same approach as CQ
- **Pass/fail ratio** — count PASS vs FAIL vs WARN verdicts

---

## Phase 4: Actionable Items

Generate **at least 3** specific, actionable items. Each item must:
- Reference a **specific file, directory, or backlog item** (not generic advice)
- Include a **specific zuvo command**
- State the **reason** derived from the data

### Derivation rules (priority order):

1. **High-churn files** — for each file in the churn hotspot list with N ≥ 5 changes: check whether a corresponding test file exists. If no test file found: `zuvo:write-tests <file>` with reason "high-churn, N changes, no test coverage found".
2. **Churn instability** — for files with N ≥ 5 changes that already have tests: `zuvo:refactor <file>` with reason "N changes suggest instability or unclear responsibilities".
3. **Critical backlog items** — for each OPEN CRITICAL item: `zuvo:backlog fix <ID>` with reason "critical debt item open N days".
4. **Old open items** — if oldest open item is > 14 days: `zuvo:backlog prioritize` with reason "oldest item open N days, prioritization overdue".
5. **Low CQ scores** — if average CQ score < 16/22: `zuvo:code-audit <top-churn-directory>` with reason "CQ average N/22 below threshold".
6. **Low Q scores** — if average Q score < 12/17: `zuvo:write-tests <top-churn-directory>` with reason "Q average N/17 suggests test quality gaps".

If fewer than 3 items can be derived from the data, supplement with: "Run `zuvo:code-audit .` to establish a quality baseline" or "Run `zuvo:test-audit .` to identify test gaps."

---

## Phase 5: Report and Output

### Write Report File

Create `audit-results/retro-YYYY-MM-DD.md` (use today's date). If `audit-results/` does not exist, create it.

Use this exact structure:

```markdown
# Engineering Retrospective — YYYY-MM-DD

## Summary
[Tweetable one-liner: period, commits, releases, key metric]

## Shipping Velocity
- **Window:** <range> (<N> days, <N> commits)
- **Deployment frequency:** N releases in period (frequency: 1 per X days)
- **Change lead time:** avg N days (branch create → tag)
- **Commits:** N total, N/day average

## Churn Hotspots
[Top 5 most-changed files with change count. Note if test file was found for each.]

| Rank | File | Changes | Has Tests |
|------|------|---------|-----------|
| 1 | src/orders/service.ts | 12 | No |
| 2 | src/auth/guard.ts | 8 | Yes |

## Backlog Health
- **Open items:** N (N critical, N high)
- **Added this period:** N
- **Resolved this period:** N
- **Oldest unresolved:** [item ID] — open N days

## Quality Trends
- **CQ scores:** avg N/22 ([N runs in period], or "no runs.log data")
- **Q scores:** avg N/17 ([N runs in period], or "no runs.log data")
- **Most-used skills:** [skill1 (N runs), skill2 (N runs)]
- **Pass/fail ratio:** N PASS, N WARN, N FAIL

## Actionable Items
1. `zuvo:write-tests src/orders/` — high-churn (12 changes), no test file found
2. `zuvo:refactor src/auth/guard.ts` — 8 changes suggest instability
3. `zuvo:backlog fix BD-007` — critical debt item open 21 days

## Comparison vs Prior Retro
[Delta table or "First retro — run again next period for trends"]
```

### Prior Retro Comparison

Check for existing `audit-results/retro-*.md` files. If one or more exist, compare with the most recent:

| Metric | Prior | Current | Delta |
|--------|-------|---------|-------|
| Deployment frequency | N/period | N/period | +/-N |
| Avg lead time | N days | N days | +/-N days |
| Open backlog items | N | N | +/-N |
| Avg CQ score | N/22 | N/22 | +/-N |
| Avg Q score | N/17 | N/17 | +/-N |

If no prior retro exists: note "First retro — run again next period for trends."

### Terminal Output Block

Print the RETRO COMPLETE block after writing the report:

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

If E13 (insufficient history) was triggered, show:

```
RETRO COMPLETE [QUALITATIVE ONLY — <10 commits in window]
  Window:      HEAD~30..HEAD (fallback — fewer than 10 commits found)
  Backlog:     +N added, -N resolved, N open (N critical)
  Report:      audit-results/retro-YYYY-MM-DD.md

  Actions:
  1. [derived from backlog only]
```

---

## Phase 6: Run Log

Append to `~/.zuvo/runs.log` per `../../shared/includes/run-logger.md`.

| Field | Value |
|-------|-------|
| SKILL | `retro` |
| CQ_SCORE | `-` (no production code evaluated) |
| Q_SCORE | `-` (no tests evaluated) |
| VERDICT | `PASS` if report written, `WARN` if qualitative-only (E13), `ABORTED` if stopped for monorepo (E14) |
| TASKS | Number of actionable items generated |
| DURATION | `6-phase` or `qualitative` (E13) |
| NOTES | One-line summary, e.g., `v1.1.0..v1.2.0, 47 commits, 3 actions` |
