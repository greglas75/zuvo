# Session Memory Protocol

> Shared include — maintains `memory/project-state.md` so that every new session starts with full project context. Updated by skills after each run, read by `hooks/session-start` on session init.

## Purpose

When Claude Code, Cursor, or Codex restarts, the agent loses all conversation context. This protocol persists a **project state snapshot** to disk so the next session can restore it instantly.

## File: `memory/project-state.md`

Single file, overwritten (not appended) after each skill run. Max ~200 lines.

### Format

```markdown
# Project State

> Auto-maintained by zuvo skills. Last updated: YYYY-MM-DD HH:MM by zuvo:<skill>.

## Tech Stack

| Layer | Technology | Config file |
|-------|-----------|-------------|
| Language | TypeScript | tsconfig.json |
| Framework | Next.js 14 | next.config.js |
| Database | PostgreSQL | prisma/schema.prisma |
| Testing | Jest + Playwright | jest.config.ts, playwright.config.ts |
| CI/CD | GitHub Actions | .github/workflows/ |
| Package Manager | pnpm | pnpm-lock.yaml |

## Project Summary

<2-3 sentences describing what this project is and does>

## Recent Activity

| When | Skill | What | Verdict |
|------|-------|------|---------|
| 2026-04-03 14:30 | build | Added user export CSV feature | PASS CQ:19/22 |
| 2026-04-03 11:00 | review | Reviewed auth module (3 files) | WARN — 2 NITs |
| 2026-04-02 16:45 | refactor | Extracted payment logic from OrderService | PASS CQ:20/22 |
| 2026-04-02 10:00 | brainstorm | Spec: notification system redesign | PASS |
| 2026-04-01 15:30 | ship | v1.3.0 → v1.4.0, direct flow | PASS |

## Active Work

- **In progress:** [branch name] — [what's being worked on]
- **Pending plan:** [spec path] — [status: Approved/Reviewed]
- **Open PR:** #[number] — [title] (if known)

## Backlog Summary

| Severity | Count |
|----------|-------|
| high | 3 |
| medium | 7 |
| low | 12 |
| Total open | 22 |

Top 3 high-severity items:
1. [B-14] order.service.ts — Missing error handling on payment call (CQ8)
2. [B-21] auth.middleware.ts — No rate limiting on login endpoint (Security)
3. [B-9] db/migrations/ — Index missing on orders.user_id (Performance)

## Key Decisions

| Date | Decision | Context |
|------|----------|---------|
| 2026-04-03 | Use CSV for export (not XLSX) | Simpler, no binary dependency |
| 2026-04-01 | Migrate from REST to tRPC for internal APIs | Type safety, less boilerplate |
| 2026-03-28 | PostgreSQL over MongoDB | Relational data, ACID transactions needed |

## Last Release

- **Version:** 1.4.0 (tag: v1.4.0)
- **Date:** 2026-04-01
- **Branch:** main
- **Review depth:** full
```

## When to Update

Update `memory/project-state.md` at the END of every skill run, after Auto-Docs and before Run Log. This is the LAST write operation before logging.

## What Each Skill Updates

### First run on a new project (file doesn't exist)

If `memory/project-state.md` does not exist, the current skill MUST create it by:

1. **Tech Stack detection** (one-time, then cached):
   - Scan project root for config files: `package.json`, `tsconfig.json`, `pyproject.toml`, `Cargo.toml`, `go.mod`, `composer.json`, `Gemfile`, `pom.xml`, `build.gradle`
   - Detect framework from config: Next.js, Django, Rails, FastAPI, Express, Spring, etc.
   - Detect test framework: Jest, Vitest, pytest, go test, RSpec, JUnit, etc.
   - Detect CI: `.github/workflows/`, `.gitlab-ci.yml`, `Jenkinsfile`, etc.
   - Detect package manager: npm/pnpm/yarn/bun/pip/poetry/cargo/go/composer
   - Detect database from config/schema files

2. **Project Summary**: Read README.md (first 50 lines) or main config file. Write 2-3 sentence description.

3. **Initialize all sections** with current data (or "none" if empty).

### Subsequent runs (file exists)

**Read the file first.** Then patch only the sections that changed:

| Section | Updated by | How |
|---------|-----------|-----|
| Tech Stack | Any skill (if new dependency detected) | Add row, don't remove existing |
| Project Summary | Only if empty or obviously wrong | Patch, not rewrite |
| Recent Activity | ALL skills | Prepend new entry, keep max 5, drop oldest |
| Active Work | build, execute, plan, brainstorm | Update branch/PR/spec info |
| Backlog Summary | Skills that write to backlog | Recount from `memory/backlog.md` |
| Key Decisions | brainstorm, plan, architecture | Append new decision, keep max 10 |
| Last Release | ship only | Overwrite from `memory/last-ship.json` |

### Update rules

- **Recent Activity**: Maximum 5 entries. Newest at top. One entry per skill run. Format: `| YYYY-MM-DD HH:MM | skill | one-line summary | verdict + score |`
- **Active Work**: Detect from `git branch --show-current`, `git log --oneline -1`, check for open specs in `docs/specs/`. Clear completed items.
- **Backlog Summary**: Count rows in `memory/backlog.md` grouped by severity. List top 3 high-severity items with their IDs.
- **Key Decisions**: Only add genuinely new decisions (architectural, technology, design choices). Skip implementation details. Max 10 entries, drop oldest when exceeded.
- **Last Release**: Copy from `memory/last-ship.json` if it exists. Show version, date, branch, review depth.

## Execution Steps

### Step 1: Check if file exists

```
if memory/project-state.md exists:
  READ it → use as base for patching
else:
  Run full Tech Stack detection + Project Summary
  Initialize all sections from scratch
```

### Step 2: Update applicable sections

Based on the current skill and its completion data, update only the relevant sections (see table above).

### Step 3: Write the file

Overwrite `memory/project-state.md` with the updated content. This is NOT append — it's a full rewrite of the state snapshot.

### Step 4: Print confirmation

```
SESSION-MEMORY: project-state.md updated
```

One line. If update fails, log warning and proceed to Run Log.

## Reading on Session Start

The `hooks/session-start` script reads `memory/project-state.md` (if it exists) and injects its content alongside the skill routing table. This gives every new session:

1. **Routing table** (what skills are available — existing)
2. **Project context** (what this project is, what's been happening — NEW)

If the file doesn't exist (first ever skill run), session starts without project context. The first skill run will create it.

## Error Handling

- **File write fails**: Log `SESSION-MEMORY: could not update project-state.md — <reason>`. Proceed to Run Log.
- **Backlog file missing**: Set all counts to 0, note "backlog not initialized".
- **No git available**: Skip Active Work branch detection, note "git unavailable".
- **File corrupted**: Recreate from scratch (full Tech Stack detection).

## What NOT to Do

- Do not include code snippets, file contents, or sensitive data.
- Do not include full backlog — only summary counts and top 3 high-severity.
- Do not include full project-journal — only last 5 entries in Recent Activity.
- Do not block skill completion if session memory update fails.
- Do not update Tech Stack on every run — only add new discoveries, never remove.
- Do not exceed 200 lines in project-state.md. Keep it concise.
