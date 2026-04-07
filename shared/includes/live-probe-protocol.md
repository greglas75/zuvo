# Live Probe Protocol

> Shared safety rules for skills that probe live URLs (`--live-url`).
> Referenced by `seo-audit` and `content-audit`.

## Consent Gate

| Scenario | Static Analysis (code) | Live Probes (--live-url) |
|----------|----------------------|------------------------|
| No --live-url | Proceed (code read only) | N/A |
| --live-url localhost | Proceed | Proceed freely (GET/HEAD only) |
| --live-url staging | Proceed | Confirm with user, then proceed |
| --live-url production | Proceed | Confirm with user, then proceed. Default to code-only if confirmation is unavailable. |

## Rate Limiting

| Target | Max rate | Notes |
|--------|----------|-------|
| Internal URLs (same domain) | 2 req/s | Pages, images, internal links |
| External URLs (third-party) | 1 req/s | Outbound links, external resources |

## Error Threshold Escalation

| Condition | Action |
|-----------|--------|
| 3 consecutive 429 responses | Pause for 30 seconds, then resume |
| 3 consecutive 5xx responses | Halt live probing entirely. Continue with code-only analysis. |
| Connection timeout (>10s) | Skip URL, log as `INSUFFICIENT DATA` |
| DNS resolution failure | Skip URL, log as `INSUFFICIENT DATA` |

## HTTP Method Restriction

**Read-only:** GET and HEAD only. No POST/PUT/DELETE. Never submit forms, trigger
mutations, or modify server state.

## Best Practices

- Prefer HEAD for existence checks (lighter than GET)
- Follow redirects up to 5 hops (record chain length)
- Respect `Retry-After` headers when present
- Set a descriptive User-Agent: `zuvo-audit/1.0 (content quality check)`
- Do not probe URLs behind authentication (skip with `INSUFFICIENT DATA`)
