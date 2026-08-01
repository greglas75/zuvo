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

### COMPONENT Lazy/Suspense Caveat

When all lazy children are mocked with `vi.mock`, Vitest can resolve `React.lazy()` imports synchronously. Testing Library wraps `render()` in `act()`, which flushes microtasks before control returns. In that setup, a Suspense fallback may never be observable even though the fallback exists in production.

Implications:
- do **not** write doomed synchronous assertions for the fallback just because the code renders one
- prefer `findBy...` assertions for the resolved lazy child
- if you must test the fallback, either export it directly or use a real delayed lazy import instead of sync mocks
- treat an unobservable fallback under sync mocks as an environment limitation, not automatic missing coverage

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

## Generic-Return Interface Mock (TS)

When the unit-under-test depends on a collaborator whose method returns a **generic** (`get<T>(key): Promise<T>`, `query<R>(sql): R[]`, a repository `findOne<E>()`), do NOT hand-roll a per-test `as any` cast — it loses type-safety and hides shape drift. Mock the interface with a typed factory so each test supplies the concrete return shape:

```typescript
// Typed mock factory: preserves the generic signature, lets each test pin T.
function mockStore(): vi.Mocked<Store> {
  return {
    get: vi.fn(),      // signature get<T>(key: string): Promise<T>
    set: vi.fn(),
  } as unknown as vi.Mocked<Store>;
}

// In a test — the cast lives ONCE, at the resolved value, typed to the real T:
const store = mockStore();
store.get.mockResolvedValue({ id: 1, name: "x" } satisfies User);  // `satisfies` enforces shape
```

Rule: the factory carries the ONE sanctioned structural cast (`as unknown as vi.Mocked<Store>` — unavoidable, since `vi.fn()` cannot satisfy a generic-method interface); per test, the only addition is `satisfies <ConcreteType>` on the resolved value, and no cast ever appears at the call site. This catches return-shape drift at compile time while keeping the mock reusable across tests.

## Time-Dependent Code Templates (Date.now / setTimeout / setInterval / performance.now)

`vi.useFakeTimers()` in `beforeEach`, `vi.useRealTimers()` in `afterEach`. Never rely on real
time passing — `await new Promise(r => setTimeout(r, 100))` in a test is the flake pattern.

| Production pattern | Test approach |
|-------------------|---------------|
| `setTimeout` / debounce / throttle | `vi.advanceTimersByTime(ms)` + assert fired / not fired at threshold-1 vs threshold |
| `Date.now()` deltas (cooldowns, elapsed) | `vi.setSystemTime(base)` → act → `vi.setSystemTime(base + delta)` → assert |
| `setInterval` (periodic) | advance by interval × N, assert N invocations |
| `performance.now()` timing | `vi.spyOn(performance, 'now').mockReturnValueOnce(0).mockReturnValueOnce(50)` |
| Timestamp recorded in state | `vi.setSystemTime(12345); handler(e); expect(state.lastEventTime).toBe(12345)` |
| Burst/rate detection (N events in T ms) | fire N events advancing time between each; assert detection exactly at threshold |

**Common miss:** production uses `Date.now()` for deltas but tests run on the real clock —
passes locally, flakes in CI. Grep the production file for `Date.now|performance.now|setTimeout|setInterval`; any hit ⇒ fake timers.

## NestJS Logger Spy

Single home: `test-mock-safety-js.md` rule 5 (spy on `Logger.prototype.error` BEFORE constructing
the service). Duplicated verbatim here until 2026-08-01; both files load together at STANDARD/HEAVY,
so the copy was double context for zero information.
