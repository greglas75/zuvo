# Knowledge Prime

Load project-specific knowledge before starting work. If no knowledge base exists, skip silently.

## When to use

Called by skills at the start of work, before any implementation or analysis. The skill passes:
- `WORK_TYPE` — `planning` | `implementation` | `review` | `research`
- `WORK_KEYWORDS` — comma-separated keywords from the task description (e.g., `"auth,token,session"`)
- `WORK_FILES` — space-separated file paths or globs that will be touched (optional — if absent, ranking uses tags and confidence only)

---

## Protocol

### Step 1: Check for knowledge base

```
Glob("knowledge/*.jsonl")
```

If no files found: print `[KNOWLEDGE] No knowledge base found — starting fresh.` and exit. Do NOT create the directory.

### Step 2: Load JSONL files

Read all existing files in `knowledge/`:

| File | Type tag | Section priority |
|------|----------|-----------------|
| `knowledge/anti-patterns.jsonl` | `anti-pattern` | 1st (highest) |
| `knowledge/gotchas.jsonl` | `gotcha` | 1st (highest) |
| `knowledge/decisions.jsonl` | `decision` | 2nd |
| `knowledge/codebase-facts.jsonl` | `codebase-fact` | 3rd |
| `knowledge/api-behaviors.jsonl` | `api-behavior` | 3rd |
| `knowledge/patterns.jsonl` | `pattern` | 4th (lowest) |

Parse each line as a JSON object. Skip malformed lines and log:
```
[KNOWLEDGE] Skipped malformed line N in knowledge/<file>.jsonl — preserved as-is in file
```
Never delete or overwrite malformed lines. They may contain data in an unknown schema version — preserve them.

### Step 3: Score and filter

For each entry, compute a relevance score:

| Condition | Points |
|-----------|--------|
| Any `tags[]` value matches a word in `WORK_KEYWORDS` | +3 |
| Any `affectedFiles[]` glob matches a file in `WORK_FILES` | +2 |
| `confidence == "high"` | +1 |
| `confidence == "medium"` | +0 |
| `confidence == "low"` | -1 |
| `updatedAt` within last 30 days | +1 (recency bonus) |
| `updatedAt` older than 180 days AND `confidence != "high"` | -1 (staleness penalty) |
| `timesSurfaced == 0` AND `confidence == "low"` | -2 (unvalidated) |

**If `WORK_FILES` is not provided:** skip the affectedFiles check entirely. Do not penalize entries for missing file matches.

**`timesSurfaced` does NOT affect score.** Frequent surfacing is not a quality signal — only `confidence` (from provenance) and relevance determine ranking.

Keep entries with score >= 1. Sort by score descending within each type group.

### Step 4: Select entries (cap at 10 total)

Apply per-section caps after filtering:

| Section | Types | Max entries |
|---------|-------|-------------|
| MUST AVOID | `anti-pattern`, high-confidence `gotcha` | 3 |
| GOTCHAS | `gotcha` (remaining) | 2 |
| DECISIONS | `decision` | 2 |
| CODEBASE FACTS | `codebase-fact`, `api-behavior` | 2 |
| PATTERNS | `pattern` | 1 |

Total cap: **10 entries**. Within each section, take highest-scoring entries first.

**Conflict detection:** If an `anti-pattern` and a `pattern` describe the same code construct (same symbol, same file pattern, same operation), surface both — anti-pattern first — with a note:
```
⚠ Conflict: anti-pattern and pattern both apply to <topic>. Anti-pattern takes precedence.
```

### Step 5: Output

Print a structured block before starting work:

```
KNOWLEDGE PRIMED (N entries)
──────────────────────────────

MUST AVOID (anti-patterns + critical gotchas):
  • [fact] — [recommendation]
    (source: [provenance[0].reference], confidence: [high/medium/low])

GOTCHAS:
  • [fact] — [recommendation]

DECISIONS:
  • [fact] — [recommendation]

CODEBASE FACTS:
  • [fact] — [recommendation]

PATTERNS:
  • [fact] — [recommendation]
──────────────────────────────
```

Only print sections that have entries. Skip empty sections.

Anti-patterns always appear before patterns in the same topic area. If a conflict note applies, print it inline.

### Step 6: Increment timesSurfaced

For each entry included in the output, increment `timesSurfaced` by 1 and update `updatedAt` to today.

**Rewrite protocol:**
1. Read the full file into memory.
2. Parse each line. For lines matching an included entry (by `id`): update `timesSurfaced` and `updatedAt`.
3. For malformed lines: write them back unchanged (never discard).
4. For unknown fields: preserve them unchanged (schema may have evolved).
5. Write the full file back.

`timesSurfaced` tracks how often an entry reaches agents. It does NOT influence `confidence`. Confidence upgrades happen only in Curate, based on independent provenance sources.
