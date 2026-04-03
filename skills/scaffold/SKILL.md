---
name: scaffold
description: >
  Generate new modules, components, endpoints, or services by detecting existing
  patterns in the codebase and replicating them. Supports component, endpoint,
  service, model, hook, middleware, page, and worker types. Auto-detects project
  conventions (naming, file location, import style, test co-location) from a
  canonical example, then generates new files that match. Flags: --dry-run
  (preview only), --no-test (skip test generation), --minimal (bare minimum).
---

# zuvo:scaffold — Pattern-Based Code Generation

A structured workflow for generating new code modules by detecting and replicating existing patterns in the codebase. Instead of generating from generic templates, scaffold finds the best existing example of the requested type and uses it as the canonical pattern, ensuring every new file matches project conventions exactly.

**Scope:** Creating new files that follow established project patterns. CRUD endpoints, React components, API routes, services, models, hooks, middleware, pages, workers.
**Out of scope:** Feature implementation logic (`zuvo:build`), design system creation (`zuvo:design`), project initialization from scratch, refactoring existing code (`zuvo:refactor`).

---

## Argument Parsing

Parse `$ARGUMENTS` for these flags:

| Flag | Effect |
|------|--------|
| `[type] [name]` | What to scaffold — e.g., `component UserProfile`, `endpoint /api/orders`, `service PaymentService`, `model Order` |
| `--dry-run` | Preview generated files without writing anything to disk |
| `--with-test` | Also generate test file (default: yes) |
| `--no-test` | Skip test file generation |
| `--minimal` | Bare minimum output — no boilerplate comments, no JSDoc, no section headers |
| _(remaining text)_ | Additional context for generation (e.g., "with pagination" or "using Redis") |

Both `[type]` and `[name]` are required. If either is missing, print usage and stop:

```
USAGE: zuvo:scaffold <type> <name> [--dry-run] [--no-test] [--minimal]

  Types: component, endpoint, route, service, model, hook, middleware, page, worker
  Examples:
    zuvo:scaffold component UserProfile
    zuvo:scaffold endpoint /api/orders --dry-run
    zuvo:scaffold service PaymentService --no-test
    zuvo:scaffold model Order --minimal
```

### Supported Types

| Type | Aliases | Description |
|------|---------|-------------|
| `component` | — | React/Vue/Svelte/Astro component |
| `endpoint` | `route` | API endpoint (REST, tRPC, GraphQL resolver) |
| `service` | — | Business logic service class or module |
| `model` | `entity` | Database model/entity (Prisma, TypeORM, Mongoose, SQLAlchemy, Drizzle) |
| `hook` | `composable` | React hook / Vue composable |
| `middleware` | `mw` | Express/Koa/Fastify/Next.js middleware |
| `page` | — | Full page component (Next.js, Nuxt, SvelteKit, Astro) |
| `worker` | `job` | Background job / queue worker / cron handler |

If the type is not recognized, print the supported types table and stop.

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

This skill does not override env-compat defaults. Scaffold is a single-agent skill — no parallel dispatch needed.

---

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

CodeSift is used heavily in Phase 0 and Phase 1 to find canonical examples and analyze patterns. If CodeSift is unavailable, fall back to grep-based searches.

After creating any file, update the index: `index_file(path="/absolute/path/to/file")`

---

## Mandatory File Reading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-patterns.md           -- READ/MISSING
  2. {plugin_root}/rules/file-limits.md            -- READ/MISSING
  3. {plugin_root}/shared/includes/auto-docs.md    -- READ/MISSING
  4. {plugin_root}/shared/includes/session-memory.md -- READ/MISSING
