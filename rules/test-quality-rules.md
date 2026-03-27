# Test Quality Standards

Applies to every test-writing workflow. Read before producing any test. Companion to `testing.md` Q1-Q17 evaluation.

---

## Edge Case Checklist (mandatory)

For every parameter a method accepts, identify its type from the table below and write tests for the listed edge cases:

| Input type | Edge cases to test | Example assertion |
|------------|-------------------|-------------------|
| **string** | `null`, `undefined`, `''` (empty), `' '` (whitespace only), very long (`'a'.repeat(10000)`), Unicode (`'日本語'`), special chars (`'<script>alert(1)</script>'`) | `expect(fn('')).toThrow()` or verify fallback behavior |
| **number** | `null`, `undefined`, `0`, `-1`, `NaN`, `Infinity`, `Number.MAX_SAFE_INTEGER`, float where int expected (`3.14`) | `expect(fn(NaN)).toThrow()` |
| **array** | `null`, `undefined`, `[]` (empty), single element `[x]`, very large array, duplicate elements | `expect(fn([])).toEqual([])` or verify empty handling |
| **object** | `null`, `undefined`, `{}` (empty), missing required keys, extra unknown keys, nested null (`{ meta: null }`) | `expect(fn({ meta: null })).not.toThrow()` |
| **boolean** | explicit `false` (not just truthy/falsy check), `undefined` vs `false` distinction | `expect(fn(false)).toBe(X)` — not same as `fn(undefined)` |
| **Date** | `null`, invalid date (`new Date('invalid')`), epoch (`new Date(0)`), far future | `expect(fn(new Date('invalid'))).toThrow()` |
| **optional param** | omitted entirely vs passed as `undefined` vs passed as `null` — verify all three behave correctly | `fn()` vs `fn(undefined)` vs `fn(null)` |
| **enum/union** | every member of the union, plus an invalid value not in the union | `expect(fn('INVALID_STATUS')).toThrow()` |
| **enum x enum (matrix)** | When two enum/union params interact, test the full cross-product or at minimum: all diagonal + boundary transitions. Use `it.each` with table. | `it.each([['warn','info',false], ['warn','warn',true], ['warn','error',true]])('level %s filters %s → %s', ...)` |
| **events (listener/handler)** | Concurrent dispatch (2+ events in same tick), out-of-order delivery, duplicate event, event during teardown, rapid-fire same event | `handler(eventA); handler(eventB); expect(state).toBeConsistent()` |
| **time-dependent** | `Date.now()`, `setTimeout`, `setInterval`, `performance.now()`, debounce, throttle. Must use `vi.useFakeTimers()`. Test at exact threshold, at threshold-1 (should NOT trigger), and at threshold+1 (should trigger). Never rely on real clock. | `vi.advanceTimersByTime(DEBOUNCE_MS - 1); expect(cb).not.toHaveBeenCalled(); vi.advanceTimersByTime(1); expect(cb).toHaveBeenCalled();` |

**Application procedure:** List each method's parameters. Find each parameter's type in the table. Write at minimum the null/undefined/empty test. Add boundary tests where the method has conditional logic depending on that parameter.

**Efficient handling for many parameters:** Use a factory pattern. Test one edge case per `it()`, overriding one field:
```typescript
it('handles null userComment', () => {
  expect(fn(createInput({ userComment: null }))).toBe(expectedFallback);
});
```

**When edge cases may be skipped:** THIN wrappers (under 50 LOC, pure delegation, no owned branching) — test wiring and error propagation only. The full checklist applies to STANDARD and COMPLEX files.

