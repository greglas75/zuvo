# Implementation Plan: SEO/GEO Audit Fixes

**Spec:** `docs/specs/2026-03-29-seo-fixes-spec.md`
**Target repo:** `/Users/greglas/DEV/zuvo-landing/`
**Created:** 2026-03-29
**Tasks:** 11
**Estimated complexity:** 10 standard, 1 complex (OG image generation)

## Architecture Summary

Single-page Astro 6.1 static site deployed to Cloudflare Pages. All components are flat `.astro` files imported by `index.astro` through `Layout.astro`. CSS tokens defined in `global.css` under `:root` and `[data-theme="light"]`. No test framework, no business logic, no API. The `public/` directory is copied verbatim to `dist/` at build time. Cloudflare Pages reads `_headers` from `dist/` at the edge.

## Technical Decisions

- **Fonts:** Self-hosted via fontsource npm packages (`@fontsource-variable/jetbrains-mono`, `@fontsource-variable/instrument-sans`). Variable WOFF2 files placed in `public/fonts/`.
- **Sitemap:** `@astrojs/sitemap` integration (official, zero-config beyond `site` property).
- **JSON-LD:** Dedicated `StructuredData.astro` component using `set:html={JSON.stringify(...)}`.
- **OG Image:** Satori + resvg-js build script, output committed to `public/og.png`.
- **Contrast:** Scoped CSS overrides using `:global()` wrapper for globally-defined classes.
- **CSP:** `font-src 'self'` only (no external domains after font self-hosting).

## Quality Strategy

- **TDD exempt:** All tasks are config, static files, CSS, or template changes. No unit tests.
- **Verification model:** Build-then-inspect. Each task has a shell verification command.
- **CQ gates:** Only CQ13 (dead code) activates — resolved by deleting `Pricing.astro`.
- **Critical ordering:** Font files → CSS `@font-face` → `_headers` CSP. Violating this order causes silent font fallback or CSP-blocked fonts.
- **Silent failure risks:** Font file paths, `:global()` wrapper on `.badge`, satori font Buffer loading, Cloudflare cache staleness.

## Task Breakdown

### Task 1: Install dependencies and download font files

