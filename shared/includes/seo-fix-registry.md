# SEO Fix Registry (shared between seo-audit agents and seo-fix)

> Single source of truth for `fix_type` identifiers, safety classifications,
> target platforms, validation rules, caveats, and `fix_params` schema.
> Both `seo-audit` agents (producers) and `seo-fix` (consumer) MUST use this
> registry.
> If a `fix_type` is not listed here, it is not auto-fixable.

## Fix Inventory

| fix_type | Description | Fixable? | Base safety | eta_minutes | Target platforms |
|----------|-------------|----------|-------------|-------------|------------------|
| `sitemap-add` | Add or repair sitemap generation and route coverage | Yes | MODERATE | 20 | Astro, Next.js, Hugo |
| `json-ld-add` | Add or repair JSON-LD for key pages | Yes | MODERATE | 30 | Astro, Next.js, Hugo |
| `schema-cleanup` | Remove duplicate or spam-like JSON-LD before adding more | Yes | MODERATE | 35 | Astro, Next.js, Hugo |
| `meta-og-add` | Add or normalize Open Graph and Twitter metadata | Yes | MODERATE | 20 | Astro, Next.js, Hugo |
| `robots-fix` | Create or repair `robots.txt` with intentional AI bot policy | Yes | MODERATE | 20 | Astro, Next.js, Hugo, Universal |
| `llms-txt-add` | Create minimal `llms.txt` and optional `llms-full.txt` companion when repo content allows it | Yes | SAFE | 10 | Astro, Next.js, Hugo, Universal |
| `headers-add` | Add a baseline security header set via host/platform config | Yes | SAFE | 15 | Cloudflare, Vercel, Netlify, Universal |
| `canonical-fix` | Repair canonical URL configuration | Yes | DANGEROUS | 45 | Astro, Next.js, Hugo |
| `font-display-add` | Add `font-display: swap` to font declarations | Yes | SAFE | 5 | Universal |
| `lang-attr-add` | Add a root `lang` attribute | Yes | SAFE | 5 | Universal |
| `alt-text-add` | Add empty alt text to decorative images only | Yes | SAFE | 10 | Universal |
| `viewport-add` | Add a missing viewport tag | Yes | SAFE | 5 | Universal |
| `hreflang-add` | Add or normalize `hreflang` metadata | No — MANUAL only | MANUAL | 45 | Manual |
| `noindex-change` | Change `noindex` behavior | No — MANUAL only | MANUAL | 20 | Manual |
| `redirect-add` | Add or change redirects | No — MANUAL only | MANUAL | 30 | Manual |

**Audit agents:** For checks that result in `FAIL`, set `fix_type` to the
matching value above. If no fix type matches, set `fix_type: null`.

**seo-fix:** Only processes findings where `fix_type` is in the fixable rows
above.

## Safety Classification (per framework)

Base safety may be upgraded one tier by `seo-fix` if the target file already
contains related config or conflicting implementations.

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
| `schema-cleanup` | MODERATE | MODERATE | MODERATE | -- |
| `meta-og-add` | MODERATE | MODERATE | MODERATE | -- |
| `robots-fix` | MODERATE | MODERATE | MODERATE | MODERATE |
| `canonical-fix` | DANGEROUS | DANGEROUS | DANGEROUS | -- |

## Fix Parameters Schema

| fix_type | Required params | Optional params |
|----------|-----------------|-----------------|
| `sitemap-add` | `framework` | `site_url`, `existing_sitemap`, `lastmod_strategy` |
| `json-ld-add` | `framework`, `schema_types` | `page_class`, `org_name`, `site_name`, `existing_block_count` |
| `schema-cleanup` | `framework` | `target_files`, `page_class`, `duplicate_types`, `existing_block_count` |
| `meta-og-add` | `framework`, `missing_tags` | `page_class`, `site_url`, `default_image` |
| `robots-fix` | `framework`, `issue`, `strategy`, `bot_policy_profile` | `bot_keys`, `current_rules`, `sub_issues`, `platform_overrides`, `network_provider` |
| `llms-txt-add` | -- | `site_name`, `pages`, `content_dirs`, `generate_full_companion` |
| `headers-add` | `platform` | `existing_headers_file`, `csp_mode` |
| `canonical-fix` | `framework` | `site_url`, `preferred_host` |
| `font-display-add` | -- | `font_files` |
| `lang-attr-add` | -- | `locale` |
| `alt-text-add` | -- | `image_files`, `decorative_signals` |
| `viewport-add` | -- | -- |

