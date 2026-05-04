---
name: db-audit
description: >
  Database performance and safety audit. 70+ checks across 13 dimensions
  (DB1-DB13): query patterns, indexes, schema design, connections, transactions,
  migrations, caching, query optimization, ORM anti-patterns, observability,
  data lifecycle, DB security, and migration deployment safety. Code-level checks for all ORMs. Optional
  live analysis via PostgreSQL or MySQL connection.
  Switches: zuvo:db-audit full | [path] | [file] | --schema | --queries | --connections | --live <conn>
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - search_patterns          # KEY — n-plus-one-django, missing-index, raw-sql
    - audit_scan
    - get_file_tree            # find migrations/, schema files
    - get_file_outline
    - search_text              # SQL string scans
    - search_symbols           # repository / DAO / Model classes
    - get_symbol
    - get_symbols
    - find_references          # who calls this query
    - trace_call_chain
  by_stack:
    typescript: [get_type_info]
    javascript: []
    python: [python_audit, analyze_async_correctness]
    php: [php_project_audit, php_security_scan]
    kotlin: [analyze_sealed_hierarchy, find_extension_functions, trace_flow_chain, trace_suspend_chain, trace_compose_tree, analyze_compose_recomposition, trace_hilt_graph, trace_room_schema, analyze_kmp_declarations, extract_kotlin_serialization_contract]
    nestjs: [nest_audit]
    nextjs: [framework_audit, nextjs_route_map]
    astro: [astro_audit, astro_actions_audit, astro_hydration_audit]
    hono: [analyze_hono_app, audit_hono_security]
    express: []
    fastify: []
    react: [react_quickstart, analyze_hooks, analyze_renders]
    django: [analyze_django_settings, effective_django_view_security, taint_trace, get_model_graph]
    fastapi: [trace_fastapi_depends, get_pydantic_models]
    flask: [find_framework_wiring]
    jest: []
    yii: [resolve_php_service]
    # ORMs / databases — full SQL toolchain (verified 2026-05-04: each tool catches what others miss)
    prisma:
      - analyze_prisma_schema     # FK index coverage, soft-delete, status-as-String warnings
      - explain_query             # KEY — Prisma→EXPLAIN ANALYZE: unbounded queries, N+1, missing indexes
    drizzle: []
    sql:
      - sql_audit                 # composite: 5 gates (drift, orphan, lint, dml, complexity)
      - analyze_schema            # tables/columns/FKs/relations → ERD for executive summary
      - diff_migrations           # classify ops: additive/modifying/destructive (deploy risk)
      - trace_query               # cross-codebase table-ref tracing (DDL, DML, FK, ORM)
      - search_columns            # find columns by name/type — PII discovery (DB12)
    postgres:
      - migration_lint            # squawk PG migration safety (30+ patterns: NOT NULL no default, etc.)
---

# zuvo:db-audit

Audit database interactions from code patterns through schema design to live
query plans. Produces a scored report with specific, actionable fixes ranked by
impact and effort.

**When to use:** Before releases, after adding models or queries, when latency
increases, after scaling incidents, periodic health check.
**When NOT to use:** Code quality (`zuvo:review`), full-stack performance
(`zuvo:performance-audit`), security-only (`/security-audit`).

## Mandatory File Loading

Read every file below before starting. Print the checklist.

```
CORE FILES LOADED:
  1. ../../shared/includes/codesift-setup.md      -- [READ | MISSING -> STOP]
  2. ../../shared/includes/env-compat.md           -- [READ | MISSING -> STOP]
  3. ../../shared/includes/run-logger.md           -- [READ | MISSING -> STOP]
```

**Deferred (lazy load):**

```
DEFERRED FILES (read only when needed):
  - ../../shared/includes/retrospective.md  -- read right before Phase 6 (saves ~3K tokens during audit)
```

Note: `cq-patterns.md` is NOT loaded — this is a read-only audit, not a code quality review. Loading it wastes ~7K tokens per turn.

If any CORE file is MISSING, STOP. Do not proceed from memory.

---

## MANDATORY TOOL CALLS — Audit Validity Gate

**This audit is INVALID if any of the tools below are skipped when their trigger condition holds.** "DEFERRED", "N/A", "no diff vs prior audit" are NOT valid reasons. The presence of trigger artifacts (migrations directory, .sql files, ORM schema, etc.) is what dictates the call — not whether they changed since the last audit.

### Required tool list

| Tool | Trigger | Reason | Skip allowed? |
|------|---------|--------|---------------|
| `sql_audit` | Project has any `.sql` file (migrations, schema, dumps) anywhere under `TARGET_ROOT` | DB6/DB12/DB13 — bundles 5 gates (drift, orphan, lint, dml, complexity) that no manual scan reproduces | **NO** — audit FAILS if skipped while trigger holds |
| `analyze_schema` | Same as `sql_audit` (`.sql` files exist) | DB3 schema design — extracts tables/columns/FKs/relationships, generates ERD for executive summary | **NO** when `.sql` exists |
| `diff_migrations` | `migrations/` dir exists (any ORM/framework) | DB6/DB13 deployment safety — classifies every op as additive/modifying/destructive with risk ranking; surfaces destructive ops missed by `sql_audit lint` gate | **NO** when migrations exist |
| `trace_query` | At least one HIGH/MEDIUM finding mentions a table OR `sql_audit orphan` gate flags any orphan | DB3/DB13 verification — confirms zero references for "orphan" claim and traces every cited table across DDL/DML/FK/ORM (Prisma + Drizzle) | **NO** when condition holds |
| `search_columns` | Always | DB12 PII discovery — find every `email`/`password`/`ssn`/`token` column across all tables | **NO** — always required |
| `migration_lint` | Postgres detected (any of: `pg`, `psycopg2`, `@prisma/adapter-pg`, `postgres-js` in deps) AND `migrations/` dir exists | DB13 migration deployment safety (squawk: 30+ PG-specific patterns including `NOT NULL` without default, `CREATE INDEX` without `CONCURRENTLY`, etc.) | **NO** when both conditions hold |
| `analyze_prisma_schema` | `prisma/schema.prisma` exists | DB2/DB3/DB6 Prisma-specific schema gates (FK index coverage %, unindexed FKs, soft-delete detection, `status: String` smell) | **NO** when schema exists |
| `explain_query` | Prisma project AND any HIGH/MEDIUM finding cites a `prisma.<model>.<call>` query | DB1/DB2 Prisma-specific N+1 + missing-index detection via simulated EXPLAIN ANALYZE; finds risks `sql_audit dml` cannot see | **NO** when condition holds |
| `python_audit` | Language detected as Python | DB1 N+1 detection (`n-plus-one-django` pattern), DB9 ORM anti-patterns | **NO** when Python project |
| `nest_audit` | Framework detected as NestJS (`@nestjs/*` in deps) | DB1/DB4 NestJS DI + repository scoping issues | **NO** when NestJS project |
| `analyze_django_settings` + `get_model_graph` | `django` in pyproject/requirements | DB6 Django migration safety, DB3 model graph | **NO** when Django |
| `scan_secrets` | Always | DB12 hardcoded credentials in code or `.env` | **NO** — always required |
| `search_patterns(pattern="unbounded-findmany")` + `search_patterns(pattern="await-in-loop")` + `search_patterns(pattern="toctou")` | Always | DB1/DB5 — these are the ONLY tool-verified gates for those patterns | **NO** — always required |

