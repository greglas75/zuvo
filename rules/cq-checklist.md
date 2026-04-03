# Code Quality Self-Evaluation

Run after writing production code, before writing tests. Companion patterns are in `cq-patterns.md`.

---

## 28 Evaluation Gates

Each gate is scored 1 (pass with evidence), 0 (fail or unproven), or N/A (precondition inactive, justify in one sentence).

| # | Domain | Gate |
|---|--------|------|
| CQ1 | Types | Unions, enums, or branded types used where plain `string`/`number` is too loose? No `==`/`!=` loose equality? |
| CQ2 | Types | Explicit return types on all public functions? No implicit `any` anywhere? No `as unknown as X` casts? No `!` non-null assertions without justification? |
| CQ3 | Validation | **CRITICAL** — Input validated at every boundary? (a) required fields enforced, (b) format/range/allowlist applied, (c) runtime schema at entry point? |
| CQ4 | Security | **CRITICAL** — Auth guards paired with query-level tenant scoping? Guard alone is insufficient — `organizationId` must appear in service WHERE clauses. If any public method requires orgId, all must (or document exemptions). |
| CQ5 | Security | **CRITICAL** — Zero sensitive data in logs (ALL log outputs including structured logger), errors, response bodies (including stack traces gated by NODE_ENV), headers, or query params? No raw `dangerouslySetInnerHTML`? (Header like `x-modified-by: user@email.com` = violation; `stack: err.stack` in non-dev response = violation; `logger.info('User login', { email })` = violation.) |
| CQ6 | Resources | **CRITICAL** — No unbounded memory growth from external data? Pagination, streaming, or batching used? |
| CQ7 | Resources | All database queries bounded (LIMIT / cursor)? List responses return slim payloads (`select` fields)? |
| CQ8 | Errors | **CRITICAL** — Infrastructure failures handled? No empty `catch {}`. Timeouts on outbound calls. `response.ok` checked before `.json()`. `return await` inside try/catch. No infra details leaked. Frontend: `AbortSignal.timeout()` on every fetch. Node.js `execFile`/`exec` with callback: use `promisify(execFile)` or wrap in try/catch (sync throw before spawn = callback never fires = hang). |
| CQ9 | Data | Multi-table mutations wrapped in transactions? FK order respected during delete/create sequences? |
| CQ10 | Data | Nullable values guarded before access? No unsafe `.find()` without null check? No unvalidated `as Type` / `!` non-null assertion? |
| CQ11 | Structure | **File** within its type limit (service 300-450L, component 200-300L, hook 250L, util 100L)? **Functions** within limits (public 50L, private 30L, handler 25L, $tx 60L, useEffect 20L)? No deeper than 4 nesting levels? 5 params max? **Hard gate: file exceeding 2x the type limit = automatic CQ11 FAIL.** |
| CQ12 | Structure | No magic strings or numbers? No index-based mapping (`row[0]`)? Named constants in use? |
| CQ13 | Hygiene | No dead code (unreachable branches, unused exports)? No TODO without a ticket reference? No stale feature flags (>30 days since full rollout = stale)? No mixed `console.*` and structured logger in same file? **Note: commented-out old implementations and debug leftovers are dead code. Explanatory comments, API examples, and documented workarounds are NOT.** |
| CQ14 | Hygiene | **CRITICAL** — No duplicated logic? (a) block exceeding 10 lines repeated, OR (b) same structural pattern appearing 5+ times? |
| CQ15 | Async | Every async call awaited or explicitly fire-and-forget with `.catch()`? `return await` used inside try/catch? No `await` inside `Promise.all()` argument list? |
| CQ16 | Data | Monetary values use exact arithmetic (integer-cents, Decimal.js)? No `toFixed()` during computation? **Scope: actual currency amounts only.** Indices, ratios, scores = N/A. |
| CQ17 | Performance | No sequential `await` in loops where batch or `Promise.all` suffices? No N+1 queries? No `.find()` inside a loop? |
| CQ18 | Data | Cross-system consistency maintained? Multi-store operations handle partial failures? |
| CQ19 | Contract | API request AND response shapes validated by runtime schema? No hope-based typing? |
| CQ20 | Contract | Single canonical source per data point? No dual fields stored independently for the same concept? |
| CQ21 | Concurrency | No time-of-check-to-time-of-use races? Mutations idempotent or CAS-protected? Mutating API endpoints safe to retry (idempotency key or CAS guard)? No shared mutable state? |
| CQ22 | Resources | All listeners, timers, and observers cleaned up on unmount/destroy? No stale closures in callbacks? |
| CQ23 | Resources | Cache entries have TTL or explicit invalidation? No stale-forever entries? Redis `SET` without `EX`/`PX` = violation. In-memory cache without eviction policy = violation. |
| CQ24 | Contract | API changes are additive only (new optional fields, new endpoints)? Removing or renaming fields has a deprecation path with migration guide? Breaking changes without versioning or deprecation = violation. |
| CQ25 | Structure | New endpoint/component/service follows existing project patterns? Same naming convention, same file structure, same error handling approach as existing code? "Special snowflake" = violation. |
| CQ26 | Observability | Log statements use structured logger with context (requestId, userId, traceId), not plain `console.log` strings? Every service/controller uses the project's standard logger. |
| CQ27 | Observability | Log levels used correctly? `logger.error` reserved for unrecoverable failures and infrastructure errors, not validation failures or expected business conditions. `logger.warn` for recoverable but unexpected situations. Validation failure logged as `error` = violation. Stack trace logged as `info` = violation. |
| CQ28 | Resilience | Client timeout < server timeout < DB timeout (not inverted)? If code defines timeouts at multiple layers, verify the hierarchy is correct. Inverted timeout hierarchy = violation. |

