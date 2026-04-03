---
name: migrate
description: "Structured migration runner for database schema changes, framework/library major upgrades, and API version transitions. Detects the project's ORM or migration tool automatically, generates forward and rollback migrations, applies codemods for breaking changes, and verifies safety with a pre-flight checklist. Supports three modes: db (schema migrations), upgrade (dependency major bumps), and api (versioned endpoint transitions). Flags: --dry-run (preview only), --rollback (generate down migration), --data (include data transformation)."
---

# zuvo:migrate — Structured Migration Runner

A disciplined workflow for migrations that change schemas, APIs, or major dependencies. Detects the project's tooling automatically, generates migration artifacts in the project's native format, and verifies safety before completion.

**Scope:** Any migration that changes database schemas, upgrades frameworks or libraries across major versions, or transitions API versions with backward compatibility.
**Out of scope:** Feature logic (`zuvo:build`), bug fixes (`zuvo:debug`), performance tuning (`zuvo:performance-audit`), general refactoring without a version boundary (`zuvo:refactor`).

---

## Argument Parsing

Parse `$ARGUMENTS` to determine the migration mode and flags:

| Input | Mode | Example |
|-------|------|---------|
| `db [description]` | Database schema migration | `zuvo:migrate db add user preferences table` |
| `upgrade [package] [target-version]` | Framework/library major upgrade | `zuvo:migrate upgrade next 15` |
| `api [version-spec]` | API version transition | `zuvo:migrate api v1->v2` |
| _(empty)_ | Ask the user: "What type of migration? (db / upgrade / api)" | -- |

### Flags

| Flag | Effect |
|------|--------|
| `--dry-run` | Preview migration plan without generating or executing files |
| `--rollback` | Generate rollback (down) migration alongside the forward migration |
| `--data` | Include data migration script (not just schema changes) |

Flags can be combined: `zuvo:migrate db add preferences --rollback --data`

---

## Environment Compatibility

Read `{plugin_root}/shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

**Interaction behavior is governed entirely by env-compat.md.** This skill does not override env-compat defaults. Specifically:
- User confirmation gates follow env-compat rules for the detected environment.
- `--dry-run` is an additive override: it stops execution after Phase 2 regardless of environment.

---

## CodeSift Integration

Read `{plugin_root}/shared/includes/codesift-setup.md` for the full initialization sequence.

**Key tools for migrations:**

| Phase | Task | CodeSift tool | Fallback |
|-------|------|--------------|----------|
| 0 | Detect ORM/migration framework | `get_file_tree(repo, path_prefix=".", compact=true)` | Glob for config files |
| 0 | Read current schema | `get_file_outline(repo, schema_path)` | Read the file directly |
| 1 | Find all usages of deprecated APIs | `search_text(repo, query="oldAPI", file_pattern="*.ts")` | Grep |
| 1 | Trace callers of changed functions | `trace_call_chain(repo, symbol_name, direction="callers", depth=3)` | Grep for imports |
| 1 | Find all API route definitions | `search_symbols(repo, query="router\|controller\|endpoint", include_source=true)` | Grep |
| 1 | Batch multiple lookups | `codebase_retrieval(repo, queries=[...])` | Sequential Grep/Read |
| 3 | Verify no broken references | `find_references(repo, symbol_name)` | Grep |

After editing any file, update the index: `index_file(path="/absolute/path/to/file")`

---

## Mandatory File Reading

Before starting work, read each file below. Print the checklist with status.

```
CORE FILES LOADED:
  1. {plugin_root}/rules/cq-patterns.md              -- READ/MISSING
  2. {plugin_root}/shared/includes/auto-docs.md       -- READ/MISSING
  3. {plugin_root}/shared/includes/session-memory.md  -- READ/MISSING