### Pre-flight check (run BEFORE any phase)

Before Phase 0, verify the required tools are reachable:

```
# Detect triggers
sql_files=$(find TARGET_ROOT -name "*.sql" -not -path "*/node_modules/*" -not -path "*/.git/*" | head -1)
migrations_dir=$(find TARGET_ROOT -type d -name "migrations" -not -path "*/node_modules/*" | head -1)
prisma_schema=$([ -f TARGET_ROOT/prisma/schema.prisma ] && echo "yes" || echo "no")
```

For each trigger that holds, confirm the matching tool is in the preloaded tool list (from `codesift-setup.md` Step 2.5 ToolSearch). If a required tool is NOT in the list and is also NOT in the deferred-tools banner:
- Print `[ABORT] Required tool '<name>' not reachable. db-audit cannot produce a valid report without it.`
- Do NOT proceed with grep fallback. The audit is incomplete by definition.
- Exit with status `INCOMPLETE` and add a backlog item: `[BLOCKER] db-audit needs <tool> on <project>`.

### Forbidden escape hatches

The following telemetry values are **forbidden** when the trigger condition holds:

| Value | Forbidden when | Required value instead |
|-------|----------------|------------------------|
| `sql_audit: DEFERRED` | `.sql` files exist | `sql_audit: <gates_passed>/<gates_run>` |
| `sql_audit: N/A` | `.sql` files exist | (same as above) |
| `sql_audit: skipped (no diff vs prior)` | EVER | (same as above — trigger is presence, not delta) |
| `migration_lint: DEFERRED` | Postgres + migrations exist | `migration_lint: <findings>` |
| `scan_secrets: DEFERRED` | EVER | `scan_secrets: <count>` |
| `codesift: unavailable` | `mcp__codesift__*` was in deferred-tools session-start banner | `codesift: deferred-not-preloaded (FAILURE: skill required preload)` |

### Audit completion verification (run BEFORE writing PASS/WARN/FAIL status)

At the end of the audit, before emitting the status block:

1. Re-check each trigger condition.
2. For each held trigger, verify the corresponding tool was actually called in this session (the LLM must self-report honestly — there is no automated post-execution gate yet, so use the run log as ground truth).
3. If ANY required tool is missing for a held trigger:
   - Override the verdict to `INCOMPLETE` regardless of finding count.
   - Print: `[VALIDITY GATE FAIL] <tool> required by <trigger>, not called. Audit cannot be trusted.`
   - Add the gap to the backlog as `B-db-audit-incomplete-<date>`.

A db-audit that says "0 critical findings" while skipping `sql_audit` on a project with 34 migrations is **lying**, not passing. The completion gate exists to catch that.

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All 13 dimensions across the project (auto-decides mode in Phase 0.4) |
| `[path]` | Scope to a directory or module |
| `[file]` | Deep audit of a single file (all applicable dimensions) |
| `--schema` | Schema analysis only (DB2, DB3, DB6) |
| `--queries` | Query pattern analysis only (DB1, DB8, DB9) |
| `--connections` | Connection and pool management only (DB4) |
| `--live <conn>` | Enable Phase 3: connect to the database for EXPLAIN and statistics |
| `--force-full` | Skip audit mode decision in Phase 0.4 — always run full audit even if a recent prior audit exists |
| `--delta` | Force delta mode (only allowed if commits_since < 5 AND hours_since < 4 — see Phase 0.4) |

---

## Safety Gates

### GATE 1 -- Read-Only

This audit is **read-only**. The only write target is `audits/`.

FORBIDDEN:
- Running any migration
- Modifying schema files, model files, or ORM configuration
- Executing INSERT/UPDATE/DELETE against any database
- Modifying connection strings or pool settings

### GATE 2 -- Live Mode Scoping

When `--live <conn>` is used:
- Only SELECT and EXPLAIN queries are permitted
- No DDL (CREATE, ALTER, DROP)
- No DML (INSERT, UPDATE, DELETE)
- Connection must be read-only if the database supports read replicas

---

## Phase 0: Detect and Prepare

### 0.0 CodeSift Capability Check

If CodeSift MCP is available, run these two calls before anything else:

1. `get_extractor_versions()` — check if the project's primary language has a full parser (symbol-level tools) or only text-stub support. If text-stub only: skip all symbol-based CodeSift calls (search_symbols, get_file_outline, trace_call_chain, find_references) and use Grep/Read fallbacks instead. Print the result.
2. `analyze_project()` — returns detected stack (framework, language, package manager, monorepo), file classifications, dependency counts, and git health. Use the output to pre-fill ORM, Engine, and Deployment detection below instead of manual file scanning.

If `analyze_project` returns enough to populate the stack table, skip 0.1/0.2/0.3 manual detection and jump to the output block. If it returns partial data (e.g. framework=null), fill the gaps with the manual tables below.

### 0.1 ORM Detection

If not resolved by `analyze_project`:

| Signal | ORM |
|--------|-----|
| `prisma/schema.prisma` | Prisma |
| `ormconfig.*` or `DataSource` import | TypeORM |
| `drizzle.config.*` | Drizzle |
| `.sequelizerc` or `sequelize` in deps | Sequelize |
| `knexfile.*` or `knex` in deps | Knex |
| `settings.py` with `DATABASES` | Django ORM |
| `sqlalchemy` in requirements | SQLAlchemy |
| Raw `pg`/`mysql2` without ORM | Raw SQL client |

### 0.2 Database Engine Detection

If not resolved by `analyze_project`:

| Signal | Engine | Managed provider |
|--------|--------|------------------|
| `postgresql` in connection string or schema provider | PostgreSQL | — |
| `mysql` in connection string or provider | MySQL | — |
| `sqlite` in provider | SQLite | — |
| `mongodb` in provider or `mongoose` | MongoDB | — |
| `neon.tech` in DATABASE_URL | PostgreSQL | **Neon** (built-in pooler) |
| `supabase.co` in DATABASE_URL | PostgreSQL | **Supabase** (built-in pooler) |
| `pscale.sh` or `psdb.cloud` | MySQL | **PlanetScale** (built-in pooler) |
| `cockroachlabs.cloud` | CockroachDB | **Cockroach Cloud** (built-in pooler) |
| `rds.amazonaws.com` | PostgreSQL/MySQL | **AWS RDS** |
| `azure.com` with `database` segment | PostgreSQL/MySQL/SQL Server | **Azure Database** |
| `googleapis.com` with `cloudsql` | PostgreSQL/MySQL | **Cloud SQL** |
| `mongodb.net` | MongoDB | **MongoDB Atlas** |

**Managed provider note:** When a managed provider with built-in pooling is detected (Neon, Supabase, PlanetScale, Cockroach Cloud), DB4 should NOT be marked critical-fail for "no PgBouncer config" — the platform handles pooling. Mark these findings as TOOL-VERIFIED with note "managed pooling: <provider>" and pass DB4 if no other issues exist.

