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
| TYPE_CONTRACT | File emits NO runtime value: only `type` / `interface` / `declare` / `.d.ts` / `*.types.ts` | Per exported type: 1 minimal + 1 maximal construction, + 1 `@ts-expect-error` per illegal discriminant combination |

## TYPE_CONTRACT Test Strategy

A file that emits no runtime value has nothing to execute, so a runtime spec written against it can
only assert that a literal equals itself. Until 2026-08-19 there was no row for it in the table
above, so it fell through `ELSE → STANDARD` and got the runtime-spec template — producing suites
whose every assertion was a tautology and whose Q7/Q11 correctly scored 0.

**The output is `<name>.test-d.ts`, not `<name>.spec.ts`, and it contains ZERO runtime `expect`.**

### Validity precondition — state it or the suite means nothing

`expectTypeOf` and `@ts-expect-error` are erased by esbuild. They fail ONLY under
`vitest --typecheck` (or when the spec files are inside `tsc --noEmit`'s `include`). Without that,
a wrongly-typed literal transpiles happily and the suite is green **independently of the state of
the types**.

So before writing a single assertion:

```bash
# 1. Is a typecheck lane configured at all?
grep -r "typecheck" package.json vitest.config.* tsconfig*.json 2>/dev/null
# 2. Do the spec files actually enter it?
npx tsc --noEmit --listFiles 2>/dev/null | grep 'test-d'
```

Record the answer in the manifest as a blocking field, never as a footnote:

- `type_tests: ENFORCED (vitest --typecheck)` / `ENFORCED (tsc --noEmit includes *.test-d.ts)`
- `type_tests: NOT_ENFORCED` — then the suite is **decorative**, say so in the completion block and
  either wire the lane in this run or record it as the top backlog item. Do not report a green
  type suite that nothing runs.

### The six patterns, ordered by what actually occurs

Measured across 292 hand-written type files in two production repos (tgm-survey-platform, rs_be).
Cover them in this order — the frequency is the priority.

| # | Construct | Sites | Required assertions |
|---|---|---:|---|
| 1 | optional property (`x?: T`) | 2366 | **minimal + maximal construction per type.** Maximal alone is the single biggest blind spot: an object with every field set still compiles after `x?: T` becomes `x: T`, so optional→required drift is invisible. The minimal object — required fields only — is the assertion that catches it. |
| 2 | nullable (`\| null`) | 1209 | three distinct cases: `null`, `undefined`, and **absent**. They are different types and a `?: T \| null` accepts all three while `: T \| null` rejects two. Pin which. |
| 3 | `Record<K, V>` / index signature | 360 | one in-domain key, and `@ts-expect-error` on an out-of-domain key when `K` is a finite union. A `Record<string, …>` accepting anything is worth one line saying so, not four. |
| 4 | `readonly` property | 296 | `@ts-expect-error` on assignment. A readonly field with no rejection test is an unpinned promise. |
| 5 | function/method signature in a type | 259 | one call with correct args pinning the return via `expectTypeOf(...).returns`, plus `@ts-expect-error` on a wrong-arity or wrong-arg-type call. Parameter **contravariance** is where these break. |
| 6 | union of literals / discriminated union | 379 | see below — this is the one pattern that carries real weight. |

### The long tail — 11 of 299 sites, but each fails silently

Measured on the four heaviest hand-written type files (100 exported types): the six patterns above
cover 288 sites, these four cover the remaining 11. They are rare and each one is invisible when it
breaks, so they get an assertion whenever they appear — never a sampling rule.

| Construct | Sites | Required assertion |
|---|---:|---|
| `interface Child extends Parent` | 7 | `expectTypeOf<Child>().toMatchTypeOf<Parent>()` — plus an explicit pin on every field the child RE-DECLARES. A child that widens an inherited field still extends cleanly, so the relation holds while the contract has already drifted. |
| mapped type (`[K in Keys]`) | 2 | pin the produced key set: `expectTypeOf<keyof Mapped>().toEqualTypeOf<'a' \| 'b'>()`. A mapped type is a key transform; asserting a value's shape says nothing about which keys were produced. |
| `Omit` / `Pick` / `Partial` / `Required` | 1 | `@ts-expect-error` on the key that was supposed to be removed, and a positive construction proving a kept key survived. An `Omit<T, 'secret'>` that quietly stops omitting compiles everywhere. |
| generic with `extends` constraint | 1 | one instantiation INSIDE the bound, one `@ts-expect-error` outside it. A constraint with only in-bound instantiations is an unproven claim. |

Anything outside these ten patterns: name it in the manifest with the file and line rather than
covering it silently. An unlisted construct is a gap in this template, and the next run should widen
the table — not quietly skip the type.

### Discriminated unions — the pattern the rest should imitate

For every discriminated union, pin **the correlations, not the members**:

```ts
// Pin each variant's full shape by its discriminant. This forces a deliberate update when
// the contract changes, which is the entire point — a member list does not.
expectTypeOf<Extract<Presentation, { source: 'hb' }>['shareMethod']>().toEqualTypeOf<'hb_softmax'>()
expectTypeOf<Extract<Presentation, { status: 'unavailable' }>['metricKind']>().toEqualTypeOf<null>()

// Pin the FULL union of every constrained field, on EVERY variant that has one. A pin on
// Suppressed['suppressionReason'] while Unavailable['suppressionReason'] carries a different
// union and stays unpinned is the half-applied version of this pattern.
expectTypeOf<Suppressed['suppressionReason']>().toEqualTypeOf<'low_base' | 'quality_flag'>()

// …and prove the union REJECTS. Without these the suite proves the types are at least as
// permissive as the examples, never that they forbid an illegal state.
// @ts-expect-error status 'reportable' cannot carry a suppressionReason
const bad1: Presentation = { status: 'reportable', suppressionReason: 'low_base', … }
// @ts-expect-error 'hb' correlates with 'hb_softmax', never 'chrzan_orme'
const bad2: Presentation = { source: 'hb', shareMethod: 'chrzan_orme', … }
```

### Banned — assertions that cannot fail

- `expectTypeOf(x).toEqualTypeOf<typeof x>()` and `expectTypeOf(v.field).toEqualTypeOf<T['field']>()`
  where `v: T` — circular. A value declared as `T` has type `T`; the assertion restates its own
  premise.
- `expect(obj).toEqual({ …the same literal… })` in a type spec — a runtime tautology padding the
  assertion count.
- Any runtime `expect` at all in a `TYPE_CONTRACT` file. If a runtime assertion is genuinely
  needed, the file is not TYPE_CONTRACT — reclassify it.

### When to write NO type tests

If the file is a plain data shape with no union, no conditional, no generic constraint and no
public-API status, consumer compilation already enforces compatibility and a `.test-d.ts` adds
ceremony without coverage. Record `TYPE_CONTRACT: no-test (structural only, enforced by consumers)`
with that reason. This is a legitimate outcome, not a skipped one — the honest cases are the ones
above, not "every exported interface gets a file".

### One file per type module

Three spec files against one type module with duplicated fixtures is fragmentation, not coverage.
One `.test-d.ts` per type module; share fixtures within it.

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

### COMPONENT Callback Routing Guard

When a unit routes different handlers into the **same callback slot** depending on mode, type, or state (a "next" slot receiving a submit-all handler in one mode and a step-advance handler in another), label-only or presence-only tests are insufficient. (Framework-specific example in the JS template file.)

Add interaction tests that prove:
- the correct handler fires after the user action
- the competing handler does **not** fire
- visible state or feedback is asserted when the component owns it

One representative interaction test per distinct routing decision is the minimum. If the file has zero interaction tests, it does not satisfy the COMPONENT flow requirement.

### VALIDATOR Depth Requirements

For VALIDATOR files (validator/schema/dto, Joi/Zod/class-validator), the Fields × 3 formula expands to:

| Requirement | What to test |
|-------------|-------------|
| Each rule individually | One test per validation rule — not just "valid passes, invalid fails" |
| Error messages | Assert the specific error text, not just that it throws |
| Boundary values per field | Empty, null, undefined, min/max length, type mismatch, special chars |
| Multiple errors | Payload with 2+ invalid fields — verify ALL errors returned |
| Valid edge cases | Minimal valid payload, optional fields omitted, Unicode in strings |

Minimum for N fields: **N × 3 (valid + invalid + boundary) + 1 multi-error + 1 minimal-valid = N × 3 + 2**.

### Delegation and Inheritance (child/derived instances)

When production code creates child or derived instances (factory, `.child()`, `.clone()`, `new X(parentConfig)`):

| What to test | Rationale |
|-------------|-----------|
| Inherited properties | Child preserves parent configuration |
| Override behavior | Child overrides targeted values while the rest stays inherited |
| Isolation | Child changes must NOT propagate back to the parent |

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
