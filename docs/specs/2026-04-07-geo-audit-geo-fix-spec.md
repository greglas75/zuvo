# GEO Audit & Fix Skills — Design Specification

> **spec_id:** 2026-04-07-geo-audit-geo-fix-1415
> **topic:** GEO (Generative Engine Optimization) Audit & Fix Skills
> **status:** Approved
> **created_at:** 2026-04-07T14:15:00Z
> **approved_at:** 2026-04-07T15:55:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

AI-powered search (Google AI Overviews, ChatGPT Browse, Perplexity, Gemini) is replacing traditional search for an increasing share of queries. Whether a website gets cited by these systems depends on signals that traditional SEO only partially covers: schema graph connectivity, AI crawler access policies, content chunkability, BLUF structure, llms.txt presence, and citation-ready formatting.

The existing `seo-audit` covers GEO at surface level (D3, D5, D9, D10 with `--geo` flag), but treats it as a sub-score of SEO rather than a first-class concern. No tool on the market performs GEO auditing at the source code level — all existing tools (Otterly, Scrunch, Apify, SEOptimer) audit live URLs only and cannot tell you which Astro component is missing FAQPage schema, which markdown file lacks author frontmatter, or which Next.js layout injects JSON-LD client-side only.

**If nothing changes:** Users who want deep GEO optimization must manually cross-reference seo-audit's `--geo` output with external URL-based tools, losing the code-level precision that is zuvo's competitive advantage.

**What this spec enables:** Two new skills — `geo-audit` (deep, code-level GEO readiness assessment with 12 dimensions) and `geo-fix` (framework-aware automated fixes for technical GEO issues). Together they make zuvo the first developer tool that audits and fixes GEO at the source code level.

## Design Decisions

### Architecture: Hybrid (Decision 1)

**Chosen:** `geo-audit` is a standalone skill that imports findings from `seo-audit` when available.

- If `audit-results/seo-audit-*.json` exists, geo-audit reads overlapping findings (D3, D5, D9, D10 with `layer: geo`) and incorporates them rather than re-auditing. These findings are tagged `[IMPORTED:seo-audit]` in the report.
- If no seo-audit JSON exists, geo-audit runs all checks independently.
- `seo-audit --geo` is preserved as a lightweight mode. `geo-audit` is the deep mode.
- `geo-fix` consumes `geo-audit-*.json` output. Before applying any fix, it checks for existing `seo-fix-*.json` actions — if the same `fix_type` + `file` was already applied, it skips with status `ALREADY_APPLIED_BY_SEO_FIX`.

**Why not extend seo-audit?** seo-audit is already a large, 13-dimension skill. Adding 8 new GEO-specific dimensions would make it unwieldy and violate the principle that each skill should have a focused mandate. The hybrid pattern preserves both skills' independence while avoiding redundant work.

**Why not fully independent?** Re-auditing robots.txt AI policy, basic schema presence, and llms.txt existence when seo-audit already checked them wastes time and risks inconsistent results.

### Dimension Design: 12 Dimensions, G1-G12 (Decision 2)

**Chosen:** 12 dimensions split into two layers — Technical GEO (G1-G8, scored/blocking) and Content GEO (G9-G12, advisory only).

Content GEO dimensions (G9-G12) use measurable heuristics (regex patterns, word counts, structural checks) rather than subjective LLM quality judgments. They never produce blocking gate failures. On CMS-detected sites, they default to `INSUFFICIENT DATA`.

**Why 12 and not fewer?** Each dimension maps to a distinct, non-overlapping signal category with its own evidence type and fix approach. Merging (e.g., combining schema + canonicalization) would produce dimensions that are too broad to score meaningfully.

### Profile Auto-Detection (Decision 3)

**Chosen:** Auto-detect site profile from codebase signals. Override with `--profile`.

Detection heuristics:
- `blog`: markdown/MDX files in `content/`, `src/content/`, `posts/`, or blog route patterns
- `docs`: `docs/` directory, Docusaurus/Starlight/VitePress config, or docs route patterns
- `ecommerce`: product/cart/checkout components, Shopify/Snipcart/Stripe product config
- `marketing`: no content directory, few pages, landing page patterns
- `app-shell`: SPA framework with no content routes, dashboard patterns

Fallback: `marketing` (safest default — fewest content quality expectations).

### CMS Auto-Detection (Decision 4)

**Chosen:** Auto-detect CMS from code signals. Override with `--cms` or `--no-cms`.

