# Run Logger v2 — Design Specification

> **spec_id:** 2026-04-05-run-logger-v2-1845
> **topic:** Run Logger compliance fix + cross-repo tracking
> **status:** Approved
> **created_at:** 2026-04-05T18:45:00Z
> **approved_at:** 2026-04-05T19:30:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

The zuvo run-logger system captures skill execution data to `~/.zuvo/runs.log` for retrospective analysis via `zuvo:retro`. Currently it is broken:

- **82% data loss**: Only 9 entries logged from 50+ actual skill invocations (confirmed via conversation search across 10+ repos)
- **24 of 39 skills have no Run Log section** — they never log regardless of LLM compliance
- **LLM skips logging**: Even skills WITH Run Log sections produce entries ~30% of the time. Root cause: the `## Run Log` section sits at 95-98% position in the SKILL.md file, after the output block. The LLM treats it as an appendix after completing the "real" output
- **Format inconsistency**: 4 of 9 existing entries use pipe-delimited format instead of TSV — invisible to `zuvo:retro`'s `cut -f` parser
- **No cross-repo context**: PROJECT field uses `pwd | basename`, which breaks in worktrees and can't distinguish repos with the same directory name
- **Path resolution bug**: `mkdir -p ~/.zuvo` succeeds even if the directory is not writable, causing silent log failures

If we do nothing: `zuvo:retro` quality trends remain meaningless, cross-project analytics are impossible, and skill usage data — the primary feedback loop for plugin improvement — stays at ~18% capture rate.

## Design Decisions

### D1: Log-in-Output pattern (not trailing section)

**Chosen:** Embed the TSV log line as a required field inside each skill's named output block (e.g., `BUILD COMPLETE`). The LLM generates it as part of the output, then copies it to the log file.