```

Where `{plugin_root}` is resolved per `env-compat.md`.

**Deferred loading (read when needed):**
- `{plugin_root}/rules/testing.md` — read before generating test files (Phase 2)
- `{plugin_root}/rules/cq-checklist.md` — read at CQ spot-check time (Phase 3)

**If any CORE file missing:** Proceed in degraded mode. Note in Phase 3 output.

---

## Phase 0: Detect Project Patterns

### 0.1 Project Context

1. Read the project's `CLAUDE.md` and any rules directory for conventions.
2. Detect the tech stack from config files (`package.json`, `tsconfig.json`, `pyproject.toml`, `go.mod`, `Cargo.toml`, etc.).
3. Determine the framework: Next.js, Nuxt, SvelteKit, Express, Fastify, NestJS, Django, Flask, Rails, etc.
4. Detect the styling approach: CSS Modules, Tailwind, styled-components, SCSS, etc.
5. Detect the test runner: Jest, Vitest, pytest, Go test, etc.
6. Read `memory/backlog.md` if it exists — check for items related to the scaffold target area.

Output:
```
STACK: [language/framework] | STYLING: [approach] | RUNNER: [test runner]
```

### 0.2 Find Existing Examples

Search the codebase for existing files of the requested type. Use CodeSift when available, grep as fallback.

**Search strategy by type:**

| Type | CodeSift approach | Grep fallback |
|------|-------------------|---------------|
| `component` | `search_symbols(repo, query="", kind="function", file_pattern="*.tsx")` | `grep -rl "export default\|export function" --include="*.tsx" --include="*.vue" --include="*.svelte"` |
| `endpoint` | `search_symbols(repo, query="", kind="function", file_pattern="*route*")` | `grep -rl "GET\|POST\|PUT\|DELETE\|export async function" --include="*.ts" src/app/api/ src/pages/api/ app/api/` |
| `service` | `search_symbols(repo, query="Service", kind="class")` | `grep -rl "class.*Service\|export.*Service" --include="*.ts" --include="*.py"` |
| `model` | `search_symbols(repo, query="", kind="class", file_pattern="*model*\|*entity*\|*schema*")` | `grep -rl "model\|@Entity\|Schema\|Base" --include="*.ts" --include="*.py" --include="*.prisma"` |
| `hook` | `search_symbols(repo, query="use", kind="function", file_pattern="*hook*\|use*")` | `grep -rl "export function use\|export const use" --include="*.ts" --include="*.tsx"` |
| `middleware` | `search_symbols(repo, query="", kind="function", file_pattern="*middleware*")` | `grep -rl "middleware\|NextRequest\|Request.*Response.*next" --include="*.ts"` |
| `page` | `search_symbols(repo, query="", kind="function", file_pattern="*page*")` | Find files named `page.tsx`, `index.tsx` in route directories, or `+page.svelte` |
| `worker` | `search_symbols(repo, query="", kind="function", file_pattern="*worker*\|*job*\|*queue*")` | `grep -rl "Worker\|Job\|Queue\|process\|handler" --include="*.ts" --include="*.py"` |

Collect at least 2-3 existing examples. If zero found, warn and ask the user to point to an example or confirm generation from conventions only.

### 0.3 Select Canonical Example

From the found examples, pick the **canonical example** — the single best file to use as a pattern. Selection criteria (in priority order):

1. **Recency** — prefer recently created files (within last 90 days of git history)
2. **Completeness** — has types, error handling, tests, and follows conventions
3. **Simplicity** — not overly complex or special-cased
4. **Size** — within file-limits.md thresholds (not a god-file)

Run `get_file_outline(repo, file_path)` on the top 2-3 candidates. Pick the one with the cleanest structure.

Output:
```
CANONICAL EXAMPLE: [file path]
  Alternatives considered: [file1], [file2]
  Selection reason: [why this one]
```

---

## Phase 1: Analyze Pattern

### 1.1 Read Canonical Example

Read the canonical example file fully. Extract these structural elements:

1. **File header** — imports, type imports, constant imports
2. **Type definitions** — interfaces, types, schemas, Zod validators
3. **Main export** — function signature, class structure, component shape
4. **Internal helpers** — private functions, utility methods
5. **Error handling** — try/catch patterns, error boundaries, validation
6. **Export style** — default export, named export, barrel re-export
7. **Boilerplate** — JSDoc comments, copyright headers, lint pragmas

### 1.2 Detect Conventions

From the canonical example and surrounding project structure:

| Convention | How detected | Example |
|------------|-------------|---------|
| File naming | Directory listing of sibling files | `kebab-case.tsx`, `PascalCase.tsx`, `snake_case.py` |
| File location | Parent directory of canonical example | `src/components/`, `app/api/`, `lib/services/` |
| Import style | Read canonical imports | Absolute (`@/lib/...`) vs relative (`../../`) |
| Export style | Read canonical exports | `export default`, `export function`, `module.exports` |
| Test co-location | Check for `__tests__/`, `.test.`, `.spec.` siblings | `__tests__/Dashboard.test.tsx` or `Dashboard.spec.ts` co-located |
| Naming convention | Examine exported names | PascalCase components, camelCase functions, UPPER_SNAKE constants |

### 1.3 Read Test Pattern

If `--no-test` was NOT passed:

1. Find the test file for the canonical example.
2. Read it fully. Extract: test structure, describe/it patterns, mock strategy, assertion style.
3. If no test file exists for the canonical example, search for any test file of the same type.
4. If no test files exist at all, fall back to `{plugin_root}/rules/testing.md` defaults.

### 1.4 Pattern Summary

Print the extracted pattern:

```
PATTERN: [canonical file] -> [N] structural elements detected
  File naming:   [convention]
  File location: [directory]
  Import style:  [absolute/relative]
  Export style:  [default/named]
  Test location: [co-located / __tests__ / separate tree]
  Naming:        [PascalCase / camelCase / snake_case]
  Elements:      [list of structural blocks found]