---

## Scoring

**Always-on critical gates:** CQ3, CQ4, CQ5, CQ6, CQ8, CQ14 — any scored 0 triggers an immediate FAIL.

**Conditional critical gates** (active only when the code context applies):
- **CQ16** — critical when code manipulates prices, costs, discounts, invoices, payouts
- **CQ19** — critical when code crosses an API or module boundary. Exception: thin controllers that only return typed service data — CQ19=0 is a normal deduction (caps at B), not a critical failure.
- **CQ20** — critical when payload contains `*_id` + `*_name` pairs or number + string-with-currency for the same field
- **CQ21** — critical when concurrent mutations target the same resource. Not critical for read-only paths.
- **CQ22** — critical when code creates subscriptions, timers, or observers. Not critical for stateless handlers.
- **CQ23** — critical when code uses Redis, Memcached, or in-memory caching. Not critical for code without caching.
- **CQ24** — critical when code modifies existing API endpoint signatures (request/response shapes, route paths). Not critical for new endpoints.
- **CQ28** — critical when code defines timeouts at 2+ architectural layers (client, server, DB).

**Always-on non-critical gates (new):** CQ25, CQ26, CQ27 — scored normally. Failure is a deduction, not an auto-FAIL.

When a conditional gate is active and scored 0: FAIL.

**Thresholds:**
- **PASS:** 24+ out of 28 AND every active critical gate = 1
- **CONDITIONAL PASS:** 22-23 AND every active critical gate = 1
- **FAIL:** any active critical gate = 0, OR total below 22

---

## Evidence Standards

### Allowed Score Values

| Score | Meaning | Use when |
|-------|---------|----------|
| **1** | Proven compliant | You can cite file:function:line proving it |
| **0** | Failed or unproven | Code violates the gate, OR evidence is insufficient |
| **N/A** | Precondition does not apply | Justify with one sentence |

Note the distinction: `CQ4=0 (violation)` means a WHERE clause is missing orgId. `CQ4=0 (unproven)` means the model is complex and you cannot confirm all paths. Both score 0 for gating, but the fix action differs.

