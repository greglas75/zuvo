# Knowledge Prime

Load project-specific knowledge before starting work. If no knowledge base exists, skip gracefully (one-line log, no error).

## When to use

Called by skills at the start of work, before any implementation or analysis. The skill passes:
- `WORK_TYPE` — `planning` | `implementation` | `review` | `research`
- `WORK_KEYWORDS` — comma-separated keywords from the task description (e.g., `"auth,token,session"`). Matching is case-insensitive — normalize both keywords and tag values to lowercase before comparing.
- `WORK_FILES` — newline-separated file paths or globs that will be touched (optional — if absent, ranking uses tags and confidence only). Paths with spaces are not supported — use paths without spaces or glob patterns instead.

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

Parse each line as a JSON object. For malformed lines, log and skip:
```
[KNOWLEDGE] Preserved malformed line N in knowledge/<file>.jsonl — skipped for parsing
```
Never delete or overwrite malformed lines. They may contain data in an unknown schema version — preserve them in the file unchanged.

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

**affectedFiles matching** uses path-based glob evaluation (e.g., `src/auth/**` matches `src/auth/token.ts`). It is NOT substring matching — `auth` alone does not match `src/authentication/service.ts` unless the glob explicitly covers it.

**`timesSurfaced` does NOT affect score.** Frequent surfacing is not a quality signal — only `confidence` (from provenance) and relevance determine ranking.

Keep entries with score >= 1. Sort by score descending within each type group. **Tiebreaker:** when two entries score equally, prefer the more specific one using this order:
1. Symbol-scoped (references a named function, class, or variable)
2. File-scoped (references a specific file path)
3. Path-scoped (references a directory or glob pattern)
4. Tag-only generic (no file/symbol reference)

If two entries are equally specific at the same level, prefer the newer one (higher `updatedAt`).

### Step 4: Select entries (cap at 10 total)

Apply per-section caps after filtering:

| Section | Types | Max entries |
|---------|-------|-------------|
| MUST AVOID | `anti-pattern`, high-confidence `gotcha` (`confidence == "high"`) | 3 |
| GOTCHAS | `gotcha` (remaining) | 2 |
| DECISIONS | `decision` | 2 |
| CODEBASE FACTS | `codebase-fact`, `api-behavior` | 2 |
| PATTERNS | `pattern` | 1 |

Total cap: **10 entries**. Within each section, take highest-scoring entries first.

**Conflict detection:** If an `anti-pattern` and a `pattern` are both **actually selected for output** (within their section caps) AND describe the same code construct (same symbol, same file pattern, same operation), surface both — anti-pattern first — with a note:
```
⚠ Conflict: anti-pattern and pattern both apply to <topic>. Anti-pattern takes precedence.
```
If the anti-pattern is a narrower exception to a broader pattern (e.g., "use X" generally, but "never use X for Y case"), phrase the note as an exception rather than a full contradiction:
```
⚠ Exception: anti-pattern narrows the above pattern — avoid <topic> specifically when <condition>.
```
Only flag conflicts between entries that appear in the final output. Do not flag entries that scored but were cut by section caps, or entries that didn't score at all.

### Step 5: Output

Print a structured block before starting work:

```
KNOWLEDGE PRIMED (N entries)
──────────────────────────────

MUST AVOID (anti-patterns + high-confidence gotchas):
  • [fact] — [recommendation]
    (source: [provenance[-1].reference or "unknown"], confidence: [high/medium/low])

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

`provenance[-1]` = the most recent provenance record (last in array). The array is chronological — newest is last. If `provenance` is missing or empty, print `source: unknown`.

Anti-patterns always appear before patterns in the same topic area. If a conflict note applies, print it inline.

### Step 6: Increment timesSurfaced

For each entry included in the output, increment `timesSurfaced` by 1. Do NOT modify `updatedAt`.

`updatedAt` changes only on curate merge, fact correction, or entry edit — never on prime surfacing. Updating it here would corrupt the recency signal: an entry shown often would appear "fresh" even if its knowledge is stale.

**Rewrite protocol:**
1. Read the full file into memory.
2. Parse each line. For lines matching an included entry (by `id`): increment `timesSurfaced` only.
3. For malformed lines: write them back unchanged (never discard).
4. For unknown fields: preserve them unchanged (schema may have evolved).
5. Write the full file back.
