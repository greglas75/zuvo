# Q1-Q25 Test Quality Scoring Protocol

> Shared protocol for evaluating test quality. Used by write-tests, execute, fix-tests, write-e2e, and any skill that scores test files.

## Scoring Rules

**Source of truth:** Q1-Q25 gate definitions from `quality-gates.md`. Do NOT use memorized definitions — read the canonical file.

For each gate, score as:
- **1** — gate satisfied, with evidence (file:function:line or specific quote)
- **0** — gate violated, with evidence of the violation
- **N/A** — gate does not apply (with one-sentence justification)

**No evidence = score 0.** "Tests are thorough" is not evidence. "slug.test.ts:describe('edge cases'):42 — tests empty string, unicode, and max-length inputs" is evidence.

## Critical Gates

These gates are absolute pass/fail. Any critical gate at 0 = FAIL regardless of total score.

```
Q7  — Every error-throwing path tested with a specific error TYPE and MESSAGE
Q11 — All code branches exercised (if/else, switch, early return)
Q13 — Tests import the ACTUAL production function (not a local copy of it)
Q15 — Assertions verify content/values, not just counts or shape
Q17 — No tautological oracles (mock returns X, assert X) — expected values from spec, not echoed input
```

> These five IDs are the canonical critical gates, but the labels above were previously WRONG:
> Q7 carried Q14's text, Q11 carried Q18's, Q13 carried Q7's, and Q15 carried Q3's. Any skill
> reading this file scored a different gate than `review`/`test-audit` scored under the same ID.
> If a label here ever disagrees with `rules/testing.md`, that file wins — re-read it rather than
> trusting this summary.

## Scoring Thresholds

```
>= 82% of applicable, all critical gates = 1   →  PASS
>= 0.53 and < 0.82 of applicable, all critical gates = 1  →  FIX (improve weak gates)
< 53% OR any critical gate = 0                →  REWRITE

applicable = 25 - count(N/A) - count(out-of-scope)
```

**Percentages, not raw counts.** The gate set grows (19 -> 25 in v1.6.41), and an absolute
threshold silently changes meaning when it does: "16+" was 84% of 19 and would have become 64% of
25 — a two-band loosening produced by arithmetic, not by any decision about quality. The bands
above are the ones `test-audit` already applies, so the two now agree.

## N/A Abuse Check

Count N/A scores. If more than 50% (10+ gates) are N/A:

1. Flag as "low-signal audit"
2. Justify each N/A individually
3. Consider whether the test file is too small for meaningful evaluation

N/A is valid when the gate genuinely does not apply (e.g., Q11 for pure synchronous tests). N/A is abuse when used to avoid evaluation (e.g., Q13 scored N/A for code that throws exceptions).

## Output Format

```
Q SCORE: [passed]/[applicable] → [PASS | FIX | REWRITE]
  (applicable = 25 - count(N/A) - count(out-of-scope) — never a fixed denominator)
Critical gates: Q7=[0|1] Q11=[0|1] Q13=[0|1] Q15=[0|1] Q17=[0|1]

Q1=[score]  [evidence or N/A justification]
Q2=[score]  [evidence]
...
Q25=[score] [evidence]
```

Every gate Q1-Q25 has a line. Every score has evidence. No exceptions — a run that stops at Q19 is INCOMPLETE, not a clean score.

## Guardrails

- Do NOT score a gate as 1 without file:line evidence
- Do NOT score N/A to avoid a hard evaluation — justify every N/A
- Do NOT pass tests with a critical gate at 0
- Do NOT evaluate from memory — read the actual test file
- Do NOT conflate "tests pass" with "tests are good" — green suite ≠ quality
