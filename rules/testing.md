# Test Requirements

Mandatory testing standards for all projects and stacks. Applies to Jest, Vitest, pytest, Playwright, and equivalent runners.

---

## Foundational Rule: Code Ships With Tests

No exceptions. No deferring. No commits of new code without corresponding test coverage.

### Hard Gate (non-negotiable)

Every implementation that produces new production files MUST include tests as part of the deliverable.

**Prohibited behaviors (each is a rule violation):**
- Asking whether tests should be written — the answer is always yes
- Claiming "no new regressions" as a replacement for writing tests
- Treating tests as optional, separate, or user-requested
- Finishing with zero test files when production files were created
- Offering test writing as a follow-up step

**Verification before completing any task:**
```
Count new/modified production files (.ts/.tsx/.py/.php): N
Count new/modified test files: T
If N > 0 and T = 0 → STOP. Write tests before declaring completion.
```

**The workflow is: implement → write tests → verify green → finish.**

## Planning: Test Strategy Section

When formulating a plan, it MUST include a Test Strategy containing:

1. **Code types** being added or changed
2. **Key patterns** to apply (G-/P- IDs from pattern lookup)
3. **Test files** to create or modify (paths and scope)
4. **Critical scenarios** (error paths, edge cases, infra failures)
5. **Self-eval target**: minimum 14/17

A plan without a Test Strategy is incomplete.

## Required Tests by Code Type

### Function / Utility
- Happy path
- Error and exception cases
- Edge cases (null, undefined, empty, boundary values)

### React Component
- Renders without error
- **User flow tests** — for each interactive element, test the full cycle: user action → state change → callback or API call with correct arguments → success/error feedback. "Button visible" alone is not a flow test.
- Props and state variations
- Error state rendering
- Accessibility: ARIA labels on interactive elements, keyboard navigation
- **Gate: flow tests must comprise at least 30% of all tests.** A rendering-only suite provides zero regression safety.

### API Endpoint / Handler
- Success response (200/201)
- Error responses (400, 401, 403, 404, 500)
- Input validation (invalid and missing fields)
- Auth and authorization verification

### Hook
- Behavior: returns expected values
- State transitions: updates correctly
- Side effects: API calls, timers

### API Endpoint — Security Tests

Every backend endpoint requires these in addition to functional tests:

| # | Test | Expected |
|---|------|----------|
| S1 | Invalid schema (missing/malformed fields) | 400 + validation error |
| S2 | No auth token/cookie | 401 |
| S3 | Wrong role | 403 + `service.not.toHaveBeenCalled()` |
| S4 | Wrong tenant (different orgId/ownerId) | 403 + `service.not.toHaveBeenCalled()` + no data leak |
| S5 | Rate limit on auth endpoints | 429 after threshold |
| S6 | XSS in HTML render paths (if applicable) | Sanitized output |
| S7 | Path/ID traversal (if applicable) | 400 or 403 |

S5-S7 may be skipped when not applicable. S1-S4 are mandatory.

## Required Tests by Change Intent

| Intent | Tests Required |
|--------|---------------|
| BUGFIX | 1 regression test (reproducing the bug) + 1 happy path |
| FEATURE | Unit tests for edges and errors, plus 1 integration test |
| REFACTOR | All existing tests must pass (before = after) |
| INFRA | Smoke test + config validation |

## Test Distribution Targets

```
     /\       E2E Tests (5-10%) — critical user flows only
    /  \
   /____\     Integration Tests (30%) — component interactions
  /      \
 /________\   Unit Tests (60%) — utils, hooks, business logic
```

## File and Structure Conventions

### Naming
```
ComponentName.test.tsx         # React components
function-name.test.ts          # TypeScript functions
test_function_name.py          # Python (pytest)
feature-name.spec.ts           # Playwright E2E
```

### Placement
- Co-located preferred: `Component.tsx` alongside `Component.test.tsx`
- Alternatively in `__tests__/` next to source

### Organization
- One describe block per function or component
- Descriptive test names: `it("should return empty array when no results found")`
- Arrange-Act-Assert structure
- No test logic inside describe blocks (only in it/test)

## Favoring Real Implementations Over Mocks

**Default: use real code. Mock only when forced by external I/O.**

Before writing any mock, ask: "Can I use the real implementation?" Tests with real code find real bugs. Tests with mocks find mock configuration bugs.