## Estimated Time Bands

| Effort | Time band |
|--------|-----------|
| EASY | <30 minutes |
| MEDIUM | 1-4 hours |
| HARD | 1+ day |
| MANUAL | Human review required; do not estimate automatically |

## Expanded Fix Contracts

### `robots-fix`

- Target map:
  - Astro/React/static: `public/robots.txt`
  - Next.js: prefer `app/robots.ts`, fallback `public/robots.txt`
  - Hugo: `static/robots.txt`
- Deterministic policy template:
  - Training bots default to `Disallow: /`
  - Search, retrieval, and user-assisted bots default to `Allow: /`
  - Emit comments explaining that these are conscious defaults and may be changed
- Validation rules:
  - File parses into user-agent blocks
  - Googlebot is not blocked
  - AI bot policy is explicit for relevant bot keys from `seo-bot-registry.md`
  - Flag problematic patterns such as `/*.js*`, `/*.pdf$`, and `/*.feed*`
  - Preserve or add `Sitemap:` when sitemap location is known
- Caveats:
  - Cloudflare, WAF, CDN, or host-layer controls may override file-based policy
  - Intentional site policy may differ from defaults
- Manual checks:
  - Cloudflare Dashboard -> Security/Bots -> AI controls
  - `curl -A 'GPTBot' https://example.com/ -I`
  - `curl -A 'Googlebot' https://example.com/ -I`
- Report hints:
  - Set `network_override_risk=true` when an edge provider is detected or cannot
    be ruled out

### `headers-add`

- Baseline header set:
  - `Strict-Transport-Security: max-age=31536000; includeSubDomains`
  - `X-Content-Type-Options: nosniff`
  - `Referrer-Policy: strict-origin-when-cross-origin`
  - `Permissions-Policy: camera=(), microphone=(), geolocation=()`
  - `Content-Security-Policy-Report-Only: default-src 'self'; base-uri 'self'; frame-ancestors 'self'; upgrade-insecure-requests`
- Target map:
  - Cloudflare/Netlify: `_headers`
  - Vercel: `vercel.json`
  - Universal fallback: closest host header config already in repo
- Validation rules:
  - Do not duplicate existing headers
  - Preserve existing CSP instead of replacing it blindly

### `json-ld-add`

- Validation rules:
  - Required fields must exist for each declared schema type
  - Output must be visible in raw source, not just rendered DOM
  - If existing JSON-LD block count is greater than `3`, downgrade to
    `NEEDS_REVIEW`
  - If duplicate `@type` blocks already exist, route to `schema-cleanup`
- Caveats:
  - Adding JSON-LD on top of existing schema spam can make the page worse
- Manual checks:
  - Verify the raw HTML response contains the new script block

### `schema-cleanup`

- Goal:
  - Keep one authoritative JSON-LD block per page intent and remove exact
    duplicates or spam-like repetition
- Validation rules:
  - Remove exact duplicates safely
  - If multiple non-identical blocks conflict, stop and emit `NEEDS_REVIEW`
  - Description fields longer than `500` characters are spam signals and should
    trigger manual review before mutation
- Caveats:
  - This fix removes content, so preservation of a single authoritative block is
    mandatory

### `meta-og-add`

- Validation rules:
  - `og:image` must be absolute
  - Homepage/index pages use `og:type=website`
  - Article/blog pages use `og:type=article`
  - Generic pages default to `og:type=website` unless another page class is
    explicitly known
- Caveats:
  - Do not overwrite deliberate per-page overrides without review

### `sitemap-add`

- Validation rules:
  - `site_url` or equivalent base URL must be derivable
  - Sitemap output must cover known public routes
  - If `lastmod` values are all identical or older than `180` days, downgrade to
    `NEEDS_REVIEW`
- Caveats:
  - Installing new dependencies is not automatic; escalate if the stack needs a
    package such as `@astrojs/sitemap`

### `llms-txt-add`

- Validation rules:
  - Always create a minimal, spec-compliant `llms.txt`
  - Create `llms-full.txt` only when real content can be aggregated from repo
    sources
  - When the framework exposes a static asset directory (`public/` or
    `static/`), place `llms.txt` and `llms-full.txt` there instead of using a
    route handler fallback
  - `VERIFIED` requires a successful build (`exit code 0`) when a build command
    exists, plus a post-build artifact or local-preview check confirming that
    `/llms.txt` and any generated `/llms-full.txt` return content and do not
    resolve as `404`
  - If no content corpus exists, do not fail proposal compliance solely because
    `llms-full.txt` is absent