**Frequently missed edge cases:**
- `null` in nested objects (`{ metadata: { category: null } }` vs `{ metadata: null }`)
- Empty string vs null (they are different — test both)
- Optional field omitted vs explicitly `undefined`
- Single-element array (off-by-one in `.length` checks)
- Mock returning `[]` or `null` instead of expected data (tests the caller's null handling)
- **Hardcoded production lists** (allowlists, PII keys, status enums, level maps) — extract and test every member. 4 of 5 = incomplete.
- **Enum x enum interactions** — when two enum parameters control behavior, test the cross-product, not just the happy path

---

## Validator / Schema / DTO Depth

When the code type is VALIDATOR (files containing `validator`, `schema`, `dto`, or Joi/Zod/class-validator schemas):

| Requirement | What to test | Example |
|-------------|-------------|---------|
| **Each rule individually** | One `it()` per validation rule — not just "valid passes, invalid fails" | `it('should reject email without @')` |
| **Error messages** | Assert specific error text, not just that it throws | `expect(error.message).toContain('must be a valid email')` |
| **Boundary values per field** | Empty string, null, undefined, min length, max length, type mismatch, special chars | `makePayload({ email: '' })` |
| **Multiple errors** | Payload with 2+ invalid fields — verify all errors returned | `expect(error.details).toHaveLength(2)` |
| **Valid edge cases** | Minimum valid payload, optional fields omitted, Unicode in string fields | `makePayload({ name: '日本語テスト' })` |

Minimum test count for a validator with N fields: **N x 3** (valid + invalid + boundary per field) + 1 multi-error + 1 minimal valid = **N x 3 + 2**.

---

## Delegation and Inheritance Testing

When production code creates child or derived instances (factory, `.child()`, `.clone()`, `new X(parentConfig)`):

| What to test | Rationale | Example |
|-------------|-----------|---------|
| **Inherited properties** | Child must preserve parent configuration | `expect(child.level).toBe(parent.level)` |
| **Override behavior** | Child context overrides targeted parent values | `expect(child.module).toBe('childModule')` while `child.service === parent.service` |
| **Isolation** | Child changes must not propagate to parent | After `child.setLevel('debug')`, `expect(parent.level).toBe('info')` |

---

## Real Code First (check before writing any mock)

Tests with real code catch real bugs. Tests with mocks catch mock configuration bugs. Always verify whether you can avoid the mock.

**Decision tree for each dependency:**

```
Can I instantiate this dependency with `new Foo()` or a factory?
  └─ YES → Does it have external side effects (HTTP, DB, filesystem, email)?
      └─ NO → USE REAL IMPLEMENTATION. No mock needed.
      └─ YES → Can I swap the external part with an in-memory/fake alternative?
          └─ YES → Real impl + fake boundary (e.g., InMemoryRepo, FakeEmailSender)
          └─ NO → Mock ONLY the external boundary (vi.fn / jest.fn)
  └─ NO (framework creates it, DI container) → Mock with typed partial, prefer TestingModule with real providers where possible
```

**Warning signs of over-mocking:**
- Mock object has 5+ method stubs → use the real class
- Mock setup is longer than the test itself → use real implementation
- You need `as unknown as FooService` → the mock is incomplete
- You mock a pure function (no I/O) → always use the real function
- You mock a data transformer/mapper → always use real one

**NestJS/DI-heavy projects:** Use `TestingModule` with real providers. Override only external boundaries:
```typescript
// GOOD
const module = await Test.createTestingModule({
  providers: [
    UserService,           // real
    UserRepository,        // real (in-memory or test DB)
    { provide: HttpService, useValue: { get: vi.fn() } },  // mock only external
  ],
}).compile();

// BAD — everything mocked, no real logic exercised
const module = await Test.createTestingModule({
  providers: [
    UserService,
    { provide: UserRepository, useValue: { find: vi.fn(), save: vi.fn() } },
    { provide: HttpService, useValue: { get: vi.fn() } },
  ],
}).compile();
```

**React components:** Render with real child components. Mock only API calls (MSW) and external services. Never mock React hooks from the same project.

---

## Mock Safety

For each mock in the test plan, verify it produces values the production code can actually consume:

| Hazard | Broken mock | Correct mock |
|--------|------------|--------------|
| `AsyncGenerator` / `async function*` | `vi.fn()` — returns undefined, iteration hangs | `vi.fn().mockImplementation(async function*() { yield chunk; })` |
| `for await (const chunk of stream)` | mock that is not async iterable | must implement `Symbol.asyncIterator` |
| `stream.pipe(writer)` | no-op mock — writer never emits `finish` | `writer.on = vi.fn((event, cb) => event === 'finish' && cb())` or PassThrough stream |
| `EventEmitter.on('data')` / `.on('end')` | `vi.fn()` — callbacks never called | mock EventEmitter with `.emit('data', chunk)` + `.emit('end')` |
| Promise from `new Promise(resolve => stream.on('finish', resolve))` | stream mock never emits `finish` | mock stream as PassThrough or manually call finish handler |

**Verification:** trace the mock mentally — does it return something the production code can iterate, await, or subscribe to? If not, the test will hang silently.

---

## Mental Mutation Check (mandatory after writing tests)

After writing tests for a function, apply these 5 mutations mentally. For each: "Would any test detect this change?"

| # | Mutation | Verification |
|---|---------|--------------|
| M1 | **Negate main condition** (`if (x > 0)` → `if (x <= 0)`) | Both branches must have a test |
| M2 | **Remove null guard** (`if (!input) return default`) | A test must pass `null` and verify the default |
| M3 | **Swap operator** (`>=` → `>`, `&&` → `\|\|`) | A boundary value test must fail on the wrong operator |
| M4 | **Remove or change return value** | An assertion must verify the specific return |
| M5 | **Change error message/type** | An error path test must assert the specific message |

If any mutation would pass undetected, add a test before proceeding. This is a zero-tooling alternative to mutation testing frameworks.

---

## Oracle Independence

For every assertion, record where the expected value came from:

| Source | Quality | Action |
|--------|---------|--------|
| Spec/documentation/requirements | Best | No action needed |
| Manual calculation from business rules | Good | No action needed |
| Known reference data (fixtures from real data) | Good | No action needed |
| Inverse operation (`decode(encode(x)) === x`) | Good | No action needed |
| Reading implementation and mirroring its logic | Acceptable but weak | Mark as structural oracle — consider adding a property or reference check |
| Copy-pasting implementation logic into assertion | **Reject** | Tautological test (P-70) — rewrite with independent expected value |

**Gate:** If more than 30% of assertions derive expected values by copying implementation logic, the test suite is tautological and cannot catch bugs where the implementation itself is wrong.

### Dual-Oracle Verification

For non-trivial computations (financial, algorithmic, data transformation), derive the expected value from 2 independent sources. Agreement = high confidence. Disagreement = flag for review.

| Oracle 1 | Oracle 2 | Agreement | Action |
|----------|----------|-----------|--------|
| Spec/requirements | Manual calculation | Match | Write assertion confidently |
| Manual calculation | Reference dataset | Match | Write assertion confidently |
| Spec says X | Manual calc gives Y | **Mismatch** | Flag: `// TODO: spec says X but calculation gives Y — verify` |
| Only 1 source available | — | N/A | Single oracle with comment: `// Oracle: [source]` |

**When to use dual-oracle:**
- Financial/pricing calculations (CQ16 domain) — always
- Complex transformations with 2+ operations — always
- Simple getters, formatters, boolean checks — single oracle is sufficient

```typescript
// GOOD — dual-oracle verified:
// Oracle 1: pricing spec says "10% tax on subtotal"
// Oracle 2: manual calc: 100 * 2 = 200, * 1.1 = 220
expect(calcTotal(100, 2)).toBe(220);

// FLAGGED — mismatch:
// Oracle 1: spec says "round to nearest cent" → 33.33
// Oracle 2: manual calc with banker's rounding → 33.34
// REVIEW: dual-oracle mismatch — verify rounding rule
expect(splitBill(100, 3)).toBe(33.33); // pending confirmation
```

---

## Assertion Strength Classifier

Rate each assertion by its detection power:

| Level | Category | Example | Catches |
|-------|----------|---------|---------|
| 1 (trivial) | Existence | `toBeDefined()`, `toBeTruthy()` | Almost nothing |
| 2 (structural) | Shape | `toHaveLength(3)`, `toHaveProperty('id')` | Shape changes only |
| 3 (value) | Exact value | `toEqual(expected)`, `toBe(42)` | Value changes |
| 4 (behavioral) | Interaction | `toHaveBeenCalledWith(exact_args)` | Interaction changes |
| 5 (semantic) | Computed output | Verifies output differs from input, tests transformation logic | Logic errors |

**Gate:** At least 60% of assertions in a test file must be level 3 or higher. A majority of level 1-2 assertions provides false confidence.

---

## Self-Eval Evidence Requirements

Score inflation is the top quality problem. Agents score 17/17 when the real score is 8/17. Every critical gate scored as 1 must include a proof line. Without proof, score 0.

| Q | Proof required |
|---|---------------|
| **Q7** | Name the `it()` block testing an error/rejection path. Quote the assertion. |
| **Q11** | Enumerate ALL conditional branches in the production code. For each branch, name the test exercising it. Any branch without a test → Q11=0. |
| **Q15** | Count assertions by type: (a) value assertions (`toEqual`, `toBe`, `toContain` with specific values), (b) weak assertions (`toBeDefined`, `toBeTruthy`, `typeof`, `toHaveBeenCalled` without args). If weak exceeds 50% of total → Q15=0. Use the Assertion Strength Classifier: 60%+ level 3 or higher required. |
| **Q17** | For each key assertion: "Does this verify something the CODE COMPUTED, or something I SET UP?" If the expected value comes from mock/fixture setup rather than production code computation, that assertion is echo. If echo exceeds 50% → Q17=0. Apply Oracle Independence Check. |

---

## Auto-Fail Patterns

If any of these appear in the test file, the corresponding Q gate scores 0 with no exceptions. These patterns must be removed or replaced with behavioral assertions.

| Pattern | Auto-fails | Reason |
|---------|-----------|--------|
| `typeof x === 'function'` appears 3+ times | Q15 | Tests interface shape, not behavior |
| `toBeDefined()` is the sole assertion in an `it()` block | Q15 | Proves existence, not correctness |
| `expect(screen).toBeDefined()` | Q15, Q17 | Screen is always defined — tests nothing |
| No test calls the function with invalid/error input | Q7 | No error path coverage |
| Production code has `if`/`switch` but no test varies that parameter | Q11 | Untested branch |
| All `toHaveBeenCalledWith` args are literals from mock setup | Q17 | Echo, not computed verification |
| `expect(spy).toHaveBeenCalled()` without `CalledWith` checking args | Q15 | Proves call happened, not correctness |
| Assertion expected value is copy-paste of implementation logic | Q17 | Tautological oracle (P-70) |

---

## Time-Dependent Code (mandatory when production uses Date.now / setTimeout / setInterval / performance.now)

When production code uses time-based logic (debounce, throttle, intervals, timestamps, cooldowns, burst detection), tests must control time explicitly. Applies to all code types.

**Setup:**
```typescript
beforeEach(() => { vi.useFakeTimers(); });
afterEach(() => { vi.useRealTimers(); });
```

**Patterns:**

| Production pattern | Test approach | Example |
|-------------------|---------------|---------|
| `setTimeout` / debounce / throttle | `vi.advanceTimersByTime(ms)` + assert callback fired/not fired | `vi.advanceTimersByTime(DEBOUNCE_MS); expect(callback).toHaveBeenCalled();` |
| `Date.now()` comparison (elapsed time, cooldowns) | `vi.setSystemTime(base)` → act → `vi.setSystemTime(base + delta)` → assert | `vi.setSystemTime(1000); detector.onKey(); vi.setSystemTime(1050); detector.onKey(); expect(intervals).toEqual([50]);` |
| `setInterval` (periodic checks) | Advance by interval x N, assert N invocations | `vi.advanceTimersByTime(interval * 3); expect(check).toHaveBeenCalledTimes(3);` |
| `performance.now()` for timing | Spy on `performance.now` with controlled return values | `vi.spyOn(performance, 'now').mockReturnValueOnce(0).mockReturnValueOnce(50);` |
| Timestamp recording in state | Set system time → trigger event → assert recorded timestamp matches | `vi.setSystemTime(12345); handler(event); expect(state.lastEventTime).toBe(12345);` |
| Burst/rate detection (N events in T ms) | Set time, fire N events advancing time between each, verify detection | Fire 10 events at 10ms intervals → assert burst detected at threshold |

**Never rely on real time passing.** If a test uses `await new Promise(r => setTimeout(r, 100))` to "wait for debounce" — replace with `vi.advanceTimersByTime(100)`.

**Common miss:** production code uses `Date.now()` for deltas but tests use real time. Passes locally but is flaky in CI. Always grep for `Date.now`, `performance.now`, `setTimeout`, `setInterval` in the production file and use fake timers if any are found.