**Priority ladder (prefer higher, fall back down):**

| Priority | Approach | When to use | Example |
|----------|----------|-------------|---------|
| 1 (best) | **Real implementation** | No external side effects | `new UserService(new InMemoryUserRepo())` |
| 2 | **Real impl + controlled inputs** | Needs state but no external I/O | Test fixtures, in-memory DB, test containers |
| 3 | **Lightweight fakes** | Interface-based deps with simple contracts | `class FakeEmailSender implements EmailSender { sent: Email[] = [] }` |
| 4 (last resort) | **Mocks (vi.fn/jest.fn)** | External I/O, non-determinism, expensive ops | HTTP APIs, payment gateways, `Date.now()`, `crypto.randomUUID()` |

**Mocks are justified for:**
- External HTTP/gRPC services
- Payment gateways, email/SMS providers
- File system operations in unit tests
- Time (`Date.now`, timers), randomness
- Heavy computation not under test

**Mocks are not justified for:**
- Your own services, repositories, utilities (if pure or with in-memory alternatives)
- Data transformers, mappers, validators
- Simple class instantiation
- Anything where mock setup is longer than the real implementation

**Diagnostic:** If you need `as unknown as FooService` → use the real class. If a mock has 10+ method stubs → use the real class with faked dependencies.

## Pre-Writing Steps (mandatory for all workflows)

### 1. Identify Coverage Gaps

Before writing any test, read the production file and enumerate specific untested areas:

```
COVERAGE GAPS:
  UNCOVERED BRANCH: line 34, else path (when input is null)
  UNCOVERED BRANCH: line 56, catch block (DB timeout)
  UNCOVERED METHOD: calculateDiscount (lines 90-120)
  UNTESTED EDGE: quantity=0 early return (line 42)
```

Target these gaps first.

### 2. Test Amplification (for existing tests)

When fixing existing tests, classify each assertion before deciding what to do:

| Classification | Action |
|----------------|--------|
| **STRONG** — behavioral assertion, tests owned logic | KEEP |
| **WEAK** — `toBeDefined`, `toBeTruthy`, `typeof` | ADD value assertion alongside |
| **TAUTOLOGICAL** — expected value mirrors implementation (P-70) | REPLACE with spec-derived literal |
| **DEAD** — always-true, silent skip, unreachable | DELETE and replace with real test |

Rewrite from scratch only when more than 60% of assertions are WEAK + TAUTOLOGICAL + DEAD.

### 3. Oracle Independence

For each expected value, verify its source:

| Source | Quality |
|--------|---------|
| Spec/requirements/documentation | Best |
| Manual calculation from business rules (as literal: `220`, not `100 * 2 * 1.1`) | Good |
| Known reference data / fixtures | Good |
| Inverse operation (`decode(encode(x)) === x`) | Good |
| **Copied from implementation** | **Reject (P-70)** |

For financial and algorithmic code: derive expected values from 2 independent sources (dual-oracle). Disagreement = flag for review.

## Prohibited Test Patterns

- `it.todo()` / `it.skip()` / `describe.skip()` for required tests = BLOCKING
- Tests without assertions (calling code without verifying output)
- Mocking the unit under test
- Snapshot tests as the only coverage for a component
- Blind snapshot updates (`jest -u`) without reviewing diffs
- Tests depending on execution order

## Quick-Fail Patterns (any one triggers Q17 critical gate FAIL)

**1. Always-true assertions (AP9)**
```typescript
// FORBIDDEN — screen is always defined
expect(screen).toBeDefined();
// FIX
expect(screen.getByText('Industry Name')).toBeInTheDocument();
```

**2. UI input echo (AP10)**
```typescript
// FORBIDDEN — you typed 'moon', you check 'moon'
await userEvent.type(input, 'moon');
expect(input).toHaveValue('moon');
// FIX — assert the downstream effect
expect(fetchProfiles).toHaveBeenCalledWith({ searchParams: { first_name: 'moon' } });
```

**3. MSW mock echo (AP10)**
```typescript
// FORBIDDEN — MSW returns { id: 29 }, you verify id === 29
expect(payload.id).toEqual(id);
// FIX — verify transformed or computed output
expect(payload.industry_name).toBe('Finance');
```

