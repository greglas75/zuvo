---
name: content-migration
description: >
  Compare old CMS page with new SSG page after migration. Finds missing
  headings, paragraphs, images, CTAs, tables, forms. Optionally fixes gaps
  in local .md files. Use when content was migrated from Joomla/WordPress/
  Drupal to Astro/Hugo/Next.js and you need to verify nothing was lost.
  Flags: --old <url>, --new <url>, --fix, --source-file <path>.
---

# zuvo:content-migration — CMS-to-SSG Content Parity Check & Fix

Compare an old CMS page with its new SSG version. Report parity gaps.
Optionally apply safe additive fixes to the local markdown source.

**When to use:** After a CMS-to-SSG migration when you need to verify that
headings, paragraphs, CTAs, images, tables, and forms were preserved.
**One page pair per invocation.** For bulk comparison, run multiple times.

**Out of scope:** SEO optimization (`zuvo:seo-audit`), content hygiene
(`zuvo:content-audit`), pixel-level visual comparison, redirect mapping.

---

## Mandatory File Loading

Read before work begins:

1. `../../shared/includes/env-compat.md` -- Environment adaptation
2. `../../shared/includes/live-probe-protocol.md` -- Consent + rate limiting

Load on demand:
- `../../shared/includes/codesift-setup.md` -- Only if source file needs discovery
- `../../shared/includes/migration-fix-registry.md` -- Only with `--fix`
- `../../shared/includes/verification-protocol.md` -- Only with `--fix`
- `../../shared/includes/run-logger.md` -- At report phase

---

## Safety Gates

### GATE 1 — Consent
Per `live-probe-protocol.md` for BOTH `--old` and `--new` URLs.

### GATE 2 — Read-Only Default
Without `--fix`: compare and report only. Writes only to `audit-results/`.

### GATE 3 — Conservative Fixes
With `--fix`:
- **Never** delete content from the new site
- **Never** reorder existing content
- **Never** modify files not explicitly resolved as the source
- Dirty file check: `git status --porcelain -- <file>`. Dirty → STOP.
- If insertion point is ambiguous → `NEEDS_REVIEW`, do not guess
- All fixes are additive (insert missing content only)

---

## Arguments

| Argument | Behavior |
|----------|----------|
| `--old <url>` | Original CMS page URL (required) |
| `--new <url>` | New SSG page URL or localhost (required) |
| `--fix` | Apply fixes to local .md file (default: compare only) |
| `--source-file <path>` | Explicit path to the .md file for --new page |
| `--settle-ms <ms>` | Wait after page load (default: 3000, max: 15000) |
| `--scroll-to-bottom` | Scroll page before extraction (triggers lazy-loaded images/content) |
| `--content-selector <sel>` | CSS selector for content area (default: auto-detect main/article) |
| `--wait-for <sel>` | Wait for specific element before extraction (e.g. `.testimonials`) |

---

## Phase 0: Setup

**0.1 Browser detection:**
Playwright or Chrome DevTools MCP available → `MODE=full`.
Neither → `MODE=degraded` (curl, warn about JS content).

**0.2 Framework detection:**
Astro / Hugo / Next.js / generic. Same as content-audit.

**0.3 Source file resolution** (for `--fix`):

| Priority | Strategy | Confidence |
|----------|----------|-----------|
| 1 | `--source-file <path>` argument | Explicit |
| 2 | Frontmatter `slug` matches URL path | HIGH |
| 3 | Frontmatter `url` / `permalink` field | HIGH |
| 4 | File path convention (`src/pages/path.md` → `/path/`) | MEDIUM |
| 5 | Content collection H1/title match | LOW |

- HIGH confidence → proceed
- MEDIUM → proceed with note in report
- LOW or multiple candidates → ask user to confirm
- Zero candidates → compare-only mode, `fix_type: null`

