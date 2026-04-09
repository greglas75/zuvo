# Content Writing Skills — Design Specification

> **spec_id:** 2026-04-09-content-writing-skills-1845
> **topic:** write-article and content-optimize skills
> **status:** Draft
> **created_at:** 2026-04-09T18:45:00Z
> **approved_at:** null
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

Zuvo has 49 skills covering code audits, testing, refactoring, SEO, and content hygiene — but zero skills that **write** or **improve** content. The user operates multiple websites with automated article generation and needs:

1. A pipeline that produces high-quality, non-generic articles from scratch
2. A tool that evaluates existing articles and optimizes them without destroying author voice

No open-source tool combines deep research, anti-slop enforcement, and adversarial review in a CLI/plugin-native pipeline. This is an unoccupied niche.

**If we do nothing:** The user continues generating articles with raw LLM prompts — no research grounding, no anti-slop gates, no SEO structure, no quality scoring. Output is generic AI slop.

## Design Decisions

### DD1: Two skills, not one

**Chosen:** Separate `write-article` (create from scratch) and `content-optimize` (improve existing). They share infrastructure (banned vocabulary, SEO pass, adversarial review) but have fundamentally different input/output contracts.

**Why:** A combined skill would have two completely different Phase 0s (research vs analyze), different safety models (create file vs modify file), and confusing argument parsing.

### DD2: content-optimize is a hybrid (audit + fix in one)

**Chosen:** Option C — `content-optimize` always produces a diagnostic report. The `--apply` flag additionally rewrites the content. Without `--apply`, it's read-only.

**Rejected:**
- (A) All-in-one without report — loses audit trail
- (B) Separate audit + prose-fix skills — unnecessary overhead for the user's batch workflow

**Why:** The user runs this across multiple sites. Two commands per article is friction. The report is always produced regardless of `--apply`, so audit trail is preserved.

### DD3: Deep STORM-inspired research as default

**Chosen:** Option B — full research pipeline: 3-5 reader personas, multi-perspective Q&A, 3-5 web searches, competitor analysis, structured fact sheet with citations.

**Why:** The user prioritizes article quality over speed. Shallow research produces shallow articles. The STORM pattern (Stanford, 28K stars) is the strongest proven approach for outline generation via multi-perspective questioning.

### DD4: Adaptive anti-slop enforcement

**Chosen:** Option C — hard-banned words (always block) + soft-banned words (tone-dependent).

**Structure:**
- **HARD BAN (10 words):** "delve", "tapestry", "it's worth noting", "in the realm of", "game-changer", "as an AI", "certainly!", "I'd be happy to", "multifaceted", "embark"
- **SOFT BAN (20+ words, tone-dependent):** "Furthermore", "Moreover", "comprehensive", "robust", "leverage", "utilize", "seamless", "cutting-edge", "unlock", "empower", "streamline", "foster", "nuanced", "landscape", "In conclusion", "In today's world", "It is important to note"
- **Burstiness check:** max 3 consecutive sentences in 15-25 word range (WARNING, not blocker)

Soft bans activate based on `--tone`:
- `casual` / `marketing`: all soft bans active (strictest)
- `technical`: "Furthermore", "Moreover", "In conclusion" allowed; rest banned
- `formal` / `academic`: all soft bans are WARNINGs only (least strict)

**Why:** One threshold doesn't fit all content types. "Furthermore" is slop in a blog post but normal in a technical reference.

### DD5: Site-aware output without publish pipeline

**Chosen:** Option B — `--site-dir <path>` writes directly to the site's content directory, auto-detects frontmatter schema from existing articles, validates internal links against real files.

**Rejected:** (C) Adding `--commit`/`--pr` — this duplicates `zuvo:ship`. The recommended chain: `write-article` → `content-optimize --apply` → `zuvo:ship`.

**Why:** Each site has its own frontmatter format. Auto-detection eliminates manual format configuration. No publish actions — skill writes files, user controls git.

## Solution Overview

### write-article: 6-Phase Pipeline

