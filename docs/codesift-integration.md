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

The `repo` parameter auto-resolves from the working directory, so `list_repos()` is unnecessary in a single-repo session.

**Start with `plan_turn`.** For any non-trivial task, `plan_turn(query="<the task>")` is the preferred entry point: it returns ranked tools, symbols and files for that query and reveals the ones it recommends — in one call. It replaces guessing which of ~150 tools fits.

**A first negative search is not proof of absence.** On MCP hosts most CodeSift tools are *deferred* — present but not yet loaded — so a `select:` lookup can miss them while a keyword search finds them. Retry with a keyword query before concluding CodeSift is unavailable; declaring degraded mode early costs the whole run its analysis quality.

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
| Jump to symbol definition | `go_to_definition` (LSP-backed when available) |
| One call instead of five | `audit_scan` — dead code + patterns + clones + complexity + hotspots |
| Whole-project health (Python) | `python_audit` — 8 checks with a health score |
| Framework audits | `framework_audit` (Next.js), `analyze_hono_app`, `astro_audit`, `nest_audit` |
| Get function return/param types | `get_type_info` (LSP hover) |
| Cross-file rename | `rename_symbol` (type-safe, updates imports) |
| Find unused exports | `find_dead_code` |
| Detect anti-patterns | `search_patterns` (empty-catch, etc.) |
| Git churn hotspots | `analyze_hotspots` |
| Find past conversation about code | `find_conversations_for_symbol` |
| Search conversation history | `search_conversations` |

**Prefer the compound tools.** `audit_scan` replaces five separate calls with one consistent
snapshot of the index; the same applies to `python_audit` and the framework audits.

### After editing files

Skills that modify files call `index_file(path)` after each edit to keep the CodeSift index current. This takes ~9ms per file. The full `index_folder` (3-8 seconds) is never used for single-file updates.

## Two traps worth knowing

**A stale index answers confidently with old data.** If `index_file` returns `skipped=true`, or an
outline still shows the pre-edit structure after an edit you confirmed on disk, the index is stale.
Do NOT loop on `index_file` and do NOT escalate to a full `index_folder` — verify on disk
(`wc -l`, a bounded `Read`) and record the check as degraded. A line count quoted back to you in a
hook message comes from the index and can be stale for the same reason.

**The hooks can block the fallback.** `codesift setup claude --hooks` installs precheck hooks that
redirect `Read` on large files and `grep`/`rg`/`find` to CodeSift. If the MCP server is offline
while those hooks stay active, the prescribed fallback is exactly what they refuse and the run
deadlocks. Use what the hooks never intercept: `python3 -c` with `re`, `git grep`, `git ls-files`,
and bounded `Read` with `offset`/`limit`.

Full operational detail — the version skills actually load — is in
[`../shared/includes/codesift-setup.md`](../shared/includes/codesift-setup.md).

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
| `go_to_definition` | `search_symbols` + guess | Less precise jump |
| `get_type_info` | Read file + parse manually | Slower |
| `rename_symbol` | Manual Edit in each file | Error-prone, misses imports |
| `search_conversations` | Not possible | No conversation history access |
| `find_conversations_for_symbol` | Not possible | No cross-reference |

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
