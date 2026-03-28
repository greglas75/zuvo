---
name: seo-audit
description: >
  SEO/GEO site audit covering 13 dimensions with 6 critical gates. Scans source
  code, templates, and config files for 200+ checks across meta tags, structured
  data, AI crawlers, content quality, GEO readiness, performance, and optional
  live Core Web Vitals. Framework-aware: Astro, Next.js, Hugo, WordPress, React,
  plain HTML. Flags: full (default), [path], --live-url <url>, --quick,
  --content-only, --geo, --persist-backlog.
---

# zuvo:seo-audit — SEO/GEO Site Audit

Hybrid code-level and optional live site audit for search engine optimization and generative engine optimization. Examines source code, templates, and config files across 13 dimensions. Optional live mode adds Core Web Vitals measurement, broken link detection, and rendered DOM verification.

**Scope:** Pre-launch readiness, periodic SEO health, GEO optimization, content scaling preparation, post-redesign verification.
**Out of scope:** Code quality (`zuvo:code-audit`), security vulnerabilities (`zuvo:security-audit`), deep performance profiling (`zuvo:performance-audit`).

## Mandatory File Loading

Read these files before any work begins:

1. `{plugin_root}/shared/includes/codesift-setup.md` -- CodeSift discovery and tool selection
2. `{plugin_root}/shared/includes/env-compat.md` -- Agent dispatch and environment adaptation

Print the checklist:

