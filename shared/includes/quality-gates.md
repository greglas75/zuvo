# Quality Gates — Quick Reference

> Summary of CQ1-CQ28 (code quality) and Q1-Q19 (test quality) gates for agent use.

This is a condensed reference. Full details, evidence examples, and N/A rules are in `rules/cq-checklist.md` (code) and `rules/testing.md` (tests). Agents should read the full files when performing detailed evaluations. CQ23-CQ28 and Q18-Q19 were added in v1.3.0.

## CQ1-CQ28: Code Quality Gates

| # | Category | What it checks |
|---|----------|---------------|
| CQ1 | Types | No loose strings/numbers where unions fit. No `==`/`!=`. |
| CQ2 | Types | Public functions have explicit return types. No implicit `any`. No `as unknown as X`. No unjustified `!`. |
| CQ3 | Validation | Boundary inputs validated: required fields, format/range, runtime schema. |
| CQ4 | Security | Auth guards backed by query-level filtering. Guard alone is not enough. |
| CQ5 | Security | No PII in logs (ALL outputs including structured logger), error messages, response bodies, headers, or query params. |
| CQ6 | Resources | No unbounded memory from external data. Pagination or streaming enforced. |
| CQ7 | Resources | DB queries bounded with LIMIT/cursor. List endpoints return slim payloads. |
| CQ8 | Errors | Infrastructure failures handled. Timeouts on outbound calls. `response.ok` checked. No empty catch blocks. |
| CQ9 | Data | Multi-table mutations wrapped in transactions. FK order respected. |
| CQ10 | Data | Nullable values guarded. No `.find()` without null check. No unsafe `as`/`!`. |
| CQ11 | Structure | File and function sizes within limits. No deep nesting (>4). Max 5 params. |
| CQ12 | Structure | No magic strings or numbers. Named constants used. |
| CQ13 | Hygiene | No dead code, no TODO without ticket, no stale flags (>30d = stale), no mixed logging. |
| CQ14 | Hygiene | No duplicated logic (blocks >10 lines repeated, or same pattern 5+ times). |
| CQ15 | Async | Every async call awaited or has `.catch()`. `return await` in try/catch. |
| CQ16 | Data | Money uses integer-cents or Decimal. No float arithmetic on currency. |
| CQ17 | Performance | No sequential await in parallelizable loops. No N+1. No `.find()` in loop. |
| CQ18 | Data | Cross-system consistency handled. Partial sync failures addressed. |
| CQ19 | Contract | API request and response validated by runtime schema. |
| CQ20 | Contract | Single canonical source per data point. No dual fields stored independently. |
| CQ21 | Concurrency | No TOCTOU races. Mutations idempotent or CAS-protected. Mutating endpoints safe to retry (idempotency key). |
| CQ22 | Resources | Listeners, timers, observers cleaned up on unmount. No stale closures. |
| CQ23 | Resources | Cache has TTL or explicit invalidation. No stale-forever entries. |
| CQ24 | Contract | API changes additive only. Breaking changes have deprecation path. |
| CQ25 | Structure | New code follows existing project patterns. No special snowflakes. |
| CQ26 | Observability | Structured logger with context (requestId, userId), not plain console.log. |
| CQ27 | Observability | Log levels correct. `error` for infrastructure failures only, not validation. |
| CQ28 | Resilience | Timeout hierarchy correct: client < server < DB. |

### Critical Gates (Static)

These are always critical. If any scores 0, the evaluation is FAIL regardless of total:

**CQ3, CQ4, CQ5, CQ6, CQ8, CQ14**

### Critical Gates (Conditional)

These become critical only when the code context activates them:

| Gate | Activates when |
|------|---------------|
| CQ16 | Code touches prices, costs, discounts, invoices, payouts |
| CQ19 | Code crosses an API or module boundary |
| CQ20 | Payload contains `*_id` + `*_name` pairs or number + currency-string |
| CQ21 | Concurrent mutations on the same resource |
| CQ22 | Code creates subscriptions, timers, or observers |
| CQ23 | Code uses Redis, Memcached, or in-memory caching |
| CQ24 | Code modifies existing API endpoint signatures |
| CQ28 | Code defines timeouts at 2+ architectural layers |

