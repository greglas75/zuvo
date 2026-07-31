# Test Writing Blocklist

> Patterns that MUST NOT appear in written tests. If you catch yourself reaching for one, STOP and reconsider testability classification.

| Blocked Pattern | Why | Do Instead |
|----------------|-----|------------|
| `assertIsBool` / `assertIsInt` / `assertIsString` as sole assertion | Tests TYPE not VALUE — accepts both correct and wrong results | `assertEquals`/`assertFalse`/`assertTrue` with specific expected value |
| `assertInstanceOf` as sole assertion (except factory/DI tests) | Existence test, not behavior | Test a method call and verify its output |
| `markTestSkipped('Requires database')` + no real assertion | Stub test, inflates coverage with zero value | Write integration test with transaction rollback, or skip file + backlog item |
| `assertTrue(true)` as primary assertion | Always-true, passes regardless of production behavior | Let test pass naturally (no exception = pass) or use `expectNotToPerformAssertions()` |
| TODO comment as test body ("With DB fixtures: create X, verify Y") | Recipe, not a test | Write the actual test or add backlog item |
| Testing a different class than the test file name | `FooServiceTest` testing `BarHelper` constants | Create `BarHelperTest` for BarHelper |
| `canConnectToDb()` guard wrapping most tests | Mixing unit and integration | Choose one strategy per file |
| `if (condition) { expect(...) }` / ternary expect | Assertion silently skipped when condition is false — test is green but verifies nothing | Assert precondition first (`expect(condition).toBe(true)`), then assert outcome unconditionally. Or use separate tests for each branch. |

## Typed mock gate (JS/TS)

Untyped mocks compile against ANY production refactor — they keep passing when
the real service signature changes, which is exactly when tests should fail.

| Blocked Pattern | Why | Do Instead |
|----------------|-----|------------|
| `Record<string, jest.Mock>` / `Record<string, vi.Mock>` as a service mock | Erases the service's method names AND signatures — a renamed method never fails the test | Typed subset: `Pick<RespondentService, 'findOne' \| 'create'>` or a `MockedMethods<T, K>` helper |
| `as never` on a mock or argument | Silences every type error the compiler would have caught | Fix the mock's type; if the cast feels necessary, the mock shape is wrong |
| Broad `as any` on a mock object or domain argument | Same signature-blindness as `Record<string, Mock>` | `as unknown as Pick<T, ...>` at most, scoped to one property with a comment |
| Mock defined but never asserted or consumed | Dead setup — implies coverage that doesn't exist and hides which collaborators matter | Delete it, or assert on it (`toHaveBeenCalledWith`) |
| `expect.anything()` on a DOMAIN argument (id, payload, entity) | Accepts every wrong value — the delegation contract is untested | Assert the concrete value or a typed `expect.objectContaining({...})` with the domain fields |

`expect.anything()` remains acceptable for genuinely incidental arguments
(loggers, abort signals, framework-injected context) — name the reason in the
test when used.

**If reaching for a blocked pattern:** wrong testability decision. Go back to testability classification (in `test-code-types-core.md`) and choose NEEDS_INTEGRATION.
