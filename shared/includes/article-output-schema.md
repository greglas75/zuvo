# Article Output Schema — write-article JSON Contract

> Version 1.0. Consumed by `write-article` Phase 5 for structured output.

## Schema

```json
{
  "version": "1.0",
  "skill": "write-article",
  "timestamp": "ISO-8601 UTC with Z suffix",
  "project": "git root basename",
  "args": {
    "topic": "string (required)",
    "lang": "en|pl|... (default: en)",
    "tone": "casual|technical|formal|marketing (default: casual)",
    "length": "number (default: 1500)",
    "format": "md|astro-mdx|hugo|nextjs-mdx (default: md)",
    "keyword": "string|null (auto-detected if omitted)",
    "audience": "string|null",
    "site_dir": "string|null",
    "batch_mode": "boolean (default: false)"
  },
  "article": {
    "title": "string — article title",
    "slug": "string — URL-safe kebab-case slug",
    "language": "string — ISO 639-1 code",
    "tone": "string — active tone setting",
    "word_count": "number — actual word count of body",
    "format": "string — output format used",
    "output_path": "string — absolute path to saved file",
    "research_limited": "boolean — true if web search was unavailable"
  },
  "research": {
    "sources_count": "number — web sources consulted",
    "personas_count": "number — reader personas generated (3-5)",
    "competitor_gaps": ["string — each identified gap"],
    "facts_used": "number — facts from fact sheet used in draft",
    "facts_available": "number — total facts in fact sheet"
  },
  "quality": {
    "anti_slop": {
      "hard_violations": "number — should be 0",
      "soft_violations": "number — count of soft-ban hits"
    },
    "burstiness_score": "string — GOOD|FAIR|POOR",
    "adversarial_verdict": "PASS|WARN|FAIL|SKIPPED"
  },
  "seo": {
    "primary_keyword": "string",
    "meta_title": "string — 50-60 chars",
    "meta_description": "string — 150-160 chars",
    "schema_type": "BlogPosting|Article",
    "internal_links_suggested": "number",
    "internal_links_verified": "number — verified against real files (if site-dir)"
  }
}
```

## Required Fields

All top-level fields are required. Within nested objects:
- `args.*`: all present, null if not provided by user
- `article.*`: all required
- `research.*`: all required (0 if research was limited)
- `quality.*`: all required
- `seo.*`: all required

## Output Path

The JSON file is saved alongside the article:
- Default: `output/articles/YYYY-MM-DD-<slug>.json`
- With `--site-dir`: `<site-dir>/YYYY-MM-DD-<slug>.json`
