# GEO Check Registry (canonical slugs)

> Single source of truth for all check IDs used in `geo-audit` findings.
> Agents MUST use these exact slugs in `findings[].check`.
> Finding ID = `{dimension}-{check_slug}` (for example `G1-retrieval-bots-access`).

## Canonical Columns

| field | purpose |
|------|---------|
| `owner_agent` | The audit agent responsible for evaluating the check. |
| `layer` | One of `geo` or `hygiene`. |
| `enforcement` | One of `blocking`, `scored`, or `advisory`. |
| `evidence_mode` | One of `code`, `live`, `either`, or `proxy`. |
| `fix_type` | Shared remediation mapping when the check is auto-fixable. |
| `last_reviewed` | Date of last registry review (YYYY-MM-DD). |

## Semantic Notes

- **Import overlaps with seo-audit:** G1 robots checks overlap with seo-audit D5 (`robots-ai-policy`, `bot-policy-matrix`). G2 schema checks overlap with D3 (`json-ld-present`, `json-ld-ssr`, `json-ld-required-fields`). G9–G12 content signal checks overlap with D9 (`answer-first`, `heading-structure`) and D10 (`chunkability`, `semantic-html`).
- **When imported from seo-audit JSON:** Use the imported status directly for overlapping checks — do NOT re-evaluate them. Mark imported checks with `source: seo-audit` in the findings object.
- **Dependency direction:** geo-audit MAY read seo-audit output JSON. seo-audit MUST NOT read geo-audit output. This is a one-way dependency: geo depends on seo, not the reverse.

## G1 — AI Crawler Access

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `retrieval-bots-access` | Retrieval bots (ChatGPT-User, Claude-User, PerplexityBot) allowed in robots.txt | `geo-crawl-access` | geo | blocking | code | GCG1 | `robots-ai-allow` |
| `training-bots-policy` | Training bots policy is explicit (conscious choice) | `geo-crawl-access` | geo | scored | code | — | — |
| `waf-detection` | Cloudflare/WAF detected — advisory for manual check | `geo-crawl-access` | hygiene | advisory | code | — | — |
| `http-bot-status` | HTTP 200 for retrieval bot UAs | `geo-crawl-access` | geo | scored | live | — | — |
| `content-negotiation` | Accept: text/html returns HTML | `geo-crawl-access` | geo | scored | live | — | — |

## G2 — Schema Graph

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `schema-type-present` | ≥1 JSON-LD schema type present (Organization/Article/FAQPage/WebSite/Person) | `geo-schema-render` | geo | scored | code | — | `schema-org-add` |
| `schema-id-connected` | Schemas connected via @id references | `geo-schema-render` | geo | blocking | code | GCG2 | `schema-id-link` |
| `schema-attribute-rich` | Required + recommended fields populated per type | `geo-schema-render` | geo | scored | code | — | — |
| `schema-graph-pattern` | Uses @graph array (preferred over scattered schemas) | `geo-schema-render` | hygiene | advisory | code | — | — |
| `schema-sameas-present` | Wikidata/Wikipedia sameAs links for entities | `geo-schema-render` | geo | scored | code | — | — |

## G3 — llms.txt & AI Discovery

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `llms-txt-present` | llms.txt in public/static root | `geo-content-signals` | geo | scored | code | — | `llms-txt-generate` |
| `llms-txt-structure` | H1 site name, blockquote, H2 sections per llmstxt.org spec | `geo-content-signals` | geo | scored | code | — | `llms-txt-update` |
| `llms-full-present` | llms-full.txt companion | `geo-content-signals` | geo | advisory | code | — | — |
| `llms-txt-coverage` | Link coverage ratio (entries vs indexed pages) | `geo-content-signals` | geo | scored | code | — | `llms-txt-update` |
| `llms-robots-ref` | llms.txt referenced/discoverable from robots.txt | `geo-content-signals` | hygiene | advisory | code | — | — |

## G4 — SSR & Rendering

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `json-ld-ssr` | JSON-LD in SSR output, not client-side injection | `geo-schema-render` | geo | blocking | code | GCG3 | — |
| `content-ssr` | H1, H2, first paragraph in server-rendered HTML | `geo-schema-render` | geo | scored | code | — | — |
| `astro-island-check` | No schema/content in client:load/idle/visible islands | `geo-schema-render` | geo | scored | code | — | — |
| `nextjs-client-check` | No JSON-LD in 'use client' components | `geo-schema-render` | geo | scored | code | — | — |

## G5 — Freshness Signals

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `date-modified-present` | dateModified in Article schema, not hardcoded | `geo-schema-render` | geo | scored | code | — | `schema-date-add` |
| `date-published-present` | datePublished in Article schema | `geo-schema-render` | geo | scored | code | — | `schema-date-add` |
| `frontmatter-freshness` | date/updated/lastmod fields in content frontmatter | `geo-schema-render` | geo | scored | code | — | `frontmatter-date-add` |
| `build-time-detection` | Uniform dateModified flagged as build-injected | `geo-schema-render` | hygiene | advisory | code | — | — |
| `freshness-ui-visible` | Visible "Last updated: date" in templates | `geo-schema-render` | geo | advisory | code | — | `freshness-ui-add` |