**0.4 Print summary:**
```
SETUP: Old=[url] New=[url] Mode=[full|degraded] Source=[path|not resolved] Fix=[on|off]
```

---

## Phase 1: Extract

For each URL (old, new):

1. Navigate browser to URL
2. If `--scroll-to-bottom`: scroll to page bottom (triggers lazy load)
3. If `--wait-for <sel>`: wait until selector appears (max 10s)
4. Wait `--settle-ms` (default 3s)
5. Extract content from page (see below)
6. Take full-page screenshot → `audit-results/content-migration-{timestamp}/`

### Content Extraction

Extract structured content from the page's **content area only**. The
extraction automatically strips navigation, header, footer, and sidebar
elements to avoid false positives from layout differences.

**Content root resolution:**
1. `--content-selector` if provided
2. `<main>` element
3. `<article>` element
4. `.content` or `#content` container
5. Fallback: `<body>` — but auto-strip `<nav>`, `<header>`, `<footer>`,
   `<aside>`, `[role="navigation"]`, `[role="banner"]`, `[role="contentinfo"]`

If fallback to `<body>` is used, warn in report: "No semantic content
container found. Using body with nav/header/footer stripped. Consider
`--content-selector` for more precise results."

**Extracted elements:**
- **Headings** (H1-H6): tag, text, order
- **Paragraphs** (>5 words): text, word count, order
- **Images**: src, alt text, order
- **Links/CTAs**: text, href, isCTA flag, order
- **Lists** (ul/ol): item count, item texts
- **Tables**: row/column count, header text
- **Forms**: field types, submit button text

**SEO metadata** (compared separately, not part of parity score):
- Title tag, meta description, canonical URL, og:image, H1 count
- Report as separate block: show old vs new with change type (shortened, missing, changed)
- Title shortened >50% or meta description missing = WARNING in report

**CTA detection** — element is a CTA if:
- `<button>` tag or `role="button"`
- Class contains `btn` or `cta`
- Text matches (EN): `register|sign up|join|buy|start|get started|contact|book now|learn more|try free|subscribe|download|apply|pricing|demo|free trial|reserve|schedule|enroll|book a call`
  or (PL): `zarejestruj|kup|kontakt|sprawdz|zobacz|rezerwuj|zapisz|pobierz|dowiedz|umow|dolacz|cennik|zamow|wyprobuj`

---

## Phase 2: Compare

Compare the two extracted structures. The LLM compares semantically —
matching by meaning, not exact string equality. This naturally handles:
- Rephrased headings ("Our Services" vs "Services We Offer")
- Shortened marketing copy
- Translated or localized text
- CTA label changes with same intent

### What to report

For each element from the OLD page, determine:

**Parity status** (what happened to this element):

| Status | Meaning |
|--------|---------|
| **MATCHED** | Found in new page (exact or semantic match) |
| **PARTIAL** | Found but significantly shortened or changed |
| **MISSING** | Not found in new page |
| **ADDED** | In new page but not old (informational only) |

**Severity** (business impact, independent from status):

| Element type | MISSING severity | PARTIAL severity |
|-------------|-----------------|-----------------|
| H1 | CRITICAL | HIGH |
| CTA / tel: / mailto: | CRITICAL | HIGH |
| H2-H6 headings | HIGH | MEDIUM |
| Paragraphs | MEDIUM | MEDIUM |
| Images | MEDIUM | LOW |
| Lists, tables, forms | HIGH | MEDIUM |

**PARTIAL detection** — element exists but is degraded:
- Paragraph: 50-90% word overlap (existing rule)
- Heading: new heading is <60% character length of old
- Title tag: new is <50% character length of old
- Meta description: new is <70% character length of old

Prefer semantic equivalence, but do NOT mark as MATCHED when intent,
structure, or informational value materially changed.

### Parity Score

```
score = (elements MATCHED + elements PARTIAL) / total elements in old page * 100
```

