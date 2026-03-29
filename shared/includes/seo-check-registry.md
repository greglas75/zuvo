# SEO Check Registry (canonical slugs)

> Single source of truth for all check IDs used in seo-audit findings.
> Agents MUST use these exact slugs in findings[].check.
> Finding ID = `{dimension}-{check_slug}` (e.g., `D4-sitemap-exists`).

## D1 — Meta Tags and On-Page SEO

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `title-present` | Title tag exists | -- | null |
| `title-length` | Title 30-60 chars | -- | null |
| `meta-description-present` | Meta description exists | -- | null |
| `meta-description-length` | Meta description 120-160 chars | -- | null |
| `viewport-present` | Viewport meta tag | -- | `viewport-add` |
| `heading-hierarchy` | H1 exists, H1>H2>H3 nesting | -- | null |
| `unique-titles` | No duplicate titles across pages | -- | null |

## D2 — Open Graph and Social

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `og-title` | og:title present | -- | `meta-og-add` |
| `og-description` | og:description present | -- | `meta-og-add` |
| `og-image` | og:image present and accessible | -- | `meta-og-add` |
| `og-image-dimensions` | OG image 1200x630 | -- | null |
| `og-type` | og:type present | -- | `meta-og-add` |
| `twitter-card` | twitter:card present | -- | `meta-og-add` |

## D3 — Structured Data (JSON-LD)

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `json-ld-present` | JSON-LD script tag exists | -- | `json-ld-add` |
| `json-ld-ssr` | JSON-LD in initial HTML (not client-only) | CG5 | `json-ld-add` |
| `json-ld-schema-match` | Schema type matches page content | -- | null |
| `json-ld-required-fields` | Required properties per schema.org type | -- | null |

## D4 — Sitemap

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `sitemap-exists` | Sitemap generation config or file exists | CG1 | `sitemap-add` |
| `sitemap-coverage` | Sitemap covers all public routes | -- | null |
| `sitemap-lastmod` | lastmod dates present | -- | null |
| `sitemap-robots-ref` | robots.txt references sitemap | -- | `robots-fix` |

## D5 — AI Crawlers and Crawlability

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `robots-exists` | robots.txt exists and is valid | -- | `robots-fix` |
| `robots-googlebot` | Googlebot not blocked | CG2 | `robots-fix` |
| `robots-ai-policy` | Conscious AI crawler policy (3+ bots) | CG6 | null |
| `llms-txt-present` | llms.txt exists and accessible | -- | `llms-txt-add` |
| `crawl-delay` | No excessive crawl-delay | -- | null |

## D6 — Images

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `img-alt-text` | Alt text on content images | -- | `alt-text-add` |
| `img-modern-format` | WebP/AVIF usage | -- | null |
| `img-lazy-loading` | Lazy loading on below-fold images | -- | null |
| `img-dimensions` | Width/height attributes (CLS prevention) | -- | null |

## D7 — Internal Linking

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `orphan-risk` | Potential orphan pages (code-only: risk, not definitive) | -- | null |
| `nav-consistency` | Consistent navigation patterns | -- | null |
| `broken-link-patterns` | Broken internal link patterns in code | -- | null |

## D8 — Performance (Code-Level)

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `render-blocking` | No render-blocking resources | -- | null |
| `font-loading` | font-display: swap on @font-face | -- | `font-display-add` |
| `img-optimization` | Image optimization components used | -- | null |
| `js-bundle` | No excessive JS bundle indicators | -- | null |

## D9 — Content Quality

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `thin-content` | No pages < 300 words | -- | null |
| `answer-first` | Summary within first 120 words | -- | null |
| `heading-structure` | H2/H3 sections <= 300 words | -- | null |
| `duplicate-titles` | No duplicate title patterns in content | -- | null |

## D10 — GEO/AI Readiness

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `llms-txt-quality` | llms.txt content quality (if file exists; presence is D5) | -- | null |
| `semantic-html` | Semantic elements (main, nav, section) | -- | null |
| `chunkability` | Content chunkable for AI extraction | -- | null |
| `eeat-signals` | E-E-A-T: author, datePublished, dateModified, citations | -- | null |
| `freshness` | Freshness signals: lastmod, dateModified, git age | -- | null |

## D11 — Security and Technical

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `https-active` | HTTPS active (code-only: INSUFFICIENT DATA unless deploy config proves it) | CG3 | null |
| `mixed-content` | No http:// references in source | -- | null |
| `security-headers` | Security headers configured | -- | `headers-add` |
| `canonical-present` | Canonical tag present on pages (layout/template level) | CG4 | `canonical-fix` |
| `canonical-consistent` | Canonical URL pattern consistent (trailing slash, www) | -- | `canonical-fix` |
| `noindex-staging` | noindex on staging/preview environments | -- | null |

## D12 — Internationalization

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `lang-attribute` | lang attribute on html element | -- | `lang-attr-add` |
| `hreflang-present` | hreflang tags (if multi-language) | -- | null |
| `locale-urls` | Locale-specific URL patterns | -- | null |

## D13 — Monitoring

| check_slug | Check | CG? | fix_type |
|------------|-------|-----|----------|
| `analytics-present` | Analytics integration detected | -- | null |
| `search-console` | Search Console verification (advisory — INSUFFICIENT DATA in code-only) | -- | null |
| `error-reporting` | Structured error reporting | -- | null |

---

## Summary

| Dimension | Check count |
|-----------|------------|
| D1 | 7 |
| D2 | 6 |
| D3 | 4 |
| D4 | 4 |
| D5 | 5 |
| D6 | 4 |
| D7 | 3 |
| D8 | 4 |
| D9 | 4 |
| D10 | 5 |
| D11 | 6 |
| D12 | 3 |
| D13 | 3 |
| **Total** | **58** |
| Critical gates | 6 (CG1-CG6) |
