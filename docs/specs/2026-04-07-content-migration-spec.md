# Content Migration — Design Specification

> **spec_id:** 2026-04-07-content-migration-1230
> **topic:** CMS-to-SSG content migration comparison and fix
> **status:** Approved
> **created_at:** 2026-04-07T12:30:00Z
> **approved_at:** 2026-04-07T13:15:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

When migrating websites from legacy CMSes (Joomla, WordPress, Drupal) to
modern SSGs (Astro, Hugo, Next.js), automated content extraction often produces
incomplete results: missing sections, broken images, lost CTA buttons, wrong
heading hierarchy, content ordering issues. Manual page-by-page verification is
tedious and error-prone — a 50-page site takes hours to verify.

No existing tool combines URL mapping, DOM content extraction, semantic
comparison, AND automated fix generation in one workflow. SiteDiff does HTML
diff but no fixes. BackstopJS does pixel comparison but misses semantic gaps.
Screaming Frog does SEO parity but is not automatable.

**If we do nothing:** content parity issues ship to production, degrading UX
and losing content that was present on the old site. The user discovers missing
CTAs and sections weeks later from customer complaints.

## Design Decisions

### D1: Single skill with compare + fix (not audit/fix pair)

**Chosen:** One skill `content-migration` that compares two URLs, identifies
parity gaps, and fixes them in local content files — all in one invocation.

**Why:** The user's workflow is "compare and fix everything" in one session.
Separating into audit/fix adds friction for a task that's inherently
sequential: you compare, you fix, you verify. The skill has a `--dry-run`
mode for comparison-only.

**Alternatives considered:**
- Separate audit + fix skills (like content-audit/content-fix) — rejected
  because migration is a one-time workflow, not recurring hygiene
- Manual comparison with content-audit CC3 — rejected because CC3 only checks
  for CMS artifacts in local files, it doesn't compare against the original

### D2: Playwright DOM extraction as primary comparison method

**Chosen:** Use Playwright to render both pages (old and new), extract
structured content via `page.evaluate()`, then diff the JSON structures.
Screenshots as informational evidence only.

**Why:** Pixel comparison (BackstopJS-style) produces false positives on
redesigned layouts. DOM text extraction captures semantic content regardless
of visual styling. Playwright handles JS-rendered content (Astro islands,
React components).

**Extraction targets:**
- Headings: `document.querySelectorAll('h1,h2,h3,h4,h5,h6')` → `[{tag, text, order}]`
- Paragraphs: `document.querySelectorAll('p')` → `[{text, wordCount, order}]`
- Images: `document.querySelectorAll('img')` → `[{src, alt, order}]`
- CTAs/Links: `document.querySelectorAll('a[href], button')` → `[{text, href, type, order}]`
- Lists: `document.querySelectorAll('ul, ol')` → `[{type, itemCount, items}]`
- Tables: `document.querySelectorAll('table')` → `[{rows, cols, headerText}]`
- Forms: `document.querySelectorAll('form')` → `[{fields, submitText}]`
- Embedded media: `document.querySelectorAll('iframe, video, audio')` → `[{src, type}]` *(V2 — CM5, not extracted in V1)*

**Fallback:** If Playwright is unavailable, fall back to `curl` + HTML parsing.
JS-dependent sections flagged as `INSUFFICIENT DATA`.

### D3: 6 comparison dimensions (CM1–CM6)

**Chosen:** Six dimensions covering all content element types. V1 implements
CM1–CM4. CM5–CM6 are V2.

| Dim | Name | V1? |
|-----|------|-----|
| CM1 | Text Content Parity | Yes |
| CM2 | Image Parity | Yes |
| CM3 | Link & CTA Parity | Yes |
| CM4 | Structural Parity | Yes |
| CM5 | Embedded Media Parity | V2 |
| CM6 | Meta/SEO Parity | V2 |

### D4: Source file resolution cascade

