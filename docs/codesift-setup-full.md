# CodeSift Setup

> How to discover, initialize, and use CodeSift for code analysis in Zuvo skills.

## Step 1: Discover Availability and Load Tool Schemas

At the start of any skill that analyzes code, check whether CodeSift MCP tools are available in the current environment.

- **Claude Code / environments with tool discovery:** look for `codesift`, then the legacy name `jcodemunch`.
- **Codex:** if CodeSift is configured, use the `mcp__codesift__*` tools directly.
- **If neither path is available:** CodeSift is unavailable. Skip to the Degraded Mode section below.

**Loading tool schemas (REQUIRED before calling any CodeSift tool):**

CodeSift tools may be deferred — calling them without loading their schema first will fail. The loading mechanism differs per platform:

| Platform | How to load CodeSift tools |
|----------|---------------------------|
| **Claude Code** | `ToolSearch("select:mcp__codesift__search_text,mcp__codesift__search_symbols,mcp__codesift__codebase_retrieval,mcp__codesift__search_patterns,mcp__codesift__get_file_outline,mcp__codesift__get_file_tree,mcp__codesift__analyze_project")` |
| **Codex** | MCP tools are available directly as `mcp__codesift__*` — try calling one. If it fails, CodeSift is not configured. |
| **Cursor / Antigravity** | CodeSift typically unavailable — skip to Degraded Mode. |

For **sub-agents** dispatched via the Agent tool (Claude Code only): include the ToolSearch call at the very top of the agent prompt. Sub-agents start with a clean tool list and must load schemas themselves. Adjust the tool list per agent role — only load what the agent needs.

For **hidden tools** (not in the default ListTools), use CodeSift's native discovery on any platform where CodeSift is available:

```
describe_tools(names=["scan_secrets", "ast_query", "review_diff"], reveal=true)
```

## Step 2: Initialize (Once Per Session)

1. Call `get_extractor_versions()` to check language support — if the project's primary language is text-stub only, skip symbol-based tools
2. Call `analyze_project()` to auto-detect stack, framework, and conventions — saves manual file scanning
3. Repo auto-resolves from CWD — only call `list_repos()` if you're in a multi-repo session
4. If the project is not indexed: `index_folder(path=<project_root>)` to create the index

After editing any file during a skill run, update the index immediately:

```
index_file(path="/absolute/path/to/changed-file.ts")
```

This takes ~9ms. Never use `index_folder` for single-file updates (that takes 3-8 seconds).

## Step 3: Tool Selection

Use CodeSift tools instead of built-in search tools. They return more precise results with fewer tokens.

### Text and Symbol Search

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| Find text in files | `search_text(repo, query, file_pattern)` | Grep |
| Find function or class definition | `search_symbols(repo, query, include_source=true)` | Grep for function names |
| Find where a symbol is defined | `go_to_definition(repo, symbol_name)` | search_symbols + manual filtering |
| Get return type or parameter types | `get_type_info(repo, symbol_name)` | Read entire file + parse |
| Find all usages of a symbol | `find_references(repo, symbol_name)` | Grep for imports |
| Trace call chain (callers or callees) | `trace_call_chain(repo, symbol_name, direction, depth)` | Repeated Grep |
| Trace HTTP route to handler and DB | `trace_route(repo, "/api/users/:id")` | Manual search_text + trace chain |

### Structure and Context

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| File outline (exports, functions) | `get_file_outline(repo, file_path)` | Read entire file |
| Directory tree | `get_file_tree(repo, path_prefix, compact=true)` | Glob or ls |
| Read one symbol's source | `get_symbol(repo, symbol_id)` | Read whole file |
| Read multiple symbols at once | `get_symbols(repo, symbol_ids=[...])` | Multiple Read calls |
| Understand a symbol with its imports and siblings | `get_context_bundle(repo, symbol_name)` | get_symbol + search_text + get_file_outline |
| Dense context for many symbols | `assemble_context(repo, query, level)` | Multiple Read calls |
| Discover code modules and clusters | `detect_communities(repo, focus="src")` | get_knowledge_map + guessing |

