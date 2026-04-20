# CodeSift Setup

> Discover, initialize, and fall back to built-ins when CodeSift is unavailable.
> **Tool usage rules are in `~/.claude/rules/codesift.md` (global memory) — not repeated here.**

## Step 1: Discover Availability

At the start of any skill that analyzes code, check whether CodeSift MCP tools are available.

- **Claude Code / Codex / Cursor with MCP:** look for `mcp__codesift__*` tools in the tool list.
- **If absent:** CodeSift is unavailable. Skip to Degraded Mode below.

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