```
CORE FILES LOADED:
  1. codesift-setup.md   -- [READ | MISSING -> STOP]
  2. env-compat.md       -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Environment Compatibility

Read `../../shared/includes/env-compat.md` for agent dispatch patterns, path resolution, and progress tracking across Claude Code, Codex, and Cursor.

## CodeSift Integration

Read `../../shared/includes/codesift-setup.md` for the full initialization sequence.

**Summary:** Run the CodeSift setup from `codesift-setup.md` at skill start. Use CodeSift for structured data discovery, meta tag pattern search, and component analysis when available. Fall back to Grep/Read/Glob if unavailable.

---

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 -- Live Audit Consent

| Scenario | Static Analysis (code) | Live Tests (--live-url) |
|----------|----------------------|------------------------|
| No --live-url | Proceed (code read only) | N/A |
| --live-url localhost | Proceed | Proceed freely (GET/HEAD only) |
| --live-url staging | Proceed | Confirm with user, then proceed |
| --live-url production | Proceed | WARN: "This appears to be production. Consider staging/localhost." |

**Rate limiting (live audit):** Max 2 requests/second internal, 1 req/s external. 3 consecutive 429s triggers a 30s pause. 3 consecutive 5xx results halt the live audit.

**Read-only:** GET and HEAD only. No POST/PUT/DELETE.

### GATE 2 -- Read-Only Audit

This audit is read-only against source code. Sole allowed write target: `audit-results/` for the report file.

**FORBIDDEN:**
- Writing to any source/production file
- Modifying application code (suggest fixes in report, do not apply)
- Installing packages or modifying dependencies

---

## Phase 0: Parse $ARGUMENTS and Stack Detection

### 0.1 Arguments

| Argument | Behavior |
|----------|----------|
| `full` (default) | All 13 dimensions, code-only |
| `[path]` | Audit specific directory or module |
| `--live-url <url>` | Code audit + live audit (CWV, broken links, rendered DOM) |
| `--quick` | Critical gates only -- fast pass/fail (CG1-CG6) |
| `--content-only` | Content and GEO dimensions only (D7, D9, D10, D13) |
| `--geo` | GEO-focused: content + structured data + technical (D5 only) |
| `--persist-backlog` | Write HIGH/CRITICAL findings to `memory/backlog.md` |

Default: `full` (no `--live-url`).

### 0.2 Stack Detection

Detect the web framework from project config files:

```bash
# Web framework detection
ASTRO=$(find . -name "astro.config.*" -maxdepth 3 2>/dev/null | wc -l)
NEXT=$(find . -name "next.config.*" -maxdepth 3 2>/dev/null | wc -l)
HUGO=$(find . -name "hugo.toml" -o -name "hugo.yaml" -maxdepth 2 2>/dev/null | wc -l)
WP=$(find . -name "wp-config.php" -maxdepth 3 2>/dev/null | wc -l)
REACT=$(grep -rl "from 'react'" . --include="*.tsx" --include="*.jsx" 2>/dev/null | head -5 | wc -l || true)
```

Also detect:
- **Content format:** markdown (content/posts/blog directories), database-driven, or none
- **SEO files:** robots.txt, sitemap*, llms.txt
- **Deploy platform:** Netlify, Vercel, Cloudflare, Apache, Nginx

Store results:
```
DETECTED_STACK = [astro | nextjs | hugo | wordpress | react | html]
CONTENT_FORMAT = [markdown | database | none]
```

Print:
```
Stack: [framework] | Content: [format] | Deploy: [platform]
SEO files: robots.txt [found/MISSING] | sitemap [found/MISSING] | llms.txt [found/MISSING]
Mode: [full/quick/content-only/geo] | Live: [url or "code-only"]
```

---

## Phase 1: MCP Tool Inventory (live mode only)

**Skip if no `--live-url`.** Code agents use only Grep/Read/Glob/Bash.

When `--live-url` is provided, check for browser tools:

```
Check 1: chrome-devtools OR playwright   -> DOM inspection, screenshots
Check 2: lighthouse (optional)           -> CWV measurement
Check 3: accessibility-scanner (optional) -> WCAG audit
```

For each missing tool that is relevant, inform the user of the capability gap and suggest installation.

**CWV fallback chain:**
1. chrome-devtools evaluate_script -> Performance API
2. Bash: `npx lighthouse <url> --output json --chrome-flags="--headless"`
3. SKIP: "No CWV measurement tools available. D8-live = INSUFFICIENT DATA."

Set availability flags and proceed.

---

## Phase 2: Code Audit (13 Dimensions)

Run all applicable dimensions based on the selected mode. For each check, record PASS, PARTIAL, or FAIL with file:line evidence.

### D1 -- Meta Tags and On-Page SEO

Search for title tags, meta descriptions, viewport tags, heading hierarchy. Framework-specific patterns:
- **Next.js:** Check `metadata` exports in layout.tsx/page.tsx, or `<Head>` usage
- **Astro:** Check frontmatter and `<head>` in layout components
- **Hugo:** Check baseof.html and partial templates
- **WordPress:** Check theme functions.php and SEO plugin config

### D2 -- Open Graph and Social

Check og:title, og:description, og:image, og:type, twitter:card tags. Verify images have correct dimensions (1200x630 for OG).

### D3 -- Structured Data (JSON-LD)

Search for JSON-LD script tags. Verify server-side rendering (not client-only injection). Check schema types match page content. Validate required properties per schema.org type.

**Critical gate CG5:** JSON-LD must be server-side rendered (present in initial HTML, not injected by JavaScript).

### D4 -- Sitemap

Check for sitemap.xml generation. Verify it covers all public routes. Check for lastmod dates and changefreq values.

**Critical gate CG1:** Sitemap must exist and be accessible.

### D5 -- AI Crawlers and Crawlability

Check robots.txt for Googlebot access. Check for AI crawler policies (GPTBot, ClaudeBot, Perplexitybot). Verify conscious decisions (explicit allow/disallow, not default). Check for llms.txt file.

**Critical gates:**
- **CG2:** Googlebot not blocked in robots.txt
- **CG6:** AI crawler policy is a conscious decision (not default/absent)

### D6 -- Images

Check for alt text on images. Verify modern formats (WebP, AVIF). Check lazy loading on below-fold images. Verify width/height attributes prevent CLS.

### D7 -- Internal Linking

Check for orphan pages (no internal links pointing to them). Verify consistent navigation patterns. Check for broken internal link patterns in code.

### D8 -- Performance (code-level)

Check for render-blocking resources. Verify font loading strategy (font-display: swap). Check image optimization (next/image, astro:image, srcset). Check for excessive JavaScript bundle indicators.

### D9 -- Content Quality

Scan content files for word count (thin content < 300 words). Check for answer-first structure. Verify heading hierarchy within content. Check for duplicate title patterns.

### D10 -- GEO/AI Readiness

Check for llms.txt file. Verify structured HTML (semantic elements, clear hierarchy). Check content "chunkowability" for AI extraction. Assess E-E-A-T signals (author info, dates, citations).

### D11 -- Security and Technical

**Critical gate CG3:** HTTPS active (check for mixed content, http:// references).

Check for security headers configuration. Verify canonical URL patterns. Check for noindex on staging/preview environments.

### D12 -- Internationalization

Check for hreflang tags. Verify language attribute on html element. Check for locale-specific URL patterns.

### D13 -- Monitoring

Check for analytics integration. Verify Search Console setup indicators. Check for structured error reporting.

---

## Phase 3: Live Audit (only if --live-url)

**Runs in parallel with Phase 2 code agents in environments that support it.**

### 3.1 Core Web Vitals

Measure LCP, CLS, and INP using the available tool chain. Record measurement source (Lighthouse, Performance API, or N/A).

### 3.2 Rendered DOM Verification

Verify that JSON-LD is present in rendered DOM (not just source). Check that meta tags are rendered correctly. Verify OG images are accessible.

### 3.3 Broken Link Check

Check up to 50 internal links and 100 external links. Record status codes.

### 3.4 Visual Verification

If browser tools available, capture screenshots at 3 breakpoints (1440, 768, 375). Check for mobile rendering issues.

---

## Phase 4: Scoring

### 4.1 Evaluate Critical Gates

All 6 gates MUST have explicit PASS/FAIL:

```
CG1: Sitemap exists                    -- from D4
CG2: Googlebot not blocked             -- from D5
CG3: HTTPS active                      -- from D11
CG4: Canonical tags present            -- from D1
CG5: JSON-LD server-side rendered      -- from D3
CG6: AI crawler policy conscious       -- from D5
```

**Any critical gate = 0 means overall result is FAIL regardless of score.**

### 4.2 Dimension Scores

Per-dimension: `score = (sum of check scores / count of applicable checks) * 100`

### 4.3 Overall Score

```
Dimension weights:
  D1: 10%  D2: 5%   D3: 12%  D4: 8%   D5: 8%   D6: 5%   D7: 7%
  D8: 10%  D9: 15%  D10: 10% D11: 5%  D12: 3%  D13: 2%

