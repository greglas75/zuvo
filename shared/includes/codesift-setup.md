# CodeSift Setup

> Discover, initialize, and fall back to built-ins when CodeSift is unavailable.
> **Tool usage rules are in `~/.claude/rules/codesift.md` (global memory) — not repeated here.**
> **Audit skills consuming this include must also emit the Tool Availability Block — see end of file.**

## Step 1: Discover Availability

At the start of any skill that analyzes code, check whether CodeSift MCP tools are available.

- **Claude Code / Codex / Cursor with MCP:** look for `mcp__codesift__*` tools in the tool list.
- **Deferred-tool MCP hosts:** if `mcp__codesift__*` tools appear under "deferred tools" in the system reminder rather than directly in the tool list, run Step 2.5 (Deferred Tool Preload) before any other CodeSift call. Calling deferred tools without preload returns `InputValidationError`.
- **If absent (not in tool list and not in deferred list):** CodeSift is unavailable. Skip to Degraded Mode below.

Do not call `discover_tools` just to check availability — inspect the tool list directly.

## Step 2: Initialize (Once Per Session)

1. Repo auto-resolves from CWD — **skip `list_repos`** unless operating on multiple repos
2. If unsure whether project is indexed: `index_status()` — returns instantly
3. If not indexed: `index_folder(path=<project_root>)` — creates the index
4. After editing any file during a skill run: `index_file(path="/absolute/path")` (~9ms)

**Never** use `index_folder` for single-file updates. Never call `list_repos` more than once per session.

### Recovery When a Query Fails

If a CodeSift query fails with a repo/index error such as `Repository not found`, `not indexed`, or equivalent:

1. Run `index_status()` immediately.
2. If the repo is not indexed, run `index_folder(path=<project_root>)`.
3. Retry the original CodeSift query **once**.
4. If the retry still fails, print a degraded-mode note and fall back to native tools.

Do not abandon CodeSift after the first repo/index failure when initialization has not yet been attempted.

If CodeSift succeeds at indexing/init but later queries fail with `Transport closed` (or equivalent transport/session teardown), stop retrying CodeSift for the rest of the current skill run. Print one degraded-mode note and switch to native tools immediately.

## Step 2.5: Deferred Tool Preload (MCP-host environments)

Some MCP hosts (Claude Code, Codex Plugins) defer tool schemas to keep the system prompt small. When `mcp__codesift__*` tools appear under "deferred tools" in the session-start system reminder rather than directly in the tool list, calling them produces `InputValidationError`.

**Detect:** scan the session-start banner for any `mcp__codesift__*` name appearing in a deferred-tools list. The preload mechanism described below uses Claude Code's `ToolSearch`; on other MCP hosts use the host's equivalent tool-schema preload mechanism that honors a `select:`-style allowlist. If no such mechanism exists on the host, fall through to Degraded Mode.

**If deferred:** run stack-aware preload BEFORE Step 3. Issue exactly ONE `ToolSearch(query="select:...")` call with the union of:

1. Tools from the calling skill's `codesift_tools.always` list (frontmatter)
2. Tools from `codesift_tools.by_stack[<key>]` for every key matched against the detected stack

If the calling skill has no `codesift_tools` manifest, fall back to the legacy 6-tool preload:

```
ToolSearch(query="select:mcp__codesift__search_text,mcp__codesift__get_file_tree,mcp__codesift__search_symbols,mcp__codesift__get_symbol,mcp__codesift__index_status,mcp__codesift__plan_turn")
```

### Stack detection (one-time per session)

Before issuing the ToolSearch, run `analyze_project()` ONCE. It returns:

```json
{
  "stack": {
    "language": "javascript|python|php|kotlin|...",
    "framework": "nextjs|django|astro|nestjs|hono|...|null",
    "test_runner": "pytest|jest|vitest|...|null",
    "package_manager": "npm|pnpm|pip|composer|...",
    "monorepo": true|false
  },
  "dependency_health": { ... }
}
```

### Match `by_stack` keys against detected stack

For each key in the calling skill's `codesift_tools.by_stack`, include its tool group if ANY of the following match:

1. Key equals `analyze_project.stack.language` (e.g. `typescript`, `javascript`, `python`, `php`, `kotlin`)
2. Key equals `analyze_project.stack.framework` (e.g. `nextjs`, `django`, `astro`)
3. Key equals `analyze_project.stack.test_runner` (e.g. `pytest`, `jest`)
4. Key appears in the project's dependency manifest:
   - `package.json` (deps + devDeps): match keys like `react`, `prisma`, `drizzle`, `hono`, `vitest`
   - `composer.json` (require): match keys like `yii`, `laravel`, `symfony`
   - `pyproject.toml` / `requirements.txt`: match keys like `django`, `fastapi`, `celery`, `flask`, `pytest`
   - **Monorepo (`stack.monorepo === true`):** scan ALL workspace package.json files (`apps/*`, `packages/*`, plus paths from `workspaces` field) — not just root. Otherwise auditing a workspace dir with a different framework than root produces the wrong preload.
