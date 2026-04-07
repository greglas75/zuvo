# Knowledge Curate

Extract learnings from completed work and persist them to the project knowledge base.
Called after work is done — by `zuvo:ship` before commit, by `zuvo:execute` after all tasks complete.

---

## JSONL Schema

Each entry is a single JSON line:

```json
{
  "id": "<type>-<slug>-<YYYYMMDD>",
  "type": "pattern|gotcha|decision|anti-pattern|codebase-fact|api-behavior",
  "fact": "Clear, actionable statement in present tense.",
  "recommendation": "What to do (or avoid) as a result.",
  "confidence": "high|medium|low",
  "provenance": [
    {"source": "zuvo:execute|zuvo:ship|human|coderabbit", "reference": "<commit-sha-or-PR>", "date": "<ISO-date>"}
  ],
  "tags": ["keyword1", "keyword2"],
  "affectedFiles": ["src/auth/**", "*.test.ts"],
  "createdAt": "<ISO-8601>",
  "updatedAt": "<ISO-8601>",
  "timesSurfaced": 0
}
```

**Type definitions:**

| Type | When to use |
|------|-------------|
| `pattern` | Reusable approach that worked well |
| `gotcha` | Unexpected behavior or pitfall encountered |
| `decision` | Architectural or technical choice made with rationale |
| `anti-pattern` | Approach that caused problems — avoid it |
| `codebase-fact` | Specific quirk of this codebase |
| `api-behavior` | External API or library quirk |

**Confidence rules:**

| Level | When to assign |
|-------|---------------|
| `high` | Confirmed by 2+ independent provenance sources (different sessions, different code paths, or different contributors) |
| `medium` | Single reliable observation — directly observed, not inferred |
| `low` | Suspected but not directly confirmed, or based on inference |

**Critical:** `confidence` is NEVER upgraded because an entry was surfaced frequently (`timesSurfaced`). Frequent surfacing means it was shown a lot — not that it was validated. Confidence upgrades only when a new independent provenance record confirms the same fact from a different angle.

**Same source ≠ independent:** Multiple entries from the same workflow run, the same agent, or the same session count as one provenance source, not multiple.

---

## Protocol

### Step 1: Reflect on completed work

Think through what just happened. Ask yourself:

1. What surprised me during this work? *(→ gotcha or codebase-fact)*
2. What pattern did I use that worked well and should be repeated? *(→ pattern)*
3. What did I choose and why — and would I make the same choice again? *(→ decision)*
4. What approach caused problems or had to be changed? *(→ anti-pattern)*
5. What did I learn about an external API or library? *(→ api-behavior)*

**Final filter — ask for each candidate:**
> "Would this insight still help on a similar task next month?"

If the answer is "probably not" — discard. Only record things with lasting value.

**Generalization filter.** Only record things that are:
- Actionable (not just observational)
- Generalizable beyond this specific task
- Non-obvious (not common knowledge or best practices everyone knows)
- Unique — not already captured

**Temporary workaround rule:** If the insight depends on a workaround, hotfix, or known-temporary state — record it as `confidence: "low"` unless you have direct confirmation it reflects stable behavior.

If nothing passes all filters: print `KNOWLEDGE CURATED: No generalizable insights extracted from this session.` This is acceptable — not every task produces new knowledge.

### Step 2: Check for duplicates

```
Glob("knowledge/*.jsonl")
```

If knowledge base exists: read all entries. For each candidate insight, scan existing entries.

**Merge rule:**
> Merge only if the existing entry describes the **same core behavior** AND the **same practical recommendation**. If the recommendation differs materially (even for a similar symptom), keep them separate.

Identical symptom + different root cause = keep separate.
Identical symptom + different recommendation = keep separate.
Identical fact + identical recommendation = merge.

**Merge protocol (when merging):**
1. Append to `provenance[]`: `{"source": "<caller>", "reference": "<sha>", "date": "<today>"}`
2. Increment `timesSurfaced` by 0 (curate does not surface — only prime does)
3. Consider confidence upgrade ONLY if the new provenance source is independent from all existing sources:
   - Different session (different `started-at`)
   - Different code path or feature area
   - Different contributor (human vs agent)
   - If independent: `low→medium` or `medium→high`
   - If NOT independent (same workflow, same agent): do NOT upgrade confidence
4. Update `updatedAt`

### Step 3: Write new entries

For each NEW insight (not a duplicate):

1. Generate a unique `id`: `<type>-<2-3-word-slug>-<YYYYMMDD>` (e.g., `gotcha-prisma-null-20260407`)
2. Set `confidence` per confidence rules above (start at `"medium"` for directly observed facts, `"low"` for inferred)
3. Set `timesSurfaced: 0`
4. Write as a single JSON line appended to the appropriate file:
   - `pattern` → `knowledge/patterns.jsonl`
   - `gotcha` → `knowledge/gotchas.jsonl`
   - `decision` → `knowledge/decisions.jsonl`
   - `anti-pattern` → `knowledge/anti-patterns.jsonl`
   - `codebase-fact` → `knowledge/codebase-facts.jsonl`
   - `api-behavior` → `knowledge/api-behaviors.jsonl`

5. **Create directory if missing:** `mkdir -p knowledge`

**Rewrite safety (when updating existing entries):**
1. Read the full file into memory.
2. Parse each line. For the matched entry (by `id`): apply changes.
3. **Preserve unknown fields** — if a line has fields not in the current schema, keep them as-is.
4. **For malformed lines:** write them back unchanged. Log: `[KNOWLEDGE] Preserved malformed line N in <file> — not discarded.` Do NOT silently drop them.
5. Write the full file back.

### Step 4: Report

Print a curation summary:

```
KNOWLEDGE CURATED
  New entries:    N
  Merged:         N (updated existing entries)
  Skipped:        N (did not pass generalization filter)

New entries:
  [gotcha] "Prisma findMany returns [] not null on empty result" → knowledge/gotchas.jsonl
  [pattern] "Use factory functions for all test mocks" → knowledge/patterns.jsonl

Merged:
  [decision] "Zustand over Redux for client state" — new provenance added (confidence: medium, unchanged — same session)
  [gotcha] "API returns 200 on soft failures" — confidence upgraded medium→high (2nd independent source)

Skipped:
  "Use TypeScript types" — too obvious, not novel
  "Check for null before using value" — generic best practice
```
