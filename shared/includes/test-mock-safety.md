# Mock Safety Rules

> Mandatory rules for mock usage in tests. Apply to every test file.

1. **Verify every mock** — `toHaveBeenCalledWith` (positive) and `not.toHaveBeenCalled` (negative). Unverified mocks hide broken integrations.
2. **No `as any` or `as never` casts on mocks** — use typed factories. Casts bypass the type system and mask interface drift.
3. **Reset all mocks in `beforeEach`** — prevents test interdependency. Stale mock state from test A affecting test B is a class of flaky test.
4. **Async generators: mock with `async function*`** or iterable factory. Never mock with plain arrays when production code uses `for await`.
5. **Streams: mock with readable stream from string** — not with bare arrays or sync iterators. Tests must exercise the stream API.
6. **External services: mock at the boundary** — mock the HTTP client or SDK, not the internal service method. Test real logic, fake I/O.
7. **Module-level singleton state** (Maps, Sets, caches, counters) — these persist across tests within the same module. Two strategies:
   - **(a) Unique keys per test** — each test uses a unique identifier (IP, userId) so tests don't collide. No cleanup needed. Preferred when state is keyed.
   - **(b) Exported reset helper + beforeEach** — if the module exposes a `reset()` or `clear()` function, call it in `beforeEach`. Required when state is global (not keyed).
   Common in middleware (rate limit buckets, session caches, connection pools). If neither strategy works, the module needs refactoring for testability.
8. **NestJS Logger spy** — NestJS services create `Logger` internally (not injected). To verify error logging, spy on `Logger.prototype.error` BEFORE constructing the service:
   ```typescript
   let loggerErrorSpy: ReturnType<typeof vi.spyOn>;
   beforeEach(() => {
     loggerErrorSpy = vi.spyOn(Logger.prototype, 'error').mockImplementation(() => {});
     service = new MyService(mockDeps);
   });
   afterEach(() => { loggerErrorSpy.mockRestore(); });
   ```
9. **Filtered last-call for accumulating mocks** — when a mock is called many times in a loop (e.g., `setex` at each lock tier), `toHaveBeenCalledWith(key, value)` matches ANY call. For tier/escalation tests, filter by key and assert the LAST call: `mock.calls.filter(([k]) => k === expectedKey).at(-1)`.
10. **Mock chain coherence** — when mocking a pipeline (step A → step B → step C), mock return values must form a coherent data chain. An always-empty mock at step N (e.g., `mockFn.mockResolvedValue(new Map())`) makes step N+1's `CalledWith` assertion meaningless — it passes regardless of whether the real pipeline connects. Instead: mock step A to return realistic data that step B would actually process. Verify step B receives that data via `CalledWith`.
9. **Dedup/merge assertion identity** — when testing dedup or merge logic, assert WHICH item survived (by identity: ID, content, or distinguishing field), not just the count. `toHaveLength(1)` passes even if the wrong item survived or dedup logic was deleted entirely.

### PHP-Specific Mock Rules

11. **`onlyMethods()` vs `addMethods()` in PHPUnit** — `onlyMethods()` is for methods that EXIST on the class (including inherited/trait methods). `addMethods()` is for methods that DON'T exist and are dispatched via `__call()`. Using the wrong one: `onlyMethods(['magicMethod'])` → error. `addMethods(['realMethod'])` → silently creates a SECOND method that shadows the real one, causing false passes.
12. **`createMock()` vs `getMockBuilder()`** — `createMock()` auto-stubs ALL methods (returns null/default). Quick for simple cases. `getMockBuilder()` gives control: `disableOriginalConstructor()`, `onlyMethods()`, `addMethods()`. Use `getMockBuilder()` when: constructor has side effects, you need to mix real + magic methods, or you need partial mocking.
13. **Codeception `_before()` / `_after()` not `setUp()` / `tearDown()`** — Codeception Unit tests use `_before()` and `_after()` lifecycle hooks, not PHPUnit's `setUp()`/`tearDown()`. Using the wrong one: hooks may not fire, mocks not reset, state leaks between tests.
14. **Yii2/Laravel static singletons** — never mock `Yii::$app` or `App::make()` globally. Inject the mock via constructor or public property. If the service reads `Yii::$app->component` internally, either: (a) refactor to accept the dep in constructor, or (b) use a test application config that replaces the component. Global mock → leaks across tests.
