# Write-Article SEO/GEO Enhancement — Design Specification

> **spec_id:** 2026-04-09-write-article-seo-enhancement-2130
> **topic:** Domain-aware SEO/GEO optimization + voice humanization for write-article
> **status:** Approved
> **created_at:** 2026-04-09T21:30:00Z
> **approved_at:** 2026-04-09T22:00:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

`write-article` currently generates articles with minimal SEO: keyword placement, basic meta title/description, and a plain `BlogPosting` JSON-LD. It has no domain awareness — a recipe article gets the same schema as a SaaS comparison post. No FAQ generation, no featured snippet targeting, no BLUF enforcement, no chunkability gate, no GEO signals (G6/G9/G10/G11/G12), and no voice humanization.

Competitors (Surfer, Frase, KoalaWriter, Writesonic) auto-generate FAQ from PAA data, emit multi-schema JSON-LD, and score for AI Overview citation. None of them do domain-aware schema selection or voice matching from existing site content.

**If we do nothing:** Articles rank worse than competitor-generated content. No rich results beyond basic article snippet. No AI Overview citations. Content sounds generic AI across all niches.

## Design Decisions

### DD1: Registry-based domain detection (17 niches)

**Chosen:** New `shared/includes/domain-profile-registry.md` with 17 niche profiles. Each profile defines: schema types, E-E-A-T tier, content structure rules, required elements, and detection signals.

Detection cascade:
1. `--domain <niche>` explicit override (highest priority)
2. Frontmatter tags/categories scan of 3-5 existing articles in `--site-dir`
3. Fallback: `general`

**Why:** Lightweight detection (~5s) with rich per-niche rules. Registry grows independently of skill code. No competitor has this as a plugin feature.

### DD2: Humanization via prompt rules + voice matching (option D)

**Chosen:** Two layers:
- **Always active:** Anti-detection prompt rules in Phase 3 drafting (sentence variation, fragments, entity grounding, structural asymmetry, parenthetical asides, hedging)
- **When `--site-dir` available:** Voice matching — Phase 0 reads 3-5 existing articles, extracts voice profile (sentence rhythm, person, punctuation style, formality, distinctive patterns), Phase 3 constrains drafting to match that profile

**Rejected:**
- (A) Prompt rules only — misses the opportunity to match existing site voice
- (B) Voice matching only — doesn't work without `--site-dir`
- (C) Detection API feedback loop — adds cost/complexity, LLM re-generation still has same fingerprint

**Why:** Prompt rules are free and always-on. Voice matching adds real differentiation when site context exists. No API dependency.

### DD3: FAQ generation from research, not hallucination

**Chosen:** FAQ section generated ONLY when:
1. Topic has informational intent (not product/marketing landing page)
2. Research phase yields 3+ distinct answerable questions (from persona questions or competitor PAA gaps)
3. Article length > 800 words (not COMPACT mode)
4. No existing Q&A section detected in outline

FAQ questions must trace to the research fact sheet. Hallucinated questions blocked by Phase 4 adversarial review.

**Why:** KoalaWriter and Surfer source FAQ from actual PAA data. LLM-hallucinated FAQ degrades quality. Our research phase already produces persona questions — reuse them.

### DD4: Featured snippet targeting per H2

**Chosen:** Phase 2 (Outline) classifies each H2 section by query intent:
- "What is X" / definitional → **paragraph snippet** (40-60 word answer-first block)
- "How to X" / procedural → **list snippet** (ordered `<ol>` steps)
- "X vs Y" / comparison → **table snippet** (clean comparison table)

Phase 3 (Draft) respects this classification when structuring each section.

**Why:** Featured snippets appear in 19% of queries alongside AI Overviews. Format must match query intent — a list answer for a definitional query won't get picked.

### DD5: GEO signals from existing registries

**Chosen:** Reuse checks from `geo-check-registry.md` and `seo-check-registry.md` as GENERATION constraints (not just audit checks):

| Signal | Source | Applied in |
|--------|--------|-----------|
| BLUF ≤30 words first sentence per H2 | G9 | Phase 3 drafting |
| H2 question words (What/How/Why) | G10 | Phase 2 outline |
| Section max 300 words | G6/G10 | Phase 3 drafting |
| Stats with attribution + year | G11 | Phase 3 + Phase 4 review |
| No throat-clearing after headings | G12 | Phase 4 anti-slop review |
| No keyword stuffing (max 3x/500 words) | G12 | Phase 4 review |
| Article `@id` + `isPartOf` Organization | geo-fix template | Phase 5 schema |
| `datePublished` + `dateModified` | G5 | Phase 5 frontmatter |
| OG tags (`og:title`, `og:description`, `og:type`, `og:image`) | D2 | Phase 5 output |