**Chosen:** 5-step cascade to find which local `.md` file corresponds to a URL:

1. Frontmatter `slug` field matches URL path
2. Frontmatter `url` or `permalink` field
3. File path convention: `src/content/blog/my-post.md` → `/blog/my-post/`
4. Content collection match: search `src/content/**/*.md` for title match
5. Fallback: `--source-file <path>` explicit argument

If multiple candidates found: present all, ask user to disambiguate.
If zero candidates: report finding with `fix_type: null` (manual fix needed).

### D5: Fix safety — content addition is MODERATE

**Chosen:** Adding content scraped from the old site into local `.md` files
is classified as MODERATE. It requires `--fix` flag to apply. Default mode
is comparison-only (dry-run).

| Operation | Safety | Gate |
|-----------|--------|------|
| Show comparison report | N/A | Always runs |
| Add missing heading/paragraph | MODERATE | `--fix` required |
| Add missing CTA/link | MODERATE | `--fix` required |
| Rewrite image path | V2 | Deferred — needs asset mapping |
| Reorder content sections | V2 | Deferred — complex section boundary detection |
| Delete content from new site | FORBIDDEN | Never auto-applied |

### D6: Fuzzy text matching for content parity

**Chosen:** Paragraphs match if they share >70% of significant words
(stopwords removed). Between 50–70% = PARTIAL match (triggers
`paragraph-truncated`). Below 50% = no match (`paragraph-missing`).

The 70% threshold aligns with `paragraph-truncated` at >30% word loss —
a paragraph with 65% word overlap is PARTIAL, not FULL, ensuring
truncation is always detected.

Headings use stricter matching: >80% character similarity (Levenshtein
normalized). Heading text is short enough that character-level comparison
works better than word-level.

### D7: Page pairing — explicit URL pairs in V1

**Chosen:** V1 requires explicit `--old <url>` and `--new <url>` arguments
for a single page comparison. Multi-page and sitemap mode are V2.

**V2 additions:**
- `--sitemap`: crawl both sitemaps, auto-pair by slug
- `--map <file>`: JSON mapping file for bulk comparison
- `--old <url1>,<url2> --new <url3>`: many-to-one merging

## Solution Overview

```
User runs: zuvo:content-migration --old <url> --new <url> [--fix] [--source-file <path>]

Phase 0: Setup
  ├── Check Playwright/Chrome DevTools availability → MODE
  ├── Detect local framework (Astro/Hugo/Next)
  ├── Resolve source file for --new URL (cascade D4)
  └── Print setup summary

Phase 1: Extract
  ├── Navigate Playwright to --old URL
  │   ├── Wait for settle (3s default)
  │   ├── Extract DOM content → old_content JSON
  │   └── Take full-page screenshot → old.png
  ├── Navigate Playwright to --new URL
  │   ├── Wait for settle (3s default)
  │   ├── Extract DOM content → new_content JSON
  │   └── Take full-page screenshot → new.png
  └── Save screenshots to audit-results/content-migration-{timestamp}/

Phase 2: Compare
  ├── Diff old_content vs new_content per dimension (CM1–CM4)
  ├── Classify each gap: MISSING / PARTIAL / CHANGED / ADDED
  ├── Calculate parity score per dimension and overall
  └── Generate findings with fix_type tags

Phase 3: Report
  ├── Print comparison report (terminal)
  ├── Write audit-results/content-migration-YYYY-MM-DD.md
  └── Write audit-results/content-migration-YYYY-MM-DD.json

Phase 4: Fix (only with --fix)
  ├── For each MISSING/PARTIAL finding with fix_type:
  │   ├── Read source .md file
  │   ├── Determine insertion point (see Insertion Algorithm)
  │   ├── Convert extracted content to markdown (see Content Serialization)
  │   ├── Insert converted markdown into .md file
  │   └── Verify file still parses as valid markdown
  ├── Build verification (if build command exists)
  ├── Adversarial review: `git add -u && git diff --staged | adversarial-review --json --mode code`
  │   If not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`
  └── Commit suggestion

