# SEO Fix Registry (shared between seo-audit agents and seo-fix)

> Single source of truth for fix_type identifiers, safety classifications, and fix_params schema.
> Both seo-audit agents (producers) and seo-fix (consumer) MUST use this registry.
> If a fix_type is not listed here, it is not auto-fixable.

## Fix Types

| fix_type | Description | Fixable? |
|----------|------------|----------|
| `sitemap-add` | Add sitemap generation config | Yes |
| `json-ld-add` | Add JSON-LD structured data to layout | Yes |
| `meta-og-add` | Add missing OG/social meta tags | Yes |
| `robots-fix` | Fix robots.txt (missing, malformed, blocking) | Yes |
| `llms-txt-add` | Create llms.txt (index) + llms-full.txt (aggregated content) for AI discovery | Yes |
| `headers-add` | Add security headers via platform config | Yes |
| `canonical-fix` | Fix canonical URL configuration | Yes (DANGEROUS) |
| `font-display-add` | Add font-display: swap to @font-face | Yes |
| `lang-attr-add` | Add lang attribute to html element | Yes |
| `alt-text-add` | Add alt="" to decorative images | Yes |
| `viewport-add` | Add viewport meta tag | Yes |
| `hreflang-add` | Add hreflang tags | No — MANUAL only |
| `noindex-change` | Modify noindex directives | No — MANUAL only |
| `redirect-add` | Add redirects | No — MANUAL only |

**Audit agents:** For checks that result in FAIL, set `fix_type` to the matching value above. If no fix_type matches, set `fix_type: null` (finding is informational or requires manual work).

**seo-fix:** Only processes findings where `fix_type` is in the "Yes" rows above.

## Safety Classification (per framework)

Base safety — may be upgraded one tier by seo-fix if target file has existing related config.

| fix_type | astro | nextjs | hugo | * (universal) |
|----------|-------|--------|------|---------------|
| `llms-txt-add` | SAFE | SAFE | SAFE | SAFE |
| `headers-add` | SAFE | SAFE | SAFE | SAFE |
| `font-display-add` | SAFE | SAFE | SAFE | SAFE |
| `lang-attr-add` | SAFE | SAFE | SAFE | SAFE |
| `alt-text-add` | SAFE | SAFE | SAFE | SAFE |
| `viewport-add` | SAFE | SAFE | SAFE | SAFE |
| `sitemap-add` | MODERATE | MODERATE | SAFE | -- |
| `json-ld-add` | MODERATE | MODERATE | MODERATE | -- |
| `meta-og-add` | MODERATE | MODERATE | MODERATE | -- |
| `robots-fix` | MODERATE | MODERATE | MODERATE | -- |
| `canonical-fix` | DANGEROUS | DANGEROUS | DANGEROUS | -- |

## Fix Parameters Schema

| fix_type | Required params | Optional params |
|----------|-----------------|-----------------|
| `sitemap-add` | `framework` | `site_url` |
| `json-ld-add` | `framework`, `schema_types` | `org_name`, `site_name` |
| `meta-og-add` | `framework`, `missing_tags` | `site_url`, `default_image` |
| `robots-fix` | `framework`, `issue` | `current_rules` |
| `llms-txt-add` | -- | `site_name`, `pages`, `content_dirs` |
| `headers-add` | `platform` | -- |
| `canonical-fix` | `framework` | `site_url` |
| `font-display-add` | -- | `font_files` |
| `lang-attr-add` | -- | `locale` |
| `alt-text-add` | -- | `image_files` |
| `viewport-add` | -- | -- |

## Confidence Scale

Assigned by audit agents per finding:

| Level | When |
|-------|------|
| HIGH | Direct evidence in source code (file:line) |
| MEDIUM | Inferred from config/convention but not directly observed |
| LOW | Heuristic or absence-based inference |