**4. Opaque dispatch verification**
```typescript
// FORBIDDEN — proves "a thunk was dispatched" but not which one
expect(typeof dispatchedAction).toBe('function');
// FIX — mock the thunk, verify CalledWith
expect(fetchProfiles).toHaveBeenCalledWith({ searchParams: expect.objectContaining({ first_name: 'moon' }) });
```

**5. Silent test skip (AP2)**
```typescript
// FORBIDDEN — test passes when it skips
if (checkboxes.length === 0) return;
// FIX
expect(checkboxes.length).toBeGreaterThan(0);
```

**6. Redux wrong initial state (P-40)**
```typescript
// FORBIDDEN
const state = reducer({ initialState: {} }, action);
// FIX — use real slice state shape
const state = reduceFrom({ type: addProfile.fulfilled.type, payload });
expect(state.profiles).toContainEqual(expect.objectContaining({ id: 29 }));
```

**7. Loading-only Redux assertions (P-41)**
```typescript
// FORBIDDEN — loading checked but data never verified
expect(state.loading).toEqual(false);
// FIX — verify data in store
expect(state.loading).toBe(false);
expect(state.profiles).toEqual(PROFILE_FIXTURES);
```

**8. Tautological oracle (P-70)**
```typescript
// FORBIDDEN — expected value mirrors implementation logic
expect(calcTotal(100, 2)).toBe(100 * 2 * 1.1);
// FIX — use spec-derived literal
expect(calcTotal(100, 2)).toBe(220); // from pricing spec: "10% tax on subtotal"
```

**9. Raw .length instead of .toHaveLength (AP25)**
```typescript
// FORBIDDEN — worse error messages, masks missing property
expect(result.issues.length).toBe(3);
expect(result.password.length).toBe(12);
// FIX
expect(result.issues).toHaveLength(3);
expect(result.password).toHaveLength(12);
```

**10. Vague quantity on known fixture (AP27)**
```typescript
// FORBIDDEN — test knows fixture output but asserts "at least one"
expect(result.errors.length).toBeGreaterThan(0);
// FIX — assert exact count
expect(result.errors).toHaveLength(2);
```

**11. Mock return echoed in assertion (AP29)**
```typescript
// FORBIDDEN — proves mock setup, not production logic
mockService.findOne.mockResolvedValue(testData[0]);
const result = await controller.getOne('123');
expect(result.id).toBe(testData[0].id);  // echo
// FIX — assert computed/transformed value
expect(result.cpiAfterDiscount).toBe(2.25); // 2.5 * 0.9
```

**12. Persistent skip without tracking (AP28)**
```typescript
// FORBIDDEN — dead code, coverage gap, untracked debt
it.skip('NEG-1: seed.ts no longer defines createOptions locally', () => { ... });
describe.skip('FeedbackService', () => { /* 200 lines never run */ });
// FIX — remove, unskip, or add backlog reference
// SKIP: [JIRA-123] blocked by migration, expires 2026-04-15
```

## Red Flags -- Quick Heuristics

These indicators correlate with low test quality. Use as pre-screening before full Q1-Q17 evaluation.

| Indicator | Avg Score | What it signals |
|-----------|-----------|-----------------|
| 0 CalledWith in entire file | 2.6/10 | Almost certainly Tier C/D |
| 4+ CalledWith assertions | 8.4/10 | Likely Tier A/B |
| Factory functions (`makeX()`) | 8.4/10 | Strongest single quality predictor |
| `toBeTruthy()` as sole assertion | 2.5/10 | No real verification |
| Fixture:assertion ratio > 20:1 | 2.3/10 | Auto Tier-D |
| Tests calling `__privateMethod()` | 3.0/10 | Coupled to implementation |
| `expect(x.length).toBe(N)` not `.toHaveLength(N)` | 4.5/10 | AP25: worse error messages |
| `expect(x.length).toBeGreaterThan(0)` on known fixture | 4.0/10 | AP27: vague quantity, masks bugs |
| Mock return echoed in assertion | 2.8/10 | AP29: input echo, Q17 failure |
| Mock-to-assertion ratio > 2.0 | 4.0/10 | More mock setup than assertions |
| 0 CalledWith AND >3 bare toHaveBeenCalled() | 3.0/10 | Q15 failure predictor |
| BOTH bare toHaveBeenCalled() AND toBeDefined() in same file | 5.5/10 | Either alone avg 9/17, both avg 5.5/17 |
| `describe.skip`/`it.skip` without ticket or expiry | 5.0/10 | AP28: persistent dead code |

