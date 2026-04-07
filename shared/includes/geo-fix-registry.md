# GEO Fix Registry (shared between geo-audit agents and geo-fix)

> Single source of truth for `fix_type` identifiers, safety classifications,
> target platforms, validation rules, caveats, and `fix_params` schema.
> Both `geo-audit` agents (producers) and `geo-fix` (consumer) MUST use this
> registry.
> If a `fix_type` is not listed here, it is not auto-fixable.

## Fix Inventory

| fix_type | Description | Fixable? | Base safety | eta_minutes | Target platforms |
|----------|-------------|----------|-------------|-------------|-----------------|
| `robots-ai-allow` | Add allow rules for retrieval bots | yes | SAFE | 5 | Universal |
| `robots-ai-policy-change` | Modify existing bot rules (could open training) | manual | DANGEROUS | 15 | Universal |
| `schema-org-add` | Add Organization JSON-LD to root layout | yes | MODERATE | 15 | Astro, Next.js, Hugo |
| `schema-article-add` | Add Article JSON-LD to blog/post layout | yes | MODERATE | 15 | Astro, Next.js, Hugo |
| `schema-faq-add` | Add FAQPage JSON-LD to Q/A content pages | yes | MODERATE | 20 | Astro, Next.js, Hugo |
| `schema-id-link` | Connect existing schemas via @id | yes | MODERATE | 10 | Universal |
| `schema-restructure` | Modify existing JSON-LD structure | manual | DANGEROUS | 30 | Universal |
| `canonical-add` | Add canonical tag to base layout | yes | SAFE | 5 | Astro, Next.js, Hugo |
| `trailing-slash-config` | Set framework trailing slash config | yes | MODERATE | 10 | Astro, Next.js, Hugo |
| `sitemap-robots-ref` | Add Sitemap directive to robots.txt | yes | SAFE | 5 | Universal |
| `sitemap-lastmod-fix` | Add/fix lastmod from git/frontmatter | yes | MODERATE | 15 | Universal |
| `frontmatter-date-add` | Add dateModified to content frontmatter | yes | MODERATE | 10 | Universal |
| `schema-date-add` | Add dateModified to Article schema | yes | MODERATE | 10 | Astro, Next.js, Hugo |
| `freshness-ui-add` | Add visible "Updated: date" component | yes | MODERATE | 15 | Astro, Next.js, Hugo |
| `llms-txt-generate` | Generate llms.txt from sitemap/content | yes | SAFE | 10 | Universal |
| `llms-txt-update` | Add missing entries to existing llms.txt | yes | SAFE | 5 | Universal |

**Audit agents:** For checks that result in `FAIL`, set `fix_type` to the
matching value above. If no fix type matches, set `fix_type: null`.

**geo-fix:** Only processes findings where `fix_type` is in the fixable rows
above (Fixable? = yes). Findings marked `manual` require human review.

## Safety Classification (per framework)

Base safety may be upgraded one tier by `geo-fix` if the target file already
contains related config or conflicting implementations. See Context-Aware Safety
Upgrade Rules below.

| fix_type | astro | nextjs | hugo | * (universal) |
|----------|-------|--------|------|---------------|
| `robots-ai-allow` | SAFE | SAFE | SAFE | SAFE |
| `sitemap-robots-ref` | SAFE | SAFE | SAFE | SAFE |
| `canonical-add` | SAFE | SAFE | SAFE | -- |
| `llms-txt-generate` | SAFE | SAFE | SAFE | SAFE |
| `llms-txt-update` | SAFE | SAFE | SAFE | SAFE |
| `schema-org-add` | MODERATE | MODERATE | MODERATE | -- |
| `schema-article-add` | MODERATE | MODERATE | MODERATE | -- |
| `schema-faq-add` | MODERATE | MODERATE | MODERATE | -- |
| `schema-id-link` | MODERATE | MODERATE | MODERATE | MODERATE |
| `trailing-slash-config` | MODERATE | MODERATE | MODERATE | -- |
| `sitemap-lastmod-fix` | MODERATE | MODERATE | MODERATE | MODERATE |
| `frontmatter-date-add` | MODERATE | MODERATE | MODERATE | MODERATE |
| `schema-date-add` | MODERATE | MODERATE | MODERATE | -- |
| `freshness-ui-add` | MODERATE | MODERATE | MODERATE | -- |
| `robots-ai-policy-change` | DANGEROUS | DANGEROUS | DANGEROUS | DANGEROUS |
| `schema-restructure` | DANGEROUS | DANGEROUS | DANGEROUS | DANGEROUS |

