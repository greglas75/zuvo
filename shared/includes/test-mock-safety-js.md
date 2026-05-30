# Mock Safety Rules — JavaScript / TypeScript

> Stack-specific mock rules for Vitest, Jest, NestJS.
> Universal rules are in `test-mock-safety-core.md`.

1. **No `as any` or `as never` casts on mocks** — use typed factories. Casts bypass the type system and mask interface drift. Note: `as unknown as ServiceType` is acceptable when no mock factory exists — it avoids `as any` while preserving the target type.
2. **Reset with `vi.clearAllMocks()` or `vi.resetAllMocks()` in `beforeEach`** — `clearAllMocks()` clears call records but does NOT clear `mockResolvedValue`, `mockReturnValue`, or `mockImplementation`. A mock set in test A can leak into test B. If any test relies on a mock NOT having a return value: use `resetAllMocks()`. For `vi.mock`'d sync parsers/factories driven by `mockReturnValue`, prefer `mockReset()`/`resetAllMocks()` — `clearAllMocks()` keeps the configured return value, leaking stale data across tests. (Exception: passthrough module mocks — see rule 6.)
3. **Async generators: mock with `async function*`** or iterable factory. Never mock with plain arrays when production code uses `for await`.
4. **Streams: mock with readable stream from string** — not with bare arrays or sync iterators. Tests must exercise the stream API.
5. **NestJS Logger spy** — NestJS services create `Logger` internally (not injected). To verify error logging, spy on `Logger.prototype.error` BEFORE constructing the service:
   ```typescript
   let loggerErrorSpy: ReturnType<typeof vi.spyOn>;
   beforeEach(() => {
     loggerErrorSpy = vi.spyOn(Logger.prototype, 'error').mockImplementation(() => {});
     service = new MyService(mockDeps);
   });
   afterEach(() => { loggerErrorSpy.mockRestore(); });
   ```
6. **Passthrough module mock (call the real impl by default, override per-test)** — when you only need to force one path (e.g. an error) but want the real function everywhere else:
   ```typescript
   vi.mock('@/x', async (imp) => {
     const actual = await imp();
     return { ...actual, fn: vi.fn(actual.fn) };  // real impl, spy-wrapped
   });
   // one test only:
   vi.mocked(fn).mockRejectedValueOnce(new Error('boom'));
   ```
   Reset with `vi.clearAllMocks()` in `beforeEach` — do NOT use `resetAllMocks()`/`mockReset()` here: reset wipes the wrapped impl and the passthrough silently becomes a no-op returning `undefined`. This is the direct exception to rule 2's "prefer reset" guidance.
