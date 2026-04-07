---
name: content-migration
description: >
  CMS-to-SSG content migration comparison and fix. Compares an old CMS page
  (Joomla, WordPress, Drupal) with a new SSG page (Astro, Hugo, Next.js)
  element-by-element using Playwright DOM extraction. Identifies missing
  headings, paragraphs, images, CTAs, links, tables, forms. Optionally fixes
  parity gaps in local content files. 4 dimensions (CM1-CM4): text parity,
  image parity, link/CTA parity, structural parity.
  Flags: --old <url>, --new <url>, --fix, --source-file <path>,
  --content-selector <sel>, --settle-ms <ms>.
---

# zuvo:content-migration — CMS-to-SSG Content Parity Check & Fix

Compare an old CMS page with its new SSG version element-by-element. Identify content parity gaps (missing sections, images, CTAs). Optionally fix gaps in local content files.

**Scope:** Content parity verification for CMS-to-SSG migrations. One page pair per invocation.
**Out of scope:** Bulk/multi-page comparison (V2), SEO optimization (`zuvo:seo-audit`), content hygiene (`zuvo:content-audit`), visual pixel comparison, old site archival, redirect mapping.

## Mandatory File Loading

Read these files before any work begins:

1. `../../shared/includes/codesift-setup.md` -- CodeSift for source file discovery
2. `../../shared/includes/env-compat.md` -- Environment adaptation
3. `../../shared/includes/live-probe-protocol.md` -- Consent gate + rate limiting for both URLs
4. `../../shared/includes/run-logger.md` -- Run logging contract
5. `../../shared/includes/verification-protocol.md` -- Build verification rules
6. `../../shared/includes/migration-fix-registry.md` -- Fix types and insertion algorithm

```
CORE FILES LOADED:
  1. codesift-setup.md          -- [READ | MISSING -> STOP]
  2. env-compat.md              -- [READ | MISSING -> STOP]
  3. live-probe-protocol.md     -- [READ | MISSING -> STOP]
  4. run-logger.md              -- [READ | MISSING -> STOP]
  5. verification-protocol.md   -- [READ | MISSING -> STOP]
  6. migration-fix-registry.md  -- [READ | MISSING -> STOP]
```

If any file is missing, STOP.

## Safety Gates (NON-NEGOTIABLE)

### GATE 1 — Live Probe Consent
Read `../../shared/includes/live-probe-protocol.md`. Consent gate fires for BOTH `--old` and `--new` URLs. Rate limiting applies independently per domain.

### GATE 2 — Read-Only by Default
Without `--fix`, this skill is read-only (compare and report only).
**Allowed writes (always):** `audit-results/`
**Allowed writes (with --fix):** the resolved source `.md` file only.

### GATE 3 — Fix Safety
With `--fix`: MODERATE fixes (`content-add`, `cta-restore`) apply automatically. Never delete content from new site. Dirty file check: `git status --porcelain -- <file>` before write. If dirty → `NEEDS_REVIEW`.

---

## Arguments

| Argument | Behavior |
|----------|----------|
| `--old <url>` | Original CMS page URL (required) |
| `--new <url>` | New SSG page URL or localhost (required) |
| `--fix` | Apply fixes to local content file (default: compare only) |
| `--source-file <path>` | Explicit path to the .md file for the new page |
| `--settle-ms <ms>` | Wait after page load before extraction (default: 3000) |
| `--content-selector <sel>` | CSS selector for main content area (default: auto-detect) |

---

## Phase 0: Setup

### 0.1 Browser capability detection
```
Playwright MCP or Chrome DevTools MCP available? → MODE=full
Neither? → MODE=degraded (curl + HTML text only, warn about JS content)
```

### 0.2 Detect local framework
Same stack detection as content-audit (Astro/Hugo/Next.js/etc.).

### 0.3 Resolve source file
Find local `.md` file for `--new` URL. Cascade:
1. `--source-file <path>` — explicit
2. Frontmatter `slug` field matching URL path
3. Frontmatter `url` or `permalink` field
4. File path convention (`src/pages/path.md` → `/path/`)
5. Content collection title match

Multiple candidates → ask user. Zero → compare-only, `fix_type: null`.

### 0.4 Print summary
```
SETUP:
  Old URL:      [url]
  New URL:      [url]
  Mode:         [full (Playwright) | degraded (curl)]
  Framework:    [astro | hugo | nextjs | generic]
  Source file:  [path.md | not resolved]
  Fix mode:     [enabled | compare only]
```

---

## Phase 1: Extract

### 1.1 Extract both pages

For each URL (old, new):
1. Navigate Playwright to URL (or curl in degraded mode)
2. Wait `--settle-ms` for JS rendering
3. Run DOM extraction script via `browser_evaluate`
4. Take full-page screenshot → `audit-results/content-migration-{timestamp}/`

### 1.2 DOM Extraction Script

