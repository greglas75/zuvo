# Auto-Docs Protocol

> Shared include — referenced by skills that modify code or produce artifacts. Updates project documentation automatically after skill completion.

## When to Run

Run AFTER the skill's main work is done and output block is printed, but BEFORE the Run Log entry. This is a **non-blocking** step — if it fails, log a warning and proceed to Run Log.

## Documentation Targets

Auto-docs updates these files based on the invoking skill:

| File | Updated by | Purpose |
|------|-----------|---------|
| `docs/project-journal.md` | ALL skills below | Chronological log of all significant changes |
| `docs/architecture.md` | brainstorm, plan, execute, build, refactor | Component map, data flow, key decisions |
| `docs/api-changelog.md` | build, execute, refactor, review (FIX mode) | API surface changes (endpoints, contracts, schemas) |
| `README.md` | ship | Version badge, install instructions, feature list |
| `CHANGELOG.md` | ship (if not already updated by ship itself) | Formal changelog |

## Skill → Update Matrix

| Skill | project-journal | architecture | api-changelog | README | CHANGELOG |
|-------|:-:|:-:|:-:|:-:|:-:|
| brainstorm | ✓ decision | ✓ if structural | — | — | — |
| plan | ✓ plan approved | ✓ if new components | — | — | — |
| execute | ✓ per task | ✓ if structural | ✓ if API changed | — | — |
| build | ✓ feature | ✓ if new component | ✓ if API changed | — | — |
| refactor | ✓ refactoring | ✓ if structure changed | ✓ if API changed | — | — |
| review | ✓ only in FIX mode | — | ✓ if API fix | — | — |
| ship | ✓ release | — | — | ✓ | ✓ (if missing) |

## Detection Rules

### "If structural" — update architecture.md when:
- New directory or module created
- File moved between directories
- New service/controller/model introduced
- Dependency between modules added or removed
- Database schema changed

### "If API changed" — update api-changelog.md when:
- New endpoint added
- Endpoint removed or path changed
- Request/response schema modified
- Authentication/authorization changed
- Status codes or error shapes modified

### "If new component" — update architecture.md when:
- New top-level directory in src/
- New service, controller, or module file created
- New database table or migration

## File Formats

### docs/project-journal.md

Append-only log. Each entry is a section. Create the file if it doesn't exist.

```markdown
# Project Journal

Automatic log of project changes maintained by zuvo skills.

---

## YYYY-MM-DD HH:MM — zuvo:<skill> — <one-line summary>

**Type:** feature | refactoring | bugfix | decision | plan | release
**Scope:** <files or components affected>
**Details:**
- <bullet point 1>
- <bullet point 2>

**Quality:** CQ: <score> | Q: <score> | Verdict: <verdict>
[only if scores available, omit line if all dashes]

---
```

Rules:
- One entry per skill run (not per file, not per task)
- For `execute`: one entry per completed task (tasks are significant units)
- Max 5 bullet points in Details
- Scope lists files OR component names, not both (prefer component names for >3 files)
- Newest entries at the TOP (prepend after the H1 + intro line)

### docs/architecture.md

Maintained document (not append-only). Create with scaffold if it doesn't exist.

```markdown
# Architecture

> Auto-maintained by zuvo skills. Last updated: YYYY-MM-DD.

## Overview

<1-3 sentences describing the project>

## Components

| Component | Path | Responsibility |
|-----------|------|---------------|
| <name> | <path> | <one-line> |

## Data Flow

<describe how data moves through the system — request lifecycle, event flow, etc.>

## Key Decisions

| Date | Decision | Rationale | Skill |
|------|----------|-----------|-------|
| YYYY-MM-DD | <what was decided> | <why> | zuvo:<skill> |

## Dependencies

| From | To | Type |
|------|----|------|
| <component> | <component> | <uses/imports/calls> |
```

