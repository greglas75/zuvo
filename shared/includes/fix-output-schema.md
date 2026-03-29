# Fix Output Schema (v1.0)

> Standard JSON output format for zuvo fix skills (seo-fix, future code-fix, etc.).
> Produced alongside markdown reports in `audit-results/`.
> Consumers: CI pipelines, backlog tools, reporting dashboards.

## File Naming

`audit-results/[skill-name]-YYYY-MM-DD.json`

Auto-increment with `-2`, `-3` suffix if same-day file exists.

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version, e.g., `"1.0"` |
| `skill` | string | Fix skill name (e.g., `"seo-fix"`) |
| `timestamp` | string | ISO 8601 UTC timestamp |
| `project` | string | Absolute path to project root |
| `args` | string | Arguments passed to the skill |
| `source_audit` | string | Path to the audit JSON that was consumed |
| `result` | string | `"COMPLETE"` (all fixable fixed), `"PARTIAL"` (some fixed), `"DRY_RUN"` (no changes) |
| `score.before` | number | Overall score from source audit |
| `score.estimated_after` | number | Recalculated from confirmed fixes only |
| `score.method` | string | Always `"confirmed-fixes-only"` |
| `summary` | object | Counts: `total`, `fixed`, `needs_review`, `manual`, `out_of_scope`, `no_template`, `insufficient_data` |
| `actions` | array | `[{ finding_id, fix_type, status, file, verification }]` |
| `files_modified` | array | List of file paths changed |
| `build_result` | string | `"PASS"`, `"FAIL"`, or `"NOT_VERIFIED"` |

## Actions Array

Each entry in `actions[]`:

| Field | Type | Description |
|-------|------|-------------|
| `finding_id` | string | Stable ID from audit (e.g., `"D4-sitemap-exists"`) |
| `fix_type` | string | From shared seo-fix-registry.md |
| `status` | string | `"FIXED"`, `"NEEDS_REVIEW"`, `"MANUAL"`, `"OUT_OF_SCOPE"`, `"NO_TEMPLATE"`, `"INSUFFICIENT_DATA"` |
| `file` | string or null | File modified (null if no change) |
| `verification` | string | `"VERIFIED"` (re-check passed), `"ESTIMATED"` (no runtime check), `"FAILED"` (re-check failed, rolled back) |

## Example

```json
{
  "version": "1.0",
  "skill": "seo-fix",
  "timestamp": "2026-03-29T10:30:00Z",
  "project": "/Users/dev/my-site",
  "args": "--auto",
  "source_audit": "audit-results/seo-audit-2026-03-29.json",
  "result": "PARTIAL",
  "score": {
    "before": 53,
    "estimated_after": 74,
    "method": "confirmed-fixes-only"
  },
  "summary": {
    "total": 13,
    "fixed": 7,
    "needs_review": 2,
    "manual": 1,
    "out_of_scope": 1,
    "no_template": 1,
    "insufficient_data": 1
  },
  "actions": [
    {
      "finding_id": "D4-sitemap-exists",
      "fix_type": "sitemap-add",
      "status": "FIXED",
      "file": "astro.config.mjs",
      "verification": "VERIFIED"
    },
    {
      "finding_id": "D1-canonical-present",
      "fix_type": "canonical-fix",
      "status": "MANUAL",
      "file": null,
      "verification": null
    }
  ],
  "files_modified": ["astro.config.mjs", "src/layouts/Layout.astro", "public/llms.txt"],
  "build_result": "PASS"
}
```

## Versioning

- Adding optional fields = minor bump (1.1) — backward compatible
- Changing required fields = major bump (2.0) — old files ignored by consumers