```
Phase 0: Setup
  ├─ Detect environment (env-compat)
  ├─ Validate args (topic, --lang, --tone, --length, --site-dir, --format)
  ├─ Detect web search availability
  └─ If --site-dir: analyze existing articles for frontmatter schema

Phase 1: Research (3 parallel agents)
  ├─ Agent 1: Topic Researcher — web search, fact gathering, source citations
  ├─ Agent 2: Persona Generator — 3-5 reader personas, their questions
  ├─ Agent 3: Competitor Analyst — top content for this topic, gap analysis
  └─ Output: structured fact sheet + persona questions + competitor gaps

Phase 2: Outline
  ├─ Generate outline from persona questions (STORM pattern)
  ├─ Map research facts to outline sections
  ├─ Internal adversarial critique of outline structure
  ├─ Interactive: present for approval (max 3 revisions)
  └─ Async: auto-approve with [AUTO-DECISION] after 1 self-revision

Phase 3: Draft
  ├─ Section-by-section generation
  ├─ Each section receives: its outline, mapped facts, previous sections summary
  ├─ For articles >3000 words: continuity check between sections
  ├─ Research facts MUST be used (not model memory)
  └─ Banned vocabulary stripped from research summaries before injection

Phase 4: Review (adversarial)
  ├─ Anti-slop check: banned vocabulary (hard + soft per tone)
  ├─ Burstiness check: sentence length variety
  ├─ Fact verification: every claim traced back to research fact sheet
  ├─ Domain sensitivity: medical/legal/financial + casual tone = WARNING
  ├─ Structural review: intro hook, section flow, CTA, conclusion
  └─ Cross-model adversarial review (adversarial-loop-docs --mode article)

Phase 5: SEO + Output
  ├─ Keyword placement: title, H1, first 100 words, H2s
  ├─ Meta tags: title (50-60 chars), description (150-160 chars)
  ├─ Schema: BlogPosting JSON-LD (headline, author, dates, image)
  ├─ Internal links: suggest 2-5 per 1000 words (validated if --site-dir)
  ├─ Frontmatter: auto-detect schema if --site-dir, else standard YAML
  ├─ Format: plain MD (default), Astro MDX, Hugo, Next.js MDX
  └─ Save to --site-dir or output/articles/YYYY-MM-DD-<slug>.<ext>
```

### content-optimize: 5-Phase Pipeline

```
Phase 0: Setup
  ├─ Validate file type (.md, .mdx supported; .html tolerated; binary blocked)
  ├─ Dirty file check (uncommitted changes → STOP)
  ├─ Language detection (auto or --lang)
  ├─ Extract protected regions (code blocks, MDX components, complex frontmatter)
  └─ Detect web search availability

Phase 1: Analyze
  ├─ Score across 6 dimensions:
  │   ├─ Readability (LLM-estimated FK grade, sentence complexity)
  │   ├─ Engagement (hook strength, tension/release, specificity ratio)
  │   ├─ SEO (keyword presence, meta quality, heading hierarchy, schema)
  │   ├─ Structure (heading density, paragraph length, section balance)
  │   ├─ Authority (E-E-A-T signals, cited sources, first-hand experience)
  │   └─ Anti-slop (banned vocabulary count, burstiness, AI-pattern density)
  ├─ Composite score (0-100) with A/B/C/D tier
  └─ If score >= 80: default to "enhancement only" mode

Phase 2: Benchmark (requires web search)
  ├─ Extract primary topic/keywords from article
  ├─ Search for top-ranking competitor content
  ├─ Compare: topics covered, depth, structure, word count
  ├─ Identify gaps: topics competitors cover that this article misses
  └─ If web search unavailable: SKIP with explicit note

Phase 3: Diagnose
  ├─ Weak sections (thin content, vague claims, missing examples)
  ├─ Missing topics (from competitor gap analysis)
  ├─ Structural issues (poor heading hierarchy, weak intro/CTA)
  ├─ SEO gaps (missing meta, keyword opportunities, schema gaps)
  ├─ Freshness issues (outdated stats, deprecated references)
  └─ Voice profile extraction (sentence length, person, punctuation, transitions)

Phase 4: Optimize (only with --apply)
  ├─ Rewrite weak sections while preserving voice profile
  ├─ Add content for gap-fill sections
  ├─ Improve headings, strengthen intro/conclusion
  ├─ SEO pass: update meta, add schema, suggest internal links
  ├─ Protected regions re-inserted verbatim
  ├─ Internal links validated against real files (if in a site directory)
  ├─ Re-score optimized article (Phase 1 dimensions)
  ├─ If any dimension regressed → rollback that change
  ├─ Voice delta check: LOW/MED/HIGH
  │   └─ HIGH voice delta in interactive mode → ask user confirmation
  └─ Adversarial review on the diff (adversarial-loop-docs --mode article)

Phase 5: Report
  ├─ Before/after scores per dimension
  ├─ Changes made (or proposed if no --apply)
  ├─ Voice delta metric
  ├─ Competitor gap coverage (if benchmark ran)
  ├─ Protected regions count
  └─ Save to audit-results/content-optimize-YYYY-MM-DD.md (+ .json)
```

