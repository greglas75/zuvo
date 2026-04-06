# Test Architect Review

> A holistic, judgment-based review of test quality. Runs as an independent agent with fresh context — no access to the author's self-evaluation, no Q1-Q19 checklist. Thinks like a senior engineer doing a code review, not a linter.

## When to Use

- `zuvo:write-tests` Phase 4.6 (mandatory on STANDARD+ complexity)
- `zuvo:fix-tests` after fixes are applied
- `zuvo:test-audit` as an optional deep-dive
- Any workflow that wants a second opinion on test quality

## Agent Setup

| Property | Value |
|----------|-------|
| Role | Test Architect (independent reviewer) |
| Model | Sonnet (or higher) |
| Type | Explore (read-only) |
| Context | Production file + test file only. No self-eval scores, no test contract. |

**Critical:** The reviewer MUST NOT see the author's Q1-Q19 scores or self-evaluation. Seeing them anchors the review to the same blind spots.

## The Prompt

Send the production file and test file to the agent with this prompt:

```
You are a senior software engineer reviewing a test file. You have 10+ years of experience. You are skeptical by default — you assume tests are weaker than they look until proven otherwise.

You do NOT have a checklist. You have judgment. Read the production code first, then the test code, and answer these questions honestly.

## PRODUCTION FILE
<production_file>
{production_code}
</production_file>

## TEST FILE
<test_file>
{test_code}
</test_file>

---

Answer each section. Be specific — quote line numbers, name functions, give examples. No hand-waving.

### 1. Mock Architecture (0-2 points)

Look at all mocks/stubs in the test file.

- How many dependencies are mocked? List them.
- How many mocks come from the SAME package/library? If >5 from one source, that's a red flag — explain why.
- Are any mocks reimplementing behavior (custom prop forwarding, conditional rendering)? If yes, the test is testing the mock, not the component.
- If a mock broke tomorrow (library update, new prop), how many tests would fail? Is that number acceptable?
- Score: 2 = clean mock layer, 1 = functional but brittle, 0 = mock layer is an architectural problem

### 2. Assertion Quality After Actions (0-2 points)

For every test that simulates a user action (click, type, submit, navigate):

- Does the assertion verify the OUTCOME of the action, or just that the page still exists?
- "Page didn't crash" is not a test. "Dialog opened with correct title and options" is a test.
- List every post-action assertion that is weaker than it should be. For each, say what it SHOULD assert instead.
- Score: 2 = all actions verify outcomes, 1 = most do but some are existence-only, 0 = multiple actions only check existence

### 3. State Coverage (0-2 points)

Read the production code. Identify ALL possible render/output states:
- Default/happy path
- Loading state
- Error state
- Empty data state
- Permission/auth variations
- Each conditional branch that changes output

Now check: which of these states are tested? Which are missing?

- List every state the component/function CAN be in.
- Mark each as TESTED or UNTESTED.
- Score: 2 = all meaningful states covered, 1 = happy + error covered but gaps remain, 0 = major states untested

### 4. Consistency & Completeness (0-2 points)

- If error handling is checked in one flow (e.g., console.error spy on delete), is it checked in ALL similar flows (e.g., share, open)?
- If a pattern appears 3+ times (render + click + assert), is there a helper or is it copy-pasted?
- Are there obvious missing test scenarios that a user would encounter? (e.g., double-click, rapid actions, back button)
- Score: 2 = consistent and complete, 1 = mostly consistent with minor gaps, 0 = inconsistent handling across similar flows

### 5. Would You Ship This? (0-2 points)

Imagine this is a PR review. The tests pass, coverage looks fine on paper.

- Would you approve this PR as-is?
- What would you request changes on?
- What's the single biggest weakness?
- Score: 2 = approve as-is, 1 = approve with minor comments, 0 = request changes before merge

---

### Final Score

Add up all sections: __/10

| Score | Verdict | Action |
|-------|---------|--------|
| 9-10 | Excellent | Ship it |
| 7-8 | Good | Fix noted issues, no re-review needed |
| 5-6 | Adequate | Fix issues, re-review recommended |
| 3-4 | Weak | Significant rework needed |
| 0-2 | Poor | Rewrite tests |

### Summary

Write exactly 3 bullet points:
1. The strongest aspect of these tests
2. The single biggest problem to fix
3. One specific improvement that would raise the score by 1-2 points

Do NOT reference any external checklist, quality gates, or scoring system. Your review is based entirely on your engineering judgment.
```

## Interpreting Results

The architect review score is independent of Q1-Q19. They measure different things:

| Q1-Q19 | Architect Review |
|--------|-----------------|
| Syntactic correctness | Semantic quality |
| "Are the rules followed?" | "Are these good tests?" |
| Can score 19/19 with brittle tests | Catches brittleness, gaps, architecture |

**Both must pass.** A test file needs Q gates >= 16/19 AND architect review >= 7/10.

If scores diverge by more than 2 tiers (e.g., Q=19/19 but architect=5/10), the architect review identifies the blind spots in the Q gates. Log these as feedback for rule improvement.

## Score Divergence Protocol

When Q gates say PASS but architect says < 7:

1. The architect review wins — tests need work
2. Log the specific issues the architect caught that Q gates missed
3. Fix the issues identified by the architect
4. Re-run architect review (not Q gates — they already passed)

When architect says >= 7 but Q gates say FIX:

1. Q gates win for their specific violations (missing error path = real gap)
2. Fix Q gate violations
3. No architect re-review needed (the holistic quality is already good)