## G6 — Structured HTML & Chunkability

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `tables-present` | Tables in content-heavy pages | `geo-content-signals` | geo | scored | code | — | — |
| `lists-present` | Ordered/unordered lists in content | `geo-content-signals` | geo | scored | code | — | — |
| `definition-lists` | dl/dt/dd for glossaries | `geo-content-signals` | geo | advisory | code | — | — |
| `section-length` | 130-160 word sections (Kopp research); >300 flagged | `geo-content-signals` | geo | advisory | code | — | — |
| `semantic-html-elements` | article/section/nav/aside vs div-soup | `geo-content-signals` | geo | scored | code | — | — |

## G7 — Canonicalization & URL Hygiene

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `canonical-present` | link rel=canonical on all pages | `geo-crawl-access` | geo | blocking | code | GCG4 | `canonical-add` |
| `canonical-self-ref` | Canonical points to self | `geo-crawl-access` | geo | scored | code | — | — |
| `trailing-slash-config` | Framework enforces trailing slash policy | `geo-crawl-access` | hygiene | scored | code | — | `trailing-slash-config` |
| `www-redirect` | www vs non-www redirect configured | `geo-crawl-access` | hygiene | scored | code | — | — |
| `url-param-handling` | No duplicate content from URL parameters | `geo-crawl-access` | hygiene | advisory | code | — | — |

## G8 — Sitemap & Discovery

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `sitemap-present` | sitemap.xml exists and valid | `geo-crawl-access` | geo | scored | code | — | — |
| `sitemap-robots-ref` | Sitemap: directive in robots.txt | `geo-crawl-access` | geo | scored | code | — | `sitemap-robots-ref` |
| `sitemap-lastmod` | lastmod values present and varying (not uniform) | `geo-crawl-access` | geo | scored | code | — | `sitemap-lastmod-fix` |
| `sitemap-coverage` | Content pages included in sitemap | `geo-crawl-access` | geo | advisory | code | — | — |

## G9 — BLUF & Answer Blocks

All checks in G9 are `advisory`. Profile: app-shell → N/A; CMS detected → INSUFFICIENT DATA.

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `bluf-first-sentence` | First sentence after H2/H3: ≤30 words, no throat-clearing, contains number/proper noun/technical term | `geo-content-signals` | geo | advisory | code | — | — |
| `answer-block-present` | 2-3 sentences direct answer before elaboration | `geo-content-signals` | geo | advisory | code | — | — |
| `profile-bluf-check` | Marketing profile: product clarity check | `geo-content-signals` | geo | advisory | code | — | — |

## G10 — Heading Structure

All checks in G10 are `advisory`. Profile: app-shell → N/A; CMS detected → INSUFFICIENT DATA.

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `single-h1` | One H1 per page | `geo-content-signals` | geo | advisory | code | — | — |
| `h2-question-words` | H2s contain question words (What/How/Why...) | `geo-content-signals` | geo | advisory | code | — | — |
| `heading-hierarchy` | No H3 without preceding H2 | `geo-content-signals` | geo | advisory | code | — | — |
| `section-word-limit` | Max 300 words between headings | `geo-content-signals` | geo | advisory | code | — | — |
| `heading-context` | Headings make sense out of context | `geo-content-signals` | geo | advisory | code | — | — |

## G11 — Citation Signals

All checks in G11 are `advisory`. Profile: docs/ecommerce → N/A; app-shell → N/A; CMS detected → INSUFFICIENT DATA.

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `stats-with-attribution` | Statistics with source/timeframe regex | `geo-content-signals` | geo | advisory | code | — | — |
| `dated-facts` | Numbers paired with year references | `geo-content-signals` | geo | advisory | code | — | — |
| `source-linking` | Inline citations or reference sections | `geo-content-signals` | geo | advisory | code | — | — |

## G12 — Anti-patterns

All checks in G12 are `advisory`. Profile: app-shell → N/A; CMS detected → INSUFFICIENT DATA.

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | GCG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|------|----------|
| `throat-clearing` | Throat-clearing openers in first 200 chars after H2/H3 | `geo-content-signals` | geo | advisory | code | — | — |
| `keyword-stuffing` | Same phrase >3× per 500 words | `geo-content-signals` | geo | advisory | code | — | — |
| `generic-superlatives` | best/leading/top/premier/#1/world-class regex | `geo-content-signals` | geo | advisory | code | — | — |
| `filler-phrases` | "It's important to note that" etc. (EN + PL with --lang) | `geo-content-signals` | geo | advisory | code | — | — |

---

## Summary

| Dimension | Name | Check count |
|-----------|------|------------|
| G1 | AI Crawler Access | 5 |
| G2 | Schema Graph | 5 |
| G3 | llms.txt & AI Discovery | 5 |
| G4 | SSR & Rendering | 4 |
| G5 | Freshness Signals | 5 |
| G6 | Structured HTML & Chunkability | 5 |
| G7 | Canonicalization & URL Hygiene | 5 |
| G8 | Sitemap & Discovery | 4 |
| G9 | BLUF & Answer Blocks | 3 |
| G10 | Heading Structure | 5 |
| G11 | Citation Signals | 3 |
| G12 | Anti-patterns | 4 |
| **Total** | | **53** |
| Blocking checks | | 4 (GCG1-GCG4) |

## Profile Override Notes

| Profile | Dimensions affected | Override |
|---------|---------------------|---------|
| `app-shell` | G9, G10, G11, G12 | N/A — no long-form content to evaluate |
| `cms-detected` | G9, G10, G11, G12 | INSUFFICIENT DATA — content not in source |
| `docs` | G11 | N/A — citations not applicable |
| `ecommerce` | G11 | N/A — citations not applicable |
