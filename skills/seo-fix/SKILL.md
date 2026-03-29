---
name: seo-fix
description: >
  Apply fixes from seo-audit findings. Reads audit JSON, classifies fixes by
  safety tier (SAFE/MODERATE/DANGEROUS), applies templates per framework.
  Supports Astro, Next.js, Hugo. Modes: default (SAFE only), --auto (SAFE+MODERATE),
  --all (all tiers, requires confirmation), --dry-run, --finding F1,F3, --category sitemap.
---

# zuvo:seo-fix — Apply SEO Audit Fixes

Read seo-audit JSON findings. Apply framework-specific fixes based on safety tier. Verify. Report.

**Scope:** Post-audit fix application for SEO findings.
**Out of scope:** Content writing, image generation, WordPress plugin config, React SPA fixes, redirects, noindex management.

## Mandatory File Loading

Read these files before any work begins:

1. `{plugin_root}/shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `{plugin_root}/shared/includes/env-compat.md` -- Agent dispatch and environment adaptation
3. `{plugin_root}/shared/includes/backlog-protocol.md` -- Backlog fingerprint dedup and update

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md     -- [READ | MISSING -> STOP]
  2. env-compat.md         -- [READ | MISSING -> STOP]
  3. backlog-protocol.md   -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- DANGEROUS Fix Confirmation

DANGEROUS fixes (canonical-fix) are NEVER auto-applied. They require:
- `--all` flag explicitly passed
- User confirmation before each DANGEROUS fix

### GATE 2 -- Build Verification

After applying fixes, run build verification if build tool is available (astro build, next build, hugo). Build failure = revert last fix.

---

## Phase 0: Load Findings

1. Find latest `audit-results/seo-audit-*.json` (sort by date in filename)
2. If no JSON found: "No audit JSON found. Run `zuvo:seo-audit` first."
3. Check age from `timestamp` field. If >24h: warn "Audit is N hours old. Consider re-running `zuvo:seo-audit` for fresh results."
4. Parse findings array. Print summary:

```
AUDIT: seo-audit 2026-03-28 (2h ago) | Score: 53/100 (C) | 13 findings
  SAFE:              5 findings (auto-fixable)
  MODERATE:          4 findings (fixable with validation)
  DANGEROUS:         2 findings (manual only)
  SKIP:              2 findings (no template available)
  INSUFFICIENT DATA: N findings (require live audit for verification)
