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

## ORCHESTRATOR / THIN Guidance

ORCHESTRATOR files (app.ts, server.ts, main.ts) that are THIN (pure wiring, no owned branching):
- **Mock ALL imports as pass-through.** Do not analyze transitive dependency chains.
- **Test what THIS file does:** route mounting, middleware wiring, health endpoints, CORS config.
- **Do not overthink mocking strategy.** If import has external deps (DB, auth, HTTP), mock the entire module. One-line pass-through mock is sufficient.
- **Keep tests focused:** verify routes are mounted at correct paths, middleware is applied to correct route groups, health check returns expected shape.

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
