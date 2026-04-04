# Quality Gates

Zuvo enforces two quality gate systems: **CQ1-CQ28** for production code and **Q1-Q19** for test code. Every skill that writes or reviews code runs these evaluations with evidence requirements. Scores determine whether work can proceed.

---

## CQ1-CQ28: Code Quality Gates

Each gate is scored **1** (pass with evidence), **0** (fail or unproven), or **N/A** (precondition not active, requires justification).

| # | Domain | What it checks |
|---|--------|---------------|
| CQ1 | Types | Unions/enums used where plain string/number is too loose. No `==`/`!=` loose equality. |
| CQ2 | Types | Explicit return types on all public functions. No implicit `any`. No `as unknown as X`. No unjustified `!`. |
| CQ3 | Validation | Input validated at every boundary: required fields, format/range, runtime schema. |
| CQ4 | Security | Auth guards paired with query-level tenant scoping. Guard alone is insufficient. |
| CQ5 | Security | Zero sensitive data in logs (ALL outputs including structured logger), errors, response bodies, headers, or query params. |
| CQ6 | Resources | No unbounded memory growth from external data. Pagination/streaming/batching enforced. |
| CQ7 | Resources | DB queries bounded with LIMIT/cursor. List endpoints return slim payloads. |
| CQ8 | Errors | Infrastructure failures handled. Timeouts on outbound calls. `response.ok` checked. No empty catch. |
| CQ9 | Data | Multi-table mutations in transactions. FK order respected. |
| CQ10 | Data | Nullable values guarded. No `.find()` without null check. No unsafe `as`/`!`. |
| CQ11 | Structure | File/function sizes within limits. No deep nesting (>4). Max 5 params. |
| CQ12 | Structure | No magic strings or numbers. Named constants used. |
| CQ13 | Hygiene | No dead code, no TODO without ticket, no stale flags (>30d = stale), no mixed logging. |
| CQ14 | Hygiene | No duplicated logic (blocks >10 lines repeated, or same pattern 5+ times). |
| CQ15 | Async | Every async call awaited or has `.catch()`. `return await` in try/catch. |
| CQ16 | Data | Money uses integer-cents or Decimal. No float arithmetic on currency. |
| CQ17 | Performance | No sequential await in parallelizable loops. No N+1. No `.find()` in loop. |
| CQ18 | Data | Cross-system consistency handled. Partial sync failures addressed. |
| CQ19 | Contract | API request and response shapes validated by runtime schema. |
| CQ20 | Contract | Single canonical source per data point. No dual fields stored independently. |
| CQ21 | Concurrency | No TOCTOU races. Mutations idempotent or CAS-protected. Idempotency keys on mutating endpoints. |
| CQ22 | Resources | All listeners, timers, observers cleaned up on unmount. No stale closures. |
| CQ23 | Resources | Cache has TTL or explicit invalidation. No stale-forever entries. |
| CQ24 | Contract | API changes additive only. Breaking changes have deprecation path. |
| CQ25 | Structure | New code follows existing project patterns. No special snowflakes. |
| CQ26 | Observability | Structured logger with context (requestId, userId), not plain console.log. |
| CQ27 | Observability | Log levels correct. `error` for infrastructure failures only, not validation. |
| CQ28 | Resilience | Timeout hierarchy correct: client < server < DB. |

### Critical gates -- static (always block)

**CQ3, CQ4, CQ5, CQ6, CQ8, CQ14**

Any of these scored 0 is an immediate FAIL, regardless of the total score.

### Critical gates -- conditional (block when context activates)

| Gate | Becomes critical when |
|------|----------------------|
| CQ16 | Code touches prices, costs, discounts, invoices, payouts |
| CQ19 | Code crosses an API or module boundary |
| CQ20 | Payload contains `*_id` + `*_name` pairs or number + currency-string |
| CQ21 | Concurrent mutations on the same resource |
| CQ22 | Code creates subscriptions, timers, or observers |
| CQ23 | Code uses Redis, Memcached, or in-memory caching |
| CQ24 | Code modifies existing API endpoint signatures |
| CQ28 | Code defines timeouts at 2+ architectural layers |

### CQ scoring thresholds

| Result | Criteria |
|--------|---------|
| **PASS** | Score >= 24/28 AND all active critical gates = 1 |
| **CONDITIONAL PASS** | Score 22-23/28 AND all active critical gates = 1 |
| **FAIL** | Any active critical gate = 0, OR total score < 22 |

---

## Q1-Q19: Test Quality Gates