### Citing Evidence

```
PREFERRED:  file:function:line    → order.service.ts:updateStatus:112
ACCEPTABLE: file:line-range       → order.service.ts:108-125
```

For every CQ scored 1, provide:
```
CQ[N]=1
  Scope: [what was audited — e.g., "7 Prisma queries in order.service.ts"]
  Evidence: [file]:[function]:[line] — [what satisfies the gate]
  Exceptions: [deliberate exclusions with rationale, or "none"]
```

A claim without file:line evidence must be scored 0.

### Classifying Sensitive Data (CQ5)

- **Direct PII** (never in logs/errors/responses): email, phone, IP, name, address, DOB, government ID, payment card, password/token
- **Sensitive identifiers** (mask when possible): tenant slug, session token, API key, webhook secret, payment provider ID
- **Safe operational data** (acceptable in private backend logs): internal UUID (orgId, orderId), enum status, counts, timestamps, error codes

What is safe in backend logs may still be unsafe in HTTP responses, client-visible logs, or support exports. Audit each output channel: throws (appear in HTTP responses), logger calls (backend logs), return values (client payloads).

### Negative Evidence

Scoring 0 based on absence is valid when: (1) the project's logging API is identified first, (2) an exhaustive search is documented (`rg "try|catch|logger" file.ts → 0 matches`), (3) the correct baseline is used (if the project uses `this.logger.*`, absence of `console.log` is irrelevant).

### What Strong Evidence Looks Like

- **CQ3=1:** "schema: CreateOfferDto (dto:12), z.string().uuid() on id, z.enum() on status, ValidationPipe global"
- **CQ4=1:** "guard: tenantProcedure (trpc.init.ts:34) + WHERE { organizationId } on ALL 7 queries (listed)"
- **CQ5=1:** "enumerated: 4 throws (no PII), 3 logger calls (orgId=UUID safe), no dangerouslySetInnerHTML"
- **CQ6=1:** "all 5 findMany bounded: findAll take=200, export AsyncGenerator BATCH=1000, bulk cap=1000"
- **CQ8=1:** "try/catch on redis (fallback to DB), timeout 10s on payment, .catch on email, response.ok checked"
- **CQ14=1:** "compared all method pairs >20L (create vs batch: different), counted patterns <5 occurrences"
- **CQ9=1:** "IN tx: order.create + orderItem.createMany + audit. OUTSIDE: email .catch()"
- **CQ21=1:** "CAS: updateMany WHERE { id, status: current }, count===0 → ConflictException"

Vague claims like "no duplication" or "errors handled" score 0.

### Evidence Format Principles

1. **File:function:line** — every claim points to specific code
2. **What, not whether** — show `where: { id, organizationId }`, not "query is scoped"
3. **All paths, not one** — 7 queries means confirm all 7
4. **Inside AND outside** — for transactions, enumerate both
5. **Count your claims** — CQ4=1 with 7 queries means list each one
6. **Vague = 0** — no file:line means score is 0
7. **State audit method** — `rg "prisma\." file.ts → 7 matches`

### Before Submitting CQ=1

Can I point to file:function:line? Did I check ALL instances, not just one? Am I scoring what I actually wrote, or what I intended to write? If N/A count exceeds 14: is each justified?

---

## N/A Guidelines

N/A scores count as 1 in the total but require justification. Excessive N/A usage inflates scores.