**Rejected:** Keeping `## Run Log` as a trailing section (compliance stays at ~30%). Also rejected: router-level fallback in `using-zuvo` (no post-skill hook mechanism exists; router doesn't know skill-specific field values).

**Why:** Research on LLM instruction compliance (Liu et al. 2024 "Lost in the Middle", AGENTIF benchmark 2025) confirms that fill-in-the-blank templates inside output blocks have ~3x higher compliance than prose instructions in trailing sections. The LLM is still in "generating output" mode when it encounters the template.

### D2: TSV with backward-compatible field extension (9→11)

**Chosen:** Keep TSV format, append two new fields (BRANCH, HEAD_SHA7) at positions 10-11. Existing `cut -f1-9` queries continue to work.

**Rejected:** JSONL (higher LLM generation error rate for JSON vs TSV). Also rejected: full 12-field schema with SESSION_ID (deferred — pipeline linking achievable via NOTES grep on spec topic; will revisit when `$CLAUDE_SESSION_ID` becomes available in Claude Code env).

### D3: Per-skill templates (not centralized logging)

**Chosen:** Each skill has a literal TSV template line with named placeholders inside its output block. 37 skills log (excluding `using-zuvo` and `worktree`).

**Rejected:** Centralized post-skill hook in `using-zuvo` (no such mechanism exists; would require runtime, which this markdown-only plugin doesn't have).

### D4: Standardized VERDICT vocabulary

**Chosen:** Five values only: `PASS`, `WARN`, `FAIL`, `BLOCKED`, `ABORTED`. Each skill maps its outcomes to these.

**Rejected:** Skill-specific vocabularies like `HEALTHY`/`AT RISK`/`CRITICAL` (breaks retro aggregation, confuses cross-skill analysis).

## Solution Overview

```
┌─────────────────────────────────────────────┐
│  run-logger.md (shared include)             │
│  - 11-field TSV schema                      │
│  - Path resolution (with write-test fix)    │
│  - PROJECT from git worktree root           │
│  - BRANCH + HEAD_SHA7 resolution            │
│  - "Log-in-Output" pattern instructions     │
└──────────────┬──────────────────────────────┘
               │ referenced by
    ┌──────────┼──────────────────┐
    ▼          ▼                  ▼
┌────────┐ ┌────────┐      ┌──────────┐
│ 15     │ │ 22     │      │ retro    │
│ skills │ │ skills │      │ (reader) │
│ UPDATE │ │ ADD    │      │ UPDATE   │
│ pattern│ │ pattern│      │ parser   │
└────────┘ └────────┘      └──────────┘
```

**Change 1 — `run-logger.md`:** New 11-field schema, fixed path resolution, Log-in-Output pattern documentation.

**Change 2 — 15 existing skills (UPDATE):** Remove trailing `## Run Log` sections, add `Run:` template line to output blocks, standardize VERDICT values, add `run-logger.md` to mandatory file loading for the 10 that don't already list it, update PROJECT resolution from `pwd | basename` to `git rev-parse --show-toplevel`.

Skills: brainstorm, build, canary, code-audit, debug, deploy, execute, plan, refactor, release-docs, retro, review, security-audit, ship, test-audit.

**Change 3 — 22 new skills (ADD):** Add `run-logger.md` to mandatory file loading, add `Run:` template to output blocks with category-specific mappings.

Skills: api-audit, architecture, backlog, ci-audit, db-audit, dependency-audit, design, design-review, docs, env-audit, fix-tests, pentest, performance-audit, presentation, receive-review, seo-audit, seo-fix, structure-audit, tests-performance, ui-design-team, write-e2e, write-tests.

**Change 4 — `retro` skill (PARSER + OWN LOG):** Update Phase 3 parser to handle 11-field and 9-field entries (split by tab count; lines with <10 tabs treat BRANCH/HEAD_SHA7 as `-`). Display branch distribution in Quality Trends when any 11-field entries exist in the filtered window (e.g., `main: 8 runs, feature/x: 2 runs`). Also: remove retro's standalone Phase 6 Run Log section, embed `Run:` template in RETRO COMPLETE output block (retro is itself one of the 15 existing skills being updated).

## Detailed Design

### Data Model — TSV Schema v2

```
DATE\tSKILL\tPROJECT\tCQ_SCORE\tQ_SCORE\tVERDICT\tTASKS\tDURATION\tNOTES\tBRANCH\tHEAD_SHA7
```

| # | Field | Type | Resolution | Example |
|---|-------|------|------------|---------|
| 1 | DATE | ISO 8601 + Z | `date -u +%Y-%m-%dT%H:%M:%SZ` | `2026-04-05T18:45:00Z` |
| 2 | SKILL | string | Skill name without `zuvo:` prefix | `build` |
| 3 | PROJECT | string | `basename "$(git rev-parse --show-toplevel 2>/dev/null \|\| pwd)"` | `tgm-survey-platform` |
| 4 | CQ_SCORE | string | `N/28`, `N-critical` (audits), or `-` | `22/28` |
| 5 | Q_SCORE | string | `N/19`, `N-total` (audits), or `-` | `16/19` |
| 6 | VERDICT | enum | `PASS\|WARN\|FAIL\|BLOCKED\|ABORTED` only | `PASS` |
| 7 | TASKS | string | Count of completed tasks, or `-` | `4` |
| 8 | DURATION | string | `N-phase`, `N-tasks`, `tier-N`, or skill label | `standard` |
| 9 | NOTES | string | Max 80 chars, no tabs | `added user export CSV` |
| 10 | BRANCH | string | `git branch --show-current 2>/dev/null \|\| echo "-"` | `main` |
| 11 | HEAD_SHA7 | string | `git rev-parse --short HEAD 2>/dev/null \|\| echo "-"` | `a3f7b2c` |

### Path Resolution (updated)

```bash
# Step 1: Determine log file path
if [ -n "$CODEX_WORKSPACE" ] || ! mkdir -p ~/.zuvo 2>/dev/null || ! test -w ~/.zuvo; then
  LOG_PATH="memory/zuvo-runs.log"
else
  LOG_PATH="$HOME/.zuvo/runs.log"
fi

# Step 2: Resolve PROJECT from git root (worktree-safe)
PROJECT=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || pwd)")

# Step 3: Resolve new fields
BRANCH=$(git branch --show-current 2>/dev/null || echo "-")
HEAD_SHA7=$(git rev-parse --short HEAD 2>/dev/null || echo "-")
```

### Log-in-Output Pattern

Each skill's named output block includes a `Run:` line as a required field. Example for `build`:

```markdown
## BUILD COMPLETE

Feature: [description]
Tier: [LIGHT / STANDARD / DEEP]
Files: [N created] + [N modified]
CQ: [score/28] | Q: [score/19]
Verdict: [PASS/WARN/FAIL]
Run: <ISO-8601>\tbuild\t<project>\t<CQ>\t<Q>\t<VERDICT>\t<TASKS>\t<DURATION>\t<NOTES>\t<BRANCH>\t<SHA7>

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.
```

The `Run:` line is a **mandatory field** — the output block is not complete without it.

### Skill Categories and Field Mappings

**Pipeline skills** (brainstorm, plan, execute):
- CQ_SCORE: `-`
- Q_SCORE: `-`
- TASKS: `-` (brainstorm/plan) or completed count (execute)
- DURATION: `3-phase` (brainstorm/plan) or `N-tasks` (execute)

**Core skills** (build, review, refactor, debug):
- CQ_SCORE: `N/28` if evaluated, `critical-only` for light tier, `-` if not applicable
- Q_SCORE: `N/19` if evaluated, `-` if not applicable
- TASKS: count or `-`
- DURATION: tier or phase label

**Audit skills** (11 skills: api-audit, code-audit, test-audit, pentest, performance-audit, db-audit, dependency-audit, ci-audit, env-audit, structure-audit, seo-audit):
- CQ_SCORE: `N-critical` (number of critical findings)
- Q_SCORE: `N-total` (total findings count)
- VERDICT: `PASS` (0 critical), `WARN` (1-3 critical), `FAIL` (4+ critical)
- TASKS: `-`
- DURATION: `N-dimensions`

**Security-audit** (special case — uses percentage-based health grade, not finding counts):
- CQ_SCORE: `-` (security-audit uses S-dimension scores, not CQ checklist)
- Q_SCORE: `-`
- VERDICT: `PASS` (HEALTHY), `WARN` (NEEDS ATTENTION), `FAIL` (AT RISK or CRITICAL)
- TASKS: `-`
- DURATION: `N-dimensions`

**Test skills** (write-tests, write-e2e, fix-tests, tests-performance):
- CQ_SCORE: `-`
- Q_SCORE: `N/19` if Q self-eval ran
- TASKS: count of test files written/fixed
- DURATION: skill-specific

**Release skills** (ship, deploy, release-docs, retro):
- CQ_SCORE: `-`
- Q_SCORE: `-`
- TASKS: `-`
- DURATION: `N-phase` (ship: `5-phase`, deploy: `7-phase`, release-docs: `5-phase`, retro: `6-phase`)

**Canary** (special case — timed monitoring, not phased):
- CQ_SCORE: `-`
- Q_SCORE: `-`
- VERDICT: `PASS` (HEALTHY), `WARN` (DEGRADED), `FAIL` (BROKEN)
- TASKS: `-`
- DURATION: resolved monitoring duration (e.g., `one-shot`, `10m`, `30m`)

**Deploy VERDICT mapping:** `PASS` (success), `WARN` (PARTIAL — partial deployment), `FAIL` (failed), `ABORTED` (cancelled before completion)

**Utility skills** (docs, presentation, backlog, design, design-review, ui-design-team, architecture, receive-review, seo-fix):
- CQ_SCORE: `-`
- Q_SCORE: `-`
- TASKS: `-` or count if applicable
- DURATION: skill-specific label

### Integration Points

**`shared/includes/run-logger.md`** — single source of truth for:
- TSV schema definition (11 fields)
- Path resolution logic
- PROJECT / BRANCH / HEAD_SHA7 resolution
- "Log-in-Output" pattern description and example

**37 SKILL.md files** — each references `run-logger.md` in mandatory file loading and embeds a `Run:` template in its output block.

**`skills/retro/SKILL.md`** Phase 3 — updated to:
- Parse 11-field lines (using fields 10-11 when present)
- Fall back gracefully on 9-field lines (BRANCH and HEAD_SHA7 treated as `-`)
- Optionally display branch distribution in Quality Trends

### Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Skill aborted mid-run | Not logged (existing behavior). Deferred: future abort-detection would require defining "minimum work threshold" per skill |
| Skill in worktree | PROJECT resolved from `git rev-parse --show-toplevel`, not `pwd`. Worktree and main tree produce same PROJECT value |
| Codex App (no `~/.zuvo/`) | Falls back to `memory/zuvo-runs.log` (existing behavior, now with write-test fix) |
| `~/.zuvo/` not writable | `test -w` detects this, falls back to project-local path |
| Pipeline chain | No SESSION_ID field (deferred). Chain reconstructable via NOTES content + timestamp proximity |
| Old 9-field entries | Retro handles gracefully — missing fields 10-11 treated as `-` |
| Not in a git repo | PROJECT = `basename $(pwd)`, BRANCH = `-`, HEAD_SHA7 = `-` |
| runs.log doesn't exist | Bash `>>` creates it; Write tool should create if missing |
| Concurrent writes | Atomic for small writes via `>>` on Unix. Document as known limitation for Write-tool path |
| Mixed DATE formats | Old entries may lack `Z` suffix; retro parses both `T...` and `T...Z` as UTC |

## Acceptance Criteria

1. **AC1 — Schema**: `run-logger.md` defines an 11-field TSV schema with BRANCH and HEAD_SHA7 as fields 10-11
2. **AC2 — Path fix**: Path resolution includes `test -w ~/.zuvo` and PROJECT uses `git rev-parse --show-toplevel`
3. **AC3 — 37 skills log**: Every skill except `using-zuvo` and `worktree` has a `Run:` template in its output block and `run-logger.md` in its mandatory file loading
4. **AC4 — VERDICT standardized**: All skills use only `PASS|WARN|FAIL|BLOCKED|ABORTED`
5. **AC5 — No trailing sections**: No skill has a standalone `## Run Log` section — all logging is via the Log-in-Output pattern
6. **AC6 — Retro updated**: `zuvo:retro` Phase 3 parses each line by tab count: lines with <10 tabs (9-field) treat BRANCH and HEAD_SHA7 as `-`; lines with 10 tabs (11-field) populate all fields. Quality Trends section appends a `Branch distribution:` line (e.g., `main: 8 runs, feature/x: 2 runs`) when at least one 11-field entry exists in the filtered window. Retro's own Phase 6 Run Log section is replaced by a `Run:` template in its RETRO COMPLETE output block
7. **AC7 — Backward compatible**: `cut -f1-9` on new entries yields the same 9-field structure as old format. Note: DATE format standardizes to Z-suffix (UTC); retro's date parser must handle both `T...` and `T...Z` formats. Old entries remain parseable

## Out of Scope

- **SESSION_ID / pipeline linking field** — deferred until `$CLAUDE_SESSION_ID` available or explicit need emerges
- **Migration of 4 existing pipe-delimited entries** — legacy data, retro already skips them
- **Dashboard or analytics UI** — runs.log remains a local file, queried via shell
- **Abort detection** — mid-run logging requires per-skill "minimum work threshold" definitions
- **JSONL format migration** — TSV confirmed as better fit for LLM generation
- **Codex App log aggregation** — cloud `memory/zuvo-runs.log` remains per-project

## Open Questions

None — all design questions resolved during Phase 2 dialogue.