Detection signals:
- WordPress: `wp-config.php`, `wp-content/`, PHP WordPress function calls
- Contentful: `@contentful/rich-text-*` imports, `contentful` SDK usage
- Sanity: `@sanity/client` imports, `sanity.config.*`
- Strapi: `@strapi/*` imports, Strapi API calls
- Prismic: `@prismicio/*` imports
- Any headless CMS: GraphQL queries returning body/content/richText fields to known CMS endpoints (*.contentful.com, *.sanity.io, *.prismic.io, *.strapi.*). Generic GraphQL usage (analytics, feature flags) does NOT trigger CMS detection.

When CMS detected: G9-G12 → `INSUFFICIENT DATA`, executive summary shows `SCOPE NOTICE: "CMS-backed site detected ([type]). Content quality dimensions cannot be assessed from source code. Use --live-url for partial live verification."` This is a first-class status in the report header, not a footnote.

### geo-fix Safety Tiers (Decision 5)

**Chosen:** Four-tier safety model matching seo-fix conventions.

| Safety | Fix types | Notes |
|--------|-----------|-------|
| SAFE | llms.txt generate, robots.txt AI bot allow rules, canonical tag add, sitemap reference in robots.txt | Auto-applied, no validation needed |
| MODERATE | FAQPage/Article/Organization JSON-LD add, `@id` graph linking, dateModified add to frontmatter, alt-text scaffold, meta freshness tags | Applied with 3-layer validation |
| DANGEROUS | robots.txt bot policy change (could open training bots), schema restructure on existing JSON-LD | Never auto-applied, requires explicit user confirmation with diff preview |
| OUT_OF_SCOPE | Content rewriting, BLUF restructuring, heading changes, statistics addition, anti-pattern removal | Emits content scaffold only (suggested outline, target structure, example answer blocks). **Never writes body content.** |

**`fix_safety` enum extension:** This spec adds `"OUT_OF_SCOPE"` as a valid value for the `fix_safety` field in `fix-output-schema.md`, bumping it to v1.2. Migration notes: (1) `OUT_OF_SCOPE` is additive — existing consumers that switch on `fix_safety` should add a default/ignore branch. (2) The `scaffold` field is optional and absent from non-OUT_OF_SCOPE findings. (3) seo-fix does NOT need changes — it never encounters `OUT_OF_SCOPE` in its own output. The new enum value only appears in geo-fix JSON.

**Context-aware safety upgrade** applies to these fix types only:
- `schema-org-add` → upgrades MODERATE→DANGEROUS when target file already has JSON-LD
- `schema-article-add` → upgrades MODERATE→DANGEROUS when target file already has JSON-LD
- `schema-faq-add` → upgrades MODERATE→DANGEROUS when target file already has JSON-LD
- `schema-id-link` → upgrades MODERATE→DANGEROUS when target schema has existing `@id` references
- `robots-ai-allow` → upgrades SAFE→MODERATE when robots.txt already has bot-specific rules
- `canonical-add` → upgrades SAFE→MODERATE when layout already has `<link rel="canonical">`

Other fix types are not subject to safety upgrade. This is encoded as an `upgrade_eligible: true/false` field in `geo-fix-registry.md`.

### Anti-Pattern Detection: Multilingual (Decision 6)

**Chosen:** English-first pattern library with `--lang` flag for additional languages.

Default patterns (English): "In this article we will...", "Let's explore...", "It's important to note that...", "As we all know...", generic superlatives without evidence.

`--lang pl` adds Polish patterns: "W tym artykule omówimy...", "Zanim przejdziemy do...", "Warto wspomnieć, że...".

Detection is regex-based on first 200 characters after each H2/H3. This is measurable and deterministic, not LLM-subjective.

## Solution Overview

