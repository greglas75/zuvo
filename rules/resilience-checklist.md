# Resilience Quality Gates (RES1-RES6)

Run when auditing production-readiness for services with external dependencies. Extends CQ8 (error handling) with resilience patterns.

---

## 6 Resilience Gates

| # | Domain | Gate |
|---|--------|------|
| RES1 | Circuit Breaker | **Circuit breaker on external calls** — calls to external services (payment, email, third-party APIs) use circuit breaker pattern (open/half-open/closed). After N consecutive failures, circuit opens and fails fast instead of hanging. Implementation: library (opossum, cockatiel, resilience4j) or manual state machine. |
| RES2 | Retry | **Retry with exponential backoff** — retries on transient failures use exponential backoff with jitter. No naive retry loops (`for i in range(3): try...`). Max retry count bounded (typically 3-5). Non-retryable errors (4xx, validation) must NOT retry. |
| RES3 | Degradation | **Graceful degradation** — service continues operating when a dependency is unavailable. Cache miss → fallback to DB. Payment gateway down → queue for later. Email service down → log and continue. Feature flags can disable non-critical features. |
| RES4 | Timeouts | **Timeout hierarchy** — client timeout < server timeout < DB timeout. No unbounded waits. Every outbound call has explicit timeout. HTTP clients: `AbortSignal.timeout()` or equivalent. DB: query timeout configured. Queue consumers: processing timeout. |
| RES5 | Bulkhead | **Bulkhead isolation** — failure in one module/circuit doesn't cascade. Connection pools are per-service (not shared). Thread/worker pools are bounded. One slow endpoint doesn't block others. Rate limiting per-client or per-feature. |
| RES6 | Idempotency | **Idempotency for mutations** — mutating operations (POST, PUT, payment, email) are safe to retry. Idempotency key in request header or body. Deduplication on server side (check-before-create, upsert, CAS). At-least-once delivery handled safely. |

---

## Scoring

Each gate: **1** (pass with evidence), **0** (fail or unproven), **N/A** (precondition not active).

**Critical gates:**
- RES1 — critical when code calls external HTTP/gRPC services
- RES4 — critical for any service with outbound calls
- RES6 — critical for payment, email, webhook, or state-changing operations

**Conditional gates:**
- RES2 — critical when automatic retries are implemented (bad retry = worse than no retry)
- RES3 — critical for services with >2 external dependencies
- RES5 — critical for monoliths or services handling >1000 rps

**Thresholds:**
- **PASS:** 4+ out of 6 AND all active critical gates = 1
- **WARN:** 3 AND all active critical gates = 1
- **FAIL:** any active critical gate = 0, OR total below 3

---

## Evidence Standards

```
RES1=1
  Scope: 3 external service calls (Stripe, SendGrid, S3)
  Evidence: payment.service.ts:23 — CircuitBreaker({ threshold: 5, timeout: 30000 })
            email.service.ts:15 — CircuitBreaker({ threshold: 3, timeout: 10000 })
            storage.service.ts:8 — CircuitBreaker({ threshold: 5, timeout: 15000 })
  Exceptions: none

RES4=1
  Scope: all outbound calls
  Evidence: Client timeout: 5s (axios defaults)
            Server timeout: 30s (Fastify server.timeout)
            DB timeout: 10s (Prisma queryTimeout)
            Hierarchy: 5s < 10s < 30s ✓
  Exceptions: file upload endpoint uses 120s client timeout (documented)

RES6=1
  Scope: 4 mutation endpoints
  Evidence: POST /orders — idempotencyKey from X-Idempotency-Key header
            payment.service.ts:89 — upsert on paymentId (dedup)
  Exceptions: PUT /users/profile — idempotent by nature (full replace)
```

---

## When to Use

- `zuvo:security-audit` — RES1, RES4, RES5 overlap with availability concerns
- `zuvo:performance-audit` — RES4 (timeouts), RES5 (bulkhead) affect performance
- `zuvo:deploy` — verify RES1, RES3, RES4 before production deployment
- `zuvo:threat-model` — RES gates map to STRIDE "Denial of Service" category