## Context-Aware Safety Upgrade Rules

The following fix types are `upgrade_eligible: true`. When the condition is met,
`geo-fix` MUST upgrade the safety tier by one level before applying the fix.
Upgraded fixes require explicit confirmation or a `--force` flag to proceed.

| fix_type | Upgrade condition | From → To |
|----------|-------------------|-----------|
| `schema-org-add` | Target file contains existing JSON-LD | MODERATE → DANGEROUS |
| `schema-article-add` | Target file contains existing JSON-LD | MODERATE → DANGEROUS |
| `schema-faq-add` | Target file contains existing JSON-LD | MODERATE → DANGEROUS |
| `schema-id-link` | Target file contains existing `@id` references | MODERATE → DANGEROUS |
| `robots-ai-allow` | `robots.txt` has existing bot rules | SAFE → MODERATE |
| `canonical-add` | Layout file has an existing canonical tag | SAFE → MODERATE |

All other fix types: `upgrade_eligible: false`. Their safety tier is fixed.

When a safety upgrade fires, `geo-fix` MUST:

1. Record `upgraded: true` and `upgrade_reason: "<condition matched>"` in the
   fix result JSON.
2. Downgrade the finding to `NEEDS_REVIEW` if running in non-interactive mode
   without `--force`.
3. Emit a warning block naming the conflict before applying the fix.

## Fix Parameters Schema

| fix_type | Required params | Optional params |
|----------|-----------------|-----------------|
| `robots-ai-allow` | `framework` | `bot_keys`, `current_rules`, `platform_overrides` |
| `robots-ai-policy-change` | -- | -- |
| `schema-org-add` | `framework` | `org_name`, `site_url`, `logo_url`, `social_profiles` |
| `schema-article-add` | `framework`, `page_class` | `author`, `date_published`, `date_modified`, `site_url` |
| `schema-faq-add` | `framework` | `page_class`, `faq_items` |
| `schema-id-link` | `framework`, `source_type`, `target_type` | `base_url`, `existing_ids` |
| `schema-restructure` | -- | -- |
| `canonical-add` | `framework` | `site_url`, `preferred_host` |
| `trailing-slash-config` | `framework` | `current_setting`, `preferred_mode` |
| `sitemap-robots-ref` | `framework` | `sitemap_url` |
| `sitemap-lastmod-fix` | `framework`, `lastmod_strategy` | `content_dirs`, `git_log_format` |
| `frontmatter-date-add` | -- | `content_dirs`, `date_field`, `date_source` |
| `schema-date-add` | `framework` | `page_class`, `date_field`, `date_source` |
| `freshness-ui-add` | `framework` | `component_path`, `date_field`, `date_format` |
| `llms-txt-generate` | -- | `site_name`, `site_url`, `pages`, `content_dirs`, `generate_full_companion` |
| `llms-txt-update` | `existing_llms_path` | `site_url`, `pages`, `content_dirs` |

## Estimated Time Bands

| Effort | Time band |
|--------|-----------|
| EASY | <30 minutes |
| MEDIUM | 1-4 hours |
| HARD | 1+ day |
| MANUAL | Human review required; do not estimate automatically |

## Expanded Fix Contracts

### `schema-org-add`

**Pre-conditions:**
- Root layout file is locatable (`layout.astro`, `_app.tsx`, `baseof.html`, etc.)
- `upgrade_eligible` check: scan file for any `<script type="application/ld+json">` block; if found, upgrade to DANGEROUS

**Templates:**

Astro (`src/layouts/Layout.astro` — inside `<head>`):
```astro
<script type="application/ld+json" set:html={JSON.stringify({
  "@context": "https://schema.org",
  "@type": "Organization",
  "@id": "{site_url}/#organization",
  "name": "{org_name}",
  "url": "{site_url}",
  "logo": {
    "@type": "ImageObject",
    "url": "{logo_url}"
  },
  "sameAs": [/* {social_profiles} */]
})} />
```

Next.js (`app/layout.tsx` — inside `<head>` or via `next/script`):
```tsx
<script
  type="application/ld+json"
  dangerouslySetInnerHTML={{__html: JSON.stringify({
    "@context": "https://schema.org",
    "@type": "Organization",
    "@id": "{site_url}/#organization",
    "name": "{org_name}",
    "url": "{site_url}",
    "logo": {"@type": "ImageObject", "url": "{logo_url}"},
    "sameAs": [/* {social_profiles} */]
  })}}
/>
```