**Files:** `package.json`, `public/fonts/JetBrainsMono-Variable.woff2`, `public/fonts/InstrumentSans-Variable.woff2`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] Install production and dev dependencies:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing
  npm install @astrojs/sitemap
  npm install --save-dev satori @resvg/resvg-js @fontsource-variable/jetbrains-mono @fontsource-variable/instrument-sans
  ```
- [ ] Copy font files to `public/fonts/`:
  ```bash
  cp node_modules/@fontsource-variable/jetbrains-mono/files/jetbrains-mono-latin-wghs-normal.woff2 public/fonts/JetBrainsMono-Variable.woff2
  cp node_modules/@fontsource-variable/instrument-sans/files/instrument-sans-latin-wghs-normal.woff2 public/fonts/InstrumentSans-Variable.woff2
  ```
- [ ] Verify:
  ```bash
  ls -lh public/fonts/*.woff2
  ```
  Expected: Two `.woff2` files, each 30-120KB
- [ ] Commit: `add self-hosted font files and SEO dependencies`

---

### Task 2: Configure Astro — site, trailingSlash, sitemap

**Files:** `astro.config.mjs`
**Complexity:** standard
**Dependencies:** Task 1 (sitemap package must be installed)
**Model routing:** Sonnet

- [ ] Replace `astro.config.mjs` content:
  ```js
  // @ts-check
  import { defineConfig } from 'astro/config';
  import sitemap from '@astrojs/sitemap';

  export default defineConfig({
    site: 'https://zuvo.dev',
    trailingSlash: 'always',
    integrations: [sitemap()],
  });
  ```
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && npx astro build 2>&1 | tail -5 && ls dist/sitemap-index.xml dist/sitemap-0.xml
  ```
  Expected: Build succeeds. Both sitemap files exist in `dist/`.
- [ ] Commit: `configure Astro site URL, trailing slash, and sitemap generation`

---

### Task 3: Self-host fonts — replace Google Fonts @import with local @font-face

**Files:** `src/styles/global.css`
**Complexity:** standard
**Dependencies:** Task 1 (font files must exist in `public/fonts/`)
**Model routing:** Sonnet

- [ ] In `src/styles/global.css`, replace line 7:
  ```css
  @import url('https://fonts.googleapis.com/css2?family=Instrument+Sans:wght@400;500;600&family=JetBrains+Mono:ital,wght@0,400;0,500;0,600;0,700;0,800;1,400&display=swap');
  ```
  With:
  ```css
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
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && npx astro build && grep -c "googleapis" dist/_astro/*.css
  ```
  Expected: Build succeeds. grep count = 0 (no Google Fonts URLs in built CSS).
- [ ] Commit: `self-host fonts — replace Google Fonts import with local @font-face`

---

### Task 4: Add static SEO files — robots.txt, llms.txt, apple-touch-icon

**Files:** `public/robots.txt`, `public/llms.txt`, `public/apple-touch-icon.png`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] Create `public/robots.txt`:
  ```
  User-agent: *
  Content-Signal: search=yes,ai-train=no
  Allow: /

  Sitemap: https://zuvo.dev/sitemap-index.xml
  ```
- [ ] Create `public/llms.txt` (content from spec section 4)
- [ ] Create `public/apple-touch-icon.png` — 180x180 PNG (generate from favicon.svg or create programmatically)
- [ ] Verify:
  ```bash
  wc -c /Users/greglas/DEV/zuvo-landing/public/robots.txt && grep "Sitemap" /Users/greglas/DEV/zuvo-landing/public/robots.txt && wc -l /Users/greglas/DEV/zuvo-landing/public/llms.txt && file /Users/greglas/DEV/zuvo-landing/public/apple-touch-icon.png
  ```
  Expected: robots.txt < 200 bytes, Sitemap directive present, llms.txt non-empty, apple-touch-icon is PNG.
- [ ] Commit: `add robots.txt, llms.txt, and apple-touch-icon for SEO/GEO`

---

### Task 5: Add security headers (_headers file for Cloudflare Pages)

**Files:** `public/_headers`
**Complexity:** standard
**Dependencies:** Task 3 (font self-hosting must be complete — CSP uses `font-src 'self'`)
**Model routing:** Sonnet

- [ ] Create `public/_headers`:
  ```
  /*
    X-Content-Type-Options: nosniff
    X-Frame-Options: DENY
    Referrer-Policy: strict-origin-when-cross-origin
    Permissions-Policy: camera=(), microphone=(), geolocation=(), interest-cohort=()
    Strict-Transport-Security: max-age=31536000; includeSubDomains; preload
    Content-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline' https://static.cloudflareinsights.com; style-src 'self' 'unsafe-inline'; img-src 'self' data:; font-src 'self'; connect-src 'self' https://cloudflareinsights.com; frame-ancestors 'none'
  ```
- [ ] Verify:
  ```bash
  grep "font-src" /Users/greglas/DEV/zuvo-landing/public/_headers && grep -c "googleapis" /Users/greglas/DEV/zuvo-landing/public/_headers
  ```
  Expected: `font-src 'self'` present. googleapis count = 0.
- [ ] Commit: `add Cloudflare Pages security headers (HSTS, CSP, X-Frame-Options)`

---

### Task 6: Add StructuredData component and update Layout.astro

**Files:** `src/components/StructuredData.astro`, `src/layouts/Layout.astro`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] Create `src/components/StructuredData.astro` (exact content from spec section 5)
- [ ] Modify `src/layouts/Layout.astro`:
  - Add import in frontmatter: `import StructuredData from '../components/StructuredData.astro';`
  - Add `<StructuredData />` inside `<head>` (after `<title>`)
  - Add `<meta name="twitter:image" content="https://zuvo.dev/og.png" />`
  - Add `<meta property="og:site_name" content="Zuvo" />`
  - Add `<link rel="apple-touch-icon" sizes="180x180" href="/apple-touch-icon.png" />`
  - Fix canonical: `href="https://zuvo.dev/"` (add trailing slash)
  - Fix og:url: `content="https://zuvo.dev/"` (add trailing slash)
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && npx astro build && grep -c "application/ld+json" dist/index.html && grep 'rel="canonical"' dist/index.html && grep 'twitter:image' dist/index.html
  ```
  Expected: ld+json count = 2. Canonical has trailing slash. twitter:image present.
- [ ] Commit: `add JSON-LD structured data, fix canonical, add twitter:image and apple-touch-icon`

---

### Task 7: Fix Nav.astro — aria-label and contrast override

**Files:** `src/components/Nav.astro`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] Change line 6 `aria-label="Zuvo home"` to `aria-label="Zuvo.dev home"`
- [ ] Add scoped contrast overrides to the `<style>` block:
  ```css
  .nav__logo-dot {
    color: #8585a5;
  }

  :global([data-theme="light"]) .nav__logo-dot {
    color: #6a6a58;
  }
  ```
  Note: `.nav__logo-dot` is defined within Nav.astro's own `<style>` block (line 83-88), so it is already scoped to this component. The override replaces `color: var(--z-muted)` with a higher-contrast hex value. No `:global()` needed on the selector itself — only on the light theme parent.
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && npx astro build && grep 'aria-label' dist/index.html | grep -o 'aria-label="[^"]*"' | head -1
  ```
  Expected: `aria-label="Zuvo.dev home"`
- [ ] Commit: `fix nav logo aria-label and contrast for WCAG AA compliance`

---

### Task 8: Fix Hero.astro — contrast overrides on badge, stat-label, terminal-title

**Files:** `src/components/Hero.astro`
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] Add scoped contrast overrides to Hero.astro's `<style>` block:
  ```css
  :global(.badge) {
    color: #9595b5;
  }
  :global([data-theme="light"]) :global(.badge) {
    color: #555545;
  }

  .hero__stat-label,
  .hero__terminal-title {
    color: #8585a5;
  }
  :global([data-theme="light"]) .hero__stat-label,
  :global([data-theme="light"]) .hero__terminal-title {
    color: #6a6a58;
  }
  ```
  Note: `.badge` is a global class from `global.css` — must use `:global()`. `.hero__stat-label` and `.hero__terminal-title` are defined within Hero.astro's own `<style>` — no `:global()` needed on the selector, only on the theme parent.
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && npx astro build && grep -c "9595b5\|8585a5" dist/_astro/*.css
  ```
  Expected: Count > 0 (override colors present in built CSS).
- [ ] Commit: `fix hero contrast overrides for WCAG AA compliance in both themes`

---

### Task 9: Fix CTA.astro footer copy and delete Pricing.astro

**Files:** `src/components/CTA.astro` (modify), `src/components/Pricing.astro` (delete)
**Complexity:** standard
**Dependencies:** none
**Model routing:** Sonnet

- [ ] In `CTA.astro`, find "Open-source core, commercial add-ons" and replace with "Open-source, MIT licensed"
- [ ] Delete `src/components/Pricing.astro`
- [ ] Verify:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && grep -c "commercial add-ons" src/components/CTA.astro && ls src/components/Pricing.astro 2>&1
  ```
  Expected: grep count = 0. Pricing.astro: "No such file or directory".
- [ ] Commit: `fix footer copy to match MIT license, delete dead Pricing component`

---

### Task 10: Generate OG image

**Files:** `scripts/generate-og.mjs`, `public/og.png`
**Complexity:** complex
**Dependencies:** Task 1 (font files and satori/resvg must be installed)
**Model routing:** Opus

- [ ] Create `scripts/generate-og.mjs`:
  ```js
  import { readFileSync, writeFileSync, mkdirSync } from 'fs';
  import satori from 'satori';
  import { Resvg } from '@resvg/resvg-js';

  const fontData = readFileSync('./public/fonts/JetBrainsMono-Variable.woff2');

  const svg = await satori(
    {
      type: 'div',
      props: {
        style: {
          width: '1200px',
          height: '630px',
          display: 'flex',
          flexDirection: 'column',
          justifyContent: 'center',
          alignItems: 'center',
          backgroundColor: '#06060a',
          fontFamily: 'JetBrains Mono',
          padding: '60px',
        },
        children: [
          {
            type: 'div',
            props: {
              style: {
                fontSize: '72px',
                fontWeight: 800,
                color: '#e8a849',
                marginBottom: '24px',
              },
              children: 'Zuvo',
            },
          },
          {
            type: 'div',
            props: {
              style: {
                fontSize: '28px',
                fontWeight: 400,
                color: '#c8c8dc',
                textAlign: 'center',
                lineHeight: '1.5',
              },
              children: '33 AI Development Skills for Claude Code',
            },
          },
          {
            type: 'div',
            props: {
              style: {
                fontSize: '18px',
                fontWeight: 400,
                color: '#7a7a9a',
                marginTop: '16px',
              },
              children: 'Multi-agent pipelines · Quality gates · Stack-aware rules',
            },
          },
        ],
      },
    },
    {
      width: 1200,
      height: 630,
      fonts: [
        {
          name: 'JetBrains Mono',
          data: fontData,
          weight: 400,
          style: 'normal',
        },
      ],
    }
  );

  const resvg = new Resvg(svg, {
    fitTo: { mode: 'width', value: 1200 },
  });
  const pngData = resvg.render();
  const pngBuffer = pngData.asPng();

  writeFileSync('./public/og.png', pngBuffer);
  console.log(`Generated og.png (${(pngBuffer.length / 1024).toFixed(1)} KB)`);
  ```
- [ ] Run the script:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && node scripts/generate-og.mjs
  ```
- [ ] Verify:
  ```bash
  file public/og.png && ls -lh public/og.png
  ```
  Expected: PNG image data, size < 150KB.
  ```bash
  python3 -c "from struct import unpack; f=open('public/og.png','rb'); f.seek(16); w,h=unpack('>II',f.read(8)); print(f'{w}x{h}')"
  ```
  Expected: `1200x630`
- [ ] Commit: `add OG image generation script and branded 1200x630 og.png`

---

### Task 11: Full build verification and cleanup

**Files:** none (verification only)
**Complexity:** standard
**Dependencies:** Tasks 1-10 (all tasks must be complete)
**Model routing:** Sonnet

- [ ] Run full build:
  ```bash
  cd /Users/greglas/DEV/zuvo-landing && npm run build 2>&1
  ```
  Expected: Exit 0, no errors.
- [ ] Verify all deliverables in `dist/`:
  ```bash
  echo "=== Sitemap ===" && ls dist/sitemap-index.xml dist/sitemap-0.xml
  echo "=== robots.txt ===" && wc -c dist/robots.txt
  echo "=== _headers ===" && head -3 dist/_headers
  echo "=== llms.txt ===" && wc -l dist/llms.txt
  echo "=== og.png ===" && file dist/og.png && ls -lh dist/og.png
  echo "=== apple-touch-icon ===" && file dist/apple-touch-icon.png
  echo "=== fonts ===" && ls dist/fonts/
  echo "=== JSON-LD ===" && grep -c "application/ld+json" dist/index.html
  echo "=== canonical ===" && grep 'rel="canonical"' dist/index.html
  echo "=== no googleapis ===" && grep -rc "googleapis" dist/ || echo "PASS: 0 references"
  echo "=== no commercial add-ons ===" && grep -c "commercial add-ons" dist/index.html || echo "PASS: 0 references"
  echo "=== no Pricing ===" && ls src/components/Pricing.astro 2>&1
  ```
  Expected: All checks pass per acceptance criteria in spec.
- [ ] Visual verification (manual):
  ```bash
  npx astro preview
  ```
  - Open http://localhost:4321
  - DevTools → Network: confirm fonts load from `/fonts/`, no `googleapis` requests
  - DevTools → Elements: check JSON-LD scripts in `<head>`
  - Toggle light/dark theme: verify contrast on `.badge`, `.nav__logo-dot`, `.hero__stat-label`
  - Right-click "View Page Source": confirm canonical has trailing slash

---

## Post-Deploy Steps (not automated)

After deploying to Cloudflare Pages:

1. **Purge Cloudflare cache** for `/robots.txt` (dashboard → Cache → Purge by URL)
2. **Verify live site**: `curl -I https://zuvo.dev/robots.txt` (should be < 200 bytes)
3. **Verify headers**: `curl -I https://zuvo.dev/ | grep -i "strict-transport\|content-security\|x-frame"`
4. **Submit sitemap** to Google Search Console: `https://zuvo.dev/sitemap-index.xml`
5. **Test social cards**: Share `https://zuvo.dev/` on Twitter/Slack/LinkedIn — OG image should appear
6. **Validate JSON-LD**: Google Rich Results Test with `https://zuvo.dev/`
7. **Re-run SEO audit**: `zuvo:seo-audit https://zuvo.dev/` — target score >= 82