```

Where `{plugin_root}` is resolved per `env-compat.md`.

**Conditional files (loaded at the phase that needs them):**

| File | Load when | Skip when |
|------|-----------|-----------|
| `{plugin_root}/rules/testing.md` | Before Phase 3 verification (if tests exist) | No test framework detected |
| `{plugin_root}/rules/file-limits.md` | Phase 0 (stack detection) | If unavailable, use defaults |
| `{plugin_root}/rules/security.md` | When migration touches auth tables, secrets, or access control | No security-sensitive schemas in scope |

**If any CORE file missing:** Proceed in degraded mode. Note in Phase 4 output.

---

## Phase 0: Detect Migration Context

### 0.1 Project Detection

1. Read the project's `CLAUDE.md` and any rules directory for conventions
2. Detect the tech stack from config files (`package.json`, `tsconfig.json`, `pyproject.toml`, `Cargo.toml`, `Gemfile`, etc.)
3. Detect the ORM or migration framework:

| Signal | Framework | Migration tool |
|--------|-----------|---------------|
| `prisma/schema.prisma` | Prisma | `prisma migrate` |
| `ormconfig.ts` or `data-source.ts` with TypeORM imports | TypeORM | TypeORM migrations |
| `knexfile.ts` or `knexfile.js` | Knex | `knex migrate` |
| `manage.py` + `django` in requirements | Django | `python manage.py makemigrations` |
| `alembic.ini` or `alembic/` directory | Alembic (SQLAlchemy) | `alembic revision` |
| `db/migrate/` + `Gemfile` with `rails` | Rails | `rails generate migration` |
| `drizzle.config.ts` | Drizzle | `drizzle-kit generate` |
| `migrations/` + raw SQL files | Raw SQL | Manual SQL files |
| None detected | Unknown | Ask user for migration format |

### 0.2 Mode-Specific Context

**For `db` mode:**
- Read the current schema file (models, tables, columns, indexes, constraints)
- Locate the migration directory and understand the naming convention (timestamps, sequential, etc.)
- List existing migrations to understand the history

**For `upgrade` mode:**
- Read the current version of the target package from the lockfile or manifest
- Identify the target version (from argument or latest major)
- Locate changelog, migration guide, or breaking changes document if available online
- Detect the package manager (`npm`, `pnpm`, `yarn`, `pip`, `cargo`, `bundler`)

**For `api` mode:**
- Detect the current API version strategy (URL prefix, header, query param)
- Find all route/endpoint definitions for the current version
- Identify consumers (internal clients, SDKs, documentation references)

Output:
```
MIGRATION CONTEXT
  Mode:       [db | upgrade | api]
  Framework:  [detected ORM/tool/package]
  Current:    [current schema state | current version | current API version]
  Target:     [desired state | target version | target API version]
  Tool:       [migration command that will be used]
  Directory:  [where migration files live]
```

---

## Phase 1: Analyze Impact

### 1.1 Impact Assessment

**For `db` mode:**
- Diff desired schema changes vs current schema
- Classify each change: ADDITION (new table/column), MODIFICATION (type change, constraint change), DELETION (drop table/column)
- Flag destructive operations: `DROP TABLE`, `DROP COLUMN`, column type narrowing, `NOT NULL` without default
- Check for large table operations that could cause locks (adding index on table with >1M rows estimate)
- If `--data`: identify rows/records that need transformation

**For `upgrade` mode:**
- Use CodeSift or Grep to find all usages of the package's exports across the codebase
- Cross-reference with the package's breaking changes list
- Classify each affected usage: AUTO-FIXABLE (codemod available), MANUAL-FIX (needs human judgment), REMOVED (feature gone, needs alternative)
- Check for transitive dependency conflicts

**For `api` mode:**
- Map all endpoints in the current API version
- Identify consumers: internal services, frontend clients, external integrations, SDKs
- Classify each endpoint: UNCHANGED (copy as-is), MODIFIED (schema/behavior change), DEPRECATED (remove in new version), NEW (add in new version only)

### 1.2 Risk Assessment

```
IMPACT ANALYSIS
  Mode:       [db | upgrade | api]
  Files:      [N files affected]
  Changes:    [N additions, N modifications, N deletions]
  Risk:       [LOW | MEDIUM | HIGH]
  Reason:     [why this risk level]
