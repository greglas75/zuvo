# SEO/GEO Audit Fixes -- Design Specification

> **Date:** 2026-03-29
> **Status:** Approved
> **Author:** zuvo:brainstorm
> **Audit reference:** `audit-results/seo-audit-2026-03-28.md`
> **Target repo:** `/Users/greglas/DEV/zuvo-landing/`

## Problem Statement

zuvo.dev scored 53/100 (FAIL) on the SEO/GEO audit with 2 critical gate failures:
- **CG1:** No sitemap.xml (returns homepage HTML)
- **CG5:** No JSON-LD structured data

Additional findings: malformed robots.txt (53KB with HTML appended), broken OG image (404), no llms.txt, color contrast failures, missing security headers, no apple-touch-icon, canonical trailing slash mismatch, and a content contradiction between a dead Pricing component and the FAQ.

If unfixed: Google cannot properly index the site, social sharing shows broken previews, AI search engines cannot extract structured product info, and accessibility standards are not met.

**Target:** Score >= 82 (Tier B), all 6 critical gates PASS.

## Design Decisions

| Decision | Chosen | Why |
|----------|--------|-----|
| AI crawler policy | Allow search, block training | `Content-Signal: ai-train=no` retained. Per-bot `Disallow` rules removed. llms.txt becomes reachable. |
| Pricing situation | Everything is free | Delete `Pricing.astro`. Fix footer copy. JSON-LD uses `price: "0"` confidently. |
| Contrast strategy | Scoped overrides | Preserve global token aesthetic. Only text elements get targeted `color` overrides for WCAG AA. |
| OG image | Programmatic generation | Build script creates 1200x630 PNG from design tokens. Matches site aesthetic automatically. |
| Font hosting | Self-hosted in `/public/fonts/` | Eliminates Google Fonts privacy concern, simplifies CSP, removes render-blocking external request. |
| Footer links | Out of scope | Broken `href="#"` links will be fixed in a separate task. |
| Approach | Static Files + Self-Hosted Fonts (B) | All fixes via static files in `public/`, one new component, config changes. No new runtime dependencies. |

## Solution Overview

Add 7 new files (5 in `public/`, 1 component, font files), modify 6 existing files, delete 1 dead component. Install `@astrojs/sitemap` as the only new dependency. Self-host Google Fonts to eliminate external dependency and simplify CSP.

```
public/
  robots.txt          NEW -- clean directives, AI crawlers allowed
  _headers            NEW -- security headers for Cloudflare Pages
  llms.txt            NEW -- AI search engine manifest
  og.png              NEW -- 1200x630 branded image (programmatic)
  apple-touch-icon.png NEW -- 180x180 PNG
  fonts/
    JetBrainsMono-*.woff2   NEW -- self-hosted (variable or 400/600/700/800)
    InstrumentSans-*.woff2  NEW -- self-hosted (variable or 400/500/600)

src/
  components/
    StructuredData.astro    NEW -- JSON-LD schemas
    Pricing.astro           DELETE -- dead component, contradictory content
    Nav.astro               MODIFY -- fix aria-label, contrast override
    Hero.astro              MODIFY -- contrast overrides on .badge, .stat-label
    CTA.astro               MODIFY -- fix footer "commercial add-ons" copy
  layouts/
    Layout.astro            MODIFY -- add StructuredData, twitter:image,
                                      apple-touch-icon, fix canonical, add og:site_name
  styles/
    global.css              MODIFY -- replace @import with local @font-face

astro.config.mjs            MODIFY -- add site, trailingSlash, @astrojs/sitemap
```

## Detailed Design

### 1. astro.config.mjs

```js
import { defineConfig } from 'astro/config';
import sitemap from '@astrojs/sitemap';

export default defineConfig({
  site: 'https://zuvo.dev',
  trailingSlash: 'always',
  integrations: [sitemap()],
});
```

- `site` is required by `@astrojs/sitemap` and enables `Astro.site` in templates
- `trailingSlash: 'always'` matches Cloudflare Pages behavior (appends `/` to all routes)
- Sitemap integration auto-generates `sitemap-index.xml` + `sitemap-0.xml` at build time

### 2. public/robots.txt

```
User-agent: *
Content-Signal: search=yes,ai-train=no
Allow: /

Sitemap: https://zuvo.dev/sitemap-index.xml
```

- All AI crawlers allowed to index (no per-bot `Disallow` rules)
- `Content-Signal: ai-train=no` signals no training use
- `Sitemap` directive points to the generated sitemap index
- File must be plain text, < 1KB

### 3. public/_headers

```
/*
  X-Content-Type-Options: nosniff
  X-Frame-Options: DENY
  Referrer-Policy: strict-origin-when-cross-origin
  Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=()
  Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
  Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' https://cloudflareinsights.com; frame-ancestors 'none'
```

