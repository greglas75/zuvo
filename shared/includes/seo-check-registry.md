# SEO Check Registry (canonical slugs)

> Single source of truth for all check IDs used in `seo-audit` findings.
> Agents MUST use these exact slugs in `findings[].check`.
> Finding ID = `{dimension}-{check_slug}` (for example `D4-sitemap-exists`).

## Canonical Columns

| field | purpose |
|------|---------|
| `owner_agent` | The audit agent responsible for evaluating the check. |
| `layer` | One of `core`, `hygiene`, `geo`, or `visibility-deferred`. |
| `enforcement` | One of `blocking`, `scored`, or `advisory`. |
| `evidence_mode` | One of `code`, `live`, `either`, or `proxy`. |
| `fix_type` | Shared remediation mapping when the check is auto-fixable. |

## Semantic Notes

- `llms-spec-compliance` is represented by the D5 presence/accessibility checks
  `llms-txt-present` and `llms-full-txt-present`.
- `llms-best-practice` is represented by the D10 quality check
  `llms-txt-quality`.
- `llms-txt-noindex` ensures `llms.txt` and `llms-full.txt` serve an
  `X-Robots-Tag: noindex` HTTP header. This prevents search engines from
  indexing plain-text files that would appear as "No information available" in
  SERPs, while keeping them fully crawlable for AI bots. Do NOT use
  `robots.txt Disallow` for this purpose — `Disallow` blocks crawling, not
  indexing, and the URL can still appear in search results via external links.
- D9/D10 heuristics are `scored` by default, but the page-profile registry may
  downgrade them to `advisory` or `N/A` for specific page classes.

## D1 — Meta Tags and On-Page SEO

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `title-present` | Title tag exists | `seo-technical` | hygiene | scored | code | -- | null |
| `title-length` | Title 30-60 chars | `seo-technical` | hygiene | scored | code | -- | null |
| `meta-description-present` | Meta description exists | `seo-technical` | hygiene | scored | code | -- | null |
| `meta-description-length` | Meta description 120-160 chars | `seo-technical` | hygiene | scored | code | -- | null |
| `viewport-present` | Viewport meta tag present | `seo-technical` | hygiene | scored | code | -- | `viewport-add` |
| `heading-hierarchy` | H1 exists with sane H1>H2>H3 nesting | `seo-technical` | hygiene | scored | code | -- | null |
| `unique-titles` | No duplicate titles across pages | `seo-technical` | hygiene | scored | code | -- | null |

## D2 — Open Graph and Social

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `og-title` | `og:title` present | `seo-assets` | hygiene | scored | code | -- | `meta-og-add` |
| `og-description` | `og:description` present | `seo-assets` | hygiene | scored | code | -- | `meta-og-add` |
| `og-image` | `og:image` present with usable target | `seo-assets` | hygiene | scored | either | -- | `meta-og-add` |
| `og-image-dimensions` | OG image dimensions are sane | `seo-assets` | hygiene | scored | either | -- | null |
| `og-type` | `og:type` matches page class | `seo-assets` | hygiene | scored | code | -- | `meta-og-add` |
| `twitter-card` | `twitter:card` present | `seo-assets` | hygiene | scored | code | -- | `meta-og-add` |

## D3 — Structured Data (JSON-LD)

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `json-ld-present` | JSON-LD script tag exists on key page types | `seo-assets` | core | scored | code | -- | `json-ld-add` |
| `json-ld-ssr` | JSON-LD is present in the initial response, not client-only | `seo-assets` | core | blocking | either | CG5 | `json-ld-add` |
| `json-ld-schema-match` | Schema type matches page intent | `seo-assets` | core | scored | code | -- | null |
| `json-ld-required-fields` | Required fields are populated for the declared schema | `seo-assets` | core | scored | code | -- | `json-ld-add` |
| `json-ld-duplicate-types` | No duplicate or spam-like JSON-LD blocks | `seo-assets` | core | scored | either | -- | `schema-cleanup` |