```

---

## Phase 2: Generate

### 2.1 Plan Files

Determine the files to create:

| File | Path | Purpose |
|------|------|---------|
| Main file | `[detected location]/[name with convention].[ext]` | The scaffolded module |
| Test file | `[test location]/[name].[test ext]` | Tests (unless `--no-test`) |
| Type file | `[location]/[name].types.[ext]` | Only if canonical example uses separate type files |
| Index update | `[location]/index.[ext]` | Only if a barrel file (index.ts) exists and re-exports siblings |

If `--dry-run`: print the plan and STOP here. Do not create any files.

```
DRY RUN — Files that would be created:
  [path 1] (main)
  [path 2] (test)
  [path 3] (types — only if applicable)
  [path 4] (barrel update — only if applicable)
```

### 2.2 Generate Main File

Build the new file using the extracted pattern:

1. **Start from the canonical structure.** Copy the structural skeleton: imports section, type section, main export, helpers section.
2. **Replace specifics.** Swap the canonical name for the new name everywhere. Adjust types, props, parameters to match the new module.
3. **Resolve imports.** Ensure all imports point to real files. Remove imports that are canonical-specific and not needed.
4. **Apply naming conventions.** File name, export name, internal names all follow detected conventions.
5. **Apply `--minimal` if set.** Strip JSDoc comments, section headers, boilerplate comments. Keep only functional code.
6. **Inject placeholder logic.** Add TODO comments for implementation details: `// TODO: implement [name] logic`

Rules:
- Do NOT copy business logic from the canonical example. Copy only structure.
- Do NOT invent features not requested. The scaffold is a starting point.
- Follow `cq-patterns.md` ALWAYS patterns (proper error handling, no any types, etc.).
- Respect `file-limits.md` thresholds. A scaffold should be well under limits.

### 2.3 Generate Test File

If `--no-test` is NOT set:

1. Read `{plugin_root}/rules/testing.md` before generating.
2. Use the test pattern from Phase 1.3.
3. Generate tests covering:
   - Default render / happy path call
   - Props / parameters validation
   - Error handling path
   - Edge case (empty input, null, boundary)
4. Mock only external boundaries (HTTP, database, email, time, randomness).
5. Use real imports — never mock the module under test.

### 2.4 Update Barrel File

If an `index.ts` (or equivalent barrel file) exists in the target directory and it re-exports siblings:

1. Add an export line for the new module.
2. Follow the existing export pattern (named re-export, default re-export, wildcard).

---

## Phase 3: Validate

### 3.1 Compilation Check

Run the stack-appropriate type checker on the generated files:

| Stack | Command |
|-------|---------|
| TypeScript | `npx tsc --noEmit` (or project-specific: `pnpm tsc --noEmit`) |
| Python (typed) | `mypy [file]` or `pyright [file]` |
| Go | `go build ./...` |
| Rust | `cargo check` |
| None | Skip with note |

Fix any compilation errors. Common issues: missing imports, wrong type names, stale references from canonical example.

### 3.2 Convention Check

Verify the generated files match project conventions:

```
CONVENTION CHECK
  [ ] File location matches pattern: [expected dir]
  [ ] File naming matches pattern: [expected convention]
  [ ] Export style matches pattern: [expected style]
  [ ] Import style matches pattern: [expected style]
  [ ] Naming convention matches pattern: [expected convention]
```

Fix any mismatches before proceeding.

### 3.3 Run Tests

If tests were generated:

1. Run the test file: `[test runner] [test file path]`
2. All tests must pass. Fix failures.
3. If tests cannot pass because the scaffolded module has placeholder logic, mark tests as `.todo` or `.skip` with a comment explaining why, and note this in the output.

### 3.4 CQ Spot-Check

Read `{plugin_root}/rules/cq-checklist.md`. Run a focused CQ check on the generated production file(s). Check these gates with evidence:

| Gate | What to check |
|------|---------------|
| CQ1 | Naming follows project conventions |
| CQ3 | Types are explicit (no `any`, no implicit `any`) |
| CQ5 | Error handling is present and follows canonical pattern |
| CQ6 | No hardcoded secrets, URLs, or magic numbers |
| CQ8 | Imports are clean (no unused, no circular) |
| CQ14 | File size is within limits |

Fix any gate = 0 before completing.

### 3.5 Stage and Commit

Stage exactly the files created or modified:

```
git add [explicit file list -- never -A or .]
```

Commit with a conventional message:

```
git commit -m "scaffold: add [type] [name]"
```

Follow env-compat interaction rules for commit confirmation. Do not push.

---

## Phase 3.6: Output

```
SCAFFOLD COMPLETE
----------------------------------------------------
Type:       [type]
Name:       [name]
Pattern:    [canonical file path] (canonical)
Generated:
  [file path 1] (main)
  [file path 2] (test)
  [file path 3] (types — if applicable)
  [file path 4] (barrel update — if applicable)
Convention: [naming convention summary] ✓
Tests:      [N passing | N skipped (placeholder logic) | skipped (--no-test)]
CQ:         [gates checked — all pass]
Commit:     [hash] — scaffold: add [type] [name]

Next steps:
  Implement TODO placeholders in [main file]
  zuvo:build [feature]  — flesh out the implementation
  zuvo:review [files]   — review after implementation
----------------------------------------------------
```

If `--dry-run` was set, print instead:

```
SCAFFOLD DRY RUN COMPLETE
----------------------------------------------------
Type:       [type]
Name:       [name]
Pattern:    [canonical file path] (canonical)
Would generate:
  [file path 1] (main)
  [file path 2] (test)
Convention: [naming convention summary]

Run without --dry-run to create these files.
----------------------------------------------------
```

---

## Auto-Docs

After printing the SCAFFOLD COMPLETE block, update project documentation per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the module scaffolded, type, canonical pattern used, files created.
- **architecture.md**: Update if the new module represents a new component or service in the architecture.
- **api-changelog.md**: Update if an endpoint or route was scaffolded.

Use context already gathered during the scaffold — do not re-read source files. If auto-docs fails, log a warning and proceed to Session Memory.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with scaffold type, name, canonical pattern, files created.
- **Active Work**: Update current branch and work-in-progress.
- **Tech Stack**: No changes expected (scaffold does not introduce new dependencies).

If `memory/project-state.md` doesn't exist, create it (full Tech Stack detection + all sections).

---

## Run Log

Append one TSV line to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`. All fields are mandatory:

| Field | Value |
|-------|-------|
| DATE | ISO 8601 timestamp |
| SKILL | `scaffold` |
| PROJECT | Project directory basename (from `pwd`) |
| CQ_SCORE | `spot-check` (CQ1, CQ3, CQ5, CQ6, CQ8, CQ14) |
| Q_SCORE | `N/A` if `--no-test`, otherwise `basic` |
| VERDICT | PASS / WARN / FAIL from Phase 3 checks |
| TASKS | Number of files created |
| DURATION | `light` (scaffold is always lightweight) |
| NOTES | `[type] [name] from [canonical file basename]` (max 80 chars) |

---

## Error Handling

| Situation | Action |
|-----------|--------|
| No existing examples found for type | Warn user. Ask: provide an example file path, or generate from framework conventions only? |
| Canonical example is too complex (>500 lines) | Pick a simpler alternative. If none, extract only the structural skeleton (skip internal helpers). |
| Generated file fails compilation | Fix automatically (up to 3 attempts). If still failing, print the errors and ask the user. |
| Test file fails | Mark failing tests as `.todo`/`.skip` with explanation. Note in output. |
| `--dry-run` mode | Stop after Phase 2.1. No files written, no commit, no auto-docs, no run log. |
| Type not recognized | Print supported types table and stop. |
| Name not provided | Print usage and stop. |