5. Key matches a database driver in deps. Postgres signal includes any of: `pg`, `psycopg2`, `psycopg2-binary`, `psycopg`, `postgresql`, `postgres`, `postgres-js`, `@prisma/adapter-pg`, `@neondatabase/serverless`, `@vercel/postgres`. MySQL: `mysql`, `mysql2`, `pymysql`, `mysqlclient`. SQLite: `sqlite3`, `better-sqlite3`, `aiosqlite`.
6. **Manifest-implies-language.** Match the language-level group based on the presence of a language-specific dep manifest. This handles three real-world scenarios:
   (a) hybrid projects where one language masks another (Yii2 backend + React frontend, Django backend + React SPA),
   (b) Android/JVM repos where JS tooling files confuse `analyze_project` (returns `language=javascript` for a Kotlin app), and
   (c) pure-language library projects where `analyze_project` may fail or return `partial` (a pure-Python MCP server, a pure-PHP Composer package).
   Triggers (presence-only — language manifests are overwhelmingly used for that language; tooling-only false positives are vanishingly rare):
   - **`composer.json` present** → implicitly match the `php` key, even if `stack.language` is `javascript`/`typescript`/`null`.
   - **`pyproject.toml` or `requirements.txt` present** → implicitly match the `python` key.
   - **`build.gradle.kts` or `build.gradle` present** (Gradle build script — Kotlin or Groovy DSL) → implicitly match the `kotlin` key.
   Rationale: rule #4 already handles the *framework* group (e.g. `yii`, `django`) for these cases, but the language-level group (`php_project_audit`, `python_audit`, `kotlin` Compose/Hilt/Room toolchain) was unreachable for hybrid, misclassified, or pure-language projects without a web-framework dep. This rule closes that gap symmetrically across all three languages — no asymmetric "framework dep required" caveats.

Take the UNION of all matched groups + `always`. Build one `select:` query with all tool names prefixed `mcp__codesift__`. Issue ONE ToolSearch.

### Worked example

Calling skill `code-audit` has manifest with `always` = 17 tools and `by_stack` = 13 groups.

Project is Next.js + React + Prisma + PostgreSQL + Vitest (TypeScript):
- `analyze_project` returns `language=typescript, framework=nextjs, test_runner=vitest`
- `package.json` deps include: `react`, `next`, `@prisma/client`, `pg`
- Matched groups: `typescript` (language), `nextjs` (framework), `react` (deps), `prisma` (deps), `postgres` (pg driver)
- Final preload: 17 always + 1 typescript + 2 nextjs + 3 react + 1 prisma + 1 postgres = **25 tools**
- Skipped: nestjs, astro, hono, javascript, python, django, fastapi, php, yii, sql (~16 tools)

Project is Django + Celery + pytest + PostgreSQL:
- `analyze_project` returns `language=python, framework=django, test_runner=pytest`
- `pyproject.toml` deps include: `django`, `celery`, `pytest`, `psycopg2`
- Matched groups: `python` (language), `django` (framework + deps), `postgres` (psycopg2)
- Final preload: 17 always + 2 python + 3 django + 1 postgres = **23 tools**

### Output format

After preload, mark all loaded tools as `DEFERRED-PRELOADED` in the Tool Availability Block. Print a one-line trace before continuing:

```
[CodeSift preload] stack=<lang>/<framework>/<test_runner>, groups=<N matched>, tools=<N total>
```

### Constraints

- Run preload at most ONCE per session by default — gather all known tool needs into the initial UNION-based `select:` query.
- **Mid-run preload (escape valve):** long-running skills (audits, multi-phase pipelines) may genuinely discover a niche-tool need only at a phase boundary that was not predictable at session start. A second `ToolSearch` is permitted, but only:
  - At a phase boundary (not opportunistically).
  - For tools genuinely required by the upcoming phase (not "just in case").
  - When the missing tool was not available in the calling skill's `codesift_tools` manifest at session start.
  - Hard cap: **2 `ToolSearch` calls per session**. A third indicates a planning gap — surface it as `[CodeSift preload exceeded 2 calls]` rather than silently issuing it.
