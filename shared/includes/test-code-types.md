# Test Code-Type Classification

> 11 code types for production file classification. Drives minimum test count, required patterns, and mock strategy.

## Classification Table

| Code Type | Detection Signals | Min Tests Formula |
|-----------|------------------|-------------------|
| VALIDATOR | Zod schemas, `validate*`, class-validator decorators | Fields × 3 (valid + invalid + boundary) |
| SERVICE | Injectable class with DB/HTTP calls, business logic methods | Methods × 3 |
| CONTROLLER | Route decorators, request/response handlers | Endpoints × 4 (happy + auth + validation + error) |
| HOOK | `use*` functions, React hooks with side effects | States × 3 + lifecycle tests |
| PURE | No I/O, no side effects — transforms, formatters, calculators | Functions × 4 + property-based |
| COMPONENT | React/Vue component with props and render logic | Render states × 2 + interaction tests |
| GUARD | Auth guards, permission checks, middleware | Rules × 3 (allow + deny + edge) |
| API-CALL | HTTP client wrappers, SDK calls | Methods × 3 (success + error + timeout) |
| ORCHESTRATOR | Coordinates multiple services, saga/workflow logic | Steps × 2 + full-flow integration |
| STATE-MACHINE | Finite states with transitions, event-driven reducers | Transitions × 2 + States × 1 + lifecycle flow |
| ORM/DB | Repository pattern, query builders, migrations | Queries × 3 (success + empty + constraint violation) |

## Per-Code-Type Test Strategy

Each code type has specific things to test and a recommended mock strategy. This is NOT optional — use this table in Step 1 to plan tests.

| Code Type | What to test | Mock strategy | Key pattern |
|-----------|-------------|---------------|-------------|
| **ORCHESTRATOR** | Middleware ordering invariants, route mounting, auth boundaries (presence + order), path isolation | Mock route modules + external-dep middleware as pass-through. Keep pure middleware real. | `vi.hoisted` log array for ordering (see template below) |
| **SERVICE** | Business logic branches, error paths, transaction boundaries, caller contracts | Mock external I/O only (DB, HTTP, email). Use real code for internal deps. | Test computed output, not mock echo |
| **CONTROLLER** | Input validation (400), auth (401/403), success (200/201), error shapes, security S1-S4 | Mock service layer. Real validation + guards. | Every endpoint × 4 (happy + auth + validation + error) |
| **PURE/VALIDATOR** | All branches, edge cases per parameter type, property-based tests | Zero mocks | State matrix: input combinations → expected outputs |
| **GUARD/MIDDLEWARE** | Request without header → expected behavior, wrong header → 4xx, correct header → next() called, ordering relative to other middleware | Mock downstream only | Positive AND negative assertions |
| **HOOK** | Return values, state transitions, side effects, cleanup | Mock external effects (fetch, timers) | Test lifecycle: mount → interact → verify → cleanup |
| **COMPONENT** | Render states (loading/error/empty/data), user flows (action → state → callback), a11y | Mock API calls. Real render. | 30%+ must be flow tests, not just render |
| **API-CALL** | Success + error + timeout, retry behavior, response parsing | Mock HTTP layer (MSW or vi.fn) | Test transformed output, not raw response echo |
| **STATE-MACHINE** | All transitions, invalid transitions rejected, lifecycle flows, reset behavior | Zero or minimal mocks | Transition matrix: state × event → new state |
| **ORM/DB** | Query construction, empty results, constraint violations, transaction rollback | Real DB with transaction rollback, or mock query builder | Test query RESULTS not query SHAPE |

### ORCHESTRATOR Ordering Template

For files that wire middleware/routes in a specific order, use this pattern to test ordering invariants:

```typescript
const callOrder = vi.hoisted(() => [] as string[]);

vi.mock("./middleware/auth.js", () => ({
  clerkAuth: vi.fn(async (_, next) => { callOrder.push("clerkAuth"); await next(); }),
}));
vi.mock("./middleware/tenant.js", () => ({
  tenantResolver: vi.fn(async (_, next) => { callOrder.push("tenantResolver"); await next(); }),
}));

// In test:
beforeEach(() => { callOrder.length = 0; });

it("applies middleware in correct order", async () => {
  await app.request("/api/admin/contests");
  expect(callOrder).toEqual(["clerkAuth", "tenantResolver"]);
});
```

This catches: reordered middleware (auth before DB → crash), removed middleware (silent security gap), duplicated middleware (double auth check).

### ORCHESTRATOR Pitfalls (learned from real sessions)

**Pitfall 1: Stub path collision.** When a route module is mounted at a broad prefix (e.g. `/api`), a catch-all stub (`all("*")`) steals requests meant for other routes (health checks, other mount points). FIX: Use path-specific stubs:
```typescript
// BAD — catches /api/health, /api/admin/*, everything
const social = new Hono(); social.all("*", handler);

// GOOD — only catches its own paths
const social = new Hono();
social.all("/r/*", handler);
social.all("/contests/:slug/entry/*", handler);
```

