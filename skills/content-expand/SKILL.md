---
name: content-expand
description: >
  Expand and optimize existing articles. Adds new sections, deepens thin content,
  and applies the same quality pipeline as write-article (anti-slop, BLUF, GEO
  signals, humanization, multi-schema). Includes web search research about the
  topic and auto-discovery of internal links from your content collection.
  Replaces content-optimize. Flags: [file], --dry-run, --lang, --tone,
  --site-dir, --domain, --skip-research, --light.
---

# zuvo:content-expand — Expand & Optimize Articles

Take an existing article, research the topic, add what's missing, and optimize the result — all in one pass. Same quality standards as `zuvo:write-article`.

**Scope:** Expand thin content, add missing sections, research and integrate new facts, optimize prose quality, update SEO/schema.
**Out of scope:** Encoding/markdown fixes (`zuvo:content-audit` + `content-fix`), writing from scratch (`zuvo:write-article`), CMS API, PDF/Word.

## Mandatory File Loading

**Phase 0 (always):**

1. `../../shared/includes/env-compat.md` -- Agent dispatch
2. `../../shared/includes/run-logger.md` -- Run logging
3. `../../shared/includes/banned-vocabulary/core.md` -- Shared anti-slop rules, tone matrix, G12, fallback behavior
4. `../../shared/includes/humanization-rules.md` -- Writing constraints + voice matching
5. `../../shared/includes/domain-profile-registry.md` -- 17 niche profiles
6. `../../shared/includes/seo-page-profile-registry.md` -- SEO profiles
7. `../../shared/includes/no-pause-protocol.md` -- HARD: no mid-loop pauses (batch/multi-section)

**Lazy-loaded (Phase 2 only):**

7. `../../shared/includes/prose-quality-registry.md` -- PQ1-PQ18 (scoring)
8. `../../shared/includes/adversarial-loop-docs.md` -- Cross-model review (end of Phase 2)
9. `../../shared/includes/article-output-schema.md` -- JSON output
10. `../../shared/includes/retrospective.md` -- RETRO PROTOCOL

Print `CORE FILES LOADED:` for items 1-6. After language detection, print `LANGUAGE FILE:` with the resolved banned-vocabulary language file and whether English fallback was used. Lazy items loaded inline when needed.

## Safety Gates

### GATE 1 — File Type
`.md`, `.mdx` supported. `.html` tolerated (tag-stripped, WARNING). Binary → STOP.

### GATE 2 — Dirty File Check
`git status --porcelain -- <file>`. Uncommitted changes → STOP. Require commit or stash.
`--dry-run` mode: proceed with WARNING (no file mutation).

### GATE 3 — Write Scope
Allowed: input file, `<file>.content-expand-backup`, `audit-results/`. FORBIDDEN: everything else.

## Arguments

| Argument | Behavior |
|----------|----------|
| `[file]` | Required. Path to `.md`/`.mdx` file to expand |
| `--dry-run` | Show proposed changes without writing. Print before/after diff |
| `--lang <code>` | Language override (default: auto-detect) |
| `--tone <value>` | `casual` / `technical` / `formal` / `marketing` (default: auto-detect from existing text) |
| `--site-dir <path>` | Content collection root — enables internal link discovery + voice matching |
| `--domain <niche>` | Override domain detection (one of 17 niche IDs from `domain-profile-registry.md`) |
| `--skip-research` | Skip web search; expand using existing content + LLM knowledge only |
| `--rewrite` | Allow rewriting existing sentences that have concrete defects (factual errors, grammar, outdated info). Without this flag, existing text is never modified. |
| `--light` | Skip reporting, backlog, knowledge curation. Just expand and write. |

---

## Phase 0 — Read & Score

### 0.1 Validate + Extract

1. File type validation (GATE 1). Dirty file check (GATE 2).
2. Parse frontmatter. Mark mutable fields (`title`, `description`, `keywords`, `author`). All others immutable.
3. Extract protected regions: fenced code blocks, MDX components. Store with position markers.
4. Language detection: `--lang` → frontmatter → content analysis → fallback structural-only.
5. Resolve the active language file from `../../shared/includes/banned-vocabulary/languages/` using the normalized base code. If missing: load `en.md` and emit `WARNING: banned-vocabulary fallback -> en`.

### 0.2 Domain Detection

Cascade: `--domain` → scan `--site-dir` articles for niche signals per `domain-profile-registry.md` → fallback `general`. YMYL niches emit credentials WARNING.

### 0.3 Voice Profile

If `--site-dir` has 3+ blog articles: extract voice profile per `humanization-rules.md` (rhythm, person, formality). Inconclusive → default rules only.

### 0.4 Score

