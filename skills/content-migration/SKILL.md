---
name: content-migration
description: >
  Compare old CMS page with new SSG page after migration. Finds missing
  headings, paragraphs, images, CTAs, tables, forms. Optionally patches safe
  gaps in local .md files. Use when content was migrated from Joomla/WordPress/
  Drupal to Astro/Hugo/Next.js and you need to verify nothing was lost.
  Flags: --old <url>, --new <url>, --fix, --source-file <path>, --status.
codesift_tools:
  always:
    - analyze_project
    - index_status
    - index_folder
    - index_file
    - plan_turn
    - get_file_tree
    - search_text
    - search_patterns
  by_stack: {}
---

# zuvo:content-migration — CMS-to-SSG Content Parity Check & Fix

Compare an old CMS page with its new SSG version. Report parity gaps.
Optionally apply safe additive patches to the local markdown source.

**One page pair per invocation.** For bulk progress, use `--status`.

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
- `../../shared/includes/retrospective.md` -- At report phase

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
- Limit: max 5 content insertions per run. When many gaps found, prefer
  report-first over bulk insertion.

---

## Arguments

| Argument | Behavior |
|----------|----------|
| `--old <url>` | Original CMS page URL (required, unless `--status`) |
| `--new <url>` | New SSG page URL or localhost (required, unless `--status`) |
| `--fix` | Apply fixes to local .md file (default: compare only) |
| `--source-file <path>` | Explicit path to the .md file for --new page |
| `--settle-ms <ms>` | Wait after page load (default: 3000, max: 15000) |
| `--scroll-to-bottom` | Scroll page before extraction (triggers lazy-loaded content) |
| `--content-selector <sel>` | CSS selector for content area (default: auto-detect) |
| `--wait-for <sel>` | Wait for specific element before extraction |
| `--status` | Show migration progress dashboard (no --old/--new needed) |

---

## Phase 0: Setup

**0.1 Status mode** (`--status`):
If `--status` flag is set, skip all phases. Read
`audit-results/migration-status.json` and print progress dashboard:

```
MIGRATION PROGRESS:
  A (90+):  12 pages
  B (75-89): 8 pages
  C (50-74): 5 pages
  D (<50):   3 pages
  Average parity: 78%
  Last updated: 2026-04-07 10:30 UTC
```

If no status file exists: "No migration runs recorded yet." STOP.

**0.2 Browser detection:**
Playwright or Chrome DevTools MCP available → `MODE=full`.
Neither → `MODE=degraded` (curl, warn about JS content).

**0.3 URL normalization** (for `--old`):
If URL contains Joomla query patterns (`?option=com_content`, `/component/`):
- Follow redirects (max 3 hops)
- Log final URL after redirects
- Warn: "Old URL redirected to {final_url}, using as canonical"
- Use final URL for comparison

**0.4 Framework detection:**
Astro / Hugo / Next.js / generic.

**0.5 Load ignore rules:**
If `.content-migration-ignore.yml` exists in project root, load it.

Format:
```yaml
global:
  paragraphs:
    - "Wszelkie prawa zastrzeżone 2018"
  headings:
    - "Newsletter"
  images:
    - alt: "logo-old.png"

per_url:
  "/tajlandia.html":
    paragraphs:
      - "Promocja wazna do 31.12.2023"
```

Elements matching ignore rules are excluded from findings entirely.

**0.6 Source file resolution** (for `--fix`):

| Priority | Strategy | Confidence |
|----------|----------|-----------|
| 1 | `--source-file <path>` argument | Explicit |
| 2 | Frontmatter `slug` matches URL path | HIGH |
| 3 | Frontmatter `url` / `permalink` field | HIGH |
| 4 | File path convention (`src/pages/path.md` → `/path/`) | MEDIUM |
| 5 | Content collection H1/title match | LOW |

- HIGH → proceed
- MEDIUM → proceed. Note in report: "Source file resolved with MEDIUM
  confidence via [strategy]. Verify before applying fixes."
- LOW or multiple → ask user to confirm
- Zero → compare-only, `fix_type: null`

**0.7 Print summary:**
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

Extract from the page's **content area only**. Auto-strip navigation, header,
footer, and sidebar to avoid false positives from layout differences.

**Content root resolution:**
1. `--content-selector` if provided
2. `<main>` element
3. `<article>` element
4. `.content` or `#content` container
5. Fallback: `<body>` — auto-strip `<nav>`, `<header>`, `<footer>`, `<aside>`,
   `[role="navigation"]`, `[role="banner"]`, `[role="contentinfo"]`

If fallback to `<body>`: warn "No semantic content container found. Consider
`--content-selector`."

