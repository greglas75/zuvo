# Domain Profile Registry

> Shared include consumed by `write-article` (Phase 0 detection + Phase 5 schema) and `content-optimize` (schema merge awareness). Maps content niches to SEO requirements.

## Detection Cascade

1. `--domain <niche>` explicit override (highest priority)
2. Frontmatter tags/categories scan of 3-5 existing articles in `--site-dir`
3. Fallback: `general`

If top two detected niches score within 20% of each other → `domain=mixed`, use `general` schema.

## Niche Profiles (17)

| # | Niche ID | Primary Schema | Secondary Schema | E-E-A-T | Key Content Rules |
|---|----------|---------------|-----------------|---------|-------------------|
| 1 | `health` | Article | MedicalOrganization, Person | YMYL — hard credentials | Cite clinical sources; author bio with medical qualifications; no affiliate-first |
| 2 | `finance-legal` | Article | FinancialProduct / LegalService | YMYL — hard credentials | Disclaimers required; author qualifications visible; regulatory signals |
| 3 | `ecommerce` | Product + Offer | AggregateRating, BreadcrumbList | Trust-heavy | Product schema per item; review aggregation; comparison tables |
| 4 | `recipe-food` | Recipe | NutritionInformation, BlogPosting | Standard | Ingredients WITH quantities; prep/cook time; calories; step-by-step instructions |
| 5 | `travel` | BlogPosting | TouristAttraction, LocalBusiness, Review | Standard + geo | Addresses, hours, coordinates; personal experience; photo placeholders |
| 6 | `local-business` | LocalBusiness (typed) | Review, GeoCoordinates | Standard + geo | NAP consistency; Google Business Profile alignment; sub-type specificity |
| 7 | `news` | NewsArticle | Organization, BreadcrumbList | Quasi-YMYL | datePublished critical; byline; freshness signal; masthead trust |
| 8 | `technical` | BlogPosting | HowTo, FAQPage, SoftwareApplication | Standard | Code examples; step schema; comparison tables; version numbers |
| 9 | `marketing` | Article | Organization, FAQPage | Standard | CTA placement; social proof; benefit-first copy; conversion structure |
| 10 | `market-research` | Article | Dataset reference | Standard | Statistics with attribution; methodology section; date-stamped data; charts/tables |
| 11 | `events` | Event | Organization, Offer, VirtualLocation | Standard | startDate/endDate; location; ticket pricing; performer/speaker |
| 12 | `education` | Article | FAQPage, Person (instructor) | Standard | Instructor bio; learning objectives; syllabus structure (Course schema deprecated 2025) |
| 13 | `real-estate` | RealEstateListing | Place, GeoCoordinates, Offer | Trust-heavy | Location; pricing; property details; neighborhood; gallery placeholders |
| 14 | `saas-product` | SoftwareApplication | Offer, FAQPage, AggregateRating | Standard | Pricing table; feature comparison; changelog; OS/platform; free trial CTA |
| 15 | `personal-brand` | Person | ProfilePage, Organization | Standard | Portfolio links; speaking/media; about page structure; social profiles |
| 16 | `ai-tools` | SoftwareApplication | FAQPage, AggregateRating | Standard | Benchmark tables; model comparison; prompt examples; pricing; API access |
| 17 | `general` | BlogPosting | Person | Lowest bar | Author experience signals; topic clustering; internal links. Fallback niche. |

## Detection Signals

