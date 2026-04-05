# CodeSift Setup

> How to discover, initialize, and use CodeSift for code analysis in Zuvo skills.

## Step 1: Discover Availability

At the start of any skill that analyzes code, check whether CodeSift MCP tools are available in the current environment.

- **Claude Code / environments with tool discovery:** look for `codesift`, then the legacy name `jcodemunch`.
- **Codex:** if CodeSift is configured, use the `mcp__codesift__*` tools directly.
- **If neither path is available:** CodeSift is unavailable. Skip to the Degraded Mode section below.

## Step 2: Initialize (Once Per Session)

1. Call `list_repos()` to check if the project is already indexed
2. Note the repo identifier (typically `"local/<folder-name>"`) for all subsequent calls
3. If the project is not in the list: `index_folder(path=<project_root>)` to create the index
4. Never call `list_repos()` again in the same session — the result does not change

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
| Git churn hotspots | `analyze_hotspots(repo, since_days=90)` | git log + manual analysis |
| Find unused exports | `find_dead_code(repo, file_pattern)` | Manual grep for references |
| Rename a symbol across all files | `rename_symbol(repo, symbol_name, new_name)` | Edit each file manually |

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

**ALWAYS:**
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

**NEVER:**
- `index_folder` if repo already in list_repos — file watcher auto-updates
- `list_repos` more than once per session
- Manual Edit multiple files for rename — use rename_symbol
- Read entire file for return type — use get_type_info
- index worktrees — use the main repo index

## Degraded Mode (CodeSift Unavailable)

When CodeSift is not available, fall back to built-in tools:

| CodeSift tool | Fallback | What you lose |
|---------------|----------|---------------|
| `search_text` | Grep | Nothing significant |
| `search_symbols` | Grep for function/class names | Less precise, more noise |
| `detect_communities` | Glob + directory structure analysis | No module boundary detection |
| `assemble_context` | Read key files manually | Lower coverage, higher token cost |
| `find_clones` | Skip entirely | No duplication analysis |
| `analyze_complexity` | Skip entirely | No complexity ranking |
| `trace_call_chain` | Skip entirely | No call graph |
| `trace_route` | Grep for route path + manual tracing | Slower, misses indirect handlers |
| `impact_analysis` | Grep for imports of changed files | No transitive dependency detection |
| `search_patterns` | Grep with regex patterns | Less coverage, no built-in pattern library |
| `analyze_hotspots` | Skip entirely | No churn analysis |

The first time CodeSift is unavailable in a session, notify the user:

> CodeSift not available. Running in degraded mode — code exploration will be less thorough. Install codesift-mcp for full analysis capabilities.

Do not repeat this warning after the first notification.