### Analysis and Quality

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| Blast radius of recent changes | `impact_analysis(repo, since="HEAD~3")` | Manual diff + grep |
| Find copy-paste duplication | `find_clones(repo, min_similarity=0.7)` | Manual comparison |
| Rank files by cyclomatic complexity | `analyze_complexity(repo, top_n=10)` | Manual line counting |
| Find anti-patterns (empty catch, etc.) | `search_patterns(repo, "empty-catch")` | Grep with regex |
| List available built-in patterns | `list_patterns()` | Guessing pattern names |
| Git churn hotspots | `analyze_hotspots(repo, since_days=90)` | git log + manual analysis |
| Find unused exports | `find_dead_code(repo, file_pattern)` | Manual grep for references |
| Find unused imports | `find_unused_imports(repo, file_pattern)` | Grep + manual checking |
| Rename a symbol across all files | `rename_symbol(repo, symbol_name, new_name)` | Edit each file manually |
| Scan for hardcoded secrets | `scan_secrets(min_confidence="medium")` | Manual grep for API keys |
| AST-level structural search | `ast_query(repo, query, language)` | Regex (misses structural patterns) |
| Group functions by AST shape | `frequency_analysis(repo, top_n=30)` | Manual comparison |

### Project Overview and Discovery

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| Detect stack, framework, conventions | `analyze_project()` | Manual file scanning |
| High-level repo outline by directory | `get_repo_outline()` | Glob + manual reading |
| Suggested queries for new repo | `suggest_queries()` | Guessing |
| Check parser/language support | `get_extractor_versions()` | Trial and error |
| Session usage statistics | `usage_stats()` | Estimating |
| Compact session snapshot (~200 tok) | `get_session_snapshot()` | Manual context saving |
| Full session context with evidence | `get_session_context()` | Manual tracking |

### Architecture

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| Discover code modules/clusters | `detect_communities(repo, focus="src")` | get_knowledge_map + guessing |
| Check architecture boundary rules | `check_boundaries(repo, rules=[...])` | Manual import analysis |
| Classify symbol roles (entry/core/dead) | `classify_roles(repo, file_pattern)` | Manual call graph analysis |
| Detect circular dependencies | `find_circular_deps(repo, file_pattern)` | madge / manual analysis |

### Diff and Review

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| 9-check diff analysis (secrets, complexity, etc.) | `review_diff(since="HEAD~1")` | Manual diff review |
| Structural outline of changes | `diff_outline(since="HEAD~3")` | git diff + manual parsing |

### Cross-Repo

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| Search symbols across all repos | `cross_repo_search(query)` | Manual per-repo search |
| Find references across all repos | `cross_repo_refs(symbol_name)` | Manual per-repo grep |

### Conversations (Claude Code history)

| Task | CodeSift tool | Replaces |
|------|--------------|----------|
| Search past conversations in this project | `search_conversations(query)` | Manual memory recall |
| Search across ALL projects | `search_all_conversations(query)` | Manual searching |
| Find conversations about a symbol | `find_conversations_for_symbol(symbol_name, repo)` | Manual searching |
| Index conversation history | `index_conversations()` | N/A |
| Consolidate decisions to MEMORY.md | `consolidate_memories()` | Manual writing |
| Read MEMORY.md | `read_memory()` | Read tool |

### Batch Retrieval

When you need 3 or more pieces of information, batch them into one `codebase_retrieval` call instead of making sequential requests:

```
codebase_retrieval(repo, queries=[
  {"type": "text", "query": "prisma.$transaction", "file_pattern": "*.service.ts"},
  {"type": "symbols", "query": "createOrder"},
  {"type": "file_tree", "path": "src/lib/services"},
  {"type": "semantic", "query": "how does authentication work?"},
  {"type": "references", "symbol_name": "withAuth"},
  {"type": "call_chain", "symbol_name": "processPayment", "direction": "callees"}
], token_budget=10000)
```

Use `type: "semantic"` for conceptual questions where keyword search would miss results.

### assemble_context Compression Levels

Choose the level that matches your need:

| Level | Returns | Typical budget usage | Best for |
|-------|---------|---------------------|----------|
| `L0` | Full source code | ~19 symbols per 5K budget | Editing code, debugging exact logic |
| `L1` | Signatures and docstrings | ~56 symbols per 5K budget | Understanding APIs, reading flow |
| `L2` | File summaries (export lists) | ~61 files per 5K budget | Architecture overview |
| `L3` | Directory-level overview | ~18 dirs per 600 tokens | Orientation in unfamiliar codebase |

Default to `L1` for read-only analysis. Use `L0` only when you need exact source for editing.

### search_symbols Options

- `detail_level="compact"` (~15 tokens per result) — use when you only need locations, not source
- `detail_level="standard"` (~170 tokens per result) — default, includes signature and truncated source
- `detail_level="full"` (~300 tokens per result) — complete function body
- `token_budget=3000` — let CodeSift pack as many results as fit within a token limit
- `file_pattern="*.service.ts"` — restrict search scope, halves token cost

## ALWAYS / NEVER Rules

### Built-in Patterns (for `search_patterns`)

