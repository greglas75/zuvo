# CodeSift Integration

## What is CodeSift

[CodeSift](https://github.com/nicobailey/codesift-mcp) is an MCP (Model Context Protocol) server that provides semantic code search, call chain tracing, complexity analysis, and other code intelligence features. It indexes your codebase and exposes tools that return precise results with fewer tokens than raw grep/read operations.

Zuvo uses CodeSift for deep code exploration across skills. It is optional -- Zuvo works without it in degraded mode -- but it significantly improves analysis quality and reduces token usage.

## How Zuvo uses CodeSift

### Discovery at skill start

Every skill that analyzes code begins with:

```
ToolSearch(query="codesift", max_results=20)
```

If CodeSift tools are found, the skill initializes with `list_repos()` (called once per session, never repeated) to get the repo identifier.

If CodeSift is not found, the skill falls back to built-in tools (Grep, Glob, Read) and notifies the user once:

> CodeSift not available. Running in degraded mode -- code exploration will be less thorough. Install codesift-mcp for full analysis capabilities.

### Per-agent usage

When skills dispatch sub-agents, each agent receives the CodeSift availability status and repo identifier. Agents use CodeSift tools directly:

| Agent task | CodeSift tool used |
|------------|-------------------|
| Find relevant code for blast radius | `impact_analysis`, `find_references` |
| Understand a module's structure | `get_file_outline`, `assemble_context` |
| Trace a function's callers/callees | `trace_call_chain` |
| Find similar/duplicate code | `find_clones` |
| Rank files by complexity | `analyze_complexity` |
| Discover architectural modules | `detect_communities` |
| Trace HTTP route to handler | `trace_route` |
| Search by meaning (not keyword) | `codebase_retrieval` with `type: "semantic"` |
| Batch multiple queries | `codebase_retrieval` with mixed query types |

### After editing files

Skills that modify files call `index_file(path)` after each edit to keep the CodeSift index current. This takes ~9ms per file. The full `index_folder` (3-8 seconds) is never used for single-file updates.

## Degraded mode without CodeSift

When CodeSift is unavailable, skills fall back to built-in tools with reduced capabilities:

| CodeSift tool | Fallback | What you lose |
|---------------|----------|---------------|
| `search_text` | Grep | Nothing significant |
| `search_symbols` | Grep for function/class names | Less precise, more noise |
| `detect_communities` | Glob + directory analysis | No module boundary detection |
| `assemble_context` | Read key files manually | Lower coverage, higher token cost |
| `find_clones` | Skipped | No duplication analysis |
| `analyze_complexity` | Skipped | No complexity ranking |
| `trace_call_chain` | Skipped | No call graph |
| `trace_route` | Grep for route + manual tracing | Slower, misses indirect handlers |
| `impact_analysis` | Grep for imports of changed files | No transitive dependency detection |
| `analyze_hotspots` | Skipped | No git churn analysis |

Skills still produce useful output in degraded mode, but analysis depth is reduced. Audit skills lose their advanced analysis capabilities (duplication detection, complexity ranking, call chain tracing), and pipeline agents have less context to work with.

## Installing codesift-mcp

```bash
npm install -g codesift-mcp
```

Then add it to your Claude Code MCP configuration. See the [codesift-mcp README](https://github.com/nicobailey/codesift-mcp) for setup instructions specific to your environment.

Once installed, CodeSift is automatically discovered by Zuvo skills via `ToolSearch`. No additional configuration in Zuvo is needed.

## Token budget guidance

CodeSift reduces token usage compared to raw Grep/Read operations:

| Category | CodeSift | Grep fallback | Savings |
|----------|----------|---------------|---------|
| Text search | ~49K tokens | ~73K tokens | -33% |
| File structure | ~37K tokens | ~45K tokens | -20% |
| Relationship analysis | ~52K tokens | ~61K tokens | -14% |

### Controlling token usage per call

- **`search_symbols` detail levels:** `compact` (~15 tok/result) for discovery, `standard` (~170 tok/result) for reading, `full` (~300 tok/result) for editing
- **`token_budget` parameter:** Set a ceiling on any search call (e.g., `token_budget=3000`) instead of guessing `top_k`
- **`file_pattern` parameter:** Restrict search scope to halve token cost (e.g., `file_pattern="*.service.ts"`)
- **`assemble_context` levels:** L0 (full source, ~19 symbols/5K), L1 (signatures, ~56 symbols/5K), L2 (export lists, ~61 files/5K), L3 (directory overview, ~18 dirs/600 tok)
- **`codebase_retrieval` batching:** Combine 3+ queries into one call instead of sequential requests

### Anti-patterns to avoid

- Calling `list_repos` more than once per session (result does not change)
- Using `index_folder` after editing one file (use `index_file` instead)
- Using `assemble_context` L0 when you only need to understand flow (use L1)
- Sequential `search_text` calls that could be batched via `codebase_retrieval`
- `search_symbols` without `file_pattern` when the scope is known
