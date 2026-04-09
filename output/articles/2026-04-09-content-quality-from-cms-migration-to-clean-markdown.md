---
title: "Content Quality: From CMS Migration to Clean Markdown"
description: "Encoding artifacts, mojibake, and database quirks follow you from Joomla and WordPress into Astro and Hugo unless you audit, fix, and verify before cutover."
date: "2026-04-09"
author: Zuvo
tags:
  - cms-migration
  - markdown
  - encoding
  - astro
  - hugo
keywords:
  - CMS migration
  - clean markdown
  - mojibake
  - content quality
research_limited: true
---

# Content Quality: From CMS Migration to Clean Markdown

**CMS migration** to Astro or Hugo is a chance to enforce **clean markdown**: predictable headings, honest punctuation, and text that survives diffs and linters. Static sites built with these generators reward that discipline. The bar sounds modest until you lift thousands of posts out of Joomla or WordPress. Legacy HTML, plugin shortcodes, and database encoding issues do not disappear when you change frameworks—they ride along inside exports and SQL dumps. This article names the failure modes, maps a practical pipeline, and points to verification habits that keep your new site readable for both humans and machines.

## Why CMS migrations surface “invisible” text problems

A CMS hides complexity behind an editor and a theme. When you move to file-based content, you inherit raw strings. Anything that was technically wrong but visually tolerable in the old stack can become obvious in Markdown previews, RSS readers, or search snippets. [Source: Astro migration guides emphasize export and conversion steps rather than assuming a one-click move.](https://docs.astro.build/en/guides/migrate-to-astro/from-wordpress/)

Two classes of issues dominate:

1. **Structural debris** — shortcodes, inline styles, spans inserted by page builders, and tables that never matched semantic HTML.
2. **Encoding and typography artifacts** — bytes that were stored, converted, or double-encoded while moving between PHP, MySQL, and export files.

The second class is especially cruel because it looks like “content” until you search for patterns or run automated checks. Mojibake is the usual label for text that was decoded with the wrong character set; the Unicode FAQ and general references describe it as garbling that appears when bytes are interpreted under a different mapping than the one used to write them. [Source: Wikipedia — Mojibake overview.](https://en.wikipedia.org/wiki/Mojibake)

## What broken text looks like in the real world

You will not always see one obvious glyph. Watch for these signatures:

- **Classic mojibake sequences** — sequences such as `Ã©` where you expected `é`, often from UTF-8 bytes read as Latin-1. [Source: common reports in WordPress and MySQL support threads about garbled characters after charset mismatches.](https://stackoverflow.com/questions/11024604/utf8-characters-not-showing-correctly-in-wordpress)
- **Question marks and tofu** — replacement characters where the pipeline lost code points, frequent when a connection or dump step used a legacy charset while content was already UTF-8.
- **Non-breaking spaces and zero-width characters** — invisible characters that break Markdown emphasis, search, or code fences. They often survive copy/paste from WYSIWYG editors.
- **“Double-encoded” UTF-8** — text that went through UTF-8 twice, producing over-lengthened sequences that are valid Unicode but wrong linguistically.

Variable-width UTF-8 sequences are easy to misread if any layer treats bytes as single-byte characters. [Source: Mojibake discussions note variable-width UTF-8 decoding errors.](https://en.wikipedia.org/wiki/Mojibake)

## Where Joomla and WordPress stacks hide the risk

**Database and connection charset** — WordPress stores MySQL text under a declared charset and collation. If the database, server connection, and PHP client disagree, the application may store or retrieve text with a different interpretation than you expect. Community threads and Stack Overflow answers often point to `utf8mb4` for full Unicode support and consistent connection flags. [Source: Stack Overflow UTF-8 display issues in WordPress contexts.](https://stackoverflow.com/questions/11024604/utf8-characters-not-showing-correctly-in-wordpress)

Joomla sites follow the same pattern at a different angle: PHP, the database driver, and table definitions must agree on how bytes round-trip. A staging export that looks fine in phpMyAdmin can still pick up silent transforms when copied through FTP, email, or a Windows editor that injects a BOM.

**Exports and dumps** — `mysqldump` and plugin exports can re-encode or mis-declare bytes if the default character set is not set for the session. Treat every dump as a binary artifact until you verify decoded text in a controlled editor. When in doubt, re-export with an explicit charset flag for the client session so the file header matches the bytes you think you wrote.

**The HTML layer** — Even when the database is correct, exports embed HTML entities, numeric references, and editor-specific spans. Those are not “encoding bugs,” but they interact with encoding fixes: you might repair bytes in SQL yet still ship HTML entities you should normalize for Markdown.

**RSS and feeds** — Syndicated XML is another hop. If feeds were generated while the database was misconfigured, subscribers may have seen correct text in HTML but wrong text in RSS, or the reverse. Compare feed archives with page HTML when you investigate odd clusters of bad characters.

## A practical CMS migration pipeline: audit, fix, migrate

Think in three explicit phases with different tools and exit criteria.

### 1. Audit — measure before you move

Scan for encoding artifacts, broken Unicode, HTML debris, and link rot before you promise parity with the old site. A structured audit answers questions like: “Do we have mojibake clusters?” “Are there NBSPs in code blocks?” “Are headings real headings or bold paragraphs?” In the Zuvo plugin ecosystem, **`zuvo:content-audit`** is designed to walk content files (and optional live URLs) across dimensions such as encoding artifacts, broken Markdown, migration debris, and link integrity—so you get a backlog instead of a vague feeling that something looks off. For background on how audit dimensions map to fixes, see `docs/specs/2026-04-07-content-audit-spec.md` in this repository (not a deployed URL—clone the plugin repo to read it).

### 2. Fix — apply safe, repeatable transforms

Once findings exist, batch fixes beat hand-editing. Normalize Unicode where you can prove it is safe, strip or replace editor-only spans, and re-encode sources when the issue is upstream in the dump. **`zuvo:content-fix`** is intended to consume audit output and apply tiered fixes (for example stripping problematic spaces or repairing common typography) while keeping human review for risky changes. The `docs/specs/2026-04-09-content-writing-skills-plan.md` file describes how fix tiers stay aligned with audit classes.

### 3. Migrate — compare old pages to new

When content is “clean enough,” run the structural migration. For Joomla or WordPress → Astro/Hugo, that often means exporting HTML or XML, mapping to Markdown or MDX, downloading media into static folders, and preserving redirects. **`zuvo:content-migration`** compares an old URL with a new page to catch missing headings, paragraphs, images, CTAs, and tables—exactly the class of regressions that encoding noise can obscure until you compare systematically. See `docs/specs/2026-04-07-content-migration-spec.md` for the comparison contract and optional `--fix` behavior.

Hugo documents migration tooling and community paths from other systems; Astro publishes WordPress-oriented guidance. [Source: Hugo migrations](https://gohugo.io/tools/migrations/), [Source: Astro — migrate from WordPress](https://docs.astro.build/en/guides/migrate-to-astro/from-wordpress/)

## What changes at Astro or Hugo

Both ecosystems expect content as files under `content/` or `src/content/`. That shift is an opportunity:

- **Frontmatter** — Move metadata out of HTML comments and into YAML/TOML. Keep a single schema per section so linters and editors agree.
- **Components** — Replace shortcodes with Astro components or Hugo shortcodes deliberately. Do not leave raw `[shortcode]` strings unless you intend to support them.
- **Images** — Put assets in `static/` or `public/` (or framework-native pipelines) and fix `src` paths during migration. Broken images are often caught late because text looks fine.

If your Markdown still carries odd bytes, builds may succeed while RSS, Open Graph, or AI crawlers see noisy strings. Cleaning before you wire templates reduces debugging time.

## Verification habits that stick

- **Spot-check random posts** across languages, not only English. Emoji, extended Latin, and Indic scripts stress UTF-8 handling differently than ASCII-heavy posts.
- **Search for mojibake markers** — repeated Latin-1 misfires follow patterns you can grep.
- **Validate UTF-8** at the file level after conversion; reopen in a hex-friendly editor when something looks “almost right.”
- **Freeze a golden set** — pick ten representative URLs (long article, heavy tables, old comments, non-Latin title) and store expected plain-text extracts. Regression-test your conversion script against that set whenever you change dependencies.
- **Diff at the paragraph level**, not only file level. Small invisible characters often hide in the middle of a line; side-by-side paragraph diffs surface them faster than whole-file compares.
- **Use specialized repair libraries when appropriate** — open-source tools such as `ftfy` (Python) are widely referenced for fixing mojibake and double-encoding in bulk, with the usual caveat to test on copies first. [Source: ftfy project (GitHub).](https://github.com/LuminosoInsight/python-ftfy)

## Bottom line

A migration to Astro or Hugo is not only a framework swap—**it is a quality gate for text**. Treat encoding artifacts and CMS debris as first-class risks, audit early, fix with automation where safe, and prove parity with structured comparisons. Clean markdown is not an aesthetic preference; it is what keeps your content stable across builds, search, and the next migration in five years.

---

## BlogPosting JSON-LD payload

Site templates should emit this object from the HTML `<head>` as `application/ld+json`. The fence holds the payload for copy-paste into a layout helper.

```json
{
  "@context": "https://schema.org",
  "@type": "BlogPosting",
  "headline": "Content Quality: From CMS Migration to Clean Markdown",
  "description": "Encoding artifacts, mojibake, and database quirks follow you from Joomla and WordPress into Astro and Hugo unless you audit, fix, and verify before cutover.",
  "author": { "@type": "Organization", "name": "Zuvo" },
  "datePublished": "2026-04-09",
  "dateModified": "2026-04-09"
}
```
