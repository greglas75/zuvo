# Size and Complexity Limits

Empirically derived from benchmark data (18 implementation iterations scored 5.5-10/10). These thresholds reflect the operating zone where top-tier implementations (9.5+) produced quality without trade-offs.

Project CLAUDE.md may override specific values.

---

## File Size Limits

Lines measured = executable body lines. Excludes: blank lines, imports, type/interface definitions, JSDoc comments, and comment-only lines.

```
React component (single responsibility)     <= 200 lines
React component (page/container with state)  <= 300 lines
React hook                                   <= 250 lines
NestJS controller                            <= 300 lines
NestJS service (up to 4 public methods)      <= 300 lines
NestJS service (5-8 public methods)          <= 450 lines
NestJS service (9+ public methods)           → split into two services
NestJS guard / interceptor / middleware      <= 100 lines
NestJS module                                <=  50 lines
Utility / helper file                        <= 100 lines
Type definitions file (.types.ts)            no limit (types are free)
Constants file (.constants.ts)               <=  80 lines
DTO file (single DTO class)                  <=  50 lines
DTO barrel file (re-exports)                 <=  30 lines
Test file                                    no limit (coverage > brevity)
Prisma seed / migration script               no limit
```

### Rationale

- **450L for 5+ method services:** Top scorer achieved 10/10 at ~420 lines (8 methods). At 250L the same model scored 9.5 by dropping payment lifecycle and cache validation. The extra 200L bought 0.5 points.
- **250L for hooks:** No top-tier hook exceeded 220L. Extra space does not improve hooks — relaxed limits actually degraded quality (9.5 → 9.0).
- **100L for utils:** Helpers exceeding 100L do too much. Top implementations of `withTimeout`, `sleep`, `buildCacheKey` were 5-15 lines each.

---

## Function Size Limits

Lines measured = function body only, excluding signature line, JSDoc, and closing brace.

```
Public service method                        <= 50 lines
Private service helper                       <= 30 lines
Controller action handler                    <= 25 lines (delegate to service)
Transaction callback ($transaction body)     <= 60 lines *
React hook body (top-level)                  <= 100 lines
useCallback body                             <= 50 lines
useEffect body                               <= 20 lines (extract logic to callback)
React event handler                          <= 20 lines
Validation function (flat field checks)      <= 40 lines
Pure calculation function                    <= 30 lines
Test case (single it/test block)             <= 40 lines
describe block                               no limit
```

### Transaction Callback Exception (*)

Transaction callbacks may reach 60 lines when they encompass:
- Entity lookup + null check
- Business rule validation
- Conditional status check
- Audit log creation
- Return value construction

This pattern appeared in every 9.5+ scored service implementation:
```typescript
await prisma.$transaction(async (tx) => {
  const current = await tx.order.findFirst({ ... });     // 2L
  if (!current) throw new NotFoundException();            // 1L
  if (current.status === nextStatus) return current;      // 1L  idempotent
  this.assertTransition(current.status, nextStatus);      // 1L
  const { count } = await tx.order.updateMany({           // 5L  CAS
    where: { id, organizationId, status: current.status },
    data: { status: nextStatus },
  });
  if (count === 0) throw new ConflictException();         // 1L
  await tx.auditLog.create({ data: { ... } });           // 5L  audit
  return updated;                                          // 1L
});                                                        // ~20L total
```

When a transaction callback exceeds 50L, extract named private methods:
```typescript
await prisma.$transaction(async (tx) => {
  const order = await this.findAndValidateForUpdate(tx, id, orgId, nextStatus);
  const updated = await this.applyStatusChange(tx, order, nextStatus);
  await this.auditStatusChange(tx, orgId, id, order.status, nextStatus);
  return updated;
});
```

---

## Constructor and Dependency Limits

```
NestJS service constructor dependencies     <= 5 (4 preferred)
NestJS controller constructor dependencies  <= 3 (service + guard deps)
React component props                       <= 8 (split if more)
React hook parameters                       <= 3 (use options object for 3+)
React hook useState count                   <= 6 (use useReducer or state object for 7+)
React hook useEffect count                  <= 3 (consolidate or extract custom hooks)
React hook useRef count                     <= 5 (group into single ref object for 6+)
```

### Supporting data