Hugo (`layouts/partials/head.html` — inside `<head>`):
```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "Organization",
  "@id": "{{ .Site.BaseURL }}#organization",
  "name": "{{ .Site.Title }}",
  "url": "{{ .Site.BaseURL }}"
}
</script>
```

**Post-conditions:**
- Exactly one Organization block in root layout
- `@id` follows `{site_url}/#organization` pattern
- No duplicate `@type: Organization` blocks across layouts

**Validation:**
- Confirm raw HTML response includes the `<script type="application/ld+json">` block
- Validate against Schema.org Organization required fields
- If existing JSON-LD was present and upgrade fired, emit `NEEDS_REVIEW` unless `--force`

---

### `schema-article-add`

**Pre-conditions:**
- Blog or post layout file is locatable (`[slug].astro`, `posts/[id]/page.tsx`, `single.html`, etc.)
- `upgrade_eligible` check: scan layout for any existing `<script type="application/ld+json">` block; if found, upgrade to DANGEROUS

**Templates:**

Astro (`src/layouts/BlogPost.astro` or equivalent — inside `<head>`):
```astro
<script type="application/ld+json" set:html={JSON.stringify({
  "@context": "https://schema.org",
  "@type": "Article",
  "@id": `${Astro.url}#article`,
  "headline": title,
  "datePublished": datePublished,
  "dateModified": dateModified ?? datePublished,
  "author": {"@type": "Person", "name": author},
  "isPartOf": {"@id": "{site_url}/#organization"}
})} />
```

Next.js (inside blog post `page.tsx` or layout):
```tsx
<script
  type="application/ld+json"
  dangerouslySetInnerHTML={{__html: JSON.stringify({
    "@context": "https://schema.org",
    "@type": "Article",
    "@id": `${pageUrl}#article`,
    "headline": title,
    "datePublished": datePublished,
    "dateModified": dateModified ?? datePublished,
    "author": {"@type": "Person", "name": author},
    "isPartOf": {"@id": "{site_url}/#organization"}
  })}}
/>
```

Hugo (`layouts/_default/single.html` — inside `<head>`):
```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "Article",
  "@id": "{{ .Permalink }}#article",
  "headline": "{{ .Title }}",
  "datePublished": "{{ .Date.Format "2006-01-02T15:04:05Z07:00" }}",
  "dateModified": "{{ .Lastmod.Format "2006-01-02T15:04:05Z07:00" }}",
  "author": {"@type": "Person", "name": "{{ .Params.author }}"},
  "isPartOf": {"@id": "{{ .Site.BaseURL }}#organization"}
}
</script>
```

**Post-conditions:**
- One Article block per post layout, not per-page inline
- `dateModified` present and not identical to `datePublished` (if git history allows)
- `isPartOf` references the Organization `@id` from `schema-org-add`

**Validation:**
- Confirm `datePublished` and `dateModified` fields are valid ISO 8601 strings
- Confirm `@id` is unique per article URL
- If upgrade fired due to existing JSON-LD, emit `NEEDS_REVIEW` unless `--force`

---

### `schema-faq-add`

**Pre-conditions:**
- Target page or layout is identifiable as Q/A content (FAQ route, help page, etc.)
- `faq_items` must be derivable from page content or passed as param
- `upgrade_eligible` check: scan target for existing `<script type="application/ld+json">`; if found, upgrade to DANGEROUS

**Templates:**

Astro (inside FAQ page component — `<head>` or bottom of `<body>`):
```astro
<script type="application/ld+json" set:html={JSON.stringify({
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": faqItems.map(item => ({
    "@type": "Question",
    "name": item.question,
    "acceptedAnswer": {
      "@type": "Answer",
      "text": item.answer
    }
  }))
})} />
```

Next.js:
```tsx
<script
  type="application/ld+json"
  dangerouslySetInnerHTML={{__html: JSON.stringify({
    "@context": "https://schema.org",
    "@type": "FAQPage",
    "mainEntity": faqItems.map(item => ({
      "@type": "Question",
      "name": item.question,
      "acceptedAnswer": {"@type": "Answer", "text": item.answer}
    }))
  })}}