## Detailed Design

### New Shared Includes

#### `shared/includes/banned-vocabulary.md`

Shared between both skills. Structure:

```markdown
## Hard Ban (all tones, all languages)

### English
delve, tapestry, it's worth noting, in the realm of, game-changer,
as an AI, certainly!, I'd be happy to, multifaceted, embark

### Polish
z pewnością warto zauważyć, w dzisiejszym świecie, nie da się ukryć że,
jak powszechnie wiadomo, w kontekście powyższego

## Soft Ban (tone-dependent)

### English
Furthermore, Moreover, comprehensive, robust, leverage, utilize,
seamless, cutting-edge, unlock, empower, streamline, foster,
nuanced, landscape, In conclusion, In today's world,
It is important to note, plays a crucial role, are not limited to

### Polish
Ponadto, Co więcej, Podsumowując, Warto podkreślić, Nie ulega wątpliwości,
Kluczowym aspektem jest, W dzisiejszych czasach

## Burstiness Rules

- Max 3 consecutive sentences in 15-25 word range
- Min 20% of sentences should be <10 words or >30 words
- No more than 2 consecutive sentences starting with the same word
```

#### `shared/includes/prose-quality-registry.md`

Check registry for content-optimize (analogous to `content-check-registry.md`):

| ID | Dimension | Check | Severity |
|----|-----------|-------|----------|
| PQ1 | Readability | FK grade level appropriate for audience | MEDIUM |
| PQ2 | Readability | Sentence length variety (burstiness) | MEDIUM |
| PQ3 | Engagement | Hook in first 2 sentences | HIGH |
| PQ4 | Engagement | Specificity ratio (concrete vs abstract) | HIGH |
| PQ5 | Engagement | Tension/release pattern per section | LOW |
| PQ6 | SEO | Primary keyword in title + H1 + first 100 words | HIGH |
| PQ7 | SEO | Meta description 150-160 chars with keyword | MEDIUM |
| PQ8 | SEO | BlogPosting schema present | MEDIUM |
| PQ9 | SEO | Internal links (2-5 per 1000 words) | LOW |
| PQ10 | Structure | Heading hierarchy (no skipped levels) | HIGH |
| PQ11 | Structure | Section balance (no section >2x average length) | MEDIUM |
| PQ12 | Structure | Intro + conclusion present | HIGH |
| PQ13 | Authority | E-E-A-T signals (experience, expertise markers) | MEDIUM |
| PQ14 | Authority | Cited sources or data points | HIGH |
| PQ15 | Anti-slop | Hard-banned vocabulary (zero tolerance) | CRITICAL |
| PQ16 | Anti-slop | Soft-banned vocabulary (tone-dependent) | MEDIUM |
| PQ17 | Anti-slop | AI-pattern sentence openers | MEDIUM |
| PQ18 | Freshness | References dated >2 years flagged | LOW |

#### `shared/includes/article-output-schema.md`

JSON output contract for write-article:

```json
{
  "version": "1.0",
  "skill": "write-article",
  "timestamp": "ISO-8601",
  "project": "string",
  "args": {},
  "article": {
    "title": "string",
    "slug": "string",
    "language": "en|pl|...",
    "tone": "casual|technical|formal|marketing",
    "word_count": 0,
    "format": "md|astro-mdx|hugo|nextjs-mdx",
    "output_path": "string",
    "research_limited": false
  },
  "research": {
    "sources_count": 0,
    "personas_count": 0,
    "competitor_gaps": [],
    "facts_used": 0,
    "facts_available": 0
  },
  "quality": {
    "anti_slop": { "hard_violations": 0, "soft_violations": 0 },
    "burstiness_score": 0.0,
    "adversarial_verdict": "PASS|WARN|FAIL"
  },
  "seo": {
    "primary_keyword": "string",
    "meta_title": "string",
    "meta_description": "string",
    "schema_type": "BlogPosting|Article",
    "internal_links_suggested": 0,
    "internal_links_verified": 0
  }
}
```

#### `shared/includes/content-optimize-output-schema.md`

JSON output contract for content-optimize:

```json
{
  "version": "1.0",
  "skill": "content-optimize",
  "timestamp": "ISO-8601",
  "project": "string",
  "args": {},
  "input_file": "string",
  "language": "en|pl|auto",
  "mode": "report|applied",
  "scores": {
    "before": {
      "readability": 0, "engagement": 0, "seo": 0,
      "structure": 0, "authority": 0, "anti_slop": 0,
      "composite": 0, "tier": "A|B|C|D"
    },
    "after": {
      "readability": 0, "engagement": 0, "seo": 0,
      "structure": 0, "authority": 0, "anti_slop": 0,
      "composite": 0, "tier": "A|B|C|D"
    }
  },
  "voice_delta": "LOW|MED|HIGH",
  "benchmark": {
    "performed": true,
    "competitors_analyzed": 0,
    "gaps_identified": [],
    "gaps_addressed": []
  },
  "changes": [
    {
      "section": "string",
      "type": "rewrite|addition|meta_update|heading_fix|link_add",
      "description": "string",
      "dimension_impact": "readability|engagement|seo|structure|authority|anti_slop",
      "score_delta": 0,
      "rolled_back": false,
      "rollback_reason": "string|null"
    }
  ],
  "protected_regions": {
    "code_blocks": 0,
    "mdx_components": 0,
    "frontmatter_fields_preserved": 0
  },
  "findings": [
    {
      "id": "PQ1-fk-grade-high",
      "dimension": "readability",
      "check": "PQ1",
      "severity": "MEDIUM",
      "message": "string",
      "line": 0,
      "fixable": true,
      "fix_applied": false
    }
  ]
}
```

### Agent Architecture

#### write-article agents (Phase 1, parallel)

| Agent | Model | Type | Tools | File |
|-------|-------|------|-------|------|
| Topic Researcher | sonnet | general | WebSearch, Read | `agents/topic-researcher.md` |
| Persona Generator | sonnet | general | WebSearch | `agents/persona-generator.md` |
| Competitor Analyst | sonnet | general | WebSearch, Read, Glob | `agents/competitor-analyst.md` |

#### write-article agents (Phase 4, sequential)

| Agent | Model | Type | Tools | File |
|-------|-------|------|-------|------|
| Anti-Slop Reviewer | sonnet | Explore | Read | `agents/anti-slop-reviewer.md` |

The Anti-Slop Reviewer is a SEPARATE agent from the Writer — it has no memory of the drafting process. It sees only the output text and the banned vocabulary list. This is the two-model pattern.

#### content-optimize agents (Phase 1+3, parallel)

| Agent | Model | Type | Tools | File |
|-------|-------|------|-------|------|
| Prose Quality Scorer | sonnet | Explore | Read | `agents/prose-quality-scorer.md` |
| Structure Analyst | sonnet | Explore | Read, Glob | `agents/structure-analyst.md` |

### Argument Tables

#### write-article

| Argument | Behavior |
|----------|----------|
| `<topic>` | Required. The article topic/title |
| `--lang <code>` | Language (default: `en`). Affects banned vocabulary, SEO, register |
| `--tone <value>` | `casual` / `technical` / `formal` / `marketing` (default: `casual`) |
| `--length <N>` | Approximate word count (default: `1500`). <800 = COMPACT mode |
| `--site-dir <path>` | Write to site content dir; auto-detect frontmatter schema |
| `--format <fmt>` | `md` (default) / `astro-mdx` / `hugo` / `nextjs-mdx` |
| `--keyword <term>` | Primary SEO keyword (auto-detected from topic if omitted) |
| `--audience <desc>` | Target audience description (feeds persona generation) |
| `--batch-mode` | Cache research per domain/niche across session (see Batch Mode section below) |

