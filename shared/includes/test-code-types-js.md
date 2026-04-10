# Test Code-Type Templates — JavaScript / TypeScript

> Stack-specific mock templates and patterns for Vitest, Jest, React Testing Library.
> Core classification rules are in `test-code-types-core.md`.

## COMPONENT Dispatch/Router Template

For components that switch on a type/variant to render different children (QuestionRenderer, TabRouter, StepWizard):

```typescript
// Mock all child components with testid stubs
vi.mock('./ChildA', () => ({ default: () => <div data-testid="child-a" /> }));
vi.mock('./ChildB', () => ({ default: () => <div data-testid="child-b" /> }));

// For lazy-loaded children:
vi.mock('./LazyChild', () => ({
  default: vi.fn(() => <div data-testid="lazy-child" />),
}));

// Test each dispatch case:
it('renders ChildA for type="foo"', async () => {
  render(<Dispatcher type="foo" />);
  expect(await screen.findByTestId('child-a')).toBeInTheDocument();
});

// Test unknown/default case:
it('renders fallback for unknown type', () => {
  render(<Dispatcher type="unknown" />);
  expect(screen.getByText(/unsupported/i)).toBeInTheDocument();
});
```

**Always:** `afterEach(cleanup)` for component tests. Extract from exemplar if available.
**Lazy components:** Use `findByTestId` (async) not `getByTestId` (sync).

## ORCHESTRATOR Ordering Template

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

## SERVICE + ORM Mock Templates

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

## NestJS Logger Spy

NestJS services create `Logger` internally (not injected). To verify error logging, spy on `Logger.prototype.error` BEFORE constructing the service:
```typescript
let loggerErrorSpy: ReturnType<typeof vi.spyOn>;
beforeEach(() => {
  loggerErrorSpy = vi.spyOn(Logger.prototype, 'error').mockImplementation(() => {});
  service = new MyService(mockDeps);
});
afterEach(() => { loggerErrorSpy.mockRestore(); });
```