| Niche | Frontmatter signals | Content signals |
|-------|-------------------|-----------------|
| `recipe-food` | tags: recipe, food, cooking; category: recipes | Ingredients list, prep time, servings, calories |
| `travel` | tags: travel, destination, hotel; category: travel | Addresses, GPS coords, prices in THB/USD/EUR, hotel names |
| `technical` | tags: tutorial, programming, api; category: dev | Code blocks (```), npm/pip commands, version numbers |
| `ecommerce` | tags: product, shop, price; schema: Product | Price fields, SKU, add-to-cart, buy now |
| `marketing` | tags: marketing, growth, conversion | CTA buttons, landing page terms, funnel language |
| `saas-product` | tags: saas, software, pricing; schema: SoftwareApplication | Pricing tiers, feature lists, "free trial", "sign up" |
| `ai-tools` | tags: ai, llm, model, prompt; category: ai | Model names (GPT, Claude, Gemini), benchmark scores, API endpoints |
| `news` | schema: NewsArticle; category: news | Byline, dateline, "breaking", "update" timestamps |
| `health` | tags: health, medical, wellness | Medical terms, dosage, symptom lists, "consult your doctor" |
| `finance-legal` | tags: finance, legal, investment | Disclaimers, "not financial advice", regulatory references |
| `market-research` | tags: research, data, analysis, report | Statistics with %, methodology, data tables, "according to" |
| `events` | tags: event, conference, meetup | Dates, venues, "register", ticket links |
| `education` | tags: course, learning; category: education | Syllabus, prerequisites, "instructor", learning objectives |
| `real-estate` | tags: property, real-estate, housing | Addresses, square footage/meters, pricing, bedrooms |
| `local-business` | tags: local, restaurant, service | Business hours, phone number, street address |
| `personal-brand` | tags: portfolio, about, speaker | Social links, bio, achievements, headshot |
| `general` | (no strong signals detected) | Fallback when no niche scores above threshold |

## FAQ Rules Per Niche

| Niche | Generate FAQ? | Reason |
|-------|:---:|--------|
| `health` | Yes | PAA heavy in health queries; YMYL benefits from structured Q&A |
| `finance-legal` | Yes | Same as health — structured answers build trust |
| `ecommerce` | Skip | Product pages, not informational intent |
| `recipe-food` | Yes | "Can I substitute X?", "How long does it keep?" common PAA |
| `travel` | Yes | "Is X safe?", "Best time to visit?", "How to get from A to B?" |
| `local-business` | Skip | Typically short, service-focused |
| `news` | Skip | Time-sensitive; FAQ adds stale structure |
| `technical` | Yes | "How do I X?", "What's the difference between X and Y?" |
| `marketing` | Skip | CTA-driven, FAQ dilutes conversion focus |
| `market-research` | Yes | Methodology questions, data interpretation |
| `events` | Yes | "How to register?", "Is there parking?", "Will it be recorded?" |
| `education` | Yes | "What are prerequisites?", "How long is the course?" |
| `real-estate` | Yes | "What's included?", "HOA fees?", neighborhood Q&A |
| `saas-product` | Yes | "Free tier?", "How does pricing work?", integration questions |
| `personal-brand` | Skip | Portfolio-style, not Q&A |
| `ai-tools` | Yes | "Which model is best for X?", "API limits?", comparison Q&A |
| `general` | Yes (if informational) | Default: include if topic is informational, skip if opinion/narrative |

## Snippet Format Defaults Per Niche

| Niche | Default H2 format | Rationale |
|-------|------------------|-----------|
| `recipe-food` | list (ordered steps) | Recipes are procedural |
| `technical` | list (ordered steps) | Tutorials are procedural |
| `market-research` | table (data comparisons) | Data-heavy content |
| `ecommerce` | table (product comparisons) | Feature/price comparisons |
| `events` | table (schedule/pricing) | Dates, locations, prices |
| `health` | paragraph (definitions) | Definitional/explanatory |
| `finance-legal` | paragraph (explanatory) | Regulatory explanations |
| All others | paragraph (default) | Override per H2 based on question type |

**Override rule:** The default is a starting point. Phase 2 classifies each individual H2 by its question form: "What is X" → paragraph, "How to X" → ordered list, "X vs Y" → table. The per-H2 classification overrides the niche default.

## YMYL Warning

When niche is `health` or `finance-legal`, emit at Phase 0:

```
WARNING: YMYL niche detected ([niche]). Articles in this niche require:
  - Verifiable author credentials (medical/financial/legal qualifications)
  - Clinical/regulatory source citations
  - Disclaimers where appropriate
  Add author bio with qualifications to frontmatter.
```
