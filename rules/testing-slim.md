# Test Rules (Slim)

> Condensed testing rules for write-tests pipeline. Full reference with examples: `testing.md`.

## Required Tests by Code Type

- **Function/Utility:** happy path, error cases, edge cases (null/empty/boundary)
- **Component:** render + user flow tests (30%+ must be flow tests), props/state, error state, a11y
- **API Endpoint:** 200/201 success, 400/401/403/404/500 errors, input validation, auth. Security: S1-S4 mandatory (invalid schema, no auth, wrong role, wrong tenant)
- **Hook:** return values, state transitions, side effects

## Mock Rules

Default: use real code. Mock only when forced by external I/O.

Priority: real impl > controlled inputs > lightweight fakes > mocks (last resort).

Mocks justified for: external HTTP, payment, email, file system, time, randomness.
Mocks NOT justified for: your own services, transformers, validators, simple classes.

## Pre-Writing Steps

1. **Coverage gaps:** list uncovered branches, methods, edge cases from production file
2. **Oracle independence:** every expected value from spec/manual calc, NEVER copied from implementation

## Prohibited Patterns

- `it.todo()` / `it.skip()` / `describe.skip()` without ticket = BLOCKING
- Tests without assertions
- Mocking the unit under test
- Snapshot tests as sole coverage
- Tests depending on execution order

## Quick-Fail (any one = Q17 FAIL)

- Always-true assertions (`expect(screen).toBeDefined()`)
- Input echo (`type('x')` then `expect.toHaveValue('x')`)
- Mock return echoed in assertion
- Tautological oracle (expected mirrors implementation: `expect(fn(100,2)).toBe(100*2*1.1)`)
- Vague quantity on known fixture (`toBeGreaterThan(0)` instead of exact count)

## Q1-Q19 Gates (score after writing)

Critical gates (any=0 caps at FIX): **Q7** error paths, **Q11** branches, **Q13** imports real fn, **Q15** value assertions, **Q17** no tautology.

16+/19 = PASS, 10-15 = FIX, <10 = BLOCK.

## Mutation Check (M1-M5)

After writing: mentally negate main condition (M1), remove null guard (M2), swap operator (M3), change return value (M4), change error message (M5). If any mutation undetected → add test.

## Anti-Tautology

Grep for: input echo, mock return echo, variable-assigned-then-asserted. Any match = Q17 violation → fix.