Phase 5: Verify (only with --fix, only when --new is localhost/dev server)
  ├── If --new is localhost: wait for dev server rebuild
  │   └── Poll dev server with HEAD request every 2s, max 30s timeout
  ├── If --new is production URL: skip verify (cannot trigger rebuild)
  │   └── Print: "Fixes applied locally. Deploy and re-run to verify."
  ├── Re-extract --new URL DOM (same extraction as Phase 1)
  ├── Re-compare against cached --old extraction from Phase 1
  ├── Report delta: "N findings fixed, M remaining"
  └── Run log append
```

## Detailed Design

### Check Dimensions (CM1–CM4, V1)

#### CM1 — Text Content Parity

| check_slug | Description | severity |
|------------|-------------|----------|
| `h1-missing` | H1 from old page not found in new page | HIGH |
| `heading-missing` | Any H2–H6 from old page absent in new | MEDIUM |
| `heading-order-changed` | Heading present but in different ordinal position | LOW |
| `paragraph-missing` | Paragraph >50 words from old page absent in new | MEDIUM |
| `paragraph-truncated` | Paragraph present but >30% word loss | MEDIUM |
| `text-added` | New page has sections absent from old (informational) | INFO |

#### CM2 — Image Parity

| check_slug | Description | severity |
|------------|-------------|----------|
| `img-missing` | Image from old page (by alt/position) absent in new | MEDIUM |
| `img-alt-changed` | Alt text differs between old and new | LOW |
| `img-count-mismatch` | Old has N images, new has fewer | MEDIUM |
| `img-src-broken` | Image in new page returns 404 | HIGH |

#### CM3 — Link & CTA Parity

| check_slug | Description | severity |
|------------|-------------|----------|
| `cta-missing` | CTA button (by text label) from old absent in new | HIGH |
| `cta-href-changed` | CTA present but links to different destination | MEDIUM |
| `link-missing` | Navigational link from old absent in new | LOW |
| `tel-link-missing` | Phone link (`tel:`) from old absent in new | HIGH |
| `email-link-missing` | Email link (`mailto:`) from old absent in new | HIGH |

#### CM4 — Structural Parity

| check_slug | Description | severity |
|------------|-------------|----------|
| `section-missing` | Major section (by H2 anchor) from old absent in new | HIGH |
| `section-count-mismatch` | Different number of H2-level sections | MEDIUM |
| `list-missing` | List >3 items from old absent in new | MEDIUM |
| `table-missing` | Table from old absent in new | HIGH |
| `form-missing` | Form from old absent in new | HIGH |

### Fix Types (`migration-fix-registry.md`)

| fix_type | Description | Safety |
|----------|-------------|--------|
| `content-add` | Insert missing heading, paragraph, or section from old site | MODERATE |
| `cta-restore` | Add missing CTA button/link from old site | MODERATE |
Note: `content-reorder` and `img-path-rewrite` are deferred to V2 — requires an asset mapping
strategy (`--asset-map` argument or filename matching) that is out of V1 scope.
Image parity findings (CM2) are reported but not auto-fixed in V1.

### DOM Extraction Script

The Playwright `page.evaluate()` script that extracts content from both pages:

```javascript
() => {
  // Resolve content root — prefer semantic containers, fallback to body
  const root = document.querySelector('main')
    || document.querySelector('article')
    || document.querySelector('.content')
    || document.querySelector('#content')
    || document.body;
  const extract = (sel) => [...root.querySelectorAll(sel)];
  return {
    title: document.title,
    headings: extract('h1,h2,h3,h4,h5,h6').map((el, i) => ({
      tag: el.tagName, text: el.textContent.trim(), order: i
    })),
    paragraphs: extract('p')
      .map((el, i) => ({
        text: el.textContent.trim(),
        wordCount: el.textContent.trim().split(/\s+/).length,
        order: i
      }))
      .filter(p => p.wordCount > 10),
    images: extract('img')
      .map((el, i) => ({
        src: el.src, alt: el.alt || '', order: i
      })),
    links: extract('a[href]')
      .map((el, i) => ({
        text: el.textContent.trim(), href: el.href,
        isCTA: el.tagName === 'BUTTON'
          || el.classList.contains('btn') || el.classList.contains('cta')
          || el.role === 'button'
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
        rows: el.rows.length,
        cols: el.rows[0]?.cells.length || 0,
        headerText: [...(el.querySelector('thead')?.querySelectorAll('th') || [])]
          .map(th => th.textContent.trim()),
        order: i
      })),
    forms: extract('form')
      .map((el, i) => ({
        fields: [...el.querySelectorAll('input,select,textarea')]
          .map(f => ({ type: f.type, name: f.name, label: f.labels?.[0]?.textContent })),
        submitText: el.querySelector('button[type=submit], input[type=submit]')?.textContent?.trim(),
        order: i
      }))
  };
}
```

### Content Serialization (HTML → Markdown for fixes)

When `--fix` inserts content from the old site into a `.md` file, the extracted
DOM content must be converted to clean markdown:

| Old site element | Markdown output |
|-----------------|----------------|
| `<h2>Title</h2>` | `## Title` |
| `<h3>Title</h3>` | `### Title` |
| `<p>text</p>` | `text\n` (plain paragraph) |
| `<strong>bold</strong>` | `**bold**` |
| `<em>italic</em>` | `*italic*` |
| `<a href="url">text</a>` | `[text](url)` |
| `<ul><li>item</li></ul>` | `- item` |
| `<ol><li>item</li></ol>` | `1. item` |
| `<img src="url" alt="text">` | `![text](url)` — report only, no auto-insert in V1 |
| `<br>` | `\n` (newline) |
| `<blockquote>text</blockquote>` | `> text` |
| Inline styles, `<span>`, `<div>` | Strip tags, keep text content only |
| `<font>`, `<center>`, deprecated | Strip tags, keep text content only |