**Extracted elements:**
- **Headings** (H1-H6): tag, text, order
- **Paragraphs** (>5 words): text, word count, order
- **Images**: src, alt text, filename (basename without extension), order
- **Links/CTAs**: text, href, isCTA flag, order
- **Lists** (ul/ol): item count, item texts
- **Tables**: row/column count, header text
- **Forms**: field types, submit button text

**SEO metadata** (compared separately, NOT part of parity score — metadata
findings affect report warnings but do not change parity grade):
- Title tag, meta description, canonical URL, og:image, H1 count
- Title shortened >50% or meta description missing = WARNING

**CTA detection** — element is a CTA if:
- `<button>` tag or `role="button"`
- Class contains `btn` or `cta`
- Text matches (EN): `register|sign up|join|buy|start|get started|contact|book now|learn more|try free|subscribe|download|apply|pricing|demo|free trial|reserve|schedule|enroll|book a call`
  or (PL): `zarejestruj|kup|kontakt|sprawdz|zobacz|rezerwuj|zapisz|pobierz|dowiedz|umow|dolacz|cennik|zamow|wyprobuj`
- Prefer interactive, conversion-oriented elements over ordinary links.
  Not every "learn more" is a critical CTA.

---

## Phase 2: Compare

Compare semantically — matching by meaning, not exact string equality.
This naturally handles rephrased headings, shortened copy, localized text.

Prefer semantic equivalence, but do NOT mark as MATCHED when intent,
structure, or informational value materially changed.

### Parity Status

| Status | Meaning |
|--------|---------|
| **MATCHED** | Found in new page (exact or semantic match) |
| **PARTIAL** | Found but significantly shortened or changed |
| **MISSING** | Not found in new page |
| **ADDED** | In new page but not old (informational only) |

### Severity (business impact)

| Element type | MISSING severity | PARTIAL severity |
|-------------|-----------------|-----------------|
| H1 | CRITICAL | HIGH |
| CTA / tel: / mailto: | CRITICAL | HIGH |
| H2-H6 headings | HIGH | MEDIUM |
| Paragraphs | MEDIUM | MEDIUM |
| Images | MEDIUM | LOW |
| Lists, tables, forms | HIGH | MEDIUM |

Image severity may be upgraded when the image carries essential informational
or conversion value (pricing graphic, comparison chart, hero CTA image,
trust badges).

### PARTIAL Detection

- Paragraph: 50-90% word overlap
- Heading: new is <60% character length of old
- Title tag: new is <50% character length of old
- Meta description: new is <70% character length of old

### Image Matching Cascade

Match images between old and new page in this order:
1. **Filename match**: basename without extension (`zdjecie-1.jpg` = `zdjecie-1.webp`)
2. **URL pathname match**: after CDN/domain strip, ignore query params
3. **Alt text match**: >50% similarity (handles rewritten alts)
4. **Position-based**: last resort, only if same total image count

### Parity Score

```
score = (MATCHED + PARTIAL) / total elements in old page * 100
```

| Grade | Score |
|-------|-------|
| **A** | 90-100% |
| **B** | 75-89% |
| **C** | 50-74% |
| **D** | 0-49% |

### Verdict

Hierarchy: FAIL > NEEDS_REVIEW > PROVISIONAL > PASS.
If multiple conditions match, the higher-priority verdict wins.

| Verdict | Condition |
|---------|-----------|
| **PASS** | No CRITICAL/HIGH missing items AND parity >= 90% |
| **PROVISIONAL** | Low-confidence source mapping OR old site partially loaded OR degraded extraction mode OR incomplete post-fix verification |
| **FAIL** | Any CRITICAL missing item OR parity < 50% OR new page 404 OR old site unreachable |
| **NEEDS_REVIEW** | Ambiguous source mapping OR ambiguous fix insertion points |

---

## Phase 3: Report

```
CONTENT MIGRATION -- [project]
Old: [url]  →  New: [url]
Source: [path.md | not resolved]
Parity: [score]% ([grade]) | Verdict: [PASS|FAIL|PROVISIONAL|NEEDS_REVIEW]

SEO METADATA:
  Title: "Old title" → "New title" (OK | shortened X% | MISSING)
  Meta:  "Old desc" → "New desc" (OK | MISSING)
  H1:    1 → 1 (OK) | 1 → 0 (CRITICAL)

MISSING:
  - H2 "Our Services" — CRITICAL
  - CTA "Register Now" — CRITICAL
  - Image (file: team-photo, alt: "team") — MEDIUM

PARTIAL:
  - H2 "Full guide to Vietnam" → "Vietnam" — shortened 70%, HIGH

MATCHED: 23/32 elements
Screenshots: audit-results/content-migration-{ts}/

Run: <ISO-8601-Z>	content-migration	<project>	-	-	<VERDICT>	-	parity-[grade]	<NOTES>	<BRANCH>	<SHA7>	<INCLUDES>	<TIER>
```

