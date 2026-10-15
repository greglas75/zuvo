# Test Code-Type Classification — Core

> 11 code types for production file classification. Drives the test budget (an upper bound, never a quota), required patterns, and mock strategy.
> Stack-specific templates are in `test-code-types-js.md` and `test-code-types-php.md`.

## Worth Gate — does this file earn tests at all? (run FIRST, 2026-10-09)

A test earns its place only if it would catch a plausible defect. Every row of the TEST OUTLINE names
that defect (in the test name or a one-line comment); a row that cannot name one is dropped, not
padded. A project or user rule that narrows test scope (a user-level `test-scope.md` rule,
the project's rules directory, `AGENTS.md`) outranks every formula in this file.

**NO_BEHAVIOUR shapes → Tests = 0** (record `SKIPPED_NO_BEHAVIOUR` with the shape):

| Shape | Detection | Instead |
|-------|-----------|---------|
| Presentational component | props/state → markup only; no handlers beyond passing callbacks through, no effects, no data fetching; branching limited to `x ?? '—'` / rendering an already-decided value; or marked `// @presentational` | test the formatter/selector it calls, if that has logic |
| Server-rendered view | view/template/layout/partial/widget HTML (Yii `views/**`, Blade, Twig, Jinja, ERB, `Widget::run()` output, asset registration in a view) | business logic found inside (permission, status decision, calculation, which records count) → flag it for extraction to a model/service and test THERE; presentation logic stays untested |
| Wiring | DI/module registration, route tables, provider bindings without logic, re-exports | none — the first behaviour test through it proves it. Exception: where the container resolves lazily and nothing else resolves the binding, ONE canary resolving the ports (PHP DI-WIRING row) |
| Library-only DTO | only standard decorators/schema rules (`@IsString`, `required`, `max:255`) | test custom validators and cross-field rules only (then it is VALIDATOR) |
| Pure delegation | THIN facade whose methods forward args and results unchanged | covered by the callers' behaviour tests |
| Constants / enum lists | static maps, label tables | none — unless consumers rely on an invariant (uniqueness, lockstep): ORDERED-CONFIG family |

**Exception — contracts:** markup or payloads another system parses (bot `data-*` attributes, export
layouts, API response shapes, links/tokens in mail templates) are a contract and keep a test even on
an otherwise presentational/view file.

Why: an audit of one repo (2026-10-09) found test LOC at 1.75–2.4× source, ~400 mock-echo router and
controller tests, ~360 wiring tests and per-field render tests — each traced to the per-type minimum
formulas this file used to state as floors.

## Pre-Test Meta-Check: Is Production Code Correct?

Before writing exhaustive tests, ask:
1. **Dead code?** — defensive checks under guarantees that prevent them from firing (e.g., post-check under atomic execution). If found: flag with `// CODE REVIEW: [rationale]`, don't write 200 lines testing unreachable paths.
2. **Contradictions between code and comments?** — comment says "atomic, no interleaving" but code checks for interleaving. Flag, don't silently test the contradiction.
3. **Input validation gaps?** — what happens with nil, 0, negative, wrong type? Flag if unhandled.
4. **Duplicate functions?** — single-item version that's a subset of multi-item version. Flag duplication.

**Do NOT silently test incorrect behavior — that legitimizes bugs.** One test flagging a problem is worth more than 50 tests covering it.

## Classification Table

The last column is a CEILING for planning, not a minimum: write one test per distinct behaviour that
passes the Worth Gate, table-driven where cases share a shape, and stop. Never add tests to reach it.

| Code Type | Detection Signals | Test budget (upper bound) |
|-----------|------------------|-------------------|
| VALIDATOR | Declarative per-field constraints attached to a data shape — schema objects, decorator/annotation validators, typed DTOs with field rules (e.g. Zod, class-validator, Pydantic `BaseModel`+`@field_validator`, Python dataclass DTO) | Project-decided rules × 3 (valid + invalid + boundary); a standard decorator alone (`@IsString`, `max:255`) is 0 — see VALIDATOR Depth |
| SERVICE | Business-logic unit calling I/O collaborators (DB/HTTP/queue) through injected or imported deps — any framework or none (e.g. `@Injectable`, plain class, module of functions) | Methods × 3 |
| CONTROLLER | HTTP entrypoint mapping request→response — decorators OR file-convention handlers (e.g. Nest `@Get`, Next.js App Router `export function GET/POST` / `export const POST = wrap(...)`, FastAPI path functions, invokable PHP controllers) | Endpoints × 4 at most (happy + auth + validation + error — only the cases the endpoint has; a pass-through controller is 0) |
| HOOK | Reusable stateful frontend logic unit with lifecycle/effects (e.g. React `use*`, Vue composables) | States × 3 + lifecycle tests |
| PURE | No I/O, no side effects — transforms, formatters, calculators | Functions × 4 + property-based |
| COMPONENT | UI unit rendering from props/state with interaction handlers (e.g. React/Vue/Svelte component, Astro island) | Render states × 2 + interaction tests |
| GUARD | Allow/deny decision unit gating an operation — middleware guards, policy/permission functions; a precedence matrix or tenant filter also triggers the AUTH-BOUNDARY family below | Rules × 3 (allow + deny + edge) |
| API-CALL | Thin client wrapping an external service — HTTP/SDK/`fetch` wrapper owning timeout, retry and error mapping (incl. Web `fetch`+`AbortSignal`, circuit breakers) | Methods × 3 (success + error + timeout) |
| ORCHESTRATOR | Unit coordinating ordered steps/handlers — middleware mounting, saga/workflow, step-function definitions (e.g. Hono `app.use`, Inngest `createFunction`, BullMQ flows; framework templates live in the stack file) | Steps × 2 + full-flow integration |
| STATE-MACHINE | Finite states with transitions, event-driven reducers | Transitions × 2 + States × 1 + lifecycle flow |
| ORM/DB | Unit whose primary job is constructing/executing datastore queries — detected by query construction, not base class (repository classes, query builders, raw-SQL modules; Prisma/Mongo/AR/DBAL alike) | Queries × 3 (success + empty + constraint violation) |
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
  either wire the lane in this run or record it as a process item with `~/.zuvo/backlog-add --repo "$R" --class PROCESS --conf 90 --source <skill> --target subject:<skill>-type-tests-not-enforced --title "$T" --evidence "$E"` (`backlog-protocol.md` "Filing from a skill", **Process item**; `<skill>` is the calling skill, `T` is the fixed title "type tests are not enforced by any lane", the same words on every run so a repeat only bumps `seen`, and `E` names the package and the observed state (which lane is missing); assign `"$R"`, `"$T"` and `"$E"` before the call, as "Free text goes through a variable" in that section says; an empty value is a bug, and `backlog-add` refuses a missing required field (`REFUSED missing-field:<f>`); name its F-id in the completion block). Do not report a green
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

## Cross-Cutting Families — check AFTER the code-type match

A file carries ONE code type and ZERO OR MORE families. A family match APPENDS mandatory
contract rows; it never changes the tier. Print `[FAMILY] {file}: +{NAMES}` and record
`"families": [...]` in the manifest. These six families cover the failure modes that generic
type templates provably miss (fleet audit 2026-08-19: a 1344-line suite passing every generic
gate coexisted with a live double-payment path).

| Family | Detection shape | Mandatory contract rows |
|--------|-----------------|-------------------------|
| SIDE-EFFECT-BOUNDARY | External effect (payment, email, queue publish, outbound webhook) followed by a local state write; OR consumption from queue/webhook/outbox | (1) idempotency key is a pure function of the domain id — call twice, assert same key; (2) effect SUCCEEDS then the subsequent write THROWS → state must NOT become retry-eligible or 'failed' (distinct `*_unconfirmed` state or equivalent); (3) concurrent pickup: exactly one executes — promise-race or two-connection test, mirroring whichever pattern the repo already uses; (4) duplicate delivery is a no-op |
| SCHEDULED-EXECUTION | Cadence predicate (`getUTCMinutes() === 5`, cron gate) or tick/backoff loop | cadence boundary at N-1 / N / N+1 under fake time; a skipped or failed tick does NOT wedge the next; 'ran' is observable independently of 'no-op because nothing to do'; backoff state machine gets a transition matrix |
| AUTH-BOUNDARY | Tenant/org filter injected into queries; role×resource precedence matrix; delegation checks | cross-tenant read returns EMPTY (not error, not data); read-path filter and write-path authorization enforce the SAME boundary (one test proving agreement); precedence ORDER itself (incl. admin vs explicit deny — an intentional test either way); default-deny for an unknown principal/resource; tenant id parameter that is OPTIONAL on a tenant-scoped method = Step 1.5 Bug Scan finding, not a test to write around |
| UNTRUSTED-DATA | File export, file upload, inbound webhook/email ingestion | export: spreadsheet formula-injection neutralization (`=cmd\|...`) + row-limit rejection; upload: size/type boundary + requester binding; ingestion: dedup by message id + fire-and-forget dispatch ASSERTED on args, not completion |
| ORDERED-CONFIG | First-match arrays (`config.find(...)`), module-level config tables/exported constants | value matched by 2+ entries → FIRST wins; REVERSED array must change the result; past-last-entry returns the documented default; config tables: independent expected-oracle, `Object.isFrozen`, lockstep of derived exports, uniqueness |
| PROBABILISTIC-CONSUMER | Consumes model/scorer output (LLM client, ML endpoint, vector search) | parser/threshold/routing tested against CANNED responses — exact-value asserts on a mocked model ARE correct here (explicit P-70 exception #2 in test-contract.md); with a real model only shape/range/length (`0<=score<=1`, `len(out)==len(in)`), never exact floats; golden fixture + env-gated live probe; NEVER load a real checkpoint in unit tests; vector search: below-threshold dropped, descending order, topK, filters — never assert embedding semantics |

## Per-Code-Type Test Strategy

Each code type has specific things to test and a recommended mock strategy. This is NOT optional — use this table in Step 1 to plan tests.

| Code Type | What to test | Mock strategy | Key pattern |
|-----------|-------------|---------------|-------------|
| **ORCHESTRATOR** | Middleware ordering invariants, route mounting, auth boundaries (presence + order), path isolation | Mock route modules + external-dep middleware as pass-through. Keep pure middleware real. | Ordering log array (see stack-specific template) |
| **SERVICE** | Business logic branches, error paths, transaction boundaries, caller contracts, state-changing side effects | Mock external I/O only (DB, HTTP, email). Use real code for internal deps. Behaviour that depends on SQL semantics (tenant `where`, transactions, unique, cascade) → integration test on a real DB; a mocked `$transaction` proves nothing. | Test computed output, not mock echo. CalledWith only for state-changing effects (send, charge, enqueue, write) — never for reads. |
| **CONTROLLER** | Input validation (400), auth (401/403), success (200/201), error shapes, security S1-S4 | Mock service layer. Real validation + guards. | Up to endpoint × 4 (happy + auth + validation + error), only the cases the endpoint actually has |
| **PURE/VALIDATOR** | All branches, edge cases per parameter type, property-based tests | Zero mocks | State matrix: input combinations → expected outputs |
| **GUARD/MIDDLEWARE** | Request without header → expected behavior, wrong header → 4xx, correct header → next() called, ordering relative to other middleware | Mock downstream only | Positive AND negative assertions |
| **HOOK** | Return values, state transitions, side effects, cleanup | Mock external effects (fetch, timers) | Test lifecycle: mount → interact → verify → cleanup |
| **COMPONENT** | Render states the component itself decides (loading/error/empty/data), user flows (action → state → callback), a11y, dispatch/routing | Mock the network once, not each hook. Real render, real store. Mock child components with testid stubs only for dispatch. | Presentational → Worth Gate, 0 tests. No "renders"/"exists" tests, no one-test-per-displayed-field; a calculation needing >3 cases → extract a pure function and table-test it. |
| **API-CALL** | Success + error + timeout, retry behavior, response parsing | Mock HTTP layer | Test transformed output, not raw response echo |
| **STATE-MACHINE** | All transitions, invalid transitions rejected, lifecycle flows, reset behavior | Zero or minimal mocks | Transition matrix: state × event → new state |
| **ORM/DB** | Query construction, empty results, constraint violations, transaction rollback | Real DB with transaction rollback. A mocked query builder only for query-construction logic that does not depend on SQL semantics (where/tenant scope, unique, cascade need the real DB) | Test query RESULTS not query SHAPE |

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

One representative interaction test per distinct routing decision is the minimum. A file that owns such a decision and has zero interaction tests does not satisfy the COMPONENT flow requirement; a component that only passes callbacks through unchanged owns none (Worth Gate: NO_BEHAVIOUR).

### VALIDATOR Depth Requirements

For VALIDATOR files (validator/schema/dto, Joi/Zod/class-validator), test what the PROJECT decided,
not what the library guarantees:

| Requirement | What to test |
|-------------|-------------|
| Custom validators and cross-field rules | One case per rule outcome (pass, fail, boundary) |
| Business limits | Boundaries the domain chose (max 255 answers, date not in the past) — one table |
| Error messages | Only when a consumer depends on the text (UI shows it, API contract) |
| Valid edge cases | One minimal valid payload |

Do NOT test one case per standard decorator (`@IsString`, `@IsUUID`, `required`) — that is the
library's own suite. Budget for N fields: one table over the project-decided rules + 1 minimal-valid;
a DTO with only standard rules is NO_BEHAVIOUR (Worth Gate).

### Delegation and Inheritance (child/derived instances)

When production code creates child or derived instances (factory, `.child()`, `.clone()`, `new X(parentConfig)`):

| What to test | Rationale |
|-------------|-----------|
| Inherited properties | Child preserves parent configuration |
| Override behavior | Child overrides targeted values while the rest stays inherited |
| Isolation | Child changes must NOT propagate back to the parent |

## Mixed Files

When a file combines types (e.g., a SERVICE with PURE helper functions inside it), apply both classifications. Plan behaviours for each part; the budgets are ceilings, so their sum is a ceiling too.

## PURE_EXTRACTABLE Detection

After classifying the file, scan for non-exported pure helper functions within non-pure files. Mark them for property-based testing. If 3+ such helpers exist, recommend extraction to a separate utils module.

## Complexity Classification

| Classification | Criteria | Test depth |
|---------------|----------|------------|
| THIN | Under 50 LOC, no owned branching, pure delegation | Only what the file owns: defaults, argument mapping, error translation. Pure forwarding → 0 tests (Worth Gate). Typically 0-3 tests. |
| STANDARD | 50-200 LOC, moderate branching (3-10 branches) | One test per distinct behaviour; edge cases as one table per parameter that has real boundaries. |
| COMPLEX | Over 200 LOC or more than 10 branches | Split test files by concern; one test per distinct behaviour, table-driven. Test LOC above ~1.5× the source covered is a smell — prune before adding. |

### THIN Delegation Checklist

For THIN files (facades, wrappers, barrel services) test ONLY what the facade adds:

1. **Default parameters it fills in:** call WITHOUT the defaulted arg and assert the default reached the delegate.
2. **Argument/result mapping it performs:** assert the transformed value.
3. **Error translation it performs:** one test per translated error type.

A method that forwards args and returns the delegate's result unchanged gets NO test: per-method
"called with X, returns what the mock returned" tests are mock-echo — they fail only when the file is
refactored and never when behaviour breaks. The callers' behaviour tests already pass through it.

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