Dispatch prose-quality-scorer + structure-analyst agents in parallel per `env-compat.md`. Score across 6 dimensions (PQ1-PQ17 from `prose-quality-registry.md`). Short articles get the same scrutiny as long ones — every sentence matters more when there are fewer of them.

Record: before-scores, tier, weak sections, thin sections (<100 words), missing elements per niche profile.

### 0.5 Internal Link Discovery

If `--site-dir` provided: scan the content collection (Glob `*.md` + `*.mdx`), read titles/descriptions of 10-20 articles, identify 5 most related by topic overlap. These become internal link candidates for Phase 2.

Print:
```
SETUP: [file] | [lang] | [tone] | Domain: [niche] | Voice: [matched|default]
SCORE: [composite]/100 ([tier]) | Weak: [N sections] | Thin: [N sections]
LINKS: [N candidates found | no site-dir]
```

---

## Phase 1 — Research

**Skip if `--skip-research` set.** Print: "Research skipped. Expanding from existing content + LLM knowledge."

### 1.1 Topic extraction

From article content + frontmatter, identify: primary topic, subtopics covered, subtopics missing (from Phase 0 scoring).

### 1.2 Web search

Perform 2-4 targeted web searches about the topic — NOT competitor analysis, but **factual research** for expansion:
- Facts, statistics, recent developments about the topic
- Specific details the article is missing (from Phase 0 thin-section analysis)
- Named sources, dates, version numbers for entity grounding

### 1.3 Fact sheet

Assemble research into a structured fact sheet (same format as `write-article` topic-researcher output). Each fact has source attribution + year. Tag conflicts as `[CONFLICT]`.

If web search unavailable: note `research_limited: true`, proceed with LLM knowledge only (clearly marked).

---

## Phase 2 — Expand + Optimize

This is the core phase. Expand THEN optimize in one pass — no separate faz.

### 2.1 Backup

Copy original to `<file>.content-expand-backup`. All work on temp copy. `--dry-run`: skip backup, work in memory only.

### 2.2 Expand (PRESERVE ORIGINAL TEXT)

**DEFAULT: Do not rewrite existing text.** Rewriting human prose with AI prose triggers detection on the entire article. Expand by ADDING content around what exists.

What you CAN always do:
- **Add new paragraphs** between or after existing ones
- **Add new H2/H3 sections** for missing subtopics
- **Add intro/conclusion** if missing

What you CANNOT do without `--rewrite`:
- Rephrase existing sentences
- Merge or reorder existing paragraphs
- Change existing word choices or headings

**With `--rewrite`:** Rewrites are allowed ONLY for sentences with a concrete defect: factual error, grammatical mistake, nonsensical claim, or outdated information. Each rewrite must state the reason (e.g., "Fixed: claimed population is 5M, actual is 8.3M per 2025 census"). Style preferences ("sounds better") are NOT a valid reason.

For ALL new content, apply `humanization-rules.md` constraints:
- Sentence variation (fragments + long), contractions, parenthetical asides
- Entity grounding (specific versions, dates, names from research)
- Voice matching if profile available — match the existing article's voice, not your default
- No throat-clearing (G12), BLUF per section (G9), max 300 words/section (G6)
- Stats and volatile practical facts must remain traceable to the fact sheet (G11)
- Do not build paragraph rhythm around repeated source lead-ins such as `Według X (2025)`
- Use a hard source-name budget: the same full institution/source name should appear no more than once per section and no more than 3 times in the whole article body, excluding a compact `## Źródła` section
- Use `(odczyt: miesiąc rok)` only for volatile practical facts, not for stable historical description
- Do not append a process-heavy research appendix such as `Źródła wykorzystane przy aktualizacji`
- End public articles with a compact `## Źródła` section unless the host project explicitly forbids visible sources
- In `## Źródła`, keep 3-6 grouped bullets max: source title + link only
- Group repeated institutions into one bullet whenever possible, e.g. `- **APSARA National Authority:** [Temple page](...), [Restoration update](...)`
- Do not add filler closers like `## Na koniec` if they only restate the article
- Prefer practical expansion blocks (specific H2s, lists, route notes, local comparisons, FAQ at the end) over replacing the opening with smoother narrative prose
- For practical/service-intent articles, add or preserve a short `## W skrócie` block immediately after the italic lead and before the first image or H2. Keep 3-5 bullets max.

Use these exact output shapes when applicable:

```md
## W skrócie
- [Najważniejsza decyzja / odpowiedź]
- [Najważniejszy wymóg / koszt / limit]
- [Najważniejsza opcja / wyjątek]
- [Najważniejszy warunek praktyczny]
```