- Size limits:
  - Max size cap per file: **500KB** (truncate with
    `... [truncated, see full docs at {url}]`)
  - Strategy depends on total content corpus size:
    - **Small sites (< 100 pages, corpus < 500KB):** single `llms-full.txt`,
      done
    - **Medium sites (100–300 pages, corpus 500KB–2MB):** single
      `llms-full.txt` capped at 500KB with TOC, prioritize most important
      content (homepage, key landing pages, recent articles). Emit advisory
      note listing what was excluded.
    - **Large content sites (300+ pages, corpus > 2MB):** split into
      **category files** linked from `llms.txt` index:
      ```markdown
      ## Content
      - [Travel Guides](/llms-guides.txt): Full travel guides and destination articles
      - [Blog](/llms-blog.txt): Recent blog posts and updates
      - [FAQ](/llms-faq.txt): Frequently asked questions
      ```
      Each category file capped at 500KB. Categories derived from site
      navigation, content directories, or CMS taxonomy. If the site has no
      clear categories, split chronologically (recent vs archive) or by
      content type (articles vs pages vs docs).
    - **Compression before splitting:** Before creating multiple files, try
      reducing size by: removing duplicate content across pages, stripping
      boilerplate (headers/footers repeated on every page), keeping only
      summaries for low-value pages (changelogs, legal), removing embedded
      code blocks from non-technical content
  - 100KB is too conservative for modern LLM context windows — Claude handles
    ~800KB, Cursor tolerates ~4MB, Gemini up to ~5MB
  - `llms.txt` index itself should stay under ~50KB regardless of corpus size
    (titles + URLs + one-sentence descriptions)
- X-Robots-Tag (MANDATORY):
  - All `llms*.txt` files MUST be served with `X-Robots-Tag: noindex` HTTP
    header to prevent search engine indexing
  - **Why not `robots.txt Disallow`:** `Disallow` blocks crawling, not
    indexing. The URL can still be discovered via external links and appear in
    SERPs as "No information available" (per John Mueller, Google Search
    Advocate). `X-Robots-Tag: noindex` keeps files crawlable for AI bots but
    invisible in search results.
  - **Why not `<meta name="robots">`:** `llms*.txt` are plain text, not HTML —
    there is no `<head>` element to place meta tags in
  - Platform-specific header config:
    - Cloudflare Pages / Netlify: `public/_headers` or `static/_headers`
    - Vercel: `vercel.json` `headers` array
    - Nginx: `location` block with `add_header`
    - Apache: `.htaccess` `<FilesMatch>` with `Header set`
  - Template for `_headers` (Cloudflare/Netlify). Use one entry per file; for
    category splits add each generated file:
    ```
    /llms.txt
      X-Robots-Tag: noindex
    /llms-full.txt
      X-Robots-Tag: noindex
    /llms-guides.txt
      X-Robots-Tag: noindex
    /llms-blog.txt
      X-Robots-Tag: noindex
    ```
  - Template for `vercel.json` (single regex covers all llms files):
    ```json
    {
      "headers": [
        {
          "source": "/llms(-[a-z]+)?\\.txt",
          "headers": [{ "key": "X-Robots-Tag", "value": "noindex" }]
        }
      ]
    }
    ```
  - If a `_headers` or equivalent host config file already exists, APPEND the
    `X-Robots-Tag` rules — do not overwrite existing headers
  - If `headers-add` fix is also being applied in the same run, merge the
    `X-Robots-Tag` rules into the same file
- Metadata section (best practice):
  - Add a `## Metadata` section after the blockquote description in both
    `llms.txt` and `llms-full.txt`:
    ```markdown
    ## Metadata
    - Last updated: {ISO date}
    - Language: {lang code}
    - Total pages: {count}
    ```
  - Helps AI bots assess freshness and authority
- Caveats:
  - A source file that looks correct is not enough. If the built artifact is
    missing or the endpoint responds with `404`, downgrade to
    `NEEDS_REVIEW` or mark verification as failed.

## Confidence Scale

Assigned by audit agents per finding:

| Level | When |
|-------|------|
| HIGH | Direct evidence in source code or live response (`file:line`, raw HTTP) |
| MEDIUM | Inferred from config/convention but not directly observed |
| LOW | Heuristic or absence-based inference |
