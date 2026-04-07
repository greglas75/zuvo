# Knowledge Prime

Load project-specific knowledge before starting work. If no knowledge base exists, skip silently.

## When to use

Called by skills at the start of work, before any implementation or analysis. The skill passes:
- `WORK_TYPE` — `planning` | `implementation` | `review` | `research`
- `WORK_KEYWORDS` — comma-separated keywords from the task description (e.g., `"auth,token,session"`)
- `WORK_FILES` — space-separated file paths or globs that will be touched (optional)

## Protocol

### Step 1: Check for knowledge base

```
Glob("knowledge/*.jsonl")
```

If no files found: print `[KNOWLEDGE] No knowledge base found — starting fresh.` and exit. Do NOT create the directory.

### Step 2: Load JSONL files

Read all existing files in `knowledge/`:

| File | Contains |
|------|----------|
| `knowledge/patterns.jsonl` | Reusable best practices |
| `knowledge/gotchas.jsonl` | Common pitfalls and surprises |
| `knowledge/decisions.jsonl` | Architectural choices with rationale |
| `knowledge/anti-patterns.jsonl` | Approaches to avoid |
| `knowledge/codebase-facts.jsonl` | Implementation quirks specific to this codebase |
| `knowledge/api-behaviors.jsonl` | External API quirks and integration behaviors |

Parse each line as a JSON object. Skip malformed lines (log: `[KNOWLEDGE] Skipped malformed entry in <file>`).

### Step 3: Filter and rank

For each entry, compute a relevance score:

- `+3` if any `tags[]` value matches a word in `WORK_KEYWORDS`
- `+2` if any `affectedFiles[]` glob matches a file in `WORK_FILES`
- `+1` if `confidence == "high"`
- `+0` for `confidence == "medium"`, `-1` for `confidence == "low"`
- `-2` if `usageCount == 0` and `confidence == "low"` (unvalidated low-confidence — deprioritize)

Keep entries with score >= 1. Sort by score descending. Cap at 20 total entries across all files.

If no entries score >= 1: print `[KNOWLEDGE] Knowledge base exists but no relevant entries for this task.` and exit.

### Step 4: Output

Print a structured block before starting work:

```
KNOWLEDGE PRIMED (N entries)
──────────────────────────────

MUST FOLLOW (anti-patterns, high-confidence gotchas):
  • [fact] — [recommendation] (source: [provenance[0].reference])

GOTCHAS:
  • [fact] — [recommendation]

PATTERNS:
  • [fact] — [recommendation]

DECISIONS (architectural choices):
  • [fact] — [recommendation]

CODEBASE FACTS:
  • [fact] — [recommendation]

API BEHAVIORS:
  • [fact] — [recommendation]
──────────────────────────────
```

Only print sections that have entries. Skip empty sections.

### Step 5: Increment usageCount

For each entry that was included in the output, increment its `usageCount` by 1 and update `updatedAt` to today's date. Write the updated entry back to its JSONL file (rewrite the line in place).

**Rewrite protocol:** Read the full file into memory, update matching lines (by `id`), write back the full file. JSONL files are small — full rewrite is safe.