Rules:
- **Read before write.** Always read the existing file first. Patch, don't overwrite.
- Update the `Last updated` date.
- Add new components to the Components table. Don't remove existing ones unless the code confirms they're deleted.
- Add new decisions to Key Decisions (append to bottom of table).
- Update Data Flow only when the flow actually changed.
- Keep Dependencies accurate — add new ones, remove confirmed-deleted ones.

### docs/api-changelog.md

Append-only log of API surface changes. Create if it doesn't exist.

```markdown
# API Changelog

Automatic log of API surface changes maintained by zuvo skills.

---

## YYYY-MM-DD — zuvo:<skill>

| Change | Endpoint / Contract | Details |
|--------|-------------------|---------|
| ADDED | `POST /api/users` | New user registration endpoint |
| MODIFIED | `GET /api/orders` | Added `status` query parameter |
| REMOVED | `DELETE /api/legacy` | Deprecated endpoint removed |
| SCHEMA | `OrderResponse` | Added `tracking_url` field |

---
```

Rules:
- Only log actual API surface changes (public endpoints, schemas, contracts)
- Internal refactoring that doesn't change the API surface: skip this file
- Change types: ADDED, MODIFIED, REMOVED, SCHEMA, AUTH, ERROR

### README.md updates (ship only)

- Update version badge/number if present
- Update "Installation" section if install process changed
- Update "Features" list if new user-facing features were added since last ship
- Do NOT rewrite the entire README — patch only stale sections
- Read the existing README first. If no README exists, skip (user should run `zuvo:docs readme`)

### CHANGELOG.md (ship only, gap-fill)

- Ship already handles CHANGELOG in its Phase 3
- Auto-docs only creates/updates CHANGELOG if ship's Phase 3 skipped it (e.g., `--no-changelog` flag or missing conventional commits)
- Format: Keep Changelog (keepachangelog.com)

## Execution Steps

### Step 1: Check if documentation directory exists

```
if docs/ directory does not exist:
  create docs/
```

### Step 2: Determine what to update

Using the Skill → Update Matrix above, check each column for the current skill. For conditional updates (marked "if X"), evaluate the detection rules against the actual changes made during this skill run.

### Step 3: Update each applicable file

For each file that needs updating:

1. **Read** the existing file (if it exists)
2. **Construct** the new entry/patch based on the format above
3. **Write** the update (append for journals, patch for architecture/README)

### Step 4: Print summary

```
AUTO-DOCS: updated project-journal.md [+ architecture.md] [+ api-changelog.md]
```

One line, listing only files that were actually updated. If no files needed updating (e.g., review REPORT mode), print nothing.

## Context Available Per Skill

Each skill provides this context implicitly (from its completed work):

| Skill | Available context |
|-------|------------------|
| brainstorm | Spec path, topic, decisions made, structural choices |
| plan | Plan path, task list, architectural decisions, component breakdown |
| execute | Per-task: files changed, CQ/Q scores, concerns, blockers |
| build | Feature description, files created/modified, tier, CQ/Q scores, commit hash |
| refactor | Refactoring type, target files, CQ before/after, commit hash |
| review | Scope, findings (FIX-NOW/RECOMMENDED/NIT), fixes applied (if FIX mode) |
| ship | Version old→new, tag, flow, test results, review depth, diff LOC |

You do NOT need to re-read code or re-analyze. Use the data already gathered during the skill run.

## Error Handling

- **File write fails:** Log warning `AUTO-DOCS: could not update <file> — <reason>`. Proceed to next file.
- **No docs/ directory and cannot create:** Log warning. Skip all updates.
- **File is locked or read-only:** Skip that file with warning.
- **Large project-journal.md (>500 entries):** Archive old entries to `docs/project-journal-archive-YYYY.md`, keep last 100 in main file.

## What NOT to Do

- Do not re-read source code files. Use context from the skill run.
- Do not rewrite existing documentation sections that weren't affected by this skill run.
- Do not add speculative future plans. Only document what was actually done.
- Do not include code snippets in journal entries. Keep entries high-level.
- Do not block skill completion if auto-docs fails. Always proceed to Run Log.
- Do not update architecture.md for trivial changes (typo fixes, comment updates, test-only changes).
