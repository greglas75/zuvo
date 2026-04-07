# Content Audit & Fix — Design Specification

> **spec_id:** 2026-04-07-content-audit-1057
> **topic:** Content file quality audit with companion fix skill
> **status:** Approved
> **created_at:** 2026-04-07T10:57:00Z
> **approved_at:** 2026-04-07T11:30:00Z
> **approval_mode:** interactive
> **author:** zuvo:brainstorm

## Problem Statement

Websites migrated from legacy CMSes (Joomla, WordPress, Drupal) carry encoding
artifacts, broken markdown formatting, orphan CMS paths, and garbled diacritics
that are invisible in source but visible to users and AI bots. These defects
exist across hundreds of content files and cannot be caught by `seo-audit`
(which evaluates SEO signals, not editorial hygiene) or `code-audit` (which
evaluates production code, not content files).

Real-world evidence from a Polish travel site: 211 non-breaking spaces in 76
files, 22 files with broken italic rendering, 190 files with orphan
backslashes, 11 Polish typos from encoding corruption, 38 truncated meta
descriptions, stale Joomla paths. These are systematic, grep-detectable
patterns that an LLM skill can find and fix mechanically.

**If we do nothing:** content quality issues accumulate silently, degrade UX,
confuse AI bots reading `llms-full.txt`, and erode trust in the site.

## Design Decisions

### D1: Two skills, shared registry (audit + fix)

**Chosen:** `content-audit` (read-only scan) + `content-fix` (mechanical
repairs), sharing `content-check-registry.md` and `content-fix-registry.md`.

**Why:** Matches the proven `seo-audit` / `seo-fix` pair. The registry is
designed with `fix_type` columns from day one (lesson learned from seo-audit
retrofit). Fix skill consumes audit JSON output.

**Alternatives considered:**
- Single skill with `--fix` flag — rejected because audit and fix have
  different safety models (read-only vs write)
- Audit only, fix later — rejected because encoding artifact cleanup is
  trivially safe and the registry pattern is cheap to include now

### D2: 8 dimensions (CC1–CC8), language-agnostic

**Chosen:** 8 check dimensions covering encoding, markdown syntax, CMS
artifacts, frontmatter, images, links, content completeness, and
spelling/typography. All checks are language-agnostic by default; language-specific
checks (spell-check, diacritics) activate only when language is detected.

**Why:** Avoids overlap with `seo-audit` (which owns heading hierarchy, meta
tag presence, alt text presence, thin content from SEO perspective). Keeps the
skill focused on editorial/migration hygiene.

**Alternatives considered:**
- 10+ dimensions with SEO overlap — rejected to avoid double-counting when
  both skills run on the same site
- Polish-only — rejected because the same patterns (mojibake, CMS artifacts,
  broken markdown) affect any language. The mojibake detection table covers
  all major European encodings, not just Windows-1250.

### D3: 3 parallel agents (encoding, links, prose)

**Chosen:** Three Sonnet agents dispatched in parallel, each owning 2-3
dimensions. Same pattern as `seo-audit` (seo-technical, seo-content,
seo-assets).

| Agent | Dimensions | Focus |
|-------|-----------|-------|
| `content-encoding` | CC1, CC2, CC3 | Byte-level and syntax-level file scanning |
| `content-links` | CC5, CC6 | Path resolution, live probing |
| `content-prose` | CC4, CC7, CC8 | Semantic content analysis |

**Why:** CC1-CC3 are pure grep/regex operations (fast, mechanical). CC5-CC6
need file-system resolution and optional HTTP probing. CC4/CC7/CC8 need LLM
judgment for content quality. Separating by tool profile maximizes parallelism.

### D4: Language detection via frontmatter + directory + config

**Chosen:** Multi-signal language detection cascade:
1. Frontmatter `lang` or `language` field per file
2. Directory name convention (`content/pl/`, `content/en/`, `i18n/de/`)
3. Site-level config (`hugo.toml` `defaultContentLanguage`, `astro.config`
   `i18n.defaultLocale`, `next.config` `i18n.defaultLocale`)