```

Risk levels:
- **LOW**: Additive only (new tables, new columns with defaults, new endpoints)
- **MEDIUM**: Modifications to existing structures, type changes with safe coercion, endpoint schema changes
- **HIGH**: Destructive operations (drops, type narrowing), >10 files affected, auth/payment tables, no rollback path

**If HIGH risk + >10 files affected:** Recommend phased execution. Ask user: "This is a high-risk migration affecting N files. Recommend breaking into phases. Continue as single migration or split?"

If `--dry-run`: Print the impact analysis and STOP. Do not proceed to Phase 2.

---

## Phase 2: Generate Migration

### 2.1 Database Migration (`db` mode)

Generate the migration file in the project's native format:

**Prisma:**
- Update `schema.prisma` with new models/fields
- Run conceptual diff to produce the migration SQL
- Place migration in `prisma/migrations/YYYYMMDDHHMMSS_description/migration.sql`

**TypeORM:**
- Generate migration class with `up()` and `down()` methods
- Place in the configured migrations directory
- Include `QueryRunner` calls for each schema change

**Knex:**
- Generate migration with `exports.up` and `exports.down`
- Use the project's naming convention (timestamp prefix)

**Django:**
- Generate migration class with `operations` list
- Follow Django's auto-naming convention

**Alembic:**
- Generate revision with `upgrade()` and `downgrade()` functions
- Include `op.add_column`, `op.drop_column`, etc.

**Rails:**
- Generate migration class with `change` method (or `up`/`down` for irreversible)
- Use Rails naming convention (`YYYYMMDDHHMMSS_description.rb`)

**Drizzle:**
- Update the schema definition file
- Generate SQL migration via drizzle-kit patterns

**Raw SQL:**
- Generate `up.sql` and `down.sql` files
- Include transaction wrappers where supported

For ALL frameworks:
- Include indexes for foreign keys and frequently queried columns
- Include constraints (NOT NULL, UNIQUE, CHECK) with appropriate defaults
- Add comments on non-obvious columns
- If `--data`: Generate a data transformation script (separate file, runs after schema migration)
- If `--rollback`: Generate the down/rollback migration explicitly (even if framework auto-generates)

### 2.2 Framework/Library Upgrade (`upgrade` mode)

1. **Update manifest:** Modify `package.json` / `pyproject.toml` / `Cargo.toml` / `Gemfile` with the target version
2. **Apply codemods:** For known breaking changes, apply automated fixes:
   - Renamed APIs: find-and-replace with confirmation
   - Changed import paths: update all import statements
   - Removed features: flag for manual intervention
   - Changed function signatures: update call sites
3. **Log each change:** Print `CODEMOD: [file]:[line] — [old] -> [new]` for every automated fix
4. **Flag manual fixes:** Print `MANUAL: [file]:[line] — [description of required change]` for items that need human judgment

### 2.3 API Version Migration (`api` mode)

1. **Create versioned structure:**
   - If URL-prefix strategy: create new route directory (e.g., `routes/v2/`)
   - If header/query strategy: create version-aware middleware
2. **Copy and modify endpoints:**
   - Copy current version endpoints to new version
   - Apply schema changes, new fields, removed fields
   - Update request/response types and validation
3. **Deprecation layer:**
   - Add deprecation headers to old version endpoints (`Deprecation`, `Sunset`)
   - Add warning responses for deprecated fields
   - Log deprecation usage for monitoring
4. **Migration guide:**
   - Generate `docs/api-migration-v[old]-to-v[new].md`
   - Document every endpoint change with before/after examples
   - Include timeline (if provided by user)

### 2.4 Generation Summary

Print what was generated:

```
GENERATED
  Files created:   [list with paths]
  Files modified:  [list with paths]
  Manual items:    [N items requiring human intervention]
```

---

## Phase 3: Verify

### 3.1 Database Verification (`db` mode)

1. If a test/dev database is available and the migration tool supports dry-run:
   - Run the migration in preview mode (`prisma migrate dev --create-only`, `alembic upgrade --sql`, etc.)
   - Check for SQL syntax errors
   - Verify the migration applies without conflicts
2. If `--rollback`: Verify the down migration can be applied after the up migration
3. Check that all foreign key references resolve to existing tables/columns
4. If tests exist that touch affected models: run them

### 3.2 Upgrade Verification (`upgrade` mode)

1. Run the type checker (`tsc --noEmit`, `mypy`, `pyright`, `cargo check`) and report errors
2. Run the test suite and report failures
3. List remaining manual fixes with file locations
4. Check for peer dependency conflicts

### 3.3 API Verification (`api` mode)

1. Run existing API tests against both the old and new version endpoints
2. Verify the deprecation headers are set correctly on old endpoints
3. Check that new version endpoints return correct response shapes
4. Validate that shared middleware/auth works on both versions

### 3.4 Verification Output

```
VERIFICATION
  Type checker:    [PASS | FAIL (N errors) | N/A]
  Tests:           [PASS | FAIL (N failures) | N/A]
  Migration apply: [PASS | FAIL | SKIPPED (no dev DB)]
  Rollback apply:  [PASS | FAIL | SKIPPED (no --rollback)]
  Manual items:    [N remaining]