- If `ToolSearch` itself is unavailable: skip preload and treat CodeSift as unavailable (degraded mode). Do not attempt direct calls — they fail with `InputValidationError`.
- If `analyze_project` fails or returns `status=partial` with all-null stack: do NOT skip `by_stack` matching wholesale. Rules #4 (dep manifest), #5 (DB driver), and #6 (manifest-implies-language) operate directly on filesystem manifests (`package.json`, `composer.json`, `pyproject.toml`, `requirements.txt`, `build.gradle.kts`/`build.gradle`) and remain fully applicable without a stack object. Only rules #1 (language), #2 (framework), and #3 (test_runner) get skipped because they consume `analyze_project.stack.{language,framework,test_runner}` directly. If NO manifest files are readable either (e.g. truly markdown-only repo): preload only `always` tools.
- Sub-agents inherit parent's preload state. Do NOT re-run preload in sub-agents.

## Step 3: Tool Usage

See `~/.claude/rules/codesift.md` (loaded into memory every session) for the complete task → tool mapping, hint codes, and ALWAYS/NEVER rules. That file is authoritative. Do not duplicate its content here.

Framework-specific tools (astro_*, nextjs_route_map, analyze_hono_app, trace_middleware_chain) — prefer these over generic search when the project's stack matches.

## Degraded Mode (CodeSift Unavailable)

Fall back to built-ins:

| CodeSift tool | Fallback | What you lose |
|---------------|----------|---------------|
| `search_text` / `search_symbols` | Grep | Nothing significant |
| `search_patterns` | Grep with regex | No built-in pattern library |
| `scan_secrets` | Grep for API keys | ~1100 fewer rules, more false negatives |
| `find_clones` / `analyze_complexity` / `analyze_hotspots` | **Skip** | No duplication/complexity/churn ranking |
| `trace_call_chain` / `trace_route` / `impact_analysis` | Grep + manual tracing | No call graph, slower |
| `find_dead_code` / `find_unused_imports` | Skip or manual grep | No automated detection |
| `analyze_project` | Manual file scanning | No auto-detected stack profile |
| `assemble_context` | Read files manually | Lower coverage, higher token cost |

### Text-Stub Languages

When `get_extractor_versions()` shows the project's language as text-stub only (kotlin, swift, dart, scala, php), **do NOT call** symbol-based tools — they return empty silently: `search_symbols`, `get_file_outline`, `get_symbol`, `find_references`, `trace_call_chain`.

These still work on text-stub languages: `search_text`, `get_file_tree`, `scan_secrets`, `analyze_project`.

**PHP specifically:** check `get_extractor_versions()` before symbol tools. If text-stub, fall back to `search_text`/Grep for Yii2/Laravel patterns like `::find()`, `->all()`, `->batch()`, `->with()`, `Yii::$app->cache`, `TagDependency`, `DbTarget`.

### User Notification

The first time CodeSift is unavailable in a session, notify once:

> CodeSift not available. Running in degraded mode — install `codesift-mcp` for full analysis.

Do not repeat the warning after the first notification.

## Tool Availability Block (REQUIRED in audit reports)

Audit skills MUST emit this block at the top of their report (after the audit title, before findings). Copy the template; replace status values. This is what makes degraded runs auditable after the fact.

```markdown
## Tool Availability

| Tool / Index       | Status                            | Used For   |
|--------------------|-----------------------------------|------------|
| CodeSift index     | OK (N files / N symbols)          | <dim list> |
| analyze_complexity | OK                                | <dim list> |
| analyze_hotspots   | OK                                | <dim list> |
| scan_secrets       | OK                                | <dim list> |
```

**Status vocabulary** (use exactly these strings — downstream grep-based gates depend on them):

- `OK` — tool ran, returned non-empty result
- `OK (N files / N symbols)` — index status with counts
- `DEFERRED-PRELOADED` — was deferred at session start, preloaded via ToolSearch (Step 2.5)
- `NOT INDEXED` — index missing at session start; ran `index_folder` to recover
- `TRANSPORT-CLOSED` — MCP transport died mid-run; switched to native fallback
- `EMPTY-RESULT (<fallback>)` — tool returned empty on a non-empty repo (anomaly); used `<fallback>`
- `UNAVAILABLE` — CodeSift MCP not present in tool list at all

**One status per row.** Do NOT concatenate values with `|` inside a cell — that breaks downstream grep parsing of acceptance gates. If a tool was unavailable for one dimension and `OK` for another, emit two separate rows scoped by dimension:

```markdown
| analyze_hotspots (SA13)   | EMPTY-RESULT (git fallback used)  | SA13       |
| analyze_hotspots (other)  | OK                                | <dims>     |
```