| CQ | N/A is valid when | N/A is NOT valid |
|----|-------------------|------------------|
| CQ3 | Pure internal helper with no external input | "It's simple" — if it accepts user input, it applies |
| CQ4 | Pure utility with zero auth. Internal services consumed only by authenticated callers IF: (a) JSDoc documents "Internal — caller must verify session ownership", (b) target entity lacks organizationId column (check schema). Without documentation → CQ4=0. | "Internal service" — if it touches user-scoped data, it applies |
| CQ5 | Pure computation, zero I/O, zero logging | "We don't log PII" — if it has logger/throws, it applies |
| CQ6/7 | No collections processed | "Small dataset" — external data size is never guaranteed |
| CQ8 | Pure synchronous code, zero I/O | "Errors are rare" — any external call means it applies |
| CQ9 | Read-only or single-table mutations | "Don't use transactions" — multi-table writes need transactions |
| CQ15 | No async code present | "Simple async" — if async exists, it applies |
| CQ16 | No monetary calculations. Stats/ratios = N/A. | "Display field" — if the value enters arithmetic, it applies |
| CQ17 | No async loops | "Small loop" — N+1 at any N is a problem |
| CQ18 | Single data store | "Cache is just cache" — if inconsistency breaks UX, it applies |
| CQ19 | Internal code, caller already validated | "Types are enough" — TS types vanish at runtime |
| CQ20 | No domain entities | "Legacy" — not a valid excuse |
| CQ21 | Read-only, single-user, no contested resources | "Low traffic" — races happen at any traffic level |
| CQ22 | Pure sync, stateless, no subscriptions | "One listener" — 1 listener x 1000 mounts = 1000 listeners |

| CQ23 | No caching in this code path | "Small data" — if cache exists, TTL applies |
| CQ24 | New endpoint only, no existing clients | "Internal API" — if any client calls it, backward compat applies |
| CQ25 | Single file change, no pattern to compare | "It's better this way" — consistency > preference |
| CQ26 | Pure computation, zero I/O, zero logging | "We log elsewhere" — if file has logger calls, it applies |
| CQ27 | No log statements in changed code | "It's just a warning" — if logger.error exists, check its usage |
| CQ28 | Single-layer timeout, no hierarchy to check | "Defaults are fine" — if multiple layers define timeouts, check order |

**Abuse check:** If 17+ gates are N/A, justify each one, flag the audit as low-signal, and do not count it toward aggregate metrics.

---

## Fix-First Protocol

When a gate scores 0, fix it immediately if the fix takes under 5 minutes. Do not record a 0 and continue.

```
CQ=0 found →
  Can I fix this in <5 min?
    YES → fix NOW, re-score as 1
    NO  → critical gate?
      YES → fix NOW regardless of time
      NO  → score as 0, note "FIX NEEDED: [description]"
```

**Principle:** If writing the backlog entry takes longer than the fix itself, you chose wrong.

"Out of scope" applies only to: public API signature changes, DB migrations, new dependencies, external API contract changes. Adding a WHERE clause, null guard, or type annotation is never out of scope.

### Output Format

```
Code quality self-eval: CQ1=1 CQ2=1 CQ3=1 CQ4=1 CQ5=1 CQ6=1 CQ7=1 CQ8=0 CQ9=1 CQ10=1 CQ11=1 CQ12=0 CQ13=1 CQ14=1 CQ15=1 CQ16=1 CQ17=1 CQ18=1 CQ19=1 CQ20=1 CQ21=1 CQ22=1 CQ23=N/A CQ24=N/A CQ25=1 CQ26=1 CQ27=1 CQ28=N/A
  Score: 24/26 applicable → FAIL | Critical gate: CQ8=0 → FAIL
  Evidence: CQ3=schema(dto:12) CQ4=guard+filter(service:45) CQ8=FAIL CQ14=compared(service:all) CQ25=follows existing pattern CQ26=structured logger with requestId
  Fix: CQ8 — add try/catch at service.ts:88
```

---

## Reference Patterns

Concrete code patterns to verify specific gates during evaluation.

**CQ6 — Cursor-based bounded iteration:**
```typescript
let cursor: string | undefined;
while (true) {
  const batch = await prisma.session.findMany({
    where: { surveyId }, take: 1000,
    ...(cursor ? { cursor: { id: cursor }, skip: 1 } : {}),
    select: { id: true },
  });
  if (batch.length === 0) break;
  await processBatch(batch.map(s => s.id));
  cursor = batch[batch.length - 1].id;
}
```

