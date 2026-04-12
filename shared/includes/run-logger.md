# Run Logger

> Shared include — referenced by all skills that log their execution.

## When to Log

Log at the END of every skill run, after all work is done. One line per run.

## Log File

Use an environment-aware log path:

- Claude Code: `~/.zuvo/runs.log`
- Codex CLI (local): `~/.zuvo/runs.log`
- Codex App (cloud): `memory/zuvo-runs.log`

Detection:

```bash
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null || ! test -w ~/.zuvo; then
  LOG_PATH="memory/zuvo-runs.log"
else
  LOG_PATH="$HOME/.zuvo/runs.log"
fi
```

## Field Resolution

Resolve these values before composing the log line:

```bash
# PROJECT — worktree-safe, falls back to pwd for non-git directories
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# BRANCH — current git branch, or - if not in a git repo
BRANCH=$(git branch --show-current 2>/dev/null || echo "-")

# HEAD_SHA7 — short commit hash, or - if not in a git repo
HEAD_SHA7=$(git rev-parse --short HEAD 2>/dev/null || echo "-")

# DATE — UTC ISO 8601 with Z suffix
DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
```

## Format

Single-line TSV (tab-separated), 13 fields per entry:

```
DATE\tSKILL\tPROJECT\tCQ_SCORE\tQ_SCORE\tVERDICT\tTASKS\tDURATION\tNOTES\tBRANCH\tHEAD_SHA7\tINCLUDES\tTIER
```

| # | Field | Value | Example |
|---|-------|-------|---------|
| 1 | DATE | ISO 8601 UTC with Z suffix | `2026-04-05T18:45:00Z` |
| 2 | SKILL | Skill name without `zuvo:` prefix | `build` |
| 3 | PROJECT | Git root directory basename (see Field Resolution) | `tgm-survey-platform` |
| 4 | CQ_SCORE | `N/28`, `N-critical` (audits), or `-` | `22/28` |
| 5 | Q_SCORE | `N/19`, `N-total` (audits), or `-` | `16/19` |
| 6 | VERDICT | `PASS`, `WARN`, `FAIL`, `BLOCKED`, or `ABORTED` only | `PASS` |
| 7 | TASKS | Number of tasks completed, or `-` | `4` |
| 8 | DURATION | `N-phase`, `N-tasks`, `tier-N`, or skill-specific label | `standard` |
| 9 | NOTES | One-line summary, max 80 chars, no tabs | `added user export CSV` |
| 10 | BRANCH | Current git branch (see Field Resolution) | `main` |
| 11 | HEAD_SHA7 | Short commit hash (see Field Resolution) | `a3f7b2c` |
| 12 | INCLUDES | Pipe-separated list of loaded includes/rules (without `.md` suffix), or `-` | `env-compat\|cq-patterns\|testing` |
| 13 | TIER | Classification tier used by the skill, or `-` | `STANDARD` |

**Field 12 — INCLUDES:** List every `shared/includes/*.md` and `rules/*.md` file that was actually Read during this skill run. Use basenames without `.md`, separated by `|`. Order does not matter. If no includes were loaded, use `-`.

**Field 13 — TIER:** The classification tier the skill resolved to. Common values: `LIGHT`, `STANDARD`, `DEEP`, `NANO`, `HEAVY`, `COMPONENT`, `THIN`, `COMPLEX`. If the skill does not use tiering, use `-`.

**Backward compatibility:** Fields 1-9 are unchanged from v1. Existing `cut -f1-9` queries continue to work. Fields 10-11 added in v2. Fields 12-13 added in v3.

## Log-in-Output Pattern

**Do NOT use a trailing `## Run Log` section.** Instead, embed the log line as a required field inside the skill's named output block.

### How it works

Each skill has a named output block (e.g., `BUILD COMPLETE`, `REVIEW COMPLETE`). The `Run:` line is a mandatory field inside that block — the block is not complete without it.

### Example (build skill)

```markdown
## BUILD COMPLETE

Feature: user export to CSV
Tier: STANDARD | Files: 3 created + 2 modified
CQ: 22/28 | Q: 15/19
Verdict: PASS
Run: 2026-04-05T14:30:00Z	build	zuvo-plugin	22/28	15/19	PASS	4	standard	user export CSV	main	a3f7b2c	env-compat|codesift-setup|cq-patterns|testing|code-contract|quality-gates	STANDARD

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved above.
```

### Audit skill example (TASKS=`-`, NOT skipped)

Audits don't produce tasks — **TASKS field must be `-`**, not omitted. Never merge TASKS into DURATION.