### 0.3 Deployment Detection

If not resolved by `analyze_project`:

| Signal | Type |
|--------|------|
| `vercel.json`, `netlify.toml` | Serverless (Vercel/Netlify) |
| `wrangler.toml` | Serverless (Cloudflare Workers) |
| `serverless.yml` | Serverless (AWS Lambda) |
| `Dockerfile`, `docker-compose` | Containerized |
| None of above | Traditional |

Print detection results:

```
DB AUDIT STACK
------------------------------------
ORM:       [Prisma / TypeORM / Drizzle / Django / SQLAlchemy / Raw SQL]
Engine:    [PostgreSQL / MySQL / SQLite / MongoDB]
Deploy:    [Serverless / Container / Traditional]
Scope:     [full / path / file]
Dims:      [DB1-DB13 / subset]
CodeSift:  [full-parser / text-stub / unavailable]
------------------------------------
```

### 0.4 Audit Mode Decision

**Default mode is `full`.** Delta mode is a narrow exception, NOT a shortcut.

If `--force-full` was passed: `mode = "full"` — skip the rest of this section.

Otherwise, look for the most recent prior audit at `audits/db-audit-*.md`:

```bash
PRIOR_AUDIT=$(ls -t audits/db-audit-*.md 2>/dev/null | head -1)

if [ -z "$PRIOR_AUDIT" ]; then
  mode="full"  # baseline
else
  PRIOR_SHA=$(grep -E '^\| HEAD_SHA' "$PRIOR_AUDIT" | head -1 | awk '{print $NF}')
  PRIOR_MTIME=$(stat -f %m "$PRIOR_AUDIT" 2>/dev/null || stat -c %Y "$PRIOR_AUDIT")
  NOW=$(date +%s)
  HOURS_SINCE=$(( (NOW - PRIOR_MTIME) / 3600 ))
  COMMITS_SINCE=$(git rev-list --count "${PRIOR_SHA}..HEAD" 2>/dev/null || echo 999)

  if [ "$COMMITS_SINCE" -eq 0 ] && [ "$HOURS_SINCE" -lt 2 ]; then
    mode="sanity-check"
  elif [ "$COMMITS_SINCE" -lt 5 ] && [ "$HOURS_SINCE" -lt 4 ]; then
    mode="delta"
  else
    mode="full"
  fi
fi
```

| Mode | When | What it does |
|------|------|--------------|
| `full` | No prior audit, OR commits_since ≥ 5, OR hours_since ≥ 4, OR `--force-full` | Independent re-evaluation of all dimensions. Default. |
| `delta` | commits_since < 5 AND hours_since < 4 AND prior audit exists | Verify prior findings + scan changed files only. **Requires Phase 0.5 checklist.** |
| `sanity-check` | commits_since == 0 AND hours_since < 2 | Spot-verify 1-2 specific fixes. Not a full audit. |

If user passed `--delta` but the conditions for delta are not met: print a warning and override to `full`. Do NOT silently honor the flag — the user's "I want delta" is overridden by methodology safety.

### CRITICAL — Mode does NOT affect MANDATORY TOOL CALLS

Mode (full / delta / sanity-check) controls **scope of additional analysis** — which dimensions get deep-dived, which agent-dispatched explorations run, how many findings are re-examined. Mode does **NOT** waive any tool from the MANDATORY TOOL CALLS section above.

Specifically, in EVERY mode (including `delta` and `sanity-check`):

- `sql_audit` MUST run if any `.sql` file exists.
- `analyze_schema` MUST run if any `.sql` file exists (companion to sql_audit — generates ERD).
- `diff_migrations` MUST run if `migrations/` dir exists (classifies destructive ops).
- `search_columns` MUST run (PII discovery — every audit).
- `scan_secrets` MUST run.
- `search_patterns(unbounded-findmany | await-in-loop | toctou)` MUST run.
- `migration_lint` MUST run if Postgres + `migrations/` dir exists.
- `analyze_prisma_schema` MUST run if `prisma/schema.prisma` exists.
- `explain_query` MUST run on every Prisma query cited in a HIGH/MEDIUM finding.
- `trace_query` MUST run on every table cited in a HIGH/MEDIUM finding (or flagged by `sql_audit orphan`).
- Stack-specific mandatory tools (nest_audit, python_audit, django/celery/etc.) MUST run when their language/framework is detected.

These tools ARE the audit's validity floor — without them the report cannot be trusted regardless of how small the delta is. They are also fast (single composite calls), so "delta is too small to bother" is never a defensible reason.

If you are tempted to mark any mandatory tool as `DEFERRED (delta-mode, low risk)` or `N/A (no DB changes)`: **STOP**. That is the exact failure mode this section exists to prevent. The trigger is presence of `.sql`/`migrations/`/`schema.prisma`/etc. — never delta or risk.

Print the decision:

```
AUDIT MODE: [full / delta / sanity-check]
Reason:     prior=[date or "none"] | commits_since=[N] | hours_since=[N.N]
Override:   [user --force-full | user --delta accepted | user --delta REJECTED→full | none]
Mandatory-tools-acknowledgment: I will run sql_audit + analyze_schema + diff_migrations + search_columns + scan_secrets + migration_lint (if PG) + analyze_prisma_schema (if Prisma) + search_patterns(unbounded-findmany, await-in-loop, toctou) + stack-specific mandatory tools (nest_audit/python_audit/etc. when detected) + trace_query + explain_query (on cited tables/queries) in this mode. [REQUIRED — print verbatim]
```

### 0.5 Delta Verification Checklist

**Skip this section if `mode != "delta"`.**

When `mode == "delta"`, you MUST complete every item below before writing the report. Any skipped item forces `mode = "full"` and restart from Phase 1.

```
DELTA VERIFICATION CHECKLIST
[ ] git diff --name-only <prior_sha>..HEAD  → list changed files (CHANGED_FILES)
[ ] scan_secrets on CHANGED_FILES (NEVER skip, even if DB12 was 4/4 in prior)
[ ] For every finding from prior audit:
      → 1× codebase_retrieval batch call (do NOT iterate per-finding)
[ ] For every severity downgrade you propose (M→L, H→M):
      → find_references on the symbol → document the count
      → DOWNGRADE BLOCKED without count evidence in the report
[ ] For every endpoint mentioned in any finding:
      → trace_route to confirm hot-path / cold-path status
[ ] For every finding with a matching docs/specs/*-plan.md reference:
      → tag as PLANNED (not HIGH/MEDIUM)
```

Why this checklist exists: previous delta audits inherited prior assumptions and silently propagated errors. Severity downgrades without evidence, skipped scans on changed files, and untraced endpoint claims are the four most common delta-mode failures. This checklist eliminates them.

If at any point during the audit you find yourself thinking "the prior audit already covered this," STOP — that's the anchoring bias the checklist is designed to break. Run the verification.

---

## Phase 1: Schema Analysis

**Skip if:** no schema file and no migration directory found. Mark DB2, DB3,
DB6 as INSUFFICIENT DATA.

### 1.1 Schema Inventory

Read the schema source for the detected ORM and extract:

| Item | What to Count |
|------|---------------|
| Models/tables | Total count |
| Fields per model | Average and maximum |
| Relations | 1:1, 1:N, N:M counts |
| Indexes | Count per model, which fields |
| Unique constraints | Count per model |
| Defaults | Fields with/without default values |
| Nullable fields | Count and distribution |
| Enums vs string | Enum definitions vs raw string status/type fields |

**CodeSift accelerated (Prisma):** When CodeSift has a Prisma parser (check Phase 0.0), use symbol-level tools instead of reading the entire schema file:

```
# Get all models, enums, and types at a glance
get_file_outline(file_path="prisma/schema.prisma")

# Search for specific model patterns
search_symbols(query="@@index", file_pattern="*.prisma", include_source=true)
search_symbols(query="@@unique", file_pattern="*.prisma", include_source=true)

# For large schemas (>500 lines), use assemble_context instead of Read:
assemble_context(query="prisma models with relations", level="L1", token_budget=8000)
```

This replaces reading a 500-1500 line schema file in full, saving ~5-10K tokens.

**ORM-specific sources (manual fallback):**
- **Prisma:** `prisma/schema.prisma` -- `@@index`, `@@unique`, `@default`, `?` nullable
- **TypeORM:** Entity files -- `@Column`, `@Index`, `@JoinColumn`, `@ManyToOne`
- **Django:** `models.py` -- `Field` types, `class Meta` indexes, `ForeignKey`
- **Drizzle:** Schema files -- `index()`, `unique()`, `references()`
- **SQLAlchemy:** Model files -- `Column`, `Index`, `ForeignKey`, `UniqueConstraint`

### 1.2 External Index Detection

Before scoring DB2 as "zero indexes", scan for indexes defined outside the ORM:

- SQL scripts with `CREATE INDEX` outside migration directories
- MongoDB shell scripts with `createIndex` or `ensureIndex`
- Standalone index management files

If found, inventory those indexes and add a DB2.10 finding: indexes managed
outside ORM/migrations are not reproducible on fresh environments.

### 1.3 Migration Analysis (DB6)

Read the last 10 migration files and flag:
- `CREATE INDEX` without `CONCURRENTLY` (PostgreSQL)
- `ALTER COLUMN SET NOT NULL` without prior default
- `ALTER COLUMN TYPE` (type changes on populated tables)
- `DROP COLUMN` or `DROP TABLE` without soft-delete strategy
- Missing down/reverse migration (except Prisma, which is forward-only by design)

### 1.4 Model Inventory Output

```
MODEL INVENTORY
| Model | Fields | Relations | Indexes | Uniques | Issues |
|-------|--------|-----------|---------|---------|--------|
| User  | 12     | 3         | 2       | 1       | Missing FK index on orgId |
| Order | 18     | 5         | 1       | 0       | No unique for idempotency |
```

---

## Phase 2: Code-Level Analysis (DB1-DB13)

### 2.0 CodeSift Pre-Scan

Before dispatching agents or running manual analysis, run these automated checks when CodeSift is available. They replace ~20 manual Grep calls and provide TOOL-VERIFIED findings.

#### 2.0a — Generic anti-pattern scans

```
# DB1: N+1 and unbounded query detection (automated)
search_patterns(pattern="unbounded-findmany")     # findMany without take/limit
search_patterns(pattern="await-in-loop")           # sequential await in loop = N+1

# DB5: Race condition pre-scan
search_patterns(pattern="toctou")                  # read-then-write without atomic op

# DB12: Secret exposure (hidden tool — reveal first)
# Claude Code: ToolSearch("select:mcp__codesift__scan_secrets")
# Codex/other: describe_tools(names=["scan_secrets"], reveal=true)
scan_secrets(min_confidence="medium")              # hardcoded DB passwords, connection strings
```

If `scan_secrets` is unavailable, fall back to: `Grep` for `password=`, `DATABASE_URL=`, `connection_string`, API keys in `.env` committed to git.

#### 2.0b — SQL composite audit (`sql_audit`) — MANDATORY when `.sql` files exist

**REQUIRED CALL.** If `find TARGET_ROOT -name "*.sql" -not -path "*/node_modules/*"` returns ≥1 file, you MUST call `sql_audit` in this phase. There is no condition under which "skipped" is acceptable on a `.sql`-bearing repo: not "no diff vs prior", not "DEFERRED", not "low risk this run". The 5 internal gates are independent of delta — they re-run every time and re-validate the schema↔ORM mapping from scratch. Skipping = audit invalid (see MANDATORY TOOL CALLS section above).

```
# Claude Code: ToolSearch("select:mcp__codesift__sql_audit")
# Codex/other: describe_tools(names=["sql_audit"], reveal=true)
sql_audit()                                        # runs all 5 gates: drift, orphan, lint, dml, complexity
```

Map each gate to the corresponding DB dimension:

| sql_audit gate | Maps to | What it catches |
|---------------|---------|-----------------|
| `drift`       | DB13 (migration deploy safety) | Prisma↔SQL field/type mismatches — "forgot to run migration" bugs |
| `orphan`      | DB3 (schema design) | Tables defined in SQL with zero references in code or ORM |
| `lint`        | DB2 + DB3 | Missing PK, wide tables (>20 cols), duplicate index names |
| `dml`         | DB12 (DB security) | DELETE/UPDATE without WHERE (data loss), SELECT * (unbounded) |
| `complexity`  | DB3 (schema design) | God tables: column count + FK count + index count score ≥25 |

For finer control, run a subset of gates: `sql_audit({ checks: ["drift", "dml"] })`.

The `sql_audit` result has shape:
```json
{
  "gates": [
    { "check": "drift", "pass": false, "critical": true, "finding_count": 3, "summary": "3 drifts: 2 extra in ORM, 0 extra in SQL, 1 type mismatches", "data": {...} },
    { "check": "orphan", "pass": true, ... },
    ...
  ],
  "summary": { "total_findings": 12, "critical_findings": 1, "gates_run": 5, "gates_passed": 2, "gates_failed": 3 }
}
```

Pass each gate's findings to the corresponding DB dimension scoring as TOOL-VERIFIED evidence. Critical gates (`drift` with type_mismatches > 0, `dml` with high-severity findings) propagate to the matching DB critical gate (DB13, DB12).

If `sql_audit` is unavailable (CodeSift older than v0.4.x or no `.sql` files), skip 2.0b and rely on the manual schema/migration analysis in Phase 1 + agent dispatch.

#### 2.0c — Additional SQL query tools (optional)

When deeper investigation is needed for specific findings:

| Tool | When to use |
|------|-------------|
| `analyze_schema` | Generate ERD (Mermaid) for the executive summary section |
| `trace_query(table)` | **MANDATORY** for every "orphan" finding from `sql_audit` and every table cited in HIGH/MEDIUM findings — verify zero references across `.ts`/`.py`/`.go`/`.kt`/Prisma/Drizzle |
| `search_columns(query)` | **MANDATORY** for DB12 PII discovery — find all `email`/`password`/`ssn`/`token`/`secret`/`hash` columns. Run with empty query first to inventory PII surface, then targeted queries for specific concerns. |
| `diff_migrations` | **MANDATORY when `migrations/` exists** — DB6/DB13 destructive op classification. Reports `additive`/`modifying`/`destructive` counts. Now in MANDATORY TOOL CALLS section above. |
| `analyze_schema(output_format='mermaid')` | **MANDATORY when `.sql` exists** — DB3 schema inventory + ERD for executive summary. |
| `explain_query(code='prisma.<model>.<call>(...)')` | **MANDATORY for every Prisma query cited in HIGH/MEDIUM finding** — DB1/DB2 simulated EXPLAIN ANALYZE catches N+1 from `include`, unbounded `findMany`, missing indexes that `sql_audit` cannot see (Prisma-only). |

Previously these were "drill down only" — promoted to mandatory after the 2026-05-04 audit on tgm-survey-platform showed `sql_audit` alone misses ~30% of issues that surface when paired with `diff_migrations` + `analyze_schema` + `trace_query`.

---

If CodeSift is entirely unavailable, skip Phase 2.0 and proceed directly to Agent Dispatch — agents will use Grep/Read.

Collect results from 2.0a + 2.0b. Pass them into agent prompts as "pre-verified findings" (HIGH confidence, tool-verified). Agents should NOT re-scan for these patterns — they should verify context and discover patterns the automated scan missed.

### Agent Dispatch

Refer to `env-compat.md` for the dispatch pattern.

**When parallel dispatch is available:**

| Agent | Dimensions | Focus |
|-------|-----------|-------|
| Schema Analyst | DB2, DB3, DB6, DB13 | Schema design + migration safety + deploy safety |
| Query Scanner | DB1, DB5, DB8, DB9 | Code-level query patterns |
| Infrastructure Auditor | DB4, DB7, DB10, DB11, DB12 | Connections, cache, observability, security |

**Agent prompt rules:**

1. **CodeSift tool loading** — include this block at the very top of every agent prompt so tools are callable:
   ```
   FIRST: Load CodeSift tools before doing anything else.
   - Claude Code: Run ToolSearch("select:mcp__codesift__search_text,mcp__codesift__search_symbols,mcp__codesift__codebase_retrieval,mcp__codesift__trace_route,mcp__codesift__find_references,mcp__codesift__get_file_outline,mcp__codesift__trace_call_chain,mcp__codesift__search_patterns,mcp__codesift__assemble_context")
   - Codex: Call mcp__codesift__search_text directly — MCP tools are pre-registered.
   - Cursor/Antigravity: CodeSift unavailable — use Grep/Read.
   If any tool call fails, fall back to Grep/Read.
   ```
   Adjust the tool list per agent role — Schema Analyst needs `get_file_outline` + `search_symbols` + `sql_audit` + `analyze_schema` + `search_columns`; Query Scanner needs `trace_route` + `codebase_retrieval` + `search_patterns` + `trace_query`; Infrastructure Auditor needs `search_text` + `find_references` + `diff_migrations` (for DB13 destructive op review).
2. **Token budget:** Each agent must keep its report under 800 words. Structured as: findings list (ID, severity, file:line, 1-sentence description) + 1-paragraph summary. No prose explanations per finding.
3. **CodeSift cheat sheet** — include right after the tool loading block:
   ```
   CodeSift: batch 3+ searches → codebase_retrieval(queries=[...]).
   Endpoints → trace_route first. Skip list_repos (auto-resolve).
   If empty results → fallback to Grep (parser may be unavailable).
   ```
4. **Pre-verified findings:** Pass Phase 2.0 results to agents with instruction: "These findings are TOOL-VERIFIED. Do not re-scan for them. Focus on patterns the pre-scan cannot catch."

**Without parallel dispatch:** Execute all dimensions sequentially.

### DB1: Query Patterns -- Weight 15, Max 15, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| N+1 queries | Eager loading (`include`, `joinedload`), batched IDs | `findMany` / `find` inside a loop | CRITICAL |
| Select efficiency | `select` only needed fields | `SELECT *` / no select clause | HIGH |
| Bulk operations | `createMany`, `updateMany`, bulk insert | Individual create/update in loop | HIGH |
| Raw query safety | Parameterized queries (`$queryRaw` with template, `%s` params) | String concatenation in SQL | CRITICAL |

Critical gate: DB1=0 (N+1 in hot path) triggers audit FAIL.

### DB2: Index Strategy -- Weight 15, Max 15

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| FK indexes | Every foreign key has an index | FK columns without index | HIGH |
| Composite indexes | Multi-column indexes for common query patterns | Single-column indexes on individually queried fields | MEDIUM |
| Covering indexes | Index includes all fields for frequent queries | Extra lookups required | LOW |
| Unused indexes | All indexes serve active queries | Indexes that are never hit | MEDIUM |

### DB3: Schema Design -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Normalization | Appropriate normal form, no data duplication | Same data stored in multiple tables | HIGH |
| Enum usage | Database enums or constrained strings for status/type | Arbitrary strings without validation | MEDIUM |
| Timestamps | `createdAt`/`updatedAt` on mutable models, `deletedAt` for soft delete | No audit trail | MEDIUM |
| Naming conventions | Consistent naming (snake_case or camelCase), clear foreign key names | Mixed conventions, ambiguous names | LOW |

### DB4: Connection Management -- Weight 10, Max 10, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Connection pooling | Pool configured with min/max, singleton client | New client per request | CRITICAL |
| Serverless awareness | External pooler (PgBouncer, Supabase pooler) for serverless | Direct connection from Lambda/Worker | CRITICAL |
| Connection limits | Pool size matches deployment (serverless: small, container: tuned) | Default unlimited | HIGH |
| Client instantiation | Single PrismaClient/DataSource instance | Multiple `new PrismaClient()` calls | HIGH |

Critical gate: DB4=0 (no pooling) triggers audit FAIL.

### DB5: Transaction Safety -- Weight 12, Max 12, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Multi-table mutations | Wrapped in transaction | Separate writes without transaction | CRITICAL |
| Transaction scope | Minimal scope, no external API calls inside | HTTP request or email send inside transaction | HIGH |
| Rollback handling | Explicit error handling, compensation logic | Silent swallow on transaction failure | HIGH |
| Deadlock prevention | Consistent lock ordering, timeout on transactions | Arbitrary ordering, no timeout | MEDIUM |

Critical gate: DB5=0 (multi-table mutations without transaction) triggers FAIL.

### DB6: Migration Safety -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Non-blocking DDL | `CREATE INDEX CONCURRENTLY`, `ADD COLUMN` with default | Locking index creation on large table | HIGH |
| Data migration | Separate data migration from schema migration | Mixed DDL and DML in one migration | MEDIUM |
| Reversibility | Down migrations exist and tested (non-Prisma ORMs) | No rollback path | MEDIUM |
| Type changes | Multi-step migration for type changes (add new, migrate, drop old) | Direct `ALTER TYPE` on populated column | HIGH |

