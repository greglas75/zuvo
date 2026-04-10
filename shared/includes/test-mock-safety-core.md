# Mock Safety Rules — Core

> Universal rules for mock usage in tests. Apply to every test file regardless of stack.
> Stack-specific rules are in `test-mock-safety-js.md` and `test-mock-safety-php.md`.

1. **Verify every mock** — positive assertion (CalledWith) and negative assertion (not.toHaveBeenCalled / never called). Unverified mocks hide broken integrations.
2. **Reset all mocks between tests** — prevents test interdependency. Stale mock state from test A affecting test B is a class of flaky test.
3. **External services: mock at the boundary** — mock the HTTP client or SDK, not the internal service method. Test real logic, fake I/O.
4. **Module-level singleton state** (Maps, Sets, caches, counters) — these persist across tests within the same module. Two strategies:
   - **(a) Unique keys per test** — each test uses a unique identifier so tests don't collide. Preferred when state is keyed.
   - **(b) Exported reset helper + setup hook** — if the module exposes a `reset()` or `clear()` function, call it in the setup hook.
   Common in middleware (rate limit buckets, session caches, connection pools).
5. **Mock chain coherence** — when mocking a pipeline (step A → step B → step C), mock return values must form a coherent data chain. An always-empty mock at step N makes step N+1's CalledWith assertion meaningless. Mock step A to return realistic data that step B would actually process.
6. **Dedup/merge assertion identity** — when testing dedup or merge logic, assert WHICH item survived (by identity: ID, content, or distinguishing field), not just the count. Count-only assertions pass even if the wrong item survived.
7. **Filtered last-call for accumulating mocks** — when a mock is called many times in a loop, a broad CalledWith matches ANY call. For tier/escalation tests, filter by key and assert the LAST call.