---

## Refactoring and Tests

1. **Before:** run existing tests to establish a passing baseline
2. **During:** update tests alongside each code change
3. **After:** full suite must pass with no coverage drop
4. If tests fail after refactoring: fix the code or update the tests — never delete tests without replacement

## Self-Evaluation (mandatory after writing tests)

Score every question individually. Never group or estimate.

**17 binary gates (1 = YES, 0 = NO):**

| # | Gate |
|---|------|
| Q1 | Every test name describes expected behavior (not "should work")? |
| Q2 | Tests grouped in logical describe blocks? |
| Q3 | Every mock has `CalledWith` (positive) AND `not.toHaveBeenCalled` (negative)? |
| Q4 | Known-data assertions use exact values (`toEqual`/`toBe`, not `toBeTruthy`)? |
| Q5 | Mocks are typed (not `as any`/`as never`)? |
| Q6 | Mock state is fresh per test (proper `beforeEach`, no shared mutable)? |
| Q7 | **CRITICAL** — At least one error path test (throws/rejects/returns error)? |
| Q8 | Null/undefined/empty inputs tested where applicable? |
| Q9 | Repeated setup (3+ tests) extracted to helper/factory? |
| Q10 | No magic values — test data is self-documenting? |
| Q11 | **CRITICAL** — All code branches exercised (if/else, switch, early return)? |
| Q12 | Symmetric: every "does X when Y" has "does NOT do X when not-Y"? **For each repeated pattern (auth guard, validation, error), verify every method has it.** |
| Q13 | **CRITICAL** — Tests import the actual production function (not a local copy)? |
| Q14 | Assertions verify behavior, not just that a mock was called? |
| Q15 | **CRITICAL** — Assertions verify content/values, not just counts or shape? |
| Q16 | Cross-cutting isolation: change to A verified not to affect B? |
| Q17 | **CRITICAL** — Assertions verify computed output, not input echo? Expected values from spec/manual calc, not copied from implementation (P-70). |

**N/A handling:** Q3/Q5/Q6 = 1 (N/A) for pure functions with zero mocks. Q16 = 1 (N/A) for simple single-responsibility units.

**Critical gate:** Q7, Q11, Q13, Q15, Q17 — any scored 0 caps the result at FIX regardless of total.

**Scoring:** Total count of yes answers (N/A counts as 1). 14+ = PASS, 9-13 = FIX (fix worst gap, re-score), below 9 = BLOCK (rewrite).

**Output format:**
```
Self-eval: Q1=1 Q2=1 Q3=0 Q4=1 Q5=1 Q6=1 Q7=1 Q8=0 Q9=1 Q10=1 Q11=1 Q12=0 Q13=1 Q14=1 Q15=1 Q16=1 Q17=1
  Score: 14/17 → PASS | Critical gate: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 → PASS
```

## Post-Test Mutation Check (mandatory)

After writing tests, mentally apply these 5 mutations to the production code. For each one, ask: "Would any test catch this?"

| # | Mutation | Verification |
|---|---------|--------------|
| M1 | Negate the main condition (`if (x > 0)` → `if (x <= 0)`) | Both branches have a test? |
| M2 | Remove a null guard (`if (!input) return default`) | A test passes `null` and checks the default? |
| M3 | Swap an operator (`>=` → `>`, `&&` → `\|\|`) | A boundary-value test fails on the wrong operator? |
| M4 | Change a return value (`return result` → `return null`) | An assertion checks the specific return value? |
| M5 | Change the error message/type | An error test asserts the specific message? |

If any mutation would go undetected, add a targeted test before continuing.

## Completion Checklist (do not skip)

Before declaring a task complete, verify every item:

- [ ] New code has tests (if production files > 0 and test files = 0 → write tests)
- [ ] Tests pass locally (run the test command, do not assume)
- [ ] Self-eval 14/17+ with all critical gates passing (Q7 + Q11 + Q13 + Q15 + Q17)
- [ ] Oracle check: no expected values copied from implementation (P-70)
- [ ] Mutation check: M1-M5 all caught
- [ ] Coverage did not decrease
- [ ] No skipped or todo tests for new code