### Batch Mode (`--batch-mode`) Contract

When `--batch-mode` is active on write-article:

**Cache key:** `{site-dir-basename}:{primary_keyword_normalized}` — where `primary_keyword_normalized` is lowercase, trimmed, spaces replaced with hyphens. Example: `zuvo-landing:seo-optimization`.

**What is cached:**
- Competitor analysis results (URLs, content gaps, keyword landscape)
- Domain-level facts (site name, industry, existing content inventory)
- NOT cached: topic-specific research facts, persona questions (these are per-article)

**Storage:** `memory/write-article-cache-{date}.json` in the project directory. One file per session day.

**TTL:** Cache expires at end of session or after 24 hours, whichever comes first. No cross-session persistence.

**Inter-run isolation:** Each article run gets a unique `run_id` in the run logger. The `NOTES` field includes `batch:{N}` where N is the article sequence number within the batch session. Articles share cached competitor data but have independent fact sheets, outlines, and drafts.

#### content-optimize

| Argument | Behavior |
|----------|----------|
| `[file]` | Required. Path to content file (.md, .mdx) |
| `--apply` | Apply optimizations (default: report only). See Backup Strategy below |
| `--lang <code>` | Language override (default: auto-detect) |
| `--tone <value>` | Tone context for anti-slop thresholds |
| `--force-rewrite` | Allow structural rewrites on high-scoring (>=80) articles |
| `--dry-run` | Alias for default behavior (report only, no changes) |
| `--competitors <urls>` | Manual competitor URLs (skips web search discovery) |
| `--skip-benchmark` | Skip competitor benchmarking entirely |

### Backup Strategy for `--apply`

When `content-optimize --apply` is active, the skill modifies the source file in place. To prevent data loss:

1. **Pre-condition:** Dirty file check (EC-CO-11) ensures the file is committed before any mutation. This means `git checkout -- <file>` is always a viable rollback.
2. **Backup copy:** Before any write, copy the original to `<file>.content-optimize-backup`. This file lives alongside the original.
3. **Atomic operation:** All optimizations are computed on a temp copy. The original is only replaced when the full pipeline succeeds (re-score confirms no regression).
4. **On success:** Delete the `.content-optimize-backup` file. The original is now the optimized version.
5. **On failure (crash, regression, or abort):** The `.content-optimize-backup` file remains. The report notes: `ROLLBACK: Backup preserved at <path>. Original file unchanged.`
6. **Per-dimension rollback (EC-CO-10):** If a specific section rewrite causes a dimension to regress, that single rewrite is reverted in the temp copy (not the whole file). The final file contains only non-regressive changes.

### Integration Points

#### Existing shared includes consumed

| Include | write-article | content-optimize |
|---------|:---:|:---:|
| `env-compat.md` | Yes | Yes |
| `run-logger.md` | Yes | Yes |
| `codesift-setup.md` | If technical article | No |
| `adversarial-loop-docs.md` | Yes (--mode article) | Yes (--mode article) |
| `backlog-protocol.md` | No | Yes |
| `knowledge-prime.md` | No | Yes |
| `knowledge-curate.md` | No | Yes |
| `audit-output-schema.md` | No | Yes (report format) |
| `seo-page-profile-registry.md` | Yes (word count thresholds) | Yes (profile-aware scoring) |
| `verification-protocol.md` | No | Yes (build verify after apply) |

#### New shared includes created

| Include | Purpose |
|---------|---------|
| `banned-vocabulary.md` | Hard/soft banned words per language + burstiness rules |
| `prose-quality-registry.md` | PQ1-PQ18 check definitions for content-optimize |
| `article-output-schema.md` | JSON output contract for write-article |
| `content-optimize-output-schema.md` | JSON output contract for content-optimize (before/after scores, changes, voice delta) |

#### Existing files modified