### DB7: Caching Layer -- Weight 8, Max 8

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Query result cache | Redis/Memcached for expensive/repeated queries, TTL configured | Every request hits database | HIGH |
| Cache invalidation | Event-driven or TTL with jitter | Manual invalidation, no TTL | MEDIUM |
| Cache-aside pattern | Read-through with fallback to DB on miss | All-or-nothing cache (miss = error) | MEDIUM |
| Cache key design | Includes tenant/org scope, versioned | Global keys, no scoping | MEDIUM |

### DB8: Query Optimization -- Weight 10, Max 10

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Pagination | Cursor-based for large datasets, keyset pagination | OFFSET pagination on growing table | HIGH |
| LIKE queries | Prefix match only, full-text search for complex needs | `%term%` LIKE on unindexed column | MEDIUM |
| Function on column | Avoid function calls on indexed columns in WHERE | `WHERE LOWER(email) = ...` (defeats index) | MEDIUM |
| Sorting | Sort on indexed column | Sort on computed/unindexed column for large result | MEDIUM |

### DB9: ORM-Specific Anti-Patterns -- Weight 6, Max 6

Patterns vary by detected ORM:

**Prisma:** `$queryRawUnsafe`, missing `select` on deep includes, `findMany`
without `take`, `$transaction` with long-running operations.

**TypeORM:** Lazy relations without awareness, `find()` without `select`,
`QueryBuilder` without parameter binding.

**Django:** N+1 via `object.related_set.all()` without `select_related`/
`prefetch_related`, `.count()` on unevaluated queryset.

**SQLAlchemy:** Lazy loading N+1, `session.query()` without limit, missing
`yield_per` for large result sets.

### DB10: Observability -- Weight 4, Max 4

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Query logging | Structured logging with query duration, parameterized | No query logging in production | MEDIUM |
| Slow query alerting | Threshold-based alerts (> 1s), dashboard | No monitoring for slow queries | MEDIUM |
| Connection metrics | Pool utilization tracked, alerts on exhaustion | No visibility into connection state | LOW |

### DB11: Data Lifecycle -- Weight 4, Max 4

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Archival strategy | Old data archived or partitioned | Unbounded table growth | MEDIUM |
| Batch processing | Batch deletes/updates with limits, off-peak scheduling | Full-table operations during peak hours | MEDIUM |
| Soft delete | `deletedAt` pattern with default scope excluding deleted | Hard delete without audit trail | LOW |

### DB12: Database Security -- Weight 4, Max 4, Critical Gate

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| SQL injection | All queries parameterized, no string concatenation | `$queryRawUnsafe` or string-built SQL | CRITICAL |
| Least privilege | Application user has minimal permissions | App connects as superuser | HIGH |
| Connection encryption | SSL/TLS required in connection string | Plaintext database connection | HIGH |
| Sensitive data | PII encrypted at rest, column-level encryption for secrets | Plaintext passwords or tokens in DB | CRITICAL |

Critical gate: DB12=0 (SQL injection) triggers audit FAIL.

### DB13: Migration Deployment Safety -- Weight 8, Max 8

Goes beyond DB6 (migration code quality) to assess whether migrations can be deployed safely to a running production system.

| Check | Good | Bad | Severity |
|-------|------|-----|----------|
| Destructive operations | `DROP COLUMN`/`DROP TABLE` preceded by deprecation migration, data backed up | Direct `DROP` on populated columns without prior migration to remove usage | CRITICAL |
| Lock duration estimation | Short-lived locks: `ADD COLUMN` with default (PG 11+), `CREATE INDEX CONCURRENTLY` | `ALTER TABLE` operations that acquire `ACCESS EXCLUSIVE` lock on large tables (>100K rows) | CRITICAL |
| Rollback plan | Down migration exists and tested, or forward-fix strategy documented | No rollback path — failed migration leaves DB in inconsistent state | HIGH |
| Data loss risk | `NOT NULL` additions have `DEFAULT` value, type changes preserve data | `ALTER COLUMN SET NOT NULL` without default on populated table, truncating type changes | CRITICAL |
| Backward compatibility | New columns nullable or with defaults (old app version still works), rename = add+copy+drop | Column renames or type changes that break currently-deployed app code | HIGH |
| Idempotency | Migrations use `IF NOT EXISTS`, `IF EXISTS` guards | Migrations fail on re-run (no idempotency — partial failure leaves broken state) | HIGH |
| Migration ordering | Migrations numbered/timestamped, no conflicts in team branches | Multiple migrations with same timestamp, or migrations that depend on unapplied predecessors | MEDIUM |
| Long-running DML | Data backfills use batched updates with `LIMIT` and sleep between batches | Single `UPDATE` on millions of rows (locks table, blocks queries, risks timeout) | HIGH |
| Connection impact | Migration runs outside connection pool, or uses dedicated migration connection | Migration runs through application pool, potentially exhausting connections during deploy | MEDIUM |
| Zero-downtime readiness | Migration + app deploy order documented, blue-green or rolling deploy compatible | Migration requires app downtime — schema and app must change simultaneously | HIGH |

**How to audit:**

1. Read all migration files in the migrations directory (last 20 if >20 exist)
2. For each migration, classify operations:
   - **SAFE**: `ADD COLUMN` (nullable or with default), `CREATE TABLE`, `CREATE INDEX CONCURRENTLY`
   - **CAUTION**: `ADD COLUMN NOT NULL` with default (PG 11+ safe, older = table rewrite), `ALTER COLUMN SET DEFAULT`
   - **DANGEROUS**: `DROP COLUMN`, `DROP TABLE`, `ALTER COLUMN TYPE`, `ALTER COLUMN SET NOT NULL` without default
   - **BLOCKING**: `CREATE INDEX` without `CONCURRENTLY`, `ALTER TABLE` on large table without estimated lock time
3. For DANGEROUS/BLOCKING operations, check:
   - Is there a prior migration removing code references to dropped columns?
   - Is there a rollback migration?
   - Is the table large enough to cause lock contention (estimate from schema relations)?
4. Check deployment documentation for migration strategy

**Scoring:**
- 0 DANGEROUS ops without safeguards = 8/8
- Each unguarded DANGEROUS op: -2
- Each BLOCKING op without CONCURRENTLY: -1
- No rollback path for any destructive migration: -2
- No idempotency guards: -1

**N/A:** If no migration files found, DB13=N/A.

---

## Phase 3: Live Analysis (optional --live)

**Skip unless** `--live <conn>` was provided. Requires database client access.

**Supported engines:** PostgreSQL (full), MySQL (partial). SQLite/MongoDB:
skip Phase 3, rely on code-level analysis.

### 3.1 PostgreSQL Live Queries

```sql
-- Top 20 slow queries (requires pg_stat_statements)
SELECT query, calls, mean_exec_time, total_exec_time, rows
FROM pg_stat_statements ORDER BY total_exec_time DESC LIMIT 20;

-- Unused indexes
SELECT schemaname, relname, indexrelname, idx_scan, idx_tup_read
FROM pg_stat_user_indexes WHERE idx_scan = 0
ORDER BY pg_relation_size(indexrelid) DESC;

-- Cache hit ratio
SELECT sum(heap_blks_hit) / nullif(sum(heap_blks_hit) + sum(heap_blks_read), 0)
  AS cache_hit_ratio
FROM pg_statio_user_tables;

-- Table bloat
SELECT schemaname, relname, n_dead_tup, last_autovacuum
FROM pg_stat_user_tables WHERE n_dead_tup > 10000 ORDER BY n_dead_tup DESC;

-- Active connections by state
SELECT state, count(*) FROM pg_stat_activity GROUP BY state;
```