4. HTML `lang` attribute in layout templates
5. Fallback: `unknown` — spell/typo checks emit `INSUFFICIENT DATA`

**Why:** No external dependency needed. Works for monolingual and multilingual
sites. Never assumes a language — if detection fails, spell checks degrade
gracefully instead of producing false positives.

### D5: Mojibake detection covers all major European encodings

**Chosen:** Ship a hardcoded mojibake signature table covering corruption
patterns for Latin-1, Windows-1252, ISO-8859-2 (Central European), ISO-8859-9
(Turkish), ISO-8859-7 (Greek), ISO-8859-5 (Cyrillic). Each entry maps a
garbled byte sequence to the original character and source encoding.

**Why:** The corruption patterns are deterministic (UTF-8 bytes misread as
single-byte encoding produce predictable 2-3 byte sequences). A hardcoded
table is simpler than a configurable registry for v1 and covers the most
common CMS migration scenarios worldwide.

Example patterns (subset):

| Original | Encoding | Corrupted form |
|----------|----------|---------------|
| `ą` | ISO-8859-2 → UTF-8 | `Ä…` |
| `ę` | ISO-8859-2 → UTF-8 | `Ä™` |
| `ó` | Latin-1 → UTF-8 | `Ã³` |
| `ü` | Latin-1 → UTF-8 | `Ã¼` |
| `ñ` | Latin-1 → UTF-8 | `Ã±` |
| `ş` | ISO-8859-9 → UTF-8 | `ÅŸ` |
| `ö` | Latin-1 → UTF-8 | `Ã¶` |
| `ä` | Latin-1 → UTF-8 | `Ã¤` |
| `é` | Latin-1 → UTF-8 | `Ã©` |
| `ç` | Latin-1 → UTF-8 | `Ã§` |
| U+FFFD | Any failed decode | `�` (replacement character) |

### D6: Fix safety tiers

**Chosen:** Three tiers for `content-fix`:

| Tier | Fix types | Rationale |
|------|-----------|-----------|
| **SAFE** | Strip NBSP→space, remove zero-width chars, remove BOM, remove orphan `\` lines, close unterminated italic at paragraph end | Mechanical, no semantic change |
| **MODERATE** | Fix mojibake (replace garbled sequences with correct chars), remove legacy CMS tags (`<font>`, shortcodes) | Requires pattern confidence |
| **MANUAL** | Spelling corrections, content duplication resolution, frontmatter rewrites, link target changes | Requires human judgment |

### D7: No external dependencies required

**Chosen:** All checks run via Grep, Glob, Read, Bash. Optional tool
enhancement when detected:
- `aspell` / `hunspell` — enhanced spell checking if installed
- `lychee` — enhanced external link checking if installed
- `file -i` — encoding detection (available on all Unix/macOS)

**Why:** Zuvo skills have no npm/pip dependencies (CLAUDE.md constraint). The
skill must work on any machine with just Claude Code installed.

### D8: Shared live-probe protocol

**Chosen:** Extract live probe safety rules from seo-audit into a new
`shared/includes/live-probe-protocol.md` rather than duplicating them. Both
`seo-audit` and `content-audit` reference the same include.

Rules: max 2 req/s internal, 1 req/s external, GET/HEAD only, pause on 3×429,
halt on 3×5xx, user consent required before hitting production URLs.

**Why:** seo-audit already has these rules inline. Duplicating them is a
maintenance risk. Extracting to a shared include is a one-time refactor with
zero behavior change.

## Solution Overview

```
User runs: zuvo:content-audit [path] [--live-url <url>] [--quick] [--content-path <dir>]

Phase 0: Discovery
  ├── Detect SSG framework (Astro/Hugo/Next/etc.)
  ├── Auto-detect content directories
  ├── Detect language(s) from config/frontmatter/directory
  ├── Build file manifest (skip binary, skip dist/build dirs)
  └── Print discovery summary