Active weights = sum of weights where dimension is NOT N/A
Overall = sum(dimension_score * weight) / active_weights * 100
```

### 4.4 Sub-Scores

Each normalized to 0-100:
```
SEO Score:  D1 + D2 + D4 + D6 + D7 + D8 + D11 + D12 (weighted)
GEO Score:  D3 + D5 + D9 + D10 (weighted)
Tech Score: D4 + D8 + D11 + D12 + D13 (weighted)
```

### 4.5 Grade Assignment

```
A (>= 85): Production-ready SEO+GEO. Strong across all dimensions.
B (70-84): Good foundation. Optimization opportunities identified.
C (50-69): Significant gaps. Prioritized fixes needed before scaling.
D (< 50):  Major issues. SEO/GEO blocking growth.
FAIL:      Any critical gate = 0. Must fix before any other optimization.
```

---

## Phase 5: Report Validation

Before generating the report, verify:

1. **Count Consistency:** Total checks = sum of all dimension checks
2. **Score Math:** Recalculate overall from dimension scores * weights. Must match within 0.1.
3. **Critical Gate Completeness:** All 6 gates have explicit PASS/FAIL with evidence.
4. **Evidence Completeness:** Every FAIL finding has file:line or INSUFFICIENT DATA note.
5. **Priority Math:** Verify 3D priority calculation `(SEO * 0.4) + (Business * 0.4) + ((4 - Effort) * 0.2)`.

Fix any discrepancies before presenting to user.

---

## Phase 6: Report

### Executive Summary

```
SEO/GEO AUDIT -- [project name]
----
SEO:     [N]/100  [HEALTHY / NEEDS ATTENTION / AT RISK / CRITICAL]
GEO:     [N]/100  [same scale]
Content: [N]/100  [same scale]
----
```

Health scale: HEALTHY (80+), NEEDS ATTENTION (60-79), AT RISK (40-59), CRITICAL (<40).

### Full Report Sections

1. **Header** -- project, date, stack, mode (code / code+live)
2. **Critical Gates** -- 6 gates, PASS/FAIL with evidence
3. **Dimension Scores** -- D1-D13 table with score, weight, weighted contribution
4. **Overall Score + Tier**
5. **Sub-Scores** -- SEO, GEO, Tech (each /100)
6. **Quick Wins** -- findings with Priority >= 2.0 AND Effort = EASY
7. **Full Execution Plan** -- all findings sorted by priority descending
8. **Content Report** -- articles scanned, word counts, answer-first percentage (if content scanned)
9. **GEO Readiness Panel** -- 7 dimensions (llms.txt, AI crawlers, chunkowability, structured HTML, citation readiness, E-E-A-T, freshness)
10. **Manual Check Recommendations** -- informational only, not scored
11. **CI-Parseable Summary** -- `SEO-AUDIT-RESULT: PASS|FAIL score=NN tier=X critical=none|CG-N`

### 3D Priority Calculation

For each finding:
```
SEO Impact:      HIGH(3) / MEDIUM(2) / LOW(1)
Business Impact: HIGH(3) / MEDIUM(2) / LOW(1)
Fix Effort:      EASY(1) / MEDIUM(2) / HARD(3)

Priority = (SEO * 0.4) + (Business * 0.4) + ((4 - Effort) * 0.2)
Range: 1.0 - 3.0

Quick Win = Priority >= 2.0 AND Effort = EASY
```

### Save Report

```bash
mkdir -p audit-results
```

Save to: `audit-results/seo-audit-YYYY-MM-DD.md`

Auto-increment if a report for today already exists.

---

## Phase 7: Backlog and Next Steps

### Backlog Persistence (optional)

**Activated with `--persist-backlog` flag.**

Emit entries to `memory/backlog.md` for findings with Priority >= 2.0 or SEO Impact = HIGH:
- Fingerprint format: `file|dimension|check-id`
- Deduplicate against existing entries

### Next-Action Routing

| Audit Result | Proposed Action | Why |
|--------------|-----------------|-----|
| Any CG = FAIL | Fix critical gate first | CG failures block all optimization |
| GEO Score < 50 | Add llms.txt + AI crawler rules + content structure | Highest GEO ROI |
| SEO Score < 60 | Fix meta tags + canonical + sitemap gaps | Foundation issues |
| Content < 300 words avg | Expand thin content | Content quality drives all signals |
| D3 < 50 (Structured Data) | Add/fix JSON-LD schemas | Schema markup boosts citations |
| Tier A (>= 85) | Periodic re-audit or add --live-url for CWV data | Maintain and measure |
