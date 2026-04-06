---
name: db-audit
description: >
  Database performance and safety audit. 60+ checks across 12 dimensions
  (DB1-DB12): query patterns, indexes, schema design, connections, transactions,
  migrations, caching, query optimization, ORM anti-patterns, observability,
  data lifecycle, and DB security. Code-level checks for all ORMs. Optional
  live analysis via PostgreSQL or MySQL connection.
  Switches: zuvo:db-audit full | [path] | [file] | --schema | --queries | --connections | --live <conn>
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
  1. ../../shared/includes/codesift-setup.md   -- [READ | MISSING -> STOP]
  2. ../../shared/includes/env-compat.md        -- [READ | MISSING -> STOP]
  3. ../../rules/cq-patterns.md                 -- [READ | MISSING -> STOP]
  4. ../../shared/includes/run-logger.md        -- [READ | MISSING -> STOP]
```

If any file is MISSING, STOP. Do not proceed from memory.

---

## Argument Parsing

| Token | Behavior |
|-------|----------|
| _(empty)_ or `full` | All 12 dimensions across the project |
| `[path]` | Scope to a directory or module |
| `[file]` | Deep audit of a single file (all applicable dimensions) |
| `--schema` | Schema analysis only (DB2, DB3, DB6) |
| `--queries` | Query pattern analysis only (DB1, DB8, DB9) |
| `--connections` | Connection and pool management only (DB4) |
| `--live <conn>` | Enable Phase 3: connect to the database for EXPLAIN and statistics |

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

### 0.1 ORM Detection

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

| Signal | Engine |
|--------|--------|
| `postgresql` in connection string or schema provider | PostgreSQL |
| `mysql` in connection string or provider | MySQL |
| `sqlite` in provider | SQLite |
| `mongodb` in provider or `mongoose` | MongoDB |

### 0.3 Deployment Detection

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
ORM:     [Prisma / TypeORM / Drizzle / Django / SQLAlchemy / Raw SQL]
Engine:  [PostgreSQL / MySQL / SQLite / MongoDB]
Deploy:  [Serverless / Container / Traditional]
Scope:   [full / path / file]
Dims:    [DB1-DB12 / subset]
------------------------------------
```

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

**ORM-specific sources:**
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

## Phase 2: Code-Level Analysis (DB1-DB12)

### Agent Dispatch

Refer to `env-compat.md` for the dispatch pattern.

**When parallel dispatch is available:**

| Agent | Dimensions | Focus |
|-------|-----------|-------|
| Schema Analyst | DB2, DB3, DB6 | Schema design + migration safety |
| Query Scanner | DB1, DB5, DB8, DB9 | Code-level query patterns |
| Infrastructure Auditor | DB4, DB7, DB10, DB11, DB12 | Connections, cache, observability, security |

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
| Missing index | Table known to be small (< 1000 rows, documented) |
| No indexes in ORM | External index scripts found (use external inventory for scoring) |
| No connection pool | Using managed service that pools for you (Supabase, PlanetScale) |
| Raw SQL flagged | Uses tagged template `$queryRaw` (safe, parameterized) |

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
| **Total** | | **[N]** | **[M]** | |

## Critical Gate Status
[DB1, DB4, DB5, DB12 -- PASS/FAIL per gate]

## Model Inventory
[From Phase 1]

## Findings (sorted by severity)
[Per finding: ID, severity, dimension, file:line, description, fix]

## Cross-Cutting Patterns
[Compound patterns found]

## Top 5 Action Items
[Prioritized by Impact / Effort]

## Backlog Entries
[/backlog add commands for HIGH+ findings]
```

### Report Validation

After writing, verify:
- Dimension scores sum to total in Executive Summary
- Finding counts match Executive Summary
- All models from inventory are addressed
- Critical gate status is accurate

---

## Phase 6: Next-Step Routing

```
RECOMMENDED NEXT ACTION
------------------------------------
DB1 CRITICAL (N+1)       -> zuvo:refactor [service file]
DB4 no connection pool    -> direct fix (add pool config)
DB2 missing indexes       -> direct migration (add indexes)
DB12 SQL injection        -> /security-audit [path]
DB9 ORM anti-patterns     -> zuvo:refactor [service file]
Multiple dimensions fail  -> zuvo:review [path]
------------------------------------
```

---

## DB-AUDIT COMPLETE

Score: [N] / [MAX] -- [grade]
ORM: [detected] | Engine: [detected]
Dimensions: [N scored] | Critical gates: [PASS/FAIL]
Findings: [N critical] / [N total]
Run: <ISO-8601-Z>	db-audit	<project>	<N-critical>	<N-total>	<VERDICT>	-	<N>-dimensions	<NOTES>	<BRANCH>	<SHA7>

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
