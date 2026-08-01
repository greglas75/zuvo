# Defensive Code Patterns — Core

Writing patterns only. Read BEFORE producing code. Full version with examples: `cq-patterns.md`
(same directory). Every section of the full file has a bullet here — if a bullet is unclear,
read its worked example there (regenerated 2026-08-01; the previous core had drifted ~20
patterns behind the full file).

---

## Error Handling
- **Error narrowing**: `catch (err: unknown)` + `instanceof Error` before `.message` — never `as Error` cast. Convention: always `err`, not e/error/ex.
- **Error cause chain**: `throw new Error('msg', { cause: err })` — never `throw 'string'`, never swallow catch, always `return await` in try.
- **Error strategy by impact**: critical path → rethrow. Non-critical (cache, metrics) → warn + continue. User-facing read → fallback data. Always log before falling back. Never catch-and-continue silently.
- **Typed exceptions**: `throw new NotFoundException()` — never generic `throw new Error` in framework services.
- **Correct log levels (CQ27)**: `error` = unrecoverable/infra only; validation failures are `warn`/`info`.
- **Retry (CQ8)**: bounded attempts, exponential backoff + FULL JITTER, honour `Retry-After`; retry only idempotent ops or key-carrying mutations; 4xx≠429 is a bug, not a retry.

## Security
- **Timing-safe compare (CQ33)**: hash both to fixed-width BUFFERS, then compare — `timingSafeEqual(sha256buf(a), sha256buf(b))` (`timingSafeEqual` rejects strings; digest() must return Buffer — worked factory in cq-patterns.md). Never `===` for secrets, and never `timingSafeEqual` on raw buffers: it THROWS on a length mismatch (uncaught 500 + length oracle).
- **CSPRNG + credential hashing (CQ33)**: tokens from `crypto.randomBytes`/`randomUUID`, never `Math.random()`; passwords via argon2id/bcrypt≥12, never bare SHA.
- **Defense in depth (CQ4)**: auth guard AND `WHERE { organizationId: orgId }` in query — guard alone is NOT sufficient.
- **Function-level authz + field allowlist (CQ34)**: assert permission for THIS operation (not just authenticated); write payloads through a DTO/allowlist — never `{ ...body }` into the ORM.
- **CSRF (CQ30)**: cookie-authed mutation needs `SameSite` AND a CSRF token — or a bearer transport.
- **SSRF (CQ31)**: allowlist outbound URLs, block private IPv4+IPv6 ranges, `redirect: 'error'` or re-validate every hop.
- **PII in logs (CQ5)**: log correlation IDs only — no email, password, token in logs, error messages, or API responses.
- **Path traversal (CQ31)**: `path.resolve()` + containment via `path.relative()` — reject `rel === '..'`, `rel.startsWith('..'+sep)` or an absolute `rel` (segment compare, so a file named `..config` still works). Symlinks: `realpath` the PARENT dir (the target may not exist yet). Never `normalize()`+`startsWith()`: that passes `/base-evil` for base `/base`.
- **No hardcoded secrets (CQ33, CAP5)**: runtime env + `.env` in `.gitignore` — never secrets in source.
- **Supply chain (CQ32)**: exact-pin NEW dependencies, commit the lockfile in the same change, run the advisory check.
- **Non-literal RegExp**: escape special chars before `new RegExp(userInput)`.
- **Child process (CQ31)**: `execFileSync('cmd', [args])` — avoid `shell: true`.
- **Prototype pollution**: guard dynamic keys (`__proto__`, `constructor`, `prototype`) before `obj[key] = v`.
- **Webhooks (CQ33/CQ3)**: HMAC over the RAW body bytes (never re-serialized JSON), timing-safe compare, ±5-min timestamp window, dedupe by event id.
- **LLM output = untrusted input (CQ31)**: schema-parse structured output; model text reaching path/shell/SQL/URL sinks gets user-input validation; cap agent-loop spend.
- **GCM decrypt**: pass `authTagLength` explicitly. **External scripts**: subresource integrity (CQ32).