- CSP uses `'self'` for `font-src` (self-hosted fonts, no external domains)
- `'unsafe-inline'` needed for Astro's inline `<style>` and `<script>` blocks
- Cloudflare Insights script domain whitelisted in `script-src` and `connect-src`
- `frame-ancestors 'none'` included in CSP (replaces X-Frame-Options for CSP3 browsers)

### 4. public/llms.txt

```markdown
# Zuvo

> 33 AI development skills for Claude Code with multi-agent pipelines and quality gates.

## What is Zuvo?

Zuvo is a plugin for Claude Code that adds structured software development workflows.
It provides auto-routing skills (brainstorm, plan, execute), 27 domain-specific task
and audit skills, code quality gates (CQ1-CQ22), test quality gates (Q1-Q17), and
stack-aware rules for TypeScript, React, NestJS, Python, and PHP.

## Key Features

- Auto-routing skill router (matches user intent to the right skill)
- Multi-agent pipeline: brainstorm -> plan -> execute
- 39 quality gates (22 code + 17 test)
- Parallel sub-agent dispatch for analysis
- Tech debt backlog persistence across sessions

## Installation

npm install -g zuvo
claude plugins add zuvo

## Links

- Website: https://zuvo.dev/
- GitHub: https://github.com/greglas75/zuvo
```

### 5. src/components/StructuredData.astro

```astro
---
const softwareApp = {
  "@context": "https://schema.org",
  "@type": "SoftwareApplication",
  "name": "Zuvo",
  "description": "33 AI development skills for Claude Code with multi-agent pipelines, code quality gates, and test quality gates.",
  "url": "https://zuvo.dev/",
  "applicationCategory": "DeveloperApplication",
  "operatingSystem": "macOS, Linux, Windows",
  "offers": {
    "@type": "Offer",
    "price": "0",
    "priceCurrency": "USD"
  },
  "author": {
    "@type": "Organization",
    "name": "Zuvo",
    "url": "https://zuvo.dev/"
  },
  "license": "https://opensource.org/licenses/MIT"
};

const webSite = {
  "@context": "https://schema.org",
  "@type": "WebSite",
  "name": "Zuvo",
  "url": "https://zuvo.dev/"
};
---

<script type="application/ld+json" set:html={JSON.stringify(softwareApp)} />
<script type="application/ld+json" set:html={JSON.stringify(webSite)} />
```

Placed in `Layout.astro` `<head>` as `<StructuredData />`.

### 6. Layout.astro Changes

Add to `<head>`:
```astro
<!-- New: Structured Data -->
<StructuredData />

<!-- New: twitter:image -->
<meta name="twitter:image" content="https://zuvo.dev/og.png" />

<!-- New: og:site_name -->
<meta property="og:site_name" content="Zuvo" />

<!-- New: apple-touch-icon -->
<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />

<!-- Fix: canonical trailing slash -->
<link rel="canonical" href="https://zuvo.dev/" />

<!-- Fix: og:url trailing slash -->
<meta property="og:url" content="https://zuvo.dev/" />
```

Import `StructuredData` in frontmatter.

### 7. Self-Hosted Fonts (global.css)

Replace the external `@import` with local `@font-face` declarations:

```css
/* Replace: @import url('https://fonts.googleapis.com/css2?family=...'); */

@font-face {
  font-family: 'JetBrains Mono';
  src: url('/fonts/JetBrainsMono-Variable.woff2') format('woff2');
  font-weight: 100 800;
  font-style: normal;
  font-display: swap;
}

@font-face {
  font-family: 'Instrument Sans';
  src: url('/fonts/InstrumentSans-Variable.woff2') format('woff2');
  font-weight: 400 700;
  font-style: normal;
  font-display: swap;
}
```

- Variable font files (~50-80KB each) instead of multiple weights
- `font-display: swap` prevents FOIT (flash of invisible text)
- Download fonts from Google Fonts or fontsource.org

### 8. Contrast Fixes (Scoped Overrides)

**Nav.astro** -- `.nav__logo-dot`:
```css
.nav__logo-dot {
  color: #8585a5; /* was var(--z-muted), 4.5:1 on rgba(6,6,10,0.85) */
}
[data-theme="light"] .nav__logo-dot {
  color: #6a6a58; /* 4.5:1 on rgba(246,245,240,0.88) */
}
```

**Hero.astro** -- `.badge` (default variant), `.hero__stat-label`, `.hero__terminal-title`:
```css
.badge {
  color: #9595b5; /* was var(--z-text-dim), 4.5:1 on #12121c */
}
:global([data-theme="light"]) .badge {
  color: #555545; /* 4.5:1 on #f0efe8 */
}

.hero__stat-label,
.hero__terminal-title {
  color: #8585a5; /* was var(--z-muted), 4.5:1 on #0c0c12 */
}
:global([data-theme="light"]) .hero__stat-label,
:global([data-theme="light"]) .hero__terminal-title {
  color: #6a6a58; /* 4.5:1 on #ffffff */
}
```

