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

**If reaching for a blocked pattern:** wrong testability decision. Go back to testability classification (in `test-code-types.md`) and choose NEEDS_INTEGRATION.