The conversion uses `.textContent` for paragraphs (stripping all HTML) and
preserves inline semantics (`strong` → `**`, `em` → `*`, `a` → `[text](href)`)
only for elements with clear markdown equivalents. All other HTML is stripped
to plain text to avoid injecting unsafe markup.

### Insertion Algorithm (for --fix)

When inserting missing content into the .md file:

1. Find the nearest **matched heading** in the new file that **precedes** the
   missing element's position in the old file
2. Insert after that heading's section (before the next heading of same or
   higher level)
3. If no anchor heading found (e.g., missing element was first on old page):
   insert at the beginning of the content body (after frontmatter)
4. If insertion point is ambiguous (multiple candidates): append before EOF
   and flag as `NEEDS_REVIEW` in the report

Example: Old page has H2-A, H2-B, H2-C. New page has H2-A, H2-C (missing
H2-B). Insertion point for H2-B content = after H2-A section, before H2-C.

### content-reorder

Deferred to V2. In V1, if content exists but in wrong order, report as
`heading-order-changed` (INFO) without auto-fixing. Reordering content in
markdown files requires understanding section boundaries which is complex
and error-prone.

Content scope: prefer `main`, `article`, `.content`, `#content` selectors.
Fall back to `body` if none found. This avoids comparing nav/footer/sidebar
elements that are layout-dependent.

### Parity Scoring

### Per-Dimension Scoring

Each dimension is scored independently:

```
dim_found = count of old elements matched in new (FULL or PARTIAL) for this dimension
dim_total = count of elements extracted from old page for this dimension
dim_score = dim_found / dim_total * 100
```

If `dim_total = 0` (e.g., no tables in old page), the dimension is N/A and
excluded from the overall score.

### Overall Parity Score