| File | Change |
|------|--------|
| `skills/using-zuvo/SKILL.md` | Add routing entries for both skills, update skill count 49→51 |
| `package.json` | Version bump, update description |
| `.claude-plugin/plugin.json` | Update skill count and version |
| `.codex-plugin/plugin.json` | Update skill count and version |
| `docs/skills.md` | Add entries, update category counts |
| `adversarial-loop-docs.md` | Add `--mode article` rubric (see Adversarial Article Mode section) |

### Adversarial Article Mode (`--mode article`)

**Decision (resolved from OQ#2):** Add `--mode article` to `adversarial-loop-docs.md`. This is a markdown change (adding a rubric section), not a script modification — the adversarial-review script already dispatches by mode name to the rubric in the docs include. The modification is to `shared/includes/adversarial-loop-docs.md` only.

**Fallback:** If `--mode article` is not yet available at implementation time, both skills MUST fall back to `--mode audit` with a WARNING: `"Adversarial review used --mode audit (article mode not yet available). Prose-specific checks (burstiness, voice, slop) not covered by this mode."` This ensures the pipeline never blocks on a missing mode.

**Article mode rubric (to be added to `adversarial-loop-docs.md`):**

| Severity | Trigger |
|----------|---------|
| CRITICAL | Factual claim with no source in fact sheet; internal contradiction between sections; hard-banned vocabulary present |
| WARNING | Weak E-E-A-T signals; buried answer (key point not in first 2 sentences of section); soft-banned vocabulary (tone-dependent); burstiness violation; voice inconsistency between sections |
| INFO | Style preference; minor transition quality; paragraph length variation |

### Edge Cases

| ID | Skill | Scenario | Handling |
|----|-------|----------|----------|
| EC-WA-01 | write-article | Web search unavailable | Degrade to user-context only. Tag `research_limited: true` in frontmatter. Emit warning. |
| EC-WA-02 | write-article | Vague topic | Phase 0 clarification gate: ask audience, keyword, length, tone. Async: apply defaults with [AUTO-DECISION]. |
| EC-WA-03 | write-article | Conflicting research sources | Tag `[CONFLICT]` in fact sheet. Review phase must resolve or exclude. |
| EC-WA-04 | write-article | Article >3000 words | Section-by-section draft with continuity checks between segments. |
| EC-WA-05 | write-article | Technical article needs codebase context | Detect project reference → dispatch Code Explorer sub-agent → inject real API surface into facts. |
| EC-WA-06 | write-article | Polish output + EN SEO rules | Language-aware SEO: morphological variants, Polish schema locale, PL-specific banned words. |
| EC-WA-07 | write-article | Casual tone + medical/legal topic | Domain sensitivity check → WARNING (not blocker). Surface risk, don't override user. |
| EC-WA-08 | write-article | Outline rejected 3 times | Hard cap. Prompt for manual outline or abandon. Async: auto-approve after 1 revision. |
| EC-WA-09 | write-article | Unsupported output format | Fall back to plain MD with note. |
| EC-WA-10 | write-article | Banned words in research sources | Strip from summaries BEFORE injection into draft. |
| EC-WA-11 | write-article | <800 words requested | COMPACT mode: collapse research+outline, skip competitor analysis, lighter review. |
| EC-WA-12 | write-article | Batch generation across sites | `--batch-mode` caches research per domain. Inter-run isolation in run logger. |
| EC-CO-01 | content-optimize | Non-markdown file | .md/.mdx supported. .html tolerated (strip tags). Binary → STOP. |
| EC-CO-02 | content-optimize | Complex nested YAML frontmatter | Only optimize title/description/keywords/author. Preserve all other fields byte-for-byte. |
| EC-CO-03 | content-optimize | MDX components in content | Phase 0 extracts as protected regions. Never rewrite component tags or props. |
| EC-CO-04 | content-optimize | Undetected language | Fall back to structural-only analysis. Skip language-dependent checks. |
| EC-CO-05 | content-optimize | No web search for benchmark | Skip Phase 2. Note in report. Proceed with internal analysis only. |
| EC-CO-06 | content-optimize | Article already high quality (>=80) | Enhancement-only mode by default. `--force-rewrite` required for structural changes. |
| EC-CO-07 | content-optimize | File >5000 words | Section-by-section optimization with full outline as context anchor. |
| EC-CO-08 | content-optimize | Code blocks in article | Protected regions pattern. Re-insert verbatim after optimization. |
| EC-CO-09 | content-optimize | Author voice destroyed | Voice profile extraction → voice delta metric → HIGH delta requires confirmation. |
| EC-CO-10 | content-optimize | Optimization reduces score | Re-score after optimize. Rollback any regressive change. Never deliver lower composite score. |
| EC-CO-11 | content-optimize | Uncommitted changes in file | Dirty file check → STOP. Require commit or stash first. |
| EC-CO-12 | content-optimize | Internal link suggestions point to nonexistent files | Validate against real files. Unverified links flagged `[UNVERIFIED LINK]`, not auto-inserted. |

## Acceptance Criteria

### write-article

**Must have:**
1. `zuvo:write-article "topic"` produces a complete article saved to a discoverable path
2. Research phase emits structured fact sheet with cited sources before drafting
3. Outline generated via multi-perspective persona questioning (STORM pattern)
4. Draft is section-by-section, each section fed with mapped research facts
5. Review phase checks against banned vocabulary list with hard/soft tiers
6. SEO phase adds title, description, keywords, and BlogPosting schema to frontmatter
7. Output in plain MD by default; Astro MDX, Hugo, Next.js MDX via `--format`
8. Run-logger line appended at completion
9. Async mode proceeds without prompts; all auto-decisions annotated
10. Graceful degradation when web search unavailable

**Should have:**
11. `--lang pl` activates Polish banned vocabulary and SEO rules
12. `--length <N>` controls word count; <800 = COMPACT mode
13. `--site-dir` auto-detects frontmatter schema and validates internal links
14. `--tone` adjusts anti-slop soft ban thresholds
15. Technical article support via optional CodeSift exploration
16. Domain sensitivity warning for medical/legal + casual tone
17. Cross-model adversarial review via `adversarial-loop-docs --mode article`

### content-optimize

**Must have:**
1. `zuvo:content-optimize [file]` produces a diagnostic report with scores
2. Scores across 6 dimensions: readability, engagement, SEO, structure, authority, anti-slop
3. `--apply` rewrites content; without it, report only
4. Optimized content never has lower composite score than original (rollback regressive changes)
5. Code blocks and MDX components preserved as protected regions
6. Frontmatter fields outside title/description/keywords/author preserved verbatim
7. Dirty file check blocks optimization of files with uncommitted changes
8. Run-logger line appended at completion
9. Async mode proceeds without prompts
10. Internal link suggestions validated against existing files

**Should have:**
11. `--lang` activates language-appropriate heuristics
12. High-quality articles (>=80) default to enhancement-only mode
13. Voice delta metric in report; HIGH delta requires confirmation
14. `--dry-run` shows proposed changes without applying
15. Competitor benchmark via web search (graceful skip if unavailable)
16. Cross-model adversarial review on the diff

## Out of Scope

- **CMS API publishing** — no WordPress REST, no Contentful, no headless CMS integration. Skills write files.
- **Image generation** — no AI image creation for articles. Skills output text only.
- **Plagiarism detection** — no external API calls to plagiarism checkers.
- **Translation** — `write-article` writes in ONE language per run. No auto-translation between languages.
- **RSS/feed generation** — out of scope. Framework handles this.
- **Analytics integration** — no tracking, no A/B testing, no performance measurement.
- **Video/audio content** — text articles only.
- **Comments/engagement features** — article text only, no interactive elements.

## Open Questions

1. **Should `content-optimize` also support HTML files natively?** Current design tolerates HTML with tag stripping. Full HTML support (preserving semantic tags, optimizing within `<article>`) would require more complexity. **Decision: defer to v2 if demand exists.** Not a blocker for implementation.

2. ~~**Should the adversarial-review script get a new `--mode article`?**~~ **RESOLVED:** Yes — add `--mode article` rubric to `adversarial-loop-docs.md` (markdown change only). Fallback to `--mode audit` with WARNING if not yet available. See "Adversarial Article Mode" section above.

3. ~~**Batch orchestration**~~ **RESOLVED:** Start with `--batch-mode` flag on write-article. Cache contract specified in "Batch Mode Contract" section. Evaluate separate `zuvo:content-pipeline` skill after v1 if demand justifies it.
