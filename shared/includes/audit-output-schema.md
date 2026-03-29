# Audit Output Schema (v1.0)

Standard JSON output format for zuvo audit skills, produced alongside markdown reports. Every audit skill that generates a `.md` report also writes a structured `.json` file for programmatic consumption (CI gates, fix pipelines, dashboards).

## File Naming

```
audit-results/[skill-name]-YYYY-MM-DD.json
```

Auto-incremented with `-N` suffix if a same-day file exists (e.g., `seo-audit-2026-03-28-2.json`), matching the `.md` convention.

## Required Fields

Every audit skill MUST emit these fields:

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version (e.g., `"1.0"`) |
| `skill` | string | Skill name (e.g., `"seo-audit"`, `"code-audit"`) |
| `timestamp` | string | ISO 8601 UTC timestamp |
| `project` | string | Absolute path to project root |
| `args` | string | Arguments passed to the skill |
| `stack` | string | Detected tech stack |
| `result` | string | `"PASS"`, `"FAIL"`, or `"PROVISIONAL"` |
| `score.overall` | number | Numeric score (0-100) |
| `score.tier` | string | Letter tier (`"A"`, `"B"`, `"C"`, `"D"`) |
| `critical_gates` | array | `[{ id, name, status, evidence }]` |
| `findings` | array | `[{ id, dimension, check, status, severity, priority, evidence, file, line }]` -- `id` is stable format `{dimension}-{check}` (e.g., `D4-sitemap-exists`). `status` is `"PASS"`, `"PARTIAL"`, `"FAIL"`, or `"INSUFFICIENT DATA"` |

## Optional Fields

Fix-capable audits MAY include these additional fields:

| Field | Type | Description |
|-------|------|-------------|
| `score.sub_scores` | object | Dimension-level scores (e.g., `{ "seo": 61, "geo": 38 }`) |
| `findings[].fix_type` | string | Maps to fix template registry |
| `findings[].fix_safety` | string | `"SAFE"` / `"MODERATE"` / `"DANGEROUS"` |
| `findings[].fix_params` | object | Framework-specific parameters for the template |
| `summary` | object | Aggregated counts: `findings_count`, `quick_wins`, `fixable` |

**Nullability:** `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` may be `null` for findings without an auto-fix template. Consumers MUST check for null.

## JSON Example

```json
{
  "version": "1.0",
  "skill": "seo-audit",
  "timestamp": "2026-03-28T14:30:00Z",
  "project": "/Users/greglas/DEV/zuvo-plugin",
  "args": "full",
  "stack": "astro",
  "result": "FAIL",
  "score": {
    "overall": 53,
    "tier": "C",
    "sub_scores": {
      "seo": 61,
      "geo": 38,
      "tech": 65
    }
  },
  "critical_gates": [
    { "id": "CG1", "name": "Sitemap exists", "status": "FAIL", "evidence": "No sitemap.xml found" },
    { "id": "CG2", "name": "Googlebot not blocked", "status": "PASS", "evidence": "robots.txt:1" }
  ],
  "findings": [
    {
      "id": "D4-sitemap-exists",
      "display_id": "F1",
      "dimension": "D4",
      "check": "sitemap-exists",
      "status": "FAIL",
      "severity": "HIGH",
      "seo_impact": 3,
      "business_impact": 3,
      "effort": 1,
      "priority": 2.8,
      "evidence": "No sitemap.xml or sitemap generation config found",
      "file": null,
      "line": null,
      "fix_type": "sitemap-add",
      "fix_safety": "MODERATE",
      "fix_params": {
        "framework": "astro",
        "site_url": "https://zuvo.dev"
      }
    }
  ],
  "summary": {
    "findings_count": { "total": 13, "critical": 3, "high": 4, "medium": 4, "low": 2 },
    "quick_wins": 6,
    "fixable": { "safe": 5, "moderate": 4, "dangerous": 2, "no_template": 2 }
  }
}
```

## Versioning Rules

- **Minor bump** (e.g., `1.0` to `1.1`): Adding optional fields. Consumers MUST tolerate unknown keys.
- **Major bump** (e.g., `1.0` to `2.0`): Adding, removing, or changing required fields. Consumers MAY need updates.
