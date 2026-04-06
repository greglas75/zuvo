# Audit Output Schema (v1.1)

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
| `version` | string | Schema version (e.g., `"1.1"`) |
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
| `site_profile` | string | Resolved or user-specified page/site profile (`marketing`, `docs`, `blog`, `ecommerce`, `app-shell`) |
| `score.sub_scores` | object | Dimension-level scores (e.g., `{ "seo": 61, "geo": 38 }`) |
| `strengths` | array | Positive findings worth preserving, e.g. `[{ id, title, evidence }]` |
| `findings[].enforcement` | string | `blocking`, `scored`, or `advisory` |
| `findings[].layer` | string | `core`, `hygiene`, `geo`, or `visibility-deferred` |
| `findings[].confidence_reason` | string | Short explanation for confidence level or degraded evidence |
| `findings[].eta_minutes` | number | Estimated remediation time in minutes |
| `findings[].bot_scope` | array | Relevant `bot_key` values from `seo-bot-registry.md` |
| `findings[].fix_type` | string | Maps to fix template registry |
| `findings[].fix_safety` | string | `"SAFE"` / `"MODERATE"` / `"DANGEROUS"` |
| `findings[].fix_params` | object | Framework-specific parameters for the template |
| `bot_matrix` | array | `[{ bot_key, status, evidence, verification_mode }]` |
| `render_diff` | array | `[{ field, source_value, rendered_value, drift_status, evidence }]` for key SEO fields |
| `coverage.fixable_ratio` | number | Ratio of findings with a non-null `fix_type` divided by total actionable findings |
| `manual_checks` | array | Follow-up checks required because live probing, edge config, or CMS content could not be fully verified |
| `summary` | object | Aggregated counts: `findings_count`, `quick_wins`, `fixable` |

**Nullability:** `findings[].fix_type`, `findings[].fix_safety`, and `findings[].fix_params` may be `null` for findings without an auto-fix template. Consumers MUST check for null.

## JSON Example

```json
{
  "version": "1.1",
  "skill": "seo-audit",
  "timestamp": "2026-03-28T14:30:00Z",
  "project": "/Users/greglas/DEV/zuvo-plugin",
  "args": "full",
  "stack": "astro",
  "site_profile": "marketing",
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
  "strengths": [
    {
      "id": "S1",
      "title": "Canonical tags are template-level and consistent",
      "evidence": "src/layouts/Layout.astro:14"
    }
  ],
  "findings": [
    {
      "id": "D4-sitemap-exists",
      "display_id": "F1",
      "dimension": "D4",
      "check": "sitemap-exists",
      "status": "FAIL",
      "enforcement": "blocking",
      "layer": "core",
      "severity": "HIGH",
      "confidence_reason": "No sitemap file or generation config found in repo",
      "eta_minutes": 20,
      "seo_impact": 3,
      "business_impact": 3,
      "effort": 1,
      "priority": 2.8,
      "evidence": "No sitemap.xml or sitemap generation config found",
      "file": null,
      "line": null,
      "bot_scope": [],
      "fix_type": "sitemap-add",
      "fix_safety": "MODERATE",
      "fix_params": {
        "framework": "astro",
        "site_url": "https://zuvo.dev"
      }
    }
  ],
  "bot_matrix": [
    {
      "bot_key": "gptbot",
      "status": "BLOCKED",
      "evidence": "public/robots.txt:12",
      "verification_mode": "code"
    }
  ],
  "render_diff": [
    {
      "field": "canonical",
      "source_value": "https://zuvo.dev/en/skills/seo-audit",
      "rendered_value": "https://zuvo.dev/en/skills/seo-audit",
      "drift_status": "MATCH",
      "evidence": "code + rendered DOM"
    }
  ],
  "coverage": {
    "fixable_ratio": 0.85
  },
  "manual_checks": [
    "Verify Cloudflare AI crawler settings at the edge dashboard"
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
