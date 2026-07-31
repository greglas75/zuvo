# Defensive Code Patterns — Core

Writing patterns only. Read BEFORE producing code. Full version with examples: `cq-patterns.md` (same directory).

---

## Error Handling
- **Error narrowing**: `catch (err: unknown)` + `instanceof Error` before `.message` — never `as Error` cast. Convention: always `err`, not e/error/ex.
- **Error cause chain**: `throw new Error('msg', { cause: err })` — never `throw 'string'`, never swallow catch, always `return await` in try.
- **Error strategy by impact**: critical path → rethrow. Non-critical (cache, metrics) → warn + continue. User-facing read → fallback data. Always log before falling back.
- **Typed exceptions**: `throw new NotFoundException()` — never generic `throw new Error` in framework services.

## Security
- **Timing-safe compare**: hash to a fixed width, then compare — `timingSafeEqual(sha256(a), sha256(b))`. Never `===` for secrets, and never `timingSafeEqual` on raw buffers: it THROWS on a length mismatch (uncaught 500 + length oracle).
- **Defense in depth**: auth guard AND `WHERE { organizationId: orgId }` in query — guard alone is NOT sufficient.
- **PII in logs**: log correlation IDs only — no email, password, token in logs, error messages, or API responses.
- **Path traversal**: `path.resolve()` + containment via `path.relative()` — reject `rel === '..'`, `rel.startsWith('..'+sep)` or an absolute `rel` (segment compare, so a file named `..config` still works). Symlinks: `realpath` the PARENT dir (the target may not exist yet). Never `normalize()`+`startsWith()`: that passes `/base-evil` for base `/base`.
- **No hardcoded secrets**: runtime env + `.env` in `.gitignore` — never secrets in source.
- **Non-literal RegExp**: escape special chars before `new RegExp(userInput)`.
- **Child process**: `execFileSync('cmd', [args])` — avoid `shell: true`.

## Data Integrity
- **Atomicity (TOCTOU)**: `try { await reserve(id, qty) }` — never check-then-act (state changes between check and action).
- **Idempotency**: `if (order.status === 'cancelled') return` — guard against re-entry before mutations.
- **Prisma upsert**: `prisma.upsert()` — never manual `findFirst` + `create/update` (race condition).
- **Side effects after tx**: fire-and-forget AFTER `$transaction` completes — never inside (rollback fires side effect).
- **Integer-cents**: `Math.round(priceCents * (100 - discount) / 100)` — never float arithmetic on money.

## Resource Safety
- **Bounded queries**: `findMany({ take: 100, select: { id: true } })` — never unbounded findMany.
- **Cap user limits**: `Math.min(limit ?? DEFAULT, MAX_PAGE_SIZE)` — never pass uncapped user input.
- **Timeout on outbound**: `AbortSignal.timeout(10_000)` on every fetch/HTTP call.
- **Timeout hierarchy**: DB timeout < server timeout < client timeout — the deadline shrinks with depth, so the innermost layer fails first and the caller is still there to receive the error. Inverting it exhausts the connection pool.
- **Concurrency limit**: `pLimit(5)` on dynamic fan-out — never unbounded `Promise.all` on user-sized arrays.
- **Cache TTL**: every `redis.set` needs `EX`/`PX` — never cache without expiration (CQ23).

## Type Safety & Validation
- **Exhaustive switch**: `default: const _: never = s; throw new Error(...)` — catches missing cases at compile time.
- **Guard nullable**: check `.find()` result before access — never `items.find(...).name` or `user!.profile`.
- **Schema-validate responses**: `Schema.parse(await response.json())` — external data is `unknown` until validated.
- **Check response.ok**: before `.json()` — 404/500 returns HTML, `.json()` throws SyntaxError.
- **Expose public fields only**: explicit shape in API responses — never return raw Prisma/DB object to client.
- **JSON.parse boundary**: `try { JSON.parse(input) }` on all external input — never bare parse.
- **as any bypass**: extend interface or `Omit/Pick/destructure` — never cast to `any`.
- **?? vs ||**: use `??` for defaults — `||` treats 0, `''`, false as falsy.

## Async & Lifecycle
- **No async in forEach**: `forEach` doesn't await — use `for...of` or `Promise.all(items.map(...))`.
- **Always .catch()**: `.then()` without `.catch()` = silent failure. Or use `await` in try/catch.
- **Cleanup listeners**: every `addEventListener`/`subscribe`/`setInterval` needs cleanup in return/destroy.
- **Functional updater**: `setCount(c => c + 1)` — never stale closure in async callbacks.
- **Sequential await**: comment the trade-off — use `Promise.all` with concurrency limit if no ordering needed.

## Structure
- **Map over find-in-loop**: `new Map(items.map(i => [i.id, i]))` — never `.find()` per iteration (O(n) vs O(n^2)).
- **Shared helpers (CQ14)**: extract guard/decorator to shared module — never same logic in 5+ files.
- **Config boundary**: one validated config module at startup — never `process.env` scattered across services.
- **Structured logger**: `logger.info('msg', { requestId })` — never raw `console.log` in services.
