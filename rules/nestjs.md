# NestJS Conventions

Active when NestJS is detected in the project (`@nestjs/core` in dependencies or `nest-cli.json` present). Not applicable to non-NestJS projects.

---

## Controller Design

- **Controllers are thin** — validate input, delegate to service, return response. Zero business logic.
- `@ApiResponse` decorators for every status code the endpoint can produce.
- `ParseUUIDPipe` on all UUID path params — provides free 400 on malformed IDs and prevents injection.
- `@IsEnum` on format/type params in DTOs.
- Use `@Res({ passthrough: true })` when returning Response objects — preserves interceptors.

## Service Design

- **One responsibility per service.** Three or more unrelated concerns means it should be split.
- Cap at 5-7 public methods. Beyond that, split by domain.
- Cap at 5 constructor dependencies. More signals a God Service.
- Catch blocks must log with `this.logger.error(error.message, error.stack)`.

## DTO Validation

- All DTOs use `class-validator` decorators — raw input is never trusted.
- Use `@ValidateNested()` + `@Type(() => NestedDto)` for nested objects.
- Whitelist properties: `ValidationPipe({ whitelist: true, forbidNonWhitelisted: true })`.

## Database (Prisma)

- **Never `findMany()` without `take`** on user-facing endpoints.
- Use `select` to limit returned fields — never return full entities with all relations.
- Prefer `groupBy`/`aggregate` over loading data and post-processing in JS.
- Batch operations: cap at 1000 records per batch to prevent OOM.
- Index columns used in WHERE and ORDER BY — verify with `@@index` in schema.
- Avoid N+1: use `include` for needed relations, or batch with `where: { id: { in: ids } }`.
- **Deletes require `$transaction` respecting FK order:**
```typescript
// NEVER — orphaned items, missing audit, constraint violations
async deleteOrder(id: string, orgId: string) {
  await this.prisma.orderItem.deleteMany({ where: { orderId: id } });
  await this.prisma.order.delete({ where: { id } }); // crash between = orphan state
}

// ALWAYS — single transaction, children before parent, audit inside
async deleteOrder(id: string, orgId: string) {
  return this.prisma.$transaction(async (tx) => {
    await tx.payment.deleteMany({ where: { orderId: id, organizationId: orgId } });
    await tx.orderItem.deleteMany({ where: { orderId: id, organizationId: orgId } });
    await tx.auditLog.create({ data: { action: 'ORDER_DELETED', entityId: id, orgId } });
    return tx.order.delete({ where: { id, organizationId: orgId } });
  });
}
```

- **Audit logs belong inside `$transaction`** — not after. A crash between mutation and audit means silent data loss. Bulk operations must audit only actually affected rows:
```typescript
// NEVER — audits all requested IDs, not just those that were updated
const { count } = await tx.order.updateMany({ where: { id: { in: ids }, status: 'pending' }, data: { status } });
await tx.auditLog.createMany({ data: ids.map(id => ({ action: 'STATUS_CHANGED', entityId: id })) });

// ALWAYS — query updated IDs first, audit those
const updated = await tx.order.findMany({ where: { id: { in: ids }, status: 'pending' }, select: { id: true } });
const updatedIds = updated.map(o => o.id);
await tx.order.updateMany({ where: { id: { in: updatedIds } }, data: { status } });
await tx.auditLog.createMany({ data: updatedIds.map(id => ({ action: 'STATUS_CHANGED', entityId: id })) });
```

## Multi-Tenant Safety

- **Scope all queries by tenant** (`organizationId`, `tenantId`, or equivalent).
- Auth guard plus query filter: defense in depth (see CQ4 in `cq-checklist.md`).
- Test tenant isolation: request with wrong orgId → 403 + `service.not.toHaveBeenCalled()`.

## Redis

- Set TTL on every key (`SETEX`, not `SET`) — no immortal keys.
- Use `SCAN` instead of `KEYS` — `KEYS` blocks Redis on large datasets.
- Use pipelines for batch operations to avoid per-command network round-trips.
- Atomic multi-key operations: use Lua scripts, not separate pipeline commands.
- Check each result in pipeline response arrays for errors.
- **Cache must never break requests** — wrap all reads and writes in try/catch, fall through to DB:
```typescript
async getOrder(id: string): Promise<Order> {
  try {
    const cached = await this.redis.get(`order:${id}`);
    if (cached) {
      const parsed: unknown = JSON.parse(cached);
      if (parsed && typeof parsed === 'object' && 'id' in parsed) return parsed as Order;
    }
  } catch (err) {
    this.logger.warn('Cache read failed', { id, error: (err as Error).message });
  }
  const order = await this.prisma.order.findUniqueOrThrow({ where: { id } });
  try { await this.redis.setex(`order:${id}`, 3600, JSON.stringify(order)); } catch { /* non-fatal */ }
  return order;
}
```
- **Cache invalidation:** use version-based keys (`redis.incr('order:version')` embedded in key), not SCAN+DEL (SCAN is O(n) and blocking).
- **Cache keys:** never `JSON.stringify(obj)` (property order not guaranteed). Use `${entity}:${id}:${version}`.

## Streaming and Exports

- Stream large exports — never buffer entire file (SPSS/XLSX/CSV) in memory.
- Batch Prisma queries inside stream: cap at 1000 rows per batch.
- Use `@Res({ passthrough: true })` for streaming responses.

## Payment Flows

- **Reserve funds before DB transaction, compensate on failure:**
```typescript
const reservation = await this.withTimeout(
  this.paymentGateway.reserveFunds({ ... }), 10_000, 'Payment timeout',
);
try {
  await prisma.$transaction(async (tx) => { /* create order + audit */ });
} catch (err) {
  await this.paymentGateway.releaseFunds({ ref: reservation.reference })
    .catch(e => this.logger.error('Fund release failed', { error: e.message }));
  throw err;
}
```
- **Never hold DB locks during payment calls** — payment inside `$transaction` risks timeout.
- **Compensation failures: log, do not throw** — double-throw loses the original error.

## Bulk Operations

- **Bulk status updates must use CAS** — group by current status, one `updateMany` per group:
```typescript
const byStatus = new Map<OrderStatus, string[]>();
for (const order of candidates) {
  byStatus.set(order.status, [...(byStatus.get(order.status) ?? []), order.id]);
}
await Promise.all([...byStatus.entries()].map(([status, ids]) =>
  tx.order.updateMany({ where: { id: { in: ids }, organizationId, status }, data: { status: next } })
));
```
- **Never loop with per-item transactions** — N items = N transactions = N times the latency.

## Response Shaping

- **Return typed interfaces, not raw Prisma entities:**
```typescript
private toListItem(row: OrderRow): OrderListItem {
  return { id: row.id, status: row.status, totalCents: row.totalAmountCents,
           createdAt: row.createdAt.toISOString(), itemCount: row._count?.items ?? 0 };
}
```
- **Mapper functions control the API contract** — decoupling internal schema from the public interface.

## Error Handling

- Use typed exceptions: `BadRequestException`, `NotFoundException`, `ConflictException` — not generic `Error`.
- Domain errors extend `HttpException` or use exception filters.
- Global exception filter: map Prisma error codes to HTTP status (`P2002` → 409, `P2025` → 404).
- Never expose Prisma error details in API responses — map to user-friendly messages.