```
Run: 2026-04-11T14:00:00Z	db-audit	tgm-survey-platform	0-critical	14-total	WARN	-	13-dimensions	delta refresh partial M1 fix	chore/audit-fixes	cc12109	codesift-setup|env-compat|cq-patterns|quality-gates|knowledge-prime	-
```

Field-by-field (tab-separated):
1. `2026-04-11T14:00:00Z` — DATE
2. `db-audit` — SKILL
3. `tgm-survey-platform` — PROJECT
4. `0-critical` — CQ (audit format)
5. `14-total` — Q (audit format)
6. `WARN` — VERDICT
7. **`-`** — TASKS (audit has no tasks → use `-`, do NOT skip)
8. `13-dimensions` — DURATION (audit-specific label)
9. `delta refresh partial M1 fix` — NOTES
10. `chore/audit-fixes` — BRANCH
11. `cc12109` — HEAD_SHA7
12. `codesift-setup|env-compat|cq-patterns|quality-gates|knowledge-prime` — INCLUDES
13. `-` — TIER (audit has no tier → use `-`)

**Critical:** Always emit all 13 fields. If a field has no value, write `-`. Never skip a field — tab count must be exactly 12.

### Template format

Each skill's SKILL.md includes a literal template with placeholders:

```
Run: <ISO-8601-Z>\t<skill>\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>\t<INCLUDES>\t<TIER>
```

The LLM fills in the placeholders when generating the output block, then appends the resulting line to the log file.

**Filling INCLUDES:** A PostToolUse hook (`hooks/track-includes.sh`) automatically tracks every `shared/includes/*.md` and `rules/*.md` file Read during the session. To get the list, run:

```bash
INCLUDES=$(sort -u /tmp/zuvo-includes-*.txt 2>/dev/null | paste -sd'|' - || echo "-")
```

If the hook file doesn't exist (e.g., Codex/Cursor without hooks), fall back to manually listing the includes you loaded. Use basenames without `.md`, pipe-separated. Example: `env-compat|cq-patterns-core|testing|quality-gates`. If none, use `-`.

**Filling TIER:** Use the tier/classification you resolved in Phase 0 or Phase 1 (e.g., `LIGHT`, `STANDARD`, `DEEP`). If the skill has no tiering, use `-`.

## VERDICT Vocabulary

Only these 5 values are valid. Skills with non-standard internal vocabularies must map to these:

| Standard | Meaning |
|----------|---------|
| `PASS` | Skill completed successfully |
| `WARN` | Completed with non-critical issues |
| `FAIL` | Critical issues found or skill failed |
| `BLOCKED` | Could not proceed due to hard blocker |
| `ABORTED` | User cancelled or skill rejected |

## What NOT to Log

- Do not log failed skill invocations (wrong skill routed, user cancelled immediately)
- Do not log partial runs where no work was done
- Do not include file paths, code snippets, or sensitive data in NOTES
- Do not send data anywhere — this is a local file only

## Context Metrics Collection

After appending the Run: line, collect context metrics by running:

```bash
bash "${CLAUDE_PLUGIN_ROOT:-$(dirname "$(dirname "$(dirname "$0")")")}/hooks/collect-context-metrics.sh" "<SKILL>" "<PROJECT>" "<TIER>"
```

This reads the session include log (from `track-includes.sh` hook), calculates cumulative file sizes, and appends a metrics line to `~/.zuvo/context-metrics.log`. The metrics file enables trend tracking via `zuvo:context-audit`.

If `collect-context-metrics.sh` is not found, skip silently — metrics collection is optional.

## Reading the Log

Resolve the log path first (same logic as writing), then query:

```bash
# Last 20 runs
tail -20 "$LOG_PATH"

# Runs for a specific project
grep "tgm-survey" "$LOG_PATH"

# Only failures
grep "FAIL" "$LOG_PATH"

# CQ scores over time for build
grep "build" "$LOG_PATH" | cut -f4

# Branch distribution
grep "zuvo-plugin" "$LOG_PATH" | cut -f10 | sort | uniq -c | sort -rn

# Include loading frequency (v3 field 12)
cut -f12 "$LOG_PATH" | tr '|' '\n' | sort | uniq -c | sort -rn

# Tier distribution per skill (v3 field 13)
awk -F'\t' '{print $2, $13}' "$LOG_PATH" | sort | uniq -c | sort -rn

# Which includes does review actually load?
grep "^.*review" "$LOG_PATH" | cut -f12 | tr '|' '\n' | sort | uniq -c | sort -rn
```
