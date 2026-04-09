# Mock Safety Rules

> Mandatory rules for mock usage in tests. Apply to every test file.

1. **Verify every mock** — `toHaveBeenCalledWith` (positive) and `not.toHaveBeenCalled` (negative). Unverified mocks hide broken integrations.
2. **No `as any` or `as never` casts on mocks** — use typed factories. Casts bypass the type system and mask interface drift.
3. **Reset all mocks in `beforeEach`** — prevents test interdependency. Stale mock state from test A affecting test B is a class of flaky test.
4. **Async generators: mock with `async function*`** or iterable factory. Never mock with plain arrays when production code uses `for await`.
5. **Streams: mock with readable stream from string** — not with bare arrays or sync iterators. Tests must exercise the stream API.
6. **External services: mock at the boundary** — mock the HTTP client or SDK, not the internal service method. Test real logic, fake I/O.