```

## Arguments

| Argument | Behavior |
|----------|----------|
| (default) | Read latest JSON, apply SAFE fixes, recommend MODERATE + DANGEROUS |
| `--auto` | Apply SAFE + MODERATE fixes automatically (skip DANGEROUS) |
| `--all` | Apply all fixes including DANGEROUS (requires confirmation) |
| `--dry-run` | Show what would be fixed, change nothing |
| `--finding F1,F3` | Fix specific findings by ID |
| `--category sitemap,json-ld` | Fix specific fix_type categories |
| `[json-path]` | Use specific JSON file instead of latest |

---

## Phase 1: Detect Framework & Targets

Reuse seo-audit Phase 0.2 stack detection. Map each finding's `fix_type` to a template.

### Template Registry

| fix_type | Framework | Template | Target File |
|----------|-----------|----------|-------------|
| `sitemap-add` | astro | Install `@astrojs/sitemap`, add to integrations, ensure `site:` set | `astro.config.mjs` |
| `sitemap-add` | nextjs | Create `app/sitemap.ts` with route export | `app/sitemap.ts` (new) |
| `sitemap-add` | hugo | Set `enableRobotsTXT = true`, add `[sitemap]` config | `hugo.toml` |
| `json-ld-add` | astro | Add `<script type="application/ld+json" set:html={...} />` to layout head | `src/layouts/*.astro` |
| `json-ld-add` | nextjs | Add `<script dangerouslySetInnerHTML>` in layout.tsx | `app/layout.tsx` |
| `json-ld-add` | hugo | Create `layouts/partials/json-ld.html`, include in head | `layouts/partials/json-ld.html` (new) |
| `meta-og-add` | astro | Add `<meta property="og:*">` tags to head component | `src/components/BaseHead.astro` or layout |
| `meta-og-add` | nextjs | Add to `metadata` export in layout.tsx | `app/layout.tsx` |
| `meta-og-add` | hugo | Add OG meta tags to `layouts/partials/head/opengraph.html` | `layouts/partials/head/opengraph.html` |
| `robots-fix` | astro | Create/fix `public/robots.txt` or `src/pages/robots.txt.ts` | `public/robots.txt` |
| `robots-fix` | nextjs | Create `app/robots.ts` with rules export | `app/robots.ts` (new) |
| `robots-fix` | hugo | Set `enableRobotsTXT = true`, create `layouts/robots.txt` template | `hugo.toml` + `layouts/robots.txt` |
| `llms-txt-add` | * | Create `public/llms.txt` with site structure | `public/llms.txt` (new) |
| `headers-add` | cloudflare | Create `public/_headers` with security headers | `public/_headers` (new) |
| `headers-add` | vercel | Add `headers` to `vercel.json` or `next.config.js` | `vercel.json` or `next.config.js` |
| `headers-add` | netlify | Create `public/_headers` or add to `netlify.toml` | `public/_headers` (new) |
| `canonical-fix` | astro | Set `site:` in config, add canonical `<link>` in layout | `astro.config.mjs` + layout |
| `canonical-fix` | nextjs | Add `alternates.canonical` to metadata export | `app/layout.tsx` |
| `canonical-fix` | hugo | Verify `baseURL` in config, add `<link rel="canonical">` via `.Permalink` | `hugo.toml` + head partial |
| `font-display-add` | * | Add `font-display: swap` to `@font-face` declarations | CSS files with `@font-face` |
| `lang-attr-add` | * | Add `lang` attribute to `<html>` element | Layout/template files |
| `alt-text-add` | * | Add empty `alt=""` to decorative images | Component files with `<img>` |
| `viewport-add` | * | Add `<meta name="viewport">` to head | Layout head |

**Note on WordPress/React/plain HTML:** Template registry covers Astro, Next.js, and Hugo as primary frameworks. WordPress fixes are plugin-based (Yoast/RankMath config, not code changes) -- outside auto-fix scope. React SPAs without SSR have limited SEO value -- seo-fix will warn and skip. Plain HTML gets universal (*) templates only.

### Safety Classification (per framework)

| fix_type | astro | nextjs | hugo | * (universal) |
|----------|-------|--------|------|---------------|
| `llms-txt-add` | SAFE | SAFE | SAFE | SAFE |
| `headers-add` | SAFE | SAFE | SAFE | SAFE |
| `font-display-add` | SAFE | SAFE | SAFE | SAFE |
| `lang-attr-add` | SAFE | SAFE | SAFE | SAFE |
| `alt-text-add` | SAFE | SAFE | SAFE | SAFE |
| `viewport-add` | SAFE | SAFE | SAFE | SAFE |
| `sitemap-add` | MODERATE (pkg install) | MODERATE (new file) | SAFE (config toggle) | -- |
| `json-ld-add` | MODERATE | MODERATE | MODERATE | -- |
| `meta-og-add` | MODERATE | MODERATE | MODERATE | -- |
| `robots-fix` | MODERATE | MODERATE | MODERATE | -- |
| `canonical-fix` | DANGEROUS | DANGEROUS | DANGEROUS | -- |

**Explicitly out of scope for fix templates:** `noindex-change` and `redirect-add`. These require HTTP-level configuration decisions that vary too much across deploy platforms. They appear in audit findings as manual recommendations only, never as fixable items.

### Fix Parameters Schema

| fix_type | Required params | Optional params | Notes |
|----------|-----------------|-----------------|-------|
| `sitemap-add` | `framework` | `site_url` | `site_url` null if not in config -- seo-fix will prompt or skip |
| `json-ld-add` | `framework`, `schema_types` | `org_name`, `site_name` | `schema_types`: array, e.g., `["WebSite", "Organization"]` |
| `meta-og-add` | `framework`, `missing_tags` | `site_url`, `default_image` | `missing_tags`: e.g., `["og:locale", "twitter:image"]` |
| `robots-fix` | `framework`, `issue` | `current_rules` | `issue`: "missing" or "malformed" or "blocking-googlebot" |
| `llms-txt-add` | -- | `site_name`, `pages` | Universal. `pages` derived from sitemap or file tree |
| `headers-add` | `platform` | -- | `platform`: cloudflare, vercel, netlify |
| `canonical-fix` | `framework` | `site_url` | DANGEROUS. `site_url` required for safe application |
| `font-display-add` | -- | `font_files` | Universal. `font_files`: paths to CSS with @font-face |
| `lang-attr-add` | -- | `locale` | Default: `en`. Derived from config if available |
| `alt-text-add` | -- | `image_files` | Universal. Only decorative images (no content images) |
| `viewport-add` | -- | -- | Universal. Standard viewport meta tag |

---

## Phase 2: Apply Fixes

Apply fixes in safety tier order: SAFE first, then MODERATE, then DANGEROUS.

### SAFE fixes (auto-applied)

For each SAFE finding:
1. Read target file (or confirm new file path)
2. Apply template with `fix_params` from JSON
3. Verify: file exists, content injected correctly (grep for expected pattern)
4. Record: `{ finding_id, action, file, status: "FIXED" }`

### MODERATE fixes (applied with validation)

For each MODERATE finding:
1. Read target file + surrounding context
2. Apply template
3. **Validation step:**
   - Sitemap: verify `site` URL is configured, integration added correctly
   - JSON-LD: validate schema properties against schema.org required fields
   - Meta tags: verify image URLs are absolute, not relative
   - Robots.txt: verify Googlebot is NOT blocked after fix (re-check CG2)
4. If validation fails: revert, mark as `NEEDS_REVIEW`
5. Record: `{ finding_id, action, file, status: "FIXED" | "NEEDS_REVIEW", validation }`

### INSUFFICIENT DATA findings (skipped)

Findings with status `INSUFFICIENT DATA` are treated like SKIP -- cannot fix what we cannot confirm is broken. Log them in the report as "requires live audit" and do not attempt any fix.

### DANGEROUS fixes (reported only, unless --all)

For each DANGEROUS finding:
1. Generate the exact diff that would be applied
2. Explain the risk
3. Print: "This fix requires manual review. Apply with `zuvo:seo-fix --finding F7 --all`"
4. Record: `{ finding_id, action, file, status: "MANUAL", diff, risk }`

---

## Phase 3: Verify

After all fixes applied:
1. If build tool available: run build (`astro build`, `next build`, etc.) -- fail = revert last fix
2. Re-run critical gate checks on modified files (CG1-CG6 subset)
3. Compare: before/after scores from JSON vs quick re-check

---

## Phase 4: Report

```
SEO FIX REPORT -- [project name]
----
Findings: 13 total | 7 fixed | 2 needs review | 2 manual | 2 skipped
Score:    53 -> 78 (estimated, re-audit for exact)
----

FIXED (auto-applied):
  F2: Added llms.txt                              public/llms.txt (new)
  F5: Added security headers                      public/_headers (new)
  F8: Added font-display: swap                    src/styles/global.css:14
  F9: Added lang="en" to <html>                   src/layouts/Layout.astro:1
  F11: Added viewport meta tag                    src/layouts/Layout.astro:7

FIXED (validated):
  F1: Added @astrojs/sitemap integration           astro.config.mjs:3,8
  F3: Added JSON-LD (WebSite + Organization)       src/layouts/Layout.astro:12

NEEDS REVIEW:
  F4: robots.txt fix -- validation warning         public/robots.txt
      Warning: existing rules modified. Verify Googlebot access.
  F6: OG image meta -- relative URL detected       src/layouts/Layout.astro
      Warning: og:image uses relative path. Provide absolute URL.

MANUAL (user action required):
  F7: Canonical URL configuration                  DANGEROUS -- wrong canonical can deindex pages
      Suggested diff: [shows exact changes]
  F10: Add hreflang tags                           DANGEROUS -- incorrect hreflang causes duplicate content
      Suggested diff: [shows exact changes]

SKIPPED:
  F12: Content quality < 300 words                 No template -- requires human writing
  F13: E-E-A-T author information                  No template -- requires real data

NEXT STEPS:
  1. Review NEEDS_REVIEW items above
  2. Apply MANUAL fixes if appropriate: zuvo:seo-fix --finding F7,F10 --all
  3. Re-audit for exact score: zuvo:seo-audit
  4. Expand thin content (F12): write 300+ words per page
```

---

## Phase 5: Update Backlog

1. Update backlog (per `shared/includes/backlog-protocol.md`):
   - For each FIXED finding: compute fingerprint `{file}|D{dimension}|{fix_type}`, remove the row from backlog
   - For each NEEDS_REVIEW finding: if exists in backlog, increment `Seen` count, keep OPEN
   - For each MANUAL finding: compute fingerprint, add as OPEN if not already present (severity from JSON)
   - For each SKIPPED finding (no template): add to backlog as OPEN with category "seo-manual"
2. Save report to `audit-results/seo-fix-YYYY-MM-DD.md`
3. Save fix JSON to `audit-results/seo-fix-YYYY-MM-DD.json`:

```json
{
  "result": "PARTIAL",
  "source_audit": "audit-results/seo-audit-2026-03-28.json",
  "before_score": 53,
  "estimated_after_score": 78,
  "fixed": 7,
  "needs_review": 2,
  "manual": 2,
  "skipped": 2,
  "files_modified": ["astro.config.mjs", "src/layouts/Layout.astro", "public/llms.txt", "public/_headers"]
}
```
