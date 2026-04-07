# Migration Fix Registry (content-migration)

> Fix types for CMS-to-SSG content migration parity fixes.
> Used by `content-migration` skill when `--fix` is enabled.

## Fix Inventory

| fix_type | Description | Safety | eta_minutes |
|----------|-------------|--------|-------------|
| `content-add` | Insert missing heading, paragraph, or section from old site | MODERATE | 5 |
| `cta-restore` | Add missing CTA button/link from old site | MODERATE | 5 |

## Deferred to V2

| fix_type | Description | Safety | Reason |
|----------|-------------|--------|--------|
| `img-path-rewrite` | Update image src to new location | MODERATE | Needs asset mapping strategy |
| `content-reorder` | Move content section to match original ordering | DANGEROUS | Complex section boundary detection |

## Fix Application Rules

- All fixes require `--fix` flag (default is compare-only)
- MODERATE fixes apply with `--fix` — user has explicitly opted in
- No DANGEROUS fixes in V1 — report as `MANUAL_FIX_NEEDED`
- Never delete content from the new site
- Never modify files outside the resolved source file

## Content Serialization

Extracted DOM content is converted to markdown before insertion:

| Old site element | Markdown output |
|-----------------|----------------|
| `<h2>Title</h2>` | `## Title` |
| `<h3>Title</h3>` | `### Title` |
| `<p>text</p>` | Plain paragraph |
| `<strong>bold</strong>` | `**bold**` |
| `<em>italic</em>` | `*italic*` |
| `<a href="url">text</a>` | `[text](url)` |
| `<ul><li>item</li></ul>` | `- item` |
| `<ol><li>item</li></ol>` | `1. item` |
| `<blockquote>text</blockquote>` | `> text` |
| Inline styles, `<span>`, `<div>` | Strip tags, keep text |

## Insertion Algorithm

1. Find nearest **matched heading** in the new file that **precedes** the
   missing element's position in the old file
2. Insert after that heading's section (before next heading of same/higher level)
3. If no anchor found: insert at beginning of content body (after frontmatter)
4. If ambiguous: append before EOF, flag as `NEEDS_REVIEW`

## Confidence Scale

| Level | When |
|-------|------|
| HIGH | Element clearly present in old, clearly absent in new |
| MEDIUM | Fuzzy match — element partially present or text differs |
| LOW | Heuristic inference (e.g., CTA detected by keyword, not by class) |
