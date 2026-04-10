# Test Code-Type Classification — Core

> 11 code types for production file classification. Drives minimum test count, required patterns, and mock strategy.
> Stack-specific templates are in `test-code-types-js.md` and `test-code-types-php.md`.

## Pre-Test Meta-Check: Is Production Code Correct?

Before writing exhaustive tests, ask:
1. **Dead code?** — defensive checks under guarantees that prevent them from firing (e.g., post-check under atomic execution). If found: flag with `// CODE REVIEW: [rationale]`, don't write 200 lines testing unreachable paths.
2. **Contradictions between code and comments?** — comment says "atomic, no interleaving" but code checks for interleaving. Flag, don't silently test the contradiction.
3. **Input validation gaps?** — what happens with nil, 0, negative, wrong type? Flag if unhandled.
4. **Duplicate functions?** — single-item version that's a subset of multi-item version. Flag duplication.

**Do NOT silently test incorrect behavior — that legitimizes bugs.** One test flagging a problem is worth more than 50 tests covering it.

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

## Per-Code-Type Test Strategy

Each code type has specific things to test and a recommended mock strategy. This is NOT optional — use this table in Step 1 to plan tests.

| Code Type | What to test | Mock strategy | Key pattern |
|-----------|-------------|---------------|-------------|
| **ORCHESTRATOR** | Middleware ordering invariants, route mounting, auth boundaries (presence + order), path isolation | Mock route modules + external-dep middleware as pass-through. Keep pure middleware real. | Ordering log array (see stack-specific template) |
| **SERVICE** | Business logic branches, error paths, transaction boundaries, caller contracts, side-effect CalledWith | Mock external I/O only (DB, HTTP, email). Use real code for internal deps. | Test computed output, not mock echo. Side-effect CalledWith in every success test. |
| **CONTROLLER** | Input validation (400), auth (401/403), success (200/201), error shapes, security S1-S4 | Mock service layer. Real validation + guards. | Every endpoint × 4 (happy + auth + validation + error) |
| **PURE/VALIDATOR** | All branches, edge cases per parameter type, property-based tests | Zero mocks | State matrix: input combinations → expected outputs |
| **GUARD/MIDDLEWARE** | Request without header → expected behavior, wrong header → 4xx, correct header → next() called, ordering relative to other middleware | Mock downstream only | Positive AND negative assertions |
| **HOOK** | Return values, state transitions, side effects, cleanup | Mock external effects (fetch, timers) | Test lifecycle: mount → interact → verify → cleanup |
| **COMPONENT** | Render states (loading/error/empty/data), user flows (action → state → callback), a11y, dispatch/routing | Mock API calls. Real render. Mock child components with testid stubs for dispatch. | 30%+ must be flow tests, not just render. |
| **API-CALL** | Success + error + timeout, retry behavior, response parsing | Mock HTTP layer | Test transformed output, not raw response echo |
| **STATE-MACHINE** | All transitions, invalid transitions rejected, lifecycle flows, reset behavior | Zero or minimal mocks | Transition matrix: state × event → new state |
| **ORM/DB** | Query construction, empty results, constraint violations, transaction rollback | Real DB with transaction rollback, or mock query builder | Test query RESULTS not query SHAPE |

### Private Method Testing

Private/internal methods should be tested through the public API, not directly. Rules:

- **3+ branches in private method** → dedicate a `describe` block. Name it after the behavior, not the method: `describe('slug generation from name')` not `describe('generateSlug')`. Test through the public method that calls it.
- **1 branch in private method** → cover implicitly through caller tests. No separate describe needed.
- **Private method called by multiple public methods** → test the shared behavior once in its own describe, then verify each caller delegates correctly.

## Mixed Files

When a file combines types (e.g., a SERVICE with PURE helper functions inside it), apply both classifications. Sum the minimum test counts.

## PURE_EXTRACTABLE Detection

After classifying the file, scan for non-exported pure helper functions within non-pure files. Mark them for property-based testing. If 3+ such helpers exist, recommend extraction to a separate utils module.

## Complexity Classification

| Classification | Criteria | Test depth |
|---------------|----------|------------|
| THIN | Under 50 LOC, no owned branching, pure delegation | Wiring correctness + error propagation + default param delegation. Skip edge case checklist. 5-12 tests. |
| STANDARD | 50-200 LOC, moderate branching (3-10 branches) | Full edge case checklist per parameter. 15-40 tests. |
| COMPLEX | Over 200 LOC or more than 10 branches | Split test files by concern. Full coverage. 40-80 tests. |

### THIN Delegation Checklist

For THIN files (facades, wrappers, barrel services) where methods are single-line delegations:

1. **Per-method delegation test:** verify correct args passed to delegate + return value forwarded unchanged
2. **Default parameter tests:** for each method with default parameters, call WITHOUT the defaulted arg and assert the default was forwarded.
3. **One error propagation test:** verify delegate rejection propagates unchanged (one representative test is sufficient)
4. **Cross-module isolation:** for key methods, assert unrelated delegates were NOT called

**Pass-through assertions:** For methods that return delegate results without transformation, use reference equality. This is NOT mock-echo — it verifies the contract "return exactly what the delegate gives." Combined with CalledWith on the delegate call, this is the strongest assertion for pure delegation.

**Bundling:** Bundled tests (multiple methods in one test) are acceptable for THIN delegation when each method is a single-line delegation. Split when any method has branching, defaults, or transformations.

**Re-exports:** Named re-exports are module system wiring, not behavior. Do NOT test them. Only test class methods or functions with owned logic.

**CRITICAL:** THIN complexity does NOT mean simple testing. A 67-line ORCHESTRATOR with 0 branches can have critical ordering invariants that require more test sophistication than a 200-line SERVICE with 10 branches.

## Testability Classification

| Classification | Signal | Strategy |
|---------------|--------|----------|
| UNIT_MOCKABLE | All deps injected, no static DB/ORM calls | Standard unit test with mocks |
| UNIT_REFLECTION | Protected/private properties, constructor does DI but also creates internal deps | Partial mock + disable constructor + inject via reflection |
| NEEDS_INTEGRATION | Static ORM calls, framework singletons, global state | Integration test with real DB — use project's DB test pattern |
| MIXED | Some methods unit-testable, some need DB | Split: unit tests for injectable methods, integration tests for static-call methods |

**Detection rules:**
- Static ORM/AR: `ClassName::findOne`, `::find`, `DB::table` → NEEDS_INTEGRATION
- Constructor injection with `$this->dep = $dep` → UNIT_MOCKABLE or UNIT_REFLECTION
- Both in same file → MIXED (decide per method)