**Why:** These checks already exist in our registries. Applying them at generation time (not just audit time) is zero-cost and ensures articles pass seo-audit and geo-audit on first run.

## Solution Overview

### Changes to write-article SKILL.md

**Phase 0 — additions:**
- Domain detection (cascade: `--domain` → site scan → `general`)
- Voice profile extraction when `--site-dir` available (read 3-5 articles, extract rhythm/person/formality/patterns)
- New arg: `--domain <niche>` override

**Phase 2 — additions:**
- H2 question-word preference (G10)
- Snippet target classification per H2 (paragraph/list/table)
- FAQ candidate collection from persona questions

**Phase 3 — additions:**
- BLUF enforcement: first sentence per H2 section ≤30 words, no throat-clearing (G9/G12)
- Section cap: max 300 words between headings (G6)
- Snippet format compliance per H2 classification
- Stats must carry attribution + year reference (G11)
- Humanization prompt rules (always active):
  - Vary sentence length: include fragments (<8 words) and long sentences (>30 words)
  - No more than 3 consecutive medium-length sentences
  - Use contractions (don't, can't, it's)
  - Include 1+ parenthetical aside per 500 words
  - Include 1+ rhetorical question per 1000 words
  - At least 1 first-person reference per article (we/our/I)
  - Hedging transitions: "but", "although", "that said" — not "Furthermore"
  - Entity grounding: specific versions, dates, named tools per section
  - Structural asymmetry: vary section lengths (no uniform 3-paragraph blocks)
- Voice matching constraints when profile available (match sentence rhythm, person, formality)

**Phase 4 — additions:**
- Anti-slop reviewer gets G12 anti-pattern checks (throat-clearing, keyword density, generic superlatives)
- FAQ quality gate: each FAQ answer must trace to fact sheet

**Phase 5 — additions:**
- Domain-aware multi-schema JSON-LD (per domain-profile-registry)
- FAQ schema when FAQ section present
- OG metadata generation
- `datePublished` + `dateModified` in frontmatter and schema
- Article `@id` + `isPartOf` Organization pattern (from geo-fix template)

### New shared includes

#### `shared/includes/domain-profile-registry.md`

17 niche profiles:

| # | Niche ID | Primary Schema | Secondary Schema | E-E-A-T | Content Rules |
|---|----------|---------------|-----------------|---------|---------------|
| 1 | `health` | Article | MedicalOrganization, Person (medicalSpecialty) | YMYL — hard credentials | Cite clinical sources, author bio with qualifications, no affiliate-first |
| 2 | `finance-legal` | Article | FinancialProduct or LegalService | YMYL — hard credentials | Disclaimers required, author qualifications visible, regulatory signals |
| 3 | `ecommerce` | Product + Offer | AggregateRating, BreadcrumbList | Trust-heavy | Product schema per item, review aggregation, comparison tables |
| 4 | `recipe-food` | Recipe | NutritionInformation, BlogPosting | Standard | Ingredients with quantities, prep/cook time, calories, step-by-step |
| 5 | `travel` | BlogPosting | TouristAttraction, LocalBusiness, Review | Standard + geo | Addresses, hours, coordinates, personal experience, photo placeholders |
| 6 | `local-business` | LocalBusiness (typed) | Review, GeoCoordinates | Standard + geo | NAP consistency, Google Business Profile alignment, sub-type specificity |
| 7 | `news` | NewsArticle | Organization, BreadcrumbList | Quasi-YMYL | datePublished critical, byline, freshness signal, masthead trust |
| 8 | `technical` | BlogPosting | HowTo, FAQPage, SoftwareApplication | Standard | Code examples, step schema, comparison tables, version numbers |
| 9 | `marketing` | Article | Organization, FAQPage | Standard | CTA placement, social proof, benefit-first copy, conversion structure |
| 10 | `market-research` | Article | Dataset reference | Standard | Statistics with attribution, methodology section, date-stamped data, charts/tables |
| 11 | `events` | Event | Organization, Offer, VirtualLocation | Standard | startDate/endDate, location, ticket pricing, performer/speaker |
| 12 | `education` | Article | FAQPage, Person (instructor) | Standard | Instructor bio, learning objectives, syllabus structure (Course schema deprecated) |
| 13 | `real-estate` | RealEstateListing | Place, GeoCoordinates, Offer | Trust-heavy | Location, pricing, property details, neighborhood, gallery placeholders |
| 14 | `saas-product` | SoftwareApplication | Offer, FAQPage, AggregateRating | Standard | Pricing table, feature comparison, changelog, OS/platform, free trial CTA |
| 15 | `personal-brand` | Person | ProfilePage, Organization | Standard | Portfolio links, speaking/media, about page structure, social profiles |
| 16 | `ai-tools` | SoftwareApplication | FAQPage, AggregateRating | Standard | Benchmark tables, model comparison, prompt examples, pricing, API access |
| 17 | `general` | BlogPosting | Person | Lowest bar | Author experience signals, topic clustering, internal links. Fallback niche. |

Per-niche detection signals (for auto-detect from `--site-dir`):

| Niche | Frontmatter signals | Content signals |
|-------|-------------------|-----------------|
| `recipe-food` | tags: recipe/food/cooking, category: recipes | ingredients list, prep time, servings |
| `travel` | tags: travel/destination/hotel, category: travel | addresses, GPS coords, prices in THB/USD/EUR |
| `technical` | tags: tutorial/programming/api, category: dev/engineering | code blocks, npm/pip commands, version numbers |
| `ecommerce` | tags: product/shop/price, schema: Product | price fields, SKU, add-to-cart |
| `marketing` | tags: marketing/growth/conversion, category: marketing | CTA buttons, landing page terms |
| `saas-product` | tags: saas/software/pricing, schema: SoftwareApplication | pricing tiers, feature lists |
| `ai-tools` | tags: ai/llm/model/prompt, category: ai | model names, benchmark scores, API endpoints |
| `news` | schema: NewsArticle, category: news | byline, dateline, breaking/update timestamps |
| `health` | tags: health/medical/wellness, category: health | medical terms, dosage, symptom lists |
| `finance-legal` | tags: finance/legal/investment, category: finance | disclaimers, regulatory references |
| `market-research` | tags: research/data/analysis/report | statistics, methodology, data tables |
| `events` | tags: event/conference/meetup | dates, venues, ticket links |
| `education` | tags: course/learning/tutorial, category: education | syllabus, prerequisites, instructor |
| `real-estate` | tags: property/real-estate/housing | addresses, square footage, pricing |
| `local-business` | tags: local/restaurant/service | business hours, phone, address |
| `personal-brand` | tags: portfolio/about/speaker | social links, bio, achievements |
| `general` | (fallback — no strong signals) | — |

### Changes to existing files

| File | Change |
|------|--------|
| `skills/write-article/SKILL.md` | Add domain detection to Phase 0, snippet targeting to Phase 2, BLUF/humanization/GEO to Phase 3, G12 checks to Phase 4, multi-schema+FAQ+OG to Phase 5. Add `--domain` arg. |
| `skills/write-article/agents/anti-slop-reviewer.md` | Add G12 anti-pattern checks (throat-clearing, keyword density, generic superlatives) |
| `shared/includes/article-output-schema.md` | Expand `seo.schema_type` to support arrays, add `seo.snippet_targets`, `seo.domain`, `seo.faq_count`, `seo.og_tags` |
| `shared/includes/banned-vocabulary.md` | Add G12 throat-clearing phrases and generic superlatives to soft ban list |
| `skills/content-optimize/SKILL.md` | Phase 4 schema update: merge not replace (detect existing `@type` arrays, preserve specific schemas) |

### Edge Cases

| ID | Scenario | Handling |
|----|----------|----------|
| EC-SE-01 | Multi-topic `--site-dir` (travel + dev) | Score signal density. Top two categories within 20% → `domain=mixed`, use `general` schema + FAQ from both. |
| EC-SE-02 | Wrong auto-detection | `--domain` override always wins. Print detection result in SETUP block for user verification. |
| EC-SE-03 | No `--site-dir` | `domain=unknown` → use `general`. No voice matching. Print note. |
| EC-SE-04 | COMPACT mode (<800 words) | Skip deep site scan, FAQ generation, voice matching. Domain detection lightweight (1 file). |
| EC-SE-05 | FAQ without informational intent | Skip FAQ for `marketing` tone + `ecommerce`/`saas-product` niches unless explicitly requested. |
| EC-SE-06 | Conflicting schema types | Single JSON-LD with `@type` array: `["BlogPosting", "Recipe"]`. Never two separate `<script>` tags. |
| EC-SE-07 | Framework-specific schema injection | `astro-mdx`: component placeholder. `hugo`: shortcode hint. `nextjs-mdx`: inline JSON-LD. Unsupported: raw JSON-LD + note. |
| EC-SE-08 | YMYL niche without credentials | Emit WARNING: "YMYL niche detected (health/finance-legal). Articles in this niche require verifiable author credentials for E-E-A-T. Add author bio with qualifications." |
| EC-SE-09 | Voice matching finds no consistent voice | Print "Voice profile: inconclusive (articles too varied)". Fall back to prompt rules only. |
| EC-SE-10 | content-optimize overwrites rich schema | content-optimize Phase 4: detect `@type` arrays → merge, don't replace. Preserve Recipe/HowTo/Event if present. |
| EC-SE-11 | PAA data unavailable (no web search) | Skip FAQ generation. Note: "FAQ omitted — web search unavailable for PAA verification." |
| EC-SE-12 | Recipe niche article without quantities | Emit WARNING: "Recipe niche detected but no ingredient quantities found. Add proportions for Recipe schema compliance." |

## Acceptance Criteria

**Domain detection:**
1. `--domain travel` produces travel-specific schema (TouristAttraction + LocalBusiness)
2. Auto-detection from `--site-dir` with recipe blog produces `domain=recipe-food`
3. No `--site-dir` and no `--domain` → `domain=general` with BlogPosting schema
4. Detection result printed in SETUP block

**Schema generation:**
5. Recipe-food articles emit `@type: ["BlogPosting", "Recipe"]` with NutritionInformation
6. Technical articles emit HowTo schema when step-by-step content present
7. FAQ schema auto-appended when FAQ section exists in final draft
8. All schemas include `@id`, `isPartOf` (Organization), `datePublished`, `dateModified`
9. OG tags (`og:title`, `og:description`, `og:type: article`, `og:image` placeholder) in frontmatter

**GEO signals:**
10. Every H2 section's first sentence ≤30 words, answer-first (G9 BLUF)
11. No section exceeds 300 words between headings (G6 chunkability)
12. H2 headings use question words when topic is informational (G10)
13. Statistics carry source attribution and year (G11)
14. No throat-clearing openers after headings (G12)

**FAQ:**
15. FAQ section only when: informational intent + 3+ research-backed questions + >800 words
16. Each FAQ answer traceable to fact sheet
17. FAQ schema in JSON-LD when FAQ section present

**Featured snippets:**
18. Each H2 classified as paragraph/list/table query type in outline
19. Section content format matches classification (definition=paragraph, steps=ordered list, comparison=table)

**Humanization — prompt rules:**
20. Mix of fragment sentences (<8 words) and long sentences (>30 words) in every article
21. Contractions used throughout (don't, can't, it's)
22. 1+ parenthetical aside per 500 words
23. 1+ rhetorical question per 1000 words
24. At least 1 first-person reference per article
25. No more than 3 consecutive medium-length sentences

**Humanization — voice matching:**
26. When `--site-dir` has 3+ articles, voice profile extracted and printed in SETUP block
27. Draft matches extracted formality level, sentence rhythm, and person preference
28. When voice profile inconclusive, falls back to prompt rules with note

**content-optimize compatibility:**
29. content-optimize Phase 4 merges schema `@type` arrays, never overwrites specific types with BlogPosting

## Out of Scope

- **Content cluster generation** (pillar + spoke articles) — v2 feature, too large for this enhancement
- **Post-publish AI visibility monitoring** (Frase-style) — requires ongoing API integration
- **CMS publish pipeline** (WordPress/Webflow direct posting) — skill writes files only
- **AI detection API integration** (Originality.ai feedback loop) — deferred, LLM re-generation has same fingerprint
- **Paid PAA data sources** (Semrush/Ahrefs API) — FAQ sourced from research phase only
- **Image generation** — schema gets `og:image` placeholder, actual image is user responsibility

## Open Questions

1. ~~**Per-niche word count minimums?**~~ **RESOLVED:** No. Word count depends on topic, not niche. `--length` from user + COMPACT mode <800. Niche registry defines schema/structure/E-E-A-T only.

2. ~~**Voice matching from non-article pages?**~~ **RESOLVED:** Only match against files in the same content directory (e.g., `src/content/blog/`), not about/landing pages. Different voice.