```
┌─────────────────────────────────────────────────────┐
│                    User runs                         │
│               zuvo:geo-audit [path]                  │
└──────────────────────┬──────────────────────────────┘
                       │
          ┌────────────▼────────────┐
          │  Phase 0: Detection     │
          │  Stack, Profile, CMS    │
          │  Import seo-audit JSON  │
          └────────────┬────────────┘
                       │
        ┌──────────────┼──────────────┐
        ▼              ▼              ▼
   ┌─────────┐   ┌─────────┐   ┌─────────┐
   │ Agent 1  │   │ Agent 2  │   │ Agent 3  │
   │ Crawl &  │   │ Schema & │   │ Content  │
   │ Access   │   │ Render   │   │ Signals  │
   │ G1,G7,G8 │   │ G2,G4,G5 │   │ G6,G9-12 │
   │          │   │          │   │ G3       │
   └────┬─────┘   └────┬─────┘   └────┬─────┘
        └──────────────┼──────────────┘
                       ▼
          ┌────────────────────────┐
          │  Phase 2: Merge &      │
          │  Score (main agent)    │
          └────────────┬───────────┘
                       ▼
          ┌────────────────────────┐
          │  Phase 3: Validation   │
          │  + Adversarial Review  │
          └────────────┬───────────┘
                       ▼
          ┌────────────────────────┐
          │  Phase 4: Report +     │
          │  JSON Output           │
          │  geo-audit-YYYY-MM-DD  │
          └────────────────────────┘
                       │
                       ▼ (user runs geo-fix)
          ┌────────────────────────┐
          │  geo-fix reads JSON    │
          │  Dedup vs seo-fix      │
          │  Apply by safety tier  │
          │  Adversarial review    │
          │  Build verify          │
          └────────────────────────┘
```

## Detailed Design

### Dimensions

#### G1: AI Crawler Access (blocking gate GCG1)

**What it checks:**
- robots.txt: training vs retrieval bot matrix using `seo-bot-registry.md` taxonomy
  - PASS: retrieval bots (ChatGPT-User, Claude-User, PerplexityBot) allowed
  - PARTIAL: some retrieval bots blocked, some allowed
  - FAIL: all retrieval bots blocked
  - Note: blocking training bots (GPTBot, CCBot) while allowing retrieval bots is a PASS — this is a valid strategic choice
- Cloudflare/WAF detection: scan for `_headers`, `wrangler.toml`, Cloudflare Pages config, Vercel `vercel.json` firewall rules
  - If detected: emit ADVISORY — "WAF/CDN detected ([platform]). AI bot blocking cannot be verified from source code. Manually check: [platform-specific instructions]"
  - Never emit false PASS for WAF-protected sites
- HTTP status per bot UA (`--live-url` only): curl with retrieval bot user-agent strings per `seo-bot-registry.md` (ChatGPT-User, Claude-User, PerplexityBot)
  - 200 = PASS, 403/429/503 = FAIL, timeout = INSUFFICIENT DATA
  - **Bot identity rule:** Both robots.txt scoring and live HTTP checks use the same canonical bot names from `seo-bot-registry.md`. Never mix training bot names (GPTBot, ClaudeBot) with retrieval bot names (ChatGPT-User, Claude-User) — the registry defines the mapping.
- Content negotiation (`--live-url` only): verify `Accept: text/html` returns HTML, not JSON API response
- **WAF detection scoring rule:** When WAF/CDN is detected (Cloudflare, Vercel, etc.) AND `--live-url` is not provided, G1 robots.txt checks are capped at PARTIAL with note: "WAF detected — robots.txt PASS cannot be confirmed without live verification." This prevents false PASS for sites where WAF blocks bots despite permissive robots.txt.

**Evidence:** robots.txt file content, detected WAF indicators, HTTP response codes (live mode).

**Fix types:** `robots-ai-allow` (SAFE — add allow rules for retrieval bots), `robots-ai-policy-change` (DANGEROUS — modify existing bot rules that could open training access).

#### G2: Schema Graph (blocking gate GCG2)

**What it checks:**
- Schema presence: at least one of Organization, Article, FAQPage, WebSite, Person in JSON-LD
- `@id` connectivity: schemas reference each other via `@id`
  - Organization `@id` exists
  - Article/BlogPosting `publisher` → Organization `@id`
  - Article `author` → Person `@id`
  - Person `worksFor` → Organization `@id`
  - WebSite `publisher` → Organization `@id`
- Attribute richness: per Growth Marshal research, generic minimally-populated schema underperforms no schema (41.6% vs 59.8% citation rate). Check required + recommended fields per type:
  - Organization: name, url, logo, sameAs (≥1), foundingDate or description
  - Article: headline, author, datePublished, dateModified, publisher, image
  - Person: name, jobTitle or description, sameAs or url
  - FAQPage: mainEntity with ≥3 Question items, each with acceptedAnswer
- `@graph` pattern: prefer `@graph` array over scattered inline schemas (cleaner for AI parsing)
- Wikidata/Wikipedia `sameAs` links for entity disambiguation

**Evidence:** JSON-LD blocks extracted from layout/page files, `@id` graph map, missing required fields per type.