```

If verification fails: print the errors, attempt automated fixes for obvious issues, re-run. If still failing after one retry, list the failures and proceed to Phase 4 with WARN verdict.

---

## Phase 4: Safety Checklist

Print the safety checklist. Mark each item based on analysis.

```
MIGRATION SAFETY
  [x] Backward compatible? (data survives rollback)
  [x] Rollback tested? (down migration works)
  [ ] Zero-downtime possible? (no table locks on large tables)
  [x] Data preserved? (no destructive DROP without backup)
  [x] Indexes added for new queries?
  [x] Constraints have defaults? (NOT NULL columns have DEFAULT)
  [ ] Consumer notification? (API clients informed of changes)
```

For each unchecked item, print a warning with the specific concern:

```
WARNING: Zero-downtime — adding index on `orders` table (estimated >1M rows) may lock table.
  Recommendation: Use CREATE INDEX CONCURRENTLY (PostgreSQL) or online DDL.
WARNING: Consumer notification — 3 internal services consume v1 endpoints.
  Recommendation: Notify teams before deploying v2 deprecation.
```

### Stage and Commit

Stage exactly the files created or modified:

```
git add [explicit file list -- never -A or .]
```

Commit with a descriptive message:

```
git commit -m "migrate: [mode] [description]"
```

Examples:
- `migrate: db add user_preferences table with indexes`
- `migrate: upgrade next.js 14 -> 15 with codemod fixes`
- `migrate: api v1 -> v2 with deprecation layer`

Do not push. Pushing is a separate user decision.

---

## Output Block

```
MIGRATION COMPLETE
----------------------------------------------------
Type:       [db | upgrade | api] ([framework/tool])
Migration:  [path to migration file(s)]
Impact:     [N files affected, N models/endpoints changed]
Risk:       [LOW | MEDIUM | HIGH] ([reason])
Rollback:   [path to rollback file | "not generated (use --rollback)"]
Tests:      [passing | N failures | N/A]
Verify:     types [PASS|FAIL|N/A] | tests [PASS|FAIL|N/A] | apply [PASS|FAIL|SKIP]
Safety:     [N/M checks passed]
Commit:     [hash] -- [message]

Next steps:
  [Framework-specific deploy command, e.g.:]
  npx prisma migrate deploy                -- apply to production
  python manage.py migrate                 -- apply to production
  rails db:migrate RAILS_ENV=production    -- apply to production
  zuvo:review [migration files]            -- independent review
  git push origin [branch]                 -- push when ready
----------------------------------------------------
```

---

## Auto-Docs

After printing the MIGRATION COMPLETE block, update project documentation per `{plugin_root}/shared/includes/auto-docs.md`:

- **project-journal.md**: Log the migration type, framework, files changed, risk level, safety checklist result.
- **architecture.md**: Update if database schema changed (new tables, removed tables, new relationships) or if API version strategy was introduced/modified.
- **api-changelog.md**: Update if API endpoints were added, modified, deprecated, or versioned.

Use context already gathered during the migration -- do not re-read source files. If auto-docs fails, log a warning and proceed to Session Memory.

---

## Session Memory

After Auto-Docs, update `memory/project-state.md` per `{plugin_root}/shared/includes/session-memory.md`:

- **Recent Activity**: Prepend entry with migration type, framework, risk level, verdict.
- **Active Work**: Update current branch and work-in-progress.
- **Backlog Summary**: Recount if any items were persisted during this migration.
- **Tech Stack**: Add new discoveries if migration introduced new dependencies or changed the database schema.

If `memory/project-state.md` doesn't exist, create it (full Tech Stack detection + all sections).

---

## Run Log

Append one TSV line to `memory/zuvo-runs.log` per `{plugin_root}/shared/includes/run-logger.md`. All fields are mandatory:

| Field | Value |
|-------|-------|
| DATE | ISO 8601 timestamp |
| SKILL | `migrate` |
| PROJECT | Project directory basename (from `pwd`) |
| CQ_SCORE | `-` (migrations do not produce CQ scores) |
| Q_SCORE | `-` (migrations do not produce Q scores) |
| VERDICT | PASS / WARN / FAIL from Phase 3 verification |
| TASKS | Number of migration files generated |
| DURATION | `[mode]-[N]-phase` (e.g., `db-4-phase`, `upgrade-4-phase`) |
| NOTES | `[mode] [description]` (max 80 chars) |