### 3.2 MySQL Live Queries

```sql
-- Slow queries via performance_schema
SELECT * FROM performance_schema.events_statements_summary_by_digest
ORDER BY SUM_TIMER_WAIT DESC LIMIT 20;

-- Unused indexes
SELECT * FROM sys.schema_unused_indexes;

-- Active connections
SHOW PROCESSLIST;
```

### 3.3 Unsupported Engines

If the engine is not PostgreSQL or MySQL, print:
"Live analysis requires PostgreSQL or MySQL. Skipping Phase 3."
Mark Phase 3 as SKIPPED.

---

## Phase 4: Verification and Scoring

### 4.1 False Positive Filters

| Pattern | Skip When |
|---------|-----------|
| `findMany` without `take` | Inside admin tool, migration script, or seed file |
| N+1 loop | Loop is bounded (< 10 items) AND commented as intentional |
| `await-in-loop` (search_patterns hit) | Function contains `*_CONCURRENCY_LIMIT`, `BATCH_SIZE`, `CHUNK_SIZE`, or similar bounded-concurrency constant |
| `await-in-loop` (search_patterns hit) | Loop body is inside a seed/migration/admin script (path contains `seed/`, `scripts/`, `migrations/`, `tools/`) |
| `await-in-loop` (search_patterns hit) | Loop is wrapped by `pLimit`, `Promise.all` with chunks, `pAll`, `bottleneck`, or similar concurrency limiter |
| `await-in-loop` (search_patterns hit) | Loop is bounded by literal `< 10` and the bound is visible in source |
| Missing index | Table known to be small (< 1000 rows, documented) |
| No indexes in ORM | External index scripts found (use external inventory for scoring) |
| No connection pool | Using managed service that pools for you (Neon, Supabase, PlanetScale, Cockroach Cloud — see Phase 0.2) |
| Raw SQL flagged | Uses tagged template `$queryRaw` (safe, parameterized) |

**Anti-noise rule for await-in-loop:** If `search_patterns(pattern="await-in-loop")` returns more than 10 hits, do NOT report each one as a finding. Instead, group them by file, identify which match the false-positive filters above, and report only the residual count with the worst 3 examples. Reporting 30+ "potential N+1" findings without filtering = noise that drowns signal.

### 4.2 Severity Classification

| Level | Criteria |
|-------|----------|
| CRITICAL | Data loss, connection exhaustion, SQL injection, OOM in production |
| HIGH | User-visible latency, missing safety guard, scalability wall |
| MEDIUM | Performance debt, suboptimal pattern, maintenance risk |
| LOW | Recommendation, best practice gap, future-proofing |

### 4.3 Cross-Dimension Correlations

Flag compound patterns:

| Pattern | Dimensions | Impact |
|---------|-----------|--------|
| N+1 on unindexed column | DB1+DB2 | Exponential degradation |
| Unbounded query without cache on large table | DB1+DB7+DB11 | OOM risk |
| External API call inside transaction without timeout | DB5+DB4 | Connection pool exhaustion |
| Serverless + no external pooler + multiple client instances | DB4+deployment | Connection storm |
| OFFSET pagination on growing table | DB8+DB11 | Degrading page load times |

### 4.4 Scoring

Score each dimension per the rubric. Calculate weighted total.

**Critical gate check:**
- DB1=0 (N+1 in hot path) -> FAIL
- DB4=0 (no connection pooling) -> FAIL
- DB5=0 (multi-table mutations without transaction) -> FAIL
- DB12=0 (SQL injection) -> FAIL

Any critical gate = 0 overrides the overall grade to **FAIL**.

**Grade calculation (excluding N/A dimensions):**

| Grade | Percentage |
|-------|-----------|
| A | >= 85% |
| B | 70-84% |
| C | 50-69% |
| D | < 50% |

---

## Phase 5: Report

Save to: `audits/db-audit-[YYYY-MM-DD].md`

**REQUIRED:** emit the Tool Availability Block (template in `../../shared/includes/codesift-setup.md`) at the top of the report, after the title and before findings. Auditing degraded runs depends on this — do NOT skip it.

### Report Structure

