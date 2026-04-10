# Mock Safety Rules — JavaScript / TypeScript

> Stack-specific mock rules for Vitest, Jest, NestJS.
> Universal rules are in `test-mock-safety-core.md`.

1. **No `as any` or `as never` casts on mocks** — use typed factories. Casts bypass the type system and mask interface drift. Note: `as unknown as ServiceType` is acceptable when no mock factory exists — it avoids `as any` while preserving the target type.
2. **Reset with `vi.clearAllMocks()` or `vi.resetAllMocks()` in `beforeEach`** — `clearAllMocks()` clears call records but does NOT clear `mockResolvedValue` or `mockImplementation`. A mock set in test A can leak into test B. If any test relies on a mock NOT having a return value: use `resetAllMocks()`.
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