/>
```

Hugo (partial — `layouts/partials/schema-faq.html`):
```html
<script type="application/ld+json">
{
  "@context": "https://schema.org",
  "@type": "FAQPage",
  "mainEntity": [
    {{ range .Params.faq }}
    {
      "@type": "Question",
      "name": "{{ .question }}",
      "acceptedAnswer": {"@type": "Answer", "text": "{{ .answer }}"}
    }{{ if not (last 1 .) }},{{ end }}
    {{ end }}
  ]
}
</script>
```

**Post-conditions:**
- `faqItems` array has at least two entries
- Each Question has non-empty `name` and `acceptedAnswer.text`
- No duplicate FAQPage blocks on the same URL

**Validation:**
- Validate against Schema.org FAQPage spec (minimum fields)
- If upgrade fired, emit `NEEDS_REVIEW` unless `--force`

---

### `schema-id-link`

**Pre-conditions:**
- At least two existing JSON-LD blocks are present across layouts
- `source_type` and `target_type` are known (e.g., Article → Organization)
- `upgrade_eligible` check: if any existing block already contains a `@id` matching `base_url`, upgrade to DANGEROUS

**Templates (universal — framework-agnostic JSON-LD patch):**

Add `"isPartOf"` / `"publisher"` / `"author"` link from Article to Organization:
```json
"isPartOf": {"@id": "{site_url}/#organization"},
"publisher": {"@id": "{site_url}/#organization"}
```

Add `"mainEntityOfPage"` back-link from Organization to homepage:
```json
"mainEntityOfPage": {"@id": "{site_url}/"}
```

Add `"breadcrumb"` link referencing a BreadcrumbList `@id`:
```json
"breadcrumb": {"@id": "{page_url}#breadcrumb"}
```

**Post-conditions:**
- All linked `@id` values resolve to a block present in the page or root layout
- No circular `@id` references
- Each `@id` value is an absolute URL (not a fragment-only value)

**Validation:**
- Confirm `@id` values are consistent between the linking block and target block
- If upgrade fired due to existing `@id` references, emit `NEEDS_REVIEW` unless `--force`
- Manual check: Google Rich Results Test — confirm graph is connected

---

## OUT_OF_SCOPE Handling

Findings coded **G9–G12** have `fix_type: null` and `fix_safety: "OUT_OF_SCOPE"`.
These map to content-quality gaps that no automated tool can resolve correctly.

**geo-fix behavior for OUT_OF_SCOPE findings:**

- NEVER writes body copy, descriptions, summaries, or factual content
- NEVER populates author bios, About pages, or mission statements
- Emits **structural scaffolds only**: HTML comment placeholders that mark
  where content must be added by a human or content team
- Scaffold format: `<!-- TODO: [description of content needed] -->`

**Example scaffold output for a missing About page section:**
```html
<!-- TODO: Add a 150-300 word organization description here.
     Include: founding year, core mission, primary audience, key differentiators.
     GEO signal: this content is used by AI retrieval to answer "what is {org_name}?" -->
```

**Example scaffold output for missing author attribution:**
```html
<!-- TODO: Add author bio block.
     Include: name, role, expertise areas, optional photo alt text.
     GEO signal: named authorship increases E-E-A-T signals for AI citation. -->
```

**Scaffold rules:**
- One scaffold comment per missing content area; do not duplicate
- Scaffold comments MUST include a brief GEO rationale so the content author
  understands why the content matters for AI retrieval
- geo-fix records these as `status: SCAFFOLDED` (not `APPLIED` or `SKIPPED`)
  in the fix result JSON
- Scaffolds do not count toward the fix success count in the run summary

---

## Dedup Boundary

`geo-fix` includes `llms-txt-generate` and `llms-txt-update` fix types. These
overlap with `seo-fix`'s `llms-txt-add` fix type.

**Dedup protocol (runtime):**

1. Before applying `llms-txt-generate` or `llms-txt-update`, geo-fix reads the
   seo-fix output JSON (if present) from the current audit run.
2. If a `llms-txt-add` entry exists in the seo-fix JSON with a matching `file`
   path and `status: APPLIED`, geo-fix MUST skip the llms-txt fix and record
   `status: DEDUPED` with `dedup_source: "seo-fix"`.
3. If seo-fix applied `llms-txt-add` but the result was `NEEDS_REVIEW` or
   `FAILED`, geo-fix proceeds with its own fix attempt and records the attempt
   independently.
4. If no seo-fix JSON is present, geo-fix proceeds normally.

This ensures exactly one agent writes the `llms.txt` file per run, preventing
conflicting writes.

---

## Confidence Scale

Assigned by audit agents per finding:

| Level | When |
|-------|------|
| HIGH | Direct evidence in source code or live response (`file:line`, raw HTTP) |
| MEDIUM | Inferred from config/convention but not directly observed |
| LOW | Heuristic or absence-based inference |
