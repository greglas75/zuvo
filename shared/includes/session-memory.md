# Session Memory Protocol

> Shared include — maintains project context across sessions. Static context lives in the project's `CLAUDE.md`, dynamic state in `memory/project-state.md`. Updated by skills after each run, read on session init.

## Purpose

When Claude Code, Cursor, or Codex restarts, the agent loses all conversation context. This protocol splits project knowledge into two layers:

| Layer | File | Content | Updated |
|-------|------|---------|---------|
| **Static** | `CLAUDE.md` (project) | Tech stack, conventions, architecture decisions | Rarely (on `ship`, `init`, or major changes) |
| **Dynamic** | `memory/project-state.md` | Recent activity, active work, backlog counts | Every skill run |

Static context loads automatically (CLAUDE.md is always injected). Dynamic state is loaded by `hooks/session-start`.

---

## Static Layer: CLAUDE.md Proposals

When a skill detects new **stable project facts**, it proposes additions to the project's `CLAUDE.md` (NOT the plugin's CLAUDE.md). These are facts that won't change between sessions:

### What goes in CLAUDE.md (static)

```markdown
## Tech Stack

| Layer | Technology | Config |
|-------|-----------|--------|
| Language | TypeScript | tsconfig.json |
| Framework | Next.js 14 | next.config.js |
| Database | PostgreSQL | prisma/schema.prisma |
| Testing | Jest + Playwright | jest.config.ts |
| CI/CD | GitHub Actions | .github/workflows/ |
| Package Manager | pnpm | pnpm-lock.yaml |

## Conventions

- Component pattern: function components with arrow syntax
- Styling: Tailwind v4, no inline styles
- API: tRPC for internal, REST for external
- Naming: kebab-case files, PascalCase components

## Key Decisions

| Date | Decision | Why |
|------|----------|-----|
| 2026-04-03 | CSV export (not XLSX) | No binary dependency |
| 2026-04-01 | tRPC for internal APIs | Type safety |
| 2026-03-28 | PostgreSQL over MongoDB | Relational + ACID |
```

### When to propose CLAUDE.md updates

- **First run** (no Tech Stack section in CLAUDE.md): Detect stack, write full section.
- **`ship` skill**: Append Key Decisions accumulated since last release.
- **`architecture` skill**: Update Conventions section if patterns changed.
- **Any skill** detecting a new dependency/tool: Add row to Tech Stack.

**Process**: Read CLAUDE.md → check if section exists → if missing or outdated, append/patch. Never remove existing content. Print: `CLAUDE.md: proposed [section] update` (or `CLAUDE.md: already current`).

---

## Dynamic Layer: memory/project-state.md

Single file, overwritten (not appended) after each skill run. **Max ~80 lines** — only dynamic data.

### Format

```markdown
# Project State

> Auto-maintained by zuvo skills. Last updated: YYYY-MM-DD HH:MM by zuvo:<skill>.

## Recent Activity

| When | Skill | What | Verdict |
|------|-------|------|---------|
| 2026-04-03 14:30 | build | Added user export CSV feature | PASS CQ:19/22 |
| 2026-04-03 11:00 | review | Reviewed auth module (3 files) | WARN — 2 NITs |
| 2026-04-02 16:45 | refactor | Extracted payment logic | PASS CQ:20/22 |
| 2026-04-02 10:00 | brainstorm | Spec: notification redesign | PASS |
| 2026-04-01 15:30 | ship | v1.3.0 → v1.4.0 | PASS |

## Active Work

- **In progress:** [branch name] — [what's being worked on]
- **Pending plan:** [spec path] — [status]
- **Open PR:** #[number] — [title]

## Backlog Summary

| Severity | Count |
|----------|-------|
| high | 3 |
| medium | 7 |
| low | 12 |
| Total | 22 |

Top 3 high-severity:
1. [B-14] order.service.ts — Missing error handling on payment call
2. [B-21] auth.middleware.ts — No rate limiting on login endpoint
3. [B-9] db/migrations/ — Index missing on orders.user_id

## Last Release

- **Version:** 1.4.0
- **Date:** 2026-04-01
- **Branch:** main
```

---

## CodeSift Fingerprint (optional)

When CodeSift is available, use it for faster and cheaper context gathering instead of reading config files:

| Need | CodeSift call | Replaces |
|------|--------------|----------|
| Project structure | `get_file_tree(repo, path_prefix="src")` | `find src -type f` |
| Module map | `detect_communities(repo)` | Manual grep for imports |
| Component inventory | `search_symbols(repo, query="", kind="function", file_pattern="*.tsx")` | Scanning files one by one |
| Complexity hotspots | `analyze_complexity(repo)` | Reading + counting |
| Dependency graph | `get_file_outline(repo, "package.json")` | `cat package.json` |