Weighted average of dimension scores:

| Dimension | Weight | Rationale |
|-----------|--------|-----------|
| CM1 (Text) | 40% | Text content is the primary value |
| CM2 (Images) | 20% | Images support text |
| CM3 (Links/CTAs) | 25% | CTAs are business-critical |
| CM4 (Structure) | 15% | Tables/forms are important but less common |

```
overall = sum(dim_score * weight) / sum(weight for applicable dims)
```

| Grade | Score | Meaning |
|-------|-------|---------|
| **A** | 90-100% | Near-complete parity |
| **B** | 75-89% | Minor gaps, mostly migrated |
| **C** | 50-74% | Significant content missing |
| **D** | 0-49% | Major migration failure |

### Arguments

| Argument | Behavior |
|----------|----------|
| `--old <url>` | Original CMS page URL (required) |
| `--new <url>` | New SSG page URL or localhost dev server (required) |
| `--fix` | Apply fixes to local content files (default: compare only) |
| `--source-file <path>` | Explicit path to the .md file for the new page |
| `--dry-run` | Alias for default (compare only, no fixes) |
| `--settle-ms <ms>` | Wait time after page load before extraction (default: 3000) |
| `--content-selector <sel>` | CSS selector for main content area (default: auto-detect) |

### Mandatory File Loading

```
1. ../../shared/includes/codesift-setup.md
2. ../../shared/includes/env-compat.md
3. ../../shared/includes/live-probe-protocol.md
4. ../../shared/includes/run-logger.md
5. ../../shared/includes/verification-protocol.md
6. ../../shared/includes/migration-fix-registry.md  (NEW)
```

### New Files to Create

```
skills/content-migration/SKILL.md
shared/includes/migration-fix-registry.md
```

No agents needed — this is a single-agent skill. The comparison logic runs
inline because it's a sequential workflow (extract old → extract new → diff →
fix). Agent dispatch would add latency without parallelism benefit.

### Integration Points

| Existing file | How content-migration uses it |
|--------------|--------------------------|
| `shared/includes/live-probe-protocol.md` | Consent gate for both old and new URLs |
| `shared/includes/verification-protocol.md` | Build verification after fixes |
| `scripts/adversarial-review.sh` | `--mode code` on fix diff |
| `skills/using-zuvo/SKILL.md` | Add routing entry |
| `docs/skills.md` | Update count |
| `.claude-plugin/plugin.json` | Update count |
| `.codex-plugin/plugin.json` | Update count |

### Report Output

**Terminal output (Phase 3):**

```
CONTENT MIGRATION REPORT -- [project]
----
Old: [old-url]
New: [new-url]
Source file: [path.md] (or "not resolved")
Parity: [score]% ([grade])
----

CM1 — Text:      [score]% | [N] missing, [M] partial
CM2 — Images:    [score]% | [N] missing
CM3 — Links/CTA: [score]% | [N] missing CTAs, [M] missing links
CM4 — Structure:  [score]% | [N] missing sections

FINDINGS:
  F1: [CM1-heading-missing] "Our Services" (H2) — present in old, absent in new
      Source: [path.md] → insert after line [N]
      Fix: content-add (MODERATE, requires --fix)
  F2: [CM3-cta-missing] "Register Now" button — present in old, absent in new
      Fix: cta-restore (MODERATE, requires --fix)
  ...

Screenshots: audit-results/content-migration-{timestamp}/

Run: <ISO-8601-Z>	content-migration	<project>	-	-	<VERDICT>	-	4-dim	<NOTES>	<BRANCH>	<SHA7>
```

**JSON output** (`audit-results/content-migration-YYYY-MM-DD.json`):

