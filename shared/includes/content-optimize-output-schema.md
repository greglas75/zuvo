# Content-Optimize Output Schema — JSON Contract

> Version 1.0. Consumed by `content-optimize` Phase 5 for structured output.

## Schema

```json
{
  "version": "1.0",
  "skill": "content-optimize",
  "timestamp": "ISO-8601 UTC with Z suffix",
  "project": "git root basename",
  "args": {
    "file": "string (required) — input file path",
    "apply": "boolean (default: false)",
    "lang": "string|null (auto-detected if omitted)",
    "tone": "string|null",
    "force_rewrite": "boolean (default: false)",
    "competitors": ["string — manual competitor URLs"] ,
    "skip_benchmark": "boolean (default: false)"
  },
  "input_file": "string — absolute path to analyzed file",
  "language": "string — detected or specified language code",
  "mode": "report|applied — whether --apply was active",
  "scores": {
    "before": {
      "readability": "number 0-100",
      "engagement": "number 0-100",
      "seo": "number 0-100",
      "structure": "number 0-100",
      "authority": "number 0-100",
      "anti_slop": "number 0-100",
      "composite": "number 0-100",
      "tier": "A|B|C|D"
    },
    "after": {
      "readability": "number 0-100 (null if mode=report)",
      "engagement": "number 0-100 (null if mode=report)",
      "seo": "number 0-100 (null if mode=report)",
      "structure": "number 0-100 (null if mode=report)",
      "authority": "number 0-100 (null if mode=report)",
      "anti_slop": "number 0-100 (null if mode=report)",
      "composite": "number 0-100 (null if mode=report)",
      "tier": "A|B|C|D|null"
    }
  },
  "voice_delta": "LOW|MED|HIGH|null — null if mode=report",
  "benchmark": {
    "performed": "boolean",
    "competitors_analyzed": "number",
    "gaps_identified": ["string — each content gap found"],
    "gaps_addressed": ["string — gaps addressed in optimization (empty if report-only)"]
  },
  "changes": [
    {
      "section": "string — heading or section identifier",
      "type": "rewrite|addition|meta_update|heading_fix|link_add",
      "description": "string — what was changed and why",
      "dimension_impact": "readability|engagement|seo|structure|authority|anti_slop",
      "score_delta": "number — positive = improvement",
      "rolled_back": "boolean — true if change was reverted due to regression",
      "rollback_reason": "string|null — why the change was rolled back"
    }
  ],
  "protected_regions": {
    "code_blocks": "number — fenced code blocks preserved",
    "mdx_components": "number — JSX/component tags preserved",
    "frontmatter_fields_preserved": "number — non-optimizable YAML fields kept"
  },
  "findings": [
    {
      "id": "string — e.g. PQ1-fk-grade-high",
      "dimension": "readability|engagement|seo|structure|authority|anti_slop|freshness",
      "check": "PQ1-PQ18",
      "severity": "CRITICAL|HIGH|MEDIUM|LOW",
      "message": "string — human-readable finding",
      "line": "number|null — line in source file",
      "fixable": "boolean — can this be auto-fixed?",
      "fix_applied": "boolean — was it fixed in this run?"
    }
  ]
}
```

## Required Fields

All top-level fields required. Within nested objects:
- `scores.before.*`: all required
- `scores.after.*`: all null when `mode=report`
- `changes[]`: empty array when `mode=report`
- `findings[]`: always populated (the diagnostic report)
- `benchmark.*`: `performed=false` and zeros when skipped

## Output Path

- Report (always): `audit-results/content-optimize-YYYY-MM-DD.md` and `.json`
- Applied changes: modifications to the input file itself