```markdown
# Database Audit Report

## Metadata
| Field | Value |
|-------|-------|
| Project | [name] |
| Date | [YYYY-MM-DD] |
| ORM | [detected ORM] |
| Engine | [detected engine] |
| Deployment | [detected deployment type] |
| Scope | [full / path / file] |
| Live analysis | [enabled / skipped] |
| CodeSift | [full-parser / text-stub / unavailable] |
| Prior audit | [date or "none — baseline"] |

## Executive Summary

**Score: [N] / [MAX]** -- [A/B/C/D or FAIL]

| Metric | Count |
|--------|-------|
| CRITICAL findings | N |
| HIGH findings | N |
| MEDIUM findings | N |
| LOW findings | N |

[2-3 sentence summary]

## Dimension Scores

| # | Dimension | Score | Max | Notes |
|---|-----------|-------|-----|-------|
| DB1 | Query Patterns | [N] | 15 | |
| DB2 | Index Strategy | [N] | 15 | |
| DB3 | Schema Design | [N] | 8 | |
| DB4 | Connection Mgmt | [N] | 10 | |
| DB5 | Transaction Safety | [N] | 12 | |
| DB6 | Migration Safety | [N] | 8 | |
| DB7 | Caching Layer | [N] | 8 | |
| DB8 | Query Optimization | [N] | 10 | |
| DB9 | ORM Anti-Patterns | [N] | 6 | |
| DB10 | Observability | [N] | 4 | |
| DB11 | Data Lifecycle | [N] | 4 | |
| DB12 | DB Security | [N] | 4 | |
| DB13 | Migration Deploy Safety | [N] | 8 | |
| **Total** | | **[N]** | **[M]** | |

## Critical Gate Status
[DB1, DB4, DB5, DB12 -- PASS/FAIL per gate]

## Model Inventory
[From Phase 1]

## Findings (sorted by severity)

Per finding:
- **ID:** DB{dimension}-{NNN} (e.g. DB1-001)
- **Severity:** CRITICAL / HIGH / MEDIUM / LOW
- **Status:** NEW / RESOLVED / PARTIAL / PLANNED / REGRESSION (see status rules below)
- **Confidence:** TOOL-VERIFIED (from Phase 2.0 pre-scan) / HIGH / MEDIUM
- **File:line:** exact location
- **Description:** 1 sentence
- **Fix:** concrete code change or command
- **Effort:** S (<1h) / M (1-4h) / L (4h+)
- **Evidence:** required for any severity downgrade — `find_references` count, `trace_route` hot/cold path, etc.

### Status rules

| Status | When to use | Counted in severity totals? |
|--------|-------------|----------------------------|
| `NEW` | First time this finding appears | Yes |
| `RESOLVED` | Prior finding no longer present (verified, not assumed) | No (moved to "Resolved" section) |
| `PARTIAL` | Part of prior issue is fixed, part remains. Severity stays at original level with `(partial)` suffix — DO NOT downgrade. | Yes, at original severity |
| `PLANNED` | Finding has a linked task in `docs/specs/*-plan.md` or `memory/backlog.md`. Tracked separately. | No (moved to "Planned" section) |
| `REGRESSION` | Finding was RESOLVED in prior audit but reappeared | Yes, severity = max(prior, current) |

**Severity downgrade rule:** A finding's severity may only be lowered (e.g. M→L) when ALL of these are true:
1. The Evidence field includes a concrete count from `find_references` or `trace_route`
2. The downgrade reason is documented in 1 sentence in the Description
3. If `mode == "delta"`, the Phase 0.5 checklist was completed for this specific finding

If any of the three conditions fail, keep the prior severity. Anchoring to a number you didn't independently verify is the #1 cause of audit drift.

## Delta from Prior Audit

If a prior `audits/db-audit-*.md` exists, include:

| Finding | Prior status | Current status | Change |
|---------|-------------|----------------|--------|
| DB1-001 | CRITICAL | RESOLVED | Fixed in [commit] |
| DB2-003 | HIGH | HIGH | Still open |
| DB9-001 | — | NEW | First detected |

Score delta: [prior score] → [current score] ([+/-N])

If no prior audit exists, print: "No prior audit found — baseline established."

## Cross-Cutting Patterns
[Compound patterns found]

## Top 5 Action Items

Per item: priority (P0/P1/P2), effort (S/M/L), blast radius (N files), concrete action.

## Delete These Tomorrow

Actionable commands for findings that require zero design decisions — just execute:

```bash
# Example format:
# DB1-003: Add take: 100 to unbounded findMany
# File: src/services/user.service.ts:45

# DB2-001: Add missing FK index
# npx prisma migrate dev --name add_org_id_index

# DB12-002: Remove hardcoded connection string
# Move to .env: DATABASE_URL=...
```

List only findings with effort=S. If none qualify, omit this section.

## Backlog Entries
[/backlog add commands for HIGH+ findings]
```

### Report Validation

After writing, verify:
- Dimension scores sum to total in Executive Summary
- Finding counts match Executive Summary (counted: NEW + PARTIAL + REGRESSION; not counted: RESOLVED + PLANNED)
- All models from inventory are addressed
- Critical gate status is accurate
- Every finding has a DB{N}-{NNN} ID, severity, status, confidence, file:line, and effort
- Every severity downgrade has Evidence field populated (find_references count or trace_route output)
- PLANNED findings have a verified link to `docs/specs/*-plan.md` or `memory/backlog.md`
- PARTIAL findings keep prior severity with `(partial)` suffix — no downgrade
- Delta section references correct prior audit (or states "baseline")
- TOOL-VERIFIED findings match Phase 2.0 pre-scan output
- "Delete These Tomorrow" only contains effort=S items
- If `mode == "delta"`: Phase 0.5 checklist is fully completed (all 6 items checked)

---

## Phase 6: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
DB1 CRITICAL (N+1)       -> zuvo:refactor [service file]
DB4 no connection pool    -> direct fix (add pool config)
DB2 missing indexes       -> direct migration (add indexes)
DB12 SQL injection        -> /security-audit [path]
DB13 unsafe migrations    -> rewrite migrations with CONCURRENTLY, rollbacks, batch DML
DB9 ORM anti-patterns     -> zuvo:refactor [service file]
Multiple dimensions fail  -> zuvo:review [path]
------------------------------------
```

---

## Completion Gate Check

Before printing the final output block, verify every item. Unfinished items = pipeline incomplete.

```
COMPLETION GATE CHECK
[ ] ORM + engine + deployment type detected and printed
[ ] N+1 query detection ran (DB1 critical gate)
[ ] Unbounded query detection ran (DB1/DB7)
[ ] Migration safety audit ran (DB6)
[ ] Critical gates printed: DB1, DB2, DB4, DB6, DB7, DB10, DB11
[ ] Report saved to audits/
[ ] Backlog updated for HIGH+ findings
[ ] Run: line printed and appended to log
```

## DB-AUDIT COMPLETE

Score: [N] / [MAX] -- [grade]
ORM: [detected] | Engine: [detected]
Dimensions: [N scored] | Critical gates: [PASS/FAIL]
Findings: [N critical] / [N total]

### Validity Gate (REQUIRED — print BEFORE Run line)

```
VALIDITY GATE
  triggers_held:
    sql_files: [yes(N) | no]
    migrations_dir: [yes | no]
    prisma_schema: [yes | no]
    postgres_in_deps: [yes | no]
    framework: [nestjs | django | none]
  required_tool_calls (held triggers only):
    sql_audit: [<gates_passed>/<gates_run> | NOT_CALLED — VIOLATES_TRIGGER]
    analyze_schema: [<table_count> tables | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    diff_migrations: [<additive>/<modifying>/<destructive> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    trace_query: [<table_count> traced | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    search_columns: [<pii_columns_found> | NOT_CALLED — VIOLATES_TRIGGER]
    migration_lint: [<findings> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    analyze_prisma_schema: [<fk_index_coverage> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    explain_query: [<queries_explained> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    nest_audit: [<score> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    python_audit: [<findings> | not_required | NOT_CALLED — VIOLATES_TRIGGER]
    scan_secrets: [<findings> | NOT_CALLED — VIOLATES_TRIGGER]
  pattern_calls:
    unbounded-findmany: [<count> | NOT_CALLED — VIOLATES_TRIGGER]
    await-in-loop: [<count> | NOT_CALLED — VIOLATES_TRIGGER]
    toctou: [<count> | NOT_CALLED — VIOLATES_TRIGGER]
  gate_status: [PASS | FAIL — <which tools missing>]
```

If `gate_status = FAIL`, override the VERDICT below to `INCOMPLETE` regardless of finding count, append `[VALIDITY GATE FAIL]` to the Run line NOTES column, and add a backlog item.

Run: <ISO-8601-Z>	db-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>


### Retrospective (REQUIRED)

**Load now (deferred):** Read `../../shared/includes/retrospective.md` if not already loaded.

Follow the retrospective protocol from `retrospective.md`.
Gate check → structured questions → TSV emit → markdown append.
If gate check skips: print "RETRO: skipped (trivial session)" and proceed.

After printing this block, append the `Run:` line value (without the `Run: ` prefix) to the log file path resolved per `run-logger.md`.

VERDICT: PASS (0 critical findings), WARN (1-3 critical), FAIL (4+ critical).

---

## Execution Notes

- All commands use the resolved `TARGET_ROOT` from argument parsing
- CodeSift integration follows `codesift-setup.md` -- use indexed search when
  available, fall back to Grep/Read/Glob when not
- Agent dispatch follows `env-compat.md` -- parallel when supported, sequential
  otherwise
- ORM detection determines which anti-pattern checks to run (DB9 is
  ORM-specific)
- Live analysis (Phase 3) is strictly opt-in and read-only
- Prisma does not use down migrations -- do not flag this as an issue