### CQ Scoring

| Result | Criteria |
|--------|---------|
| PASS | Score >= 24/28 AND all active critical gates = 1 |
| CONDITIONAL PASS | Score 22-23/28 AND all active critical gates = 1 |
| FAIL | Any active critical gate = 0, OR total score < 22 |

### CQ Evidence Format

Every gate scored as 1 requires evidence:

```
CQ[N]=1
  Scope: [what was checked — e.g., "7 Prisma queries in order.service.ts"]
  Evidence: file:function:line — [what satisfies the gate]
  Exceptions: [deliberate exclusions with rationale, or "none"]
```

No evidence = score is 0. Vague claims ("errors handled") are not evidence.

### N/A Abuse Rule

If more than 60% of gates (17+) are scored N/A, flag the evaluation as "low-signal audit" and justify each N/A individually. N/A counts as 1 for scoring but requires a one-sentence explanation.

---

## Q1-Q19: Test Quality Gates

| # | What it checks |
|---|---------------|
| Q1 | Test names describe expected behavior (not "should work") |
| Q2 | Tests grouped in logical describe blocks |
| Q3 | Every mock verified with `CalledWith` (positive) and `not.toHaveBeenCalled` (negative) |
| Q4 | Assertions use exact values (`toEqual`/`toBe`), not loose checks (`toBeTruthy`) |
| Q5 | Mocks are properly typed (no `as any` or `as never`). Note: `as unknown as ServiceType` is acceptable when no mock factory exists — it avoids `as any` while preserving the target type. Score Q5=1 for `as unknown as X`, Q5=0 only for `as any` or `as never`. |
| Q6 | Mock state reset between tests (proper `beforeEach`, no shared mutable state) |
| Q7 | Every error-throwing path tested with specific error type AND message (not just "at least one") |
| Q8 | Null, undefined, and empty inputs tested where applicable |
| Q9 | Repeated setup (3+ tests) extracted to helper or factory |
| Q10 | No magic values — test data is self-documenting |
| Q11 | All code branches exercised (if/else, switch, early return) |
| Q12 | Symmetric testing: "does X when Y" paired with "does NOT do X when not-Y" |
| Q13 | Tests import the actual production function (not a local copy) |
| Q14 | Assertions verify behavior, not just that a mock was called |
| Q15 | Assertions verify content and values, not just counts or shapes |
| Q16 | Cross-cutting isolation: changes to A verified not to affect B |
| Q17 | Assertions verify computed output, not input echo. Expected values from spec, not copied from implementation. |
| Q18 | No flaky signals: no `Date.now()` without fake timers, no `setTimeout` for timing, no `Math.random()` without seed, no execution-order dependence. |
| Q19 | Tests fully isolated: no shared mutable state between tests, each test runs independently in any order. |

### Critical Gates

These are always critical. If any scores 0, the evaluation is capped at FIX:

**Q7, Q11, Q13, Q15, Q17**

### Q Scoring

| Result | Criteria |
|--------|---------|
| PASS | Score >= 16/19, all critical gates = 1 |
| FIX | Score 10-15/19, or any critical gate = 0 — fix worst gaps, re-score |
| REWRITE | Score < 10 — tests need fundamental rework |

### Q Evidence Format

```
Self-eval: Q1=1 Q2=1 Q3=0 Q4=1 Q5=1 Q6=1 Q7=1 Q8=0 Q9=1 Q10=1 Q11=1 Q12=0 Q13=1 Q14=1 Q15=1 Q16=1 Q17=1 Q18=1 Q19=1
  Score: 16/19 → PASS | Critical gate: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 → PASS
```

---

## Fix-First Rule

When a gate violation is found during evaluation:

1. Can you fix it in under 5 minutes? If yes, fix it now and re-score as 1.
2. Is it a critical gate violation? If yes, fix it now regardless of time.
3. Otherwise, score as 0 and note what needs fixing. Persist to backlog if not fixed in this session.

Adding a WHERE clause, null guard, try/catch, or type annotation is never "out of scope."
