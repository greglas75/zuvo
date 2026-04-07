# Knowledge Curate

Extract learnings from completed work and persist them to the project knowledge base.
Called after work is done — by `zuvo:ship` before commit, by `zuvo:execute` after all tasks complete.

## JSONL Schema

Each entry is a single JSON line:

```json
{
  "id": "<type>-<slug>-<YYYYMMDD>",
  "type": "pattern|gotcha|decision|anti-pattern|codebase-fact|api-behavior",
  "fact": "Clear, actionable statement in present tense.",
  "recommendation": "What to do (or avoid) as a result.",
  "confidence": "high|medium|low",
  "provenance": [{"source": "zuvo:execute|zuvo:ship|human|coderabbit", "reference": "<commit-sha-or-PR>", "date": "<ISO-date>"}],
  "tags": ["keyword1", "keyword2"],
  "affectedFiles": ["src/auth/**", "*.test.ts"],
  "createdAt": "<ISO-8601>",
  "updatedAt": "<ISO-8601>",
  "usageCount": 0
}
```

**Type definitions:**

| Type | When to use |
|------|-------------|
| `pattern` | Reusable approach that worked well |
| `gotcha` | Unexpected behavior or pitfall encountered |
| `decision` | Architectural or technical choice made with rationale |
| `anti-pattern` | Approach that caused problems — avoid it |
| `codebase-fact` | Specific quirk of this codebase (e.g., "UserService caches 5min") |
| `api-behavior` | External API or library quirk (e.g., "Prisma findMany returns [] not null") |

**Confidence:**
- `high` — verified, observed directly, multiple confirmations
- `medium` — single reliable observation
- `low` — suspected but not fully confirmed

## Protocol

### Step 1: Reflect on completed work

Think through what just happened. Ask yourself:

1. What surprised me during this work? *(→ gotcha or codebase-fact)*
2. What pattern did I use that worked well and should be repeated? *(→ pattern)*
3. What did I choose and why — and would I make the same choice again? *(→ decision)*
4. What approach caused problems or had to be changed? *(→ anti-pattern)*
5. What did I learn about an external API or library? *(→ api-behavior)*

**Generalization filter:** Only record things that are:
- Actionable (not just observational)
- Generalizable beyond this specific task
- Non-obvious (don't record "use TypeScript types" — record "this API returns 200 on soft failures")
- Unique (not already in the knowledge base)

Skip anything that is obvious, project-agnostic boilerplate, or only relevant to this one task.

### Step 2: Check for duplicates

```
Glob("knowledge/*.jsonl")
```

If knowledge base exists: read all entries. For each candidate insight, scan existing entries for similarity. Use this rule:

> If an existing entry captures the same core fact (even with different wording), do NOT create a new entry. Instead, increment the existing entry's `usageCount` and add a provenance record.

**Similarity check:** The core fact matches if the behavior/principle described is the same, even if the wording differs. Use your judgment — this is an LLM similarity check, not string matching.

**Merge protocol:** If merging into an existing entry:
- Append to `provenance[]`: `{"source": "<caller>", "reference": "<sha>", "date": "<today>"}`
- Increment `usageCount`
- If new observation adds confidence: upgrade `confidence` (low→medium, medium→high only if this is a second independent confirmation)
- Update `updatedAt`

### Step 3: Write new entries

For each NEW insight (not a duplicate):

1. Generate a unique `id`: `<type>-<2-3-word-slug>-<YYYYMMDD>` (e.g., `gotcha-prisma-null-20260407`)
2. Write as a single JSON line appended to the appropriate file:
   - `pattern` → `knowledge/patterns.jsonl`
   - `gotcha` → `knowledge/gotchas.jsonl`
   - `decision` → `knowledge/decisions.jsonl`
   - `anti-pattern` → `knowledge/anti-patterns.jsonl`
   - `codebase-fact` → `knowledge/codebase-facts.jsonl`
   - `api-behavior` → `knowledge/api-behaviors.jsonl`

3. **Create directory if missing:** `mkdir -p knowledge`
4. Append: one JSON line per entry, no trailing comma, no array wrapper.

### Step 4: Report

Print a curation summary:

```
KNOWLEDGE CURATED
  New entries:    N
  Merged:         N (updated existing entries)
  Skipped:        N (obvious, non-generalizable, or duplicate)

New entries:
  [gotcha] "Prisma findMany returns [] not null on empty result" → knowledge/gotchas.jsonl
  [pattern] "Use factory functions for all test mocks" → knowledge/patterns.jsonl

Merged:
  [pattern] "Constructor DI for all services" — confidence upgraded medium→high
```

If nothing was learned: print `KNOWLEDGE CURATED: No generalizable insights extracted from this session.` This is acceptable — not every task produces new knowledge.