Note: Exact hex values will be verified against actual backgrounds with a contrast ratio calculator during implementation. These are design targets (>= 4.5:1 for normal text).

### 9. Nav.astro Aria Fix

Change:
```html
<a href="/" class="nav__logo" aria-label="Zuvo home">
```
To:
```html
<a href="/" class="nav__logo" aria-label="Zuvo.dev home">
```

This matches the visible text "Zuvo.dev" rendered by the three child spans.

### 10. OG Image Generation

Create a build script (`scripts/generate-og.mjs`) that:
1. Uses `satori` to render an HTML/CSS template to SVG
2. Uses `@resvg/resvg-js` to convert SVG to 1200x630 PNG
3. Writes output to `public/og.png`
4. Design: dark background (`#06060a`), "Zuvo" in accent color (`#e8a849`), tagline in white, subtle grid/glow effect matching the site aesthetic

Script runs as a pre-build step or manually. Output is committed to `public/`.

Alternatively: if satori/resvg adds too much dev-dependency weight, create the image manually in a canvas-based HTML file and screenshot it. The programmatic approach is preferred for maintainability.

### 11. CTA.astro Footer Copy

Change "Open-source core, commercial add-ons" to "Open-source, MIT licensed" (or similar -- matches FAQ and JSON-LD).

### 12. Delete Pricing.astro

Remove `src/components/Pricing.astro`. It is not imported anywhere and contains contradictory pricing tiers.

## Edge Cases

| Edge Case | Handling |
|-----------|----------|
| Cloudflare serves stale 53KB robots.txt after deploy | Purge Cloudflare cache for `/robots.txt` via dashboard or API. Document as post-deploy step. |
| CSP breaks page rendering | Self-hosted fonts = `font-src 'self'` only. Test with DevTools console for CSP violations before deploy. |
| Contrast must pass both themes | Each scoped override includes both default and `[data-theme="light"]` selectors. Verify both states with contrast checker. |
| Canonical/sitemap trailing slash mismatch | `trailingSlash: 'always'` in config. Canonical set to `https://zuvo.dev/`. Sitemap URLs match. |
| OG image too large (> 150KB) | Compress PNG output. Target < 150KB. Verify dimensions are exactly 1200x630. |
| AI crawlers allowed but training blocked | Consistent policy: `Content-Signal: ai-train=no` in robots.txt. Crawlers can index for search/citation but not training. llms.txt is reachable and useful. |
| @font-face files not found | Verify font files exist in `public/fonts/` and paths in `@font-face` match. Build will succeed but fonts fall back to system if paths are wrong. |

## Acceptance Criteria

**Must have:**

1. `astro build` produces `sitemap-index.xml` and `sitemap-0.xml` in output directory
2. `https://zuvo.dev/sitemap-index.xml` returns valid XML with HTTP 200 after deploy
3. `https://zuvo.dev/robots.txt` returns plain text < 1KB with valid directives
4. `https://zuvo.dev/og.png` returns HTTP 200 with a 1200x630 PNG image < 150KB
5. Rendered DOM contains two `<script type="application/ld+json">` elements (SoftwareApplication + WebSite)
6. JSON-LD validates at Google Rich Results Test without errors
7. Canonical tag in `<head>` is `https://zuvo.dev/` (with trailing slash)
8. `og:url` meta tag matches canonical (`https://zuvo.dev/`)
9. Fonts render correctly from self-hosted WOFF2 files (no Google Fonts external requests)
10. `Pricing.astro` is deleted from the repository

**Should have:**

11. `_headers` file produces correct response headers (verify with `curl -I`)
12. `https://zuvo.dev/llms.txt` returns HTTP 200 with product description
13. `apple-touch-icon.png` exists and is linked in `<head>`
14. `twitter:image` meta tag present in `<head>`
15. `og:site_name` meta tag present in `<head>`
16. Footer copy says "open-source, MIT licensed" (not "commercial add-ons")
17. Nav logo `aria-label` matches visible text content

**Edge case handling:**

18. All contrast overrides achieve >= 4.5:1 ratio in dark theme (verified with contrast checker)
19. All contrast overrides achieve >= 4.5:1 ratio in light theme (verified with contrast checker)
20. CSP in `_headers` does not cause console errors (test with DevTools)
21. `font-display: swap` prevents FOIT (text visible during font load)
22. Cloudflare cache purged for `/robots.txt` after first deploy

## Out of Scope

- `og:locale` meta tag -- omitted, single-language English site, D1 score already 90/100
- Footer broken links (`href="#"` for Docs, Changelog, Discord, Privacy) -- separate task
- Dynamic per-page OG images via Satori API routes -- revisit when content pages are added
- Nonce-based CSP (requires SSR/hybrid mode with Cloudflare adapter)
- Blog, docs, or changelog subpages -- separate feature
- Google Search Console submission -- manual post-deploy step, not code
- Mobile responsive audit or visual regression testing

## Open Questions

None. All questions were resolved in the design dialogue.