## D4 — Sitemap

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `sitemap-exists` | Sitemap generation config or sitemap file exists | `seo-technical` | core | blocking | either | CG1 | `sitemap-add` |
| `sitemap-coverage` | Sitemap covers public routes | `seo-technical` | core | scored | either | -- | `sitemap-add` |
| `sitemap-lastmod` | `lastmod` data is present and plausible | `seo-technical` | hygiene | scored | either | -- | `sitemap-add` |
| `sitemap-robots-ref` | `robots.txt` references the sitemap | `seo-technical` | hygiene | scored | code | -- | `robots-fix` |

## D5 — AI Crawlers and Crawlability

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `robots-exists` | `robots.txt` exists and parses into agent blocks | `seo-technical` | core | scored | code | -- | `robots-fix` |
| `robots-googlebot` | Googlebot is not blocked | `seo-technical` | core | blocking | either | CG2 | `robots-fix` |
| `robots-ai-policy` | AI bot policy is conscious and internally consistent | `seo-technical` | core | blocking | either | CG6 | `robots-fix` |
| `bot-policy-matrix` | Canonical AI bot matrix is explicit for relevant tiers and live probes when available | `seo-technical` | core | scored | either | -- | `robots-fix` |
| `cloudflare-override-risk` | Edge controls such as Cloudflare are surfaced when they may override file-based crawler policy | `seo-technical` | hygiene | advisory | proxy | -- | `robots-fix` |
| `robots-js-block` | `robots.txt` does not block `/*.js*` assets needed for rendering | `seo-technical` | hygiene | advisory | code | -- | `robots-fix` |
| `robots-pdf-block` | `robots.txt` does not unintentionally block `/*.pdf$` resources | `seo-technical` | hygiene | advisory | code | -- | `robots-fix` |
| `robots-feed-block` | `robots.txt` does not unintentionally block feeds such as `/*.feed*` or RSS endpoints | `seo-technical` | hygiene | advisory | code | -- | `robots-fix` |
| `llms-txt-present` | llms-spec-compliance: minimal `llms.txt` exists and is accessible | `seo-technical` | geo | scored | either | -- | `llms-txt-add` |
| `llms-full-txt-present` | llms-spec-compliance companion: rich `llms-full.txt` exists when the site claims a richer AI index | `seo-technical` | geo | advisory | either | -- | `llms-txt-add` |
| `llms-txt-noindex` | llms files serve `X-Robots-Tag: noindex` header to prevent search engine indexing while keeping them crawlable for AI bots | `seo-technical` | geo | scored | either | -- | `headers-add` |
| `crawl-delay` | No excessive crawl-delay or blanket throttling | `seo-technical` | hygiene | advisory | code | -- | null |

## D6 — Images

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `img-alt-text` | Alt text is present on content images and decorative images are explicit | `seo-assets` | hygiene | scored | code | -- | `alt-text-add` |
| `img-modern-format` | Modern image formats are used where appropriate | `seo-assets` | hygiene | scored | code | -- | null |
| `img-lazy-loading` | Below-the-fold images are lazily loaded | `seo-assets` | hygiene | scored | code | -- | null |
| `img-dimensions` | Width/height or aspect reservation prevents layout shift | `seo-assets` | hygiene | scored | code | -- | null |

## D7 — Internal Linking

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `orphan-risk` | Potential orphan pages are surfaced as a risk, not a definitive failure | `seo-content` | hygiene | advisory | proxy | -- | null |
| `nav-consistency` | Navigation patterns are consistent and expose primary routes | `seo-content` | hygiene | scored | code | -- | null |
| `broken-link-patterns` | Broken internal link patterns are absent in source | `seo-content` | hygiene | scored | code | -- | null |

