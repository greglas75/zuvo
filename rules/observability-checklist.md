# Observability Quality Gates (OBS1-OBS8)

Run when auditing production-readiness. Companion to `cq-checklist.md` (code quality) and `testing.md` (test quality).

---

## 8 Observability Gates

| # | Domain | Gate |
|---|--------|------|
| OBS1 | Logging | **Structured logging** — logs include context (requestId, userId, traceId), not plain string interpolation. Logger uses JSON or structured format, not `console.log`. |
| OBS2 | Error Tracking | **Error reporting** — errors sent to tracking system (Sentry, Datadog, Bugsnag) with context. Not just `console.error`. Unhandled rejections and uncaught exceptions captured globally. |
| OBS3 | Health | **Health endpoints** — `/health` and `/ready` exist. Health checks dependencies (DB ping, cache ping, external service reachability). Returns structured JSON with component status. |
| OBS4 | Metrics | **Metrics exposure** — key operations have metrics: request latency histogram, request count by endpoint, error rate, active connections. Prometheus/StatsD/custom format. |
| OBS5 | Tracing | **Trace propagation** — trace ID generated at entry point and propagated to downstream calls. `X-Request-Id` or OpenTelemetry `traceparent` header. Trace ID included in log entries. |
| OBS6 | Alerting | **Alert conditions defined** — error rate, latency p95, and availability thresholds documented. Alert rules exist (PagerDuty, OpsGenie, CloudWatch Alarms, or equivalent). |
| OBS7 | Log Levels | **Correct log levels** — DEBUG for development detail, INFO for business events, WARN for recoverable issues, ERROR for failures requiring attention. Not ERROR for validation failures. Not INFO for stack traces. |
| OBS8 | Log Safety | **No sensitive data in logs** — extends CQ5 to ALL log outputs. No PII (email, phone, IP), no credentials (tokens, API keys), no payment data. Audit every `logger.*` call. Safe: internal UUIDs, enum status, timestamps, error codes. |

---

## Scoring

Each gate: **1** (pass with evidence), **0** (fail or unproven), **N/A** (precondition not active).

**Always-on critical gates:** OBS1, OBS2, OBS8 — any scored 0 in production code is a finding.

**Conditional gates:**
- OBS3, OBS4, OBS5, OBS6 — critical for deployed services, N/A for libraries or CLI tools
- OBS7 — critical when project has >10 logger calls

**Thresholds:**
- **PASS:** 6+ out of 8 AND all active critical gates = 1
- **WARN:** 4-5 AND all active critical gates = 1
- **FAIL:** any active critical gate = 0, OR total below 4

---

## Evidence Standards

```
OBS1=1
  Scope: 12 logger calls across 4 service files
  Evidence: order.service.ts:45 — logger.info({ requestId, userId, action: 'createOrder' })
  Exceptions: none

OBS3=1
  Scope: health endpoint at /api/health
  Evidence: health.controller.ts:12 — checks DB (prisma.$queryRaw), Redis (redis.ping()),
            returns { status: 'ok', db: 'up', cache: 'up', uptime: process.uptime() }
  Exceptions: none

OBS8=1
  Scope: 12 logger calls audited
  Evidence: all use { userId: uuid, action: string } pattern — no PII fields
  Exceptions: none (email used in auth but not logged)
```

---

## When to Use

- `zuvo:code-audit` — include OBS gates for production services
- `zuvo:deploy` — verify OBS3 (health) before deployment
- `zuvo:canary` — verify OBS2 (error tracking) captures post-deploy issues
- `zuvo:performance-audit` — check OBS4 (metrics) for performance monitoring
