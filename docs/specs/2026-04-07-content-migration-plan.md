# Implementation Plan: Content Migration

**Spec:** docs/specs/2026-04-07-content-migration-spec.md
**spec_id:** 2026-04-07-content-migration-1230
**plan_revision:** 1
**status:** Approved
**Created:** 2026-04-07
**Tasks:** 4
**Estimated complexity:** all standard (markdown files)

## Task Breakdown

### Task 1: Create migration-fix-registry.md
**Files:** `shared/includes/migration-fix-registry.md`
**Dependencies:** none

### Task 2: Create content-migration SKILL.md
**Files:** `skills/content-migration/SKILL.md`
**Dependencies:** Task 1

### Task 3: Update routing + counts
**Files:** `skills/using-zuvo/SKILL.md`, `docs/skills.md`, `.claude-plugin/plugin.json`, `.codex-plugin/plugin.json`
**Dependencies:** Task 2

### Task 4: Install + verify
**Dependencies:** Task 1-3
