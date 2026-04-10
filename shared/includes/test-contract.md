# Pre-Write Test Contract

> Fill this contract BEFORE writing any test code. Do not skip sections. Empty sections = you haven't read the production code carefully enough.

## Purpose

This contract forces the agent to plan tests from the production code's behavior, not from intuition or memory. Every assertion must trace back to a contract entry. Tests written without this contract tend to be shallow (weak assertions, missing branches, tautological oracles).

## When to Use

- `zuvo:write-tests` — Phase 3, before writing each test file
- `zuvo:build` — before writing tests for each production file
- `zuvo:execute` — before the GREEN phase of each TDD task
- Any workflow that produces test files

## The Contract

Fill this template for each production file being tested:

```
TEST CONTRACT: [production-file-path]
═══════════════════════════════════════

1. BRANCHES (exhaustive list from production code)
   List every branching point. Each MUST have at least one test on each side.

   Branch 1: [file:line] if (condition) → test TRUE path + test FALSE path
   Branch 2: [file:line] switch (value) → test each case + default
   Branch 3: [file:line] try/catch → test success path + each error type
   Branch 4: [file:line] early return → test trigger + test skip
   ...

   Total branches: [N]
   Minimum tests from branches alone: [N × 2]

2. ERROR PATHS (every way this code can fail)
   List every throw, reject, error return, and catch block.

   Error 1: [file:line] throws [ErrorType] when [condition] — message: "[exact or pattern]"
     Side-effects NOT executed: [insert, update, email send, etc.]
   Error 2: [file:line] rejects with [ErrorType] when [condition]
     Side-effects NOT executed: [list]
   Error 3: [file:line] returns { error: ... } when [condition]
     Side-effects NOT executed: [list]
   Error 4: [file:line] catch block handles [what] — does [action]
   ...

   Total error paths: [N]
   Tests needed: [N] (one per error path, asserting specific type + message)

   For each error path, verify BOTH:
   - The correct error is thrown (type + message)
   - Operations AFTER the throw point were NOT called (insert, update, emit, etc.)

3. EXPECTED VALUES (where each assertion value comes from)
   For every assertion you plan to write, state the SOURCE of the expected value.

   Assertion 1: expect(result).toBe(220) — SOURCE: pricing spec says "10% tax on subtotal", 100×2×1.1=220
   Assertion 2: expect(status).toBe('active') — SOURCE: business rule: "users with verified email are active"
   Assertion 3: expect(items).toHaveLength(3) — SOURCE: fixture has exactly 3 items matching filter
   ...

   REJECTED sources (P-70 violation):
   ✗ "I ran the function and it returned X" — that's copying implementation output
   ✗ "The code does X * Y so I expect X * Y" — that's mirroring the formula
   ✗ "The mock returns X so I check for X" — that's echo testing

   EXCEPTION — pass-through delegation (NOT a P-70 violation):
   For methods whose contract IS "return exactly what the delegate gives" (service facades,
   thin wrappers, DB query pass-through), `expect(result).toBe(mockReturnValue)` is correct.
   The mock-echo IS the behavioral test — the method's job is to pass through unchanged.
   Must be COMBINED with CalledWith on the delegate (verifies correct query/args).
   This exception applies ONLY when the method body is `return delegate(args)` with no
   transformation. If the method filters, maps, or computes — P-70 applies normally.

4. MOCK INVENTORY (what gets mocked and why)
   List every dependency that will be mocked, and justify WHY a mock is needed.

   Mock 1: [dependency] — WHY: external HTTP call / database I/O / non-deterministic
   Mock 2: [dependency] — WHY: [justification]
   NOT mocked: [dependency] — WHY: pure function, using real implementation

   For each mock, state:
   - What it returns (success case)
   - What it throws (error case)
   - CalledWith assertion planned: YES/NO

5. MUTATION TARGETS (pre-planned M1-M5 from testing.md)
   For each mutation, name the test that would catch it:

   M1 (negate main condition): Test "[name]" would fail
   M2 (remove null guard): Test "[name]" would fail
   M3 (swap operator): Test "[name]" would fail
   M4 (change return value): Test "[name]" would fail
   M5 (change error message): Test "[name]" would fail

   If any mutation has no catching test → add one to the plan.

6. TEST OUTLINE (describe/it structure)
   describe('[UnitName]')
     describe('[method or behavior group]')
       it('[expected behavior when condition]') — covers Branch 1 TRUE
       it('[expected behavior when opposite]') — covers Branch 1 FALSE
       it('[throws ErrorType when condition]') — covers Error 1
       ...
```

## Verification

After filling the contract, verify:

- [ ] Every branch from section 1 has at least one test in section 6
- [ ] Every error path from section 2 has a dedicated test in section 6
- [ ] No expected value in section 3 is sourced from implementation output
- [ ] Every mock in section 4 has a CalledWith assertion planned
- [ ] All 5 mutations in section 5 have a catching test identified
- [ ] Test count >= minimum from Code-Type Gate formula

If any check fails, expand the test outline before writing code.

## ORCHESTRATOR Contract Variant

For ORCHESTRATOR files (app.ts, server.ts, main.ts) — replace sections 1-3 with these. Keep sections 4-6.

```
TEST CONTRACT (ORCHESTRATOR): [production-file-path]
═══════════════════════════════════════

1. MIDDLEWARE ORDERING (what runs in what order)
   List every middleware registration in source order:

   Position 1: [file:line] app.use("*", requestId)     — purpose: assign request ID
   Position 2: [file:line] app.use("*", errorHandler)   — purpose: catch downstream errors
   Position 3: [file:line] app.use("*", corsMiddleware)  — purpose: CORS headers
   ...

   Critical ordering constraints:
   - errorHandler MUST follow requestId (needs ID for error logs)
   - dbMiddleware MUST precede route handlers (they need DB connection)

2. AUTH BOUNDARY MATRIX (which middleware applies where)
   Fill every cell. Every NO cell needs a negative assertion test.

   | Route group | clerkAuth | tenantResolver | publicTenantResolver | rateLimit |
   |-------------|-----------|----------------|---------------------|-----------|
   | Admin       | YES       | YES            | NO                  | NO        |
   | Public      | NO        | NO             | YES                 | per-path  |
   | Webhook     | NO        | NO             | NO                  | NO        |
   | Health      | NO        | NO             | NO                  | NO        |

3. RATE LIMIT BINDING (path → config)
   Each rate limiter has a target path and config:

   Limit 1: /contests/*/register → (3, 3600) — 3 per hour
   Limit 2: /contests/*/verify   → (5, 3600) — 5 per hour
   ...

   Test: each limit must have a path-execution test (not just factory call).

4-6: Same as standard contract (MOCK INVENTORY, MUTATION TARGETS, TEST OUTLINE).
```

Use this variant when `test-code-types.md` classifies the file as ORCHESTRATOR. The standard contract (sections 1-3 above) is for SERVICE, CONTROLLER, PURE, and other types.

## Anti-Patterns This Contract Prevents

| Problem | How the contract catches it |
|---------|---------------------------|
| Missing branches | Section 1 forces exhaustive branch listing |
| Weak error tests | Section 2 requires specific error type + message per path |
| Tautological oracles (P-70) | Section 3 rejects implementation-derived expected values |
| Unnecessary mocks | Section 4 requires justification for each mock |
| Undetectable mutations | Section 5 maps each mutation to a specific test |
| Shallow test suites | Minimum test count derived from branches + errors, not intuition |