**Fix types:** `schema-org-add` (MODERATE — add Organization JSON-LD to root layout), `schema-article-add` (MODERATE — add Article JSON-LD to blog/post layout), `schema-faq-add` (MODERATE — add FAQPage to pages with Q/A content), `schema-id-link` (MODERATE — connect existing schemas via `@id`), `schema-restructure` (DANGEROUS — modify existing JSON-LD).

#### G3: llms.txt & AI Discovery

**What it checks:**
- `llms.txt` present in public/static root directory
- Structure per llmstxt.org spec: H1 with site name, optional blockquote summary, H2-delimited sections with markdown links
- `llms-full.txt` companion file present (advisory — not required)
- Link coverage: ratio of indexed pages to llms.txt entries (lower is fine for curated lists, but 0 entries = FAIL)
- llms.txt referenced in or discoverable from robots.txt (emerging convention)

**Evidence:** llms.txt file content, link inventory, llms-full.txt presence.

**Scoring note:** Per Otterly GEO Audit 2.0 (July 2025), llms.txt was removed from their scoring due to "insufficient evidence of impact." This skill includes it as scored (not blocking) because: (a) adoption is at 844K+ sites and growing (Semrush, Oct 2025), (b) low implementation cost, (c) future-proofing. The SKILL.md will note this caveat.

**Fix types:** `llms-txt-generate` (SAFE — generate from sitemap/content index), `llms-txt-update` (SAFE — add missing entries).

#### G4: SSR & Rendering (blocking gate GCG3)

**What it checks:**
- JSON-LD is in SSR output, not injected client-side
  - FAIL patterns: `useEffect` + JSON-LD injection (Next.js), `client:load` island containing schema (Astro), `document.head.appendChild` with schema script
  - PASS patterns: inline `<script type="application/ld+json">` in layout/page component rendered server-side
- Critical content in SSR: H1, H2 headings, first paragraph after H2 (BLUF location) — all must be in server-rendered HTML, not hydration-dependent
- Astro-specific: `client:load`, `client:idle`, `client:visible` directives on components that contain schema or primary content
- Next.js-specific: schema in `page.tsx`/`layout.tsx` (PASS) vs in a `'use client'` component (FAIL)

**Evidence:** framework-specific code patterns in layout/page files, client directive usage.

**Fix types:** No automated fix — SSR migration requires architectural changes. Emit ADVISORY with migration guidance.

#### G5: Freshness Signals

**What it checks:**
- `dateModified` in Article/BlogPosting schema — present and not hardcoded to a static value
- `datePublished` in Article schema — present
- Frontmatter freshness: `date`, `updated`, `lastmod`, `modified` fields in markdown/MDX content files
- Build-time injection detection: if all pages share identical `dateModified`, flag as "likely build-injected — not true content freshness"
- Sitemap `lastmod` values: present and varying (not uniform)
- Visible "Last updated: [date]" pattern in templates (text/UI signal for both users and AI)

**Evidence:** frontmatter field audit across content files, schema dateModified values, sitemap lastmod samples.

**Fix types:** `frontmatter-date-add` (MODERATE — add dateModified to frontmatter), `schema-date-add` (MODERATE — add dateModified to Article schema from frontmatter/git), `freshness-ui-add` (MODERATE — add visible "Updated: date" component to templates).

#### G6: Structured HTML & Chunkability

**What it checks:**
- Tables (`<table>`) in content-heavy pages: present for comparison data
- Ordered/unordered lists in content: present for enumerations, steps, features
- Definition lists (`<dl>/<dt>/<dd>`) for glossaries/terminology (advisory)
- Section length: self-contained passages in the 130–160 word range per Kopp Online Marketing "LLM readability and chunk relevance" research and Writesonic AI Overviews length analysis. Flagged as advisory when sections exceed 300 words without sub-headings.
- Semantic HTML: `<article>`, `<section>`, `<nav>`, `<aside>` vs div-soup

**Evidence:** HTML element inventory per template/page type, section word count distribution.

**Fix types:** No automated content restructuring. Emit ADVISORY with structural suggestions.

#### G7: Canonicalization & URL Hygiene