Call `list_patterns()` to verify the current list. Known patterns:

| Pattern name | What it detects | Maps to |
|---|---|---|
| `unbounded-findmany` | findMany without take/limit | CQ7, DB1 |
| `await-in-loop` | Sequential await inside loop (N+1) | CQ17, DB1 |
| `empty-catch` | Empty catch block (swallowed error) | CQ8 |
| `any-type` | Usage of `any` type | CQ1 |
| `console-log` | console.log in production code | CQ13 |
| `no-error-type` | Catch without instanceof Error narrowing | CQ8 |
| `toctou` | Read-then-write without atomic operation | CQ21, DB5 |
| `useEffect-no-cleanup` | useEffect without cleanup return | CQ22 |
| `scaffolding` | TODO/FIXME/HACK markers, placeholder stubs | Tech debt |

**ALWAYS:**
- `analyze_project()` at the start of any audit to detect stack — before manual file scanning
- `get_extractor_versions()` at session start to know which languages have full vs text-stub parser support — skip symbol-based tools for text-stub languages
- `semantic_search` or `codebase_retrieval(type:"semantic")` for conceptual questions
- `trace_route` FIRST for any API endpoint — NEVER multiple search_text + trace_call_chain
- `detect_communities` BEFORE `get_knowledge_map` — NEVER knowledge_map without communities first
- `index_file(path)` after editing — NEVER index_folder (9ms vs 3-8s)
- `include_source=true` on search_symbols
- `get_symbols` (batch) for 2+ symbols — NEVER sequential get_symbol
- Batch 3+ searches into `codebase_retrieval`
- `search_conversations` when encountering error/bug that may have been solved before
- `search_text(ranked=true)` when you need to know WHICH FUNCTION contains a match
- `discover_tools` + `describe_tools` when you need a tool not in ListTools
- `get_session_snapshot()` before long tasks or when approaching 50+ tool calls — survives context compaction
- `list_patterns()` before running `search_patterns` to verify available pattern names

**NEVER:**
- `index_folder` if repo already in list_repos — file watcher auto-updates
- `list_repos` more than once per session — repo auto-resolves from CWD
- Manual Edit multiple files for rename — use rename_symbol
- Read entire file for return type — use get_type_info
- Index worktrees — use the main repo index
- Call symbol-based tools (search_symbols, get_file_outline, trace_call_chain, find_references) on text-stub languages (kotlin, swift, dart, etc.) — they return empty results silently

## Degraded Mode (CodeSift Unavailable)

When CodeSift is not available, fall back to built-in tools:

| CodeSift tool | Fallback | What you lose |
|---------------|----------|---------------|
| `analyze_project` | Manual file scanning (Glob + Read) | No auto-detected stack profile |
| `search_text` | Grep | Nothing significant |
| `search_symbols` | Grep for function/class names | Less precise, more noise |
| `search_patterns` | Grep with regex patterns | Less coverage, no built-in pattern library |
| `scan_secrets` | Grep for API key patterns | ~1100 fewer rules, more false negatives |
| `detect_communities` | Glob + directory structure analysis | No module boundary detection |
| `assemble_context` | Read key files manually | Lower coverage, higher token cost |
| `find_clones` | Skip entirely | No duplication analysis |
| `analyze_complexity` | Skip entirely | No complexity ranking |
| `trace_call_chain` | Skip entirely | No call graph |
| `trace_route` | Grep for route path + manual tracing | Slower, misses indirect handlers |
| `impact_analysis` | Grep for imports of changed files | No transitive dependency detection |
| `analyze_hotspots` | Skip entirely | No churn analysis |
| `review_diff` | Manual diff review | No automated 9-check analysis |
| `ast_query` | Grep (regex) | Misses structural patterns |
| `find_dead_code` | Skip or manual grep | No automated dead export detection |
| `find_unused_imports` | Skip | No automated unused import detection |

### Text-Stub Degradation (Parser Unavailable for Language)

When `get_extractor_versions()` shows the project's language as text-stub only (kotlin, swift, dart, scala, etc.), these tools still work:

- `search_text`, `get_file_tree`, `scan_secrets`, `search_conversations` — text-based, no parser needed
- `analyze_project` — framework detection works for all languages

These tools return empty and should NOT be called:

- `search_symbols`, `get_file_outline`, `get_symbol`, `find_references`, `trace_call_chain`

The first time CodeSift is unavailable in a session, notify the user:

> CodeSift not available. Running in degraded mode — code exploration will be less thorough. Install codesift-mcp for full analysis capabilities.

Do not repeat this warning after the first notification.
