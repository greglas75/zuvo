# Q1-Q19 Test Quality Scoring Protocol

> Shared protocol for evaluating test quality. Used by write-tests, execute, fix-tests, write-e2e, and any skill that scores test files.

## Scoring Rules

**Source of truth:** Q1-Q19 gate definitions from `quality-gates.md`. Do NOT use memorized definitions — read the canonical file.

For each gate, score as:
- **1** — gate satisfied, with evidence (file:function:line or specific quote)
- **0** — gate violated, with evidence of the violation
- **N/A** — gate does not apply (with one-sentence justification)

**No evidence = score 0.** "Tests are thorough" is not evidence. "slug.test.ts:describe('edge cases'):42 — tests empty string, unicode, and max-length inputs" is evidence.

## Critical Gates

These gates are absolute pass/fail. Any critical gate at 0 = FAIL regardless of total score.

```
Q7  — Tests verify behavior, not implementation details
Q11 — No flaky patterns (timers, random, network without mock)
Q13 — Error paths tested (every throw/reject has a catching test)
Q15 — Mocks verified with toHaveBeenCalledWith
Q17 — No tautological oracles (mock returns X, assert X)
```

## Scoring Thresholds

```
16+/19, all critical gates = 1  →  PASS
12-15/19, all critical gates = 1  →  FIX (improve weak gates)
<12/19 OR any critical gate = 0  →  REWRITE
```

## N/A Abuse Check

Count N/A scores. If more than 50% (10+ gates) are N/A:

1. Flag as "low-signal audit"
2. Justify each N/A individually
3. Consider whether the test file is too small for meaningful evaluation

N/A is valid when the gate genuinely does not apply (e.g., Q11 for pure synchronous tests). N/A is abuse when used to avoid evaluation (e.g., Q13 scored N/A for code that throws exceptions).

## Output Format

```
Q SCORE: [N]/19 → [PASS | FIX | REWRITE]
Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]

Q1=[score]  [evidence or N/A justification]
Q2=[score]  [evidence]
...
Q19=[score] [evidence]
```

Every gate has a line. Every score has evidence. No exceptions.

## Guardrails

- Do NOT score a gate as 1 without file:line evidence
- Do NOT score N/A to avoid a hard evaluation — justify every N/A
- Do NOT pass tests with a critical gate at 0
- Do NOT evaluate from memory — read the actual test file
- Do NOT conflate "tests pass" with "tests are good" — green suite ≠ quality