**What it checks:**
- `<link rel="canonical">` present on all pages
- Canonical self-referencing (page's canonical points to itself, not a different URL)
- Trailing slash consistency: framework config enforces one policy
  - Astro: `trailingSlash` in astro.config
  - Next.js: `trailingSlash` in next.config
  - Hugo: `canonifyURLs` and `relativeURLs` in config
- www vs non-www redirect configuration
- URL parameter handling: no content-bearing URLs with query parameters that create duplicates
- Redirect chains: framework-level redirect config doesn't create chains >1 hop

**Evidence:** canonical tag presence in layout templates, framework config values, redirect configuration.

**Critical gate GCG4:** Canonical tags present in layout template.

**Fix types:** `canonical-add` (SAFE — add canonical tag to base layout), `trailing-slash-config` (MODERATE — set framework config).

#### G8: Sitemap & Discovery

**What it checks:**
- `sitemap.xml` present and valid
- Referenced in `robots.txt` via `Sitemap:` directive
- `lastmod` values present and accurate (not uniform build-time stamps)
- All content pages included (compare sitemap entries to actual content files/routes)
- Sitemap index for large sites (>50K URLs or >50MB)

**Evidence:** sitemap file analysis, robots.txt Sitemap directive, route inventory comparison.

**Fix types:** `sitemap-robots-ref` (SAFE — add Sitemap directive to robots.txt), `sitemap-lastmod-fix` (MODERATE — add/fix lastmod from git/frontmatter dates).

#### G9: BLUF & Answer Blocks (advisory only)

**What it checks (measurable heuristics):**
- First sentence after H2/H3 headings: does it contain a direct statement (not a question, not a "In this section..." opener)?
  - Heuristic: first sentence ≤30 words, no throat-clearing regex match, contains at least one number, proper noun (capitalized word not at sentence start), or technical term (word with hyphen, slash, or dot)
- Answer block presence: 2-3 sentences of direct answer before elaboration
- Profile-aware: `marketing` profile checks for product clarity ("X is a [category] that [does thing]"), not Q/A structure

**Evidence:** first-sentence excerpts per H2/H3, throat-clearing pattern matches.

**On CMS-detected sites:** `INSUFFICIENT DATA`.

**Fix types:** OUT_OF_SCOPE. Emit content scaffold with suggested answer block templates per heading.

#### G10: Heading Structure (advisory only)

**What it checks:**
- Single H1 per page
- H2 headings contain question words (What, How, Why, When, Which, Where, Can, Do, Is, Are, Should) — measured as % of H2s that are questions
- H2/H3 hierarchy: no H3 without preceding H2
- Section length: max 300 words between headings (chunkability for RAG)
- Heading makes sense out of context (no "Overview", "Details", "More Info" without qualifier)

**Evidence:** heading inventory per page/template, question-word match rate, section word counts.

**On CMS-detected sites:** `INSUFFICIENT DATA`.

**Fix types:** OUT_OF_SCOPE. Emit heading restructure suggestions.

#### G11: Citation Signals (advisory only)

**What it checks:**
- Statistics with attribution: regex for patterns like `[number] [unit/percent] [timeframe]? [according to/per/via/by] [source]`
- Dated facts: numbers or claims paired with year references
- Source linking: inline citations or reference sections
- Profile-aware: `docs` and `ecommerce` profiles skip this check (N/A)

**Evidence:** matched citation patterns per content file, count of attributed vs unattributed statistics.

**On CMS-detected sites:** `INSUFFICIENT DATA`.

**Fix types:** OUT_OF_SCOPE. Emit citation scaffold with suggested attribution format.

#### G12: Anti-patterns (advisory only)

**What it checks (regex-based, deterministic):**
- Throat-clearing openers in first 200 chars after H2/H3 (language-specific pattern library)
- Keyword stuffing: same keyword phrase appearing >3× per 500 words
- Generic superlatives: regex match for "best", "leading", "top", "premier", "#1", "world-class" — flagged as advisory pattern. No attempt to verify whether supporting evidence exists nearby (that would require semantic judgment, not regex).
- Filler phrases: "It's important to note that", "As we all know", "Needless to say" (EN default)
- `--lang pl` adds: "Warto wspomnieć, że", "Jak wszyscy wiemy", "W tym artykule omówimy"

**Evidence:** matched anti-pattern instances with line references and surrounding context.

**On CMS-detected sites:** `INSUFFICIENT DATA`.

**Fix types:** OUT_OF_SCOPE. Emit anti-pattern report only.

### Critical Gates Summary

| Gate | Check | Dimension | Enforcement |
|------|-------|-----------|-------------|
| GCG1 | Retrieval bots not blocked in robots.txt | G1 | blocking |
| GCG2 | ≥1 schema type present AND has `@id` field | G2 | blocking — FAIL condition: no schema has `@id`. Note: schema present WITHOUT `@id` = G2 dimension PARTIAL score but GCG2 FAIL. Schema absent entirely = both G2 FAIL and GCG2 FAIL. |
| GCG3 | JSON-LD is SSR-rendered (not client-only) | G4 | blocking |
| GCG4 | Canonical tags present in layout | G7 | blocking |

Any critical gate FAIL → overall result "FAIL" regardless of score. INSUFFICIENT DATA on a blocking gate → result "PROVISIONAL".

### Scoring Model

Reuses seo-audit's scoring mechanics:

- Check → value: PASS=1.0, PARTIAL=0.5, FAIL=0.0, INSUFFICIENT DATA=excluded
- Dimension score = sum(check values) / count(non-excluded checks) × 100
- Overall = weighted sum of dimension scores

**Dimension weights (sum to 100%):**

| Dimension | Weight | Rationale |
|-----------|--------|-----------|
| G1: AI Crawler Access | 15% | Blocking if wrong — no access = no citation |
| G2: Schema Graph | 18% | Core GEO signal; attribute richness matters more than presence |
| G3: llms.txt | 8% | Growing but unconfirmed impact; low weight reflects uncertainty |
| G4: SSR & Rendering | 12% | Binary gate — if schema isn't SSR, nothing else matters |
| G5: Freshness Signals | 10% | Strong empirical signal — cited pages avg 1,064 days old vs 1,432 for organic results, 25.7% freshness advantage (Ahrefs, n=17M citations) |
| G6: Structured HTML | 7% | Aids extraction but not decisive alone |
| G7: Canonicalization | 10% | Prevents attribution fragmentation |
| G8: Sitemap | 5% | Discovery aid, not citation driver |
| G9: BLUF | 5% | Advisory; 44.2% of citations from first 30% of text (Kevin Indig, Feb 2026, 100M+ AI citations analysis via Similarweb) |
| G10: Heading Structure | 4% | Advisory; structured H1-H2-H3 pages 2.8× more likely cited (Incremys study) |
| G11: Citation Signals | 3% | Advisory; +41% with statistics (Princeton GEO) |
| G12: Anti-patterns | 3% | Advisory; keyword stuffing = -10% (Princeton GEO) |

**Tier boundaries:** A (≥85), B (70-84), C (50-69), D (<50). Consistent with seo-audit for cross-skill comparability.

### Agent Dispatch

Three parallel agents (Claude Code: Task tool, sonnet model, Explore type):

| Agent | Dimensions | File |
|-------|-----------|------|
| Crawl & Access Agent | G1, G7, G8 | `agents/geo-crawl-access.md` |
| Schema & Render Agent | G2, G4, G5 | `agents/geo-schema-render.md` |
| Content Signals Agent | G3, G6, G9, G10, G11, G12 | `agents/geo-content-signals.md` |

Agents return raw check statuses only (PASS/PARTIAL/FAIL/INSUFFICIENT DATA). The main agent calculates all scores in a dedicated scoring phase. This boundary is strictly enforced (same pattern as seo-audit).

### seo-audit Import Protocol

Phase 0 includes an import step:

1. Scan `audit-results/` for `seo-audit-*.json` files
2. If found, select the file with the lexicographically greatest filename (ISO date + optional `-N` suffix ensures correct ordering)
3. Extract findings with `layer: geo` from dimensions D3, D5, D9, D10. Also extract `critical_gates.CG5` status from the JSON root object (CG5 is a gate value, not a dimension finding — handled separately).
4. Map to geo-audit dimensions:
   - D5 `robots-ai-policy` → G1
   - D5 `llms-txt-present` → G3
   - D3 JSON-LD checks → G2
   - D3 CG5 (SSR) → G4
   - D9 `heading-structure` → G10
   - D9 `answer-first` → G9
   - D10 `freshness` → G5
   - D10 `semantic-html` → G6
   - D10 `eeat-signals` → G2/G5
5. Imported findings are tagged `[IMPORTED:seo-audit]` and use the seo-audit's evidence
6. geo-audit adds its own deeper checks on top (e.g., `@id` graph connectivity goes beyond D3's schema presence check)
7. If imported finding conflicts with geo-audit's own check, geo-audit's result takes precedence (it's deeper). The conflict is noted in the finding's `confidence_reason` field: "Overrides imported seo-audit finding [id] which reported [status]."

**Dependency direction constraint:** geo-audit MAY read seo-audit output. seo-audit MUST NOT read geo-audit output. This prevents circular dependency between the two skills.

### Framework Detection

Reuses seo-audit Phase 0.2 detection logic (bash `find` commands):

| Framework | Detection signals |
|-----------|-----------------|
| Astro | `astro.config.*` |
| Next.js | `next.config.*` |
| Hugo | `hugo.toml`, `hugo.yaml`, `config.toml` with Hugo patterns |
| Nuxt | `nuxt.config.*` |
| SvelteKit | `svelte.config.*` |
| Gatsby | `gatsby-config.*` |
| WordPress | `wp-config.php`, `wp-content/` |
| Docusaurus | `docusaurus.config.*` |
| VitePress | `.vitepress/config.*` |
| Remix | `remix.config.*`, `app/root.tsx` |

### geo-fix Integration

`geo-fix` follows the same architectural pattern as `seo-fix`:

1. Reads `audit-results/geo-audit-YYYY-MM-DD.json`
2. Filters to: (a) FAIL and PARTIAL findings with `fix_type` != null, AND (b) OUT_OF_SCOPE findings with `fix_safety: "OUT_OF_SCOPE"` (for scaffold emission)
3. Dedup check: reads `audit-results/seo-fix-*.json` for already-applied fixes with matching `fix_type` + `file`
4. Plans fixes by safety tier (SAFE first, then MODERATE, skip DANGEROUS unless `--all`)
5. Applies fixes per framework using templates from `geo-fix-registry.md`
6. Runs adversarial review on staged diff. **Enforcement rule:** adversarial reviewer MUST verify that OUT_OF_SCOPE scaffolds contain only structural markers (HTML comments, placeholder text like `<!-- TODO: Add answer block here -->`) and NO generated prose body content. Any generated body text = adversarial review FAIL.
7. Build verification
8. Outputs `audit-results/geo-fix-YYYY-MM-DD.json`

### JSON Output Schema

Uses shared `audit-output-schema.md` v1.1 with `"skill": "geo-audit"`. Key fields:

```json
{
  "version": "1.1",
  "skill": "geo-audit",
  "created_at": "2026-04-07T14:15:00Z",
  "project": "example-site",
  "profile": "blog",
  "cms_detected": null,
  "seo_audit_imported": "2026-04-06",
  "score": {
    "overall": 72,
    "tier": "B",
    "dimensions": {
      "G1": { "score": 85, "checks": 4, "excluded": 1 },
      ...
    }
  },
  "critical_gates": {
    "GCG1": "PASS",
    "GCG2": "FAIL",
    "GCG3": "PASS",
    "GCG4": "PASS"
  },
  "findings": [
    {
      "id": "G2-schema-id-disconnected",
      "display_id": "F3",
      "dimension": "G2",
      "enforcement": "scored",
      "status": "FAIL",
      "description": "Organization and Article schemas have @id but are not cross-referenced",
      "evidence": "...",
      "confidence_reason": "...",
      "severity": "HIGH",
      "priority": 2.4,
      "fix_type": "schema-id-link",
      "fix_safety": "MODERATE",
      "fix_params": { "file": "src/layouts/BaseLayout.astro" },
      "imported_from": null
    }
  ],
  "scope_notices": ["CMS-backed site..."],
  "advisories": ["Cloudflare detected..."]
}
```

### New Shared Includes

| File | Purpose |
|------|---------|
| `shared/includes/geo-check-registry.md` | Canonical check slugs for G1-G12: slug, enforcement, owner_agent, evidence_mode, profile_overrides, fix_type mapping, `last_reviewed` date |
| `shared/includes/geo-fix-registry.md` | Fix type IDs, safety tier, fix_params schema, framework-specific templates |

Both modeled on existing `seo-check-registry.md` and `seo-fix-registry.md`.

### Flags & Arguments

**geo-audit:**

| Flag | Default | Description |
|------|---------|-------------|
| `[path]` | `.` | Scope to directory or file |
| `--profile` | auto-detect | Override: `blog`, `docs`, `ecommerce`, `marketing`, `app-shell` |
| `--cms` / `--no-cms` | auto-detect | Override CMS detection |
| `--live-url URL` | none | Enable live checks (G1 HTTP status, content negotiation) |
| `--lang LANG` | `en` | Anti-pattern language: `en`, `pl` (v1 scope). Additional languages (`de`, `es`, `fr`) deferred to v2. |
| `--persist-backlog` | false | Persist findings to zuvo backlog |
| _(no --json flag)_ | — | JSON output is always on. No flag needed — geo-audit always writes `geo-audit-*.json`. |

**geo-fix:**

| Flag | Default | Description |
|------|---------|-------------|
| (no args) | latest audit | Read latest `geo-audit-*.json` |
| `--dry-run` | false | Show planned fixes without applying |
| `--auto` | SAFE only | Apply SAFE + MODERATE fixes |
| `--all` | false | Include DANGEROUS fixes (requires confirmation per fix) |
| `--skip-adversarial` | false | Skip cross-provider review of fixes |

## Acceptance Criteria

1. geo-audit produces a structured report with explicit status for all 12 dimensions (PASS/PARTIAL/FAIL/INSUFFICIENT DATA/N/A — no dimension silently omitted)
2. Every FAIL or PARTIAL finding has file-level evidence (file path, extracted content, or explicit "INSUFFICIENT DATA — requires live audit")
3. All 4 critical gates have explicit status in the report
4. Scope limitations (CMS, SPA, app-shell profile) appear in the executive summary, not buried in findings
5. JSON output validates against `audit-output-schema.md` v1.1
6. When `seo-audit-*.json` exists, overlapping findings are imported (not re-audited) and tagged `[IMPORTED:seo-audit]`
7. geo-fix deduplicates against `seo-fix-*.json` before applying any fix
8. geo-fix never auto-writes body content — content quality findings emit scaffolds only
9. Content GEO dimensions (G9-G12) never produce blocking gate failures
10. CMS-detected sites have G9-G12 set to INSUFFICIENT DATA with SCOPE NOTICE
11. Profile auto-detection correctly identifies blog, docs, ecommerce, marketing, and app-shell sites (verified against 5+ reference codebases)
12. Multilingual anti-pattern detection works for `--lang en` (default) and at least `--lang pl`
13. Training vs. retrieval bot distinction is explicit: blocking GPTBot (training) while allowing ChatGPT-User (retrieval) is scored as PASS, not FAIL
14. Schema attribute richness check distinguishes "schema present but empty" from "schema present and complete" — penalizes the former more
15. When a geo-audit check produces a different result than an imported seo-audit finding, the geo-audit result is used and the conflict is noted in `confidence_reason`
16. `--persist-backlog` passes findings to the existing zuvo backlog system using `backlog-protocol.md` fingerprint format `{file}|{dimension}|{check}`

## Out of Scope

- **Live URL crawling beyond `--live-url` flag:** This is not a web crawler. Deep crawl analysis is handled by external tools (Otterly, Screaming Frog).
- **AI citation monitoring:** Tracking whether a site actually appears in AI responses over time. This is a SaaS product category (Profound, Peec AI), not a code audit.
- **Content generation:** geo-fix will never generate body text, blog posts, FAQ answers, or statistics. It emits structural scaffolds only.
- **Platform-specific optimization:** Optimizing differently for ChatGPT vs Perplexity vs Google AI. The audit targets universal GEO signals. Platform-specific tuning is a future iteration.
- **WordPress plugin configuration:** If CMS is detected, the audit notes gaps but cannot configure Yoast/RankMath settings.
- **Paid schema validation APIs:** No dependency on Google Rich Results Test API or similar external services. Code-level heuristics only (with `--live-url` as optional enhancement).

## Open Questions

1. **llms.txt weight:** Should llms.txt be scored at all given Otterly's removal? Current decision: scored at low weight (8%) with caveat in report. Revisit when empirical data improves.
2. **Schema type coverage:** The spec covers Organization, Article, Person, FAQPage, WebSite. Should geo-audit also check Product, HowTo, Recipe, Event schemas for GEO relevance? Recommendation: add in v2 based on user feedback.
3. **`--live-url` implementation:** Should this use `curl` directly, or leverage chrome-devtools MCP for full rendered output? Current decision: curl for simplicity. Chrome-devtools is a future enhancement for SPA verification.
4. **Interaction with `seo-audit --geo`:** Should `seo-audit --geo` be deprecated, or should it remain as a "quick GEO check" that recommends running `geo-audit` for deep analysis? Current decision: keep both, add a note in seo-audit output suggesting geo-audit for deeper analysis.
5. **Reverse dedup (seo-fix after geo-fix):** geo-fix checks seo-fix output before applying fixes, but if geo-fix runs first and seo-fix runs later, seo-fix has no awareness of geo-fix actions. Deferred to v2 — either add symmetric dedup to seo-fix, or introduce a shared `applied-fixes.json` ledger.