```md
## Źródła
- **[Instytucja / grupa źródeł]:** [Tytuł 1](...), [Tytuł 2](...)
- **[Instytucja / grupa źródeł]:** [Tytuł 3](...)
- **[Instytucja / grupa źródeł]:** [Tytuł 4](...)
```

### 2.3 Internal Links

Insert 2-5 contextual internal links from Phase 0 candidates. Validate each via Glob. Unverified → `[UNVERIFIED LINK]`, not auto-inserted.

### 2.4 SEO + Schema

Read `domain-profile-registry.md` for niche-appropriate schema:
- Detect existing `@type`. If specific (Recipe, HowTo, Event) → preserve and merge. If BlogPosting only → upgrade per niche.
- FAQ: if article now has Q&A content + niche allows FAQ → add FAQPage schema.
- Inspect the local content schema/config before mutating frontmatter. Treat the schema as the source of truth for allowed fields.
- OG tags: write `og:title`, `og:description`, `og:type`, `og:image` only if those fields are clearly accepted by the local schema. If not, inherit layout-level OG behavior and record `OG: inherited-from-layout`.
- **dateModified / modifiedDate / updatedDate:** Find the exact modification-date field already accepted by the collection schema (common names: `modifiedDate`, `updatedDate`, `dateModified`, `lastmod`, `updated`) and update that field. If no such field exists and schema support is unclear, do not invent `modifiedDate`; leave frontmatter unchanged and record `Date field: unchanged (schema-blocked)`. Never touch `publishDate` / `date` / `publishedDate` — that's the original publication date.
- Meta title/description: only update if currently MISSING. Never rewrite existing meta that the author wrote.

### 2.5 Anti-slop Review

Run anti-slop check on expanded content (same as write-article Phase 4):
- Hard/soft banned vocabulary per `banned-vocabulary/core.md` + active language file + `--tone`
- G12 anti-patterns (throat-clearing, superlatives, keyword density)
- BLUF compliance (G9), chunkability (G6), citation compliance (G11)
- Dispatch anti-slop-reviewer agent (read `../../skills/write-article/agents/anti-slop-reviewer.md`) for all articles regardless of length.

Apply this review to human-facing prose only. Do not count frontmatter keys, schema-only metadata, file paths, URLs, image names, JSON-LD/schema, code, or raw source lists as banned-vocabulary violations unless the task explicitly asks to audit those zones as prose.

Fix all CRITICAL violations. Fix WARNINGs if localized.

### 2.6 Re-score + Rollback

Score expanded article (same 6 dimensions). If ANY dimension regressed → revert that section's changes. Never deliver a lower composite score.

### 2.7 Adversarial Review

Load `adversarial-loop-docs.md` now. Run: `adversarial-review --json --mode article --files "<temp-file>"` (fallback: `--json --mode audit` + WARNING). CRITICAL → fix. WARNING → fix if localized. If the script returns `status: "timeout"` or exits `124`, record `Adversarial review: skipped (timeout)` and continue without blocking the article.

### 2.8 Replace Original

Protected regions re-inserted. Frontmatter immutable fields preserved. Replace original with expanded temp copy. Delete backup. `--dry-run`: print diff only, no file changes.

---

## Phase 3 — Output

### Before/After Summary

```
CONTENT-EXPAND COMPLETE
-----
File: [path]
Words: [before] → [after] (+[N] added)
Score: [before]/100 ([tier]) → [after]/100 ([tier])
Domain: [niche] | Schema: [type(s)]
Sections added: [N] | Sections expanded: [N]
Internal links: [N] added ([N] verified)
FAQ: [N items | none] | OG: [present | inherited-from-layout | schema-blocked]
Voice: [matched | default] | Research: [N facts used | skipped | limited]

Run: <ISO-8601-Z>	content-expand	<project>	-	-	<VERDICT>	<TASKS>	3-phase	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
-----
```

After printing, append `Run:` line to log per `run-logger.md`.

**VERDICT:** `PASS` (expanded, no regressions), `WARN` (research_limited or voice delta MED+), `FAIL` (adversarial blockers), `BLOCKED` (dirty file, binary input).
**NOTES:** `[file basename] [before]->[after] +[N]words [tier]` (max 80 chars).

### Reporting (skip with `--light`)

Unless `--light`: write report to `audit-results/content-expand-YYYY-MM-DD.md`. Write JSON per `article-output-schema.md`. Run knowledge curation per `knowledge-curate.md`. Persist findings per `backlog-protocol.md`.

### Retrospective (REQUIRED)

Follow `retrospective.md`. Gate check → structured questions → TSV emit → markdown append.

Next steps: `zuvo:review [file]` | `zuvo:content-audit [file]` | `zuvo:ship`