- **5 deps max:** Top implementations used 4 dependencies (prisma, redis, email, payment). Baseline with 6 dependencies flagged as a God Service.
- **6 useState max:** Hooks with 6 useState (products, total, isLoading, isLoadingMore, error, page/cursor) scored 9+. A single state object approach also scored 9. Eight useState caused bugs.
- **3 useEffect max:** Top hooks had 2-3 effects (query change, unmount cleanup, optional trigger). Four effects with overlapping cleanup were confusing and error-prone.

---

## Nesting and Complexity Limits

```
Maximum nesting depth (if/for/try)          <= 4 levels
Maximum chained ternaries                   <= 2
Maximum conditions in single if             <= 3 (extract to named boolean or function)
Maximum parameters per function             <= 5 (use options object for 5+)
Maximum array method chain length           <= 4 (.filter().map().reduce() = 3, OK)
Callback nesting (promise chains)           <= 2 levels (use async/await)
```

---

## Naming Conventions

```
Files:
  service:     order.service.ts            controller:  order.controller.ts
  hook:        useSearchProducts.ts        (camelCase, use- prefix)
  types:       order.types.ts
  constants:   order.constants.ts
  DTO:         create-order.dto.ts         (kebab-case)
  test:        order.service.spec.ts       (or .test.ts)
  helper:      order.helpers.ts

Variables:
  constants:   CACHE_TTL_SECONDS           (SCREAMING_SNAKE)
  enums:       ORDER_STATUS.PENDING        (const object + type derivation)
  booleans:    isLoading, hasMore          (is/has/can/should prefix)
  counts:      totalCents, orderCount      (noun + unit suffix for ambiguous)
  maps:        STATUS_TRANSITIONS          (SCREAMING_SNAKE for module-level)
  refs:        abortControllerRef          (descriptive + Ref suffix)
  state:       [products, setProducts]     (noun, setNoun)

Functions:
  validators:  requireId, assertTransition, validateCreateInput
  builders:    buildListCacheKey, buildStatusPatch, buildWhereClause
  converters:  toListItem, toDetails, toSafeInteger
  predicates:  isRecord, isNonEmptyString, isOrderListResponse
  async:       fetchProducts, syncPaymentIntent (verb + noun)

NEVER use generic names for API/DB results:
  data, result, response, item, element, obj, val, tmp
  → use domain-specific: users, orderItems, surveyConfig, pricingResult
```

---

## When to Split a File

Split when any of the following apply:
1. File exceeds its category limit
2. Service has 9+ public methods → split by domain (OrderQueryService + OrderMutationService)
3. Component renders 3+ distinct sections with independent state → extract sub-components
4. Hook has 4+ useEffects → extract custom hooks (useDebounce, useAbortController)
5. File has 5+ private helper methods → extract to .helpers.ts
6. Types section exceeds 80 lines → extract to .types.ts
7. Constants exceed 30 lines → extract to .constants.ts
8. Validation logic exceeds 60 lines → extract to .validators.ts

### Effective split boundaries

```
order.service.ts          (public methods + orchestration)
order.constants.ts        (STATUS_TRANSITIONS, CACHE_TTL, limits)
order.types.ts            (interfaces, type aliases)
order.helpers.ts          (buildCacheKey, buildStatusPatch, toListItem)
order.validators.ts       (validateCreateInput, assertTransition, requireId)
dto/create-order.dto.ts   (class-validator DTO)
dto/order-filters.dto.ts  (query param DTO)
```

---

## Quick Reference

```
┌─────────────────────────────┬──────────┬────────────────────────────┐
│ Element                     │ Max Lines│ Notes                      │
├─────────────────────────────┼──────────┼────────────────────────────┤
│ Service file (5+ methods)   │ 450      │ excluding types/imports    │
│ Service file (<=4 methods)  │ 300      │                            │
│ Controller file             │ 300      │                            │
│ Hook file                   │ 250      │                            │
│ Component file              │ 200      │ 300 for page/container     │
│ Util / helper file          │ 100      │                            │
│ Public method               │  50      │                            │
│ Private helper              │  30      │                            │
│ Controller handler          │  25      │ delegate to service        │
│ $transaction body           │  60      │ exception: CAS+audit       │
│ useCallback body            │  50      │                            │
│ useEffect body              │  20      │ extract to callback        │
│ Constructor deps            │   5      │ 4 preferred                │
│ useState count              │   6      │ use object/reducer for 7+  │
│ useEffect count             │   3      │ consolidate for 4+         │
│ Nesting depth               │   4      │ if/for/try levels          │
│ Function params             │   5      │ use options object for 5+  │
└─────────────────────────────┴──────────┴────────────────────────────┘
```