```json
{
  "version": "1.1",
  "skill": "content-migration",
  "timestamp": "[ISO 8601]",
  "old_url": "[url]",
  "new_url": "[url]",
  "source_file": "[path.md or null]",
  "result": "PASS | FAIL | PROVISIONAL",
  "score": {
    "overall": 72,
    "tier": "C",
    "sub_scores": { "CM1": 80, "CM2": 50, "CM3": 60, "CM4": 100 }
  },
  "findings": [
    {
      "id": "CM1-heading-missing",
      "dimension": "CM1",
      "check": "heading-missing",
      "status": "FAIL",
      "severity": "MEDIUM",
      "old_element": { "tag": "H2", "text": "Our Services", "order": 2 },
      "new_status": "MISSING",
      "source_file": "src/content/pages/home.md",
      "source_line": null,
      "fix_type": "content-add",
      "fix_safety": "MODERATE"
    }
  ],
  "screenshots": {
    "old": "audit-results/content-migration-{ts}/old.png",
    "new": "audit-results/content-migration-{ts}/new.png"
  },
  "summary": {
    "elements_old": 32,
    "elements_matched": 23,
    "elements_missing": 7,
    "elements_partial": 2
  }
}
```

### Edge Cases

| Edge case | Handling |
|-----------|---------|
| **Old site down** | `SITE_UNREACHABLE` critical failure. Suggest `--old-snapshot <html-file>` (V2) |
| **New site JS-rendered** | Playwright renders islands. Raw HTML fallback → `INSUFFICIENT DATA` for JS sections |
| **Content intentionally removed** | All missing elements flagged as `WARNING` by default. User reviews and approves. |
| **Layout redesign, content same** | Structural/semantic comparison (text match), NOT pixel diff. Layout changes are irrelevant. |
| **Joomla query-string URLs** | Accept full URL: `--old "tgmpanel.uk/index.php?option=com_content&id=42"` |
| **Images on different CDN** | Match by alt text + position, not URL. Flag `img-cdn-changed` as INFO |
| **Source file not found** | Report finding with `fix_type: null`, suggest `--source-file <path>` |
| **Multiple content files match** | Present all candidates, ask user to confirm |
| **Large page (>500 elements)** | Cap extraction at 500 elements, warn in report |
| **Old site behind WAF** | Retry with custom user-agent. If blocked, `SITE_UNREACHABLE` |

## Acceptance Criteria

### Must have

1. `--old <url> --new <url>` produces a comparison report showing missing elements per CM1–CM4.
2. Every finding includes: element type, text from old site, status in new site, source file path (or null).
3. Report written to `audit-results/content-migration-YYYY-MM-DD.md` and `.json`.
4. `--fix` applies MODERATE fixes (content-add, cta-restore, img-path-rewrite) to local .md files.
5. Screenshots of both pages saved to `audit-results/content-migration-{timestamp}/`.
6. Parity score calculated as elements_found/elements_total with A/B/C/D grade.
7. Build verification runs after `--fix` applies changes.
8. Source file detection works for Astro content collections (frontmatter slug + file path).

### Should have

1. `--content-selector` override for non-standard content containers.
2. `--settle-ms` configurable wait time for JS rendering.
3. Degraded mode (curl + HTML parsing) when Playwright unavailable.
4. Adversarial review on fix diff.

### Edge case handling

1. Old site unreachable → `SITE_UNREACHABLE` error, not false PASS.
2. Source file not resolved → finding has `fix_type: null`, report explains.
3. Content intentionally removed → all gaps are WARNING, user reviews.

## Out of Scope

- **Bulk/multi-page comparison** — V1 handles one page pair. Sitemap mode is V2.
- **Content writing** — skill adds content from old site, does not generate new content.
- **SEO optimization** — meta/SEO parity (CM6) is V2. SEO quality is `seo-audit`'s domain.
- **Visual pixel comparison** — screenshots are evidence, not the basis for findings.
- **Old site content scraping for archival** — skill compares and fixes, not archives.
- **Redirect mapping** — checking that old URLs 301 to new URLs is a separate concern.

## Open Questions

None — all design decisions resolved during brainstorm.