```javascript
() => {
  const customSel = '__CONTENT_SELECTOR__';
  const root = (customSel !== '__CONTENT_SELECTOR__' && document.querySelector(customSel))
    || document.querySelector('main')
    || document.querySelector('article')
    || document.querySelector('.content')
    || document.querySelector('#content')
    || document.body;
  const extract = (sel) => [...root.querySelectorAll(sel)];
  return {
    title: document.title,
    meta_description: document.querySelector('meta[name="description"]')?.content || '',
    headings: extract('h1,h2,h3,h4,h5,h6').map((el, i) => ({
      tag: el.tagName, text: el.textContent.trim(), order: i
    })),
    paragraphs: extract('p')
      .map((el, i) => ({
        text: el.textContent.trim(), html: el.innerHTML,
        wordCount: el.textContent.trim().split(/\s+/).length, order: i
      }))
      .filter(p => p.wordCount > 10),
    images: extract('img')
      .map((el, i) => ({ src: el.src, alt: el.alt || '', order: i })),
    links: extract('a[href]')
      .map((el, i) => ({
        text: el.textContent.trim(), href: el.href,
        isCTA: el.tagName === 'BUTTON' || el.classList.contains('btn')
          || el.classList.contains('cta') || el.role === 'button'
          || /register|sign.up|join|buy|start|get.started|contact|book.now|learn.more|try.free|get.a.quote|subscribe|download|apply/i.test(el.textContent),
        order: i
      })),
    lists: extract('ul, ol')
      .map((el, i) => ({
        type: el.tagName, itemCount: el.children.length,
        items: [...el.children].map(li => li.textContent.trim()), order: i
      })),
    tables: extract('table')
      .map((el, i) => ({
        rows: el.rows.length, cols: el.rows[0]?.cells.length || 0,
        headerText: [...(el.querySelector('thead')?.querySelectorAll('th') || [])]
          .map(th => th.textContent.trim()), order: i
      })),
    forms: extract('form')
      .map((el, i) => ({
        fields: [...el.querySelectorAll('input,select,textarea')]
          .map(f => ({ type: f.type, name: f.name })),
        submitText: el.querySelector('button[type=submit], input[type=submit]')
          ?.textContent?.trim(), order: i
      }))
  };
}
```

Replace `__CONTENT_SELECTOR__` with `--content-selector` if provided.

---

## Phase 2: Compare

### 2.1 Matching rules

**Headings (CM1):** >80% character similarity (Levenshtein) = FULL. 50-80% = PARTIAL.
**Paragraphs (CM1):** >70% significant word overlap = FULL. 50-70% = PARTIAL (`paragraph-truncated`). <50% = `paragraph-missing`.
**Images (CM2):** Match by alt text, then by position.
**CTAs/Links (CM3):** Match by text label (case-insensitive).
**Structure (CM4):** Match by element type and count.

### 2.2 Scoring

Per-dimension: `dim_score = elements_matched / elements_in_old * 100`

Weights: CM1 Text 40% | CM3 Links/CTAs 25% | CM2 Images 20% | CM4 Structure 15%

| Grade | Score | Meaning |
|-------|-------|---------|
| **A** | 90-100% | Near-complete parity |
| **B** | 75-89% | Minor gaps |
| **C** | 50-74% | Significant content missing |
| **D** | 0-49% | Major migration failure |

### 2.3 Generate findings

Each gap produces a finding with: `id`, `dimension`, `check`, `status`, `severity`, `old_element`, `new_status`, `source_file`, `fix_type`, `fix_safety`.

---

## Phase 3: Report

### 3.1 Terminal + markdown report

```
CONTENT MIGRATION REPORT -- [project]
----
Old: [old-url]  |  New: [new-url]
Source file: [path.md]
Parity: [score]% ([grade])
----

CM1 — Text:      [score]% | [N] missing headings, [M] missing paragraphs
CM2 — Images:    [score]% | [N] missing images
CM3 — Links/CTA: [score]% | [N] missing CTAs
CM4 — Structure:  [score]% | [N] missing sections

FINDINGS:
  F1: [CM1-heading-missing] "Our Services" (H2)
      Fix: content-add (MODERATE, requires --fix)
  ...

Screenshots: audit-results/content-migration-{timestamp}/

Run: <ISO-8601-Z>	content-migration	<project>	-	-	<VERDICT>	-	4-dim	<NOTES>	<BRANCH>	<SHA7>
```

Append Run: line to log per `run-logger.md`.

### 3.2 JSON report

Write `audit-results/content-migration-YYYY-MM-DD.json` with fields: version, skill, timestamp, old_url, new_url, source_file, result (PASS|FAIL|PROVISIONAL), score (overall, tier, sub_scores), findings[], screenshots, summary.

---

## Phase 4: Fix (only with --fix)

### 4.0 Pre-flight
Source file must be resolved. Dirty file check. Save snapshot for rollback.

### 4.1 Apply fixes
For each finding with fix_type (`content-add`, `cta-restore`):
1. **Insertion point** — per `migration-fix-registry.md` algorithm (nearest matched heading anchor)
2. **Convert to markdown** — per serialization table (headings→`##`, paragraphs→text, links→`[text](href)`, strip HTML)
3. **Insert** at determined position
4. **Validate** markdown syntax

### 4.2 Build verification
Run build command if exists. Exit 0 = PASS. Failure → rollback.

### 4.3 Adversarial review
```bash
git add -u && git diff --staged | adversarial-review --json --mode code
```
If not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`

---

## Phase 5: Verify (only with --fix + localhost)

If `--new` is localhost: poll dev server (HEAD every 2s, max 30s) → re-extract → re-compare → report delta.
If `--new` is production: skip. Print "Deploy and re-run to verify."

---

## Edge Cases

| Edge case | Handling |
|-----------|---------|
| **Old site down** | Playwright 2 attempts. Then `SITE_UNREACHABLE`. |
| **JS-rendered new site** | Playwright renders islands. Degraded → `INSUFFICIENT DATA`. |
| **Content intentionally removed** | All gaps = WARNING. User reviews. |
| **Layout redesign** | Semantic text comparison, not pixel diff. |
| **Joomla query URLs** | Accept full URL with query params. |
| **Images on different CDN** | Match by alt text, not URL. |
| **Source file not found** | `fix_type: null`. Suggest `--source-file`. |
| **New page 404** | `PAGE_MISSING` critical failure. |
| **Large page >500 elements** | Cap + warn. |