Append Run: line per `run-logger.md`.
Append Run: line per `retrospective.md`.

**JSON report** → `audit-results/content-migration-YYYY-MM-DD.json`:

```json
{
  "version": "1.2",
  "skill": "content-migration",
  "timestamp": "2026-04-07T10:15:00Z",
  "old_url": "...",
  "new_url": "...",
  "source_file": "src/content/pages/home.md",
  "verdict": "FAIL",
  "score": { "overall": 72, "grade": "C" },
  "seo_metadata": {
    "title": { "old": "...", "new": "...", "status": "shortened", "delta": "-50%" },
    "meta_description": { "old": "...", "new": null, "status": "missing" }
  },
  "findings": [],
  "summary": { "matched": 23, "partial": 2, "missing": 7, "total_old": 32 }
}
```

**Update progress** → `audit-results/migration-status.json`:

Auto-append/update this page's result. Keyed by new URL path.

```json
{
  "/tajlandia": { "score": 92, "grade": "A", "verdict": "PASS", "last_run": "2026-04-07T10:15:00Z" },
  "/wietnam": { "score": 67, "grade": "C", "verdict": "FAIL", "last_run": "2026-04-07T09:30:00Z" }
}
```

---

## Phase 4: Fix (only with --fix)

Read `../../shared/includes/migration-fix-registry.md` now.

### Pre-flight
1. Source file MUST be resolved. If not → STOP, suggest `--source-file`.
2. `git status --porcelain -- <file>` — dirty → STOP.
3. Save file snapshot for rollback.

### Apply fixes

For each MISSING element (max 5 insertions per run):

1. **Find insertion point** in the .md file:
   - Find nearest heading that matches a heading PRECEDING the missing
     element in the old page
   - Insert after that heading's section
   - If no anchor found → do NOT auto-insert. Report as `NEEDS_REVIEW`
     with suggested content. User must place manually.

2. **Convert to markdown:**
   - Headings → `## Title`
   - Paragraphs → plain text
   - Links → `[text](href)`
   - Lists → `- item` / `1. item`
   - Strip all HTML, keep text only. Never insert raw HTML.

3. **Group by context**: if old page had H2 + 3 paragraphs as a section,
   insert as a unit, not individually.

4. **Do NOT fix:** images (path mapping needed), tables (complex formatting),
   forms (interactive elements). Report as `MANUAL_FIX_NEEDED`.

### Post-fix

1. Build verification if build command exists (exit 0 = PASS, else rollback)
2. Adversarial review (MANDATORY):
   `git add -u && git diff --staged | adversarial-review --mode code`
   If not in PATH: `~/.claude/plugins/cache/zuvo-marketplace/zuvo/*/scripts/adversarial-review.sh`
   - CRITICAL → undo fix, report as `NEEDS_REVIEW`
   - WARNING (localized, low-risk) → fix
   - WARNING (broad, structural) → report only, do not auto-fix
   - Unresolved → include in report, mark fix as PROVISIONAL

---

## Phase 5: Verify (only with --fix)

### 5.1 Localhost verification
If `--new` is localhost/127.0.0.1:
1. Wait for HMR window (2s default)
2. Re-fetch new URL
3. For each fixed finding, re-check that specific element:
   - Query new page for the inserted heading/paragraph/CTA
   - `VERIFIED` if found, `FAILED` if still missing
4. Report:
   ```
   Fixed and verified: F1, F3, F5
   Fixed but not verified: F7 (HMR timeout)
   Failed verification: F2 (not visible — CSS hidden?)
   ```

### 5.2 Production verification
If `--new` is production URL:
- Skip verification
- Print: "Fixes applied locally. Deploy and re-run to verify."
- Mark verdict as PROVISIONAL (incomplete verification)

---

## Edge Cases

| Situation | Handling |
|-----------|---------|
| Old site down | 2 Playwright attempts → `SITE_UNREACHABLE` → verdict FAIL |
| JS-rendered content | Playwright renders. Degraded → warn, verdict PROVISIONAL |
| Lazy-loaded content | `--scroll-to-bottom` + `--settle-ms 8000` |
| Content intentionally removed | Report as MISSING (user's decision — not auto-classified as defect). Use `.content-migration-ignore.yml` to suppress persistent findings. |
| Layout redesign | Semantic comparison. Layout differences irrelevant. |
| Joomla query URLs | Follow redirects, log final URL, use canonical |
| Images on different CDN | Match by filename, then alt text, then position |
| Source file not found | Compare-only. Suggest `--source-file`. |
| New page 404 | Immediate FAIL. |
| No `<main>` element | Fallback `<body>` with nav/footer stripped + warning |
| Different language old vs new | Fuzzy match still works. Flag lang mismatch as INFO. |