| Grade | Score |
|-------|-------|
| **A** | 90-100% |
| **B** | 75-89% |
| **C** | 50-74% |
| **D** | 0-49% |

### Verdict

| Verdict | Condition |
|---------|-----------|
| **PASS** | No CRITICAL/HIGH missing items AND parity >= 90% |
| **PROVISIONAL** | Low-confidence source mapping OR old site partially loaded |
| **FAIL** | Any CRITICAL missing item OR parity < 50% OR new page 404 |
| **NEEDS_REVIEW** | Ambiguous source mapping OR ambiguous fix insertion points |

---

## Phase 3: Report

```
CONTENT MIGRATION -- [project]
Old: [url]  →  New: [url]
Source: [path.md | not resolved]
Parity: [score]% ([grade])

MISSING:
  - H2 "Our Services" — not found in new page
  - CTA "Register Now" button — not found
  - Image (alt="team photo") — not found
  - Table (3 rows × 4 cols) — not found

PARTIAL:
  - P "We offer managed IT..." — 40% shorter in new page

MATCHED: 23/32 elements
Screenshots: audit-results/content-migration-{ts}/

Run: <ISO-8601-Z>	content-migration	<project>	-	-	<VERDICT>	-	parity	<NOTES>	<BRANCH>	<SHA7>
```

Append Run: line per `run-logger.md`.

Save JSON to `audit-results/content-migration-YYYY-MM-DD.json`.

---

## Phase 4: Fix (only with --fix)

Read `../../shared/includes/migration-fix-registry.md` now.

### Pre-flight
1. Source file MUST be resolved. If not → STOP, suggest `--source-file`.
2. `git status --porcelain -- <file>` — dirty → STOP.
3. Save file snapshot for rollback.

### Apply fixes

For each MISSING element:

1. **Find insertion point** in the .md file:
   - Find the nearest heading in the .md file that matches a heading that
     PRECEDES the missing element in the old page
   - Insert after that heading's section (before next heading of same/higher level)
   - If no anchor found → do NOT auto-insert. Report as `NEEDS_REVIEW`
     with suggested content. User must place it manually.

2. **Convert to markdown:**
   - Headings → `## Title`
   - Paragraphs → plain text
   - Links → `[text](href)`
   - Lists → `- item` / `1. item`
   - Strip all HTML tags, keep text only
   - Never insert raw HTML

3. **Insert** the markdown at the determined position.

4. **Do NOT fix:** images (path mapping needed), tables (complex formatting),
   forms (interactive elements). Report these as `MANUAL_FIX_NEEDED`.

### Post-fix

1. Build verification if build command exists (exit 0 = PASS, else rollback)
2. Adversarial review (MANDATORY):
   `git add -u && git diff --staged | adversarial-review --json --mode code`
   If not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`
   - CRITICAL → undo fix, report as `NEEDS_REVIEW`
   - WARNING (localized) → fix
   - Unresolved → include in report, mark fix as PROVISIONAL
3. If `--new` is localhost: wait 1s for HMR, re-extract, report delta

---

## Edge Cases

| Situation | Handling |
|-----------|---------|
| Old site down | 2 Playwright attempts → `SITE_UNREACHABLE` |
| JS-rendered content | Playwright handles. Degraded mode → warn |
| Lazy-loaded content | Use `--scroll-to-bottom` and `--settle-ms 8000` |
| Content intentionally removed | Report as MISSING (not auto-classified as defect — final decision is user's). If `.content-migration-ignore.yml` exists in project root, exclude listed elements from findings. |
| Layout redesign | Semantic comparison. Layout differences are irrelevant. |
| Joomla query URLs | Accepted: `--old "site.com/index.php?option=com_content&id=42"` |
| Images on different CDN | Match by alt text, not URL |
| Source file not found | Compare-only. Suggest `--source-file`. |
| New page 404 | Immediate error. |
| No `<main>` element | Fallback to `<body>` with nav/footer auto-stripped |