**CQ9 + CQ17 — Atomic batch replace inside transaction:**
```typescript
await prisma.$transaction(async (tx) => {
  await tx.model.deleteMany({ where: { scopeId } });
  await tx.model.createMany({ data: items, skipDuplicates: true });
});
```

**CQ14 — Duplication detection procedure:**
1. List all methods exceeding 20 lines plus declarative structures. Check for blocks sharing 10+ structurally identical lines. Extract these.
2. Count identical try/catch blocks, error handlers, reducers. Five or more repetitions = CQ14 FAIL regardless of individual block size.
3. Beware the rationalization trap: "Each block is only 3 lines" — total duplicated lines are what matter.

**CQ18 — Multi-store synchronization:** Match operations (soft delete both or neither). Establish single source of truth plus derived views. Use transactions for SQL stores and async cleanup queues for external stores.

**CQ12 vs CQ20 distinction:** If deleting one field loses information → CQ20 (dual source of truth). If both are just inconsistent coding style → CQ12 (magic values).

**CQ21 — CAS state machine transition:**
```typescript
const { count } = await prisma.order.updateMany({
  where: { id, status: 'pending' },
  data: { status: 'shipped' },
});
if (count === 0) throw new ConflictException('Order already transitioned');
```

**CQ8 — External service timeout:**
```typescript
const result = await Promise.race([
  paymentProvider.charge(amount),
  new Promise((_, reject) => setTimeout(() => reject(new Error('Payment timeout')), 5000)),
]);
```

---

## High-Risk Gates by Code Type

| Code Type | Focus CQs | Common Failures |
|-----------|-----------|-----------------|
| **SERVICE** | CQ1,3,4,8,14,16,17,18,20,21,23,26,27 | Status as string, no validation, guard without filter, unhandled DB errors, duplication, float money, N+1, multi-store sync, dual fields, TOCTOU, stale cache, unstructured logs, wrong log level |
| **CONTROLLER** | CQ3,4,5,12,13,19,24,25 | Missing DTO, auth bypass, PII in error, magic codes, dead endpoints, no response schema, breaking API change, inconsistent pattern |
| **REACT** | CQ6,10,11,13,15,22,25 | Unbounded list, null crash, oversized file, dead code, dropped promise, listener leak, inconsistent component pattern |
| **ORM/DB** | CQ6,7,9,10,17,20,23 | Unbounded findMany, no LIMIT, wrong delete order, null column, N+1, dual fields, stale cache |
| **ORCHESTRATOR** | CQ6,8,9,14,15,17,18,21,28 | All IDs in memory, no error handling, no tx, duplication, dropped promises, N+1, sync, TOCTOU, inverted timeouts |
| **HOOK** | CQ6,8,10,11,15,22 | Unbounded spread, no AbortController, nullable fields, oversized body, dropped promise, no cleanup |
| **PURE** | CQ1,2,10,12,16 | Stringly-typed, no return type, null edge case, magic numbers, float money |

### Pure Computation Services

These still require auditing even though many gates are N/A.

| CQ | What to check | Typical miss |
|----|---------------|-------------|
| CQ2 | All public methods have explicit return types? | Complex object literal with no interface |
| CQ3 | Public methods callable from boundary have runtime validation? | Claiming N/A as "pure internal" but method is public |
| CQ10 | `as Type` casts followed by null guards? `.find()` results checked? | Claiming pass because "no DB" but casts on unknown have no guard |
| CQ11 | Methods within limits (30L private, 50L public)? | Claiming pass without counting |
| CQ16 | Financial arithmetic integer-safe? `toFixed()` only for display? | "Uses round()" — `round(float*float)` is still float |