**Pitfall 2: Rate limit path binding.** Testing `rateLimit.toHaveBeenCalledWith(3, 3600)` proves the factory was called but NOT that the limit is applied to `/register`. Test path execution:
```typescript
// INCOMPLETE — proves config, not binding
expect(rateLimit).toHaveBeenCalledWith(3, 3600);

// COMPLETE — proves limit runs on the right path
it("applies 3/3600 rate limit on /register", async () => {
  await app.request("/api/contests/slug/register");
  expect(callOrder).toContain("rateLimit(3/3600)");
});
```

**Pitfall 3: Auth boundary checklist.** Test BOTH presence AND absence of middleware per route group. Missing absence tests = silent security gap if someone adds auth to public routes:
```
Auth boundary matrix (test each cell):
| Route group | clerkAuth | tenantResolver | publicTenantResolver | rateLimit |
|-------------|-----------|----------------|---------------------|-----------|
| Admin       | YES       | YES            | NO                  | NO        |
| Public      | NO        | NO             | YES                 | per-path  |
| Webhook     | NO        | NO             | NO                  | NO        |
| Health      | NO        | NO             | NO                  | NO        |
```
Every NO cell needs `expect(callOrder).not.toContain("clerkAuth")`.

### ORCHESTRATOR Min Tests Formula

```
middleware_count (ordering)
+ route_modules × 1 (mount verification)
+ rate_limiters × 2 (config + path execution)
+ auth_boundaries × 2 (positive + negative per group)
+ endpoints × 1 (health, etc.)
+ 1 (404 unknown path)
```

Example: 4 middleware + 13 routes + 6 limiters×2 + 4 groups×2 + 2 endpoints + 1 = 32 tests.

**CRITICAL:** THIN complexity does NOT mean simple testing. A 67-line ORCHESTRATOR with 0 branches can have critical ordering invariants that require more test sophistication than a 200-line SERVICE with 10 branches.

### SERVICE + ORM Mock Templates

For services with chainable query builders — use these templates to avoid wasting turns on mock setup.

**Drizzle (chainable select):**
```typescript
function thenableChain(result: unknown) {
  const chain: Record<string, unknown> = {};
  const self = () => chain;
  chain.from = vi.fn(self);
  chain.where = vi.fn(self);
  chain.leftJoin = vi.fn(self);
  chain.groupBy = vi.fn(self);
  chain.having = vi.fn(self);
  chain.for = vi.fn(self);
  chain.then = (resolve: (v: unknown) => void) => resolve(result);
  return chain;
}

// Sequential results for tx.select():
let callIdx = 0;
const selectFn = vi.fn(() => thenableChain(results[callIdx++]));
```

**Prisma (delegate mock):**
```typescript
const prismaMock = {
  user: { findMany: vi.fn(), create: vi.fn(), update: vi.fn() },
  $transaction: vi.fn((fn) => fn(prismaMock)),
};
```

**Key rule:** Mock the query builder chain, not individual SQL. Test the RESULT of the query (what your service returns), not the query SHAPE (which methods were called).

## Mixed Files

When a file combines types (e.g., a SERVICE with PURE helper functions inside it), apply both classifications. Sum the minimum test counts.

## PURE_EXTRACTABLE Detection

After classifying the file, scan for non-exported pure helper functions within non-pure files. Mark them for property-based testing. If 3+ such helpers exist, recommend extraction to a `[file].utils.ts` module.

## Complexity Classification

| Classification | Criteria | Test depth |
|---------------|----------|------------|
| THIN | Under 50 LOC, no owned branching, pure delegation | Wiring correctness + error propagation. Skip edge case checklist. 5-12 tests. |
| STANDARD | 50-200 LOC, moderate branching (3-10 branches) | Full edge case checklist per parameter. 15-40 tests. |
| COMPLEX | Over 200 LOC or more than 10 branches | Split test files by concern. Full coverage. 40-80 tests. |

## Testability Classification

| Classification | Signal | Strategy |
|---------------|--------|----------|
| UNIT_MOCKABLE | All deps injected, no static DB/ORM calls | Standard unit test with mocks |
| UNIT_REFLECTION | Protected/private properties, constructor does DI but also creates internal deps | Partial mock + `disableOriginalConstructor()` + inject via reflection |
| NEEDS_INTEGRATION | Static ORM calls, framework singletons, global state | Integration test with real DB — use project's DB test pattern |
| MIXED | Some methods unit-testable, some need DB | Split: unit tests for injectable methods, integration tests for static-call methods |

**Detection rules:**
- Static ORM/AR: `ClassName::findOne`, `::find`, `DB::table` → NEEDS_INTEGRATION
- Constructor injection with `$this->dep = $dep` → UNIT_MOCKABLE or UNIT_REFLECTION
- Both in same file → MIXED (decide per method)
