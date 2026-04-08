# Benchmark Corpus Task — Write Production Code

You are participating in a benchmark. Write TWO production TypeScript files. Follow any file size limits and quality rules you have loaded (e.g. file-limits.md, cq-patterns.md). After both files, emit the SELF_EVAL_SUMMARY block.

---

## Minimal Type Contracts

Define these types inline in whichever file uses them (or in a shared block at the top):

```typescript
type OrderStatus = 'pending' | 'confirmed' | 'processing' | 'shipped' | 'delivered' | 'cancelled';

interface OrderFilters {
  status?: OrderStatus;
  dateRange?: { from: Date; to: Date };
  customerId?: string;
  take?: number;
  skip?: number;
}

interface CreateOrderDto {
  customerId: string;
  lineItems: Array<{ productId: string; quantity: number; unitPrice: number }>;
  currency: string;
}

interface ExportFilters {
  status?: OrderStatus;
  dateRange?: { from: Date; to: Date };
}
```

You may define any additional local types needed. Do NOT invent external packages beyond what is specified.

---

## File 1: OrderService.ts

NestJS service class (`@Injectable()`). Dependencies injected via constructor: `PrismaService`, `RedisService`, `EmailService`, `PaymentGateway`.

Implement the following methods:

- `findAll(filters: OrderFilters, orgId: string)` — query orders with filters (status, dateRange, customerId); Redis cache with TTL; bounded with take/skip pagination; scoped to orgId
- `findById(id: string, orgId: string)` — find single order; throw NotFoundException if not found or wrong org
- `create(dto: CreateOrderDto, orgId: string)` — create order + line items in a single transaction; validate dto; emit audit log; return created order
- `deleteOrder(id: string, orgId: string)` — delete order + line items atomically in transaction; invalidate cache; emit audit log
- `updateStatus(id: string, newStatus: OrderStatus, orgId: string)` — state machine enforcement: pending→confirmed→processing→shipped→delivered; cancellation allowed from any non-delivered state; send email notification on `shipped` status with error handling; emit audit log
- `calculateMonthlyRevenue(month: Date, orgId: string)` — aggregate total revenue by currency for the given month; return `{ currency: string, total: number }[]`
- `bulkUpdateStatus(ids: string[], newStatus: OrderStatus, orgId: string)` — update multiple orders; skip invalid transitions silently; return count of updated orders
- `getOrdersForExport(filters: ExportFilters, orgId: string)` — full order data including line items, customer, and payments; bounded by maxRows: 10000

All queries must be scoped by `organizationId`. Redis cache must be invalidated on all mutations. Audit logging on all mutations. Email notification on shipping must have `.catch()` or `await` with error handling.

---

## File 2: useSearchProducts.ts

React custom hook for product search. Implement:

- Debounced search input (300ms) using `AbortController` to cancel in-flight requests
- Pagination with `loadMore` that appends results (not replaces)
- Runtime validation of API response shape (hand-rolled checks, NOT Zod)
- Error handling with automatic retry on failure (max 3 attempts, exponential backoff)
- Separate loading states: `isLoading` (initial/reset search) and `isLoadingMore` (loadMore)
- Cleanup on unmount: abort in-flight requests, clear debounce timers

Return value: `{ products, total, isLoading, isLoadingMore, error, hasMore, loadMore, retry }`

---

## Required Response Format

Your response MUST follow this structure exactly:

1. A fenced TypeScript block for File 1:
   ````
   ```typescript
   // FILE: OrderService.ts
   <full implementation>
   ```
   ````

2. A fenced TypeScript block for File 2:
   ````
   ```typescript
   // FILE: useSearchProducts.ts
   <full implementation>
   ```
   ````

3. The SELF_EVAL_SUMMARY block at the very end (no prose after it):

```
SELF_EVAL_SUMMARY
OrderService: <score 0-20>/20
useSearchProducts: <score 0-20>/20
```

Score 0-20 = sum of: completeness (0-5) + accuracy (0-5) + actionability (0-5) + no_hallucinations (0-5).