## D8 — Performance (Code-Level)

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `render-blocking` | No obvious render-blocking resource patterns | `seo-assets` | hygiene | scored | either | -- | null |
| `font-loading` | Fonts use `font-display: swap` or equivalent | `seo-assets` | hygiene | scored | code | -- | `font-display-add` |
| `img-optimization` | Image optimization primitives are used | `seo-assets` | hygiene | scored | code | -- | null |
| `js-bundle` | No excessive JS bundle indicators for the chosen stack | `seo-assets` | hygiene | scored | proxy | -- | null |

## D9 — Content Quality

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `thin-content` | Page content meets profile-aware depth expectations | `seo-content` | geo | scored | proxy | -- | null |
| `answer-first` | Primary answer or summary appears early enough for the page profile | `seo-content` | geo | scored | proxy | -- | null |
| `heading-structure` | Heading structure supports scanability and extraction | `seo-content` | geo | scored | proxy | -- | null |
| `duplicate-titles` | Content title patterns are not duplicated or template-stale | `seo-content` | geo | scored | proxy | -- | null |

## D10 — GEO/AI Readiness

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `llms-txt-quality` | llms-best-practice: `llms.txt`/`llms-full.txt` contains substantive, extraction-friendly content | `seo-content` | geo | scored | proxy | -- | null |
| `semantic-html` | Semantic HTML supports AI extraction | `seo-content` | geo | scored | code | -- | null |
| `chunkability` | Content is chunkable into stable sections | `seo-content` | geo | scored | proxy | -- | null |
| `eeat-signals` | E-E-A-T signals are visible for the page profile | `seo-content` | geo | scored | proxy | -- | null |
| `freshness` | Freshness signals are present when the page profile expects them | `seo-content` | geo | advisory | proxy | -- | null |

## D11 — Security and Technical

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `https-active` | HTTPS is active or deploy config proves it | `seo-technical` | core | blocking | proxy | CG3 | null |
| `mixed-content` | No `http://` resource references leak into production paths | `seo-technical` | hygiene | scored | code | -- | null |
| `security-headers` | Security headers are configured through the platform or host | `seo-technical` | hygiene | scored | either | -- | `headers-add` |
| `canonical-present` | Canonical is present at the layout/template level | `seo-technical` | core | blocking | code | CG4 | `canonical-fix` |
| `canonical-consistent` | Canonical scheme/domain patterns are consistent | `seo-technical` | hygiene | scored | code | -- | `canonical-fix` |
| `source-render-parity` | Key SEO fields remain consistent between raw source and rendered output | `seo-technical` | core | scored | either | -- | null |
| `noindex-staging` | Staging and preview environments carry `noindex` protections | `seo-technical` | hygiene | advisory | proxy | -- | null |

## D12 — Internationalization

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `lang-attribute` | Root HTML carries a valid `lang` attribute | `seo-technical` | hygiene | scored | code | -- | `lang-attr-add` |
| `hreflang-present` | `hreflang` tags exist when the site is multilingual | `seo-technical` | hygiene | advisory | code | -- | `hreflang-add` |
| `locale-urls` | Locale-aware URL patterns are consistent | `seo-technical` | hygiene | advisory | code | -- | null |

## D13 — Monitoring

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | CG? | fix_type |
|------------|-------|-------------|-------|-------------|---------------|-----|----------|
| `analytics-present` | Analytics integration is visible in code or config | `seo-technical` | visibility-deferred | advisory | proxy | -- | null |
| `search-console` | Search Console verification is visible or explicitly not inferable | `seo-technical` | visibility-deferred | advisory | proxy | -- | null |
| `error-reporting` | Error reporting or monitoring integration exists | `seo-technical` | visibility-deferred | advisory | code | -- | null |

---

## Summary

| Dimension | Check count |
|-----------|------------|
| D1 | 7 |
| D2 | 6 |
| D3 | 5 |
| D4 | 4 |
| D5 | 12 |
| D6 | 4 |
| D7 | 3 |
| D8 | 4 |
| D9 | 4 |
| D10 | 5 |
| D11 | 7 |
| D12 | 3 |
| D13 | 3 |
| **Total** | **67** |
| Blocking checks | 6 (CG1-CG6) |