### CodeSift fingerprint flow (first run only)

CodeSift is only used during the **one-time** Tech Stack detection (when CLAUDE.md has no `## Tech Stack` section yet). Once written to CLAUDE.md, detection never runs again.

```
if CLAUDE.md already has ## Tech Stack:
  SKIP — nothing to detect
else if CodeSift available:
  tree = get_file_tree(repo, path_prefix="src")           # ~50 tokens
  outline = get_file_outline(repo, "package.json")         # ~30 tokens
  communities = detect_communities(repo)                   # ~80 tokens
  → Write Tech Stack + Project Summary to CLAUDE.md
else:
  Fall back to traditional config file reading → write to CLAUDE.md
```

---

## When to Update

Update `memory/project-state.md` at the END of every skill run, after Auto-Docs and before Run Log.

## What Each Skill Updates

### First run on a new project

If `memory/project-state.md` does not exist:

1. **Tech Stack detection** (one-time, then never again):
   - Check if project CLAUDE.md already has `## Tech Stack` → if yes, SKIP detection entirely
   - If no Tech Stack in CLAUDE.md: detect and write it (using CodeSift or config file scanning)
   - This runs **once per project lifetime**, not per session

2. **Initialize project-state.md** with dynamic sections only:
   - Recent Activity: current skill run
   - Active Work: from git branch
   - Backlog Summary: zeros or from backlog.md
   - Last Release: from last-ship.json or "none"

### Subsequent runs (file exists)

**Read the file first.** Then patch only changed sections:

| Section | Updated by | How |
|---------|-----------|-----|
| Recent Activity | ALL skills | Prepend entry, keep max 5, drop oldest |
| Active Work | build, execute, plan, brainstorm | Update branch/PR/spec info |
| Backlog Summary | Skills that write to backlog | Recount from `memory/backlog.md` |
| Last Release | ship only | Overwrite from `memory/last-ship.json` |

### CLAUDE.md updates (static, rare)

| Section | Updated by | Trigger |
|---------|-----------|---------|
| Tech Stack | Any skill | New dependency/tool detected |
| Conventions | architecture, design | Pattern change |
| Key Decisions | brainstorm, plan, architecture, ship | New architectural decision |

### Update rules

- **Recent Activity**: Max 5 entries. Newest at top. One entry per skill run.
- **Active Work**: From `git branch --show-current` + `git log --oneline -1`. Clear completed items.
- **Backlog Summary**: Count from `memory/backlog.md`. Top 3 high-severity with IDs.
- **Last Release**: From `memory/last-ship.json`. Version, date, branch.
- **Key Decisions** (CLAUDE.md): Only architectural/technology choices. Max 10, drop oldest.

## Execution Steps

### Step 1: Check files

```
if memory/project-state.md exists:
  READ it → use as base for patching
else:
  if CLAUDE.md has NO ## Tech Stack section:
    Detect stack (one-time) → write to CLAUDE.md
  Initialize project-state.md with dynamic sections only
```

### Step 2: Update dynamic state

Based on the current skill and its output, update only relevant sections of `memory/project-state.md`.

### Step 3: Check CLAUDE.md (if applicable)

If current skill detected new static facts (new dependency, new decision, new convention):
- Read project CLAUDE.md
- Propose addition (append, never remove)
- Print: `CLAUDE.md: updated [section]` or `CLAUDE.md: already current`

### Step 4: Write and confirm

Overwrite `memory/project-state.md`. Print:

```
SESSION-MEMORY: project-state.md updated (N lines)
```

If update fails, log warning and proceed to Run Log.

## Reading on Session Start

`hooks/session-start` reads `memory/project-state.md` (if it exists) and injects alongside the routing table. Combined with CLAUDE.md (auto-injected), every new session gets:

1. **Static context** (CLAUDE.md): tech stack, conventions, decisions
2. **Dynamic state** (project-state.md): recent activity, active work, backlog
3. **Routing table**: available skills

## Error Handling

- **File write fails**: Log warning, proceed to Run Log.
- **Backlog missing**: Set counts to 0.
- **No git**: Skip Active Work branch detection.
- **File corrupted**: Recreate from scratch.
- **CLAUDE.md not writable**: Skip static update, log warning.

## What NOT to Do

- Do not include code snippets, file contents, or sensitive data.
- Do not duplicate static info (Tech Stack, Decisions) in project-state.md — it belongs in CLAUDE.md.
- Do not block skill completion if session memory update fails.
- Do not exceed 80 lines in project-state.md.
- Do not modify the plugin's CLAUDE.md — only the project's CLAUDE.md.