Phase 1: Parallel Agent Dispatch
  ├── Agent A: content-encoding (CC1, CC2, CC3)
  │   └── Grep-based: mojibake, NBSP, ZWS, broken markdown, CMS artifacts
  ├── Agent B: content-links (CC5, CC6)
  │   └── Extract links/images → resolve paths → optional live check
  └── Agent C: content-prose (CC4, CC7, CC8)
      └── Read frontmatter → check completeness → detect duplication → spell

Phase 2: Merge & Score
  ├── Collect findings from all agents
  ├── Deduplicate cross-agent findings
  ├── Calculate dimension scores and overall grade (A/B/C/D)
  └── Identify auto-fixable findings (tag with fix_type)

Phase 3: Adversarial Review
  └── adversarial-review --json --mode audit

Phase 4: Report
  ├── Markdown report → audit-results/content-audit-YYYY-MM-DD.md
  ├── JSON report → audit-results/content-audit-YYYY-MM-DD.json
  └── Run log append

Phase 5: Backlog (optional --persist-backlog)
  └── Append/update memory/backlog.md per backlog-protocol.md
```

### content-fix Detailed Design

```
User runs: zuvo:content-fix [--auto] [--dry-run] [--finding CC1-nbsp-present] [--fix-type encoding-strip]

Phase 0: Load content-audit JSON (latest or specified)
Phase 1: Classify fixes by safety tier
Phase 2: Apply SAFE fixes (default), SAFE+MODERATE (--auto)
Phase 3: Build verification (if build command exists)
Phase 4: Adversarial review of diff
Phase 5: Report + backlog update
```

**content-fix Mandatory File Loading:**

```
1. ../../shared/includes/env-compat.md
2. ../../shared/includes/content-fix-registry.md    (NEW)
3. ../../shared/includes/fix-output-schema.md
4. ../../shared/includes/content-check-registry.md  (NEW)
5. ../../shared/includes/backlog-protocol.md
6. ../../shared/includes/verification-protocol.md
7. ../../shared/includes/run-logger.md
```

**content-fix Arguments:**

| Argument | Behavior |
|----------|----------|
| (default) | Apply SAFE fixes only (`encoding-strip`, `markdown-fix`, `typography-fix`) |
| `--auto` | Apply SAFE + MODERATE fixes (`encoding-mojibake`, `artifact-remove`) |
| `--dry-run` | Show what would be fixed, change nothing |
| `--finding CC1-nbsp-present,CC2-broken-italic` | Fix specific findings by stable ID |
| `--fix-type encoding-strip,markdown-fix` | Fix specific fix_type categories |
| `[json-path]` | Use specific JSON file instead of latest |

**content-fix Safety Gates:**

- **GATE 1 — Write Scope:** Only content files from the audit manifest +
  `audit-results/` for reports + `memory/backlog.md`. No package installs,
  no config file modifications.
- **GATE 2 — Dirty File Check:** Before modifying any file, check for
  uncommitted changes. If dirty, mark as `NEEDS_REVIEW`.
- **GATE 3 — Stale Audit:** If audit JSON timestamp >24h old, require
  confirmation for `--auto` mode.
- **No DANGEROUS tier:** content-fix has SAFE, MODERATE, and MANUAL only.
  MANUAL findings are never auto-applied — they appear in the report as
  advisory output with suggested changes.

**content-fix Output:**

- Markdown: `audit-results/content-fix-YYYY-MM-DD.md`
- JSON: `audit-results/content-fix-YYYY-MM-DD.json` (schema: `fix-output-schema.md` v1.1)
- Auto-increment `-2.md`, `-3.md` for same-day runs

## Detailed Design

### Check Dimensions (CC1–CC8)

#### CC1 — Encoding Quality

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `nbsp-present` | Non-breaking spaces (U+00A0) in content | scored | `encoding-strip` |
| `zero-width-present` | Zero-width spaces (U+200B, U+200C, U+200D, U+FEFF) | scored | `encoding-strip` |
| `bom-present` | UTF-8 BOM marker at file start | advisory | `encoding-strip` |
| `mojibake-detected` | Garbled multi-byte sequences from encoding mismatch | blocking | `encoding-mojibake` |
| `replacement-char` | U+FFFD replacement characters present | scored | `encoding-strip` |
| `encoding-mismatch` | File encoding is not UTF-8 (detected via `file -i`) | advisory | null |
| `soft-hyphen-present` | Soft hyphens (U+00AD) in content | advisory | `encoding-strip` |

#### CC2 — Markdown Syntax

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `broken-italic` | Unclosed `*` or `_` at paragraph end | scored | `markdown-fix` |
| `split-italic` | Split formatting like `* *text*` | scored | `markdown-fix` |
| `orphan-backslash` | Standalone `\` on a line (not a line break in target renderer) | advisory | `markdown-fix` |
| `unclosed-code` | Unclosed inline code or fenced code block | scored | null |
| `malformed-link` | Broken link syntax `[text](`, `[](url)`, unmatched `[]` | scored | null |
| `malformed-image` | Broken image syntax `![](`, missing closing `)` | scored | null |
| `unlabeled-code-block` | Fenced code block without language label | advisory | null |

#### CC3 — Migration Artifacts

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `joomla-path` | Joomla-style paths (`/images/stories/`, `index.php?option=com_`) | scored | `artifact-remove` |
| `wp-shortcode` | WordPress shortcodes (`[caption]`, `[gallery]`, `[embed]`) | scored | `artifact-remove` |
| `php-tag` | PHP tags (`<?php`, `<?=`) in content files | blocking | `artifact-remove` |
| `legacy-html` | Deprecated HTML (`<font>`, `<center>`, `align=`) | scored | `artifact-remove` |
| `wysiwyg-junk` | Excessive inline styles from WYSIWYG editors (`style="..."` >50 chars) | scored | `artifact-remove` |
| `template-unexpanded` | Unexpanded template variables (`{{title}}`, `%TITLE%`, `{component}`) | scored | null |
| `cms-url-internal` | Absolute URLs pointing to localhost/staging/old-domain in content | scored | null |

#### CC4 — Frontmatter Quality

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `fm-title-missing` | Frontmatter `title` field missing or empty | advisory | null |
| `fm-description-missing` | Frontmatter `description` field missing or empty | advisory | null |
| `fm-date-missing` | Frontmatter `date` field missing | advisory | null |
| `fm-date-future` | Frontmatter `date` is in the future | advisory | null |
| `fm-yaml-malformed` | YAML parsing errors in frontmatter | blocking | null |
| `fm-encoding-artifact` | Unicode artifacts (NBSP, mojibake) in frontmatter string fields | scored | `encoding-strip` |

Note: `fm-title-missing` and `fm-description-missing` are advisory because
SEO effectiveness of these fields is `seo-audit`'s domain (D1). Content-audit
checks that frontmatter **exists and parses**; seo-audit evaluates **SEO
quality** (length, uniqueness, keyword relevance). `fm-description-truncated`
is removed — SERP truncation is a pure SEO signal owned by seo-audit D1.

#### CC5 — Image Integrity

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `img-path-broken` | Image path does not resolve to an existing file (source check) | scored | null |
| `img-path-relative-risk` | Framework-relative path (`@/`, `~/`, `../assets/`) — cannot verify without build | advisory | null |
| `img-alt-quality` | Alt text is filename, single word, or non-descriptive ("image", "photo", "img") | scored | null |
| `img-404-live` | Image returns 404/5xx on live site (requires `--live-url`) | blocking | null |
| `img-oversized` | Image file >500KB without optimization evidence | advisory | null |
| `img-spaces-in-path` | Image filename contains spaces or special characters | scored | null |

#### CC6 — Link Integrity

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `link-internal-broken` | Internal link target file does not exist (source check) | scored | null |
| `link-anchor-broken` | Fragment link (`#id`) does not match any heading in target | scored | null |
| `link-external-dead` | External link returns 404/5xx (requires `--live-url`) | scored | null |
| `link-external-redirect` | External link redirects >2 hops (requires `--live-url`) | advisory | null |
| `link-mailto-malformed` | Malformed mailto: link | advisory | null |
| `link-empty-href` | Empty `href=""` or `href="#"` in content | scored | null |

#### CC7 — Content Completeness

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `content-empty` | Content file has no body text (only frontmatter or whitespace) | scored | null |
| `content-draft-committed` | File has `draft: true` in frontmatter but is committed | advisory | null |
| `content-duplicate-paragraph` | Near-duplicate paragraphs across files (LLM-judged, non-deterministic, capped at top 50 files by size) | advisory | null |
| `content-orphan-file` | Content file not linked from navigation or other content | advisory | null |
| `content-stale` | Content older than 2 years with no recent git modification | advisory | null |

#### CC8 — Spelling & Typography

| check_slug | Check | enforcement | fix_type |
|------------|-------|-------------|----------|
| `typo-diacritics` | Missing or corrupted diacritics for detected language | scored | null |
| `typo-double-space` | Multiple consecutive spaces in prose (not code blocks) | advisory | `typography-fix` |
| `typo-double-punctuation` | Repeated punctuation (`..` not `...`, `,,`, `!!`) | advisory | `typography-fix` |
| `typo-spell-check` | Spell checker findings (requires `aspell`/`hunspell` installed) | advisory | null |
| `typo-inconsistent-quotes` | Mixed straight and curly quotes in same file | advisory | null |

### Fix Registry (`content-fix-registry.md`)

| fix_type | Description | Safety | eta_minutes |
|----------|-------------|--------|-------------|
| `encoding-strip` | Replace NBSP→space, remove ZWS/BOM/soft-hyphens | SAFE | 5 |
| `encoding-mojibake` | Replace garbled multi-byte sequences with correct characters | MODERATE | 10 |
| `markdown-fix` | Close unclosed italic at paragraph end, remove orphan `\` lines, fix split italic | SAFE | 5 |
| `artifact-remove` | Remove legacy CMS tags, shortcodes, PHP fragments, deprecated HTML | MODERATE | 10 |
| `typography-fix` | Collapse double spaces, fix double punctuation | SAFE | 5 |

### Content Path Auto-Detection

Detection cascade (first match wins):

| Framework | Auto-detected paths |
|-----------|-------------------|
| Hugo | `content/` |
| Astro | `src/content/`, `src/pages/` (`.md`/`.mdx` only) |
| Next.js | `content/`, `posts/`, `pages/` (`.md`/`.mdx` only) |
| Gatsby | `content/`, `src/pages/` |
| Generic | `content/`, `posts/`, `articles/`, `docs/`, `blog/` |

Override with `--content-path <dir>`.

### File Manifest Rules

**Include:** `.md`, `.mdx`, `.html` (in content dirs only), `.txt` (content-like)

**Exclude always:** `dist/`, `.next/`, `_site/`, `public/` (build output),
`node_modules/`, `.git/`, binary files (detected by extension: `.jpg`, `.png`,
`.gif`, `.pdf`, `.woff`, `.mp4`, `.zip`, etc.)

**Template files:** `.astro`, `.tsx`, `.jsx` — scan only text content between
tags, skip template expressions (`{...}`, `{{ }}`, `<% %>`)

### Scoring Model

Same tier model as `code-audit`:

| Grade | Score range | Meaning |
|-------|-----------|---------|
| **A** | 90-100% | Clean content, minor advisory items |
| **B** | 75-89% | Some issues, no blocking findings |
| **C** | 50-74% | Significant issues affecting quality |
| **D** | 0-49% | Critical issues, CMS migration incomplete |

Score = `(checks_passed / checks_applicable) * 100`

Blocking findings (`mojibake-detected`, `php-tag`, `fm-yaml-malformed`,
`img-404-live`) cap the grade at **D** regardless of score.

### Arguments

| Argument | Behavior |
|----------|----------|
| `[path]` | Scope to specific file or directory |
| `--content-path <dir>` | Override auto-detected content directory |
| `--live-url <url>` | Enable live link/image checks (CC5.4, CC6.3, CC6.4) |
| `--quick` | Grep-only checks, no agent dispatch: all blocking checks + `broken-italic`, `joomla-path`, `wp-shortcode`, `img-path-broken`, `link-internal-broken`. Skips CC4/CC7/CC8 entirely. |
| `--lang <code>` | Force language for spell/typography checks |
| `--check-external` | Enable external link checking (requires network) |
| `--persist-backlog` | Append findings to memory/backlog.md |
| `--profile <type>` | Content profile (blog, docs, ecommerce, marketing) for threshold tuning |

### Mandatory File Loading

```
1. ../../shared/includes/codesift-setup.md
2. ../../shared/includes/env-compat.md
3. ../../shared/includes/backlog-protocol.md
4. ../../shared/includes/content-check-registry.md   (NEW)
5. ../../shared/includes/audit-output-schema.md
6. ../../shared/includes/live-probe-protocol.md       (NEW — extracted from seo-audit)
7. ../../shared/includes/run-logger.md
8. ../../shared/includes/verification-protocol.md
```

### Integration Points

| Existing file | How content-audit uses it |
|--------------|--------------------------|
| `shared/includes/audit-output-schema.md` | JSON output follows v1.1 schema |
| `shared/includes/backlog-protocol.md` | Backlog persistence with fingerprint dedup |
| `shared/includes/env-compat.md` | Agent dispatch per environment |
| `scripts/adversarial-review.sh` | `--mode audit` for report validation |
| `skills/seo-audit/SKILL.md` | Replace inline live-probe rules with include reference to `shared/includes/live-probe-protocol.md` |
| `skills/using-zuvo/SKILL.md` | Add routing entry for content-audit intent |
| `docs/skills.md` | Update skill count 39→41 (audit + fix) |
| `.claude-plugin/plugin.json` | Update skill count |
| `.codex-plugin/plugin.json` | Update skill count |
| `package.json` | Update skill count metadata |

**New files to create:**

```
skills/content-audit/SKILL.md
skills/content-audit/agents/content-encoding.md
skills/content-audit/agents/content-links.md
skills/content-audit/agents/content-prose.md
skills/content-fix/SKILL.md
shared/includes/content-check-registry.md
shared/includes/content-fix-registry.md
shared/includes/live-probe-protocol.md   (extracted from seo-audit)
```

### Edge Cases

| Edge case | Handling strategy |
|-----------|-----------------|
| **Mixed encoding in single file** | Run `file -i` per file. Non-UTF-8 files get `ENCODING-WARN` and Unicode checks become `INSUFFICIENT DATA` |
| **Large files (100KB+)** | Read in 500-line chunks. Flag in evidence: "large file — chunked read" |
| **Binary files in content dir** | Skip by extension whitelist. Log in "Skipped files" section |
| **Template syntax false positives** | Strip template interpolation (`{...}`, `{{ }}`, `<% %>`) before text checks on `.astro`/`.tsx`/`.jsx`/`.mdx` files |
| **CMS-backed content (no local files)** | Detect CMS config files. Emit `CONTENT INACCESSIBLE` warning. Recommend `--live-url` |
| **Framework-relative image paths** | Flag as `POTENTIAL_RISK`, not hard FAIL. Definitive only with `--live-url` |
| **Anchor links to renamed headings** | Source mode: `PARTIAL`. Live mode: `FAIL` (DOM inspection) |
| **Multilingual content directories** | Detect language per file/directory. Apply language-specific checks only for matching language |
| **Standalone `\` (renderer-dependent)** | Stack-aware: flag for Hugo/Goldmark, skip for GFM-target renderers |
| **Duplicate content detection (O(n^2))** | Cap at top 50 longest files. Declare sampling strategy in report |
| **Frontmatter with template expressions** | Strip `{{...}}` and `{...}` from YAML string values before text checks |

## Acceptance Criteria

### Must have

1. Running `zuvo:content-audit` on a project with `.md` files produces findings for: NBSP, zero-width spaces, broken italic, mojibake, broken image paths, truncated frontmatter descriptions.
2. Every finding includes `file`, `line`, `check` (slug from registry), `evidence`, `severity`, `confidence`, and `fix_type` (or null).
3. JSON output conforms to `audit-output-schema.md` v1.1.
4. Markdown report is written to `audit-results/content-audit-YYYY-MM-DD.md`.
5. `--quick` mode skips CC4/CC7/CC8 agent dispatch and runs only grep-based checks (all blocking + key scored checks from CC1-CC3, CC5, CC6 source-only).
6. `--live-url` enables CC5.4 (image 404) and CC6.3/CC6.4 (link checks) with rate limiting per `live-probe-protocol.md`.
7. Template interpolation syntax in `.astro`, `.tsx`, `.mdx` files is stripped before text checks. Known template patterns (`{...}`, `{{ }}`, `<% %>`) are documented in `content-check-registry.md`.
8. Binary files in content directories are skipped without error.
9. `content-fix` reads audit JSON, applies SAFE fixes (`encoding-strip`, `markdown-fix`, `typography-fix`) without confirmation, applies MODERATE (`encoding-mojibake`, `artifact-remove`) only with `--auto`.
10. `content-fix` runs build verification after applying fixes.

### Should have

1. Language detection from frontmatter/directory/config; spell checks degrade to `INSUFFICIENT DATA` when language is unknown.
2. Frontmatter string fields are checked for encoding artifacts, not just body content.
3. Mojibake detection covers Latin-1, Windows-1252, ISO-8859-2, ISO-8859-9 encodings.
4. Duplicate paragraph detection is bounded and declares its sampling strategy.
5. `content-fix` supports `--dry-run` and `--finding` flags.
6. Adversarial review runs on both audit report and fix diff.

### Edge case handling

1. Non-UTF-8 files detected and flagged; Unicode checks become `INSUFFICIENT DATA`.
2. Files >100KB read in chunks with explicit note in evidence.
3. CMS-backed sites with no local content files emit `CONTENT INACCESSIBLE` warning.
4. Anchor fragment validation works in source mode (heading extraction) and live mode (DOM).
5. Stack-aware `\` backslash handling (Hugo vs GFM).
6. `--content-path` override works for non-standard directory structures.

## Out of Scope

- **SEO signals** — meta tag presence/length, heading hierarchy, alt text
  presence, thin content scoring, structured data, crawlability. These are
  `seo-audit`'s domain (D1, D6, D7, D9, D10).
- **Code quality** — production code patterns, test quality. These are
  `code-audit` and `test-audit` domains.
- **Content writing** — generating new content, rewriting paragraphs, SEO
  copywriting. The skill audits existing content, it does not create content.
- **CMS API content** — scanning content stored in headless CMS databases
  (Contentful, Sanity, Strapi). Only local files are scanned. Use `--live-url`
  for deployed content.
- **PDF/Word document scanning** — only plain text formats (md, mdx, html, txt).
- **Automated spell-check without installed tools** — LLM-based spell checking
  is advisory only for obvious errors (like corrupted diacritics). Full spell
  checking requires `aspell`/`hunspell` and is capability-gated.

## Open Questions

None — all design decisions resolved during brainstorm.
