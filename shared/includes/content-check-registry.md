# Content Check Registry (canonical slugs)

> Single source of truth for all check IDs used in `content-audit` findings.
> Agents MUST use these exact slugs in `findings[].check`.
> Finding ID = `{dimension}-{check_slug}` (for example `CC1-nbsp-present`).

## Canonical Columns

| field | purpose |
|------|---------|
| `owner_agent` | The audit agent responsible for evaluating the check. |
| `layer` | One of `encoding`, `syntax`, `migration`, `metadata`, `integrity`, `content`, or `typography`. |
| `enforcement` | One of `blocking`, `scored`, or `advisory`. |
| `evidence_mode` | One of `code`, `live`, `either`, or `proxy`. |
| `fix_type` | Shared remediation mapping when the check is auto-fixable. |

## Semantic Notes

- Content-audit checks editorial/migration hygiene, NOT SEO signals.
  `seo-audit` owns: heading hierarchy (D1/D9), meta tag presence/length (D1),
  alt text presence (D6), thin content (D9), semantic HTML (D10).
- `fm-title-missing` and `fm-description-missing` are advisory because SEO
  effectiveness is `seo-audit`'s domain. Content-audit checks that frontmatter
  **exists and parses**; seo-audit evaluates **SEO quality**.
- Template expressions (`{...}`, `{{ }}`, `<% %>`) must be stripped from
  `.astro`, `.tsx`, `.jsx`, `.mdx` files before running CC2 and CC8 checks.
  Known patterns: Astro `{expr}`, Hugo `{{ .Var }}`, EJS `<% code %>`,
  Svelte `{#each}`, Vue `v-bind`.
- Language-specific checks (CC8 typo-diacritics, typo-spell-check) activate
  only when language is detected. If language is unknown, these checks emit
  `INSUFFICIENT DATA`, not false positives.

## CC1 — Encoding Quality

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `nbsp-present` | Non-breaking spaces (U+00A0) in content | `content-encoding` | encoding | scored | code | `encoding-strip` |
| `zero-width-present` | Zero-width spaces (U+200B, U+200C, U+200D, U+FEFF) | `content-encoding` | encoding | scored | code | `encoding-strip` |
| `bom-present` | UTF-8 BOM marker at file start | `content-encoding` | encoding | advisory | code | `encoding-strip` |
| `mojibake-detected` | Garbled multi-byte sequences from encoding mismatch | `content-encoding` | encoding | blocking | code | `encoding-mojibake` |
| `replacement-char` | U+FFFD replacement characters present | `content-encoding` | encoding | scored | code | `encoding-strip` |
| `encoding-mismatch` | File encoding is not UTF-8 (detected via `file -i`) | `content-encoding` | encoding | advisory | code | null |
| `soft-hyphen-present` | Soft hyphens (U+00AD) in content | `content-encoding` | encoding | advisory | code | `encoding-strip` |