## Data Integrity
- **Atomicity (TOCTOU)**: `try { await reserve(id, qty) }` — never check-then-act (state changes between check and action).
- **Idempotency**: `if (order.status === 'cancelled') return` — guard against re-entry before mutations.
- **Re-entry locks**: release by TOKEN (`if (lock.owner === myToken) release()`) — never unconditionally in `finally` (releases someone else's lock after your timeout).
- **Prisma upsert**: `prisma.upsert()` — never manual `findFirst` + `create/update` (race condition).
- **Side effects after tx**: fire-and-forget AFTER `$transaction` completes — never inside (rollback fires side effect).
- **Integer-cents**: `Math.round(priceCents * (100 - discount) / 100)` — never float arithmetic on money.
- **Idempotency-Key (CQ21)**: one key per logical mutation, reused across retries; server stores first result under the key and replays duplicates.
- **Outbox (CQ18)**: event row written IN the same transaction as the state change; relay delivers at-least-once; consumers idempotent. Dual-write without it = violation.
- **Date-only ≠ timestamp**: calendar dates travel as `YYYY-MM-DD` strings/PlainDate — `new Date('1990-05-10')` renders a day early west of UTC.
- **UTC-canonical time**: store/compare in UTC, convert at the display edge only.
- **Copy before mutating**: `[...items].sort()` — never mutate a parameter; validate string params too (`!userId?.trim()`).
- **structuredClone** for deep copies — never `JSON.parse(JSON.stringify(x))` (drops Dates/undefined/Maps).
- **API backward compat (CQ24)**: additive changes only; removals need a deprecation path.

## Resource Safety
- **Bounded queries**: `findMany({ take: 100, select: { id: true } })` — never unbounded findMany.
- **Cap user limits**: `Math.min(limit ?? DEFAULT, MAX_PAGE_SIZE)` — never pass uncapped user input.
- **Cap accumulators**: batched/streamed data collected in memory needs a max size — never grow unbounded on external input (CQ6/CQ39).
- **Timeout on outbound**: `AbortSignal.timeout(10_000)` on every fetch/HTTP call.
- **Streams: INACTIVITY timeout**, not a total deadline — a healthy 90s download must not die at 30s; reset the timer on each chunk, clear it in `finally`.
- **Stream safety**: handle `error`, honour backpressure (`write()` return + `drain`), always finalize (`finally`/`pipeline`).
- **Timeout hierarchy (CQ28)**: DB timeout < server timeout < client timeout — the deadline shrinks with depth, so the innermost layer fails first and the caller is still there to receive the error. Inverting it exhausts the connection pool.
- **Concurrency limit**: `pLimit(5)` on dynamic fan-out — never unbounded `Promise.all` on user-sized arrays.
- **Cache TTL (CQ23)**: every `redis.set` needs `EX`/`PX` — never cache without expiration.
- **Cache expensive computations**: key by version, invalidate on change — never rebuild an index per call.
- **Cursor pagination (CQ7)**: offset drifts under live writes (dupes/missing rows) — cursor over a stable unique ordering with an `id` tiebreaker.

## Type Safety & Validation
- **Exhaustive switch**: `default: const _: never = s; throw new Error(...)` — catches missing cases at compile time.
- **Guard nullable**: check `.find()` result before access — never `items.find(...).name` or `user!.profile`. `Array.isArray` before array ops on unknown data.
- **Schema-validate responses (CQ19)**: `Schema.parse(await response.json())` — external data is `unknown` until validated.
- **Check response.ok**: before `.json()` — 404/500 returns HTML, `.json()` throws SyntaxError.
- **Expose public fields only (CQ5)**: explicit shape in API responses — never return raw Prisma/DB object to client.
- **JSON.parse boundary**: `try { JSON.parse(input) }` on all external input — never bare parse.
- **as any bypass**: extend interface or `Omit/Pick/destructure` — never cast to `any`.
- **?? vs ||**: use `??` for defaults — `||` treats 0, `''`, false as falsy.

## Async & Lifecycle
- **No async in forEach**: `forEach` doesn't await — use `for...of` or `Promise.all(items.map(...))`.
- **Always .catch()**: `.then()` without `.catch()` = silent failure. Or use `await` in try/catch.
- **Cleanup listeners (CQ22)**: every `addEventListener`/`subscribe`/`setInterval` needs cleanup in return/destroy.
- **Functional updater**: `setCount(c => c + 1)` — never stale closure in async callbacks.
- **Sequential await**: comment the trade-off — use `Promise.all` with concurrency limit if no ordering needed.
- **Async singleton (CQ21)**: cache the PROMISE (`p ??= init()`) for single-flight, and reset it in `.catch` — a cached rejection bricks every later caller.
- **Independent fan-out**: `Promise.allSettled` + partition, handle BOTH halves — `Promise.all` throws away 99 successes for 1 failure; ignoring the rejected half drops errors (CQ15).
- **Cancellation composition (CQ35)**: `AbortSignal.any([received, AbortSignal.timeout(n)])` — accept + forward the ambient signal, never mint a fresh controller mid-chain.
- **Graceful shutdown (CQ22/CQ38)**: SIGTERM → stop intake, drain in-flight, close pools, force-exit BEFORE the orchestrator's kill window.

## Structure
- **Map over find-in-loop**: `new Map(items.map(i => [i.id, i]))` — never `.find()` per iteration (O(n) vs O(n^2)).
- **Shared helpers (CQ14)**: extract guard/decorator to shared module — never same logic in 5+ files.
- **Data-driven registration**: table/map of handlers — never N copy-pasted register blocks.
- **Copy-paste bug sweep (CQ13/CQ14)**: identical if/else-if conditions, identical operator operands, identical function bodies, boolean-literal compares, commented-out code — all flagged; full list in `cq-patterns.md`.
- **Pattern consistency (CQ25)**: new code follows the project's existing shape — no special snowflakes.
- **Config boundary**: one validated config module at startup — never `process.env` scattered across services.
- **Structured logger (CQ26)**: `logger.info('msg', { requestId })` — never raw `console.log` in services.
- **Docker**: non-root `USER`, drop privileges — never run app containers as root.
