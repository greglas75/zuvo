# Q1-Q25 Test Quality Scoring Protocol

> Shared protocol for evaluating test quality. Used by write-tests, execute, fix-tests, write-e2e, and any skill that scores test files.

## Scoring Rules

**Source of truth:** Q1-Q25 gate definitions from `quality-gates.md`. Do NOT use memorized definitions — read the canonical file.

For each gate, score as:
- **1** — gate satisfied, with evidence (file:function:line or specific quote)
- **0** — gate violated, with evidence of the violation
- **N/A** — gate precondition verified inactive (with reason and source evidence; unavailable measurements use only the explicit exception in that gate, such as Q21)

**No evidence = score 0.** "Tests are thorough" is not evidence. "slug.test.ts:describe('edge cases'):42 — tests empty string, unicode, and max-length inputs" is evidence.

## Critical Gates

These gates are absolute pass/fail. Any critical gate at 0 = FAIL regardless of total score.

```
Q7  — Every contract negative case tested: throws/rejections assert type+message; filter/sentinel/fallback cases assert exact results within the accepted input domain
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

## Q7 Accepted Input Domain

Read the production signature, runtime entry points, documented contract and callers first.
Record negative cases the function promises to handle, including malformed inputs reaching
untrusted boundaries. Internal helpers may rely on a caller's proven validation; TypeScript types
alone do not validate an HTTP payload. Do not demand a new throw on typed out-of-domain `null`
to satisfy a test score. Filtering unsupported records or returning a documented sentinel is
negative behavior too: assert the exact retained records or sentinel, not merely "did not throw".
For real throwing/rejecting paths, type AND message assertions remain mandatory. List every
feasible negative path and its test. If the full accepted domain has no negative cases, Q7=1
requires an exhaustive contract, branch and caller inventory proving their absence. A total
getter is not required to invent a throw. Missing investigation remains 0/unproven, not a pass.
Untrusted inputs include HTTP handlers, CLI arguments, files, messages and deserialization;
trace callees up to the actual runtime validator before claiming an internal-only domain.

## Scoring Thresholds

```
>= 82% of applicable, all critical gates = 1   →  PASS
>= 53% and < 82% of applicable, all critical gates = 1  →  FIX (improve weak gates)
< 53% OR any critical gate = 0                →  REWRITE

applicable = 25 - count(N/A) - count(out-of-scope)
```

**Percentages, not raw counts.** The gate set grows (19 -> 25 in v1.6.41), and an absolute
threshold silently changes meaning when it does: "16+" was 84% of 19 and would have become 64% of
25 — a two-band loosening produced by arithmetic, not by any decision about quality. The bands
above are the ones `test-audit` already applies, so the two now agree.

## N/A Abuse Check

Count N/A scores. If more than 50% of in-scope Q gates are N/A:

1. Flag as "low-signal audit"
2. Justify each N/A individually
3. Until every exclusion is supported by the required evidence or a gate-specific unavailable-measurement exception, mark the audit INCOMPLETE. Once resolved, score normally; a high count alone does not reject a small unit. This Q review trigger is separate from the CQ independent-review threshold.

N/A is valid when the precondition is verified inactive (e.g., Q5 with no mocks). Synchronous code still requires Q11 branch coverage, and Q13 still requires importing the actual production unit. Unknown applicability is 0/unproven, never N/A. An unavailable measurement may be N/A only when its canonical gate explicitly permits it (Q21); it is not a passing measurement. A zero denominator is INCOMPLETE, never PASS.

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