## CC2 — Markdown Syntax

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `broken-italic` | Unclosed `*` or `_` at paragraph end | `content-encoding` | syntax | scored | code | `markdown-fix` |
| `split-italic` | Split formatting like `* *text*` | `content-encoding` | syntax | scored | code | `markdown-fix` |
| `orphan-backslash` | Standalone `\` on a line (not a line break in target renderer) | `content-encoding` | syntax | advisory | code | `markdown-fix` |
| `unclosed-code` | Unclosed inline code or fenced code block | `content-encoding` | syntax | scored | code | null |
| `malformed-link` | Broken link syntax `[text](`, `[](url)`, unmatched `[]` | `content-encoding` | syntax | scored | code | null |
| `malformed-image` | Broken image syntax `![](`, missing closing `)` | `content-encoding` | syntax | scored | code | null |
| `unlabeled-code-block` | Fenced code block without language label | `content-encoding` | syntax | advisory | code | null |

## CC3 — Migration Artifacts

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `joomla-path` | Joomla-style paths (`/images/stories/`, `index.php?option=com_`) | `content-encoding` | migration | scored | code | `artifact-remove` |
| `wp-shortcode` | WordPress shortcodes (`[caption]`, `[gallery]`, `[embed]`) | `content-encoding` | migration | scored | code | `artifact-remove` |
| `php-tag` | PHP tags (`<?php`, `<?=`) in content files | `content-encoding` | migration | blocking | code | `artifact-remove` |
| `legacy-html` | Deprecated HTML (`<font>`, `<center>`, `align=`) | `content-encoding` | migration | scored | code | `artifact-remove` |
| `wysiwyg-junk` | Excessive inline styles from WYSIWYG editors (`style="..."` >50 chars) | `content-encoding` | migration | scored | code | `artifact-remove` |
| `template-unexpanded` | Unexpanded template variables (`{{title}}`, `%TITLE%`, `{component}`) | `content-encoding` | migration | scored | code | null |
| `cms-url-internal` | Absolute URLs pointing to localhost/staging/old-domain in content | `content-encoding` | migration | scored | code | null |

## CC4 — Frontmatter Quality

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `fm-title-missing` | Frontmatter `title` field missing or empty | `content-prose` | metadata | advisory | code | null |
| `fm-description-missing` | Frontmatter `description` field missing or empty | `content-prose` | metadata | advisory | code | null |
| `fm-date-missing` | Frontmatter `date` field missing | `content-prose` | metadata | advisory | code | null |
| `fm-date-future` | Frontmatter `date` is in the future | `content-prose` | metadata | advisory | code | null |
| `fm-yaml-malformed` | YAML parsing errors in frontmatter | `content-prose` | metadata | blocking | code | null |
| `fm-encoding-artifact` | Unicode artifacts (NBSP, mojibake) in frontmatter string fields | `content-prose` | metadata | scored | code | `encoding-strip` |

## CC5 — Image Integrity

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `img-path-broken` | Image path does not resolve to an existing file (source check) | `content-links` | integrity | scored | code | null |
| `img-path-relative-risk` | Framework-relative path (`@/`, `~/`, `../assets/`) — cannot verify without build | `content-links` | integrity | advisory | code | null |
| `img-alt-quality` | Alt text is filename, single word, or non-descriptive ("image", "photo", "img") | `content-links` | integrity | scored | code | null |
| `img-404-live` | Image returns 404/5xx on live site (requires `--live-url`) | `content-links` | integrity | blocking | live | null |
| `img-oversized` | Image file >500KB without optimization evidence | `content-links` | integrity | advisory | code | null |
| `img-spaces-in-path` | Image filename contains spaces or special characters | `content-links` | integrity | scored | code | null |

## CC6 — Link Integrity

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `link-internal-broken` | Internal link target file does not exist (source check) | `content-links` | integrity | scored | code | null |
| `link-anchor-broken` | Fragment link (`#id`) does not match any heading in target | `content-links` | integrity | scored | either | null |
| `link-external-dead` | External link returns 404/5xx (requires `--live-url`) | `content-links` | integrity | scored | live | null |
| `link-external-redirect` | External link redirects >2 hops (requires `--live-url`) | `content-links` | integrity | advisory | live | null |
| `link-mailto-malformed` | Malformed mailto: link | `content-links` | integrity | advisory | code | null |
| `link-empty-href` | Empty `href=""` or `href="#"` in content | `content-links` | integrity | scored | code | null |

## CC7 — Content Completeness

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `content-empty` | Content file has no body text (only frontmatter or whitespace) | `content-prose` | content | scored | code | null |
| `content-draft-committed` | File has `draft: true` in frontmatter but is committed | `content-prose` | content | advisory | code | null |
| `content-duplicate-paragraph` | Near-duplicate paragraphs across files (LLM-judged, non-deterministic, capped at top 50 files by size) | `content-prose` | content | advisory | proxy | null |
| `content-orphan-file` | Content file not linked from navigation or other content | `content-prose` | content | advisory | proxy | null |
| `content-stale` | Content older than 2 years with no recent git modification | `content-prose` | content | advisory | proxy | null |

## CC8 — Spelling & Typography

| check_slug | Check | owner_agent | layer | enforcement | evidence_mode | fix_type |
|------------|-------|-------------|-------|-------------|---------------|----------|
| `typo-diacritics` | Missing or corrupted diacritics for detected language | `content-prose` | typography | scored | code | null |
| `typo-double-space` | Multiple consecutive spaces in prose (not code blocks) | `content-prose` | typography | advisory | code | `typography-fix` |
| `typo-double-punctuation` | Repeated punctuation (`..` not `...`, `,,`, `!!`) | `content-prose` | typography | advisory | code | `typography-fix` |
| `typo-spell-check` | Spell checker findings (requires `aspell`/`hunspell` installed) | `content-prose` | typography | advisory | code | null |
| `typo-inconsistent-quotes` | Mixed straight and curly quotes in same file | `content-prose` | typography | advisory | code | null |

---

## Summary

| Dimension | Check count |
|-----------|------------|
| CC1 | 7 |
| CC2 | 7 |
| CC3 | 7 |
| CC4 | 6 |
| CC5 | 6 |
| CC6 | 6 |
| CC7 | 5 |
| CC8 | 5 |
| **Total** | **49** |
| Blocking checks | 4 (`mojibake-detected`, `php-tag`, `fm-yaml-malformed`, `img-404-live`) |

## Quick Mode Checks

When `--quick` is active, only source-only grep checks run (no agent dispatch):

- CC1: `mojibake-detected` (blocking), `nbsp-present`, `zero-width-present`
- CC2: `broken-italic`
- CC3: `php-tag` (blocking), `joomla-path`, `wp-shortcode`
- CC5: `img-path-broken` (Glob path resolution)
- CC6: `link-internal-broken` (Glob path resolution)

Checks returning `INSUFFICIENT DATA` in quick mode:
- `fm-yaml-malformed` (needs YAML parser, not grep)
- `img-404-live` (needs `--live-url`, not grep)
- All CC4, CC7, CC8 checks (need agent dispatch)