| # | What it checks |
|---|---------------|
| Q1 | Test names describe expected behavior (not "should work") |
| Q2 | Tests grouped in logical describe blocks |
| Q3 | Every mock verified with `CalledWith` (positive) and `not.toHaveBeenCalled` (negative) |
| Q4 | Assertions use exact values (`toEqual`/`toBe`), not loose checks (`toBeTruthy`) |
| Q5 | Mocks properly typed (no `as any` or `as never`) |
| Q6 | Mock state reset between tests (proper `beforeEach`, no shared mutable state) |
| Q7 | Every error-throwing path tested with specific error type AND message |
| Q8 | Null, undefined, and empty inputs tested |
| Q9 | Repeated setup (3+ tests) extracted to helper or factory |
| Q10 | No magic values -- test data is self-documenting |
| Q11 | All code branches exercised (if/else, switch, early return) |
| Q12 | Symmetric testing: "does X when Y" paired with "does NOT do X when not-Y" |
| Q13 | Tests import the actual production function (not a local copy) |
| Q14 | Assertions verify behavior, not just that a mock was called |
| Q15 | Assertions verify content and values, not just counts or shapes |
| Q16 | Cross-cutting isolation: changes to A verified not to affect B |
| Q17 | Assertions verify computed output, not input echo. Expected values from spec, not copied from implementation. |
| Q18 | No flaky signals: no `Date.now()` without fake timers, no `setTimeout` for timing, no `Math.random()` without seed. |
| Q19 | Tests fully isolated: no shared mutable state between tests, each runs independently in any order. |

### Critical gates (always block)

**Q7, Q11, Q13, Q15, Q17**

### Q scoring thresholds

| Result | Criteria |
|--------|---------|
| **PASS** | Score >= 16/19, all critical gates = 1 |
| **FIX** | Score 10-15/19, or any critical gate = 0 -- fix worst gaps, re-score |
| **REWRITE** | Score < 10 -- tests need fundamental rework |

---

## Evidence format

Every gate scored as 1 requires evidence. No evidence means the score is 0.

### CQ evidence

```
CQ[N]=1
  Scope: [what was checked -- e.g., "7 Prisma queries in order.service.ts"]
  Evidence: file:function:line -- [what satisfies the gate]
  Exceptions: [deliberate exclusions with rationale, or "none"]
```

Vague claims like "errors handled" are not evidence. Specific file paths, function names, and line numbers are required.

### Q evidence

```
Self-eval: Q1=1 Q2=1 Q3=0 Q4=1 Q5=1 Q6=1 Q7=1 Q8=0 Q9=1 Q10=1 Q11=1 Q12=0 Q13=1 Q14=1 Q15=1 Q16=1 Q17=1 Q18=1 Q19=1
  Score: 16/19 -> PASS | Critical gate: Q7=1 Q11=1 Q13=1 Q15=1 Q17=1 -> PASS
```

---

## N/A abuse prevention

If more than 60% of gates (17+ of 28 for CQ, or 12+ of 19 for Q) are scored N/A, the evaluation is flagged as **low-signal audit**. Every N/A requires a one-sentence justification explaining why the precondition is inactive. N/A counts as 1 for scoring but must be defensible.

This prevents agents from marking everything N/A to avoid doing the evaluation work.

---

## Fix-first rule

When a gate violation is found during evaluation:

1. **Can you fix it in under 5 minutes?** Fix it now, re-score as 1.
2. **Is it a critical gate?** Fix it now regardless of time.
3. **Otherwise:** Score as 0, note what needs fixing, persist to backlog if not fixed this session.

Adding a WHERE clause, null guard, try/catch, or type annotation is never "out of scope."

---

## Test anti-patterns (AP1-AP29)

Test audits check for 29 anti-patterns in addition to the Q1-Q19 gates. These are common structural problems that reduce test value:

| Range | Coverage |
|-------|----------|
| AP1-AP18 | Core anti-patterns: skip in new tests, mock-as-implementation, tautological tests, leaking state, .toBeDefined-only, etc. |
| AP25 | `expect(x.length).toBe(N)` instead of `.toHaveLength(N)` — worse error messages, masks missing property (Q4) |
| AP26 | Real timers in time-dependent tests without `useFakeTimers` — causes flaky tests |
| AP27 | `expect(x.length).toBeGreaterThan(0)` when exact fixture count is known — masks off-by-one and duplicates (Q4/Q15) |
| AP28 | Persistent `it.skip`/`describe.skip` without backlog tracking — dead code and coverage gaps |
| AP29 | Mock return value echoed in assertion — proves mock setup, not production logic (Q17). Most common audit failure. |

Full AP definitions with detection heuristics and fix guidance are in `rules/testing.md`.

---

## Where to find the full definitions

- **CQ details, scoring rules, evidence examples:** `rules/cq-checklist.md`
- **CQ code patterns (NEVER/ALWAYS pairs):** `rules/cq-patterns.md`
- **Q details, test patterns, scoring:** `rules/testing.md`
- **Test quality enforcement rules:** `rules/test-quality-rules.md`
- **Quick reference for agents:** `shared/includes/quality-gates.md`
