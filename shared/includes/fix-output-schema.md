# Fix Output Schema (v1.1)

> Standard JSON output format for zuvo fix skills (seo-fix, future code-fix, etc.).
> Produced alongside markdown reports in `audit-results/`.
> Consumers: CI pipelines, backlog tools, reporting dashboards.

## File Naming

`audit-results/[skill-name]-YYYY-MM-DD.json`

Auto-increment with `-2`, `-3` suffix if same-day file exists.

## Required Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | string | Schema version, e.g., `"1.1"` |
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
| `build_result` | string | `"PASS"`, `"FAIL"`, or `"NOT_VERIFIED"` — `"PASS"` requires the detected build command to exit `0` |

## Actions Array

Each entry in `actions[]`:

| Field | Type | Description |
|-------|------|-------------|
| `finding_id` | string | Stable ID from audit (e.g., `"D4-sitemap-exists"`) |
| `fix_type` | string | From shared seo-fix-registry.md |
| `status` | string | `"FIXED"`, `"NEEDS_REVIEW"`, `"MANUAL"`, `"OUT_OF_SCOPE"`, `"NO_TEMPLATE"`, `"INSUFFICIENT_DATA"`, or `"NEEDS_PARAMS"` |
| `file` | string or null | File modified (null if no change) |
| `verification` | string or null | `"VERIFIED"` (re-check passed; when a build exists this also requires `exit code 0` plus any required artifact/endpoint checks), `"ESTIMATED"` (no deterministic runtime/artifact check), `"FAILED"` (re-check failed, rolled back, or built endpoint/artifact still missing/404), or `null` when no verification ran because the action remained manual/review-only |
| `eta_minutes` | number or null | Estimated effort or review time for this action |
| `manual_checks` | array or null | Human follow-up checks still required |
| `estimated_time` | string or null | Human-readable time band such as `"<30 minutes"` or `"1-4 hours"` |
| `policy_notes` | array or null | Policy-specific guidance, e.g. crawler strategy or edge-platform caveats |
| `advisory_scaffolds` | array or null | Non-mutating follow-up structures such as content outlines or suggested sections |
| `risk_notes` | array or null | Important caveats associated with this action |
| `network_override_risk` | boolean or null | Whether edge/network controls may invalidate the file-level fix |

## Optional Top-Level Fields

| Field | Type | Description |
|-------|------|-------------|
| `manual_checks` | array | Aggregated follow-up checks across actions |
| `estimated_time` | object | Roll-up of estimated effort, e.g. `{ "easy": 2, "medium": 1, "hard": 0 }` |
| `policy_notes` | array | High-level policy considerations that affected fix decisions |
| `advisory_scaffolds` | array | Suggested human follow-ups for out-of-scope items |

## Example

```json
{
  "version": "1.1",
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
      "verification": "VERIFIED",
      "eta_minutes": 20,
      "estimated_time": "<30 minutes",
      "manual_checks": null,
      "policy_notes": [
        "Keep the sitemap host aligned with the canonical root"
      ],
      "advisory_scaffolds": null,
      "risk_notes": [],
      "network_override_risk": false
    },
    {
      "finding_id": "D1-canonical-present",
      "fix_type": "canonical-fix",
      "status": "MANUAL",
      "file": null,
      "verification": null,
      "eta_minutes": 45,
      "estimated_time": "1-4 hours",
      "manual_checks": [
        "Review canonical host and path strategy",
        "Verify no pages point at a different canonical root"
      ],
      "policy_notes": [
        "Canonical normalization should follow the primary production host policy"
      ],
      "advisory_scaffolds": [
        "Document preferred host and path rules before editing templates"
      ],
      "risk_notes": [
        "Wrong canonical targets can suppress indexed pages"
      ],
      "network_override_risk": null
    }
  ],
  "manual_checks": [
    "Confirm Cloudflare or CDN rules do not override file-level crawler policy"
  ],
  "estimated_time": {
    "easy": 1,
    "medium": 1,
    "hard": 0
  },
  "policy_notes": [
    "Training bots may remain blocked while user-proxy fetchers stay allowed"
  ],
  "advisory_scaffolds": [
    "For thin content findings, generate a human review outline instead of auto-writing copy"
  ],
  "files_modified": ["astro.config.mjs", "src/layouts/Layout.astro", "public/llms.txt"],
  "build_result": "PASS"
}
```

## Versioning

- Adding optional fields = minor bump (1.1) — backward compatible
- Changing required fields = major bump (2.0) — old files ignored by consumers
